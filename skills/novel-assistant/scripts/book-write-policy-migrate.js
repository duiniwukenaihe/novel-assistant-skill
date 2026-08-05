#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { acquireBookWriteLease, atomicWriteJson, atomicWriteText } = require('./lib/workflow-state-store');

const POLICY_FILE = '追踪/story-system/write-policy.json';
const IDENTITY_FILE = '追踪/story-system/chapter-identities.json';
const PROJECTION_LOG_FILE = '追踪/story-system/projection-log.jsonl';
const SNAPSHOT_DIR = '追踪/story-system/write-policy-migrations';
const TRANSACTIONS_DIR = '追踪/story-system/transactions';
const COMMITS_DIR = '追踪/story-system/commits';
const BOOK_LOCK_DIR = '追踪/story-system/.write.lock';
const SCHEMA_AUTHORITY_FILE = '追踪/schema/chapters.jsonl';
const ASSET_AUTHORITY_FILE = '追踪/章节资产.jsonl';
const LOCK_TTL_MS = 15 * 60 * 1000;

try {
  const args = parseArgs(process.argv.slice(2));
  const root = resolveBookRoot(args.projectRoot);
  let result;
  if (args.command === 'preview') result = previewMigration(root, { resumeIntent: args.resumeIntent, selectionFile: args.selectionFile });
  else if (args.command === 'confirm') result = confirmMigration(root, args);
  else if (args.command === 'apply') result = applyMigration(root, args);
  else if (args.command === 'rollback') result = rollbackMigration(root, args);
  else throw failure('blocked_invalid_command', `unknown command: ${args.command}`);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} catch (error) {
  process.stdout.write(`${JSON.stringify({
    status: error && error.status ? error.status : 'error',
    message: String(error && error.message ? error.message : error),
    conflicts: error && error.conflicts ? error.conflicts : undefined,
  }, null, 2)}\n`);
  process.exitCode = 2;
}

function parseArgs(argv) {
  const args = { command: argv[0] || '', projectRoot: '', previewId: '', snapshot: '', selectionFile: '', confirm: false, resumeIntent: '' };
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--preview-id') args.previewId = argv[++index] || '';
    else if (arg === '--snapshot') args.snapshot = argv[++index] || '';
    else if (arg === '--selection-file') args.selectionFile = argv[++index] || '';
    else if (arg === '--resume-intent') args.resumeIntent = argv[++index] || '';
    else if (arg === '--confirm') args.confirm = true;
    else if (arg === '--json') continue;
    else if (arg === '--help' || arg === '-h') usage(0);
    else throw failure('blocked_invalid_argument', `unknown argument: ${arg}`);
  }
  if (!args.projectRoot) throw failure('blocked_invalid_argument', 'missing --project-root');
  if (args.command === 'confirm' && (!args.confirm || !args.previewId)) {
    throw failure('blocked_confirmation_required', 'confirm requires --preview-id and --confirm');
  }
  if (args.command === 'apply' && !args.snapshot) throw failure('blocked_invalid_argument', 'apply requires --snapshot');
  if (args.command === 'rollback' && (!args.snapshot || !args.confirm)) {
    throw failure('blocked_confirmation_required', 'rollback requires --snapshot and --confirm');
  }
  return args;
}

function usage(code) {
  process.stdout.write('Usage: node book-write-policy-migrate.js <preview|confirm|apply|rollback> --project-root <book-dir> [--preview-id <id>] [--snapshot <id>] [--selection-file <json>] [--resume-intent <text>] [--confirm] [--json]\n');
  process.exit(code);
}

function shellQuote(value) {
  return `'${String(value || '').replace(/'/g, `'"'"'`)}'`;
}

function buildEntryGuardContinuationCommand(intent) {
  return `node scripts/workflow-entry-guard.js --project-root . --user-intent ${shellQuote(intent)} --write --compact --json`;
}

function attachEntryGuardContinuation(result, intent) {
  const resumeIntent = String(intent || '').trim();
  if (!resumeIntent) return result;
  result.resume_intent = resumeIntent;
  result.continuation_required = true;
  result.continuation_command = buildEntryGuardContinuationCommand(resumeIntent);
  return result;
}

function buildResumeIntentMenu(previewId, intent, selectionFile = '') {
  const selectionArgument = selectionFile ? ` --selection-file ${shellQuote(path.resolve(selectionFile))}` : '';
  const confirmCommand = `node scripts/book-write-policy-migrate.js confirm --project-root . --preview-id ${shellQuote(previewId)}${selectionArgument} --confirm --resume-intent ${shellQuote(intent)} --json`;
  const introspectCommand = `node scripts/book-write-policy-migrate.js preview --project-root . --resume-intent ${shellQuote(intent)} --json`;
  const options = [
    {
      number: 1,
      label: '确认严格写入策略迁移',
      action: 'confirm_write_policy_migration',
      description: `仅写入确认快照，使用原意图 ${intent} 继续后续任务。`,
      recommended: true,
      display: '1. 确认严格写入策略迁移（推荐）',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: confirmCommand,
    },
    {
      number: 2,
      label: '仅查看本次预览',
      action: 'inspect_write_policy_migration_preview',
      description: '重新生成本次预览，不写入任何内容。',
      recommended: false,
      display: '2. 仅查看本次预览',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: introspectCommand,
    },
    {
      number: 3,
      label: '稍后再处理',
      action: 'pause',
      description: '暂不应用严格写入策略，保持当前目录。',
      recommended: false,
      display: '3. 稍后再处理',
      interaction_mode: 'semantic_only',
    },
    {
      number: 4,
      label: '补充原任务意图',
      action: 'free_text',
      description: '调整原任务的目的、范围或目标，再生成新的预览。',
      recommended: false,
      display: '4. 补充原任务意图',
      interaction_mode: 'semantic_only',
    },
  ];
  return {
    render_mode: 'text_numbers',
    status: 'write_policy_migration_preview',
    intro: '检测到当前书籍未启用严格写入策略。先完成策略预览/确认/应用，再继续原任务。',
    selection_contract: 'execute_command_or_route_intent',
    options,
    text: options.map(option => option.display).join('\n'),
  };
}

