#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const {
  MAX_HEALTH_RECOVERIES,
  aggregateUsage,
  createPlan,
  createRunDirectory,
  emptyUsage,
  estimateRunBudget,
  normalizeUsage,
} = require('./lib/behavior-eval-contract');
const {
  sourceCommit,
} = require('./lib/bundle-version');
const { buildAdapterInvocation, resolveEvaluationAdapter, resolveExecutable } = require('./lib/workflow-host-adapters');
const { createStreamHealthMonitor } = require('./lib/workflow-stream-health');
const { readZcodeTurnUsage } = require('./lib/zcode-local-telemetry');

const DEFAULT_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_TERMINATION_GRACE_MS = 3 * 1000;
const EVENT_TEXT_LIMIT = 4096;
const ACTIVE_PROCESS_GROUPS = new Set();

const USAGE = `Usage: node scripts/behavior-eval.js <plan|run> --scenario <id> --hosts <claude,codex,zcode> [--json] [--execute-paid] [--paid-confirmation <run-id>] [--max-budget-usd <n>] [--timeout-ms <n>]

Create behavior-evaluation contracts and explicit paid host runs.
`;

process.once('exit', () => {
  for (const child of ACTIVE_PROCESS_GROUPS) terminateProcessGroup(child, 'SIGKILL');
});

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = { command: command || 'plan', json: false, executePaid: false };
  for (let index = 0; index < rest.length; index += 1) {
    const arg = rest[index];
    if (arg === '--json') options.json = true;
    else if (arg === '--execute-paid') options.executePaid = true;
    else if (['--scenario', '--hosts', '--run-id', '--paid-confirmation', '--max-budget-usd', '--timeout-ms'].includes(arg)) {
      const value = rest[index + 1];
      if (!value || value.startsWith('--')) throw new Error(`${arg} requires a value`);
      options[arg.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = value;
      index += 1;
    } else if (arg === '--help' || arg === '-h') options.help = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return options;
}

function formatPlan(result) {
  const lines = [
    `Behavior evaluation: ${result.status}`,
    `Scenario: ${result.scenario.id}`,
    `Hosts: ${result.hosts.join(', ')}`,
    `Token receipts required; paid execution ${result.paidExecution ? 'enabled' : 'disabled'}`,
    `Output directory: ${result.output.directory}`,
  ];
  if (Array.isArray(result.commands) && result.commands.length > 0) {
    lines.push('Planned commands:', ...result.commands.map((item) => `  ${item.host}: ${item.command} (${item.mode})`));
  } else if (Array.isArray(result.artifacts)) {
    lines.push('Artifacts:', ...result.artifacts.map((artifact) => `  ${artifact}`));
  }
  return lines.join('\n');
}

function emit(result, json) {
  process.stdout.write(json ? `${JSON.stringify(sanitizeForArtifact(publicResult(result)))}\n` : `${formatPlan(result)}\n`);
}

function publicResult(result) {
  if (!result || typeof result !== 'object') return result;
  const { budget, ...rest } = result;
  const publicUsage = (usage) => {
    if (!usage || typeof usage !== 'object') return usage;
    const { actualUsd, costSource, ...tokenOnly } = usage;
    return tokenOnly;
  };
  const output = {
    ...rest,
    tokenUsage: publicUsage(rest.tokenUsage),
    results: Array.isArray(rest.results)
      ? rest.results.map((entry) => ({ ...entry, usage: publicUsage(entry.usage) }))
      : rest.results,
  };
  if (budget) {
    output.execution = {
      confirmationRequired: Boolean(budget.confirmationRequired),
      attemptsReserved: Number(budget.attemptsReserved || 0),
    };
  }
  return output;
}

function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArgs(argv);
    if (options.help) {
      process.stdout.write(USAGE);
      return 0;
    }
    if (!['plan', 'run'].includes(options.command)) throw new Error(`unsupported command: ${options.command}`);
    if (!options.scenario) throw new Error('--scenario is required');
    if (!options.hosts) throw new Error('--hosts is required');
    // A confirmed dry-run plan is the authorization record. Reuse its ID for
    // execution unless a maintainer explicitly supplies a different run ID.
    if (options.command === 'run' && !options.runId && options.paidConfirmation) {
      options.runId = options.paidConfirmation;
    }
    const plan = createPlan({ ...options, executionMode: options.command === 'run' ? 'paid' : 'dry-run' });
    if (options.command === 'plan') {
      emit(plan, options.json);
      return 0;
    }
    return runEvaluation(plan, options).then((result) => {
      emit(result, options.json);
      return result.status === 'pass' ? 0 : 1;
    }).catch((error) => {
      const blocked = error && error.code && String(error.code).startsWith('blocked_');
      const result = { status: blocked ? 'blocked' : 'error', reason: error.code || error.message };
      if (blocked) emit({ ...plan, ...result }, options.json);
      else process.stderr.write(options.json ? `${JSON.stringify(result)}\n` : `${result.reason}\n`);
      return blocked ? 1 : 2;
    });
  } catch (error) {
    const result = { status: 'error', reason: error.message };
    process.stderr.write(options && options.json ? `${JSON.stringify(result)}\n` : `${error.message}\n`);
    return 2;
  }
}

