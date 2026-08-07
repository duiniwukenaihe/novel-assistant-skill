'use strict';

// In-process invocation of the workflow state machine. Historically every
// stage-finalize script spawned `node scripts/workflow-state-machine.js
// apply-result ...` (each spawn re-loaded ~70 modules). This module exposes the
// same command contract through the exported runCommand so callers can require
// instead of spawn. The returned shape is compatible with
// classifyWorkflowApply({ status, stdout }) so downstream parsing is unchanged.

const path = require('path');
const { runCommand } = require(path.join(__dirname, '..', 'workflow-state-machine.js'));

function invoke(command, options) {
  const base = {
    command,
    projectRoot: options.projectRoot,
    result: options.resultFile,
    input: options.input,
    bindCurrent: options.bindCurrent,
    compact: options.compact !== false,
    json: true,
    write: true,
  };
  if (options.workflowId) base.workflowId = options.workflowId;
  let result;
  try {
    result = runCommand(base);
  } catch (error) {
    return {
      status: 2,
      stdout: JSON.stringify({
        status: 'apply_result_invocation_failed',
        message: String((error && error.message) || error),
      }),
    };
  }
  const stdout = JSON.stringify(result);
  const status = result && typeof result.status === 'string' && !result.status.startsWith('blocked_')
    ? 0
    : 2;
  return { status, stdout, result };
}

function invokeApplyResult({ projectRoot, workflowId, resultFile, compact = true }) {
  return invoke('apply-result', { projectRoot, workflowId, resultFile, compact });
}

function invokeResolveAction({ projectRoot, input, bindCurrent = true, compact = true }) {
  return invoke('resolve-action', { projectRoot, input, bindCurrent, compact });
}

// For workflow-runner style callers that expect the parsed result object
// directly (not the { status, stdout } spawn wrapper). Mirrors the old
// runState() contract: returns the state machine JSON as an object, or a
// blocked object on failure.
function invokeRunnerCommand({ command, projectRoot, workflowId = '', input = '', bindCurrent = false, resultFile = '', pendingActionId = '', visibleChoiceHash = '', stateVersion = '', bookRoot = '', scope = '', reason = '', compact = false }) {
  const base = { command, projectRoot, compact, json: true, write: true };
  if (workflowId) base.workflowId = workflowId;
  if (input) base.input = input;
  if (bindCurrent) base.bindCurrent = true;
  if (resultFile) base.result = resultFile;
  if (pendingActionId) base.pendingActionId = pendingActionId;
  if (visibleChoiceHash) base.visibleChoiceHash = visibleChoiceHash;
  if (stateVersion !== '') base.stateVersion = String(stateVersion);
  if (bookRoot) base.bookRoot = bookRoot;
  if (scope) base.scope = scope;
  if (reason) base.reason = reason;
  try {
    return runCommand(base);
  } catch (error) {
    // Match the historical spawn runState() fallback: a crashed state machine
    // produced no stdout, so JSON.parse('{}') yielded an empty object. Runner
    // callers treat a missing status as blocked_apply_result. Preserving this
    // contract keeps in-process invocation behavior-identical to spawning.
    return {};
  }
}

module.exports = {
  invokeApplyResult,
  invokeResolveAction,
  invokeRunnerCommand,
};
