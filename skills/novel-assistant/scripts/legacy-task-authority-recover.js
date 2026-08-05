#!/usr/bin/env node
'use strict';

// Legacy task-authority recovery.
//
// Reads an allowlisted pre-workflow `追踪/workflow/current-task.json`, including
// the original `task_id` / `task_type` shape and a constrained
// `type=outline_backfill` shape, produces a deterministic read-only preview, archives the original bytes, and hands control back to the current
// state machine via `workflow-state-machine.js create --workflow-type
// long_write`. The script owns no creative asset writes; everything it
// touches lives under `追踪/workflow/`. Authoritative durable state is
// delegated to `workflow-task-authority` / `workflow-state-machine` rather
// than constructed inline.

const cp = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const { resolveTaskAuthority, readFocusedTask } = require('./lib/workflow-task-authority');
const { acquireNamedProjectLock } = require('./lib/workflow-state-store');

const RECOVERY_LOCK_NAME = 'legacy-recovery.lock';
const RECOVERY_LOCK_OWNER = 'legacy-task-authority-recover';
const RECOVERY_LOCK_TTL_MS = 5 * 60 * 1000;

const SCHEMA_VERSION = '1.0.0';
const WORKFLOW_TYPE = 'long_write';
const SNAPSHOT_DIR = '追踪/workflow/archived';
const SNAPSHOT_KIND = 'legacy-recovery';
const TASKS_DIR = '追踪/workflow/tasks';
const FOCUS_POINTER = '追踪/workflow/current-task.json';
const PREVIEW_ID_LENGTH = 24;
const ACTION_ID_MAX_LENGTH = 128;
const TASK_ID_PATTERN = /^[A-Za-z0-9._-]+$/;
const PREVIEW_ID_PATTERN = /^[A-Za-z0-9._-]+$/;
const WORKFLOW_ID_RE = /^[A-Za-z0-9._-]+$/;

// Directories whose contents we treat as immutable creative / planning
// assets. We exclude the workflow directory itself so recovery never tries to
// hash its own scratch state.
const PROTECTED_DIRS = ['正文', '大纲', '细纲', '设定'];

// Scope extraction patterns. The helper ONLY consumes the resume_intent
// argument — never legacy task_type or resume_command — and never returns
// the entire freeform narrative. Three shapes are recognised:
//   1. Optional 第N卷 prefix + 第N至M章/节/小节
//   2. 第N至M章/节/小节 (no volume prefix)
//   3. N-M章/节/小节 (no 第 character, preceded by a non-第 word boundary)
const SCOPE_UNSPECIFIED = '未指定';
const SCOPE_PATTERN_VOLUME = /第\s*\d+\s*卷\s*第\s*\d+\s*(?:至|到|-|~)\s*\d+\s*(?:章|节|小节)/;
const SCOPE_PATTERN_JUAN = /第\s*\d+\s*(?:至|到|-|~)\s*\d+\s*(?:章|节|小节)/;
const SCOPE_PATTERN_BARE = /(?<!第)\b\d+\s*(?:至|到|-|~)\s*\d+\s*(?:章|节|小节)/;

// Extract a tightly bounded scope token from the resume intent. Returns the
// default `SCOPE_UNSPECIFIED` when no recognised range token is present, so
// freeform narrative never becomes the successor's scope.
function extractResumeScope(intent) {
  const text = String(intent || '');
  if (!text) return SCOPE_UNSPECIFIED;
  let match = text.match(SCOPE_PATTERN_VOLUME);
  if (match) return match[0].replace(/\s+/g, '');
  match = text.match(SCOPE_PATTERN_JUAN);
  if (match) return match[0].replace(/\s+/g, '');
  match = text.match(SCOPE_PATTERN_BARE);
  if (match) return match[0].replace(/\s+/g, '');
  return SCOPE_UNSPECIFIED;
}

function normalizedDurableScope(scope) {
  return String(scope || SCOPE_UNSPECIFIED);
}

function parseArgs(argv) {
  const args = {
    command: argv[0] || '',
    projectRoot: '',
    resumeIntent: '',
    previewId: '',
    snapshot: '',
    confirm: false,
  };
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') {
      args.projectRoot = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--resume-intent') {
      args.resumeIntent = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--preview-id') {
      args.previewId = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--snapshot') {
      args.snapshot = argv[index + 1] || '';
      index += 1;
    } else if (arg === '--confirm') {
      args.confirm = true;
    } else if (arg === '--json' || arg === '--help' || arg === '-h') {
      // recognized no-op flag
    } else {
      throw recoveryFailure('blocked_invalid_argument', `unknown argument: ${arg}`);
    }
  }
  if (!args.command) throw recoveryFailure('blocked_invalid_argument', 'missing command');
  if (!args.projectRoot) throw recoveryFailure('blocked_invalid_argument', 'missing --project-root');
  if (!['preview', 'confirm', 'apply'].includes(args.command)) {
    throw recoveryFailure('blocked_invalid_command', `unknown command: ${args.command}`);
  }
  if (!args.resumeIntent || !args.resumeIntent.trim()) {
    throw recoveryFailure('blocked_invalid_argument', 'missing --resume-intent');
  }
  if (args.command === 'confirm' && (!args.confirm || !args.previewId)) {
    throw recoveryFailure('blocked_confirmation_required', 'confirm requires --preview-id and --confirm');
  }
  if (args.command === 'apply' && !args.snapshot) {
    throw recoveryFailure('blocked_invalid_argument', 'apply requires --snapshot');
  }
  return args;
}

function recoveryFailure(status, message, extras) {
  const error = new Error(message);
  error.status = status;
  if (extras) Object.assign(error, extras);
  return error;
}

