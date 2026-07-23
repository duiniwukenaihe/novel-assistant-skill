'use strict';

const path = require('path');
const { spawnSync } = require('child_process');
const { normalizeHostUsage } = require('./workflow-host-adapters');
const { acquireProjectLock } = require('./workflow-state-store');
const { claimFamilyWriter, readTaskFamily } = require('./task-family-store');
const { mutateTaskAuthority, resolveTaskAuthority } = require('./workflow-task-authority');
const { sanitizeForArtifact } = require('../behavior-eval');
const { recordSessionHeartbeat } = require('../workflow-session-heartbeat');

const SCRIPT_DIR = path.resolve(__dirname, '..');

function refreshRunnerLease(root, workflowId, taskDir, stageId, runId) {
  let release = null;
  try {
    release = acquireProjectLock(root, `workflow-runner:${runId}`, 2 * 60 * 1000);
    const resolved = resolveRunnerTask(root, workflowId, taskDir);
    if (resolved.status !== 'ok') return resolved;
    const current = resolved.task;
    if (String(current.current_stage || '') !== String(stageId || '')) {
      return {
        status: 'blocked_runner_stage_drift',
        workflow_id: workflowId,
        task_dir: taskDir,
        expected_stage: String(stageId || ''),
        current_stage: String(current.current_stage || ''),
        message: 'durable workflow stage changed before runner lease refresh',
      };
    }
    const now = new Date().toISOString();
    current.runtime_guard = current.runtime_guard || {};
    current.runtime_guard.checkpoint_updated_at = current.runtime_guard.checkpoint_updated_at
      || ((current.runtime_guard.heartbeat || {}).checkpoint_updated_at)
      || ((current.runtime_guard.heartbeat || {}).updated_at)
      || now;
    current.runtime_guard.process_heartbeat_at = now;
    current.runtime_guard.runner_lease = {
      workflow_id: workflowId,
      stage_id: stageId,
      run_id: runId,
      process_heartbeat_at: now,
      expires_at: new Date(Date.now() + 2 * 60 * 1000).toISOString(),
    };
    if (current.task_family_id) {
      const family = readTaskFamily(root, current.task_family_id);
      const holder = String((((family || {}).writer_lease || {}).holder_session_id) || '');
      const runnerSessionId = holder || `runner:${runId}`;
      const runnerHost = holder
        ? String((((family || {}).writer_lease || {}).host) || holder.split(':')[0] || 'runner')
        : 'workflow-runner';
      recordSessionHeartbeat(root, {
        taskFamilyId: current.task_family_id,
        sessionId: runnerSessionId,
        host: runnerHost,
        observedAt: now,
        expiresAt: new Date(Date.now() + 3 * 60 * 1000).toISOString(),
        capability: {
          host_execution_mode: 'managed_runner',
          stream_abort: true,
          process_liveness: true,
          exact_usage: false,
        },
      });
      claimFamilyWriter(root, current.task_family_id, {
        session_id: runnerSessionId,
        host: runnerHost,
        capability: {
          host_execution_mode: 'managed_runner',
          stream_abort: true,
          process_liveness: true,
        },
      }, { write: true, projectLockHeld: true, hostLiveness: () => 'running' });
    }
    mutateTaskAuthority(root, workflowId, Number(current.state_version || 0), () => current, { projectLockHeld: true });
    return { status: 'ok', workflow_id: workflowId, task_dir: taskDir };
  } catch (error) {
    if (!['WORKFLOW_LOCKED'].includes(error.code)) throw error;
    return {
      status: 'blocked_workflow_locked',
      code: error.code,
      workflow_id: workflowId,
      task_dir: taskDir,
      message: error.message,
    };
  } finally {
    if (release) release();
  }
}

function releaseRunnerLease(root, workflowId, taskDir, stageId, runId) {
  let release = null;
  try {
    release = acquireProjectLock(root, `workflow-runner:${runId}`, 2 * 60 * 1000);
    const resolved = resolveRunnerTask(root, workflowId, taskDir);
    if (resolved.status !== 'ok') return resolved;
    const current = resolved.task;
    if (String(current.current_stage || '') !== String(stageId || '')) return;
    const lease = ((current.runtime_guard || {}).runner_lease) || {};
    if (String(lease.run_id || '') !== String(runId || '')) return;
    delete current.runtime_guard.runner_lease;
    mutateTaskAuthority(root, workflowId, Number(current.state_version || 0), () => current, { projectLockHeld: true });
    return { status: 'ok', workflow_id: workflowId, task_dir: taskDir };
  } catch (error) {
    if (!['WORKFLOW_LOCKED'].includes(error.code)) throw error;
  } finally {
    if (release) release();
  }
}