async function runEvaluation(plan, options = {}) {
  const authorization = authorizePaidRun(plan, options);
  const timeoutMs = positiveInteger(options.timeoutMs, '--timeout-ms', DEFAULT_TIMEOUT_MS);
  const terminationGraceMs = positiveInteger(options.terminationGraceMs, 'terminationGraceMs', DEFAULT_TERMINATION_GRACE_MS);
  const runDirectory = createRunDirectory(plan.output.absoluteDirectory);
  const projectDirectory = path.join(runDirectory, 'project');
  fs.mkdirSync(projectDirectory, { mode: 0o700 });
  fs.chmodSync(projectDirectory, 0o700);
  materializeFixture(plan.scenario.fixture, projectDirectory);
  const output = { ...plan.output, absoluteDirectory: runDirectory };
  const eventLog = path.join(runDirectory, 'events.jsonl');
  const startedAt = Date.now();
  const executionPlan = {
    ...plan,
    status: 'running',
    paidExecution: true,
    output,
    budget: {
      ...plan.budget,
      paidExecution: true,
      confirmationRequired: false,
      maxBudgetUsd: authorization.maxBudgetUsd,
    },
  };
  const packet = writeRunnerPacket(projectDirectory, executionPlan, timeoutMs);
  const preflight = preflightHosts(executionPlan, projectDirectory, packet, authorization, options);
  appendEvent(eventLog, { type: 'preflight', status: preflight.ok ? 'ready' : 'blocked', hosts: plan.hosts });
  if (!preflight.ok) return writeSummary(runDirectory, executionPlan, startedAt, preflight.results, eventLog);

  const ledger = { ...authorization, attemptsStarted: 0, actualUsd: 0, actualCostKnown: true };
  const results = [];
  for (const hostPlan of preflight.hosts) {
    if (ledger.actualUsd > ledger.maxBudgetUsd) {
      results.push(blockedResult(hostPlan.host, executionPlan, 'blocked_budget_actual_exceeded'));
      continue;
    }
    results.push(await evaluateHost({
      hostPlan,
      plan: executionPlan,
      projectDirectory,
      eventLog,
      timeoutMs,
      terminationGraceMs,
      ledger,
    }));
    const usage = results[results.length - 1].usage;
    if (Number.isFinite(usage.actualUsd)) ledger.actualUsd += usage.actualUsd;
    else ledger.actualCostKnown = false;
  }
  return writeSummary(runDirectory, executionPlan, startedAt, results, eventLog, ledger);
}

function authorizePaidRun(plan, options) {
  if (!options.executePaid) throw blockedError('blocked_paid_confirmation_required');
  if (String(options.paidConfirmation || '') !== String(plan.output.runId || '')) throw blockedError('blocked_paid_confirmation_required');
  const maxBudgetUsd = positiveBudget(options.maxBudgetUsd);
  if (maxBudgetUsd === null) throw blockedError('blocked_budget_required');
  const expectedEstimate = estimateRunBudget(plan.hosts);
  if (!Number.isFinite(plan.budget.estimatedUsd) || plan.budget.estimatedUsd !== expectedEstimate) throw blockedError('blocked_budget_estimate_unavailable');
  if (maxBudgetUsd < plan.budget.estimatedUsd) throw blockedError('blocked_budget_estimate_exceeds_max');
  return { executePaid: true, confirmation: options.paidConfirmation, maxBudgetUsd, estimatedUsd: plan.budget.estimatedUsd };
}