function shellQuote(value) {
  return `'${String(value || '').replace(/'/g, `'\\''`)}'`;
}

// Resolve a project root through realpath while preserving its lexical value
// for prefix containment. `fs.realpathSync` follows the entire chain and
// returns ENOENT if any segment is missing, so we fall back to the lexical
// path when the target does not yet exist (e.g. archive dir before confirm).
function safeRealpath(file) {
  try {
    return fs.realpathSync(file);
  } catch (_) {
    return path.resolve(file);
  }
}

function isSymlink(file) {
  try {
    return fs.lstatSync(file).isSymbolicLink();
  } catch (_) {
    return false;
  }
}

// Reject any ancestor of `target` (or `target` itself) that is a symlink
// pointing outside the project tree. We check only ancestors inside the
// project root; system-level symlinks (e.g. macOS `/tmp` -> `/private/tmp`)
// are not our concern.
function rejectAncestorSymlinks(root, target, label) {
  const projectReal = safeRealpath(root);
  const absoluteTarget = path.resolve(root, target);
  const relative = path.relative(root, absoluteTarget);
  if (!relative || relative.startsWith('..')) {
    // Target is the project root itself or above it; nothing to walk.
    return;
  }
  const segments = relative.split(path.sep).filter(Boolean);
  let cursor = root;
  for (const segment of segments) {
    cursor = path.join(cursor, segment);
    let stat;
    try {
      stat = fs.lstatSync(cursor);
    } catch (_) {
      // Path does not exist yet; nothing to verify until creation time.
      continue;
    }
    if (stat.isSymbolicLink()) {
      const resolved = safeRealpath(cursor);
      if (!resolved.startsWith(projectReal + path.sep) && resolved !== projectReal) {
        throw recoveryFailure(
          'blocked_legacy_task_authority_recovery',
          `${label} contains a symlink escaping the project: ${cursor} -> ${resolved}`,
        );
      }
    }
  }
}

// Confirm that a path lies inside the project root lexically, and that
// none of the relevant ancestors within the project are symlinks escaping
// the project tree. The containment check itself is lexical because the
// caller already built the path with `path.join(root, relativePath)`; the
// symlink walk catches any trickery where a subdirectory of the project
// happens to be a symlink pointing elsewhere.
function requireInside(root, target, label) {
  const absoluteTarget = path.resolve(root, target);
  const relative = path.relative(root, absoluteTarget);
  if (relative && (relative.startsWith('..') || path.isAbsolute(relative))) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `${label} is outside the project: ${target}`,
    );
  }
  rejectAncestorSymlinks(root, absoluteTarget, label);
  if (fs.existsSync(absoluteTarget)) {
    const projectReal = safeRealpath(root);
    const resolved = safeRealpath(absoluteTarget);
    if (resolved !== projectReal && !resolved.startsWith(projectReal + path.sep)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `${label} resolves outside the project: ${resolved}`,
      );
    }
    if (resolved !== absoluteTarget && isSymlink(absoluteTarget)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `${label} is a symlink: ${absoluteTarget} -> ${resolved}`,
      );
    }
    return resolved;
  }
  return absoluteTarget;
}

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function normalizeLegacyTaskAuthority(task) {
  if (!task || typeof task !== 'object' || Array.isArray(task)) {
    return { ok: false, reason: 'current-task.json must be a JSON object' };
  }
  const taskId = String(task.task_id || '');
  if (taskId) {
    if (!TASK_ID_PATTERN.test(taskId)) {
      return { ok: false, reason: `legacy task_id fails safety check: ${JSON.stringify(taskId)}` };
    }
    return {
      ok: true,
      task,
      task_id: taskId,
      task_type: String(task.task_type || ''),
      source_shape: 'task_id',
    };
  }
  if (task.type !== 'outline_backfill') {
    return { ok: false, reason: 'current-task.json has no safe task_id or allowlisted legacy type' };
  }
  const actionId = String(task.action_id || '');
  if (!actionId
      || actionId.length > ACTION_ID_MAX_LENGTH
      || !TASK_ID_PATTERN.test(actionId)) {
    return { ok: false, reason: 'outline_backfill action_id fails safety or length check' };
  }
  const targets = task.target_files;
  if (!Array.isArray(targets) || targets.length === 0) {
    return { ok: false, reason: 'outline_backfill target_files must be a non-empty array' };
  }
  const safeTargets = targets.every((target) => {
    if (typeof target !== 'string' || !target || target.includes('\\') || target.includes(String.fromCharCode(0))) return false;
    if (path.posix.isAbsolute(target) || !target.startsWith('大纲/')) return false;
    if (target.split('/').includes('..')) return false;
    return path.posix.normalize(target) === target;
  });
  if (!safeTargets) {
    return { ok: false, reason: 'outline_backfill target_files contain a non-canonical or unsafe path' };
  }
  const generatedTaskId = `legacy_outline_backfill_${sha256(Buffer.from(actionId, 'utf8')).slice(0, 16)}`;
  const normalizedTask = {
    ...task,
    task_id: generatedTaskId,
    task_type: 'outline_backfill',
  };
  return {
    ok: true,
    task: normalizedTask,
    task_id: generatedTaskId,
    task_type: 'outline_backfill',
    source_shape: 'outline_backfill',
  };
}

// Walk a directory without following symlinks. Files whose ancestors include
// the workflow directory are excluded so recovery state never participates in
// the protected-asset hash ledger.
function walkProtectedFiles(root, baseDir) {
  if (!fs.existsSync(baseDir)) return [];
  const files = [];
  const stack = [baseDir];
  while (stack.length) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch (_) {
      continue;
    }
    for (const entry of entries) {
      const child = path.join(current, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (child.includes(`${path.sep}workflow${path.sep}`)) continue;
        stack.push(child);
      } else if (entry.isFile()) {
        files.push(child);
      }
    }
  }
  return files.sort();
}

function relativePosix(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function computeProtectedHashes(root) {
  const hashes = {};
  for (const relative of PROTECTED_DIRS) {
    const baseDir = path.join(root, relative);
    for (const file of walkProtectedFiles(root, baseDir)) {
      const bytes = fs.readFileSync(file);
      hashes[relativePosix(root, file)] = sha256(bytes);
    }
  }
  return hashes;
}

function equalHashes(a, b) {
  const aKeys = Object.keys(a).sort();
  const bKeys = Object.keys(b).sort();
  if (aKeys.length !== bKeys.length) return false;
  for (let i = 0; i < aKeys.length; i += 1) {
    if (aKeys[i] !== bKeys[i]) return false;
    if (a[aKeys[i]] !== b[bKeys[i]]) return false;
  }
  return true;
}

function loadLegacySource(root) {
  const focusPath = path.join(root, FOCUS_POINTER);
  rejectAncestorSymlinks(root, focusPath, 'current-task pointer');
  if (!fs.existsSync(focusPath)) {
    throw recoveryFailure('blocked_legacy_task_authority_recovery', `missing current task: ${focusPath}`);
  }
  const bytes = fs.readFileSync(focusPath);
  let task;
  try {
    task = JSON.parse(bytes.toString('utf8'));
  } catch (_) {
    throw recoveryFailure('blocked_legacy_task_authority_recovery', 'current-task.json is not valid JSON');
  }
  if (!task || typeof task !== 'object' || Array.isArray(task)) {
    throw recoveryFailure('blocked_legacy_task_authority_recovery', 'current-task.json must be a JSON object');
  }
  if (task.workflow_id) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `current-task.json already carries workflow_id: ${task.workflow_id}`,
    );
  }
  const normalized = normalizeLegacyTaskAuthority(task);
  if (!normalized.ok) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      normalized.reason,
    );
  }
  return { bytes, task: normalized.task, sourcePath: focusPath };
}

function computePreviewId(sourceHash, protectedHashes, intent) {
  const payload = `${sourceHash}\u0000${JSON.stringify(protectedHashes)}\u0000${intent}`;
  return sha256(Buffer.from(payload, 'utf8')).slice(0, PREVIEW_ID_LENGTH);
}

function commandFor(command, args) {
  return `node scripts/legacy-task-authority-recover.js ${command} --project-root . ${args}`;
}

function buildRecoveryOptions(previewId, intent) {
  const quotedIntent = shellQuote(intent);
  const confirmCommand = commandFor(
    'confirm',
    `--preview-id ${previewId} --resume-intent ${quotedIntent} --confirm --json`,
  );
  const previewCommand = commandFor('preview', `--resume-intent ${quotedIntent} --json`);
  return [
    {
      number: 1,
      label: '确认任务权威恢复方案（推荐）',
      description: `仅写入确认快照并保留原意图 ${intent}；下一步再应用恢复。`,
      recommended: true,
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: confirmCommand,
    },
    {
      number: 2,
      label: '仅查看本次预览',
      description: '重新生成本次预览，不写入任何内容。',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: previewCommand,
    },
    {
      number: 3,
      label: '稍后再处理',
      description: '暂不恢复，保留旧任务不变。',
      interaction_mode: 'semantic_only',
    },
    {
      number: 4,
      label: '补充原任务意图',
      description: '调整原任务的目的、范围或目标，重新生成预览。',
      interaction_mode: 'semantic_only',
    },
  ];
}

function renderRecoveryMenuText(options) {
  return options
    .map((option) => {
      const suffix = option.description ? `\n   ${option.description}` : '';
      return `${option.number}. ${option.label}${suffix}`;
    })
    .join('\n');
}

function buildRecoveryVisibleResponse(intent, previewId) {
  const options = buildRecoveryOptions(previewId, intent);
  return {
    render_mode: 'text_numbers',
    status: 'legacy_task_authority_recovery_preview',
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: true,
    intro: '检测到旧任务权威：先完成确认，再应用迁移。',
    options,
    text: renderRecoveryMenuText(options),
  };
}

function runPreview(root, intent) {
  requireInside(root, path.join(root, FOCUS_POINTER), 'current-task pointer');
  const source = loadLegacySource(root);
  const sourceHash = sha256(source.bytes);
  const protectedHashes = computeProtectedHashes(root);
  const previewId = computePreviewId(sourceHash, protectedHashes, intent);
  if (!PREVIEW_ID_PATTERN.test(previewId)) {
    throw recoveryFailure('blocked_legacy_task_authority_recovery', 'computed preview_id failed safety check');
  }
  const scope = extractResumeScope(intent);
  const visible = buildRecoveryVisibleResponse(intent, previewId);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'legacy_task_authority_recovery_preview',
    preview_id: previewId,
    task_id: source.task.task_id,
    task_type: source.task.task_type,
    resume_intent: intent,
    scope,
    source_hash: sourceHash,
    protected_hashes: protectedHashes,
    visible_response: visible,
    read_only: true,
  };
}

function runConfirm(root, args) {
  requireInside(root, path.join(root, FOCUS_POINTER), 'current-task pointer');
  requireInside(root, path.join(root, SNAPSHOT_DIR), 'archive directory');
  const snapshotRelative = `${SNAPSHOT_DIR}/${SNAPSHOT_KIND}-${args.previewId}.json`;
  const snapshotPath = path.join(root, snapshotRelative);
  requireInside(root, snapshotPath, 'snapshot path');
  const applyCommand = commandFor(
    'apply',
    `--snapshot ${shellQuote(snapshotRelative)} --resume-intent ${shellQuote(args.resumeIntent)} --json`,
  );
  // Defect E + Gap 1: when a canonical snapshot for the supplied preview-id
  // already exists, route through the FULL `readRecoverySnapshot` validator
  // (project_root, source_path, embedded base64 hash, schema, kind, status)
  // instead of trusting only kind/id/intent. A forged foreign snapshot at
  // the canonical filename path is rejected outright. For status=confirmed
  // we still demand the current legacy source_hash matches (no drift); for
  // applying/applied we allow source replacement (the focus pointer has
  // been replaced by the successor) but require all other fields to
  // validate. We additionally require resume_intent to match the snapshot's
  // recorded intent: a different intent must require a fresh preview, even
  // if the rest of the snapshot is otherwise valid.
  if (args.previewId && PREVIEW_ID_PATTERN.test(args.previewId) && fs.existsSync(snapshotPath)) {
    let journalStatus = '';
    try {
      journalStatus = String(JSON.parse(fs.readFileSync(snapshotPath, 'utf8')).status || '');
    } catch (_) { /* unreadable fast-path snapshot falls through */ }
    const allowDrift = journalStatus === 'applying' || journalStatus === 'applied';
    // A snapshot at the canonical filename path MUST pass the full
    // validator (project_root, source_path, embedded base64 hash, kind,
    // status, intent). If any field drifts we MUST propagate the error,
    // not swallow it: the slow path would otherwise shallow-accept a
    // foreign snapshot whose only forged field is project_root or
    // source_path (neither participates in expectedId computation).
    const { snapshot: existing } = readRecoverySnapshot(
      root,
      snapshotRelative,
      { allowSourceHashDrift: allowDrift },
    );
    if (String(existing.resume_intent || '') !== String(args.resumeIntent || '')) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        'resume_intent differs from the snapshot; run preview again',
      );
    }
    // Outer status must be semantically consistent with the journal status:
    //   - applied -> recovered/continue (visible must match)
    //   - confirmed -> recovery_confirmed (apply step)
    //   - applying -> confirmed (we re-offer the apply step on a stable state)
    const visible = buildReconfirmVisibleResponse(existing, snapshotPath, root, applyCommand);
    const outerStatus = existing.status === 'applied'
      ? 'legacy_task_authority_recovered'
      : 'legacy_task_authority_recovery_confirmed';
    return {
      schemaVersion: SCHEMA_VERSION,
      status: outerStatus,
      changed: false,
      snapshot_path: snapshotRelative,
      preview_id: args.previewId,
      resume_intent: args.resumeIntent,
      apply_command: applyCommand,
      successor_workflow_id: existing.successor_workflow_id || undefined,
      visible_response: visible,
    };
  }
  const source = loadLegacySource(root);
  const sourceHash = sha256(source.bytes);
  const protectedHashes = computeProtectedHashes(root);
  const expectedId = computePreviewId(sourceHash, protectedHashes, args.resumeIntent);
  if (!args.previewId || args.previewId !== expectedId) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'preview_id does not match current source/intent/protected hashes; run preview again',
    );
  }
  if (fs.existsSync(snapshotPath)) {
    const existingRaw = fs.readFileSync(snapshotPath);
    const existing = JSON.parse(existingRaw.toString('utf8'));
    if (existing.preview_id !== expectedId || existing.source_hash !== sourceHash || existing.resume_intent !== args.resumeIntent) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        'recovery snapshot already exists with different content; refuse to overwrite',
      );
    }
    // Idempotent re-confirm: emit a distinct apply visible_response so the
    // user sees the next concrete step (apply), not another confirm prompt
    // that would loop them. The apply command is anchored to the same
    // canonical snapshot and intent.
    const visible = buildReconfirmVisibleResponse(existing, snapshotPath, root, applyCommand);
    const outerStatus = existing.status === 'applied'
      ? 'legacy_task_authority_recovered'
      : 'legacy_task_authority_recovery_confirmed';
    return {
      schemaVersion: SCHEMA_VERSION,
      status: outerStatus,
      changed: false,
      snapshot_path: snapshotRelative,
      preview_id: expectedId,
      resume_intent: args.resumeIntent,
      apply_command: applyCommand,
      successor_workflow_id: existing.successor_workflow_id || undefined,
      visible_response: visible,
    };
  }
  const snapshot = {
    schemaVersion: SCHEMA_VERSION,
    kind: 'legacy_task_authority_recovery',
    preview_id: expectedId,
    confirmed: true,
    status: 'confirmed',
    project_root: path.resolve(root),
    confirmed_at: new Date().toISOString(),
    resume_intent: args.resumeIntent,
    scope: extractResumeScope(args.resumeIntent),
    source_task_id: source.task.task_id,
    source_task_type: source.task.task_type,
    source_path: relativePosix(root, source.sourcePath),
    source_hash: sourceHash,
    protected_hashes: protectedHashes,
    source_bytes_base64: source.bytes.toString('base64'),
  };
  atomicWriteJson(snapshotPath, snapshot);
  // Defect D: use the same unified apply-step builder for first-confirm so
  // visible_response.text is built FROM options[0] (which carries the apply
  // label/command), never stale.
  const visible = buildReconfirmVisibleResponse(snapshot, snapshotPath, root, applyCommand);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'legacy_task_authority_recovery_confirmed',
    changed: true,
    snapshot_path: snapshotRelative,
    preview_id: expectedId,
    resume_intent: args.resumeIntent,
    apply_command: applyCommand,
    visible_response: visible,
  };
}

// Idempotent-confirm visible response: option 1 carries the apply command
// anchored to the canonical snapshot and intent, so the user always sees the
// next concrete step instead of another confirm prompt that would loop them.
// Unified for both first and repeated confirm so the rendered text is always
// consistent with options[0] (defect D).
//
// Gap 1: when the journal is already status=applied, the visible response
// MUST reflect recovered/continue (not confirmed), so a user re-running the
// original confirm command after apply sees the next concrete step on the
// successor (option 1 = workflow-entry-guard continuation) rather than
// another confirm/apply that would loop them. We delegate to
// buildApplyVisibleResponse for the applied branch because it already emits
// the correct recovered/continue text + continuation command.
function buildReconfirmVisibleResponse(snapshot, snapshotPath, root, applyCommand) {
  const journalStatus = String(snapshot.status || '');
  if (journalStatus === 'applied') {
    const durable = {
      workflow_id: String(snapshot.successor_workflow_id || ''),
      workflow_type: WORKFLOW_TYPE,
      user_goal: String(snapshot.resume_intent || ''),
      task_dir: String(snapshot.successor_task_dir || ''),
    };
    return buildApplyVisibleResponse(durable, snapshot, snapshotPath, root);
  }
  return buildConfirmedApplyVisibleResponse(snapshot, snapshotPath, root, applyCommand);
}

function buildConfirmedApplyVisibleResponse(snapshot, snapshotPath, root, applyCommand) {
  const resumeIntent = String(snapshot.resume_intent || '');
  const snapshotRelative = relativePosix(root, snapshotPath);
  const options = [
    {
      number: 1,
      label: '应用已确认的任务权威恢复（推荐）',
      description: `对快照 ${snapshotRelative} 应用意图 ${resumeIntent} 的恢复。`,
      recommended: true,
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: applyCommand,
    },
    {
      number: 2,
      label: '仅查看本次预览',
      description: '重新生成本次预览，不写入任何内容。',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: `node scripts/legacy-task-authority-recover.js preview --project-root . --resume-intent ${shellQuote(resumeIntent)} --json`,
    },
    {
      number: 3,
      label: '查看本次恢复快照',
      description: `只读查看 ${snapshotRelative}。`,
      interaction_mode: 'informational',
    },
    {
      number: 4,
      label: '暂停并保留断点',
      description: '暂不应用，保留已确认的快照和焦点。',
      interaction_mode: 'semantic_only',
    },
  ];
  return {
    render_mode: 'text_numbers',
    status: 'legacy_task_authority_recovery_confirmed',
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: true,
    intro: '快照已确认：直接进入应用阶段，无需再次确认。',
    options,
    text: options.map((option) => {
      const suffix = option.description ? `\n   ${option.description}` : '';
      return `${option.number}. ${option.label}${suffix}`;
    }).join('\n'),
    interaction_contract: 'render_visible_response_text_verbatim',
    apply_command: applyCommand,
  };
}

function readRecoverySnapshot(root, snapshotRelative, { allowSourceHashDrift = false } = {}) {
  if (!snapshotRelative) {
    throw recoveryFailure('blocked_invalid_argument', 'snapshot path is required');
  }
  // Restrict the snapshot path to the canonical archived location and
  // filename shape: 追踪/workflow/archived/legacy-recovery-<safe preview id>.json.
  // A bare '..' walk or any other relative location is rejected without
  // ever opening the file. requireInside then catches remaining symlink
  // escapes for the canonical path.
  const normalized = String(snapshotRelative).replace(/\\/g, '/');
  const prefix = `${SNAPSHOT_DIR}/${SNAPSHOT_KIND}-`;
  if (!normalized.startsWith(prefix) || !normalized.endsWith('.json')) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot must live under ${prefix}<preview_id>.json; got ${snapshotRelative}`,
    );
  }
  const filename = normalized.slice(prefix.length, -'.json'.length);
  if (!PREVIEW_ID_PATTERN.test(filename)) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot filename preview_id is unsafe: ${filename}`,
    );
  }
  const snapshotPath = path.resolve(root, normalized);
  requireInside(root, snapshotPath, 'snapshot path');
  if (!fs.existsSync(snapshotPath)) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot not found: ${snapshotRelative}`,
    );
  }
  const raw = fs.readFileSync(snapshotPath);
  let snapshot;
  try {
    snapshot = JSON.parse(raw.toString('utf8'));
  } catch (_) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot is not valid JSON: ${snapshotRelative}`,
    );
  }
  if (!snapshot
      || snapshot.kind !== 'legacy_task_authority_recovery'
      || !snapshot.confirmed
      || String(snapshot.preview_id || '') !== filename
      || !['confirmed', 'applying', 'applied'].includes(String(snapshot.status || ''))) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot is missing confirmation metadata: ${snapshotRelative}`,
    );
  }
  const expectedScope = extractResumeScope(snapshot.resume_intent);
  if (snapshot.scope !== undefined && String(snapshot.scope) !== expectedScope) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot scope mismatch: expected ${JSON.stringify(expectedScope)}, got ${JSON.stringify(snapshot.scope || '')}`,
    );
  }
  // Snapshots created before scope persistence are upgraded in memory from
  // their already-confirmed resume_intent. The durable file is not rewritten.
  snapshot.scope = expectedScope;
  // Project-root identity must match the current invocation; foreign
  // snapshots from another project are rejected outright.
  const expectedRoot = path.resolve(root);
  if (String(snapshot.project_root || '') !== expectedRoot) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot project_root mismatch: expected ${expectedRoot}, got ${snapshot.project_root || '<missing>'}`,
    );
  }
  // Source path must be exactly the focus pointer; refusing drift here
  // blocks re-use of a snapshot against an unrelated current-task.json.
  const expectedSourcePath = relativePosix(root, path.join(root, FOCUS_POINTER));
  if (String(snapshot.source_path || '') !== expectedSourcePath) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot source_path mismatch: expected ${expectedSourcePath}, got ${snapshot.source_path || '<missing>'}`,
    );
  }
  if (String(snapshot.resume_intent || '') === '') {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'recovery snapshot is missing resume_intent',
    );
  }
  // Gap 5: source_bytes_base64 is now REQUIRED for newly-created recovery
  // snapshots. Without the embedded bytes, a crash between legacy pointer
  // removal and archive materialization cannot be recovered, so refusing
  // upfront keeps the recovery story deterministic.
  if (typeof snapshot.source_bytes_base64 !== 'string' || snapshot.source_bytes_base64.length === 0) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'recovery snapshot is missing embedded source_bytes_base64; crash recovery requires the verified bytes',
    );
  }
  // Defect F: verify the embedded bytes sha256 equals the recorded source_hash.
  // A forged or rotated base64 payload must be rejected on read so crash
  // recovery cannot be tricked into materializing a fabricated archive.
  const embedded = Buffer.from(snapshot.source_bytes_base64, 'base64');
  const embeddedHash = sha256(embedded);
  if (String(snapshot.source_hash || '') === '' || embeddedHash !== String(snapshot.source_hash)) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery snapshot source_bytes_base64 sha256 mismatch: expected ${snapshot.source_hash}, got ${embeddedHash}`,
    );
  }
  // Source hash drift is only checked on the initial apply path. On
  // reapply the focus pointer has already replaced the legacy file, so
  // byte-identity is impossible; the snapshot itself + the bound
  // successor carry enough authority for the reapply decision.
  if (!allowSourceHashDrift) {
    const sourcePath = path.join(root, snapshot.source_path);
    if (!fs.existsSync(sourcePath)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `recovery snapshot source_path no longer exists: ${snapshot.source_path}`,
      );
    }
    const currentSourceBytes = fs.readFileSync(sourcePath);
    if (sha256(currentSourceBytes) !== String(snapshot.source_hash || '')) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        'recovery snapshot source_hash drifted; refuse to apply',
      );
    }
  }
  return { snapshot, snapshotPath };
}

