'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {
  acquireBookWriteLease,
  acquireChapterWriteLease,
  appendJsonl,
  atomicWriteJson,
} = require('./workflow-state-store');
const { resolveTaskAuthority } = require('./workflow-task-authority');
const { assertCanonicalWriteAllowed } = require('./canonical-write-policy');
const { readTaskFamily } = require('./task-family-store');
const { normalizePromiseDeltas, projectPromiseDeltas } = require('./promise-projection');

const REQUIRED_GATES = ['output_health', 'prose_quality', 'story_drift'];
const MEMORY_SOURCE_TARGETS = new Set([
  '追踪/角色状态.md',
  '追踪/角色身份对照表.md',
  '追踪/伏笔.md',
  '追踪/上下文.md',
]);

function prepareTransaction(projectRoot, manifestFile) {
  const root = path.resolve(projectRoot);
  const manifestPath = resolveInside(root, manifestFile, 'manifest');
  const input = readJson(manifestPath);
  validateManifest(input);

  const transactionId = createId('tx');
  const transactionDir = path.join(root, '追踪', 'story-system', 'transactions', transactionId);
  const stagedDir = path.join(transactionDir, 'staged');
  fs.mkdirSync(stagedDir, { recursive: true });

  const artifacts = input.artifacts.map((artifact, index) => {
    const stagedSource = resolveInside(root, artifact.staged, 'staged artifact');
    const target = resolveInside(root, artifact.target, 'target');
    assertRegularFile(stagedSource, artifact.required !== false);
    if (fs.existsSync(target) && !fs.statSync(target).isFile()) {
      throw failure('blocked_invalid_target', `target is not a regular file: ${artifact.target}`);
    }
    const archived = path.join(stagedDir, `${String(index + 1).padStart(3, '0')}-${safeBasename(stagedSource)}`);
    fs.copyFileSync(stagedSource, archived);
    return {
      role: String(artifact.role || 'artifact'),
      required: artifact.required !== false,
      staged: relativePosix(root, archived),
      source_staged: relativePosix(root, stagedSource),
      target: relativePosix(root, target),
      content_hash: hashFile(archived),
      before_hash: fs.existsSync(target) ? hashFile(target) : null,
      before_exists: fs.existsSync(target),
    };
  });

  const transaction = {
    schemaVersion: '1.0.0',
    transaction_id: transactionId,
    status: 'prepared',
    project_root: root,
    workflow_id: String(input.workflow_id || ''),
    source_kind: 'canonical',
    migration: null,
    provenance: resolveTransactionProvenance(root, input),
    volume: String(input.volume),
    chapter: Number(input.chapter),
    source_manifest: relativePosix(root, manifestPath),
    gates: input.gates,
    artifacts,
    facts: normalizeManifestFacts(input.facts),
    promise_deltas: normalizePromiseDeltas(input.promise_deltas),
    prepared_at: new Date().toISOString(),
  };
  atomicWriteJson(path.join(transactionDir, 'transaction.json'), transaction);
  return {
    status: 'prepared',
    transaction_id: transactionId,
    transaction_file: path.join(transactionDir, 'transaction.json'),
    artifact_count: artifacts.length,
  };
}

