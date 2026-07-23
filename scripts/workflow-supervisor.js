#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  acquireSupervisorLease,
  appendSupervisorEvent,
  readSupervisorState,
  writeSupervisorState,
} = require('./lib/workflow-supervisor-store');

const USAGE = `Usage: node scripts/workflow-supervisor.js <once|watch> --project-root <book-dir> --adapter <adapter> [options]

Options:
  --max-runtime-minutes <n>  Maximum watch duration (default: 60)
  --max-cycles <n>           Maximum runner invocations in watch mode (default: 8)
  --max-retries <n>          Per-stage runner health retries (default: 1)
  --max-budget-usd <n>       Per-stage cap for an explicit paid adapter
  --max-total-budget-usd <n> Aggregate cap required for watch with a paid adapter
  --idle-timeout-ms <n>      Forwarded runner stream idle timeout
  --fake-executable <file>   Test-only fake host fixture
  --fake-mode <mode>         Test-only fake host mode
  --dry-run                  Forward dry-run to the runner; launch no host
  --json

The supervisor only delegates one existing workflow stage at a time. It never
selects user options, changes Claude/Codex/ZCode permission settings, or bypasses
the runner's transaction, quality, health, and budget gates.
`;

const PAID_ADAPTERS = new Set(['claude-code', 'codex', 'zcode']);
let active = null;
let stopRequested = '';

process.on('SIGINT', () => requestStop('signal_sigint'));
process.on('SIGTERM', () => requestStop('signal_sigterm'));

function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArgs(argv);
    const result = supervise(options);
    emit(result, options.json);
    return 0;
  } catch (error) {
    const result = {
      status: error && error.code === 'SUPERVISOR_LOCKED' ? 'stopped_supervisor_locked' : 'supervisor_error',
      reason: error && (error.code || error.message) || 'unknown_error',
    };
    emit(result, options && options.json);
    return result.status === 'stopped_supervisor_locked' ? 0 : 2;
  }
}

function supervise(options) {
  const root = path.resolve(options.projectRoot);
  if (!fs.existsSync(root)) throw new Error('project root does not exist');
  const startedAt = Date.now();
  const owner = `workflow-supervisor-${process.pid}-${startedAt}`;
  const leaseTtl = Math.max((options.maxRuntimeMinutes * 60 * 1000) + 60 * 1000, 10 * 60 * 1000);
  const release = acquireSupervisorLease(root, owner, leaseTtl);
  const previous = readSupervisorState(root);
  const base = createState(root, options, owner, previous, startedAt);
  active = { root, state: base };
  writeState(root, base, 'supervisor_started');

  try {
    if (requiresExplicitBudget(options) && !hasRequiredBudget(options)) {
      return finish(root, base, 'stopped_budget_required', { reason: 'paid_watch_requires_per_stage_and_total_budget' });
    }
    return options.command === 'once'
      ? executeCycle(root, base, options, 1)
      : watch(root, base, options, startedAt);
  } finally {
    active = null;
    release();
  }
}

function watch(root, state, options, startedAt) {
  for (let cycle = 1; cycle <= options.maxCycles; cycle += 1) {
    if (stopRequested) return finish(root, state, 'stopped_clean_shutdown', { reason: stopRequested });
    if (Date.now() - startedAt >= options.maxRuntimeMinutes * 60 * 1000) {
      return finish(root, state, 'stopped_max_runtime', { reason: 'max_runtime_reached' });
    }
    if (requiresExplicitBudget(options) && !hasRemainingReservedBudget(state, options)) {
      return finish(root, state, 'stopped_budget_exhausted', { reason: 'reserved_budget_reached' });
    }
    const result = executeCycle(root, state, options, cycle);
    if (result.status !== 'stage_applied') return result;
    if (cycle >= options.maxCycles) return finish(root, state, 'stopped_max_cycles', { reason: 'max_cycles_reached' });
  }
  return finish(root, state, 'stopped_max_cycles', { reason: 'max_cycles_reached' });
}