function archiveFileFor(sourceTaskId) {
  if (!TASK_ID_PATTERN.test(String(sourceTaskId || ''))) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `legacy task_id fails safety check: ${JSON.stringify(sourceTaskId)}`,
    );
  }
  return `${SNAPSHOT_DIR}/${sourceTaskId}.current-task.json`;
}

function callStateMachineCreate(root, intent, scope) {
  if (process.env.NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL === 'successor_create') {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'successor_create failure injected via NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL',
    );
  }
  const scopeArg = String(scope || SCOPE_UNSPECIFIED);
  const args = [
    path.join(__dirname, 'workflow-state-machine.js'),
    'create',
    '--workflow-type', WORKFLOW_TYPE,
    '--project-root', root,
    '--scope', scopeArg,
    '--user-goal', intent,
    '--reason', 'legacy_task_authority_recovery',
    '--json',
  ];
  const result = cp.spawnSync(process.execPath, args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (result.error) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `state machine spawn failed: ${result.error.message}`,
    );
  }
  let parsed;
  try {
    parsed = JSON.parse(result.stdout || '{}');
  } catch (_) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `state machine returned unparseable output: ${String(result.stdout || '').slice(0, 200)}`,
    );
  }
  if (result.status !== 0 || String(parsed.status || '').startsWith('blocked_')) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `state machine create failed: ${parsed.status || 'unknown'} ${parsed.message || parsed.reason || ''}`.trim(),
    );
  }
  const successor = (parsed.task && typeof parsed.task === 'object') ? parsed.task : null;
  if (!successor || !successor.workflow_id || !successor.task_dir) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'state machine create did not return a successor workflow_id/task_dir',
    );
  }
  if (String(successor.workflow_type || '') !== WORKFLOW_TYPE) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `state machine create returned unexpected workflow_type: ${successor.workflow_type}`,
    );
  }
  if (String(successor.user_goal || '') !== intent) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `state machine create returned mismatched user_goal: ${JSON.stringify(successor.user_goal)}`,
    );
  }
  if (String(successor.scope || '') !== scopeArg) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `state machine create returned mismatched scope: expected ${JSON.stringify(scopeArg)}, got ${JSON.stringify(successor.scope)}`,
    );
  }
  if (String(((successor.lifecycle || {}).switch_reason) || '') !== 'legacy_task_authority_recovery') {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'state machine create did not preserve the legacy recovery origin marker',
    );
  }
  return { result: parsed, successor };
}

