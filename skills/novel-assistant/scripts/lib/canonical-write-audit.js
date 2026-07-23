'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');
const { isCanonicalTarget, normalizeTargets } = require('./canonical-write-policy');
const { readTaskFamily } = require('./task-family-store');

const BASELINE_FILE = 'canonical-write-baseline.json';
const AUDIT_FILE = 'write-audit.json';
const SHORT_WRITE_FORMAL_ASSETS = ['素材卡.md', '设定.md', '小节大纲.md', '正文.md'];
const SHORT_WORKFLOW_TYPES = new Set(['short_write', 'short_startup', 'private_short_startup']);

function captureCanonicalBaseline(projectRoot, task) {
  const root = path.resolve(projectRoot);
  const currentDeclaredWriteSet = declaredCanonicalWriteSet(root, task);
  const baselineFile = taskFile(root, task, BASELINE_FILE);
  const existing = fs.existsSync(baselineFile) ? readJson(baselineFile) : null;
  const declaredWriteSet = unionDeclaredWriteSets(root, (existing || {}).declared_write_set, currentDeclaredWriteSet);
  const capturedAt = existing && validTimestamp(existing.captured_at) ? existing.captured_at : new Date().toISOString();
  const priorFiles = existing && existing.files && typeof existing.files === 'object' ? existing.files : {};
  const currentFiles = snapshotBaselineFiles(root, declaredWriteSet);
  const baseline = {
    schemaVersion: '1.1.0',
    baseline_id: existing && existing.baseline_id ? String(existing.baseline_id) : crypto.randomUUID(),
    workflow_id: String((task || {}).workflow_id || ''),
    task_family_id: String((task || {}).task_family_id || ''),
    captured_at: capturedAt,
    updated_at: new Date().toISOString(),
    declared_write_set: declaredWriteSet,
    files: { ...priorFiles, ...Object.fromEntries(Object.entries(currentFiles).filter(([target]) => !(target in priorFiles))) },
  };
  atomicWriteJson(baselineFile, baseline);
  return {
    status: existing ? 'captured_incremental' : 'captured',
    baseline_file: relativePosix(root, baselineFile),
    canonical_paths: Object.keys(baseline.files).sort(),
    declared_write_set: declaredWriteSet,
  };
}

function auditCanonicalWrites(projectRoot, task, options = {}) {
  const root = path.resolve(projectRoot);
  const currentDeclaredWriteSet = declaredCanonicalWriteSet(root, task, options);
  const baselineFile = taskFile(root, task, BASELINE_FILE);
  if (!fs.existsSync(baselineFile)) {
    return emptyAudit(currentDeclaredWriteSet, 'baseline_not_captured');
  }

  const baseline = readJson(baselineFile);
  const declaredWriteSet = Array.isArray(options.declaredWriteSet)
    ? currentDeclaredWriteSet
    : unionDeclaredWriteSets(root, baseline.declared_write_set, currentDeclaredWriteSet);
  if (declaredWriteSet.length === 0) return emptyAudit(declaredWriteSet, 'no_declared_canonical_write_set');
  const current = snapshotCanonicalFiles(root, declaredWriteSet);
  const changedPaths = Array.from(new Set([...Object.keys(baseline.files || {}), ...Object.keys(current)]))
    .filter((target) => declaredWriteSet.some((rule) => writeSetAllows(rule, target)))
    .filter((target) => String((baseline.files || {})[target] || '') !== String(current[target] || ''))
    .sort();
  let reconciliation = reconcileChangedPaths(root, task, baseline, changedPaths, current);
  let retry = null;
  if (reconciliation.unmanagedPaths.length > 0) {
    const retriedCurrent = snapshotCanonicalFiles(root, declaredWriteSet);
    const retriedPaths = changedCanonicalPaths(baseline.files || {}, retriedCurrent);
    reconciliation = reconcileChangedPaths(root, task, baseline, retriedPaths, retriedCurrent);
    retry = {
      attempted: true,
      status: reconciliation.unmanagedPaths.length > 0 ? 'receipt_pending' : 'reconciled_on_retry',
      changed_during_retry: !sameSnapshot(current, retriedCurrent),
      next_step: reconciliation.unmanagedPaths.length > 0 ? '受控提交后复检 canonical audit。' : '',
    };
  }

  const result = {
    schemaVersion: '1.0.0',
    status: reconciliation.unmanagedPaths.length > 0 ? 'blocked_unreconciled_canonical_write' : 'ok',
    workflow_id: String((task || {}).workflow_id || ''),
    audited_at: new Date().toISOString(),
    baseline_file: relativePosix(root, baselineFile),
    declared_write_set: declaredWriteSet,
    changed_paths: reconciliation.changedPaths,
    accepted_paths: reconciliation.acceptedPaths,
    unmanaged_paths: reconciliation.unmanagedPaths,
    ...(retry ? { receipt_retry: retry } : {}),
  };
  if (reconciliation.unmanagedPaths.length > 0) {
    const auditFile = taskFile(root, task, AUDIT_FILE);
    atomicWriteJson(auditFile, result);
    result.audit_file = relativePosix(root, auditFile);
  }
  return result;
}