function acceptTransaction(projectRoot, transactionRef) {
  const root = path.resolve(projectRoot);
  const transactionFile = transactionPath(root, transactionRef);
  const release = acquireBookWriteLease(root, `chapter-commit:${path.basename(path.dirname(transactionFile))}`);
  let releaseChapter = null;
  try {
    const transaction = readJson(transactionFile);
    if (transaction.status === 'accepted' && transaction.commit_id) {
      return acceptedOutput(root, transaction.commit_id, true);
    }
    if (transaction.status !== 'prepared') {
      throw failure('blocked_transaction_state', `transaction is ${transaction.status || 'unknown'}, expected prepared`);
    }
    releaseChapter = acquireChapterWriteLease(root, {
      volume: transaction.volume,
      chapter: transaction.chapter,
    }, `chapter-commit:${transaction.transaction_id}`);
    assertCanonicalWriteAllowed(root, transaction.artifacts.map(artifact => artifact.target), {
      transactionId: transaction.transaction_id,
    });
    validatePreparedArtifacts(root, transaction.artifacts);
    validateTransactionProvenance(root, transaction);

    const transactionDir = path.dirname(transactionFile);
    const backupDir = path.join(transactionDir, 'backup');
    fs.mkdirSync(backupDir, { recursive: true });
    const applied = [];
    let writeCount = 0;
    let commit = null;
    let commitFile = '';
    try {
      for (let index = 0; index < transaction.artifacts.length; index += 1) {
        const artifact = transaction.artifacts[index];
        const target = resolveInside(root, artifact.target, 'target');
        const staged = resolveInside(root, artifact.staged, 'staged artifact');
        const backup = path.join(backupDir, `${String(index + 1).padStart(3, '0')}-${safeBasename(target)}`);
        if (artifact.before_exists) fs.copyFileSync(target, backup);
        atomicWriteBuffer(target, fs.readFileSync(staged));
        applied.push({ artifact, target, backup });
        writeCount += 1;
        const forcedFailure = Number(process.env.NOVEL_ASSISTANT_TEST_FAIL_AFTER_WRITES || 0);
        if (forcedFailure > 0 && writeCount >= forcedFailure) throw new Error('forced write failure for transaction rollback test');
      }

      const commitId = createCommitId(transaction);
      commitFile = commitPath(root, commitId);
      if (fs.existsSync(commitFile)) throw failure('blocked_commit_exists', `commit already exists: ${commitId}`);
      commit = {
        schemaVersion: '1.0.0',
        commit_id: commitId,
        transaction_id: transaction.transaction_id,
        status: 'accepted',
        workflow_id: transaction.workflow_id,
        source_kind: 'canonical',
        migration: null,
        provenance: transaction.provenance,
        acceptance_status: 'accepted',
        volume: transaction.volume,
        chapter: transaction.chapter,
        gates: transaction.gates,
        artifacts: transaction.artifacts.map(artifact => ({
          role: artifact.role,
          target: artifact.target,
          before_hash: artifact.before_hash,
          content_hash: artifact.content_hash,
          after_hash: artifact.content_hash,
        })),
        facts: normalizeManifestFacts(transaction.facts),
        promise_deltas: normalizePromiseDeltas(transaction.promise_deltas),
        memory_sources: transaction.artifacts.map(item => item.target).filter(isMemorySource),
        accepted_at: new Date().toISOString(),
      };
      atomicWriteJson(commitFile, commit);
      if (process.env.NOVEL_ASSISTANT_TEST_FAIL_AFTER_COMMIT === '1') throw new Error('forced transaction persistence failure after commit');
      transaction.status = 'accepted';
      transaction.commit_id = commitId;
      transaction.accepted_at = commit.accepted_at;
      atomicWriteJson(transactionFile, transaction);
    } catch (error) {
      if (commitFile) fs.rmSync(commitFile, { force: true });
      rollbackApplied(applied);
      const latest = readJson(transactionFile);
      latest.status = 'rolled_back';
      latest.rolled_back_at = new Date().toISOString();
      latest.failure = String(error && error.message ? error.message : error);
      atomicWriteJson(transactionFile, latest);
      if (error && error.status) throw error;
      throw failure('rolled_back', latest.failure);
    }

    let projection = projectCommit(root, commit);
    try {
      if (process.env.NOVEL_ASSISTANT_TEST_FAIL_PROJECTION_LOG === '1') throw new Error('forced projection log failure');
      appendJsonl(path.join(root, '追踪', 'story-system', 'projection-log.jsonl'), projection);
    } catch (error) {
      projection = {
        schemaVersion: '1.0.0',
        commit_id: commit.commit_id,
        sources: commit.memory_sources || [],
        status: 'projection_failed',
        error: String(error && error.message ? error.message : error),
        projected_at: new Date().toISOString(),
      };
    }
    return {
      status: projection.status === 'projection_failed' ? 'accepted_with_projection_debt' : 'accepted',
      commit_id: commit.commit_id,
      commit_file: commitFile,
      projection_status: projection.status,
      already_accepted: false,
    };
  } finally {
    if (releaseChapter) releaseChapter();
    release();
  }
}

