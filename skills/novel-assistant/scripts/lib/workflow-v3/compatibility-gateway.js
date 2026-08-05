'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const authority = require('../workflow-task-authority');
const stateStore = require('../workflow-state-store');
const shortProjectState = require('../short-project-state');
const { createStageAttemptId } = require('./task-store');
const legacyProject = require('./migrations/legacy-short-project');
const migration = require('./migrations/v2-to-v3');

const ENGINE_VERSION = 3;
const TASK_SCHEMA_VERSION = 3;
const WORKFLOW_CONTRACT_VERSION = 3;
const OWNER = 'workflow-v3-compatibility-gateway';
const PLAN_DIR = path.posix.join('追踪', 'workflow', 'migrations', 'v3-plans');
const PROTECTED_ROOT_FILES = Object.freeze(['正文.md', '小节大纲.md', '大纲.md', '设定.md']);
const PROTECTED_DIRECTORIES = Object.freeze(['正文', '大纲', '设定']);
const DIGEST_PATTERN = /^sha256:([a-f0-9]{64})$/;

function inspectCompatibility(projectRoot) {
  const root = resolveRoot(projectRoot);
  const focused = authority.readFocusedTask(root);
  if (!focused.pointer || focused.authority.status !== 'ok') {
    const legacy = legacyProject.inspectLegacyShort(root);
    if (legacy.asset_status === 'legacy_short_assets_detected') {
      return compatibility('preview_required', {
        compatibility_kind: 'legacy_short_project',
        reason: 'legacy_project_import_required',
        evidence: legacy,
      });
    }
    return compatibility('unsupported', {
      compatibility_kind: 'legacy_short_project',
      reason: 'focused_durable_task_unavailable',
      evidence: legacy,
    });
  }
  return classifyTask(focused.authority.task);
}

function migrateLegacyShortProject(projectRoot, options) {
  return legacyProject.runLegacyShortProjectMigration(resolveRoot(projectRoot), options || {});
}

function migrateShortStateStorage(projectRoot) {
  return shortProjectState.migrateShortStateStorage(resolveRoot(projectRoot));
}

function classifyTask(task) {
  if (isV3Task(task)) {
    return compatibility('current', {
      workflow_id: String(task.workflow_id || ''),
      state_version: Number(task.state_version || 0),
      target_stage: String(task.current_stage || ''),
      reason: 'v3_contract_versions_current',
    });
  }
  if (String((task || {}).workflow_type || '') !== 'short_write') {
    return compatibility('unsupported', {
      workflow_id: String((task || {}).workflow_id || ''),
      state_version: Number((task || {}).state_version || 0),
      reason: 'workflow_type_not_supported',
    });
  }
  const mapped = mapV2Checkpoint(task, {});
  return compatibility(mapped.exact ? 'safe_auto_upgrade' : 'preview_required', {
    workflow_id: String(task.workflow_id || ''),
    state_version: Number(task.state_version || 0),
    source_stage: mapped.source_stage,
    target_stage: mapped.target_stage,
    checkpoint: mapped.checkpoint,
    reason: mapped.reason,
    ...(mapped.pending_action_policy ? { pending_action_policy: mapped.pending_action_policy } : {}),
  });
}

function compatibility(status, fields) {
  return { status, ...fields };
}