function buildBlockedResumeIntentMenu() {
  const options = [
    {
      number: 1,
      label: '查看并处理迁移冲突',
      action: 'inspect_write_policy_migration_conflicts',
      description: '先处理当前预览列出的冲突，再重新运行迁移预览。',
      recommended: true,
      display: '1. 查看并处理迁移冲突（推荐）',
      interaction_mode: 'semantic_only',
    },
    {
      number: 2,
      label: '暂停并保存断点',
      action: 'pause',
      description: '保持当前目录不变，稍后再处理迁移冲突。',
      recommended: false,
      display: '2. 暂停并保存断点',
      interaction_mode: 'semantic_only',
    },
    {
      number: 3,
      label: '输入其他要求',
      action: 'free_text',
      description: '补充冲突处理要求或调整当前任务目标。',
      recommended: false,
      display: '3. 输入其他要求',
      interaction_mode: 'semantic_only',
    },
  ];
  const intro = '严格写入策略迁移已阻断：必须先解决当前预览列出的冲突，才能确认或应用迁移。';
  return {
    render_mode: 'text_numbers',
    status: 'strict_blocked',
    intro,
    selection_contract: 'route_intent_only',
    free_text_enabled: true,
    options,
    text: `${intro}\n\n${options.map(option => option.display).join('\n')}`,
  };
}

function buildConfirmIntentMenu(snapshotId, intent) {
  const applyCommand = `node scripts/book-write-policy-migrate.js apply --project-root . --snapshot ${shellQuote(snapshotId)} --resume-intent ${shellQuote(intent)} --json`;
  const options = [
    {
      number: 1,
      label: '应用已确认的写入策略迁移',
      action: 'apply_write_policy_migration',
      description: `使用原意图 ${intent} 应用本次确认。`,
      recommended: true,
      display: '1. 应用已确认的写入策略迁移（推荐）',
      interaction_mode: 'execute_command',
      execution_workdir: '.',
      execution_command: applyCommand,
    },
    {
      number: 2,
      label: '仅查看本次确认',
      action: 'inspect_write_policy_migration_confirmation',
      description: '重新查看本次确认结果，不执行应用。',
      recommended: false,
      display: '2. 仅查看本次确认',
      interaction_mode: 'semantic_only',
    },
    {
      number: 3,
      label: '稍后再处理',
      action: 'pause',
      description: '暂不应用严格写入策略，保持当前目录。',
      recommended: false,
      display: '3. 稍后再处理',
      interaction_mode: 'semantic_only',
    },
    {
      number: 4,
      label: '补充原任务意图',
      action: 'free_text',
      description: '调整原任务的目的、范围或目标，重新生成预览与确认。',
      recommended: false,
      display: '4. 补充原任务意图',
      interaction_mode: 'semantic_only',
    },
  ];
  return {
    render_mode: 'text_numbers',
    status: 'write_policy_migration_confirmed',
    intro: '已写入写入策略迁移确认快照。先应用本次确认，再继续原任务。',
    selection_contract: 'execute_command_or_route_intent',
    options,
    text: options.map(option => option.display).join('\n'),
  };
}

function previewMigration(root, options = {}) {
  const policy = readPolicy(root);
  const discoveredIdentities = discoverChapterIdentities(root);
  const authorities = readChapterAuthorities(root);
  const sourceState = migrationSourceState(root, discoveredIdentities);
  const sourceFingerprint = hashJson(sourceState);
  const initialPreviewId = `write-policy-${sourceFingerprint.slice(7, 23)}`;
  const unresolvedResolution = resolveChapterIdentities(root, discoveredIdentities, authorities);
  const selectionManifest = options.selectionManifest || (options.selectionFile
    ? readSelectionManifest(path.resolve(options.selectionFile))
    : null);
  let resolution = unresolvedResolution;
  let selections = [];
  let selectionApplied = false;
  if (selectionManifest) {
    selections = validateSelectionManifest(root, selectionManifest, {
      initialPreviewId,
      sourceFingerprint,
      discoveredIdentities,
      resolution: unresolvedResolution,
      staleAsMigration: Boolean(options.selectionStaleAsMigration),
    });
    resolution = applyExplicitSelections(unresolvedResolution, selections);
    selectionApplied = true;
  }
  const chapterIdentities = resolution.identities;
  const conflicts = [
    ...policy.conflicts,
    ...authorities.conflicts,
    ...resolution.conflicts,
    ...(options.ignoreBookLease ? [] : bookLeaseConflicts(root)),
    ...dirtyTrackingConflicts(root),
  ];
  const fingerprint = sourceFingerprint;
  const previewId = selectionApplied
    ? `write-policy-selection-${hashJson({ source_fingerprint: sourceFingerprint, selections }).slice(7, 23)}`
    : initialPreviewId;
  const strictCurrent = policy.mode === 'strict' && hasTransactionLedgers(root);
  const resumeIntent = String(options.resumeIntent || '').trim();
  const baseStatus = conflicts.length
    ? 'strict_blocked'
    : strictCurrent
      ? 'strict_current'
      : policy.mode === 'strict'
        ? 'strict_ready'
        : 'legacy';
  const status = resumeIntent && baseStatus === 'legacy' ? 'write_policy_migration_preview' : baseStatus;
  const result = {
    status,
    preview_id: previewId,
    fingerprint,
    source_fingerprint: sourceFingerprint,
    selection_applied: selectionApplied,
    policy_mode: policy.mode,
    conflicts,
    chapter_identities: chapterIdentities,
    rollback_snapshot: {
      snapshot_id: previewId,
      file: relativeSnapshotFile(previewId),
      metadata: trackedMetadata(root),
      prose_hashes: discoveredIdentities.map(identity => ({ path: identity.path, hash: identity.content_hash })),
    },
  };
  if (selectionApplied) result.selections = selections;
  result.all_candidates = discoveredIdentities;
  result.authority_evidence = sourceState.authority_files;
  if (resumeIntent) {
    if (strictCurrent) return attachEntryGuardContinuation({ ...result, changed: false }, resumeIntent);
    result.resume_intent = resumeIntent;
    result.visible_response = baseStatus === 'strict_blocked'
      ? buildBlockedResumeIntentMenu()
      : buildResumeIntentMenu(previewId, resumeIntent, options.selectionFile);
  }
  return result;
}

