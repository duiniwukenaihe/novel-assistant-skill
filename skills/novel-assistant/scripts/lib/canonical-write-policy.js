'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const STRICT_ROOTS = [
  '正文',
  '正文.md',
  '设定.md',
  '小节大纲.md',
  '大纲',
  '追踪/伏笔.md',
  '追踪/时间线.md',
  '追踪/角色状态.md',
  '追踪/上下文.md',
  '追踪/memory',
  '追踪/交接包',
];
const POLICY_RELATIVE_PATH = path.join('追踪', 'story-system', 'write-policy.json');
const CHAPTER_IDENTITIES_RELATIVE_PATH = path.join('追踪', 'story-system', 'chapter-identities.json');
const ACCEPTED_COMMIT_STATUSES = new Set(['accepted', 'accepted_with_projection_debt']);

function ensureCanonicalWritePolicy(projectRoot, options = {}) {
  const root = canonicalProjectRoot(projectRoot);
  const file = path.join(root, POLICY_RELATIVE_PATH);
  if (fs.existsSync(file)) return loadCanonicalWritePolicy(root);
  const mode = String(options.mode || 'strict');
  if (!['strict', 'legacy'].includes(mode)) {
    throw failure('blocked_invalid_write_policy', 'write policy mode must be strict or legacy');
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const policy = {
    schemaVersion: '1.0.0',
    mode,
    initialized_for: String(options.initializedFor || ''),
    initialized_at: new Date().toISOString(),
  };
  try {
    const fd = fs.openSync(file, 'wx', 0o644);
    try {
      fs.writeFileSync(fd, `${JSON.stringify(policy, null, 2)}\n`);
    } finally {
      fs.closeSync(fd);
    }
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  }
  return loadCanonicalWritePolicy(root);
}

function loadCanonicalWritePolicy(projectRoot) {
  const root = canonicalProjectRoot(projectRoot);
  const file = path.join(root, POLICY_RELATIVE_PATH);
  if (!fs.existsSync(file)) {
    const managedShort = isManagedShortProject(root);
    return {
      schemaVersion: '1.0.0',
      mode: managedShort || !hasExistingStoryEvidence(root) ? 'strict' : 'migration_required',
      source: managedShort ? 'managed-short-default' : 'default',
    };
  }
  let policy;
  try {
    policy = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw failure('blocked_invalid_write_policy', `could not read write policy: ${error.message}`);
  }
  if (!policy || !['strict', 'legacy'].includes(policy.mode)) {
    throw failure('blocked_invalid_write_policy', 'write policy mode must be strict or legacy');
  }
  return { ...policy, source: relativePosix(root, file) };
}

function requiresTransaction(policy, target) {
  return policy.mode === 'strict' && isCanonicalTarget(target);
}

function assertCanonicalWriteAllowed(projectRoot, targets, context = {}) {
  const policy = loadCanonicalWritePolicy(projectRoot);
  const normalizedTargets = normalizeTargets(projectRoot, targets);
  const canonicalTargets = normalizedTargets.filter(isCanonicalTarget);
  if (policy.mode === 'migration_required' && canonicalTargets.length > 0) {
    const error = failure('blocked_write_policy_migration_required', 'existing story assets require an explicit strict write-policy migration before canonical writes');
    error.targets = canonicalTargets;
    error.policy = policy;
    error.recovery = 'node scripts/book-write-policy-migrate.js preview --project-root . --json';
    throw error;
  }
  if (policy.mode === 'strict') assertStrictChapterTargets(projectRoot, normalizedTargets);
  const protectedTargets = canonicalTargets.filter(target => requiresTransaction(policy, target));
  const transactionId = transactionIdFrom(context);
  if (protectedTargets.length) {
    if (!transactionId) {
      const error = failure('blocked_canonical_transaction_required', 'strict write policy requires a canonical transaction');
      error.targets = protectedTargets;
      error.policy = policy;
      throw error;
    }
    assertPreparedTransactionTargets(projectRoot, transactionId, protectedTargets);
  }
  const legacyCanonicalWrite = policy.mode === 'legacy' && canonicalTargets.length > 0;
  return {
    status: legacyCanonicalWrite ? 'allowed_with_risk' : 'allowed',
    mode: policy.mode,
    policy,
    targets: normalizedTargets,
    canonical_targets: canonicalTargets,
    transaction_id: transactionId || null,
    ...(legacyCanonicalWrite ? {
      warning: 'legacy_canonical_write_unprotected',
      migrate_hint: 'Enable strict mode in 追踪/story-system/write-policy.json to require canonical transactions for story assets.',
    } : {}),
  };
}

function assertStrictChapterTargets(projectRoot, targets) {
  const archivedTarget = targets.find(isArchivedChapterTarget);
  if (archivedTarget) {
    const error = failure('blocked_archived_chapter_target', `archived chapter prose is read-only: target=${archivedTarget}`);
    error.target = archivedTarget;
    error.targets = [archivedTarget];
    throw error;
  }

  const chapterTargets = targets.map(target => ({ target, identity: parseChapterProseTarget(target) })).filter(item => item.identity);
  if (!chapterTargets.length) return;
  const registry = loadChapterIdentityRegistry(projectRoot);
  const acceptedTargets = acceptedChapterTargets(projectRoot);
  for (const item of chapterTargets) {
    const key = chapterIdentityKey(item.identity.volume, item.identity.chapter);
    const selected = registry.get(key);
    if (selected) {
      if (item.target !== selected.path) throwNoncanonicalChapterTarget(item.target, selected.path);
      continue;
    }
    const priorTargets = acceptedTargets.get(key) || [];
    if (priorTargets.length > 1) {
      throwNoncanonicalChapterTarget(item.target, priorTargets.join(','));
    }
    if (priorTargets.length && !priorTargets.includes(item.target)) {
      throwNoncanonicalChapterTarget(item.target, priorTargets[0]);
    }
  }
}

function loadChapterIdentityRegistry(projectRoot) {
  const root = canonicalProjectRoot(projectRoot);
  const file = path.join(root, CHAPTER_IDENTITIES_RELATIVE_PATH);
  if (!fs.existsSync(file)) return new Map();
  let registry;
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('registry must be a regular file');
    registry = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw failure('blocked_invalid_chapter_identity_registry', `chapter identity registry is unreadable: ${error.message}`);
  }
  if (!registry || registry.schemaVersion !== '1.0.0' || !Array.isArray(registry.chapters)) {
    throw failure('blocked_invalid_chapter_identity_registry', 'chapter identity registry must use schemaVersion 1.0.0 and a chapters array');
  }
  const entries = new Map();
  for (const value of registry.chapters) {
    const entry = validateChapterIdentityEntry(root, value);
    const key = chapterIdentityKey(entry.volume, entry.chapter);
    const previous = entries.get(key);
    if (previous && (previous.path !== entry.path || previous.content_hash !== entry.content_hash)) {
      throw failure('blocked_invalid_chapter_identity_registry', `chapter identity registry has conflicting selected paths for ${entry.volume} chapter ${entry.chapter}`);
    }
    if (!previous) entries.set(key, entry);
  }
  return entries;
}

