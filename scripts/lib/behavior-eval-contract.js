'use strict';

const fs = require('fs');
const path = require('path');

const MAX_HEALTH_RECOVERIES = 1;
const ESTIMATED_HOST_ATTEMPT_USD = 0.5;
const RUN_ID_PATTERN = /^[A-Za-z0-9._-]{1,64}$/;

const scenarios = Object.freeze({
  'route-single-entry': Object.freeze({ fixture: 'empty-project', assertions: Object.freeze(['route', 'visible_response']) }),
  'write-only-section-6': Object.freeze({ fixture: 'short-eight-sections', assertions: Object.freeze(['target_scope', 'asset_diff']) }),
  'review-1-200': Object.freeze({ fixture: 'review-range', assertions: Object.freeze(['batch_coverage', 'resume']) }),
  'deconstruction-health-stop': Object.freeze({ fixture: 'fake-degeneration', assertions: Object.freeze(['early_stop', 'checkpoint']) }),
  'review-repair-staged-gate': Object.freeze({
    fixture: 'review-repair-gate',
    assertions: Object.freeze(['staged_candidate', 'canonical_unchanged', 'transaction_required']),
    requirements: Object.freeze([
      'Inspect the staged repair candidate without accepting it into canonical prose.',
      'Prove the canonical chapter hash is unchanged while the candidate remains staged or blocked.',
      'Prove canonical acceptance is unavailable without an accepted chapter commit and completed projections.',
    ]),
  }),
  'chapter-commit-conflict': Object.freeze({
    fixture: 'chapter-commit-conflict',
    assertions: Object.freeze(['concurrent_change', 'accept_blocked', 'canonical_unchanged']),
    requirements: Object.freeze([
      'Start from the prepared chapter-commit snapshot in the fixture.',
      'Introduce or detect a concurrent change to the declared canonical target before accept.',
      'Prove accept is blocked and the concurrent canonical content is not overwritten.',
    ]),
  }),
  'detail-outline-quality-gate': Object.freeze({
    fixture: 'detail-outline-quality-gate',
    assertions: Object.freeze([
      'routes_to_long_write',
      'runs_detail_outline_quality_check',
      'underfilled_outline_produces_no_prose',
      'accepted_outline_advances_to_chapter_brief',
      'result_packet_contains_workflow_and_hash',
    ]),
    requirements: Object.freeze([
      'Route both fixture cases through the installed novel-assistant long-writing workflow.',
      'Run the deterministic detail-outline quality check for the valid and underfilled outlines.',
      'Prove the underfilled outline is blocked before any prose candidate is created.',
      'Prove the valid outline may advance only to Chapter Brief, then stop before prose.',
      'Prove the accepted result packet contains workflow_id, stage_id, outline_path and outline_sha256.',
    ]),
  }),
  'short-sixth-section-transition': Object.freeze({
    fixture: 'short-sixth-section',
    assertions: Object.freeze([
      'draft_next_section_advances_to_section_machine_gate',
      'recovery_count_zero_on_clean_transition',
      'no_debug_scan_find_inspect_scripts_introduced',
      'private_overlay_not_downgraded',
      'same_transition_retry_capped_at_one',
    ]),
    requirements: Object.freeze([
      'Advance the private short_write task from draft_next_section using the single stage-controller command; it must land on section_machine_gate with recovery_count 0 on a clean transition.',
      'Prove no debug-*/scan-*/find-*/inspect-* platform triage scripts are created inside the book project, and no managed scripts/ source is mutated from the writing workflow.',
      'Prove the private private-short-extension overlay is still bound to the task authority snapshot after the book directory is relocated; a missing registry must block, never silently degrade to the public short_write template.',
      'Prove a repeated same-stage transition failure is capped at one recovery; a second consecutive failure must pause with retry_budget_result exhausted and last_trusted_artifact unchanged.',
    ]),
  }),
});

const hostCommands = Object.freeze({ claude: 'claude', codex: 'codex', zcode: 'zcode' });