// Defect A: surface post-create verification failures as a precise status that
// `runApply` MUST treat as terminal. The injection knob covers the
// resolveTaskAuthority and focus-pointer verification steps so a focused test
// can assert control-flow; production callers never set the environment.
function checkPostCreateAuthority(root, successor) {
  if (process.env.NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL === 'successor_authority') {
    return {
      status: 'blocked_task_authority_missing',
      task: null,
      message: 'successor_authority failure injected via NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL',
    };
  }
  return resolveTaskAuthority(root, successor.workflow_id);
}

function checkPostCreatePointer(root, successor, focused) {
  if (process.env.NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL === 'successor_pointer') {
    return {
      pointer: null,
      authority: { status: 'blocked_task_authority_missing', task: null, message: 'successor_pointer failure injected via NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL' },
      pointer_status: 'missing',
    };
  }
  return focused;
}

function revalidateSnapshot(root, snapshot) {
  if (String(snapshot.resume_intent || '') === '') {
    throw recoveryFailure('blocked_legacy_task_authority_recovery', 'snapshot is missing resume_intent');
  }
  const sourcePath = path.join(root, snapshot.source_path);
  requireInside(root, sourcePath, 'snapshot source path');
  if (!fs.existsSync(sourcePath)) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'source file from snapshot is missing; refuse to mutate',
    );
  }
  const currentBytes = fs.readFileSync(sourcePath);
  const currentHash = sha256(currentBytes);
  if (currentHash !== snapshot.source_hash) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'current-task.json drifted after confirmation (source hash mismatch)',
    );
  }
  const currentProtected = computeProtectedHashes(root);
  if (!equalHashes(currentProtected, snapshot.protected_hashes || {})) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'protected creative/planning asset drift detected since confirmation',
    );
  }
  return { sourcePath, currentBytes };
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(temp, file);
}