function acceptValidatedStageWrites(projectRoot, task, result, declaredWriteSet) {
  const root = path.resolve(projectRoot);
  if (String((task || {}).workflow_type || '') !== 'long_write') {
    return { status: 'not_applicable', artifacts: [] };
  }
  const targets = normalizeDeclaredWriteSet(root, declaredWriteSet);
  const artifacts = [];
  for (const target of targets) {
    const file = path.resolve(root, target);
    if (!file.startsWith(`${root}${path.sep}`) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      return {
        status: 'blocked_canonical_stage_receipt_target_missing',
        target,
        artifacts: [],
      };
    }
    artifacts.push({ target, after_hash: hashFile(file) });
  }
  if (artifacts.length === 0) return { status: 'no_canonical_stage_writes', artifacts: [] };

  const baselineFile = taskFile(root, task, BASELINE_FILE);
  const baseline = fs.existsSync(baselineFile) ? readJson(baselineFile) : {};
  const capturedAt = new Date(String(baseline.captured_at || '')).getTime();
  const acceptedAtMs = Math.max(Date.now(), Number.isFinite(capturedAt) ? capturedAt + 1 : 0);
  const attemptId = String((((task || {}).stage_execution || {}).stage_attempt_id) || 'stage')
    .replace(/[^A-Za-z0-9._-]/g, '_');
  const stageId = String((result || {}).stage_id || (task || {}).current_stage || 'stage')
    .replace(/[^A-Za-z0-9._-]/g, '_');
  const commitId = `workflow-stage-${stageId}-${attemptId}`;
  const commit = {
    schemaVersion: '1.0.0',
    commit_id: commitId,
    commit_kind: 'workflow_stage_acceptance',
    status: 'accepted',
    workflow_id: String((task || {}).workflow_id || ''),
    task_family_id: String((task || {}).task_family_id || ''),
    stage_id: String((result || {}).stage_id || ''),
    stage_attempt_id: String((((task || {}).stage_execution || {}).stage_attempt_id) || ''),
    result_packet_path: String((result || {}).result_packet_path || ''),
    accepted_at: new Date(acceptedAtMs).toISOString(),
    artifacts,
  };
  const commitsDir = path.join(root, '追踪', 'story-system', 'commits');
  const commitFile = path.join(commitsDir, `${commitId}.json`);
  if (fs.existsSync(commitFile)) {
    const existing = readJson(commitFile);
    if (String(existing.workflow_id || '') !== commit.workflow_id
        || String(existing.stage_attempt_id || '') !== commit.stage_attempt_id
        || JSON.stringify(existing.artifacts || []) !== JSON.stringify(commit.artifacts)) {
      return { status: 'blocked_canonical_stage_receipt_conflict', commit_path: relativePosix(root, commitFile), artifacts };
    }
    return { status: 'reused', commit_path: relativePosix(root, commitFile), artifacts: existing.artifacts || [] };
  }
  atomicWriteJson(commitFile, commit);
  return { status: 'accepted', commit_path: relativePosix(root, commitFile), artifacts };
}