function inspectChapter(projectRoot, volume, chapter) {
  const root = path.resolve(projectRoot);
  const commitsDir = path.join(root, '追踪', 'story-system', 'commits');
  const commits = listJson(commitsDir)
    .map(file => ({ file, value: readJson(file) }))
    .filter(item => item.value.volume === String(volume) && Number(item.value.chapter) === Number(chapter))
    .sort((a, b) => String(b.value.accepted_at).localeCompare(String(a.value.accepted_at)));
  return {
    status: 'ok',
    volume: String(volume),
    chapter: Number(chapter),
    commit_count: commits.length,
    latest_commit: commits[0] ? commits[0].value : null,
    latest_commit_file: commits[0] ? commits[0].file : null,
  };
}

function listAcceptedCommitArtifacts(projectRoot) {
  const root = path.resolve(projectRoot);
  const commitsDir = path.join(root, '追踪', 'story-system', 'commits');
  return listJson(commitsDir).flatMap((file) => {
    let commit;
    try {
      commit = readJson(file);
    } catch (_) {
      return [];
    }
    if (!commit || commit.status !== 'accepted' || !Array.isArray(commit.artifacts)) return [];
    return commit.artifacts
      .filter((artifact) => artifact && artifact.target && /^sha256:[a-f0-9]{64}$/i.test(String(artifact.after_hash || '')))
      .map((artifact) => ({
        commit_id: String(commit.commit_id || ''),
        transaction_id: String(commit.transaction_id || ''),
        target: String(artifact.target),
        after_hash: String(artifact.after_hash).toLowerCase(),
      }));
  });
}

function replayProjection(projectRoot, commitRef) {
  const root = path.resolve(projectRoot);
  const commitFile = resolveCommit(root, commitRef);
  const commit = readJson(commitFile);
  for (const artifact of commit.artifacts || []) {
    const target = resolveInside(root, artifact.target, 'target');
    if (!fs.existsSync(target) || hashFile(target) !== artifact.after_hash) {
      throw failure('blocked_commit_drift', `accepted artifact changed: ${artifact.target}`);
    }
  }
  const before = latestProjection(root, commit.commit_id);
  if (before && ['projection_current', 'projection_not_required'].includes(before.status)) {
    return { status: 'projection_current', commit_id: commit.commit_id, projection: before };
  }
  const projection = projectCommit(root, commit);
  appendJsonl(path.join(root, '追踪', 'story-system', 'projection-log.jsonl'), projection);
  if (projection.status === 'projection_failed') {
    throw failure('blocked_projection_failed', projection.error || 'projection failed');
  }
  return {
    status: before ? 'projection_repaired' : 'projection_current',
    commit_id: commit.commit_id,
    projection,
  };
}

function validateManifest(input) {
  if (!input || typeof input !== 'object') throw failure('blocked_invalid_manifest', 'manifest must be an object');
  if (!String(input.volume || '').trim()) throw failure('blocked_invalid_manifest', 'volume is required');
  if (!Number.isInteger(Number(input.chapter)) || Number(input.chapter) < 1) throw failure('blocked_invalid_manifest', 'chapter must be a positive integer');
  if (!Array.isArray(input.artifacts) || input.artifacts.length === 0) throw failure('blocked_invalid_manifest', 'artifacts are required');
  const targets = new Set();
  for (const artifact of input.artifacts) {
    if (!artifact || !String(artifact.staged || '').trim() || !String(artifact.target || '').trim()) {
      throw failure('blocked_invalid_manifest', 'every artifact requires staged and target');
    }
    const target = String(artifact.target).replace(/\\/g, '/');
    if (targets.has(target)) throw failure('blocked_invalid_manifest', `duplicate target: ${target}`);
    targets.add(target);
  }
  for (const gate of REQUIRED_GATES) {
    if (!input.gates || input.gates[gate] !== 'pass') {
      throw failure('blocked_gate_failed', `required gate did not pass: ${gate}`);
    }
  }
  if (isLegacyMarker(input)) {
    throw failure('blocked_untrusted_legacy_migration', 'chapter manifests cannot authorize legacy canonical writes; migrate the project to a durable task first');
  }
  if (input.provenance) normalizeProvenance(input.provenance, input.workflow_id);
}