// Atomic archive write: stage to a same-directory temp file, fsync via
// writeFileSync, then rename into place so concurrent readers never see a
// partial archive. Conflict-aware: if the archive already exists with
// different bytes, refuse without mutation. Any temp file is removed on
// failure so a failed write can never leave a partial archive on disk.
//
// Optional injection hook: NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL=archive_write
// forces the write step to throw so tests can prove the temp file is
// cleaned up and the canonical archive is never left half-written.
function archiveOriginalBytes(archivePath, bytes) {
  // archivePath is absolute; its parent is always the project's archive dir
  // because we constructed it from `path.join(root, archiveRelative)` after
  // the caller already validated `archiveRelative` is inside the project.
  const archiveDir = path.dirname(archivePath);
  fs.mkdirSync(archiveDir, { recursive: true });
  if (fs.existsSync(archivePath)) {
    const existing = fs.readFileSync(archivePath);
    if (!existing.equals(bytes)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `archive entry already exists with different bytes: ${archivePath}`,
      );
    }
    return { written: false };
  }
  const tempPath = `${archivePath}.tmp-${process.pid}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  try {
    if (process.env.NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL === 'archive_write') {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        'archive_write failure injected via NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL',
      );
    }
    // Write the bytes to the temp file first; rename is atomic on the same
    // filesystem, so concurrent readers only ever see the previous version
    // (or the new one) — never a half-written archive.
    fs.writeFileSync(tempPath, bytes);
    fs.renameSync(tempPath, archivePath);
  } catch (error) {
    // Clean up the temp file so a failed write never leaves a stray
    // .tmp-* sibling next to the canonical archive.
    try { fs.rmSync(tempPath, { force: true }); } catch (_) { /* ignore */ }
    if (fs.existsSync(tempPath)) {
      try { fs.rmSync(tempPath, { force: true }); } catch (_) { /* ignore */ }
    }
    throw error;
  }
  return { written: true };
}

function acquireRecoveryLock(root) {
  // Defect H: serialize concurrent apply invocations on the same project.
  // We reuse the existing acquireNamedProjectLock primitive (which provides
  // EEXIST contention + stale-owner reclaim semantics) instead of inventing
  // a new lock, so behavior stays uniform with the rest of the runtime.
  return acquireNamedProjectLock(root, {
    relativeDir: path.join('追踪', 'workflow'),
    lockName: RECOVERY_LOCK_NAME,
    owner: RECOVERY_LOCK_OWNER,
    ttlMs: RECOVERY_LOCK_TTL_MS,
    errorCode: 'LEGACY_RECOVERY_LOCKED',
    errorLabel: 'legacy recovery lock',
  });
}

function runApply(root, args) {
  requireInside(root, path.join(root, FOCUS_POINTER), 'focus pointer');
  requireInside(root, path.join(root, TASKS_DIR), 'task directory');
  requireInside(root, path.join(root, SNAPSHOT_DIR), 'archive directory');
  // Defect H: serialize concurrent apply invocations. The lock is held
  // across the entire apply (including child state-machine create) so two
  // applies cannot both call create and produce two successors.
  const releaseLock = acquireRecoveryLock(root);
  try {
    return runApplyLocked(root, args);
  } finally {
    releaseLock();
  }
}

function runApplyLocked(root, args) {
  const focusPath = path.join(root, FOCUS_POINTER);
  // Detect reapply BEFORE re-parsing the snapshot so the source-hash
  // drift check (which is impossible after the first apply replaced the
  // legacy file with the new focus pointer) can be relaxed for that path.
  const focused = readFocusedTask(root);
  const pointer = focused.pointer;
  const reapply = Boolean(pointer && pointer.workflow_id);
  // For a journal status=applying, the legacy focus pointer has already
  // been removed by the in-flight apply, so the source_path existence
  // check inside readRecoverySnapshot must be relaxed. We still validate
  // project_root, source_path lexical shape, embedded base64 hash, kind,
  // status, intent; we just do not insist on the legacy file being there.
  let snapshotStatusPeek = '';
  try {
    const peekRaw = fs.readFileSync(path.join(root, args.snapshot), 'utf8');
    snapshotStatusPeek = String(JSON.parse(peekRaw).status || '');
  } catch (_) { /* fall through to default below */ }
  const allowSourceHashDrift = reapply
    || snapshotStatusPeek === 'applying'
    || snapshotStatusPeek === 'applied';
  const { snapshot, snapshotPath } = readRecoverySnapshot(
    root,
    args.snapshot,
    { allowSourceHashDrift },
  );
  if (String(snapshot.resume_intent || '') !== String(args.resumeIntent || '')) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'resume_intent differs from the confirmed snapshot; run preview again',
    );
  }
  const expectedScope = extractResumeScope(args.resumeIntent);
  if (String(snapshot.scope || '') !== expectedScope) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `snapshot scope differs from the confirmed resume_intent: expected ${JSON.stringify(expectedScope)}, got ${JSON.stringify(snapshot.scope || '')}`,
    );
  }
  // Gap 3: crash window detection. Snapshot status=applying AND NO focus
  // pointer means the previous apply process crashed AFTER removing the
  // legacy focus pointer but BEFORE the state machine's create() returned.
  // Two sub-cases:
  //   (a) NO successor_candidate_workflow_id recorded -> crash occurred
  //       before any successor was even attempted. Recovery restores the
  //       legacy pointer atomically from the verified embedded bytes,
  //       clears any leftover .legacy-recovery-backup, and reverts the
  //       journal to confirmed with truthful interrupted metadata. It
  //       MUST NOT create or guess a successor.
  //   (b) A successor_candidate_workflow_id IS recorded -> the candidate
  //       may already exist on disk; restoring the legacy pointer over
  //       it would be wrong. We fail closed with candidate-specific
  //       diagnostics so the operator can inspect before continuing.
  if (snapshot.status === 'applying' && !pointer) {
    if (snapshot.successor_candidate_workflow_id) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `applying snapshot records candidate ${snapshot.successor_candidate_workflow_id} but the focus pointer is missing; cannot restore legacy pointer over a possibly-created successor. Inspect 追踪/workflow/tasks/${snapshot.successor_candidate_workflow_id} before retrying.`,
      );
    }
    return runCrashRecovery(root, snapshot, snapshotPath, args);
  }
  if (reapply) {
    // Use the official focus authority: a stale or malformed pointer must
    // never be trusted just because its task.json exists at the expected path.
    return runReapply(root, snapshot, snapshotPath, pointer);
  }
  const { currentBytes } = revalidateSnapshot(root, snapshot);
  // Preflight archive conflict BEFORE deleting the focus pointer or
  // creating any successor: the recovery archive is a one-shot durable
  // record, and an existing foreign entry means a different recovery was
  // already in flight on this same source_task_id. Refuse without mutation.
  const archiveRelative = archiveFileFor(snapshot.source_task_id);
  const archivePath = path.join(root, archiveRelative);
  requireInside(root, archivePath, 'archive entry');
  if (fs.existsSync(archivePath)) {
    const existingArchive = fs.readFileSync(archivePath);
    if (!existingArchive.equals(currentBytes)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `archive entry already exists with different bytes: ${archivePath}`,
      );
    }
  }
  // Atomically mark the journal as applying with enough baseline data to
  // tell new tasks from preexisting ones; recovery from a crash can then
  // distinguish the snapshot-bound successor from a same-goal lookalike.
  const preexistingTaskIds = listPreexistingTaskIds(root);
  const applyingSnapshot = {
    ...snapshot,
    status: 'applying',
    applying_started_at: new Date().toISOString(),
    preexisting_workflow_ids: preexistingTaskIds,
  };
  atomicWriteJson(snapshotPath, applyingSnapshot);
  // The legacy focus pointer must be moved aside so the state machine's
  // readFocusedAuthority does not see a workflow_id-less pointer and reject.
  // We back up the original bytes and restore them verbatim if create fails.
  const backupPath = `${focusPath}.legacy-recovery-backup`;
  fs.writeFileSync(backupPath, currentBytes);
  fs.rmSync(focusPath, { force: true });
  let createOutcome;
  try {
    createOutcome = callStateMachineCreate(root, snapshot.resume_intent, snapshot.scope);
  } catch (error) {
    // Restore the original focus pointer so the legacy file is byte-identical.
    if (fs.existsSync(backupPath)) {
      fs.writeFileSync(focusPath, fs.readFileSync(backupPath));
      fs.rmSync(backupPath, { force: true });
    }
    // The state machine failed BEFORE creating a successor, so we revert the
    // journal to confirmed with truthful failure metadata. Subsequent applies
    // can re-attempt with the same canonical snapshot.
    revertJournalToConfirmed(snapshotPath, applyingSnapshot, error);
    throw error;
  }
  fs.rmSync(backupPath, { force: true });
  const successor = createOutcome.successor;
  // Persist the candidate binding immediately (before any verification step)
  // so crash recovery can recover THE EXACT created workflow id. We do not
  // know ahead of time which id create will mint; only after it returns
  // can we record the candidate.
  const candidateSnapshot = {
    ...applyingSnapshot,
    successor_candidate_workflow_id: successor.workflow_id,
    successor_candidate_task_dir: successor.task_dir,
    successor_candidate_user_goal: String(successor.user_goal || ''),
  };
  atomicWriteJson(snapshotPath, candidateSnapshot);
  // Defect A: post-create verification must TERMINATE the apply on failure.
  // Surface the error to the caller AND keep the journal in applying state
  // with truthful failure metadata; never silently continue.
  let authority = checkPostCreateAuthority(root, successor);
  if (authority.status !== 'ok') {
    recordApplyFailure(snapshotPath, candidateSnapshot, authority,
      `state machine create succeeded but official task authority is unavailable: ${successor.workflow_id}`);
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `state machine create succeeded but official task authority is unavailable: ${successor.workflow_id} (${authority.message || authority.status})`,
    );
  }
  const durable = authority.task;
  archiveOriginalBytes(archivePath, currentBytes);
  // Re-read the focus pointer through official authority: the state
  // machine's writeFocusPointer is the canonical writer, so we trust the
  // pointer it produced only when readFocusedTask agrees.
  let postFocused = checkPostCreatePointer(root, successor, readFocusedTask(root));
  const verifiedPointer = postFocused.pointer;
  if (!verifiedPointer
      || String(verifiedPointer.workflow_id || '') !== String(successor.workflow_id)
      || postFocused.authority.status !== 'ok'
      || String(postFocused.authority.task.workflow_id || '') !== String(successor.workflow_id)) {
    recordApplyFailure(snapshotPath, candidateSnapshot, null,
      `post-create focus pointer does not resolve through official authority: ${successor.workflow_id}`);
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `post-create focus pointer does not resolve through official authority: ${successor.workflow_id} (${postFocused.authority && (postFocused.authority.message || postFocused.authority.status)})`,
    );
  }
  // Persist the applied transition atomically: bind the exact successor,
  // the archive path and its sha256, so a crash-recovered reapply can
  // never claim a different same-goal task as the recovered successor.
  const finalSnapshot = {
    ...candidateSnapshot,
    status: 'applied',
    successor_workflow_id: successor.workflow_id,
    successor_task_dir: successor.task_dir,
    archive_path: archiveRelative,
    archive_sha256: sha256(currentBytes),
    applied_at: new Date().toISOString(),
  };
  atomicWriteJson(snapshotPath, finalSnapshot);
  return buildApplyResult(root, durable, verifiedPointer, finalSnapshot, snapshotPath);
}

// Defect B: after the state machine has created a successor, we MUST NOT
// silently revert the journal to confirmed. A canonical successor may
// already exist on disk; the next apply must know it is in a recovery
// state and verify the candidate binding rather than rebuilding from
// scratch. Surface the failure to the caller; never label this as applied.
function recordApplyFailure(snapshotPath, candidateSnapshot, authority, message) {
  const reason = (authority && authority.message) ? `${message}: ${authority.message}` : String(message || 'unknown');
  const recorded = {
    ...candidateSnapshot,
    status: 'applying',
    pending_recovery: true,
    last_apply_error: reason,
    last_apply_failed_at: new Date().toISOString(),
  };
  atomicWriteJson(snapshotPath, recorded);
}

// Revert the journal to confirmed only when no successor was created
// (state machine create threw). Once the state machine has materialized
// a successor, use recordApplyFailure instead.
function revertJournalToConfirmed(snapshotPath, applyingSnapshot, reasonError) {
  const reason = (reasonError && reasonError.message) ? reasonError.message : String(reasonError || 'unknown');
  const reverted = {
    ...applyingSnapshot,
    status: 'confirmed',
    last_apply_error: reason,
    last_apply_failed_at: new Date().toISOString(),
  };
  delete reverted.applying_started_at;
  delete reverted.successor_candidate_workflow_id;
  delete reverted.successor_candidate_task_dir;
  delete reverted.successor_candidate_user_goal;
  try {
    atomicWriteJson(snapshotPath, reverted);
  } catch (_) {
    // Best-effort: the snapshot is durable state we cannot rewrite, but
    // the original failure is still surfaced to the caller.
  }
}

function listPreexistingTaskIds(root) {
  const tasksRoot = path.join(root, TASKS_DIR);
  if (!fs.existsSync(tasksRoot)) return [];
  return fs.readdirSync(tasksRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .filter((name) => WORKFLOW_ID_RE.test(name))
    .sort();
}

// Gap 3: crash recovery path. Triggered when the journal is status=applying,
// the focus pointer is gone, and no successor_candidate_workflow_id is
// recorded. The previous apply process crashed after deleting the legacy
// pointer but before the state machine's create() returned. We restore the
// legacy pointer atomically from the verified embedded source bytes,
// validate/clear the .legacy-recovery-backup sibling, and revert the
// journal to confirmed with truthful interrupted metadata. We do NOT call
// the state machine and we do NOT guess a successor id.
function runCrashRecovery(root, snapshot, snapshotPath, args) {
  const focusPath = path.join(root, FOCUS_POINTER);
  const backupPath = `${focusPath}.legacy-recovery-backup`;
  requireInside(root, focusPath, 'focus pointer');
  requireInside(root, backupPath, 'recovery backup');
  // Embedded bytes are guaranteed by readRecoverySnapshot (Gap 5) to be
  // present and to hash to snapshot.source_hash. Restore them byte-exact
  // using the same atomic temp+rename pattern as archive writes so a
  // concurrent reader never sees a partial pointer.
  const embedded = Buffer.from(String(snapshot.source_bytes_base64 || ''), 'base64');
  if (sha256(embedded) !== String(snapshot.source_hash || '')) {
    // Defensive: readRecoverySnapshot already rejected this, but never
    // trust that upstream check stays intact across refactors.
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      'crash recovery: embedded source bytes no longer match snapshot.source_hash',
    );
  }
  // Validate the .legacy-recovery-backup BEFORE writing the focus pointer.
  // A mismatched backup means a foreign recovery was racing on this same
  // project; we must not silently overwrite that signal after restoring
  // the focus pointer (which would leave the racing recovery with no
  // pointer to roll back to).
  if (fs.existsSync(backupPath)) {
    const backupBytes = fs.readFileSync(backupPath);
    if (!backupBytes.equals(embedded)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `crash recovery: ${backupPath} does not match the verified embedded bytes; refusing to overwrite without inspection`,
      );
    }
  }
  // Inventory drift guard: if the current task inventory contains a
  // workflow id that was NOT recorded in snapshot.preexisting_workflow_ids
  // (and the snapshot has no successor_candidate_workflow_id), child
  // create() may have succeeded on disk. Restoring the legacy pointer
  // over that task would corrupt the workflow state, so we fail closed
  // before any mutation. We compare the set, not exact equality, because
  // preexisting tasks may legitimately persist across the crash.
  const inventory = listPreexistingTaskIds(root);
  const preexisting = Array.isArray(snapshot.preexisting_workflow_ids)
    ? snapshot.preexisting_workflow_ids.map(String)
    : [];
  const newcomers = inventory.filter((id) => !preexisting.includes(id));
  if (newcomers.length > 0) {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `crash recovery: new workflow task(s) appeared on disk (${newcomers.join(', ')}) that were not in snapshot.preexisting_workflow_ids; child create() may have succeeded — refuse to restore the legacy focus pointer without inspection`,
    );
  }
  fs.mkdirSync(path.dirname(focusPath), { recursive: true });
  const tempPath = `${focusPath}.tmp-${process.pid}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  try {
    fs.writeFileSync(tempPath, embedded);
    fs.renameSync(tempPath, focusPath);
  } catch (error) {
    try { fs.rmSync(tempPath, { force: true }); } catch (_) { /* ignore */ }
    throw error;
  }
  // Cleanup: now that the focus pointer is restored, drop a matching
  // backup. The mismatch case was already handled above before any
  // mutation, so it is safe to remove the file here.
  if (fs.existsSync(backupPath)) {
    fs.rmSync(backupPath, { force: true });
  }
  // Revert the journal to confirmed with truthful interrupted metadata.
  // We deliberately do NOT preserve successor_candidate_workflow_id
  // (there was none) but DO record the interruption so future applies
  // can see the crash context if needed.
  const reverted = {
    ...snapshot,
    status: 'confirmed',
    last_apply_error: 'apply was interrupted before child create returned; legacy pointer restored from embedded snapshot bytes',
    last_apply_failed_at: new Date().toISOString(),
  };
  delete reverted.applying_started_at;
  delete reverted.successor_candidate_workflow_id;
  delete reverted.successor_candidate_task_dir;
  delete reverted.successor_candidate_user_goal;
  delete reverted.pending_recovery;
  try {
    atomicWriteJson(snapshotPath, reverted);
  } catch (_) { /* best-effort; the journal is durable */ }
  // Surface a precise retry/apply continuation under the same lock so the
  // user can re-run the recovery cleanly. We DO NOT mark the journal
  // applied and we DO NOT create a successor; that is the user's next
  // explicit apply invocation.
  const snapshotRelative = relativePosix(root, snapshotPath);
  const applyCommand = commandFor(
    'apply',
    `--snapshot ${shellQuote(snapshotRelative)} --resume-intent ${shellQuote(args.resumeIntent)} --json`,
  );
  const continuation = `node scripts/workflow-entry-guard.js --project-root . --user-intent ${shellQuote(snapshot.resume_intent)} --write --compact --json`;
  const visible = {
    render_mode: 'text_numbers',
    status: 'legacy_task_authority_recovery_confirmed',
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: true,
    intro: '检测到上一次恢复被中断：旧任务权威已原子还原，请重新执行应用步骤。',
    options: [
      {
        number: 1,
        label: '重新应用任务权威恢复（推荐）',
        description: `使用原意图 ${snapshot.resume_intent} 重新创建后续 long_write 任务。`,
        recommended: true,
        interaction_mode: 'execute_command',
        execution_workdir: '.',
        execution_command: applyCommand,
      },
      {
        number: 2,
        label: '继续执行任务权威恢复',
        description: '跳过应用阶段，直接进入任务入口。',
        interaction_mode: 'execute_command',
        execution_workdir: '.',
        execution_command: continuation,
      },
      {
        number: 3,
        label: '查看本次恢复快照',
        description: `只读查看 ${snapshotRelative}。`,
        interaction_mode: 'informational',
      },
      {
        number: 4,
        label: '暂停并保留断点',
        description: '暂不继续任务，保留旧任务为焦点。',
        interaction_mode: 'semantic_only',
      },
    ],
    text: [
      '1. 重新应用任务权威恢复（推荐）',
      `   使用原意图 ${snapshot.resume_intent} 重新创建后续 long_write 任务。`,
      '2. 继续执行任务权威恢复',
      '   跳过应用阶段，直接进入任务入口。',
      `3. 查看本次恢复快照`,
      `   只读查看 ${snapshotRelative}。`,
      '4. 暂停并保留断点',
      '   暂不继续任务，保留旧任务为焦点。',
    ].join('\n'),
    interaction_contract: 'render_visible_response_text_verbatim',
    apply_command: applyCommand,
    continuation_command: continuation,
  };
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'legacy_task_authority_recovery_confirmed',
    changed: true,
    snapshot_path: snapshotRelative,
    preview_id: snapshot.preview_id,
    resume_intent: snapshot.resume_intent,
    apply_command: applyCommand,
    interruption_recovered: true,
    interruption_message: 'previous apply was interrupted; legacy pointer restored from verified embedded bytes',
    visible_response: visible,
  };
}