function buildMigrationPlan(projectRoot, workflowId) {
  const root = resolveRoot(projectRoot);
  const id = String(workflowId || '');
  const resolved = authority.resolveTaskAuthority(root, id);
  if (resolved.status !== 'ok') throw gatewayError('COMPATIBILITY_TASK_UNAVAILABLE', resolved.message);
  const task = resolved.task;
  if (isV3Task(task)) throw gatewayError('COMPATIBILITY_ALREADY_CURRENT', 'task already uses V3');
  if (String(task.workflow_type || '') !== 'short_write') {
    throw gatewayError('COMPATIBILITY_WORKFLOW_UNSUPPORTED', 'only V2 short_write tasks can migrate');
  }
  const mapped = mapV2Checkpoint(task, {});
  if (!mapped.exact || !migration.SUPPORTED_TARGET_STAGES.includes(mapped.target_stage)) {
    throw gatewayError('COMPATIBILITY_PREVIEW_REQUIRED', mapped.reason, { mapping: mapped });
  }
  const sourceBytes = fs.readFileSync(resolved.taskFile);
  const core = {
    workflow_id: id,
    task_dir: String(task.task_dir || ''),
    source_state_version: Number(task.state_version || 0),
    source_task_digest: digest(sourceBytes),
    source_stage: mapped.source_stage,
    checkpoint: mapped.checkpoint,
    target_stage: mapped.target_stage,
    pending_action_policy: String(mapped.pending_action_policy || ''),
    target_versions: {
      engine_version: ENGINE_VERSION,
      task_schema_version: TASK_SCHEMA_VERSION,
      workflow_contract_version: WORKFLOW_CONTRACT_VERSION,
    },
    protected_assets: collectProtectedAssetDigests(root),
  };
  const planDigest = digest(Buffer.from(stableJson(core)));
  const planPath = planRelativePath(planDigest);
  const plan = { ...core, plan_digest: planDigest, plan_path: planPath };
  stateStore.atomicWriteJson(path.join(root, planPath), plan);
  return plan;
}

function applyMigration(projectRoot, planDigest) {
  const root = resolveRoot(projectRoot);
  const expectedDigest = validateDigest(planDigest);
  const plan = readStoredPlan(root, expectedDigest);
  const release = stateStore.acquireProjectLock(root, OWNER);
  let releaseBook = null;
  try {
    releaseBook = stateStore.acquireBookWriteLease(root, OWNER);
    const resolved = authority.resolveTaskAuthority(root, plan.workflow_id);
    if (resolved.status !== 'ok') throw gatewayError('COMPATIBILITY_TASK_UNAVAILABLE', resolved.message);
    const current = resolved.task;
    if (isV3Task(current)) {
      if (String(((current.migration || {}).plan_digest) || '') === expectedDigest) {
        return {
          migrated: false,
          idempotent: true,
          workflow_id: current.workflow_id,
          state_version: Number(current.state_version || 0),
          target_stage: String(current.current_stage || ''),
          plan_digest: expectedDigest,
        };
      }
      throw gatewayError('COMPATIBILITY_ALREADY_CURRENT', 'task is V3 with another migration binding');
    }
    validateLiveSource(root, resolved, plan);

    const sourceBytes = fs.readFileSync(resolved.taskFile);
    const now = new Date().toISOString();
    const archivePath = path.posix.join('追踪', 'workflow', 'archived', `${plan.workflow_id}.pre-v3.json`);
    const archiveFile = path.join(root, archivePath);
    const rollback = {
      workflow_id: plan.workflow_id,
      source_state_version: plan.source_state_version,
      target_state_version: plan.source_state_version + 1,
      source_task_digest: plan.source_task_digest,
      source_stage: plan.source_stage,
      target_stage: plan.target_stage,
      checkpoint: plan.checkpoint,
      ...(plan.pending_action_policy
        ? { pending_action_policy: plan.pending_action_policy }
        : {}),
      plan_digest: expectedDigest,
      protected_assets: plan.protected_assets,
      captured_at: now,
    };
    writeArchiveOnce(archiveFile, {
      schema_version: '1.0.0',
      source_task_bytes_base64: sourceBytes.toString('base64'),
      source_task: JSON.parse(sourceBytes.toString('utf8')),
      rollback,
    }, plan.source_task_digest);

    const sectionIndex = inferSectionIndex(current);
    const committed = authority.mutateTaskAuthority(
      root,
      plan.workflow_id,
      plan.source_state_version,
      (draft) => {
        const migrated = migration.stripLegacyRuntimeProjections(draft);
        return {
          ...migrated,
          engine_version: ENGINE_VERSION,
          task_schema_version: TASK_SCHEMA_VERSION,
          workflow_contract_version: WORKFLOW_CONTRACT_VERSION,
          current_stage: plan.target_stage,
          current_step: plan.target_stage,
          stage_execution: {
            status: 'running',
            stage_id: plan.target_stage,
            step_id: plan.target_stage,
            stage_attempt_id: createStageAttemptId(plan.workflow_id, plan.target_stage),
            ...(sectionIndex ? { section_index: sectionIndex } : {}),
          },
          migration: {
            source_versions: {
              engine_version: ownedNumber(draft, 'engine_version'),
              task_schema_version: ownedNumber(draft, 'task_schema_version'),
              workflow_contract_version: ownedNumber(draft, 'workflow_contract_version'),
            },
            target_versions: plan.target_versions,
            source_task_digest: plan.source_task_digest,
            source_state_version: plan.source_state_version,
            target_state_version: plan.source_state_version + 1,
            source_stage: plan.source_stage,
            target_stage: plan.target_stage,
            checkpoint: plan.checkpoint,
            ...(plan.pending_action_policy
              ? { pending_action_policy: plan.pending_action_policy }
              : {}),
            archive_path: archivePath,
            plan_digest: expectedDigest,
            protected_assets_before: plan.protected_assets,
            protected_assets_after: plan.protected_assets,
            applied_at: now,
          },
        };
      },
      { owner: OWNER, projectLockHeld: true },
    );
    return {
      migrated: true,
      idempotent: false,
      workflow_id: committed.workflow_id,
      state_version: Number(committed.state_version || 0),
      target_stage: committed.current_stage,
      plan_digest: expectedDigest,
      archive_path: archivePath,
      ...(plan.pending_action_policy
        ? { pending_action_policy: plan.pending_action_policy }
        : {}),
    };
  } finally {
    if (releaseBook) releaseBook();
    release();
  }
}