function normalizeProvenance(value, workflowId) {
  if (!value || typeof value !== 'object') throw failure('blocked_invalid_provenance', 'provenance must be an object');
  const normalized = {
    task_family_id: String(value.task_family_id || ''),
    workflow_id: String(value.workflow_id || workflowId || ''),
    branch_id: String(value.branch_id || value.workflow_id || workflowId || ''),
    stage_attempt_id: String(value.stage_attempt_id || ''),
    acceptance_status: String(value.acceptance_status || 'accepted'),
  };
  if (!normalized.task_family_id || !normalized.workflow_id || !normalized.branch_id || !normalized.stage_attempt_id) {
    throw failure('blocked_invalid_provenance', 'task-family provenance requires task_family_id, workflow_id, branch_id and stage_attempt_id');
  }
  if (normalized.acceptance_status !== 'accepted') throw failure('blocked_invalid_provenance', 'chapter commit provenance acceptance_status must be accepted');
  return normalized;
}

function resolveTransactionProvenance(root, input) {
  const declared = input.provenance ? normalizeProvenance(input.provenance, input.workflow_id) : null;
  const workflowId = String((declared && declared.workflow_id) || input.workflow_id || '');
  if (input.workflow_id && declared && String(input.workflow_id) !== declared.workflow_id) {
    throw failure('blocked_task_provenance_mismatch', 'manifest workflow_id conflicts with declared provenance');
  }
  const resolved = resolveTaskAuthority(root, workflowId);
  if (resolved.status !== 'ok') throw failure(resolved.status, resolved.message || `durable task snapshot is unavailable: ${workflowId}`);
  const current = resolved.task;
  const authoritative = normalizeProvenance({
    task_family_id: current.task_family_id,
    workflow_id: current.workflow_id,
    branch_id: current.branch_id || current.workflow_id,
    stage_attempt_id: String(((current.stage_execution || {}).stage_attempt_id) || ''),
    acceptance_status: 'accepted',
  }, workflowId);
  assertTaskProvenance(current, declared || authoritative);
  return authoritative;
}

function validateTransactionProvenance(root, transaction) {
  if (isLegacyMarker(transaction)) throw failure('blocked_untrusted_legacy_migration', 'prepared legacy chapter transactions are not trusted');
  const provenance = transaction.provenance;
  if (!provenance) throw failure('blocked_invalid_provenance', 'canonical chapter transaction requires durable provenance');
  const resolved = resolveTaskAuthority(root, provenance.workflow_id);
  if (resolved.status !== 'ok') throw failure(resolved.status, resolved.message || 'durable task snapshot is unavailable');
  assertTaskProvenance(resolved.task, provenance);
  const family = readTaskFamily(root, provenance.task_family_id);
  if (!family) throw failure('blocked_task_family_missing', `task family not found: ${provenance.task_family_id}`);
  if (String(family.head_workflow_id || '') !== String(provenance.workflow_id || '')) {
    throw failure('blocked_non_head_branch_projection', '只有任务族主分支可以提交正文与状态投影。');
  }
}

function assertTaskProvenance(task, provenance) {
  const execution = task && task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const expected = {
    workflow_id: String((task || {}).workflow_id || ''),
    task_family_id: String((task || {}).task_family_id || ''),
    branch_id: String((task || {}).branch_id || (task || {}).workflow_id || ''),
    stage_attempt_id: String(execution.stage_attempt_id || ''),
  };
  const actual = {
    workflow_id: String((provenance || {}).workflow_id || ''),
    task_family_id: String((provenance || {}).task_family_id || ''),
    branch_id: String((provenance || {}).branch_id || ''),
    stage_attempt_id: String((provenance || {}).stage_attempt_id || ''),
  };
  const mismatches = Object.keys(expected).filter(field => !expected[field] || expected[field] !== actual[field]);
  if (mismatches.length) {
    throw failure('blocked_task_provenance_mismatch', `canonical provenance does not match durable task stage execution: ${mismatches.join(', ')}`);
  }
}

