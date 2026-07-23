#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { visibleCostSource } = require('./lib/workflow-execution-boundary');

const USAGE = `Usage:
  node token-cost-ledger.js init --project-root <book-dir> --workflow-id <id> [--workflow-type type] [--json]
  node token-cost-ledger.js append --project-root <book-dir> --workflow-id <id> --stage <stage> --module <module> [cost fields] [--json]
  node token-cost-ledger.js summary --project-root <book-dir> [--workflow-id <id>] [--json]

Records provenance-aware token-cost metrics for novel-assistant workflows.`;

const MODEL_CLASSES = new Set(['cheap_extract', 'standard_reasoning', 'deep_reasoning', 'unknown']);
const TOKEN_SOURCES = new Set(['host', 'provider', 'estimated', 'unavailable']);
const TOKEN_FIELDS = ['inputTokens', 'outputTokens', 'cacheReadTokens', 'cacheWriteTokens'];
const LEDGER_LOCK_WAIT_MS = 5000;
const LEDGER_LOCK_TTL_MS = 30000;

function parseArgs(argv) {
  const command = argv[2] || '';
  if (!['init', 'append', 'summary'].includes(command)) fail('missing or invalid command');
  const args = { command, json: false };
  for (let i = 3; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else if (arg.startsWith('--')) {
      const key = arg.slice(2).replace(/-([a-z])/g, (_, ch) => ch.toUpperCase());
      args[key] = argv[++i] || '';
    } else {
      fail(`unknown argument: ${arg}`);
    }
  }
  if (!args.projectRoot) fail('missing --project-root');
  if (command !== 'summary' && !args.workflowId) fail('missing --workflow-id');
  return args;
}

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(2);
}

function workflowDir(projectRoot) {
  return path.join(path.resolve(projectRoot), '追踪', 'workflow');
}

function ledgerPath(projectRoot) {
  return path.join(workflowDir(projectRoot), 'token-cost-ledger.jsonl');
}

function summaryPath(projectRoot) {
  return path.join(workflowDir(projectRoot), 'token-cost-summary.json');
}

function nowIso() {
  return new Date().toISOString();
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function toNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}

function requiredNonNegative(args, key) {
  if (!hasOwn(args, key) || args[key] === '') return 0;
  const number = Number(args[key]);
  if (!Number.isFinite(number) || number < 0) throw new Error(`invalid --${camelToKebab(key)}`);
  return number;
}

function camelToKebab(value) {
  return String(value).replace(/[A-Z]/g, (character) => `-${character.toLowerCase()}`);
}

function toBoolean(value) {
  return String(value || '').toLowerCase() === 'true';
}

function estimateTokens(inputChars, outputChars) {
  return Math.ceil((inputChars + outputChars) / 2);
}

function ensureRoot(projectRoot) {
  const root = path.resolve(projectRoot);
  fs.mkdirSync(workflowDir(root), { recursive: true });
  return root;
}

function init(args) {
  const root = ensureRoot(args.projectRoot);
  if (!fs.existsSync(ledgerPath(root))) fs.writeFileSync(ledgerPath(root), '', 'utf8');
  const summary = summarize(root, args.workflowId, {
    initialized_at: nowIso(),
    workflow_type: args.workflowType || '',
  });
  writeSummary(root, summary);
  return {
    status: 'initialized',
    project_root: root,
    workflow_id: args.workflowId,
    workflow_type: args.workflowType || '',
    cost_ledger_path: ledgerPath(root),
    cost_summary_path: summaryPath(root),
  };
}

function append(args) {
  const root = ensureRoot(args.projectRoot);
  const event = normalizeEvent(args);
  const release = acquireLedgerLock(root);
  try {
    const existing = readEvents(root).find((item) => item.event_id && item.event_id === event.event_id);
    if (existing) {
      const summary = summarize(root, args.workflowId);
      writeSummary(root, summary);
      return {
        status: 'duplicate_ignored',
        event: existing,
        cost_ledger_path: ledgerPath(root),
        cost_summary_path: summaryPath(root),
      };
    }
    appendEventAtomically(ledgerPath(root), event);
    const summary = summarize(root, args.workflowId);
    writeSummary(root, summary);
    return {
      status: 'appended',
      event,
      cost_ledger_path: ledgerPath(root),
      cost_summary_path: summaryPath(root),
    };
  } finally {
    release();
  }
}