function normalizeRunId(value, scenarioId, executionMode = 'dry-run') {
  const runId = String(value || createRunId(scenarioId, executionMode));
  if (!RUN_ID_PATTERN.test(runId)) {
    throw new Error('--run-id must contain only letters, numbers, ".", "_" or "-" and be 1-64 characters');
  }
  return runId;
}

function normalizeHosts(value) {
  const hosts = String(value || '').split(',').map((host) => host.trim()).filter(Boolean);
  if (hosts.length === 0) throw new Error('--hosts must name at least one host');
  if (new Set(hosts).size !== hosts.length) throw new Error('--hosts must not repeat a host');
  for (const host of hosts) if (!Object.prototype.hasOwnProperty.call(hostCommands, host)) throw new Error(`unsupported host: ${host}`);
  return hosts;
}

function getScenario(id) {
  const scenario = scenarios[id];
  if (!scenario) throw new Error(`unsupported scenario: ${id}`);
  return {
    id,
    fixture: scenario.fixture,
    assertions: [...scenario.assertions],
    requirements: [...(scenario.requirements || [])],
  };
}

function createPlan({ scenario: scenarioId, hosts, runId, executionMode = 'dry-run' }) {
  const scenario = getScenario(scenarioId);
  const selectedHosts = normalizeHosts(hosts);
  const resolvedRunId = normalizeRunId(runId, scenario.id, executionMode);
  const outputDirectory = `${path.posix.join('reports', 'behavior-eval', resolvedRunId)}/`;
  const estimatedUsd = estimateRunBudget(selectedHosts);
  return {
    status: 'dry_run',
    paidExecution: false,
    scenario,
    hosts: selectedHosts,
    budget: {
      paidExecution: false,
      confirmationRequired: true,
      estimatedUsd,
      actualUsd: null,
      attemptsReserved: selectedHosts.length * (MAX_HEALTH_RECOVERIES + 1),
    },
    output: {
      runId: resolvedRunId,
      directory: outputDirectory,
      summary: path.posix.join(outputDirectory, 'summary.json'),
      absoluteDirectory: path.resolve(process.cwd(), outputDirectory),
    },
    commands: selectedHosts.map((host) => ({ host, command: hostCommands[host], mode: 'planned_only', scenario: scenario.id, fixture: scenario.fixture })),
  };
}

function estimateRunBudget(hosts) {
  const selectedHosts = Array.isArray(hosts) ? hosts : normalizeHosts(hosts);
  if (selectedHosts.some((host) => !hostCommands[host])) throw new Error('blocked_budget_estimate_unavailable');
  return roundUsd(selectedHosts.length * (MAX_HEALTH_RECOVERIES + 1) * ESTIMATED_HOST_ATTEMPT_USD);
}

function createRunDirectory(directory) {
  const reportsRoot = safeReportsRoot();
  const requested = path.resolve(String(directory || ''));
  const relative = path.relative(reportsRoot, requested);
  if (!relative || relative.includes(path.sep) || relative === '..' || path.isAbsolute(relative)) {
    throw new Error('run directory must resolve to a direct child of reports/behavior-eval');
  }
  try {
    fs.mkdirSync(requested, { mode: 0o700 });
  } catch (error) {
    if (error && error.code === 'EEXIST') throw new Error('run directory already exists');
    throw error;
  }
  const resolved = fs.realpathSync(requested);
  if (path.dirname(resolved) !== reportsRoot) throw new Error('run directory escapes reports/behavior-eval');
  fs.chmodSync(resolved, 0o700);
  return resolved;
}

function safeReportsRoot() {
  const workspaceRoot = fs.realpathSync(process.cwd());
  let current = workspaceRoot;
  for (const segment of ['reports', 'behavior-eval']) {
    current = path.join(current, segment);
    if (fs.existsSync(current)) {
      if (fs.lstatSync(current).isSymbolicLink()) throw new Error(`reports root contains symlink: ${current}`);
      if (!fs.statSync(current).isDirectory()) throw new Error(`reports root is not a directory: ${current}`);
    } else {
      fs.mkdirSync(current, { mode: 0o700 });
    }
    fs.chmodSync(current, 0o700);
  }
  return fs.realpathSync(current);
}