function isLegacyMarker(value) {
  return Boolean(value && (
    String(value.source_kind || '') === 'legacy'
    || (value.migration && value.migration.source_kind === 'legacy')
  ));
}

function validatePreparedArtifacts(root, artifacts) {
  for (const artifact of artifacts || []) {
    const staged = resolveInside(root, artifact.staged, 'staged artifact');
    const target = resolveInside(root, artifact.target, 'target');
    assertRegularFile(staged, artifact.required);
    if (hashFile(staged) !== artifact.content_hash) throw failure('blocked_staged_artifact_changed', `staged artifact changed: ${artifact.staged}`);
    const currentHash = fs.existsSync(target) && fs.statSync(target).isFile() ? hashFile(target) : null;
    if (currentHash !== artifact.before_hash) throw failure('blocked_write_conflict', `target changed after prepare: ${artifact.target}`);
  }
}

function projectCommit(root, commit) {
  const base = {
    schemaVersion: '1.0.0',
    commit_id: commit.commit_id,
    sources: commit.memory_sources || [],
    facts: normalizeManifestFacts(commit.facts),
    promise_deltas: normalizePromiseDeltas(commit.promise_deltas),
    provenance: commit.provenance || {},
    projected_at: new Date().toISOString(),
  };
  if (!base.sources.length && !base.facts.length && !base.promise_deltas.length) return { ...base, status: 'projection_not_required' };
  try {
    const projector = require('./memory-projection');
    const result = base.sources.length
      ? projector.projectSources(root, base.sources, { sourceKind: 'canonical', commitId: commit.commit_id, provenance: base.provenance, leaseHeld: true })
      : { status: 'not_required', projected_count: 0 };
    const factResult = base.facts.length
      ? projector.projectAcceptedFacts(root, { status: 'accepted', commit_id: commit.commit_id }, { leaseHeld: true })
      : { factIds: [], eventFile: path.join(root, '追踪', 'memory', 'facts.jsonl') };
    const promiseResult = base.promise_deltas.length
      ? projectPromiseDeltas(root, commit)
      : { status: 'not_required', projected_count: 0 };
    return { ...base, status: 'projection_current', result, fact_result: factResult, promise_result: promiseResult };
  } catch (error) {
    return { ...base, status: 'projection_failed', error: String(error && error.message ? error.message : error) };
  }
}

function normalizeManifestFacts(value) {
  return Array.isArray(value) ? value.filter(item => item && typeof item === 'object' && !Array.isArray(item)) : [];
}

function latestProjection(root, commitId) {
  const file = path.join(root, '追踪', 'story-system', 'projection-log.jsonl');
  if (!fs.existsSync(file)) return null;
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line)).filter(item => item.commit_id === commitId).pop() || null;
}

function rollbackApplied(applied) {
  for (const item of [...applied].reverse()) {
    if (item.artifact.before_exists && fs.existsSync(item.backup)) atomicWriteBuffer(item.target, fs.readFileSync(item.backup));
    else fs.rmSync(item.target, { force: true });
  }
}

function transactionPath(root, ref) {
  const value = String(ref || '');
  if (!/^[A-Za-z0-9._-]+$/.test(value)) throw failure('blocked_invalid_transaction', 'transaction must be an id');
  return path.join(root, '追踪', 'story-system', 'transactions', value, 'transaction.json');
}

function commitPath(root, id) {
  return path.join(root, '追踪', 'story-system', 'commits', `${id}.json`);
}

function resolveCommit(root, ref) {
  const value = String(ref || '').replace(/\.json$/, '');
  if (!/^[A-Za-z0-9._-]+$/.test(value)) throw failure('blocked_invalid_commit', 'commit must be an id');
  const file = commitPath(root, value);
  if (!fs.existsSync(file)) throw failure('blocked_commit_missing', `commit not found: ${value}`);
  return file;
}