function executeCycle(root, state, options, cycle) {
  const runner = invokeRunner(root, options);
  state.cycle_count += 1;
  state.updated_at = new Date().toISOString();
  state.last_result = runner;
  state.last_checkpoint = checkpointFrom(runner, state.last_checkpoint);
  if (requiresExplicitBudget(options)) state.reserved_budget_usd += options.maxBudgetUsd;
  appendSupervisorEvent(root, {
    type: 'runner_cycle_finished',
    cycle,
    command: options.command,
    runner_status: runner.status || 'runner_invalid_output',
    stage_id: runner.stage_id || '',
    workflow_id: runner.workflow_id || '',
  });

  if (runner.status === 'stage_applied') {
    state.status = 'checkpointed';
    state.next_wake_reason = options.command === 'watch' ? 'continue_next_safe_stage' : 'manual_resume_available';
    writeState(root, state, 'checkpoint_saved');
    return publicResult(root, state, 'stage_applied');
  }

  return finish(root, state, stopStatusFor(runner.status), {
    reason: runner.status || 'runner_invalid_output',
    runner_result: runner,
  });
}

function invokeRunner(root, options) {
  const runner = path.join(__dirname, 'workflow-runner.js');
  const args = [runner, 'once', '--project-root', root, '--adapter', options.adapter, '--max-retries', String(options.maxRetries), '--json'];
  if (options.dryRun) args.push('--dry-run');
  if (options.idleTimeoutMs) args.push('--idle-timeout-ms', String(options.idleTimeoutMs));
  if (options.maxBudgetUsd > 0) args.push('--max-budget-usd', String(options.maxBudgetUsd));
  if (options.fakeExecutable) args.push('--fake-executable', options.fakeExecutable);
  if (options.fakeMode) args.push('--fake-mode', options.fakeMode);
  const invocation = spawnSync(process.execPath, args, {
    cwd: root,
    encoding: 'utf8',
    shell: false,
    maxBuffer: 20 * 1024 * 1024,
    env: process.env,
  });
  let parsed;
  try {
    parsed = JSON.parse(invocation.stdout || '{}');
  } catch (error) {
    parsed = { status: 'runner_invalid_output', error: error.message };
  }
  if (invocation.error) parsed.runner_error = invocation.error.message;
  if (!parsed.status && invocation.status !== 0) parsed.status = 'runner_error';
  return parsed;
}

function stopStatusFor(status) {
  const value = String(status || 'runner_invalid_output');
  if (value === 'needs_confirmation') return 'stopped_needs_confirmation';
  if (value === 'needs_selection') return 'stopped_needs_selection';
  if (value === 'no_active_task') return 'stopped_no_active_task';
  if (value === 'adapter_required') return 'stopped_adapter_required';
  if (/provider|auth|unauthorized|forbidden|rate_limit/i.test(value)) return 'stopped_provider';
  if (/budget|accounting/i.test(value)) return 'stopped_budget';
  return 'stopped_blocked';
}

function createState(root, options, owner, previous, startedAt) {
  return {
    schemaVersion: '1.0.0',
    status: 'running',
    project_root: root,
    owner,
    mode: options.command,
    adapter: options.adapter,
    started_at: new Date(startedAt).toISOString(),
    updated_at: new Date(startedAt).toISOString(),
    cycle_count: 0,
    max_cycles: options.maxCycles,
    max_runtime_minutes: options.maxRuntimeMinutes,
    max_budget_usd: options.maxBudgetUsd || null,
    max_total_budget_usd: options.maxTotalBudgetUsd || null,
    // Preserve previously reserved capacity across supervisor restarts. A new
    // process must not turn an already-spent watch budget back into free room.
    reserved_budget_usd: positiveOrZero(previous && previous.reserved_budget_usd),
    last_checkpoint: previous && previous.last_checkpoint || null,
    last_result: null,
    next_wake_reason: 'run_one_existing_stage',
    permission_configuration_changed: false,
  };
}

function checkpointFrom(result, previous) {
  if (result && result.status === 'stage_applied') {
    return {
      workflow_id: result.workflow_id || '',
      stage_id: result.stage_id || '',
      next_stage: result.next_stage || '',
      saved_at: new Date().toISOString(),
    };
  }
  return previous || null;
}