function preflightHosts(plan, projectDirectory, packet, authorization, options) {
  const hosts = [];
  const results = [];
  for (const host of plan.hosts) {
    let adapter;
    try {
      adapter = resolveEvaluationAdapter(host);
    } catch (error) {
      results.push(blockedResult(host, plan, 'blocked_preflight_invalid_configuration', error.message));
      continue;
    }
    const executable = resolveExecutable(adapter, options.executableOverrides || {});
    if (!executable) {
      results.push(blockedResult(host, plan, 'blocked_host_unavailable', `missing executable for ${adapter}`));
      continue;
    }
    try {
      const invocations = [];
      for (let attempt = 0; attempt <= MAX_HEALTH_RECOVERIES; attempt += 1) {
        invocations.push(buildInvocation({ host, adapter, executable, plan, projectDirectory, packet, authorization, attempt }));
      }
      hosts.push({ host, adapter, executable, invocations });
    } catch (error) {
      results.push(blockedResult(host, plan, 'blocked_preflight_invalid_configuration', error.message));
    }
  }
  return { ok: results.length === 0, hosts, results };
}

function buildInvocation({ host, adapter, executable, plan, projectDirectory, packet, authorization, attempt }) {
  return buildAdapterInvocation(adapter, {
    projectRoot: projectDirectory,
    prompt: buildPrompt(plan.scenario, attempt, packet),
    runId: `${plan.output.runId}-attempt-${attempt}`,
    runnerPacket: packet.runnerPacketRel,
    expectedResultPacket: packet.resultPacketRel,
    executableOverrides: { [adapter]: executable },
    maxBudgetUsd: authorization.maxBudgetUsd / plan.budget.attemptsReserved,
    evaluationAttempt: attempt,
    evaluationHost: host,
    skillCommand: '/novel-assistant',
    // Paid evaluation runs in a freshly created, mode 0700 fixture directory.
    // Let the host create its evidence without interactive permission loops.
    // These are host-native names: Claude Code uses bypassPermissions while
    // ZCode exposes the equivalent isolated-run mode as yolo.
    permissionMode: host === 'zcode' ? 'yolo' : 'bypassPermissions',
    // Codex defaults to workspace-write, which disables network access even
    // when a valid proxy is inherited. This run is a freshly created 0700
    // disposable fixture, so grant network only to the evaluation child.
    sandbox: host === 'codex' ? 'danger-full-access' : undefined,
    // User-level plugins and MCP servers are unrelated to this fixture and can
    // turn an otherwise valid behavior check into a slow network reconnect.
    ignoreUserConfig: host === 'codex',
  });
}

async function evaluateHost(context) {
  const { hostPlan, plan, projectDirectory, eventLog, timeoutMs, terminationGraceMs, ledger } = context;
  const attempts = [];
  for (let attempt = 0; attempt <= MAX_HEALTH_RECOVERIES; attempt += 1) {
    const invocation = hostPlan.invocations[attempt];
    const result = await runHostInvocation({
      host: hostPlan.host,
      plan,
      projectDirectory,
      eventLog,
      invocation,
      timeoutMs,
      terminationGraceMs,
      attempt,
      ledger,
    });
    attempts.push(result);
    if (result.status !== 'blocked_health') break;
    appendEvent(eventLog, { type: 'host_recovery', host: hostPlan.host, attempt: attempt + 1, policy: 'compact_retry_once' });
  }
  return aggregateAttempts(hostPlan.host, plan, attempts);
}

async function runHostInvocation(context) {
  const { host, plan, projectDirectory, eventLog, invocation, timeoutMs, terminationGraceMs, attempt, ledger } = context;
  const healthPolicy = host === 'codex' ? { maxProviderFailure: 1 } : {};
  const execution = await executeInvocation(invocation, { timeoutMs, terminationGraceMs, authorization: ledger, healthPolicy }, (channel, chunk) => {
    appendEvent(eventLog, { type: 'host_output', host, attempt, channel, text: String(chunk) });
  });
  const events = enrichHostTelemetry(host, execution.events);
  const usage = normalizeUsage(host, events);
  usage.durationMs = Math.max(usage.durationMs, execution.durationMs);
  const healthEvents = Array.isArray(execution.health.events) ? execution.health.events : [];
  if (execution.health.status === 'blocked') {
    const stopReason = execution.health.stop_reason || 'health_gate';
    const status = stopReason === 'budget_exhausted'
      ? 'blocked_budget_exhausted'
      : stopReason === 'provider_failure_loop'
        ? 'blocked_host_unavailable'
        : 'blocked_health';
    return hostResult(host, plan, status, usage, healthEvents, execution.exit, [], stopReason);
  }
  const unavailable = providerUnavailable(events, execution.exit, execution.spawnError);
  if (unavailable) return hostResult(host, plan, 'blocked_host_unavailable', usage, healthEvents, execution.exit, [], unavailable);
  if (execution.exit.code !== 0 || !hasSuccessSignal(host, events)) return hostResult(host, plan, 'fail', usage, healthEvents, execution.exit, [], 'host did not complete successfully');
  const evidence = verifyResultPacket(projectDirectory, plan.scenario);
  // A host may complete the declared behavior but omit dollar telemetry.
  // Verified host usage remains a hard requirement; the pre-approved budget
  // remains the guard when a subscription host cannot report actual USD.
  if (!usage.complete) return hostResult(host, plan, 'blocked_usage_unavailable', usage, healthEvents, execution.exit, evidence.assertions, 'host usage is missing or incomplete');
  return hostResult(host, plan, evidence.status, usage, healthEvents, execution.exit, evidence.assertions, evidence.reason);
}

