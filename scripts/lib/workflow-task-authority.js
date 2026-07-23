'use strict';

const fs = require('fs');
const path = require('path');

const WORKFLOW_ID = /^[A-Za-z0-9._-]+$/;

function resolveTaskAuthority(projectRoot, workflowId) {
  const root = path.resolve(projectRoot || '');
  const id = String(workflowId || '');
  if (!root || !WORKFLOW_ID.test(id)) return missing('invalid workflow id');
  const taskFile = path.join(root, '追踪', 'workflow', 'tasks', id, 'task.json');
  const task = readJson(taskFile);
  if (!task || task.__error || String(task.workflow_id || '') !== id || !isSafeTaskDir(root, id, task.task_dir)) {
    return missing(`durable task snapshot is unavailable: ${id}`, taskFile);
  }
  return { status: 'ok', task, taskFile, source: 'task_snapshot' };
}

// `current-task.json` is deliberately not consulted here. It is a UI focus
// pointer and may change while a background runner still owns another task.
function resolveTaskContext(projectRoot, workflowId, taskDir = '') {
  const resolved = resolveTaskAuthority(projectRoot, workflowId);
  if (resolved.status !== 'ok') return resolved;
  const requestedDir = String(taskDir || '').trim();
  if (!requestedDir) return resolved;
  const expected = normalizeTaskDir(resolved.task.workflow_id, resolved.task.task_dir);
  const requested = normalizeTaskDir(resolved.task.workflow_id, requestedDir);
  if (requested !== expected) {
    return {
      status: 'blocked_task_authority_mismatch',
      task: null,
      taskFile: resolved.taskFile,
      source: 'task_snapshot',
      message: `requested task directory does not belong to workflow ${resolved.task.workflow_id}`,
      expected_task_dir: expected,
      requested_task_dir: requested,
    };
  }
  return resolved;
}

function readFocusedTask(projectRoot) {
  const root = path.resolve(projectRoot || '');
  const pointerFile = path.join(root, '追踪', 'workflow', 'current-task.json');
  const pointer = readJson(pointerFile);
  if (!pointer || pointer.__error || !String(pointer.workflow_id || '')) {
    return { pointer: pointer || null, authority: missing('focus pointer is unavailable') };
  }
  const authority = resolveTaskAuthority(root, pointer.workflow_id);
  if (authority.status !== 'ok') return { pointer, authority };
  const task = authority.task;
  const expectedTaskDir = normalizeTaskDir(task.workflow_id, task.task_dir);
  const pointerTaskDir = normalizeTaskDir(pointer.workflow_id, pointer.task_dir);
  const pointerFindings = [];
  if (pointerTaskDir !== expectedTaskDir) pointerFindings.push('task_dir_mismatch');
  if (Number(pointer.state_version) !== Number(task.state_version)) pointerFindings.push('state_version_mismatch');
  // The focus pointer is a UI convenience, not task authority. A stale pointer
  // must never make a durable task un-runnable; callers can safely refresh it
  // on their next write while all lifecycle reads remain snapshot-backed.
  return {
    pointer,
    authority,
    pointer_status: pointerFindings.length ? 'stale' : 'current',
    pointer_findings: pointerFindings,
  };
}

function writeFocusPointer(projectRoot, task) {
  const root = path.resolve(projectRoot || '');
  const workflowId = String((task || {}).workflow_id || '');
  if (!root || !WORKFLOW_ID.test(workflowId) || !isSafeTaskDir(root, workflowId, (task || {}).task_dir)) {
    const error = new Error('workflow focus pointer requires a safe durable task');
    error.code = 'WORKFLOW_TASK_AUTHORITY_INVALID';
    throw error;
  }
  const pointer = {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    task_dir: normalizeTaskDir(workflowId, task.task_dir),
    focused_at: new Date().toISOString(),
    state_version: Number(task.state_version) || 0,
  };
  atomicWriteJson(path.join(root, '追踪', 'workflow', 'current-task.json'), pointer);
  return pointer;
}

