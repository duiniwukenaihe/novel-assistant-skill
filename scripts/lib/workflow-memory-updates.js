'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { appendJsonl, atomicWriteJson } = require('./workflow-state-store');
const { resolveExecutionMemoryPolicy, resolveWorkflowMemoryPolicy } = require('./workflow-memory-policy');
const { partitionMemoryUpdates } = require('./workflow-memory-domain-policy');

function projectAcceptedMemoryUpdates(projectRoot, task, execution, result) {
  try {
    return projectAcceptedMemoryUpdatesUnsafe(projectRoot, task, execution, result);
  } catch (error) {
    return {
      ...summary('projection_failed'),
      detail: String((error || {}).message || error || 'unknown memory projection error'),
    };
  }
}

function memoryProjectionAdvanceDecision(memoryContract = {}, projection = {}) {
  const projectionMode = String(memoryContract.projection_mode || 'none');
  const status = String((projection || {}).status || 'projection_failed');
  const required = projectionMode === 'after_accept';
  if (!required || status !== 'projection_failed') {
    return {
      can_advance: true,
      task_status: 'running',
      retry_without_model: false,
      projection_status: status,
    };
  }
  return {
    can_advance: false,
    task_status: 'accepted_pending_projection',
    retry_without_model: true,
    projection_status: status,
  };
}

function projectAcceptedMemoryUpdatesUnsafe(projectRoot, task, execution, result) {
  const root = path.resolve(projectRoot);
  let policy = resolveExecutionMemoryPolicy(execution);
  if (policy.mode === 'missing') policy = resolveWorkflowMemoryPolicy(task.workflow_type, execution.stage_id || result.stage_id || '');
  const updates = Array.isArray((result || {}).memory_updates) ? result.memory_updates : [];
  if (!policy.accepts_memory_updates || policy.projection_mode === 'none') return summary('not_applicable');
  if (!updates.length) return summary('no_updates');

  const scopedUpdates = updates.map((item) => ({
    ...item,
    workflowContext: {
      workflow_id: task.workflow_id,
      workflow_type: task.workflow_type,
      workflow_profile: task.workflow_profile || 'public',
      workflow_owner: task.workflow_owner || execution.owner_module || '',
      task_family_id: task.task_family_id || '',
      branch_id: task.branch_id || task.workflow_id,
      stage_id: execution.stage_id || result.stage_id || '',
      stage_attempt_id: execution.stage_attempt_id || '',
    },
  }));
  const stageId = safeSegment(execution.stage_id || result.stage_id || 'stage');
  const attemptId = safeSegment(execution.stage_attempt_id || 'attempt');
  const base = `${task.task_dir}/memory-projection/${stageId}/${attemptId}`;
  const domainPartition = partitionMemoryUpdates(scopedUpdates);
  const eventFile = resolveInsideProject(root, `${task.task_dir}/runner-events/memory-projection.jsonl`);
  let domainQuarantineRel = '';
  if (domainPartition.quarantined.length > 0) {
    domainQuarantineRel = `${task.task_dir}/memory-quarantine/${stageId}-${attemptId}-domain.json`;
    atomicWriteJson(resolveInsideProject(root, domainQuarantineRel), {
      workflow_id: task.workflow_id,
      stage_id: execution.stage_id || result.stage_id || '',
      stage_attempt_id: execution.stage_attempt_id || '',
      status: 'quarantined_memory_domain_violation',
      quarantined_updates: domainPartition.quarantined,
      quarantined_at: new Date().toISOString(),
    });
    appendJsonl(eventFile, {
      type: 'quarantined_memory_domain_violation',
      at: new Date().toISOString(),
      count: domainPartition.quarantined.length,
      quarantine: domainQuarantineRel,
    });
  }
  if (domainPartition.accepted.length === 0) {
    return {
      ...summary('quarantined_memory_domain_violation'),
      quarantined: domainPartition.quarantined.length,
      quarantine: domainQuarantineRel,
    };
  }
  const inputRel = `${base}/suggestions.json`;
  const inputFile = resolveInsideProject(root, inputRel);
  atomicWriteJson(inputFile, domainPartition.accepted);
  const record = runMemoryCommand(root, ['--input', inputFile, '--write', '--json']);
  if (record.status === 'blocked_output_pollution' || record.status === 'blocked_invalid_memory_suggestions') {
    const quarantineRel = `${task.task_dir}/memory-quarantine/${stageId}-${attemptId}.json`;
    atomicWriteJson(resolveInsideProject(root, quarantineRel), {
      workflow_id: task.workflow_id,
      stage_id: execution.stage_id || result.stage_id || '',
      stage_attempt_id: execution.stage_attempt_id || '',
      status: record.status,
      blocked_entry_ids: record.blockedEntryIds || [],
      memory_updates: scopedUpdates,
      quarantined_at: new Date().toISOString(),
    });
    appendJsonl(eventFile, { type: 'quarantined_memory_updates', at: new Date().toISOString(), status: record.status, quarantine: quarantineRel });
    return { ...summary('quarantined_output_pollution'), quarantine: quarantineRel };
  }
  if (!['suggestions_recorded', 'current'].includes(String(record.status || ''))) {
    appendJsonl(eventFile, { type: 'memory_projection_failed', at: new Date().toISOString(), status: record.status || 'error' });
    return { ...summary('projection_failed'), detail: record.status || 'error' };
  }
  const applied = runMemoryCommand(root, ['--apply-low-risk', '--json']);
  if (!['applied_low_risk', 'blocked_confirmation_required'].includes(String(applied.status || ''))) {
    appendJsonl(eventFile, { type: 'memory_projection_failed', at: new Date().toISOString(), status: applied.status || 'error' });
    return {
      status: 'projection_failed',
      recorded: Number(record.recorded || 0),
      applied: 0,
      confirmation_required: 0,
      detail: applied.status || 'error',
    };
  }
  const projected = {
    status: domainPartition.quarantined.length > 0
      ? 'projected_with_domain_quarantine'
      : Number(applied.confirmationRequired || 0) > 0 ? 'confirmation_required' : 'projected',
    recorded: Number(record.recorded || 0),
    applied: Number(applied.applied || 0),
    confirmation_required: Number(applied.confirmationRequired || 0),
    quarantined: domainPartition.quarantined.length,
    ...(domainQuarantineRel ? { quarantine: domainQuarantineRel } : {}),
  };
  appendJsonl(eventFile, { type: 'accepted_memory_updates', at: new Date().toISOString(), ...projected });
  return projected;
}

function runMemoryCommand(root, extra) {
  const script = path.join(__dirname, '..', 'memory-recommender.js');
  const result = spawnSync(process.execPath, [script, '--project-root', root, ...extra], {
    encoding: 'utf8', shell: false, maxBuffer: 10 * 1024 * 1024,
  });
  try {
    return JSON.parse(result.stdout || '{}');
  } catch (error) {
    return { status: 'invalid_memory_recommender_output', message: error.message };
  }
}

function resolveInsideProject(root, rel) {
  const file = path.resolve(root, String(rel || ''));
  if (file !== root && !file.startsWith(`${root}${path.sep}`)) throw new Error(`memory path escapes project root: ${rel}`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  return file;
}

function safeSegment(value) {
  return String(value || 'unknown').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 96) || 'unknown';
}

function summary(status) {
  return { status, recorded: 0, applied: 0, confirmation_required: 0 };
}

module.exports = { memoryProjectionAdvanceDecision, projectAcceptedMemoryUpdates };