function validateChapterIdentityEntry(root, value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw failure('blocked_invalid_chapter_identity_registry', 'chapter identity entry must be an object');
  }
  const volume = String(value.volume || '').trim();
  const chapter = Number(value.chapter);
  if (!volume || !Number.isInteger(chapter) || chapter < 1 || !validContentHash(value.content_hash)) {
    throw failure('blocked_invalid_chapter_identity_registry', 'chapter identity entry has invalid volume, chapter, or content_hash');
  }
  const selectedPath = validateRegistryChapterPath(root, value.path, { volume, chapter, allowArchived: false });
  if (!Array.isArray(value.excluded_candidates)) {
    throw failure('blocked_invalid_chapter_identity_registry', 'chapter identity entry requires excluded_candidates');
  }
  const excluded = value.excluded_candidates.map(candidate => {
    if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate) || !validContentHash(candidate.content_hash)) {
      throw failure('blocked_invalid_chapter_identity_registry', 'excluded chapter candidate has invalid path or content_hash');
    }
    const candidatePath = validateRegistryChapterPath(root, candidate.path, { volume, chapter, allowArchived: true });
    if (candidatePath === selectedPath) {
      throw failure('blocked_invalid_chapter_identity_registry', 'selected chapter path cannot also be an excluded candidate');
    }
    return { ...candidate, path: candidatePath };
  });
  return { ...value, volume, chapter, path: selectedPath, excluded_candidates: excluded };
}