function runReapply(root, snapshot, snapshotPath, pointer) {
  const pointerId = String(pointer.workflow_id || '');
  const snapshotStatus = String(snapshot.status || '');
  const snapshotBound = String(snapshot.successor_workflow_id || '');
  // Defect C: a confirmed snapshot may NEVER infer ownership from a current
  // pointer. We accept the pointer only when:
  //   (a) status=applied with snapshotBound that exactly matches the pointer, OR
  //   (b) status=applying with a recorded successor_candidate_workflow_id
  //       that exactly matches the pointer, the candidate was NOT in
  //       preexisting_workflow_ids, officially resolves, workflow_type is
  //       long_write, and user_goal equals snapshot.resume_intent.
  // In every other case the recovery fails closed.
  if (snapshotStatus === 'applied') {
    if (!snapshotBound) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        'applied snapshot is missing a bound successor_workflow_id; refuse to relabel',
      );
    }
    if (snapshotBound !== pointerId) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `focus pointer references ${pointerId} but snapshot is bound to successor ${snapshotBound}; refuse to relabel`,
      );
    }
  } else if (snapshotStatus === 'applying') {
    const candidate = String(snapshot.successor_candidate_workflow_id || '');
    if (!candidate) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        'applying snapshot is missing successor_candidate_workflow_id; recovery cannot guess ownership from a current pointer',
      );
    }
    if (candidate !== pointerId) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `focus pointer references ${pointerId} but applying snapshot records candidate ${candidate}; refuse to relabel`,
      );
    }
    const preexisting = Array.isArray(snapshot.preexisting_workflow_ids)
      ? snapshot.preexisting_workflow_ids.map(String)
      : [];
    if (preexisting.includes(candidate)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `successor candidate ${candidate} was already a preexisting task at confirm time; refuse to rebound`,
      );
    }
    // The official authority + workflow_type + user_goal verification is the
    // last gate so a same-goal but unrelated long_write task can never be
    // rebound as the recovered successor.
    const authority = resolveTaskAuthority(root, pointerId);
    if (authority.status !== 'ok') {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `successor candidate ${pointerId} does not resolve through official task authority (${authority.message || authority.status})`,
      );
    }
    const durable = authority.task;
    if (String(durable.workflow_type || '') !== WORKFLOW_TYPE) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `bound successor workflow_type mismatch: expected ${WORKFLOW_TYPE}, got ${durable.workflow_type}`,
      );
    }
    if (String(durable.user_goal || '') !== String(snapshot.resume_intent || '')) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `bound successor user_goal ${JSON.stringify(durable.user_goal)} does not match snapshot resume_intent ${JSON.stringify(snapshot.resume_intent)}`,
      );
    }
    if (normalizedDurableScope(durable.scope) !== String(snapshot.scope)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `bound successor scope ${JSON.stringify(durable.scope)} does not match snapshot scope ${JSON.stringify(snapshot.scope)}`,
      );
    }
  } else {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `recovery refused: snapshot status ${snapshotStatus} is neither applied nor applying`,
    );
  }
  // Use official authority: this catches stale task.json files whose
  // workflow_id does not match the directory name, which a direct read
  // would happily accept.
  const authority = resolveTaskAuthority(root, pointerId);
  if (authority.status !== 'ok') {
    throw recoveryFailure(
      'blocked_legacy_task_authority_recovery',
      `focus pointer does not resolve through official task authority: ${pointerId} (${authority.message || authority.status})`,
    );
  }
  const durable = authority.task;
  // Gap 2: for status=applied, the snapshot already binds a successor; the
  // durable task must STILL carry workflow_type=long_write, user_goal exactly
  // snapshot.resume_intent, AND task_dir exactly snapshot.successor_task_dir.
  // Without these checks, an attacker (or a partially mutated state machine)
  // could rotate the durable task.json's metadata while keeping the same id,
  // and recovery would silently rebind to the wrong workflow_type / goal /
  // task_dir. The applying branch already verifies type+goal; we extend it
  // here to task_dir as well so the two branches share the same trust story.
  if (snapshotStatus === 'applied') {
    if (String(durable.workflow_type || '') !== WORKFLOW_TYPE) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `bound successor workflow_type mismatch: expected ${WORKFLOW_TYPE}, got ${JSON.stringify(durable.workflow_type)}`,
      );
    }
    if (String(durable.user_goal || '') !== String(snapshot.resume_intent || '')) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `bound successor user_goal ${JSON.stringify(durable.user_goal)} does not match snapshot resume_intent ${JSON.stringify(snapshot.resume_intent)}`,
      );
    }
    if (String(durable.task_dir || '') !== String(snapshot.successor_task_dir || '')) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `bound successor task_dir ${JSON.stringify(durable.task_dir)} does not match snapshot successor_task_dir ${JSON.stringify(snapshot.successor_task_dir)}`,
      );
    }
    if (normalizedDurableScope(durable.scope) !== String(snapshot.scope)) {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        `bound successor scope ${JSON.stringify(durable.scope)} does not match snapshot scope ${JSON.stringify(snapshot.scope)}`,
      );
    }
  }
  // Defect I: on applying crash recovery, materialize the source archive from
  // the verified snapshot bytes if it is missing or has wrong bytes. The
  // source file has been replaced by the successor focus pointer, so this
  // path can only recover from the snapshot's source_bytes_base64 (whose
  // sha256 was already validated by readRecoverySnapshot). Refuse if a
  // foreign archive already lives at the target.
  if (snapshotStatus === 'applying') {
    const archiveRelative = String(snapshot.archive_path || archiveFileFor(snapshot.source_task_id));
    const archivePath = path.join(root, archiveRelative);
    requireInside(root, archivePath, 'archive entry');
    if (fs.existsSync(archivePath)) {
      const existingArchive = fs.readFileSync(archivePath);
      const candidateBytes = Buffer.from(String(snapshot.source_bytes_base64 || ''), 'base64');
      if (!existingArchive.equals(candidateBytes)) {
        throw recoveryFailure(
          'blocked_legacy_task_authority_recovery',
          `archive entry already exists with different bytes: ${archivePath}`,
        );
      }
    } else if (typeof snapshot.source_bytes_base64 === 'string' && snapshot.source_bytes_base64.length > 0) {
      const candidateBytes = Buffer.from(snapshot.source_bytes_base64, 'base64');
      // Use the conflict-aware atomic helper so a mid-write failure never
      // leaves a partial or stray .tmp-* file at the archive path.
      archiveOriginalBytes(archivePath, candidateBytes);
    } else {
      throw recoveryFailure(
        'blocked_legacy_task_authority_recovery',
        'applying recovery cannot materialize archive: snapshot has no embedded source_bytes_base64',
      );
    }
  }
  let workingSnapshot = snapshot;
  if (snapshotStatus === 'applying') {
    workingSnapshot = {
      ...snapshot,
      status: 'applied',
      successor_workflow_id: pointerId,
      successor_task_dir: durable.task_dir,
      archive_path: snapshot.archive_path || archiveFileFor(snapshot.source_task_id),
      archive_sha256: typeof snapshot.source_bytes_base64 === 'string' && snapshot.source_bytes_base64.length > 0
        ? sha256(Buffer.from(snapshot.source_bytes_base64, 'base64'))
        : snapshot.archive_sha256,
      applied_at: new Date().toISOString(),
      pending_recovery: false,
    };
    atomicWriteJson(snapshotPath, workingSnapshot);
  }
  return buildApplyResult(root, durable, pointer, workingSnapshot, snapshotPath);
}

