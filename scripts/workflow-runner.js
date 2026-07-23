#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { detectAdapters } = require('./lib/workflow-host-adapters');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { resolveAuthoritativeStatus } = require('./workflow-state-validate');
const { resolveExecutionMemoryPolicy, resolveWorkflowMemoryPolicy } = require('./lib/workflow-memory-policy');
const { memoryContextDecision, memoryContextFromStagePacket, prepareMemoryContext } = require('./lib/workflow-memory-context');
const { buildStageContextPacket } = require('./lib/workflow-stage-context-packet');
const { buildLongStageContextPacket } = require('./lib/long-stage-context-packet');
const { mutateTaskAuthority } = require('./lib/workflow-task-authority');
const { resolveRunnerTask } = require('./lib/workflow-runner-telemetry');
const { normalizeExecutionBoundary } = require('./lib/workflow-execution-boundary');
const {
  assertNoSymlinkEscape,
  buildRunPreview,
  redactInvocation,
  resolveInsideProject,
  runHost,
  writeRunnerPacket,
} = require('./lib/workflow-runner-execution');

const USAGE = `Usage: node scripts/workflow-runner.js <status|once|run> --project-root <book-dir> [options]

Options:
  --adapter <auto|claude-code|codex|zcode|fake>  Explicit host adapter (default: auto)
  --dry-run                                      Show the execution plan without launching a host
  --max-stages <n>                              Maximum stages for run (default: 8)
  --max-retries <n>                             Health recovery retries per stage (default: 1)
  --idle-timeout-ms <n>                         Stop a silent host after this interval
  --max-budget-usd <n>                          Claude Code budget cap for one invocation
  --fake-executable <file>                      Test-only fake host fixture
  --fake-mode <success|repeat-term|tool-loop|no-result>
  --json`;

const args = parseArgs(process.argv);
main().catch((error) => finish({ status: 'runner_error', error: error.message }, 2));

async function main() {
  const root = path.resolve(args.projectRoot);
  if (!fs.existsSync(root)) fail('project root does not exist');

  if (args.command === 'status') {
    const capabilities = detectAdapters();
    const authority = resolveAuthoritativeStatus(root);
    finish({
      project_root: root,
      capabilities,
      ...authority,
    }, authority.status === 'blocked' ? 2 : 0);
  }

  if (args.command === 'once') {
    const result = await executeOneStage(root, args);
    finish(result, exitCodeFor(result));
  }

  const stages = [];
  let finalResult = null;
  for (let index = 0; index < args.maxStages; index += 1) {
    const result = await executeOneStage(root, args);
    stages.push(result);
    finalResult = result;
    if (result.status !== 'stage_applied') break;
  }
  if (finalResult && finalResult.status === 'stage_applied' && stages.length >= args.maxStages) {
    finalResult = {
      status: 'stage_limit',
      project_root: root,
      max_stages: args.maxStages,
      last_stage: finalResult.stage_id || '',
    };
  }
  finish({
    status: finalResult ? finalResult.status : 'no_progress',
    project_root: root,
    stage_count: stages.filter((item) => item.status === 'stage_applied').length,
    stages,
    final: finalResult,
  }, finalResult ? exitCodeFor(finalResult) : 0);
}

