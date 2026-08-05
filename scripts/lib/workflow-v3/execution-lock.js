'use strict';

const path = require('path');
const { acquireNamedProjectLock } = require('../workflow-state-store');

const EXECUTION_LOCK_TTL_MS = 5 * 60 * 1000;
const EXECUTION_CAPABILITY = Symbol('workflow-v3-execution-capability');
const ACTIVE_CAPABILITIES = new WeakSet();

function withWorkflowExecutionLock(projectRoot, owner, operation) {
  const rawRoot = String(projectRoot || '').trim();
  if (!rawRoot) throw new Error('project_root_required');
  if (typeof operation !== 'function') throw new Error('execution_lock_operation_required');
  const root = path.resolve(rawRoot);
  const release = acquireNamedProjectLock(root, {
    relativeDir: path.join('追踪', 'workflow'),
    lockName: '.v3-execution.lock',
    owner: String(owner || 'workflow-v3-engine'),
    ttlMs: EXECUTION_LOCK_TTL_MS,
    errorCode: 'WORKFLOW_EXECUTION_LOCKED',
    errorLabel: 'workflow V3 execution lock',
  });
  const capability = Object.freeze({ [EXECUTION_CAPABILITY]: true, projectRoot: root });
  ACTIVE_CAPABILITIES.add(capability);
  try {
    return operation(capability);
  } finally {
    ACTIVE_CAPABILITIES.delete(capability);
    release();
  }
}

function hasWorkflowExecutionCapability(capability, projectRoot) {
  return Boolean(capability)
    && ACTIVE_CAPABILITIES.has(capability)
    && capability[EXECUTION_CAPABILITY] === true
    && String(capability.projectRoot || '') === path.resolve(String(projectRoot || ''));
}

module.exports = { hasWorkflowExecutionCapability, withWorkflowExecutionLock };
