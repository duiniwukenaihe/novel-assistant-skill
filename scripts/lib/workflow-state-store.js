'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const CHAPTER_LEASE_GUARD_TTL_MS = 30 * 1000;
const CHAPTER_LEASE_GUARD_WAIT_MS = 5 * 1000;

function atomicWriteText(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  fs.writeFileSync(temp, text);
  fs.renameSync(temp, file);
}

function atomicWriteJson(file, value) {
  atomicWriteText(file, `${JSON.stringify(value, null, 2)}\n`);
}

function appendJsonl(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const fd = fs.openSync(file, 'a');
  try {
    fs.writeSync(fd, `${JSON.stringify(value)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function createWorkflowId(workflowType, now = new Date()) {
  const stamp = new Date(now).toISOString().replace(/\D/g, '').slice(0, 17);
  const type = String(workflowType || 'workflow').replace(/[^a-zA-Z0-9_-]/g, '_');
  return `wf-${stamp}-${type}-${crypto.randomBytes(4).toString('hex')}`;
}

function mutateTask(options) {
  const projectRoot = path.resolve(options.projectRoot || '');
  const workflowId = String(options.workflowId || '');
  const expectedStateVersion = Number(options.expectedStateVersion);
  if (!projectRoot || !workflowId || !Number.isInteger(expectedStateVersion) || expectedStateVersion < 0 || typeof options.mutation !== 'function') {
    const invalid = new Error('workflow task mutation requires projectRoot, workflowId, expectedStateVersion, and mutation');
    invalid.code = 'WORKFLOW_TASK_MUTATION_INVALID';
    throw invalid;
  }

  const authority = require('./workflow-task-authority');
  const release = options.projectLockHeld ? null : acquireProjectLock(projectRoot, options.owner || 'workflow-task-mutation');
  try {
    const next = options.replaceCurrent
      ? authority.createTaskAuthority(projectRoot, options.mutation({}), { focus: true })
      : authority.mutateTaskAuthority(projectRoot, workflowId, expectedStateVersion, options.mutation, { projectLockHeld: true, owner: options.owner });
    if (typeof options.renderMarkdown === 'function') {
      const focused = authority.readFocusedTask(projectRoot);
      if (focused.authority.status === 'ok' && String(focused.authority.task.workflow_id || '') === workflowId) {
        atomicWriteText(path.join(projectRoot, '追踪', 'workflow', 'current-task.md'), options.renderMarkdown(next));
      }
    }
    return next;
  } finally {
    if (release) release();
  }
}

function readJsonFile(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function assertTaskVersion(task, workflowId, expectedStateVersion, label) {
  if (!task || task.__error || String(task.workflow_id || '') !== workflowId || Number(task.state_version || 0) !== expectedStateVersion) {
    throw taskMutationConflict(`${label} changed before mutation`);
  }
}

function taskMutationConflict(message) {
  const conflict = new Error(message);
  conflict.code = 'WORKFLOW_TASK_CONFLICT';
  return conflict;
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value));
}

function acquireProjectLock(projectRoot, owner, ttlMs = 5 * 60 * 1000) {
  return acquireNamedProjectLock(projectRoot, {
    relativeDir: path.join('追踪', 'workflow'),
    lockName: '.workflow.lock',
    owner: owner || 'workflow-state-machine',
    ttlMs,
    errorCode: 'WORKFLOW_LOCKED',
    errorLabel: 'workflow lock',
  });
}

function acquireBookWriteLease(projectRoot, owner, ttlMs = 15 * 60 * 1000) {
  return acquireNamedProjectLock(projectRoot, {
    relativeDir: path.join('追踪', 'story-system'),
    lockName: '.write.lock',
    owner: owner || 'chapter-commit',
    ttlMs,
    errorCode: 'BOOK_WRITE_LOCKED',
    errorLabel: 'book write lease',
  });
}

function acquireChapterWriteLease(projectRoot, scope, owner, ttlMs = 15 * 60 * 1000) {
  const normalizedScope = normalizeChapterScope(scope);
  const file = chapterLeasePath(projectRoot, normalizedScope);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const token = crypto.randomBytes(16).toString('hex');
  const acquiredAt = new Date();
  const lease = {
    owner: String(owner || 'chapter-commit'),
    scope: normalizedScope,
    token,
    acquiredAt: acquiredAt.toISOString(),
    expiresAt: new Date(acquiredAt.getTime() + Number(ttlMs)).toISOString(),
  };
  withChapterLeaseGuard(file, () => {
    const current = readChapterLease(file);
    if (current && !isExpiredChapterLease(current)) throw chapterLeaseConflict(current);
    atomicWriteJson(file, lease);
  });
  let released = false;
  return Object.assign(() => {
    if (released) return false;
    released = true;
    return releaseChapterWriteLease(projectRoot, normalizedScope, token);
  }, { lease, file });
}

function releaseChapterWriteLease(projectRoot, scope, token) {
  const file = chapterLeasePath(projectRoot, normalizeChapterScope(scope));
  return withChapterLeaseGuard(file, () => {
    const current = readChapterLease(file);
    if (!current || current.token !== String(token || '')) return false;
    fs.rmSync(file, { force: true });
    return true;
  });
}

function chapterLeasePath(projectRoot, scope) {
  const normalizedScope = normalizeChapterScope(scope);
  const filename = `${normalizedScope.volume.replace(/[\\/]/g, '_')}-${normalizedScope.chapter}.json`;
  return path.join(path.resolve(projectRoot), '追踪', 'story-system', 'leases', filename);
}

function normalizeChapterScope(scope) {
  const volume = String((scope || {}).volume || '').trim();
  const chapter = Number((scope || {}).chapter);
  if (!volume || /[\\/]/.test(volume) || !Number.isInteger(chapter) || chapter < 1) {
    const invalid = new Error('chapter lease requires a volume and positive chapter');
    invalid.code = 'CHAPTER_LEASE_INVALID';
    throw invalid;
  }
  return { volume, chapter };
}

function readChapterLease(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function isExpiredChapterLease(lease) {
  const expiresAt = new Date((lease || {}).expiresAt || '').getTime();
  return !Number.isFinite(expiresAt) || expiresAt <= Date.now();
}

function withChapterLeaseGuard(file, operation) {
  const releaseGuard = acquireChapterLeaseGuard(file);
  try {
    return operation();
  } finally {
    releaseGuard();
  }
}

function acquireChapterLeaseGuard(file, ttlMs = CHAPTER_LEASE_GUARD_TTL_MS, waitMs = CHAPTER_LEASE_GUARD_WAIT_MS) {
  const guardDir = `${file}.guard`;
  fs.mkdirSync(path.dirname(guardDir), { recursive: true });
  const token = crypto.randomBytes(16).toString('hex');
  const deadline = Date.now() + waitMs;
  while (true) {
    try {
      fs.mkdirSync(guardDir);
      atomicWriteJson(path.join(guardDir, 'owner.json'), { token, acquiredAt: new Date().toISOString() });
      let released = false;
      return () => {
        if (released) return;
        released = true;
        const current = readChapterLeaseGuard(guardDir);
        if (current.token !== token) return;
        fs.rmSync(guardDir, { recursive: true, force: true });
      };
    } catch (error) {
      if (!error || error.code !== 'EEXIST') throw error;
      const current = readChapterLeaseGuard(guardDir);
      if (isStaleChapterLeaseGuard(current, ttlMs)) {
        const staleDir = `${guardDir}.stale-${process.pid}-${Date.now()}-${token}`;
        try {
          fs.renameSync(guardDir, staleDir);
          fs.rmSync(staleDir, { recursive: true, force: true });
          continue;
        } catch (staleError) {
          if (!staleError || !['ENOENT', 'EEXIST'].includes(staleError.code)) throw staleError;
          continue;
        }
      }
      if (Date.now() >= deadline) throw chapterLeaseConflict(null);
      sleep(5);
    }
  }
}

function readChapterLeaseGuard(guardDir) {
  let stat;
  try {
    stat = fs.statSync(guardDir);
  } catch (_) {
    return {};
  }
  try {
    return { ...JSON.parse(fs.readFileSync(path.join(guardDir, 'owner.json'), 'utf8')), modifiedAt: stat.mtimeMs };
  } catch (_) {
    return { modifiedAt: stat.mtimeMs };
  }
}

function isStaleChapterLeaseGuard(guard, ttlMs) {
  const acquiredAt = new Date((guard || {}).acquiredAt || '').getTime();
  const timestamp = Number.isFinite(acquiredAt) ? acquiredAt : Number((guard || {}).modifiedAt);
  return Number.isFinite(timestamp) && Date.now() - timestamp > ttlMs;
}

function chapterLeaseConflict(lease) {
  const conflict = new Error(`chapter lease is held by ${(lease || {}).owner || 'another process'}`);
  conflict.code = 'CHAPTER_LEASE_CONFLICT';
  conflict.status = 'blocked_chapter_lease_conflict';
  conflict.lease = lease || null;
  return conflict;
}

function sleep(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function acquireNamedProjectLock(projectRoot, options) {
  const baseDir = path.join(projectRoot, options.relativeDir);
  const lockDir = path.join(baseDir, options.lockName);
  fs.mkdirSync(baseDir, { recursive: true });

  try {
    fs.mkdirSync(lockDir);
  } catch (error) {
    if (!error || error.code !== 'EEXIST') throw error;
    const lock = readLock(lockDir);
    if (!isStaleLock(lock, options.ttlMs)) {
      const locked = new Error(`${options.errorLabel} is held by ${lock.owner || 'another process'}`);
      locked.code = options.errorCode;
      locked.lock = lock;
      throw locked;
    }
    fs.rmSync(lockDir, { recursive: true, force: true });
    fs.mkdirSync(lockDir);
  }

  const token = crypto.randomBytes(16).toString('hex');
  const metadata = {
    pid: process.pid,
    owner: options.owner,
    token,
    acquired_at: new Date().toISOString(),
  };
  atomicWriteJson(path.join(lockDir, 'owner.json'), metadata);
  let released = false;
  return () => {
    if (released) return;
    released = true;
    const current = readLock(lockDir);
    if (current.token && current.token !== token) return;
    fs.rmSync(lockDir, { recursive: true, force: true });
  };
}

function readLock(lockDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(lockDir, 'owner.json'), 'utf8'));
  } catch (_) {
    return { owner: 'unknown', acquired_at: '' };
  }
}

function isStaleLock(lock, ttlMs) {
  const acquired = new Date(lock.acquired_at || '').getTime();
  if (!Number.isFinite(acquired)) return false;
  return Date.now() - acquired > ttlMs;
}

function validateTaskState(task, projectRoot) {
  const findings = [];
  if (!task || typeof task !== 'object') return [{ code: 'invalid_task', message: 'task must be an object' }];
  const stage = String(task.current_stage || task.current_step || '');
  const completed = Array.isArray((task.machine || {}).completed_stages) ? task.machine.completed_stages.map(String) : [];
  const execution = task.stage_execution || {};

  if (new Set(completed).size !== completed.length) {
    findings.push({ code: 'duplicate_completed_stage', message: 'completed_stages contains duplicates' });
  }
  if (execution.status === 'running' && stage && completed.includes(stage)) {
    findings.push({ code: 'running_stage_already_completed', stage, message: 'current stage cannot be both running and completed' });
  }
  if (execution.status === 'running' && execution.stage_id && stage && String(execution.stage_id) !== stage) {
    findings.push({ code: 'running_stage_mismatch', stage, execution_stage: execution.stage_id, message: 'stage execution does not match current stage' });
  }
  const expected = execution.status === 'running'
    ? String(execution.expected_result_packet || (((task.runtime_guard || {}).checkpoint_policy || {}).expected_result_packet) || '')
    : String((((task.runtime_guard || {}).checkpoint_policy || {}).expected_result_packet) || '');
  const trusted = String((((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || '');
  if (expected && trusted && expected === trusted) {
    findings.push({ code: 'future_artifact_marked_trusted', path: expected, message: 'expected result packet cannot also be the last trusted artifact' });
  }
  if (task.state_version !== undefined && (!Number.isInteger(Number(task.state_version)) || Number(task.state_version) < 1)) {
    findings.push({ code: 'invalid_state_version', message: 'state_version must be a positive integer' });
  }
  const lifecycleCompleted = ['completed', 'closed'].includes(String(((task.lifecycle || {}).status) || task.status || ''));
  const acceptedPlan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : null;
  if (lifecycleCompleted && acceptedPlan
      && ['pending', 'accepted_pending_projection'].includes(String(acceptedPlan.projection_status || acceptedPlan.status || ''))) {
    findings.push({
      code: 'completed_with_unprojected_accepted_plan',
      message: 'completed workflow cannot retain an accepted plan that has not been projected to canonical assets and memory',
    });
  }
  const revisionQueue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  if (lifecycleCompleted && revisionQueue && String(revisionQueue.status || '') === 'running') {
    findings.push({
      code: 'completed_with_active_feedback_revision_queue',
      message: 'completed workflow cannot retain an active feedback revision queue',
    });
  }
  const bookRootRef = String(task.book_root || '.').trim();
  if (projectRoot && bookRootRef && !path.isAbsolute(bookRootRef)
    && path.resolve(projectRoot, bookRootRef) !== path.resolve(projectRoot)) {
    findings.push({ code: 'book_root_mismatch', message: 'task book_root relative reference does not resolve to project root' });
  }
  return findings;
}

module.exports = {
  acquireBookWriteLease,
  acquireChapterWriteLease,
  acquireNamedProjectLock,
  acquireProjectLock,
  appendJsonl,
  acquireChapterLeaseGuard,
  atomicWriteJson,
  atomicWriteText,
  chapterLeasePath,
  createWorkflowId,
  mutateTask,
  releaseChapterWriteLease,
  validateTaskState,
};
