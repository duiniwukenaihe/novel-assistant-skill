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
const LOCK_TTL_MS = 15 * 60 * 1000;

try {
  const args = parseArgs(process.argv.slice(2));
  const root = resolveBookRoot(args.projectRoot);
  let result;
  if (args.command === 'preview') result = previewMigration(root);
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
  const args = { command: argv[0] || '', projectRoot: '', previewId: '', snapshot: '', confirm: false };
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--preview-id') args.previewId = argv[++index] || '';
    else if (arg === '--snapshot') args.snapshot = argv[++index] || '';
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
  process.stdout.write('Usage: node book-write-policy-migrate.js <preview|confirm|apply|rollback> --project-root <book-dir> [--preview-id <id>] [--snapshot <id>] [--confirm] [--json]\n');
  process.exit(code);
}

function previewMigration(root, options = {}) {
  const policy = readPolicy(root);
  const chapterIdentities = discoverChapterIdentities(root);
  const conflicts = [
    ...policy.conflicts,
    ...chapterIdentityConflicts(chapterIdentities),
    ...(options.ignoreBookLease ? [] : bookLeaseConflicts(root)),
    ...dirtyTrackingConflicts(root),
  ];
  const baseline = {
    policy_mode: policy.mode,
    policy_exists: policy.exists,
    chapter_identities: chapterIdentities,
    metadata: trackedMetadata(root),
  };
  const fingerprint = hashJson(baseline);
  const previewId = `write-policy-${fingerprint.slice(7, 23)}`;
  const strictCurrent = policy.mode === 'strict' && hasTransactionLedgers(root);
  const status = conflicts.length
    ? 'strict_blocked'
    : strictCurrent
      ? 'strict_current'
      : policy.mode === 'strict'
        ? 'strict_ready'
        : 'legacy';
  return {
    status,
    preview_id: previewId,
    fingerprint,
    policy_mode: policy.mode,
    conflicts,
    chapter_identities: chapterIdentities,
    rollback_snapshot: {
      snapshot_id: previewId,
      file: relativeSnapshotFile(previewId),
      metadata: baseline.metadata,
      prose_hashes: chapterIdentities.map(identity => ({ path: identity.path, hash: identity.content_hash })),
    },
  };
}

function confirmMigration(root, args) {
  return withBookLease(root, () => {
    const preview = previewMigration(root, { ignoreBookLease: true });
    if (preview.status === 'strict_blocked') throw blockedPreview(preview);
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
      return { status: existing.status === 'applied' ? 'strict_current' : 'confirmed', changed: false, snapshot_id: preview.preview_id, snapshot_file: file };
    }
    const snapshot = {
      schemaVersion: '1.0.0',
      snapshot_id: preview.preview_id,
      preview_id: preview.preview_id,
      status: 'confirmed',
      project_root: root,
      confirmed_at: new Date().toISOString(),
      fingerprint: preview.fingerprint,
      metadata_before: captureMetadata(root),
      prose_hashes: preview.rollback_snapshot.prose_hashes,
      chapter_identities: preview.chapter_identities,
      created_directories: [],
    };
    atomicWriteJson(file, snapshot);
    return { status: 'confirmed', changed: true, snapshot_id: snapshot.snapshot_id, snapshot_file: file };
  });
}

function applyMigration(root, args) {
  return withBookLease(root, () => {
    const snapshot = readSnapshot(root, args.snapshot);
    assertSnapshotProject(root, snapshot);
    if (snapshot.status === 'rolled_back') throw failure('blocked_snapshot_rolled_back', 'migration snapshot has already been rolled back');
    const preview = previewMigration(root, { ignoreBookLease: true });
    if (snapshot.status === 'applied') {
      if (preview.status !== 'strict_current') throw failure('blocked_migration_drift', 'applied migration metadata is no longer current');
      return { status: 'strict_current', changed: false, snapshot_id: snapshot.snapshot_id, snapshot_file: snapshotFile(root, snapshot.snapshot_id) };
    }
    if (preview.status === 'strict_blocked') throw blockedPreview(preview);
    if (preview.preview_id !== snapshot.preview_id) throw failure('blocked_migration_preview_stale', 'book metadata changed after confirmation; run preview and confirm again');
    const createdDirectories = ensureLedgerDirectories(root);
    try {
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
    return { status: 'strict_current', changed: true, snapshot_id: snapshot.snapshot_id, snapshot_file: snapshotFile(root, snapshot.snapshot_id) };
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

function discoverChapterIdentities(root) {
  const proseRoot = path.join(root, '正文');
  if (!fs.existsSync(proseRoot) || !fs.statSync(proseRoot).isDirectory()) return [];
  const identities = [];
  walkFiles(proseRoot, file => {
    if (!/\.(?:md|txt)$/i.test(file)) return;
    const relative = relativePosix(root, file);
    if (isArchivedChapterCopy(relative)) return;
    const chapterMatch = path.basename(file).match(/第\s*0*(\d+)\s*章/);
    if (!chapterMatch) return;
    const volume = relative.split('/').find(part => /^第.+卷$/.test(part)) || '第1卷';
    identities.push({
      volume,
      chapter: Number(chapterMatch[1]),
      path: relative,
      content_hash: hashFile(file),
    });
  });
  return identities.sort((left, right) => left.volume.localeCompare(right.volume, 'zh-Hans-CN') || left.chapter - right.chapter || left.path.localeCompare(right.path));
}

function isArchivedChapterCopy(relative) {
  const parts = String(relative || '').split('/');
  const base = parts.at(-1) || '';
  if (parts.some(part => /^(?:\.|_)*(?:backup|bak|archive|history|版本|归档|旧稿|草稿|原稿|deslop_backup)/i.test(part))) return true;
  return /(?:^|_)(?:原稿|备份|旧稿|草稿|修订前|历史版本)(?:_|\.|$)/.test(base);
}

function chapterIdentityConflicts(identities) {
  const conflicts = [];
  if (!identities.length) conflicts.push({ code: 'missing_chapter_identity', path: '正文' });
  const seen = new Set();
  for (const identity of identities) {
    const key = `${identity.volume}/${identity.chapter}`;
    if (seen.has(key)) conflicts.push({ code: 'duplicate_chapter_identity', volume: identity.volume, chapter: identity.chapter });
    seen.add(key);
  }
  return conflicts;
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
  return [POLICY_FILE, IDENTITY_FILE, PROJECTION_LOG_FILE].map(relative => fileMetadata(root, relative));
}

function captureMetadata(root) {
  return [POLICY_FILE, IDENTITY_FILE, PROJECTION_LOG_FILE].map(relative => {
    const file = path.join(root, relative);
    if (!fs.existsSync(file)) return { path: relative, exists: false };
    return { path: relative, exists: true, content_base64: fs.readFileSync(file).toString('base64'), hash: hashFile(file) };
  });
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
    if (!item.exists || current.hash !== item.hash) conflicts.push({ code: 'migration_metadata_changed', path: item.path });
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
    const stat = fs.statSync(file);
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