async function executeOneStage(root, options) {
  const authority = resolveAuthoritativeStatus(root);
  if (['migration_pending', 'blocked', 'completed'].includes(authority.status)) {
    return { ...authority, project_root: root };
  }
  const inspection = runState('inspect', root);
  if (inspection.status === 'no_active_task') return { status: 'no_active_task', project_root: root };
  if (inspection.status !== 'ok') return { status: inspection.status, project_root: root, detail: inspection };

  let task = inspection.task;
  let execution = task.stage_execution && task.stage_execution.status === 'running' ? task.stage_execution : null;
  if (!execution) {
    const next = runState('next-candidates', root);
    const candidates = Array.isArray(next.next_candidates) ? next.next_candidates : [];
    const continueCandidates = candidates.filter((item) => item.action_id !== 'pause');
    if (next.status === 'requires_user_confirm' || continueCandidates.some((item) => item.requires_user_confirm)) {
      return {
        status: 'needs_confirmation',
        project_root: root,
        target_stage: next.target_stage || task.current_stage || '',
        options: candidates,
      };
    }
    if (continueCandidates.length !== 1) {
      return {
        status: 'needs_selection',
        project_root: root,
        target_stage: next.target_stage || task.current_stage || '',
        options: candidates,
      };
    }
    const pending = next.pending_action || {};
    const started = runState('resolve-action', root, [
      '--input', String(continueCandidates[0].number),
      '--pending-action-id', String(pending.id || pending.pending_action_id || ''),
      '--visible-choice-hash', String(pending.visible_choice_hash || ''),
      '--state-version', String(pending.state_version === undefined ? task.state_version : pending.state_version),
      '--book-root', root,
    ]);
    if (started.status !== 'stage_started') return { status: started.status, project_root: root, detail: started };
    execution = started.stage_execution;
    const refreshed = runState('inspect', root);
    task = refreshed.task || task;
  }

  const expectedRel = String(execution.expected_result_packet || '');
  const expectedAbs = resolveInsideProject(root, expectedRel);
  if (!expectedAbs) return { status: 'blocked_unsafe_result_packet_path', project_root: root, result_packet: expectedRel };
  assertNoSymlinkEscape(root, expectedAbs);

  if (fs.existsSync(expectedAbs)) {
    const apply = runState('apply-result', root, ['--result', expectedAbs]);
    return appliedResult(root, task, execution, apply, true, null, expectedAbs);
  }

  if (options.adapter === 'auto') {
    return {
      status: 'adapter_required',
      project_root: root,
      stage_id: execution.stage_id || '',
      capabilities: detectAdapters(),
    };
  }

  let memoryPolicy = resolveExecutionMemoryPolicy(execution);
  // Compatibility for an already-running task created before stage-scoped
  // memory contracts were persisted. New attempts must use the immutable
  // contract attached to stage_execution.
  if (memoryPolicy.mode === 'missing') {
    memoryPolicy = resolveWorkflowMemoryPolicy(task.workflow_type, execution.stage_id || task.current_stage);
  }
  if (memoryPolicy.mode === 'missing') {
    return { status: 'blocked_memory_policy_missing', project_root: root, workflow_type: task.workflow_type };
  }
  // Build the minimum stage context packet for supported short- and long-form
  // writing stages. Fail-open: packet assembly must not break the runner.
  const stageContextPacket = resolveStageContextPacket(root, task, execution);
  const dryRunMemoryContext = memoryPolicy.context_source === 'stage_context'
    ? memoryContextFromStagePacket(memoryPolicy, stageContextPacket)
    : memoryContextDecision(memoryPolicy, 'dry_run_not_assembled');
  const preview = buildRunPreview(root, task, execution, options, 0, dryRunMemoryContext, stageContextPacket);
  if (options.dryRun) {
    return {
      status: 'dry_run',
      project_root: root,
      adapter: options.adapter,
      stage_id: execution.stage_id || '',
      expected_result_packet: expectedRel,
      host_execution_mode: 'managed_runner',
      execution_boundary: normalizeExecutionBoundary({ host_execution_mode: 'managed_runner', runnerOwnedChild: false }),
      invocation: redactInvocation(preview.invocation),
    };
  }

  const contextRunId = `context-${task.workflow_id}-${execution.stage_id}-${Date.now()}-${process.pid}`;
  const memoryContext = memoryPolicy.context_source === 'stage_context'
    ? memoryContextFromStagePacket(memoryPolicy, stageContextPacket)
    : prepareMemoryContext(root, task, execution, memoryPolicy, contextRunId);
  if (memoryContext.blocking) {
    return {
      status: memoryContext.status,
      project_root: root,
      workflow_id: task.workflow_id,
      stage_id: execution.stage_id || '',
      memory_context: memoryContext,
    };
  }

  let lastAttempt = null;
  for (let attempt = 0; attempt <= options.maxRetries; attempt += 1) {
    const run = buildRunPreview(root, task, execution, options, attempt, memoryContext, stageContextPacket);
    writeRunnerPacket(root, run.runnerPacketRel, run.runnerPacket);
    lastAttempt = await runHost(root, task, execution, run, options);
    if (String(lastAttempt.status || '').startsWith('blocked_')) {
      return {
        ...lastAttempt,
        project_root: root,
        stage_id: execution.stage_id || '',
      };
    }
    if (!lastAttempt.accounting.ok) {
      const blocked = markRunnerBlocked(root, task, execution, 'accounting_failure', lastAttempt);
      if (blocked.status !== 'ok') return { ...blocked, project_root: root, stage_id: execution.stage_id || '' };
      return {
        status: 'accounting_failure',
        project_root: root,
        stage_id: execution.stage_id || '',
        error: lastAttempt.accounting.error,
        recovery_packet: blocked.recovery_packet,
      };
    }
    if (lastAttempt.health.status === 'healthy' && fs.existsSync(expectedAbs)) break;
    if (attempt < options.maxRetries && lastAttempt.health.status === 'blocked') {
      const recovery = writeRecoveryPacket(root, task, execution, lastAttempt, attempt + 1);
      if (recovery.status !== 'ok') return { ...recovery, project_root: root, stage_id: execution.stage_id || '' };
      continue;
    }
    break;
  }

  if (!fs.existsSync(expectedAbs)) {
    const reason = lastAttempt && lastAttempt.health.stop_reason
      ? lastAttempt.health.stop_reason
      : 'missing_result_packet';
    const blocked = markRunnerBlocked(root, task, execution, reason, lastAttempt);
    if (blocked.status !== 'ok') return { ...blocked, project_root: root, stage_id: execution.stage_id || '' };
    return {
      status: reason,
      project_root: root,
      stage_id: execution.stage_id || '',
      attempts: lastAttempt ? lastAttempt.attempt + 1 : 0,
      health: lastAttempt ? lastAttempt.health : null,
      recovery_packet: blocked.recovery_packet,
    };
  }

  const apply = runState('apply-result', root, ['--result', expectedAbs]);
  return appliedResult(root, task, execution, apply, false, lastAttempt, expectedAbs);
}