function buildApplyResult(root, durable, pointer, snapshot, snapshotPath) {
  const visible = buildApplyVisibleResponse(durable, snapshot, snapshotPath, root);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'legacy_task_authority_recovered',
    successor_workflow_id: durable.workflow_id,
    successor_workflow_type: durable.workflow_type,
    successor_task_dir: durable.task_dir,
    successor_user_goal: durable.user_goal,
    successor_scope: durable.scope,
    current_task: pointer,
    snapshot_path: relativePosix(root, snapshotPath),
    source_task_id: snapshot.source_task_id,
    visible_response: visible,
  };
}

function buildApplyVisibleResponse(durable, snapshot, snapshotPath, root) {
  const resumeIntent = String(snapshot.resume_intent || '');
  const continuation = `node scripts/workflow-entry-guard.js --project-root . --user-intent ${shellQuote(resumeIntent)} --write --compact --json`;
  const options = [
    {
      number: 1,
      label: '继续执行任务权威恢复后的长篇写作（推荐）',
      description: `使用原意图 ${resumeIntent} 继续任务。`,
      recommended: true,
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: continuation,
    },
    {
      number: 2,
      label: '查看新任务进度',
      description: '只读查看继承自旧任务的新任务。',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: 'node scripts/workflow-state-machine.js inspect --project-root . --json',
    },
    {
      number: 3,
      label: '查看本次恢复快照',
      description: `只读查看 ${relativePosix(root, snapshotPath)}。`,
      interaction_mode: 'informational',
    },
    {
      number: 4,
      label: '暂停并保留断点',
      description: '不继续任务，保留新任务为焦点。',
      interaction_mode: 'semantic_only',
    },
  ];
  return {
    render_mode: 'text_numbers',
    status: 'legacy_task_authority_recovered',
    selection_contract: 'execute_command_or_route_intent',
    free_text_enabled: true,
    options,
    text: options.map((option) => {
      const suffix = option.description ? `\n   ${option.description}` : '';
      return `${option.number}. ${option.label}${suffix}`;
    }).join('\n'),
    interaction_contract: 'render_visible_response_text_verbatim',
    continuation_command: continuation,
  };
}