function normalizeUsage(host, events) {
  if (!hostCommands[String(host || '')]) throw new Error(`unsupported host: ${host}`);
  const records = [];
  const costs = [];
  const invalidFields = new Set();
  let durationMs = 0;
  for (const event of Array.isArray(events) ? events : []) {
    visitEvent(event, (value, key) => {
      if (key === 'duration_ms' || key === 'durationMs') {
        const duration = finiteNumber(value);
        if (duration === null) invalidFields.add(key);
        else durationMs = Math.max(durationMs, duration);
      }
      if (value && typeof value === 'object' && isUsageRecord(value)) records.push(value);
      if (['cost_usd', 'costUsd', 'total_cost_usd', 'totalCostUsd'].includes(key)) {
        const cost = finiteNumber(value);
        if (cost !== null) costs.push(cost);
      }
    });
  }
  const usage = emptyUsage(durationMs);
  const completeRecords = records.filter((record) => hasTokenKey(record, inputTokenKeys(host)) && hasTokenKey(record, outputTokenKeys(host)));
  for (const record of completeRecords) {
    collectInvalidUsageFields(record, host, invalidFields);
  }
  const selectedRecords = selectUsageRecords(completeRecords, host);
  for (const record of selectedRecords.records) {
    usage.inputTokens += tokenValue(record, inputTokenKeys(host));
    usage.outputTokens += tokenValue(record, outputTokenKeys(host));
    usage.cacheReadTokens += tokenValue(record, cacheReadTokenKeys(host));
    usage.cacheWriteTokens += tokenValue(record, cacheWriteTokenKeys(host));
    usage.durationMs = Math.max(usage.durationMs, tokenValue(record, ['duration_ms', 'durationMs']));
  }
  usage.snapshotStrategy = selectedRecords.strategy;
  usage.invalidFields = [...invalidFields];
  usage.complete = records.length > 0
    && completeRecords.length > 0
    && completeRecords[completeRecords.length - 1] === records[records.length - 1]
    && usage.invalidFields.length === 0;
  usage.source = usage.complete ? 'host' : 'estimated';
  usage.estimated = !usage.complete;
  // Stream protocols often emit the only authoritative cost on the terminal
  // result as total_cost_usd. Prefer that terminal value over intermediate
  // usage snapshots rather than treating a normal host response as unknown.
  usage.actualUsd = costs.length > 0 ? roundUsd(costs[costs.length - 1]) : null;
  usage.costSource = usage.actualUsd === null ? 'unavailable' : 'host';
  return usage;
}

function selectUsageRecords(records, host) {
  if (records.length <= 1) return { records, strategy: records.length ? 'single_terminal' : 'none' };
  const fields = [inputTokenKeys(host), outputTokenKeys(host), cacheReadTokenKeys(host), cacheWriteTokenKeys(host)];
  const cumulative = records.every((record, index) => index === 0 || fields.every((keys) => tokenValue(record, keys) >= tokenValue(records[index - 1], keys)));
  return cumulative
    ? { records: [records[records.length - 1]], strategy: 'terminal_cumulative' }
    : { records, strategy: 'sum_deltas' };
}

function collectInvalidUsageFields(record, host, invalidFields) {
  const known = new Set([
    ...inputTokenKeys(host),
    ...outputTokenKeys(host),
    ...cacheReadTokenKeys(host),
    ...cacheWriteTokenKeys(host),
    'duration_ms',
    'durationMs',
  ]);
  for (const [key, value] of Object.entries(record)) {
    if (known.has(key) && finiteNumber(value) === null) invalidFields.add(key);
  }
}