function enrichHostTelemetry(host, events) {
  const enriched = Array.isArray(events) ? [...events] : [];
  if (host !== 'zcode') return enriched;
  const response = readZcodeResponse(enriched);
  if (!response) return enriched;
  const usage = readZcodeTurnUsage({ sessionId: response.sessionId, traceId: response.traceId || '' });
  if (usage) enriched.push(usage);
  return enriched;
}

function aggregateAttempts(host, plan, attempts) {
  const last = attempts[attempts.length - 1] || blockedResult(host, plan, 'blocked_execution_missing');
  const usage = aggregateUsage(attempts.map((attempt) => attempt.usage));
  const healthEvents = attempts.flatMap((attempt) => attempt.healthEvents || []);
  let status = last.status;
  if (status === 'pass' && !usage.complete) status = 'blocked_usage_unavailable';
  return { ...last, status, usage, retries: Math.max(0, attempts.length - 1), healthEvents };
}

function hostResult(host, plan, status, usage, healthEvents, exit, assertions, reason = '') {
  const fallback = plan.scenario.assertions.map((name) => ({ name, status: status === 'blocked_host_unavailable' ? 'not_run' : 'not_met', evidence: [] }));
  return {
    host,
    status,
    assertions: assertions.length ? assertions : fallback,
    usage,
    retries: 0,
    healthEvents,
    artifacts: [path.posix.join(plan.output.directory, 'events.jsonl')],
    exit,
    ...(reason ? { reason } : {}),
  };
}

function blockedResult(host, plan, reason, detail = '') {
  return hostResult(host, plan, reason, emptyUsage(), [], { code: 1, signal: '', error: detail }, [], detail || reason);
}