function resolveRunnerTask(root, workflowId, taskDir) {
  if (!String(taskDir || '').trim()) {
    return {
      status: 'blocked_runner_task_dir_missing',
      task: null,
      workflow_id: String(workflowId || ''),
      task_dir: '',
      message: 'runner requires the durable task_dir captured at stage start',
    };
  }
  const resolved = resolveTaskAuthority(root, workflowId);
  if (resolved.status !== 'ok') return { ...resolved, workflow_id: String(workflowId || ''), task_dir: String(taskDir || '') };
  if (String(resolved.task.task_dir || '') !== String(taskDir || '')) {
    return {
      status: 'blocked_runner_task_dir_mismatch',
      task: null,
      workflow_id: String(workflowId || ''),
      task_dir: String(taskDir || ''),
      message: 'runner task_dir does not match the durable task authority',
    };
  }
  return resolved;
}

function recordCost(root, task, execution, options, attemptResult, ownerModule) {
  const script = path.join(SCRIPT_DIR, 'token-cost-ledger.js');
  const health = attemptResult.health || {};
  const failed = health.status === 'blocked' || Number(attemptResult.exit.code || 0) !== 0;
  const usage = attemptResult.usage || { token_source: 'unavailable', duration_ms: attemptResult.duration_ms || 0 };
  const command = [
    script,
    'append',
    '--project-root',
    root,
    '--workflow-id',
    task.workflow_id,
    '--workflow-type',
    task.workflow_type,
    '--stage',
    execution.stage_id || '',
    '--module',
    String(ownerModule || `workflow:${task.workflow_type}:${execution.stage_id || ''}`),
    '--token-source',
    usage.token_source || 'unavailable',
    '--event-id',
    attemptResult.run_id || '',
    '--task-complexity',
    String(((task.runtime_guard || {}).token_estimate || {}).risk_level || 'unknown'),
    '--output-chars',
    String(health.total_bytes || 0),
    '--duration-ms',
    String(usage.duration_ms || attemptResult.duration_ms || 0),
    '--retry-count',
    String(attemptResult.attempt || 0),
    '--failure-count',
    failed ? '1' : '0',
    '--status',
    failed ? 'failed' : 'completed',
    '--json',
  ];
  if (usage.token_source === 'host' || usage.token_source === 'provider') {
    command.push(
      '--input-tokens', String(usage.input_tokens || 0),
      '--output-tokens', String(usage.output_tokens || 0),
      '--cache-read-tokens', String(usage.cache_read_tokens || 0),
      '--cache-write-tokens', String(usage.cache_write_tokens || 0),
    );
  }
  for (const finding of usage.findings || []) {
    if (finding && finding.code) command.push('--finding-code', String(finding.code));
  }
  const result = spawnSync(process.execPath, command, {
    encoding: 'utf8',
    shell: false,
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    return {
      ok: false,
      error: sanitizeForArtifact(String(result.error ? result.error.message : (result.stderr || `ledger exited ${result.status}`))).slice(0, 500),
    };
  }
  return { ok: true, error: '' };
}

function reserveBudget(options, task) {
  if (options.adapter === 'fake') return null;
  const cap = Number(options.maxBudgetUsd);
  if (!Number.isFinite(cap) || cap <= 0) throw new Error('budget_required');
  const declaredEstimate = Number((((task.runtime_guard || {}).token_estimate || {}).estimated_usd));
  // A host-side cap is authoritative. New projects may not yet have a
  // provider-specific price estimate, so reserve that cap conservatively
  // instead of making every first real run impossible.
  const estimate = Number.isFinite(declaredEstimate) && declaredEstimate > 0 ? declaredEstimate : cap;
  options.budgetState = options.budgetState || { reserved: 0, actual: 0, max: cap };
  if (options.budgetState.max !== cap || options.budgetState.reserved + options.budgetState.actual + estimate > cap) {
    throw new Error('budget_estimate_exceeds_max');
  }
  options.budgetState.reserved += estimate;
  return estimate;
}

function settleBudget(options, reservation, usage) {
  if (reservation === null) return;
  options.budgetState.reserved -= reservation;
  // When the host omits cost telemetry, retain the conservative reservation as
  // consumed budget. This permits one explicitly capped run without claiming
  // a made-up cost or allowing an unbounded second run.
  const settled = Number.isFinite(usage.actual_usd) ? usage.actual_usd : reservation;
  options.budgetState.actual += settled;
  if (options.budgetState.actual > options.budgetState.max) throw new Error('budget_exceeded');
}

function cancelBudgetReservation(options, reservation) {
  if (reservation === null) return;
  options.budgetState.reserved -= reservation;
}

function collectHostEvent(line, events) {
  const value = String(line || '').trim();
  if (!value) return;
  try {
    const event = JSON.parse(value);
    if (event && typeof event === 'object') events.push(event);
  } catch {
    // Host output is untrusted and may contain prose beside stream JSON.
  }
}

module.exports = {
  collectHostEvent,
  cancelBudgetReservation,
  normalizeHostUsage,
  recordCost,
  refreshRunnerLease,
  releaseRunnerLease,
  resolveRunnerTask,
  reserveBudget,
  settleBudget,
};