function declaredCanonicalWriteSet(projectRoot, task, options = {}) {
  if (Array.isArray(options.declaredWriteSet)) {
    return normalizeDeclaredWriteSet(projectRoot, options.declaredWriteSet);
  }
  const declared = [
    ...asArray((task || {}).canonical_write_set),
    ...asArray((((task || {}).stage_execution || {}).write_set)),
    ...asArray((task || {}).result_write_set),
    ...asArray((task || {}).write_set),
    ...canonicalRootsForTask(task),
  ];
  return normalizeDeclaredWriteSet(projectRoot, declared);
}

function unionDeclaredWriteSets(projectRoot, ...writeSets) {
  return Array.from(new Set(writeSets.flatMap(writeSet => normalizeDeclaredWriteSet(projectRoot, writeSet)))).sort();
}

function normalizeDeclaredWriteSet(projectRoot, declared) {
  if (!Array.isArray(declared) || declared.length === 0) return [];
  try {
    return Array.from(new Set(normalizeTargets(projectRoot, declared).filter(isCanonicalTarget))).sort();
  } catch (_) {
    return [];
  }
}

function canonicalRootsForTask(task) {
  if (SHORT_WORKFLOW_TYPES.has(String((task || {}).workflow_type || ''))) return SHORT_WRITE_FORMAL_ASSETS;
  return [];
}

function snapshotCanonicalFiles(root, declaredWriteSet) {
  const files = {};
  if (declaredWriteSet.length === 0) return files;
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const absolute = path.join(directory, entry.name);
      const relative = relativePosix(root, absolute);
      const stat = fs.lstatSync(absolute);
      if (stat.isSymbolicLink()) continue;
      if (stat.isDirectory()) {
        if (relative === '.git' || relative.startsWith('.git/')) continue;
        visit(absolute);
      } else if (stat.isFile() && isCanonicalTarget(relative) && declaredWriteSet.some((rule) => writeSetAllows(rule, relative))) {
        files[relative] = hashFile(absolute);
      }
    }
  };
  visit(root);
  return files;
}

function snapshotBaselineFiles(root, declaredWriteSet) {
  const files = snapshotCanonicalFiles(root, declaredWriteSet);
  for (const rule of declaredWriteSet) {
    if (!rule.endsWith('/**') && !(rule in files)) files[rule] = null;
  }
  return files;
}

function reconcileChangedPaths(root, task, baseline, changedPaths, current) {
  const accepted = acceptedHashesByTarget(root, task, baseline);
  const acceptedPaths = [];
  const unmanagedPaths = [];
  for (const target of changedPaths) {
    const currentHash = current[target] || null;
    if (currentHash && accepted.get(target) === currentHash) acceptedPaths.push(target);
    else unmanagedPaths.push(target);
  }
  return { changedPaths, acceptedPaths, unmanagedPaths };
}

function acceptedHashesByTarget(root, task, baseline) {
  const accepted = new Map();
  for (const receipt of listAcceptedReceipts(root)) {
    if (!receiptBelongsToBaseline(root, task, baseline, receipt)) continue;
    try {
      const target = normalizeTargets(root, [receipt.target])[0];
      if (!isCanonicalTarget(target)) continue;
      const acceptedAt = new Date(receipt.accepted_at).getTime();
      const existing = accepted.get(target);
      if (!existing || acceptedAt > existing.accepted_at) {
        accepted.set(target, { after_hash: receipt.after_hash, accepted_at: acceptedAt });
      }
    } catch (_) {
      // An invalid historical receipt remains readable but cannot reconcile a current file.
    }
  }
  return new Map([...accepted.entries()].map(([target, value]) => [target, value.after_hash]));
}

