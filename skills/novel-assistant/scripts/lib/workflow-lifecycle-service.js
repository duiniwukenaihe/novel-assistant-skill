'use strict';

// Pure lifecycle decisions shared by interactive state transitions and runner
// recovery. Keeping them side-effect free makes their stop boundaries explicit.
function findStage(template, stageId) {
  if (!template) return null;
  return template.stages.find((item) => item.stage_id === stageId) || null;
}

function shouldStopBeforeStage(task, stageDef) {
  if (!stageDef) return false;
  if (stageDef.requires_user_confirm) return true;
  return String(task.completion_policy || '') === 'full_auto'
    && ['high', 'destructive'].includes(String(stageDef.risk_level || ''));
}

function nextStopReason(task, stageDef) {
  if (!stageDef) return 'no_next_stage';
  return shouldStopBeforeStage(task, stageDef) ? 'requires_user_confirm' : 'ready';
}

function currentUnitRole(contract, stageId) {
  return String(((contract || {}).stage_roles || {})[stageId] || '');
}

function trustedArtifactFromResult(result) {
  const outputs = Array.isArray(result.outputs) ? result.outputs : [];
  const changed = Array.isArray(result.changed_files) ? result.changed_files : [];
  const created = Array.isArray(result.created_files) ? result.created_files : [];
  return String(outputs[0] || changed[0] || created[0] || result.handoff_packet_path || '');
}

module.exports = {
  findStage,
  shouldStopBeforeStage,
  nextStopReason,
  currentUnitRole,
  trustedArtifactFromResult,
};