function confirmMigration(root, args) {
  return withBookLease(root, () => {
    const initialPreview = previewMigration(root, { ignoreBookLease: true, resumeIntent: args.resumeIntent });
    if (!args.selectionFile && String(args.previewId || '').startsWith('write-policy-selection-')) {
      throw failure('blocked_selection_required', 'this selection-bound preview must be confirmed with the same --selection-file');
    }
    const preview = args.selectionFile
      ? previewMigration(root, {
        ignoreBookLease: true,
        resumeIntent: args.resumeIntent,
        selectionFile: args.selectionFile,
        selectionStaleAsMigration: true,
      })
      : initialPreview;
    if (preview.status === 'strict_blocked') throw blockedPreview(preview);
    const resumeIntent = String(args.resumeIntent || preview.resume_intent || '').trim();
    if (preview.status === 'strict_current' && resumeIntent) {
      return attachEntryGuardContinuation({
        status: 'strict_current',
        changed: false,
        snapshot_id: preview.preview_id,
      }, resumeIntent);
    }
    if (preview.preview_id !== args.previewId) {
      throw failure('blocked_migration_preview_stale', 'book metadata changed after preview; run preview again');
    }
    if (preview.status === 'strict_current') {
      return { status: 'strict_current', changed: false, snapshot_id: preview.preview_id };
    }
    const file = snapshotFile(root, preview.preview_id);
    if (fs.existsSync(file)) {
      const existing = readJson(file, 'migration snapshot');
      if (existing.preview_id !== preview.preview_id) throw failure('blocked_snapshot_conflict', 'existing migration snapshot does not match the current preview');
      const suppliedIntent = String(args.resumeIntent || preview.resume_intent || '').trim();
      let changed = false;
      if (suppliedIntent && existing.resume_intent !== suppliedIntent) {
        existing.resume_intent = suppliedIntent;
        atomicWriteJson(file, existing);
        changed = true;
      }
      const result = {
        status: existing.status === 'applied' ? 'strict_current' : 'confirmed',
        changed,
        snapshot_id: preview.preview_id,
        snapshot_file: file,
      };
      const intent = suppliedIntent || existing.resume_intent || '';
      if (intent) {
        result.resume_intent = intent;
        result.visible_response = buildConfirmIntentMenu(preview.preview_id, intent);
      }
      return result;
    }
    const snapshot = {
      schemaVersion: '1.0.0',
      snapshot_id: preview.preview_id,
      preview_id: preview.preview_id,
      status: 'confirmed',
      project_root: root,
      confirmed_at: new Date().toISOString(),
      fingerprint: preview.fingerprint,
      source_fingerprint: preview.source_fingerprint,
      metadata_before: captureMetadata(root),
      prose_hashes: preview.rollback_snapshot.prose_hashes,
      chapter_identities: preview.chapter_identities,
      selections: preview.selections || [],
      all_candidates: preview.all_candidates || [],
      authority_evidence: preview.authority_evidence || [],
      created_directories: [],
    };
    if (resumeIntent) snapshot.resume_intent = resumeIntent;
    atomicWriteJson(file, snapshot);
    const result = { status: 'confirmed', changed: true, snapshot_id: snapshot.snapshot_id, snapshot_file: file };
    if (resumeIntent) {
      result.resume_intent = resumeIntent;
      result.visible_response = buildConfirmIntentMenu(snapshot.snapshot_id, resumeIntent);
    }
    return result;
  });
}