function listAcceptedReceipts(root) {
  const commitsDir = path.join(root, '追踪', 'story-system', 'commits');
  if (!fs.existsSync(commitsDir)) return [];
  return fs.readdirSync(commitsDir, { withFileTypes: true }).flatMap((entry) => {
    if (!entry.isFile() || !entry.name.endsWith('.json')) return [];
    try {
      const commit = readJson(path.join(commitsDir, entry.name));
      if (!commit || commit.status !== 'accepted' || !Array.isArray(commit.artifacts)) return [];
      return commit.artifacts
        .filter((artifact) => artifact && artifact.target && /^sha256:[a-f0-9]{64}$/i.test(String(artifact.after_hash || '')))
        .map((artifact) => ({
          workflow_id: String(commit.workflow_id || ''),
          accepted_at: String(commit.accepted_at || ''),
          target: String(artifact.target),
          after_hash: String(artifact.after_hash).toLowerCase(),
        }));
    } catch (_) {
      return [];
    }
  });
}

function receiptBelongsToBaseline(root, task, baseline, receipt) {
  const acceptedAt = new Date(receipt.accepted_at).getTime();
  const capturedAt = new Date((baseline || {}).captured_at || '').getTime();
  const workflowId = String((task || {}).workflow_id || '');
  if (String((baseline || {}).workflow_id || '') !== workflowId) return false;
  if (!Number.isFinite(acceptedAt) || !Number.isFinite(capturedAt) || acceptedAt <= capturedAt) return false;
  if (receipt.workflow_id === workflowId) return true;
  const familyId = String((baseline || {}).task_family_id || (task || {}).task_family_id || '');
  if (!familyId) return false;
  const family = readTaskFamily(root, familyId);
  return Boolean(family && String(family.head_workflow_id || '') === receipt.workflow_id);
}

function taskFile(root, task, filename) {
  const relativeDir = String((task || {}).task_dir || '').replace(/\\/g, '/').replace(/^\.\//, '');
  if (!relativeDir || path.isAbsolute(relativeDir) || relativeDir.split('/').includes('..')) {
    throw new Error('canonical write audit requires a safe task_dir');
  }
  const resolvedRoot = fs.realpathSync(root);
  const directory = path.resolve(resolvedRoot, ...relativeDir.split('/'));
  const existingParent = nearestExistingParent(directory);
  const realParent = fs.realpathSync(existingParent);
  if (!isInside(resolvedRoot, realParent) || !isInside(resolvedRoot, directory)) {
    throw new Error('canonical write audit requires a safe task_dir');
  }
  return path.join(directory, filename);
}

function nearestExistingParent(file) {
  let current = file;
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) throw new Error('canonical write audit requires a safe task_dir');
    current = parent;
  }
  return current;
}

function isInside(root, candidate) {
  return candidate === root || candidate.startsWith(`${root}${path.sep}`);
}

function writeSetAllows(rule, target) {
  if (rule.endsWith('/**')) {
    const prefix = rule.slice(0, -3);
    return target === prefix || target.startsWith(`${prefix}/`);
  }
  return target === rule;
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function relativePosix(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function asArray(value) {
  return Array.isArray(value) ? value.filter(Boolean) : [];
}

function changedCanonicalPaths(baseline, current) {
  return Array.from(new Set([...Object.keys(baseline || {}), ...Object.keys(current || {})]))
    .filter((target) => String((baseline || {})[target] || '') !== String((current || {})[target] || ''))
    .sort();
}

function sameSnapshot(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function validTimestamp(value) {
  return Number.isFinite(new Date(value || '').getTime());
}

function emptyAudit(declaredWriteSet, reason) {
  return {
    schemaVersion: '1.0.0',
    status: 'ok',
    reason,
    declared_write_set: declaredWriteSet,
    changed_paths: [],
    accepted_paths: [],
    unmanaged_paths: [],
  };
}

module.exports = {
  acceptValidatedStageWrites,
  auditCanonicalWrites,
  captureCanonicalBaseline,
};