function validateRegistryChapterPath(root, value, expected) {
  const input = String(value || '').trim();
  if (!input || input.includes('\\')) {
    throw failure('blocked_invalid_chapter_identity_registry', 'chapter identity paths must be project-relative POSIX paths');
  }
  let normalized;
  try {
    normalized = normalizeTarget(root, input);
  } catch (error) {
    throw failure('blocked_invalid_chapter_identity_registry', `chapter identity path is unsafe: ${input}`);
  }
  if (normalized !== input || (!expected.allowArchived && isArchivedChapterTarget(normalized))) {
    throw failure('blocked_invalid_chapter_identity_registry', `chapter identity path is not canonical: ${input}`);
  }
  const identity = parseChapterProseTarget(normalized, { allowArchived: expected.allowArchived });
  if (!identity || identity.volume !== expected.volume || identity.chapter !== expected.chapter) {
    throw failure('blocked_invalid_chapter_identity_registry', `chapter identity path does not match ${expected.volume} chapter ${expected.chapter}: ${input}`);
  }
  return normalized;
}

function acceptedChapterTargets(projectRoot) {
  const root = canonicalProjectRoot(projectRoot);
  const commitsDir = path.join(root, '追踪', 'story-system', 'commits');
  const result = new Map();
  if (!fs.existsSync(commitsDir) || !fs.statSync(commitsDir).isDirectory()) return result;
  const entries = fs.readdirSync(commitsDir, { withFileTypes: true })
    .filter(entry => entry.isFile() && entry.name.endsWith('.json'))
    .sort((left, right) => left.name.localeCompare(right.name));
  for (const entry of entries) {
    const commit = readValidAcceptedCommit(path.join(commitsDir, entry.name), root);
    if (!commit) continue;
    const key = chapterIdentityKey(commit.volume, commit.chapter);
    const targets = result.get(key) || [];
    for (const target of commit.targets) if (!targets.includes(target)) targets.push(target);
    if (targets.length) result.set(key, targets);
  }
  return result;
}