function applyMigration(root, args) {
  return withBookLease(root, () => {
    const snapshot = readSnapshot(root, args.snapshot);
    assertSnapshotProject(root, snapshot);
    if (snapshot.status === 'rolled_back') throw failure('blocked_snapshot_rolled_back', 'migration snapshot has already been rolled back');
    let preview;
    if (snapshot.status !== 'applied' && Array.isArray(snapshot.selections) && snapshot.selections.length) {
      const selectionManifest = {
        schemaVersion: '1.0.0',
        preview_id: `write-policy-${String(snapshot.source_fingerprint || '').slice(7, 23)}`,
        source_fingerprint: snapshot.source_fingerprint,
        selections: snapshot.selections,
      };
      try {
        preview = previewMigration(root, {
          ignoreBookLease: true,
          resumeIntent: args.resumeIntent || snapshot.resume_intent || '',
          selectionManifest,
          selectionStaleAsMigration: true,
        });
      } catch (error) {
        if (error && String(error.status || '').startsWith('blocked_selection_')) {
          throw failure('blocked_migration_preview_stale', 'chapter candidates or authorities changed after confirmation; run preview and confirm again');
        }
        throw error;
      }
    } else {
      preview = previewMigration(root, { ignoreBookLease: true, resumeIntent: args.resumeIntent || snapshot.resume_intent || '' });
    }
    if (snapshot.status === 'applied') {
      if (preview.status !== 'strict_current') throw failure('blocked_migration_drift', 'applied migration metadata is no longer current');
      const reapplied = {
        status: 'strict_current',
        changed: false,
        snapshot_id: snapshot.snapshot_id,
        snapshot_file: snapshotFile(root, snapshot.snapshot_id),
      };
      const resumeIntent = String(args.resumeIntent || snapshot.resume_intent || '').trim();
      if (resumeIntent) {
        reapplied.resume_intent = resumeIntent;
        reapplied.continuation_required = true;
        reapplied.continuation_command = buildEntryGuardContinuationCommand(resumeIntent);
      }
      return reapplied;
    }
    if (preview.status === 'strict_blocked') throw blockedPreview(preview);
    if (preview.preview_id !== snapshot.preview_id) throw failure('blocked_migration_preview_stale', 'book metadata changed after confirmation; run preview and confirm again');
    const createdDirectories = ensureLedgerDirectories(root);
    try {
      if (Array.isArray(snapshot.selections) && snapshot.selections.length) {
        patchAuthorityFiles(root, snapshot.selections);
      }
      atomicWriteJson(path.join(root, POLICY_FILE), {
        schemaVersion: '1.0.0',
        mode: 'strict',
        migrated_at: new Date().toISOString(),
        migration_snapshot_id: snapshot.snapshot_id,
      });
      atomicWriteJson(path.join(root, IDENTITY_FILE), {
        schemaVersion: '1.0.0',
        migration_snapshot_id: snapshot.snapshot_id,
        initialized_at: new Date().toISOString(),
        chapters: snapshot.chapter_identities,
      });
      if (!fs.existsSync(path.join(root, PROJECTION_LOG_FILE))) atomicWriteText(path.join(root, PROJECTION_LOG_FILE), '');
      snapshot.status = 'applied';
      snapshot.applied_at = new Date().toISOString();
      snapshot.created_directories = createdDirectories;
      snapshot.metadata_after = captureMetadata(root);
      atomicWriteJson(snapshotFile(root, snapshot.snapshot_id), snapshot);
    } catch (error) {
      restoreMetadata(root, snapshot.metadata_before);
      removeCreatedDirectories(root, createdDirectories);
      throw failure('rolled_back', `strict migration failed and metadata was restored: ${error.message}`);
    }
    const result = {
      status: 'strict_current',
      changed: true,
      snapshot_id: snapshot.snapshot_id,
      snapshot_file: snapshotFile(root, snapshot.snapshot_id),
    };
    const resumeIntent = String(args.resumeIntent || snapshot.resume_intent || '').trim();
    if (resumeIntent) {
      result.resume_intent = resumeIntent;
      result.continuation_required = true;
      result.continuation_command = buildEntryGuardContinuationCommand(resumeIntent);
    }
    return result;
  });
}

function rollbackMigration(root, args) {
  return withBookLease(root, () => {
    const snapshot = readSnapshot(root, args.snapshot);
    assertSnapshotProject(root, snapshot);
    if (snapshot.status === 'rolled_back') return { status: 'rolled_back', changed: false, snapshot_id: snapshot.snapshot_id };
    if (snapshot.status !== 'applied') throw failure('blocked_snapshot_not_applied', 'only an applied strict migration can be rolled back');
    const conflicts = rollbackConflicts(root, snapshot);
    if (conflicts.length) {
      const error = failure('blocked_rollback_conflict', 'book changed after migration; rollback would not be safe');
      error.conflicts = conflicts;
      throw error;
    }
    restoreMetadata(root, snapshot.metadata_before);
    removeCreatedDirectories(root, snapshot.created_directories || []);
    snapshot.status = 'rolled_back';
    snapshot.rolled_back_at = new Date().toISOString();
    atomicWriteJson(snapshotFile(root, snapshot.snapshot_id), snapshot);
    return { status: 'rolled_back', changed: true, snapshot_id: snapshot.snapshot_id, snapshot_file: snapshotFile(root, snapshot.snapshot_id) };
  });
}

function readPolicy(root) {
  const file = path.join(root, POLICY_FILE);
  if (!fs.existsSync(file)) return { mode: 'legacy', exists: false, conflicts: [] };
  try {
    const policy = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!policy || !['legacy', 'strict'].includes(policy.mode)) {
      return { mode: 'legacy', exists: true, conflicts: [{ code: 'invalid_write_policy', path: POLICY_FILE }] };
    }
    return { mode: policy.mode, exists: true, conflicts: [] };
  } catch (_) {
    return { mode: 'legacy', exists: true, conflicts: [{ code: 'invalid_write_policy', path: POLICY_FILE }] };
  }
}

function migrationSourceState(root, discoveredIdentities = discoverChapterIdentities(root)) {
  const activeCandidates = discoveredIdentities.map(identity => ({
    volume: identity.volume,
    chapter: identity.chapter,
    path: identity.path,
    content_hash: identity.content_hash,
    char_count: identity.char_count,
  }));
  const authorityFiles = [SCHEMA_AUTHORITY_FILE, ASSET_AUTHORITY_FILE].map(relative => {
    const file = path.join(root, relative);
    if (!fs.existsSync(file)) return { path: relative, exists: false, content_base64: null };
    const content = fs.readFileSync(file);
    return { path: relative, exists: true, content_base64: content.toString('base64') };
  });
  return { active_candidates: activeCandidates, authority_files: authorityFiles };
}

function readSelectionManifest(file) {
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile()) throw new Error('not a regular file');
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw failure('blocked_selection_manifest_invalid', `selection manifest is missing or invalid: ${error.message}`);
  }
}