function acceptedOutput(root, commitId, alreadyAccepted) {
  const commit = readJson(commitPath(root, commitId));
  const projection = latestProjection(root, commitId);
  const projectionCurrent = projection && ['projection_current', 'projection_not_required'].includes(projection.status);
  return {
    status: projectionCurrent ? 'accepted' : 'accepted_with_projection_debt',
    commit_id: commitId,
    commit_file: commitPath(root, commitId),
    projection_status: projection ? projection.status : 'projection_unknown',
    already_accepted: alreadyAccepted,
  };
}

function resolveInside(root, input, label) {
  const resolvedRoot = path.resolve(root);
  const absolute = path.isAbsolute(String(input || '')) ? path.resolve(String(input)) : path.resolve(resolvedRoot, String(input || ''));
  if (absolute === resolvedRoot || !absolute.startsWith(`${resolvedRoot}${path.sep}`)) throw failure('blocked_unsafe_path', `${label} escapes project root: ${input}`);
  const realRoot = fs.realpathSync(resolvedRoot);
  let existingAncestor = absolute;
  while (!fs.existsSync(existingAncestor)) {
    const parent = path.dirname(existingAncestor);
    if (parent === existingAncestor) break;
    existingAncestor = parent;
  }
  const realAncestor = fs.realpathSync(existingAncestor);
  if (realAncestor !== realRoot && !realAncestor.startsWith(`${realRoot}${path.sep}`)) {
    throw failure('blocked_unsafe_path', `${label} escapes project root through symlink: ${input}`);
  }
  return absolute;
}

function assertRegularFile(file, required) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) throw failure('blocked_missing_artifact', `staged artifact missing: ${file}`);
  if (required && fs.statSync(file).size === 0) throw failure('blocked_empty_artifact', `required staged artifact is empty: ${file}`);
}

function atomicWriteBuffer(file, buffer) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  fs.writeFileSync(temp, buffer);
  fs.renameSync(temp, file);
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function readJson(file) {
  if (!fs.existsSync(file)) throw failure('blocked_missing_file', `file not found: ${file}`);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    if (error && error.status) throw error;
    throw failure('blocked_invalid_json', `invalid json: ${file}`);
  }
}

function readOptionalJson(file) {
  if (!fs.existsSync(file)) return null;
  return readJson(file);
}

function listJson(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter(name => name.endsWith('.json')).map(name => path.join(dir, name));
}

function createId(prefix) {
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '');
  return `${prefix}-${stamp}-${crypto.randomBytes(4).toString('hex')}`;
}

function createCommitId(transaction) {
  const volume = crypto.createHash('sha256').update(String(transaction.volume)).digest('hex').slice(0, 8);
  const chapter = String(transaction.chapter).padStart(3, '0');
  const digest = crypto.createHash('sha256').update(JSON.stringify({
    artifacts: transaction.artifacts,
    facts: normalizeManifestFacts(transaction.facts),
    promise_deltas: normalizePromiseDeltas(transaction.promise_deltas),
  })).digest('hex').slice(0, 10);
  return `chapter-v${volume}-${chapter}-${digest}`;
}

function safeBasename(file) {
  return path.basename(file).replace(/[^A-Za-z0-9._\-\u4e00-\u9fff]/g, '_');
}

function relativePosix(root, file) {
  return path.relative(root, file).split(path.sep).join('/');
}

function isMemorySource(target) {
  const normalized = String(target).replace(/\\/g, '/');
  return MEMORY_SOURCE_TARGETS.has(normalized)
    || /^追踪\/交接包\/.+\.md$/.test(normalized)
    || /^追踪\/卷交接\/.+\.md$/.test(normalized)
    || normalized === '追踪/memory/active-cast.json'
    || normalized === '追踪/memory/memory-suggestions.jsonl';
}

function failure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

module.exports = {
  acceptTransaction,
  inspectChapter,
  listAcceptedCommitArtifacts,
  prepareTransaction,
  replayProjection,
};
