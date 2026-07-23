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

function loadCanonicalWritePolicy(projectRoot) {
  const root = canonicalProjectRoot(projectRoot);
  const file = path.join(root, POLICY_RELATIVE_PATH);
  if (!fs.existsSync(file)) return { schemaVersion: '1.0.0', mode: 'legacy', source: 'default' };
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
  return error;
}

module.exports = {
  POLICY_RELATIVE_PATH,
  STRICT_ROOTS,
  assertCanonicalWriteAllowed,
  isCanonicalTarget,
  loadCanonicalWritePolicy,
  normalizeTargets,
  normalizeWindowsTarget,
  requiresTransaction,
};