function finish(root, state, status, extra = {}) {
  state.status = status;
  state.updated_at = new Date().toISOString();
  state.next_wake_reason = status;
  if (extra.reason) state.stop_reason = extra.reason;
  if (extra.runner_result) state.last_result = extra.runner_result;
  writeState(root, state, 'supervisor_stopped');
  return publicResult(root, state, status);
}

function writeState(root, state, eventType) {
  writeSupervisorState(root, state);
  appendSupervisorEvent(root, {
    type: eventType,
    status: state.status,
    cycle_count: state.cycle_count,
    next_wake_reason: state.next_wake_reason,
  });
}

function publicResult(root, state, status) {
  return {
    status,
    project_root: root,
    mode: state.mode,
    adapter: state.adapter,
    cycle_count: state.cycle_count,
    last_checkpoint: state.last_checkpoint,
    last_result: state.last_result,
    next_wake_reason: state.next_wake_reason,
    supervisor_state: '追踪/workflow/supervisor-state.json',
    supervisor_events: '追踪/workflow/supervisor-events.jsonl',
  };
}

function requiresExplicitBudget(options) {
  return PAID_ADAPTERS.has(options.adapter) && !options.dryRun;
}

function hasRequiredBudget(options) {
  if (options.command === 'once') return options.maxBudgetUsd > 0;
  return options.maxBudgetUsd > 0 && options.maxTotalBudgetUsd > 0;
}

function hasRemainingReservedBudget(state, options) {
  return state.reserved_budget_usd + options.maxBudgetUsd <= options.maxTotalBudgetUsd;
}

function requestStop(reason) {
  stopRequested = reason;
  if (active) {
    try { finish(active.root, active.state, 'stopped_clean_shutdown', { reason }); } catch {}
  }
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (!['once', 'watch'].includes(command)) throw new Error('missing or invalid command');
  const options = {
    command,
    projectRoot: '',
    adapter: 'auto',
    maxRuntimeMinutes: 60,
    maxCycles: 8,
    maxRetries: 1,
    maxBudgetUsd: 0,
    maxTotalBudgetUsd: 0,
    idleTimeoutMs: 0,
    fakeExecutable: '',
    fakeMode: 'success',
    dryRun: false,
    json: false,
  };
  for (let index = 0; index < rest.length; index += 1) {
    const arg = rest[index];
    if (arg === '--json') options.json = true;
    else if (arg === '--dry-run') options.dryRun = true;
    else if (arg === '--project-root') options.projectRoot = rest[++index] || '';
    else if (arg === '--adapter') options.adapter = rest[++index] || 'auto';
    else if (arg === '--max-runtime-minutes') options.maxRuntimeMinutes = positiveNumber(rest[++index], arg);
    else if (arg === '--max-cycles') options.maxCycles = positiveNumber(rest[++index], arg);
    else if (arg === '--max-retries') options.maxRetries = nonNegativeNumber(rest[++index], arg);
    else if (arg === '--max-budget-usd') options.maxBudgetUsd = positiveNumber(rest[++index], arg);
    else if (arg === '--max-total-budget-usd') options.maxTotalBudgetUsd = positiveNumber(rest[++index], arg);
    else if (arg === '--idle-timeout-ms') options.idleTimeoutMs = positiveNumber(rest[++index], arg);
    else if (arg === '--fake-executable') options.fakeExecutable = rest[++index] || '';
    else if (arg === '--fake-mode') options.fakeMode = rest[++index] || 'success';
    else if (arg === '--help' || arg === '-h') {
      process.stdout.write(USAGE);
      process.exit(0);
    } else throw new Error(`unknown argument: ${arg}`);
  }
  if (!options.projectRoot) throw new Error('missing --project-root');
  return options;
}

function positiveNumber(value, flag) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error(`${flag} must be positive`);
  return parsed;
}

function nonNegativeNumber(value, flag) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(`${flag} must be a non-negative integer`);
  return parsed;
}

function positiveOrZero(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function emit(result, json) {
  process.stdout.write(json ? `${JSON.stringify(result, null, 2)}\n` : `${result.status}\n`);
}

if (require.main === module) process.exitCode = main();

module.exports = {
  hasRemainingReservedBudget,
  createState,
  invokeRunner,
  parseArgs,
  stopStatusFor,
  supervise,
};