function validateSelectionManifest(root, manifest, context) {
  if (!manifest || manifest.schemaVersion !== '1.0.0' || !Array.isArray(manifest.selections)) {
    throw failure('blocked_selection_manifest_invalid', 'selection manifest must use schemaVersion 1.0.0 and a selections array');
  }
  if (manifest.preview_id !== context.initialPreviewId || manifest.source_fingerprint !== context.sourceFingerprint) {
    if (context.staleAsMigration) {
      throw failure('blocked_migration_preview_stale', 'chapter candidates or authorities changed after preview; run preview again');
    }
    throw failure('blocked_selection_source_mismatch', 'selection manifest does not match the current initial preview and source fingerprint');
  }

  const unresolved = new Map();
  for (const conflict of context.resolution.conflicts.filter(item => item.code === 'duplicate_chapter_identity')) {
    unresolved.set(chapterIdentityKey(conflict.volume, conflict.chapter), conflict.candidates);
  }
  const normalized = [];
  const seen = new Set();
  for (const raw of manifest.selections) {
    const volume = String(raw && raw.volume || '').trim();
    const chapter = Number(raw && raw.chapter);
    const relative = normalizeSelectionPath(raw && raw.path);
    const contentHash = String(raw && raw.content_hash || '').trim();
    if (!volume || !Number.isInteger(chapter) || chapter < 1) {
      throw failure('blocked_selection_invalid_identity', 'each selection must include a valid volume and chapter');
    }
    const key = chapterIdentityKey(volume, chapter);
    if (seen.has(key)) throw failure('blocked_selection_duplicate', `selection repeats ${volume} chapter ${chapter}`);
    seen.add(key);

    const discoveredAtPath = context.discoveredIdentities.find(candidate => candidate.path === relative);
    if (!unresolved.has(key)) {
      if (discoveredAtPath && chapterIdentityKey(discoveredAtPath.volume, discoveredAtPath.chapter) !== key) {
        throw failure('blocked_selection_invalid_identity', 'selection volume and chapter do not match the selected prose path');
      }
      throw failure('blocked_selection_extra', 'selection includes a chapter identity that is not an unresolved duplicate');
    }
    if (isArchivedChapterCopy(relative)) throw failure('blocked_selection_archive_path', 'selection cannot choose an archived prose path');
    const file = path.resolve(root, relative);
    if (!isInsideRoot(root, file)) throw failure('blocked_selection_invalid_path', 'selection path must stay inside the book project');
    if (!fs.existsSync(file)) throw failure('blocked_selection_candidate_missing', 'selected prose candidate does not exist');
    if (pathHasSymlink(root, relative)) throw failure('blocked_selection_symlink_path', 'selection path cannot contain symbolic links');
    if (!fs.lstatSync(file).isFile()) throw failure('blocked_selection_not_regular_file', 'selected prose candidate must be a regular file');

    const candidates = unresolved.get(key);
    const candidate = candidates.find(item => item.path === relative);
    if (!candidate) throw failure('blocked_selection_not_candidate', 'selected path is not an active candidate for this duplicate identity');
    if (chapterIdentityKey(candidate.volume, candidate.chapter) !== key) {
      throw failure('blocked_selection_invalid_identity', 'selection identity does not match the selected prose path');
    }
    if (contentHash !== candidate.content_hash || hashFile(file) !== contentHash) {
      throw failure('blocked_selection_hash_mismatch', 'selected prose content hash does not match the preview');
    }
    normalized.push({ volume, chapter, path: relative, content_hash: contentHash });
  }
  const missing = [...unresolved.keys()].filter(key => !seen.has(key));
  if (missing.length) throw failure('blocked_selection_incomplete', 'selection manifest must choose exactly one candidate for every unresolved duplicate identity');
  return normalized.sort((left, right) => left.volume.localeCompare(right.volume, 'zh-Hans-CN') || left.chapter - right.chapter || left.path.localeCompare(right.path));
}

function normalizeSelectionPath(value) {
  const raw = String(value || '').replace(/\\/g, '/').replace(/^\.\//, '').trim();
  if (!raw || path.posix.isAbsolute(raw)) throw failure('blocked_selection_invalid_path', 'selection path must be project-relative');
  const normalized = path.posix.normalize(raw);
  if (normalized !== raw || normalized === '..' || normalized.startsWith('../')) {
    throw failure('blocked_selection_invalid_path', 'selection path must be normalized and stay inside the project');
  }
  return normalized;
}

function pathHasSymlink(root, relative) {
  let current = root;
  for (const part of relative.split('/')) {
    current = path.join(current, part);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) return true;
  }
  return false;
}

function applyExplicitSelections(resolution, selections) {
  const selectedByKey = new Map(selections.map(item => [chapterIdentityKey(item.volume, item.chapter), item]));
  const unresolvedConflicts = resolution.conflicts.filter(item => item.code === 'duplicate_chapter_identity');
  const unresolvedKeys = new Set(unresolvedConflicts.map(item => chapterIdentityKey(item.volume, item.chapter)));
  const identities = resolution.identities.filter(identity => !unresolvedKeys.has(chapterIdentityKey(identity.volume, identity.chapter)));
  for (const conflict of unresolvedConflicts) {
    const key = chapterIdentityKey(conflict.volume, conflict.chapter);
    const selection = selectedByKey.get(key);
    const selected = conflict.candidates.find(candidate => candidate.path === selection.path);
    identities.push({
      ...selected,
      excluded_candidates: conflict.candidates
        .filter(candidate => candidate.path !== selected.path)
        .map(candidate => ({ path: candidate.path, content_hash: candidate.content_hash, reason: 'explicit_selection' })),
    });
  }
  return {
    identities: identities.sort((left, right) => left.volume.localeCompare(right.volume, 'zh-Hans-CN') || left.chapter - right.chapter || left.path.localeCompare(right.path)),
    conflicts: resolution.conflicts.filter(item => item.code !== 'duplicate_chapter_identity'),
  };
}