// Returns the first applicable stage-scoped packet. Short and long builders
// stay separate so their domain rules do not leak into each other.
function resolveStageContextPacket(root, task, execution) {
  try {
    const input = {
      projectRoot: root,
      task,
      stage: String((execution && execution.stage_id) || ''),
    };
    for (const buildPacket of [buildStageContextPacket, buildLongStageContextPacket]) {
      const packet = buildPacket(input);
      if (packet && packet.status === 'assembled' && packet.packet_md) return packet;
    }
    return null;
  } catch (_) {
    return null;
  }
}

function writeRecoveryPacket(root, task, execution, attemptResult, nextAttempt) {
  const resolved = resolveRunnerTask(root, task.workflow_id, task.task_dir);
  if (resolved.status !== 'ok') return resolved;
  const current = resolved.task;
  const rel = `${current.task_dir}/runner-recovery/${attemptResult.run_id}.json`;
  const file = resolveInsideProject(root, rel);
  const packet = {
    schemaVersion: '1.0.0',
    workflow_id: current.workflow_id,
    stage_id: execution.stage_id,
    failed_run_id: attemptResult.run_id,
    stop_reason: attemptResult.health.stop_reason,
    evidence: attemptResult.health.evidence,
    last_trusted_artifact: (((current.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || '',
    next_attempt: nextAttempt + 1,
    recovery_policy: 'compact_retry_once_from_last_trusted_artifact',
    created_at: new Date().toISOString(),
  };
  atomicWriteJson(file, packet);
  return { status: 'ok', recovery_packet: rel };
}

function markRunnerBlocked(root, task, execution, reason, lastAttempt) {
  const resolved = resolveRunnerTask(root, task.workflow_id, task.task_dir);
  if (resolved.status !== 'ok') return resolved;
  const current = resolved.task;
  const rel = `${current.task_dir}/runner-recovery/${lastAttempt ? lastAttempt.run_id : `${execution.stage_id}-missing-result`}.final.json`;
  const file = resolveInsideProject(root, rel);
  atomicWriteJson(file, {
    schemaVersion: '1.0.0',
    workflow_id: current.workflow_id,
    stage_id: execution.stage_id,
    status: 'blocked',
    stop_reason: reason,
    attempts: lastAttempt ? lastAttempt.attempt + 1 : 0,
    health: lastAttempt ? lastAttempt.health : null,
    last_trusted_artifact: (((current.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || '',
    created_at: new Date().toISOString(),
  });

  try {
    mutateTaskAuthority(root, current.workflow_id, Number(current.state_version || 0), (draft) => {
      draft.status = reason.startsWith('model_degradation') ? 'blocked_model_degradation' : 'paused_after_step';
      draft.stage_execution = {
        ...(draft.stage_execution || {}),
      status: 'paused',
      stopped_at: new Date().toISOString(),
      stop_reason: reason,
      resume_hint: '已停在最后可信断点；修复执行环境或缩小当前阶段后再恢复。',
    };
      draft.runtime_guard = draft.runtime_guard || {};
      draft.runtime_guard.checkpoint_updated_at = new Date().toISOString();
      delete draft.runtime_guard.runner_lease;
      return draft;
    });
  } catch (error) {
    return {
      status: error.status || (error.code === 'WORKFLOW_TASK_CONFLICT' ? 'blocked_workflow_state_conflict' : 'blocked_task_authority_missing'),
      workflow_id: current.workflow_id,
      task_dir: current.task_dir,
      message: error.message,
      recovery_packet: rel,
    };
  }
  return { status: 'ok', recovery_packet: rel };
}

function appliedResult(root, task, execution, apply, reusedExistingResult, attempt, resultFile) {
  if (!['advanced', 'stage_started', 'completed', 'applied', 'stage_completed'].includes(String(apply.status || ''))) {
    return {
      status: apply.status || 'blocked_apply_result',
      project_root: root,
      stage_id: execution.stage_id || '',
      reused_existing_result: Boolean(reusedExistingResult),
      detail: apply,
    };
  }
  const memoryProjection = (apply.task && apply.task.memory_projection)
    || apply.memory_projection
    || { status: 'projected_by_state_machine', recorded: 0, applied: 0, confirmation_required: 0 };
  return {
    status: 'stage_applied',
    project_root: root,
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: execution.stage_id,
    host_execution_mode: reusedExistingResult ? (execution.host_execution_mode || 'cooperative_interactive') : 'managed_runner',
    execution_boundary: normalizeExecutionBoundary({
      host_execution_mode: reusedExistingResult ? (execution.host_execution_mode || 'cooperative_interactive') : 'managed_runner',
      runnerOwnedChild: !reusedExistingResult,
      token_source: (attempt && attempt.usage && attempt.usage.token_source) || 'unavailable',
    }),
    reused_existing_result: Boolean(reusedExistingResult),
    attempt: attempt ? attempt.attempt + 1 : 0,
    duration_ms: attempt ? attempt.duration_ms : 0,
    next_status: apply.status,
    next_stage: apply.next_stage || '',
    memory_projection: memoryProjection,
    stage_execution: apply.stage_execution || null,
    pending_action: apply.pending_action || null,
    next_candidates: Array.isArray(apply.next_candidates) ? apply.next_candidates : [],
    visible_response: apply.visible_response || null,
    interaction_contract: String(apply.interaction_contract || ''),
  };
}

function runState(command, root, extra = []) {
  const script = path.join(__dirname, 'workflow-state-machine.js');
  const result = spawnSync(process.execPath, [script, command, '--project-root', root, ...extra, '--json'], {
    encoding: 'utf8',
    shell: false,
    maxBuffer: 20 * 1024 * 1024,
  });
  let parsed;
  try {
    parsed = JSON.parse(result.stdout || '{}');
  } catch (error) {
    return { status: 'blocked_state_machine_invalid_output', error: error.message, stderr: result.stderr || '' };
  }
  if (result.error) parsed.runner_error = result.error.message;
  return parsed;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function parseArgs(argv) {
  const out = {
    command: argv[2] || '',
    projectRoot: '',
    adapter: 'auto',
    dryRun: false,
    json: false,
    maxStages: 8,
    maxRetries: 1,
    idleTimeoutMs: 5 * 60 * 1000,
    maxBudgetUsd: '',
    fakeExecutable: '',
    fakeMode: 'success',
  };
  if (!['status', 'once', 'run'].includes(out.command)) fail('missing or invalid command');
  for (let i = 3; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') out.projectRoot = argv[++i] || '';
    else if (arg === '--adapter') out.adapter = argv[++i] || 'auto';
    else if (arg === '--dry-run') out.dryRun = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '--max-stages') out.maxStages = positiveInt(argv[++i], '--max-stages');
    else if (arg === '--max-retries') out.maxRetries = nonNegativeInt(argv[++i], '--max-retries');
    else if (arg === '--idle-timeout-ms') out.idleTimeoutMs = positiveInt(argv[++i], '--idle-timeout-ms');
    else if (arg === '--max-budget-usd') out.maxBudgetUsd = argv[++i] || '';
    else if (arg === '--fake-executable') out.fakeExecutable = argv[++i] || '';
    else if (arg === '--fake-mode') out.fakeMode = argv[++i] || 'success';
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else fail(`unknown argument: ${arg}`);
  }
  if (!out.projectRoot) fail('missing --project-root');
  return out;
}

function positiveInt(value, flag) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) fail(`${flag} must be a positive integer`);
  return parsed;
}

function nonNegativeInt(value, flag) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) fail(`${flag} must be a non-negative integer`);
  return parsed;
}

function exitCodeFor(result) {
  if (!result) return 2;
  if (['runner_error', 'blocked_state_machine_invalid_output', 'blocked_unsafe_result_packet_path', 'accounting_failure'].includes(result.status)) return 2;
  return 0;
}

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(2);
}

function finish(result, code = 0) {
  if (args && args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else process.stdout.write(`${result.status || 'unknown'}\n`);
  process.exit(code);
}