function mutateTaskAuthority(projectRoot, workflowId, expectedStateVersion, mutation, options = {}) {
  if (typeof mutation !== 'function') throw authorityError('WORKFLOW_TASK_MUTATION_INVALID', 'workflow task mutation requires a mutation function');
  const root = path.resolve(projectRoot || '');
  const id = String(workflowId || '');
  const expected = Number(expectedStateVersion);
  if (!root || !WORKFLOW_ID.test(id) || !Number.isInteger(expected) || expected < 0) {
    throw authorityError('WORKFLOW_TASK_MUTATION_INVALID', 'workflow task mutation requires projectRoot, workflowId, and expectedStateVersion');
  }
  const store = require('./workflow-state-store');
  const release = options.projectLockHeld ? null : store.acquireProjectLock(root, options.owner || 'workflow-task-mutation');
  try {
    const resolved = resolveTaskAuthority(root, id);
    if (resolved.status !== 'ok') throw authorityError('WORKFLOW_TASK_AUTHORITY_MISSING', resolved.message || 'durable task snapshot is unavailable');
    if (Number(resolved.task.state_version || 0) !== expected) throw authorityError('WORKFLOW_TASK_CONFLICT', 'durable task changed before mutation');
    const draft = clone(resolved.task);
    const value = mutation(draft);
    const next = value === undefined ? draft : value;
    if (!next || typeof next !== 'object' || String(next.workflow_id || '') !== id || !isSafeTaskDir(root, id, next.task_dir)) {
      throw authorityError('WORKFLOW_TASK_CONFLICT', 'mutation must preserve the expected workflow_id and task directory');
    }
    next.state_version = expected + 1;
    next.updated_at = new Date().toISOString();
    atomicWriteJson(resolved.taskFile, next);
    const focused = readFocusedTask(root);
    if (focused.pointer && String(focused.pointer.workflow_id || '') === id) writeFocusPointer(root, next);
    return next;
  } finally {
    if (release) release();
  }
}

function createTaskAuthority(projectRoot, task, options = {}) {
  const root = path.resolve(projectRoot || '');
  const id = String((task || {}).workflow_id || '');
  if (!root || !WORKFLOW_ID.test(id)) throw authorityError('WORKFLOW_TASK_MUTATION_INVALID', 'workflow task creation requires a workflow id');
  const taskDir = normalizeTaskDir(id, task.task_dir);
  const next = { ...clone(task), task_dir: taskDir, state_version: Number(task.state_version || 0) + 1, updated_at: new Date().toISOString() };
  if (!isSafeTaskDir(root, id, next.task_dir)) throw authorityError('WORKFLOW_TASK_MUTATION_INVALID', 'workflow task directory is unsafe');
  const file = path.join(root, next.task_dir, 'task.json');
  if (fs.existsSync(file)) throw authorityError('WORKFLOW_TASK_CONFLICT', `durable task already exists for ${id}`);
  atomicWriteJson(file, next);
  if (options.focus !== false) writeFocusPointer(root, next);
  return next;
}

function isSafeTaskDir(root, workflowId, taskDir) {
  const relative = normalizeTaskDir(workflowId, taskDir);
  const expected = path.posix.join('追踪', 'workflow', 'tasks', workflowId);
  if (relative !== expected) return false;
  const resolved = path.resolve(root, relative);
  return resolved.startsWith(`${path.resolve(root)}${path.sep}`);
}

function normalizeTaskDir(workflowId, taskDir) {
  const expected = path.posix.join('追踪', 'workflow', 'tasks', String(workflowId || ''));
  const value = String(taskDir || expected).replace(/\\/g, '/').replace(/^\.\//, '');
  return value || expected;
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(temp, file);
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function missing(message, taskFile = '') {
  return { status: 'blocked_task_authority_missing', task: null, taskFile, source: 'task_snapshot', message };
}

function authorityError(code, message) {
  const error = new Error(message);
  error.code = code;
  error.status = code === 'WORKFLOW_TASK_AUTHORITY_MISSING' ? 'blocked_task_authority_missing' : undefined;
  return error;
}

module.exports = {
  createTaskAuthority,
  mutateTaskAuthority,
  readFocusedTask,
  resolveTaskAuthority,
  resolveTaskContext,
  writeFocusPointer,
};