function normalizeEvent(args) {
  const modelClass = MODEL_CLASSES.has(args.modelClass || '') ? args.modelClass : 'unknown';
  const tokenSource = args.tokenSource || 'estimated';
  if (!TOKEN_SOURCES.has(tokenSource)) throw new Error('invalid --token-source');
  const inputFiles = requiredNonNegative(args, 'inputFiles');
  const inputChars = requiredNonNegative(args, 'inputChars');
  const outputChars = requiredNonNegative(args, 'outputChars');
  const toolCalls = requiredNonNegative(args, 'toolCalls');
  const retryCount = requiredNonNegative(args, 'retryCount');
  const failureCount = requiredNonNegative(args, 'failureCount');
  const durationMs = requiredNonNegative(args, 'durationMs');
  const tokenValues = Object.fromEntries(TOKEN_FIELDS.map((field) => [field, requiredNonNegative(args, field)]));
  const suppliedEstimatedTokens = requiredNonNegative(args, 'estimatedTokens');
  const findings = String(args.findingCode || '').split(',').map(value => value.trim()).filter(Boolean)
    .map(code => ({ code, severity: 'warning' }));
  let estimatedTokens = 0;

  if (!String(args.eventId || '').trim()) throw new Error('missing --event-id for new cost event');

  if (tokenSource === 'host' || tokenSource === 'provider') {
    if (!hasOwn(args, 'inputTokens') || !hasOwn(args, 'outputTokens') || args.inputTokens === '' || args.outputTokens === '') {
      throw new Error(`token_source ${tokenSource} requires input_tokens and output_tokens`);
    }
    if (suppliedEstimatedTokens > 0) findings.push({ code: 'estimated_tokens_ignored_for_actual', severity: 'info' });
  } else if (tokenSource === 'estimated') {
    if (TOKEN_FIELDS.some((field) => hasOwn(args, field))) throw new Error('token_source estimated cannot include actual token fields');
    if (!hasOwn(args, 'estimatedTokens') && inputChars + outputChars <= 0) throw new Error('token_source estimated requires an explicit estimate or character proxy');
    estimatedTokens = hasOwn(args, 'estimatedTokens') ? suppliedEstimatedTokens : estimateTokens(inputChars, outputChars);
  } else {
    if (TOKEN_FIELDS.some((field) => hasOwn(args, field)) || hasOwn(args, 'estimatedTokens')) {
      throw new Error('token_source unavailable cannot include token values');
    }
  }

  return {
    event: 'cost_observed',
    event_id: String(args.eventId).trim(),
    created_at: args.createdAt || nowIso(),
    workflow_id: args.workflowId,
    workflow_type: args.workflowType || '',
    stage: args.stage || '',
    module: args.module || '',
    model_class: modelClass,
    task_complexity: args.taskComplexity || 'unknown',
    input_files: inputFiles,
    input_chars: inputChars,
    output_chars: outputChars,
    tool_calls: toolCalls,
    retry_count: retryCount,
    failure_count: failureCount,
    cache_hit: toBoolean(args.cacheHit),
    status: args.status || 'observed',
    token_source: tokenSource,
    input_tokens: tokenValues.inputTokens,
    output_tokens: tokenValues.outputTokens,
    cache_read_tokens: tokenValues.cacheReadTokens,
    cache_write_tokens: tokenValues.cacheWriteTokens,
    estimated_tokens: estimatedTokens,
    duration_ms: durationMs,
    findings,
    waste_signals: detectWasteSignals({
      modelClass,
      taskComplexity: args.taskComplexity || '',
      inputFiles,
      inputChars,
      outputChars,
      toolCalls,
      retryCount,
      failureCount,
      cacheHit: toBoolean(args.cacheHit),
    }),
  };
}

function detectWasteSignals(event) {
  const signals = [];
  if (event.modelClass === 'deep_reasoning' && ['low', 'mechanical', 'extract'].includes(event.taskComplexity)) {
    signals.push('model_mismatch');
  }
  if (event.retryCount > 0 || event.failureCount > 0) signals.push('failure_retry_waste');
  if (event.toolCalls >= 6 && event.outputChars >= 4000) signals.push('tool_noise_waste');
  if (event.inputChars >= 120000 || event.inputFiles >= 50) signals.push('context_thickening_waste');
  if (event.cacheHit && event.inputChars >= 60000) signals.push('cache_reuse_opportunity');
  return signals;
}

function readEvents(projectRoot) {
  const file = ledgerPath(projectRoot);
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8')
    .split(/\n+/)
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      try {
        return JSON.parse(line);
      } catch (error) {
        return { event: 'invalid_jsonl', error: error.message, raw: line };
      }
    });
}