function validateLiveSource(root, resolved, plan) {
  const task = resolved.task;
  if (String(task.workflow_type || '') !== 'short_write') {
    throw gatewayError('COMPATIBILITY_WORKFLOW_UNSUPPORTED', 'live workflow type changed');
  }
  if (String(task.task_dir || '') !== String(plan.task_dir || '')) {
    throw gatewayError('COMPATIBILITY_TASK_DIR_CHANGED', 'live task directory changed');
  }
  if (Number(task.state_version || 0) !== Number(plan.source_state_version)) {
    throw gatewayError('COMPATIBILITY_STALE_PLAN', 'live task state version changed');
  }
  if (digest(fs.readFileSync(resolved.taskFile)) !== plan.source_task_digest) {
    throw gatewayError('COMPATIBILITY_STALE_PLAN', 'live task bytes changed');
  }
  const mapped = mapV2Checkpoint(task, {});
  if (!mapped.exact || mapped.checkpoint !== plan.checkpoint || mapped.target_stage !== plan.target_stage
      || String(mapped.pending_action_policy || '') !== String(plan.pending_action_policy || '')) {
    throw gatewayError('COMPATIBILITY_CHECKPOINT_CHANGED', 'live checkpoint changed');
  }
  if (stableJson(collectProtectedAssetDigests(root)) !== stableJson(plan.protected_assets)) {
    throw gatewayError('COMPATIBILITY_CREATIVE_ASSET_CHANGED', 'protected creative assets changed');
  }
}

function readStoredPlan(root, planDigest) {
  const planPath = planRelativePath(planDigest);
  const file = path.join(root, planPath);
  let plan;
  try {
    plan = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    throw gatewayError('COMPATIBILITY_PLAN_UNAVAILABLE', 'migration preview is unavailable');
  }
  const { plan_digest: ignoredDigest, plan_path: ignoredPath, ...core } = plan;
  if (plan.plan_digest !== planDigest || plan.plan_path !== planPath
      || digest(Buffer.from(stableJson(core))) !== planDigest) {
    throw gatewayError('COMPATIBILITY_PLAN_TAMPERED', 'stored migration preview failed digest validation');
  }
  return plan;
}

function collectProtectedAssetDigests(projectRoot) {
  const root = resolveRoot(projectRoot);
  const files = new Set();
  for (const relative of PROTECTED_ROOT_FILES) {
    const file = path.join(root, relative);
    if (regularFile(file)) files.add(relative);
  }
  for (const relative of PROTECTED_DIRECTORIES) collectDirectory(root, relative, files);
  const result = {};
  for (const relative of [...files].sort()) result[relative] = digest(fs.readFileSync(path.join(root, relative)));
  return result;
}