function executeInvocation(invocation, options, onOutput) {
  const timeoutMs = positiveInteger(options && options.timeoutMs, 'timeoutMs', DEFAULT_TIMEOUT_MS);
  const terminationGraceMs = positiveInteger(options && options.terminationGraceMs, 'terminationGraceMs', DEFAULT_TERMINATION_GRACE_MS);
  return new Promise((resolve) => {
    const monitor = createStreamHealthMonitor((options && options.healthPolicy) || {});
    const events = [];
    const pending = { stdout: '', stderr: '' };
    const startedAt = Date.now();
    let child;
    let settled = false;
    let terminating = false;
    let timeout;
    let healthTimer;
    let killTimer;
    const complete = (exit, spawnError = '') => {
      if (settled) return;
      settled = true;
      if (terminating && child) terminateProcessGroup(child, 'SIGKILL');
      clearTimeout(timeout);
      clearInterval(healthTimer);
      clearTimeout(killTimer);
      if (child) ACTIVE_PROCESS_GROUPS.delete(child);
      resolve({ events, health: monitor.snapshot(), exit, spawnError, durationMs: Date.now() - startedAt });
    };
    const requestTermination = (reason, evidence) => {
      if (reason) monitor.abort(reason, evidence || {});
      if (!child || terminating) return;
      terminating = true;
      terminateProcessGroup(child, 'SIGTERM');
      killTimer = setTimeout(() => terminateProcessGroup(child, 'SIGKILL'), terminationGraceMs);
      killTimer.unref();
    };
    const flush = () => {
      for (const text of Object.values(pending)) if (text) events.push(parseEventLine(text));
    };
    const consume = (channel, chunk) => {
      const text = String(chunk);
      const lines = `${pending[channel]}${text}`.split(/\r?\n/);
      pending[channel] = lines.pop() || '';
      events.push(...lines.filter(Boolean).map(parseEventLine));
      monitor.ingest(channel, text);
      try {
        onOutput(channel, text);
      } catch (error) {
        requestTermination('event_persistence_failure', { error: error.message });
      }
      if (monitor.shouldAbort()) requestTermination();
    };
    try {
      assertSpawnAuthorized(options && options.authorization);
      child = spawn(invocation.command, invocation.args, {
        cwd: invocation.cwd,
        env: invocation.env,
        shell: false,
        stdio: invocation.stdio,
        detached: process.platform !== 'win32',
      });
      ACTIVE_PROCESS_GROUPS.add(child);
      monitor.start();
    } catch (error) {
      complete({ code: 1, signal: '', error: error.message }, error.message);
      return;
    }
    timeout = setTimeout(() => requestTermination('execution_timeout', { timeout_ms: timeoutMs }), timeoutMs);
    timeout.unref();
    const pollMs = Math.max(10, Math.min(1000, Math.floor(((options && options.healthPolicy && options.healthPolicy.idleTimeoutMs) || 5 * 60 * 1000) / 4)));
    healthTimer = setInterval(() => { if (monitor.shouldAbort()) requestTermination(); }, pollMs);
    healthTimer.unref();
    child.stdout.on('data', (chunk) => consume('stdout', chunk));
    child.stderr.on('data', (chunk) => consume('stderr', chunk));
    child.on('error', (error) => {
      flush();
      requestTermination('spawn_error', { error: error.message });
      complete({ code: 1, signal: '', error: error.message }, error.message);
    });
    child.on('close', (code, signal) => {
      flush();
      complete({ code: code === null ? 1 : code, signal: signal || '', error: '' });
    });
  });
}

function assertSpawnAuthorized(authorization) {
  if (!authorization || authorization.executePaid !== true || !authorization.confirmation || !(authorization.maxBudgetUsd > 0)) {
    throw blockedError('blocked_paid_confirmation_required');
  }
  if (!(authorization.estimatedUsd > 0) || authorization.estimatedUsd > authorization.maxBudgetUsd) throw blockedError('blocked_budget_estimate_exceeds_max');
  authorization.attemptsStarted = Number(authorization.attemptsStarted || 0) + 1;
}

function terminateProcessGroup(child, signal) {
  if (!child || !child.pid) return;
  try {
    if (process.platform !== 'win32') process.kill(-child.pid, signal);
    else child.kill(signal);
  } catch {
    try { child.kill(signal); } catch {}
  }
}

function materializeFixture(fixture, projectDirectory) {
  const source = path.join(process.cwd(), 'tests', 'fixtures', 'behavior-eval', fixture);
  if (!fs.existsSync(source) || fs.lstatSync(source).isSymbolicLink() || !fs.statSync(source).isDirectory()) throw blockedError('blocked_fixture_unavailable');
  assertNoSymlink(source);
  fs.cpSync(source, path.join(projectDirectory, 'fixture'), { recursive: true, dereference: false, mode: fs.constants.COPYFILE_FICLONE });
}

function assertNoSymlink(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const target = path.join(directory, entry.name);
    if (fs.lstatSync(target).isSymbolicLink()) throw blockedError('blocked_fixture_symlink');
    if (entry.isDirectory()) assertNoSymlink(target);
  }
}

function writeRunnerPacket(projectDirectory, plan, timeoutMs) {
  const runnerPacketRel = '.behavior-eval/scenario.json';
  const resultPacketRel = '.behavior-eval/result.json';
  writeJson(path.join(projectDirectory, runnerPacketRel), {
    scenario: plan.scenario,
    hosts: plan.hosts,
    budget: plan.budget,
    timeoutMs,
    expectedResultPacket: resultPacketRel,
  });
  return { runnerPacketRel, resultPacketRel };
}