function readValidAcceptedCommit(file, root) {
  let commit;
  try {
    commit = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
  const volume = String((commit || {}).volume || '').trim();
  const chapter = Number((commit || {}).chapter);
  if (!commit || commit.schemaVersion !== '1.0.0' || !ACCEPTED_COMMIT_STATUSES.has(commit.status)
    || !String(commit.commit_id || '').trim() || !volume || !Number.isInteger(chapter) || chapter < 1
    || !Array.isArray(commit.artifacts)) return null;
  const chapterArtifacts = commit.artifacts.filter(artifact => artifact && artifact.role === 'chapter_prose');
  if (!chapterArtifacts.length) return null;
  const targets = [];
  for (const artifact of chapterArtifacts) {
    const hash = artifact.after_hash || artifact.content_hash;
    if (!validContentHash(hash)) return null;
    let target;
    try {
      target = normalizeTarget(root, artifact.target);
    } catch (_) {
      return null;
    }
    const identity = parseChapterProseTarget(target);
    if (!identity || identity.volume !== volume || identity.chapter !== chapter || isArchivedChapterTarget(target)) return null;
    targets.push(target);
  }
  return { volume, chapter, targets };
}

function parseChapterProseTarget(target, options = {}) {
  let value = String(target || '').replace(/\\/g, '/');
  if (options.allowArchived && isArchivedChapterTarget(value)) value = `正文/${value.slice('正文/legacy-flat-layout/'.length)}`;
  const match = value.match(/^正文\/([^/]+)\/第0*(\d+)章[^/]*\.(?:md|txt)$/iu);
  if (!match) return null;
  const chapter = Number(match[2]);
  if (!Number.isInteger(chapter) || chapter < 1) return null;
  return { volume: match[1], chapter };
}

function isArchivedChapterTarget(target) {
  return String(target || '') === '正文/legacy-flat-layout' || String(target || '').startsWith('正文/legacy-flat-layout/');
}

function validContentHash(value) {
  return /^sha256:[a-f0-9]{64}$/i.test(String(value || ''));
}

function chapterIdentityKey(volume, chapter) {
  return `${String(volume)}\u0000${Number(chapter)}`;
}

function throwNoncanonicalChapterTarget(target, selected) {
  const error = failure('blocked_noncanonical_chapter_target', `chapter prose target is not canonical: selected=${selected}; target=${target}`);
  error.selected = selected;
  error.target = target;
  error.targets = [target];
  throw error;
}

function hasExistingStoryEvidence(root) {
  return ['正文', '大纲', '细纲', '设定', '正文.md', '设定.md', '小节大纲.md']
    .some(relative => pathHasContent(path.join(root, relative)));
}

function isManagedShortProject(root) {
  const snapshot = readJsonIfExists(path.join(root, '追踪', 'story-system', 'short', 'material-snapshot.json'));
  const projectState = readJsonIfExists(path.join(root, '追踪', 'story-system', 'short', 'project-state.json'))
    || readJsonIfExists(path.join(root, '追踪', 'private-short-extension', 'project-state.json'));
  return Boolean(snapshot
    && projectState
    && String(snapshot.workflow_id || '')
    && String(projectState.active_write_workflow_id || ''));
}

function readJsonIfExists(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function pathHasContent(file) {
  if (!fs.existsSync(file)) return false;
  const stat = fs.statSync(file);
  if (stat.isFile()) return stat.size > 0;
  if (!stat.isDirectory()) return false;
  return fs.readdirSync(file, { withFileTypes: true }).some(entry => pathHasContent(path.join(file, entry.name)));
}

function normalizeTargets(projectRoot, targets) {
  const values = Array.isArray(targets) ? targets : [targets];
  return values.map(value => normalizeTarget(projectRoot, value));
}

function normalizeTarget(projectRoot, value) {
  const raw = typeof value === 'object' && value !== null ? value.target : value;
  const input = String(raw || '').trim();
  if (!input) {
    throw failure('blocked_unsafe_target', 'target must be a non-empty path inside the project root');
  }
  const root = canonicalProjectRoot(projectRoot);
  const candidate = path.win32.isAbsolute(input)
    ? path.resolve(root, normalizeWindowsTarget(root, input))
    : path.resolve(root, input.replace(/\\/g, path.sep));
  const resolved = realpathWithMissingTail(candidate);
  const relative = path.relative(root, resolved);
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw failure('blocked_unsafe_target', `target is outside project root: ${input}`);
  }
  return relative.split(path.sep).join('/');
}

function assertPreparedTransactionTargets(projectRoot, transactionId, targets) {
  if (!/^[A-Za-z0-9._-]+$/.test(transactionId)) {
    throw failure('blocked_canonical_transaction_invalid', 'canonical transaction id is invalid');
  }
  const root = canonicalProjectRoot(projectRoot);
  const transactionFile = path.join(root, '追踪', 'story-system', 'transactions', transactionId, 'transaction.json');
  let transaction;
  try {
    transaction = JSON.parse(fs.readFileSync(transactionFile, 'utf8'));
  } catch (_) {
    throw failure('blocked_canonical_transaction_invalid', 'canonical transaction is missing or unreadable');
  }
  if (!transaction || transaction.schemaVersion !== '1.0.0' || transaction.transaction_id !== transactionId) {
    throw failure('blocked_canonical_transaction_invalid', 'canonical transaction does not match the chapter-commit schema');
  }
  let transactionRoot;
  try {
    transactionRoot = canonicalProjectRoot(transaction.project_root);
  } catch (_) {
    throw failure('blocked_canonical_transaction_invalid', 'canonical transaction project root is invalid');
  }
  if (transactionRoot !== root) {
    throw failure('blocked_canonical_transaction_invalid', 'canonical transaction belongs to another project');
  }
  if (transaction.status !== 'prepared') {
    throw failure('blocked_canonical_transaction_not_prepared', 'canonical transaction must be prepared before a write');
  }
  if (!Array.isArray(transaction.artifacts)) {
    throw failure('blocked_canonical_transaction_invalid', 'prepared canonical transaction has no artifacts');
  }
  const artifactTargets = new Set(transaction.artifacts.map(artifact => {
    assertPreparedArtifact(root, transactionId, artifact);
    return normalizeTarget(root, artifact && artifact.target);
  }));
  if (targets.some(target => !artifactTargets.has(target))) {
    const error = failure('blocked_canonical_transaction_target_mismatch', 'prepared canonical transaction does not include every write target');
    error.targets = targets;
    throw error;
  }
}

function assertPreparedArtifact(root, transactionId, artifact) {
  const staged = normalizeTarget(root, artifact && artifact.staged);
  const stagedPrefix = `追踪/story-system/transactions/${transactionId}/staged/`;
  if (!staged.startsWith(stagedPrefix)) {
    throw failure('blocked_canonical_transaction_invalid', 'prepared artifact is outside its transaction staging directory');
  }
  const file = path.join(root, ...staged.split('/'));
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
    throw failure('blocked_canonical_transaction_invalid', 'prepared artifact is missing');
  }
  const contentHash = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
  if (contentHash !== artifact.content_hash) {
    throw failure('blocked_canonical_transaction_invalid', 'prepared artifact content does not match its transaction');
  }
}