function discoverChapterIdentities(root) {
  const proseRoot = path.join(root, '正文');
  if (!fs.existsSync(proseRoot)) return [];
  const proseRootStat = fs.lstatSync(proseRoot);
  if (proseRootStat.isSymbolicLink() || !proseRootStat.isDirectory()) return [];
  const identities = [];
  walkFiles(proseRoot, file => {
    if (!/\.(?:md|txt)$/i.test(file)) return;
    const realFile = fs.realpathSync(file);
    const realRelative = path.relative(root, realFile);
    if (!realRelative || realRelative === '..' || realRelative.startsWith(`..${path.sep}`) || path.isAbsolute(realRelative)) return;
    const relative = relativePosix(root, file);
    if (isArchivedChapterCopy(relative)) return;
    const chapterMatch = path.basename(file).match(/第\s*0*(\d+)\s*章/);
    if (!chapterMatch) return;
    const volume = relative.split('/').find(part => /^第.+卷$/.test(part)) || '第1卷';
    const stat = fs.statSync(file);
    const content = fs.readFileSync(file, 'utf8');
    identities.push({
      volume,
      chapter: Number(chapterMatch[1]),
      path: relative,
      content_hash: hashContent(content),
      char_count: Array.from(content).length,
      mtime: stat.mtime.toISOString(),
      authority_sources: [],
    });
  });
  return identities.sort((left, right) => left.volume.localeCompare(right.volume, 'zh-Hans-CN') || left.chapter - right.chapter || left.path.localeCompare(right.path));
}

function isArchivedChapterCopy(relative) {
  const parts = String(relative || '').split('/');
  const base = parts.at(-1) || '';
  if (parts[0] === '正文' && parts[1] === 'legacy-flat-layout') return true;
  if (parts.some(part => /^(?:\.|_)*(?:backup|bak|archive|history|版本|归档|旧稿|草稿|原稿|deslop_backup)/i.test(part))) return true;
  return /(?:^|_)(?:原稿|备份|旧稿|草稿|修订前|历史版本)(?:_|\.|$)/.test(base);
}

function readChapterAuthorities(root) {
  const sources = [
    { name: 'schema', relative: SCHEMA_AUTHORITY_FILE },
    { name: 'asset', relative: ASSET_AUTHORITY_FILE },
  ];
  const pathsBySource = { schema: new Map(), asset: new Map() };
  const conflicts = [];

  for (const source of sources) {
    const file = path.join(root, source.relative);
    if (!fs.existsSync(file)) continue;
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    lines.forEach((line, index) => {
      if (!line.trim()) return;
      let row;
      try {
        row = JSON.parse(line);
      } catch (_) {
        conflicts.push({
          code: 'invalid_chapter_authority_jsonl',
          source: source.name,
          path: source.relative,
          line: index + 1,
          message: '章节权威索引包含无法解析的 JSONL；修复该行后才能继续迁移。',
        });
        return;
      }
      const draftPath = normalizeAuthorityPath(row && row.draftPath);
      if (!draftPath) return;
      const identity = authorityIdentity(row, draftPath);
      if (!identity) {
        conflicts.push({
          code: 'invalid_chapter_authority_identity',
          source: source.name,
          path: source.relative,
          line: index + 1,
          draft_path: draftPath,
          message: '章节权威索引无法确定卷号与章号；修复该行后才能继续迁移。',
        });
        return;
      }
      const key = chapterIdentityKey(identity.volume, identity.chapter);
      if (!pathsBySource[source.name].has(key)) pathsBySource[source.name].set(key, new Set());
      pathsBySource[source.name].get(key).add(draftPath);
    });

    for (const [key, draftPaths] of pathsBySource[source.name]) {
      if (draftPaths.size < 2) continue;
      const [volume, chapterText] = splitChapterIdentityKey(key);
      conflicts.push({
        code: 'ambiguous_chapter_authority',
        source: source.name,
        path: source.relative,
        volume,
        chapter: Number(chapterText),
        draft_paths: [...draftPaths].sort(),
        message: '同一章节在单个权威索引中指向多个正文路径；系统不会替作者选择。',
      });
    }
  }

  return { pathsBySource, conflicts };
}

function resolveChapterIdentities(root, identities, authorities) {
  const grouped = new Map();
  for (const identity of identities) {
    const key = chapterIdentityKey(identity.volume, identity.chapter);
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(withAuthoritySources(identity, key, authorities));
  }

  const resolved = [];
  const conflicts = [];
  if (!identities.length) {
    conflicts.push({
      code: 'missing_active_chapter_identity',
      path: '正文',
      message: '未发现可写的当前正文；归档副本不会被迁移为当前章节。',
    });
  }

  for (const [key, candidates] of grouped) {
    if (candidates.length === 1) {
      resolved.push({ ...candidates[0], excluded_candidates: [] });
      continue;
    }
    const schemaPaths = authorityPaths(authorities, 'schema', key);
    const assetPaths = authorityPaths(authorities, 'asset', key);
    const agreedPath = schemaPaths.length === 1 && assetPaths.length === 1 && schemaPaths[0] === assetPaths[0]
      ? schemaPaths[0]
      : '';
    const selected = agreedPath
      ? candidates.find(candidate => candidate.path === agreedPath && isSafeAuthorityCandidate(root, candidate, key))
      : null;
    if (selected) {
      resolved.push({ ...selected, excluded_candidates: [] });
      continue;
    }
    const [volume, chapterText] = splitChapterIdentityKey(key);
    resolved.push(...candidates);
    conflicts.push({
      code: 'duplicate_chapter_identity',
      volume,
      chapter: Number(chapterText),
      message: '同一卷章存在多个当前正文候选，且两个权威索引没有共同指向同一安全文件；系统不会替作者选择。',
      candidates,
    });
  }

  return {
    identities: resolved.sort((left, right) => left.volume.localeCompare(right.volume, 'zh-Hans-CN') || left.chapter - right.chapter || left.path.localeCompare(right.path)),
    conflicts,
  };
}