function verifyResultPacket(projectDirectory, scenario) {
  const root = fs.realpathSync(projectDirectory);
  const packet = readSafeJson(root, '.behavior-eval/result.json');
  if (!packet || packet.scenario !== scenario.id || !Array.isArray(packet.assertions)) return { status: 'fail', assertions: [], reason: 'missing or invalid result packet' };
  const byName = new Map(packet.assertions.map((assertion) => [assertion && assertion.name, assertion]));
  if (byName.size !== scenario.assertions.length) return { status: 'fail', assertions: [], reason: 'result packet assertion set is invalid' };
  const assertions = [];
  for (const name of scenario.assertions) {
    const assertion = byName.get(name);
    const evidence = Array.isArray(assertion && assertion.evidence) ? assertion.evidence : [];
    const valid = assertion && assertion.status === 'pass' && evidence.length > 0 && evidence.every((item) => verifyEvidence(root, item));
    assertions.push({ name, status: valid ? 'pass' : 'not_met', evidence: valid ? evidence.map((item) => ({ path: item.path, sha256: item.sha256 })) : [] });
  }
  return assertions.every((assertion) => assertion.status === 'pass') ? { status: 'pass', assertions } : { status: 'fail', assertions, reason: 'assertion evidence did not verify' };
}

function readSafeJson(root, relative) {
  try {
    const file = resolveProjectFile(root, relative);
    if (fs.lstatSync(file).isSymbolicLink()) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function verifyEvidence(root, item) {
  if (!item || typeof item.path !== 'string' || !/^[a-f0-9]{64}$/i.test(String(item.sha256 || ''))) return false;
  try {
    const file = resolveProjectFile(root, item.path);
    if (fs.lstatSync(file).isSymbolicLink() || !fs.statSync(file).isFile()) return false;
    const hash = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    return hash === item.sha256.toLowerCase();
  } catch {
    return false;
  }
}

function resolveProjectFile(root, relative) {
  if (!relative || path.isAbsolute(relative)) throw new Error('invalid relative project path');
  const file = path.resolve(root, relative);
  if (!file.startsWith(`${root}${path.sep}`)) throw new Error('project path escapes root');
  let current = root;
  for (const segment of relative.split(path.sep)) {
    current = path.join(current, segment);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) throw new Error('project path contains symlink');
  }
  return file;
}

function writeSummary(runDirectory, plan, startedAt, results, eventLog, ledger = null) {
  const usages = results.map((result) => result.usage);
  const allUsage = aggregateUsage(usages);
  const result = {
    status: aggregateStatus(results),
    paidExecution: true,
    scenario: plan.scenario,
    hosts: plan.hosts,
    release_evidence: buildReleaseEvidence(),
    tokenUsage: allUsage,
    durationMs: Date.now() - startedAt,
    output: plan.output,
    results,
  };
  const artifacts = [
    path.posix.join(plan.output.directory, 'events.jsonl'),
    path.posix.join(plan.output.directory, 'result.json'),
    path.posix.join(plan.output.directory, 'summary.json'),
  ];
  writeJson(path.join(runDirectory, 'result.json'), result);
  const summary = sanitizeForArtifact(publicResult({ ...result, artifacts }));
  writeJson(path.join(runDirectory, 'summary.json'), summary);
  return summary;
}

function buildReleaseEvidence() {
  const manifest = readJson(path.join(process.cwd(), 'skills', 'novel-assistant', 'novel-assistant-manifest.json')) || {};
  return {
    bundleId: String(manifest.bundleId || ''),
    sourceCommit: String(manifest.sourceCommit || sourceCommit(process.cwd()) || ''),
    hostVersions: {},
  };
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function aggregateStatus(results) {
  if (results.every((result) => result.status === 'pass')) return 'pass';
  if (results.some((result) => String(result.status).startsWith('blocked'))) return 'blocked';
  return 'fail';
}

function hasSuccessSignal(host, events) {
  const zcodeResponse = host === 'zcode' ? readZcodeResponse(events) : null;
  return events.some((event) => {
    const type = String((event || {}).type || '');
    const status = String((event || {}).status || (event || {}).subtype || '').toLowerCase();
    if (host === 'codex') return type === 'turn.completed' && ['completed', 'success'].includes(status);
    if (host === 'zcode') return (type === 'turn.completed' && ['completed', 'success'].includes(status))
      || (type === 'result' && ['completed', 'success'].includes(status))
      || (typeof event.sessionId === 'string' && event.sessionId.length > 0 && typeof event.response === 'string')
      || Boolean(zcodeResponse);
    return type === 'result' && ['success', 'completed'].includes(status);
  });
}

function readZcodeResponse(events) {
  const direct = (Array.isArray(events) ? events : []).find((event) => event
    && typeof event.sessionId === 'string'
    && event.sessionId.length > 0
    && typeof event.response === 'string');
  if (direct) return direct;
  const raw = (Array.isArray(events) ? events : [])
    .filter((event) => event && event.type === 'host_text' && typeof event.text === 'string')
    .map((event) => event.text)
    .join('\n')
    .trim();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    return typeof parsed.sessionId === 'string' && parsed.sessionId.length > 0 && typeof parsed.response === 'string'
      ? parsed
      : null;
  } catch {
    return null;
  }
}

function providerUnavailable(events, exit, spawnError) {
  const text = [spawnError, exit && exit.error, ...events.map((event) => JSON.stringify(event || {}))].join('\n');
  return /\b(?:enotfound|econnrefused|econnreset|etimedout|network is unreachable|dns|rate limit|too many requests|http\s*429|overloaded|capacity|insufficient (?:credit|balance|quota)|quota exceeded|unauthorized|authentication failed|not logged in|forbidden|invalid (?:model|provider)|model[_\s-]?(?:not found|unavailable))\b/i.test(text) ? 'provider unavailable' : '';
}

function parseEventLine(line) {
  try { return JSON.parse(line); } catch { return { type: 'host_text', text: String(line).slice(0, EVENT_TEXT_LIMIT) }; }
}

function buildPrompt(scenario, attempt, packet) {
  const assertionFiles = scenario.assertions.map((name) => `artifacts/${name}.txt`).join(', ');
  return [
    'Use the installed /novel-assistant skill for this isolated behavior evaluation.',
    `Scenario: ${scenario.id}. Fixture: ${scenario.fixture}.`,
    `Assertions: ${scenario.assertions.join(', ')}.`,
    ...(Array.isArray(scenario.requirements) && scenario.requirements.length
      ? ['Scenario requirements:', ...scenario.requirements.map((requirement, index) => `${index + 1}. ${requirement}`)]
      : []),
    `Read only ${packet.runnerPacketRel} and fixture/fixture.json. Do not search, list, or read any parent directory or repository path.`,
    `Create only ${assertionFiles}, then write ${packet.resultPacketRel}.`,
    `Write the result packet exactly as {"scenario":"${scenario.id}","assertions":[{"name":"...","status":"pass","evidence":[{"path":"artifacts/...txt","sha256":"<64 hex>"}]}]}.`,
    'It must contain one assertion per declared name and each assertion must carry the SHA-256 of its matching artifact.',
    'This is an isolated, disposable evaluation directory. Use the available write or command tool only for those declared files, then finish immediately.',
    attempt > 0 ? 'This is the one allowed recovery attempt. Resume from the last trustworthy output and keep the response compact.' : '',
  ].filter(Boolean).join('\n');
}

function appendEvent(file, event) {
  const value = sanitizeForArtifact({ at: new Date().toISOString(), ...event });
  fs.appendFileSync(file, `${JSON.stringify(value)}\n`, { encoding: 'utf8', mode: 0o600 });
  fs.chmodSync(file, 0o600);
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.chmodSync(path.dirname(file), 0o700);
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(sanitizeForArtifact(value), null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
  fs.chmodSync(temporary, 0o600);
  fs.renameSync(temporary, file);
  fs.chmodSync(file, 0o600);
}

function sanitizeForArtifact(value) {
  if (typeof value === 'string') return redact(value).slice(0, EVENT_TEXT_LIMIT);
  if (Array.isArray(value)) return value.map(sanitizeForArtifact);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, /(?:secret|password|api[_-]?key|authorization)/i.test(key) ? '[REDACTED]' : sanitizeForArtifact(child)]));
}

function redact(value) {
  return String(value)
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*/gi, 'Bearer [REDACTED]')
    .replace(/\bsk-[A-Za-z0-9_-]{8,}\b/g, '[REDACTED]')
    .replace(/\b((?:api[_-]?key|token|secret|password))\s*[=:]\s*[^\s,;]+/gi, '$1=[REDACTED]');
}

function positiveInteger(value, flag, fallback) {
  if (value === undefined) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) throw new Error(`${flag} must be a positive integer`);
  return parsed;
}

function positiveBudget(value) {
  if (value === undefined) return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) throw new Error('--max-budget-usd must be positive');
  return parsed;
}

function blockedError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

if (require.main === module) Promise.resolve(main()).then((code) => { process.exitCode = code; });

module.exports = { executeInvocation, main, parseArgs, runEvaluation, sanitizeForArtifact, terminateProcessGroup };