function normalizeWindowsTarget(projectRoot, target) {
  const root = String(projectRoot || '').replace(/\//g, '\\');
  const input = String(target || '').replace(/\//g, '\\');
  if (!path.win32.isAbsolute(root) || !path.win32.isAbsolute(input)) {
    throw failure('blocked_unsafe_target', 'Windows absolute target requires a Windows absolute project root');
  }
  const normalizedRoot = path.win32.resolve(root);
  const normalizedTarget = path.win32.resolve(input);
  const relative = path.win32.relative(normalizedRoot, normalizedTarget);
  if (!relative || relative === '..' || relative.startsWith('..\\') || path.win32.isAbsolute(relative)) {
    throw failure('blocked_unsafe_target', `target is outside project root: ${target}`);
  }
  return relative.split('\\').join('/');
}

function canonicalProjectRoot(projectRoot) {
  const root = path.resolve(String(projectRoot || ''));
  try {
    return fs.realpathSync(root);
  } catch (error) {
    throw failure('blocked_unsafe_target', `could not resolve project root: ${error.message}`);
  }
}

function realpathWithMissingTail(file) {
  const missing = [];
  let current = file;
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) throw failure('blocked_unsafe_target', `could not resolve target: ${file}`);
    missing.unshift(path.basename(current));
    current = parent;
  }
  return path.resolve(fs.realpathSync(current), ...missing);
}

function isCanonicalTarget(target) {
  return STRICT_ROOTS.some(root => target === root || target.startsWith(`${root}/`));
}

function transactionIdFrom(context) {
  return String((context || {}).transactionId || (context || {}).transaction_id || (context || {}).transaction || '').trim();
}

function relativePosix(root, file) {
  return path.relative(path.resolve(root), file).split(path.sep).join('/');
}

function failure(code, message) {
  const error = new Error(message);
  error.code = code;
  error.status = code;
  return error;
}

module.exports = {
  POLICY_RELATIVE_PATH,
  CHAPTER_IDENTITIES_RELATIVE_PATH,
  STRICT_ROOTS,
  assertCanonicalWriteAllowed,
  ensureCanonicalWritePolicy,
  isCanonicalTarget,
  isManagedShortProject,
  loadCanonicalWritePolicy,
  normalizeTargets,
  normalizeWindowsTarget,
  requiresTransaction,
};