function appendEventAtomically(file, event) {
  const fd = fs.openSync(file, 'a');
  try {
    fs.writeSync(fd, `${JSON.stringify(event)}\n`);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function acquireLedgerLock(projectRoot) {
  const lockDir = path.join(workflowDir(projectRoot), '.token-cost-ledger.lock');
  const token = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const deadline = Date.now() + LEDGER_LOCK_WAIT_MS;
  while (true) {
    try {
      fs.mkdirSync(lockDir);
      fs.writeFileSync(path.join(lockDir, 'owner.json'), JSON.stringify({ token, acquired_at: nowIso() }), 'utf8');
      let released = false;
      return () => {
        if (released) return;
        released = true;
        try {
          const owner = JSON.parse(fs.readFileSync(path.join(lockDir, 'owner.json'), 'utf8'));
          if (owner.token === token) fs.rmSync(lockDir, { recursive: true, force: true });
        } catch {
          // A replaced or already-released lock is no longer ours to remove.
        }
      };
    } catch (error) {
      if (!error || error.code !== 'EEXIST') throw error;
      if (isStaleLedgerLock(lockDir)) {
        try { fs.rmSync(lockDir, { recursive: true, force: true }); } catch {}
        continue;
      }
      if (Date.now() >= deadline) throw new Error('token cost ledger lock timeout');
      sleep(10);
    }
  }
}

function isStaleLedgerLock(lockDir) {
  try {
    return Date.now() - fs.statSync(lockDir).mtimeMs > LEDGER_LOCK_TTL_MS;
  } catch {
    return false;
  }
}

function sleep(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function summarize(projectRoot, workflowId, extra = {}) {
  const root = ensureRoot(projectRoot);
  const events = readEvents(root).filter(event => !workflowId || event.workflow_id === workflowId);
  const waste = {};
  const findings = [];
  const actual = createTokenBucket();
  const estimated = createTokenBucket();
  const unavailable = createTokenBucket();
  const buckets = { actual, estimated, unavailable };
  const seenEventIds = new Set();
  const totals = {
    input_files: 0,
    input_chars: 0,
    output_chars: 0,
    tool_calls: 0,
    retry_count: 0,
    failure_count: 0,
    estimated_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    duration_ms: 0,
  };
  for (const event of events) {
    if (event.event === 'invalid_jsonl') {
      findings.push({ code: 'invalid_jsonl', severity: 'warning', detail: event.error || 'invalid JSONL event' });
      continue;
    }
    const eventId = String(event.event_id || '');
    if (eventId && seenEventIds.has(eventId)) {
      findings.push({ code: 'duplicate_event_id', severity: 'warning', event_id: eventId });
      continue;
    }
    if (eventId) seenEventIds.add(eventId);
    for (const signal of event.waste_signals || []) {
      waste[signal] = (waste[signal] || 0) + 1;
    }
    for (const field of ['input_files', 'input_chars', 'output_chars', 'tool_calls', 'retry_count', 'failure_count']) {
      totals[field] += readMetric(event, field, findings);
    }
    const bucketName = classifyEvent(event, findings);
    const bucket = buckets[bucketName];
    bucket.events += 1;
    const durationMs = readMetric(event, 'duration_ms', findings);
    bucket.duration_ms += durationMs;
    totals.duration_ms += durationMs;
    if (bucketName === 'actual') {
      for (const field of ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens']) {
        const value = readMetric(event, field, findings);
        bucket[field] += value;
        totals[field] += value;
      }
      const source = String(event.token_source || '');
      bucket.sources[source] = (bucket.sources[source] || 0) + 1;
    } else if (bucketName === 'estimated') {
      const value = readMetric(event, 'estimated_tokens', findings);
      bucket.estimated_tokens += value;
      totals.estimated_tokens += value;
      if (!hasOwn(event, 'token_source')) bucket.legacy_events += 1;
    }
  }
  const proactiveAlerts = buildProactiveAlerts(waste, totals);
  const tokenSavingPlan = buildTokenSavingPlan(waste, totals);
  return {
    status: 'summary',
    generated_at: nowIso(),
    workflow_id: workflowId || '',
    events: events.length,
    totals,
    actual,
    estimated,
    unavailable,
    visible_cost_sources: {
      actual: visibleCostSource(actual.events > 0 ? 'host' : ''),
      estimated: visibleCostSource(estimated.events > 0 ? 'estimated' : ''),
      unavailable: visibleCostSource(unavailable.events > 0 ? 'unavailable' : ''),
    },
    findings,
    waste_signals: waste,
    proactive_alerts: proactiveAlerts,
    token_saving_plan: tokenSavingPlan,
    cost_ledger_path: ledgerPath(root),
    ...extra,
  };
}

function createTokenBucket() {
  return {
    events: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    estimated_tokens: 0,
    duration_ms: 0,
    sources: {},
    legacy_events: 0,
  };
}

function readMetric(event, field, findings) {
  if (!hasOwn(event, field) || event[field] === '') return 0;
  const number = Number(event[field]);
  if (!Number.isFinite(number) || number < 0) {
    findings.push({ code: 'invalid_numeric_value', severity: 'warning', field, event_id: event.event_id || '' });
    return 0;
  }
  return number;
}

function classifyEvent(event, findings) {
  const source = event.token_source;
  if (!source) {
    findings.push({ code: 'legacy_provenance_missing', severity: 'info', event_id: event.event_id || '' });
    return readMetric(event, 'estimated_tokens', findings) > 0 ? 'estimated' : 'unavailable';
  }
  if (!TOKEN_SOURCES.has(source)) {
    findings.push({ code: 'invalid_token_source', severity: 'warning', event_id: event.event_id || '' });
    return 'unavailable';
  }
  if (source === 'host' || source === 'provider') {
    const hasCompleteActualUsage = hasOwn(event, 'input_tokens')
      && hasOwn(event, 'output_tokens')
      && Number.isFinite(Number(event.input_tokens)) && Number(event.input_tokens) >= 0
      && Number.isFinite(Number(event.output_tokens)) && Number(event.output_tokens) >= 0;
    if (!hasCompleteActualUsage) {
      findings.push({ code: 'actual_usage_incomplete', severity: 'warning', event_id: event.event_id || '', token_source: source });
      return 'unavailable';
    }
    return 'actual';
  }
  return source;
}

function buildProactiveAlerts(wasteSignals, totals) {
  const signals = Object.keys(wasteSignals || {}).filter(name => wasteSignals[name] > 0);
  const alerts = [];
  if (signals.length > 0) {
    alerts.push({
      severity: 'warning',
      type: 'abnormal_waste',
      message: '检测到异常 token 浪费信号',
      signals,
      should_notify_user: true,
      next_action: '停在当前 checkpoint，优先缩小范围、复用中间产物或切换到更低成本的提取/聚合路径。',
    });
  }
  if (toNumber(totals.failure_count) >= 2 || toNumber(totals.retry_count) >= 2) {
    alerts.push({
      severity: 'warning',
      type: 'retry_budget_risk',
      message: '失败/重试次数偏高，应主动暂停并说明最后可信产物',
      signals: ['failure_retry_waste'],
      should_notify_user: true,
      next_action: '不要继续原样重试；运行分诊或改用确定性脚本后再续跑。',
    });
  }
  return alerts;
}

function buildTokenSavingPlan(wasteSignals, totals) {
  const signals = Object.keys(wasteSignals || {}).filter(name => wasteSignals[name] > 0);
  const actions = [];
  const add = (signal, action, why, execution) => {
    if (!actions.some(item => item.action === action && item.signal === signal)) {
      actions.push({ signal, action, why, execution });
    }
  };

  if (signals.includes('model_mismatch')) {
    add(
      'model_mismatch',
      'downgrade_model_class',
      '低复杂度提取/计数/格式校验不应消耗 deep_reasoning。',
      '下一批 mechanical/extract/low 任务改走 cheap_extract；只有跨卷仲裁、重大改纲或反复失败根因分析才升级。'
    );
  }
  if (signals.includes('tool_noise_waste')) {
    add(
      'tool_noise_waste',
      'filter_tool_output',
      '长 Bash/grep/test/MCP 输出进入上下文会放大后续成本。',
      '原始输出写入文件；主线程只读取 JSON 摘要、失败计数、路径、changed_files 和下一步。'
    );
  }
  if (signals.includes('context_thickening_waste')) {
    add(
      'context_thickening_waste',
      'reuse_artifacts_before_raw_read',
      '输入文件或字符数过大，说明可能在重复读取全文。',
      '先复用已落盘索引、批次摘要、range-summary、review-state、章节契约和 handoff 包；冲突时再回读源文件。'
    );
  }
  if (signals.includes('failure_retry_waste')) {
    add(
      'failure_retry_waste',
      'stop_retry_and_triage',
      '失败后原样重试会迅速消耗 token 且扩大污染。',
      '同类失败最多一次修正重试；第二次改用 write-failure-triage、tool-task-decompose-plan 或确定性脚本。'
    );
  }
  if (signals.includes('cache_reuse_opportunity')) {
    add(
      'cache_reuse_opportunity',
      'reuse_cached_artifacts',
      '已有缓存命中但输入仍然偏大，说明缓存没有充分压缩后续上下文。',
      '读取缓存摘要和证据索引，不再把原始批次材料塞回主线程。'
    );
  }

  if (actions.length === 0) {
    actions.push({
      signal: 'normal',
      action: 'keep_lightweight_path',
      why: '未检测到明显浪费信号。',
      execution: '继续使用当前批次预算；仍优先读取索引、摘要和结构化账本，避免无意义扩上下文。',
    });
  }

  const estimated = toNumber(totals.estimated_tokens);
  return {
    mode: 'active_and_passive',
    passive_cost_report_available: true,
    active_triggers: [
      'stage_completed',
      'batch_completed',
      'agent_handoff_completed',
      'long_report_written',
      'setup_update_completed',
      'abnormal_waste',
    ],
    passive_queries: [
      '成本',
      '成本报告',
      'token',
      'token 消耗',
      '节省 token',
      '为什么慢',
      '为什么贵',
    ],
    next_checkpoint_policy: signals.length > 0
      ? 'pause_then_offer_cheaper_recovery_path'
      : 'continue_with_summary_only',
    estimated_tokens: estimated,
    actions,
  };
}

function writeSummary(projectRoot, summary) {
  fs.writeFileSync(summaryPath(projectRoot), `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
}

function print(result, json) {
  if (json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  if (result.status === 'summary') {
    printSummary(result);
    return;
  }
  console.log(`${result.status}: ${result.workflow_id || ''}`.trim());
  if (result.cost_ledger_path) console.log(`cost_ledger_path: ${result.cost_ledger_path}`);
  if (result.cost_summary_path) console.log(`cost_summary_path: ${result.cost_summary_path}`);
}

function printSummary(result) {
  console.log('Token Cost Summary');
  console.log(`workflow_id: ${result.workflow_id || '(all)'}`);
  console.log(`events: ${result.events}`);
  console.log(`actual_tokens: input=${result.actual.input_tokens}, output=${result.actual.output_tokens}, cache_read=${result.actual.cache_read_tokens}, cache_write=${result.actual.cache_write_tokens}`);
  console.log(`estimated_events: ${result.estimated.events}`);
  console.log(`unavailable_events: ${result.unavailable.events}`);
  console.log(`estimated_tokens: ${result.totals.estimated_tokens}`);
  console.log(`input_files: ${result.totals.input_files}`);
  console.log(`input_chars: ${result.totals.input_chars}`);
  console.log(`output_chars: ${result.totals.output_chars}`);
  console.log(`tool_calls: ${result.totals.tool_calls}`);
  console.log(`retry_count: ${result.totals.retry_count}`);
  console.log(`failure_count: ${result.totals.failure_count}`);
  const signals = Object.entries(result.waste_signals || {});
  if (signals.length) {
    console.log('waste_signals:');
    for (const [name, count] of signals) console.log(`- ${name}: ${count}`);
  } else {
    console.log('waste_signals: none');
  }
  const alerts = result.proactive_alerts || [];
  if (alerts.length) {
    console.log('主动提醒:');
    for (const alert of alerts) {
      console.log(`- [${alert.severity}] ${alert.message}: ${(alert.signals || []).join(', ')}`);
      if (alert.next_action) console.log(`  next_action: ${alert.next_action}`);
    }
  } else {
    console.log('主动提醒: none');
  }
  const plan = result.token_saving_plan || {};
  console.log('节省 token 计划:');
  console.log(`mode: ${plan.mode || 'active_and_passive'}`);
  for (const action of plan.actions || []) {
    console.log(`- ${action.action} (${action.signal})`);
    if (action.execution) console.log(`  execution: ${action.execution}`);
  }
  console.log('建议: 优先治理 model_mismatch、tool_noise_waste、context_thickening_waste 和 failure_retry_waste；复杂判断保留高成本推理。');
  if ((result.findings || []).length) console.log(`findings: ${result.findings.map((finding) => finding.code).join(', ')}`);
  console.log(`cost_ledger_path: ${result.cost_ledger_path}`);
}

function main() {
  try {
    const args = parseArgs(process.argv);
    const result = args.command === 'init'
      ? init(args)
      : args.command === 'append'
        ? append(args)
        : summarize(path.resolve(args.projectRoot), args.workflowId || '');
    if (args.command === 'summary') writeSummary(path.resolve(args.projectRoot), result);
    print(result, args.json);
  } catch (error) {
    fail(error.message);
  }
}

main();