function withAuthoritySources(identity, key, authorities) {
  const authoritySources = ['asset', 'schema'].filter(source => authorityPaths(authorities, source, key).includes(identity.path));
  return { ...identity, authority_sources: authoritySources };
}

function authorityPaths(authorities, source, key) {
  const paths = authorities.pathsBySource[source].get(key);
  return paths ? [...paths].sort() : [];
}

function authorityIdentity(row, draftPath) {
  const inferredChapter = chapterNumberFromPath(draftPath);
  const chapter = Number(row.volumeChapterNo || row.chapter || row.chapterNo || inferredChapter);
  const volume = String(row.volume || draftPath.split('/').find(part => /^第.+卷$/.test(part)) || '第1卷').trim();
  if (!Number.isInteger(chapter) || chapter < 1 || !volume) return null;
  return { volume, chapter };
}

function chapterNumberFromPath(relative) {
  const match = path.posix.basename(relative).match(/第\s*0*(\d+)\s*章/);
  return match ? Number(match[1]) : 0;
}

function normalizeAuthorityPath(value) {
  const normalized = String(value || '').replace(/\\/g, '/').replace(/^\.\//, '').trim();
  if (!normalized || path.posix.isAbsolute(normalized)) return '';
  return path.posix.normalize(normalized);
}

function isSafeAuthorityCandidate(root, candidate, key) {
  if (!candidate || isArchivedChapterCopy(candidate.path)) return false;
  if (chapterIdentityKey(candidate.volume, candidate.chapter) !== key) return false;
  const file = path.resolve(root, candidate.path);
  if (!isInsideRoot(root, file) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return false;
  const real = fs.realpathSync(file);
  return isInsideRoot(root, real);
}

function isInsideRoot(root, file) {
  const relative = path.relative(root, file);
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function chapterIdentityKey(volume, chapter) {
  return `${volume}\u0000${chapter}`;
}

function splitChapterIdentityKey(key) {
  return String(key).split('\u0000');
}

function bookLeaseConflicts(root) {
  const lockDir = path.join(root, BOOK_LOCK_DIR);
  if (!fs.existsSync(lockDir)) return [];
  const ownerFile = path.join(lockDir, 'owner.json');
  let owner = { owner: 'unknown', acquired_at: '' };
  try { owner = JSON.parse(fs.readFileSync(ownerFile, 'utf8')); } catch (_) {}
  const acquiredAt = new Date(owner.acquired_at || '').getTime();
  if (Number.isFinite(acquiredAt) && Date.now() - acquiredAt > LOCK_TTL_MS) return [];
  return [{ code: 'book_write_lease_active', path: BOOK_LOCK_DIR, owner: owner.owner || 'unknown' }];
}

function dirtyTrackingConflicts(root) {
  const conflicts = [];
  const transactions = path.join(root, TRANSACTIONS_DIR);
  if (hasDirtyTransactionMetadata(transactions)) conflicts.push({ code: 'dirty_transaction_metadata', path: TRANSACTIONS_DIR });
  const commits = path.join(root, COMMITS_DIR);
  if (directoryHasFiles(commits) && readPolicy(root).mode !== 'strict') conflicts.push({ code: 'dirty_commit_metadata', path: COMMITS_DIR });
  const leases = path.join(root, '追踪/story-system/leases');
  if (directoryHasFiles(leases)) conflicts.push({ code: 'chapter_write_lease_active', path: '追踪/story-system/leases' });
  return conflicts;
}

function hasDirtyTransactionMetadata(directory) {
  if (!fs.existsSync(directory)) return false;
  for (const name of fs.readdirSync(directory)) {
    const transactionDir = path.join(directory, name);
    if (!fs.statSync(transactionDir).isDirectory()) return true;
    const file = path.join(transactionDir, 'transaction.json');
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return true;
    try {
      const transaction = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (!['accepted', 'rolled_back'].includes(transaction.status)) return true;
    } catch (_) {
      return true;
    }
  }
  return false;
}

function hasTransactionLedgers(root) {
  return fs.existsSync(path.join(root, TRANSACTIONS_DIR))
    && fs.existsSync(path.join(root, COMMITS_DIR))
    && fs.existsSync(path.join(root, PROJECTION_LOG_FILE))
    && fs.existsSync(path.join(root, IDENTITY_FILE));
}

function trackedMetadata(root) {
  return [POLICY_FILE, IDENTITY_FILE, PROJECTION_LOG_FILE, SCHEMA_AUTHORITY_FILE, ASSET_AUTHORITY_FILE]
    .map(relative => fileMetadata(root, relative));
}

function captureMetadata(root) {
  return [POLICY_FILE, IDENTITY_FILE, PROJECTION_LOG_FILE, SCHEMA_AUTHORITY_FILE, ASSET_AUTHORITY_FILE].map(relative => {
    const file = path.join(root, relative);
    if (!fs.existsSync(file)) return { path: relative, exists: false };
    return { path: relative, exists: true, content_base64: fs.readFileSync(file).toString('base64'), hash: hashFile(file) };
  });
}

function patchAuthorityFiles(root, selections) {
  const selectedByKey = new Map(selections.map(item => [chapterIdentityKey(item.volume, item.chapter), item.path]));
  for (const relative of [SCHEMA_AUTHORITY_FILE, ASSET_AUTHORITY_FILE]) {
    const file = path.join(root, relative);
    if (!fs.existsSync(file)) continue;
    const original = fs.readFileSync(file, 'utf8');
    const patched = original.replace(/[^\r\n]+/g, line => {
      if (!line.trim()) return line;
      let row;
      try { row = JSON.parse(line); } catch (_) { return line; }
      const currentPath = normalizeAuthorityPath(row && row.draftPath);
      if (!currentPath) return line;
      const identity = authorityIdentity(row, currentPath);
      if (!identity) return line;
      const selectedPath = selectedByKey.get(chapterIdentityKey(identity.volume, identity.chapter));
      if (!selectedPath || currentPath === selectedPath) return line;
      const draftPathPattern = /(\"draftPath\"\s*:\s*)(\"(?:\\.|[^\"\\])*\")/;
      if (!draftPathPattern.test(line)) return line;
      return line.replace(draftPathPattern, `$1${JSON.stringify(selectedPath)}`);
    });
    if (patched !== original) atomicWriteText(file, patched);
  }
}

function ensureLedgerDirectories(root) {
  const directories = [
    '追踪/story-system',
    TRANSACTIONS_DIR,
    COMMITS_DIR,
  ];
  const created = [];
  for (const relative of directories) {
    const directory = path.join(root, relative);
    if (!fs.existsSync(directory)) created.push(relative);
    fs.mkdirSync(directory, { recursive: true });
  }
  return created;
}

function restoreMetadata(root, metadata) {
  for (const item of metadata || []) {
    const file = path.join(root, item.path);
    if (item.exists) atomicWriteText(file, Buffer.from(item.content_base64, 'base64'));
    else fs.rmSync(file, { force: true });
  }
}

function removeCreatedDirectories(root, directories) {
  for (const relative of [...directories].sort((left, right) => right.length - left.length)) {
    const directory = path.join(root, relative);
    if (fs.existsSync(directory) && fs.readdirSync(directory).length === 0) fs.rmdirSync(directory);
  }
}

function rollbackConflicts(root, snapshot) {
  const conflicts = [];
  for (const item of snapshot.prose_hashes || []) {
    const file = path.join(root, item.path);
    if (!fs.existsSync(file) || hashFile(file) !== item.hash) conflicts.push({ code: 'legacy_prose_changed', path: item.path });
  }
  for (const item of snapshot.metadata_after || []) {
    const current = fileMetadata(root, item.path);
    if (current.exists !== item.exists || (item.exists && current.hash !== item.hash)) {
      conflicts.push({ code: 'migration_metadata_changed', path: item.path });
    }
  }
  for (const relative of snapshot.created_directories || []) {
    const directory = path.join(root, relative);
    if (fs.existsSync(directory) && fs.readdirSync(directory).length > 0) conflicts.push({ code: 'new_transaction_activity', path: relative });
  }
  return conflicts;
}

function readSnapshot(root, snapshotId) {
  if (!/^[A-Za-z0-9._-]+$/.test(String(snapshotId || ''))) throw failure('blocked_invalid_snapshot', 'migration snapshot id is invalid');
  return readJson(snapshotFile(root, snapshotId), 'migration snapshot');
}

function assertSnapshotProject(root, snapshot) {
  if (!snapshot || snapshot.schemaVersion !== '1.0.0' || path.resolve(snapshot.project_root || '') !== root) {
    throw failure('blocked_invalid_snapshot', 'migration snapshot does not belong to this book');
  }
}

function snapshotFile(root, snapshotId) {
  return path.join(root, SNAPSHOT_DIR, `${snapshotId}.json`);
}

function relativeSnapshotFile(snapshotId) {
  return `${SNAPSHOT_DIR}/${snapshotId}.json`;
}

function withBookLease(root, operation) {
  let release;
  try {
    release = acquireBookWriteLease(root, 'book-write-policy-migrate');
  } catch (error) {
    if (error && error.code === 'BOOK_WRITE_LOCKED') throw failure('blocked_book_write_locked', error.message);
    throw error;
  }
  try {
    return operation();
  } finally {
    release();
  }
}

function blockedPreview(preview) {
  const error = failure('strict_blocked', 'strict migration is blocked by current book state');
  error.conflicts = preview.conflicts;
  return error;
}

function resolveBookRoot(value) {
  try {
    const root = fs.realpathSync(path.resolve(String(value || '')));
    if (!fs.statSync(root).isDirectory()) throw new Error('not a directory');
    return root;
  } catch (error) {
    throw failure('blocked_invalid_project_root', `could not resolve book root: ${error.message}`);
  }
}

function directoryHasFiles(directory) {
  if (!fs.existsSync(directory)) return false;
  for (const name of fs.readdirSync(directory)) {
    const file = path.join(directory, name);
    if (fs.statSync(file).isDirectory()) {
      if (directoryHasFiles(file)) return true;
    } else {
      return true;
    }
  }
  return false;
}

function walkFiles(directory, visit) {
  for (const name of fs.readdirSync(directory).sort()) {
    const file = path.join(directory, name);
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink()) continue;
    if (stat.isDirectory()) walkFiles(file, visit);
    else if (stat.isFile()) visit(file);
  }
}

function fileMetadata(root, relative) {
  const file = path.join(root, relative);
  return fs.existsSync(file) ? { path: relative, exists: true, hash: hashFile(file) } : { path: relative, exists: false, hash: null };
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    throw failure('blocked_invalid_snapshot', `${label} is missing or invalid`);
  }
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function hashContent(content) {
  return `sha256:${crypto.createHash('sha256').update(content).digest('hex')}`;
}

function hashJson(value) {
  return `sha256:${crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex')}`;
}

function relativePosix(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function failure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}