function aggregateUsage(usages) {
  const values = Array.isArray(usages) ? usages : [];
  const aggregate = emptyUsage();
  aggregate.complete = values.length > 0 && values.every((usage) => usage && usage.complete && usage.source === 'host');
  aggregate.source = aggregate.complete ? 'host' : 'estimated';
  aggregate.estimated = !aggregate.complete;
  aggregate.actualUsd = values.length > 0 && values.every((usage) => Number.isFinite(usage && usage.actualUsd))
    ? roundUsd(values.reduce((sum, usage) => sum + usage.actualUsd, 0))
    : null;
  aggregate.costSource = aggregate.actualUsd === null ? 'unavailable' : 'host';
  for (const usage of values) {
    aggregate.inputTokens += nonNegativeNumber(usage && usage.inputTokens);
    aggregate.outputTokens += nonNegativeNumber(usage && usage.outputTokens);
    aggregate.cacheReadTokens += nonNegativeNumber(usage && usage.cacheReadTokens);
    aggregate.cacheWriteTokens += nonNegativeNumber(usage && usage.cacheWriteTokens);
    aggregate.durationMs += nonNegativeNumber(usage && usage.durationMs);
  }
  return aggregate;
}

function emptyUsage(durationMs = 0) {
  return {
    source: 'estimated', inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0,
    durationMs: nonNegativeNumber(durationMs), estimated: true, complete: false, actualUsd: null, costSource: 'unavailable',
  };
}

function inputTokenKeys(host) {
  return host === 'zcode' ? ['prompt_tokens', 'input_tokens', 'inputTokens', 'promptTokens'] : ['input_tokens', 'inputTokens', 'prompt_tokens', 'promptTokens'];
}

function outputTokenKeys(host) {
  return host === 'zcode' ? ['completion_tokens', 'output_tokens', 'outputTokens', 'completionTokens'] : ['output_tokens', 'outputTokens', 'completion_tokens', 'completionTokens'];
}

function cacheReadTokenKeys(host) {
  return host === 'claude' ? ['cache_read_input_tokens', 'cacheReadInputTokens', 'cache_read_tokens', 'cached_input_tokens', 'cacheReadTokens'] : ['cached_input_tokens', 'cache_read_tokens', 'cacheReadTokens', 'cache_read_input_tokens', 'cacheReadInputTokens'];
}

function cacheWriteTokenKeys(host) {
  return host === 'claude' ? ['cache_creation_input_tokens', 'cacheWriteTokens', 'cache_write_tokens', 'cacheCreationInputTokens'] : ['cache_write_tokens', 'cacheWriteTokens', 'cache_creation_input_tokens', 'cacheCreationInputTokens'];
}

function isUsageRecord(value) {
  return Object.keys(value).some((key) => /^(?:input|output|prompt|completion|cached|cache_)/.test(key));
}

function hasTokenKey(record, keys) {
  return keys.some((key) => Object.prototype.hasOwnProperty.call(record, key) && finiteNumber(record[key]) !== null);
}

function tokenValue(record, keys) {
  return keys.reduce((maximum, key) => Math.max(maximum, nonNegativeNumber(record[key])), 0);
}

function nonNegativeNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

function visitEvent(value, visit, key = '') {
  if (!value || typeof value !== 'object') return;
  visit(value, key);
  for (const [childKey, child] of Object.entries(value)) {
    if (child && typeof child === 'object') visitEvent(child, visit, childKey);
    else visit(child, childKey);
  }
}

function createRunId(scenarioId, executionMode) {
  return `${executionMode === 'paid' ? 'paid' : 'dry-run'}-${scenarioId}-${Date.now()}`;
}

function roundUsd(value) {
  return Math.round(Number(value) * 1000000) / 1000000;
}

module.exports = {
  ESTIMATED_HOST_ATTEMPT_USD,
  MAX_HEALTH_RECOVERIES,
  aggregateUsage,
  createPlan,
  createRunDirectory,
  emptyUsage,
  estimateRunBudget,
  getScenario,
  normalizeUsage,
  normalizeRunId,
  normalizeHosts,
  safeReportsRoot,
  scenarios,
};