function collectDirectory(root, relative, files) {
  const directory = path.join(root, relative);
  if (!fs.existsSync(directory)) return;
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink()) throw gatewayError('COMPATIBILITY_ASSET_SYMLINK', `protected path is a symlink: ${relative}`);
  if (!stat.isDirectory()) return;
  for (const entry of fs.readdirSync(directory).sort()) {
    const childRelative = path.posix.join(relative, entry);
    const child = path.join(root, childRelative);
    const childStat = fs.lstatSync(child);
    if (childStat.isSymbolicLink()) throw gatewayError('COMPATIBILITY_ASSET_SYMLINK', `protected path is a symlink: ${childRelative}`);
    if (childStat.isDirectory()) collectDirectory(root, childRelative, files);
    else if (childStat.isFile()) files.add(childRelative);
  }
}

function writeArchiveOnce(file, record, expectedSourceDigest) {
  if (fs.existsSync(file)) {
    let existing;
    try { existing = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { existing = null; }
    const restored = existing && typeof existing.source_task_bytes_base64 === 'string'
      ? Buffer.from(existing.source_task_bytes_base64, 'base64') : null;
    if (!restored || digest(restored) !== expectedSourceDigest) {
      throw gatewayError('COMPATIBILITY_ARCHIVE_CONFLICT', 'pre-existing migration archive does not match source task');
    }
    return;
  }
  stateStore.atomicWriteJson(file, record);
}

function inferSectionIndex(task) {
  const candidates = [
    Number(((task.stage_execution || {}).section_index) || 0),
    Number(((task.short_section_projection || {}).current_section_index) || 0),
    Number(((task.machine || {}).current_section_index) || 0),
  ];
  const scope = String(task.scope || '').match(/第\s*(\d+)\s*节/u);
  if (scope) candidates.push(Number(scope[1]));
  return candidates.find((value) => Number.isInteger(value) && value > 0) || 0;
}

function ownedNumber(value, key) {
  return Object.prototype.hasOwnProperty.call(value || {}, key) && Number.isFinite(Number(value[key]))
    ? Number(value[key]) : null;
}

function isV3Task(task) {
  return Number((task || {}).engine_version) === ENGINE_VERSION
    && Number((task || {}).task_schema_version) === TASK_SCHEMA_VERSION
    && Number((task || {}).workflow_contract_version) === WORKFLOW_CONTRACT_VERSION;
}

function mapV2Checkpoint(task, evidence) {
  return migration.mapV2Checkpoint(task, evidence || {});
}

function planRelativePath(planDigest) {
  const hash = validateDigest(planDigest).slice('sha256:'.length);
  return path.posix.join(PLAN_DIR, `${hash}.json`);
}

function validateDigest(value) {
  const text = String(value || '');
  if (!DIGEST_PATTERN.test(text)) throw gatewayError('COMPATIBILITY_PLAN_DIGEST_INVALID', 'plan digest is invalid');
  return text;
}

function resolveRoot(value) {
  const text = String(value || '').trim();
  if (!text) throw gatewayError('COMPATIBILITY_PROJECT_ROOT_REQUIRED', 'project root is required');
  return path.resolve(text);
}

function regularFile(file) {
  if (!fs.existsSync(file)) return false;
  const stat = fs.lstatSync(file);
  if (stat.isSymbolicLink()) throw gatewayError('COMPATIBILITY_ASSET_SYMLINK', `protected path is a symlink: ${file}`);
  return stat.isFile();
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function digest(bytes) {
  return `sha256:${crypto.createHash('sha256').update(bytes).digest('hex')}`;
}

function gatewayError(code, message, fields = {}) {
  const error = new Error(String(message || code));
  error.code = code;
  Object.assign(error, fields);
  return error;
}

module.exports = {
  applyMigration,
  buildMigrationPlan,
  collectProtectedAssetDigests,
  inspectCompatibility,
  mapV2Checkpoint,
  migrateLegacyShortProject,
  migrateShortStateStorage,
};