function main() {
  let args;
  let result;
  try {
    args = parseArgs(process.argv.slice(2));
    const root = path.resolve(args.projectRoot);
    // Reject a symlinked project root before resolving it: this is the
    // explicit guard requested by defect 1. We still keep requireInside's
    // same check so the same rejection survives any future caller path.
    if (fs.existsSync(root)) {
      const rootStat = fs.lstatSync(root);
      if (rootStat.isSymbolicLink()) {
        throw recoveryFailure(
          'blocked_legacy_task_authority_recovery',
          `project root is a symlink: ${root} -> ${safeRealpath(root)}`,
        );
      }
    }
    requireInside(root, root, 'project root');
    if (args.command === 'preview') result = runPreview(root, args.resumeIntent);
    else if (args.command === 'confirm') result = runConfirm(root, args);
    else result = runApply(root, args);
  } catch (error) {
    const status = (error && error.status) ? error.status : 'blocked_legacy_task_authority_recovery';
    result = {
      schemaVersion: SCHEMA_VERSION,
      status,
      reason: error && error.message ? error.message : String(error),
    };
    process.exitCode = 2;
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

if (require.main === module) main();

module.exports = {
  buildRecoveryVisibleResponse,
  computePreviewId,
  computeProtectedHashes,
  extractResumeScope,
  normalizeLegacyTaskAuthority,
  parseArgs,
  recoveryFailure,
  shellQuote,
};
