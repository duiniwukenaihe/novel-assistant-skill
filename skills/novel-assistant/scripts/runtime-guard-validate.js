#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node runtime-guard-validate.js --kind current-task|workflow-packet|result-packet <file> [--json]

Validates long-task runtime guard, checkpoint, heartbeat and output-health contracts.`;

const RUNTIME_GUARD_FIELDS = [
  'token_estimate',
  'adaptive_budget_policy',
  'heartbeat',
  'checkpoint_policy',
  'output_health_gate',
  'max_retry_budget',
  'stall_policy',
];

const TOKEN_ESTIMATE_FIELDS = [
  'input_files',
  'input_chars_estimate',
  'output_chars_budget',
  'agent_count',
  'batch_size',
  'risk_level',
];

const TOKEN_COST_GOVERNANCE_FIELDS = [
  'cost_ledger_path',
  'cost_summary_path',
  'model_routing_policy',
  'tool_output_filter',
  'retry_budget_result',
];

const RESULT_RUNTIME_FIELDS = [
  'checkpoint_state',
  'heartbeat_update',
  'budget_usage',
  'output_health_result',
  'handoff_packet_path',
  'resume_hint',
];

const CHECKPOINT_FIELDS = [
  'current_stage',
  'current_batch',
  'completed_range',
  'remaining_range',
  'failed_items',
  'reusable_outputs',
  'resume_from',
];

function parseArgs(argv) {
  const args = { kind: '', file: '', json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--kind') args.kind = argv[++i] || '';
    else if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else if (!args.file) args.file = arg;
    else fail(`Unknown argument: ${arg}`);
  }
  if (!['current-task', 'workflow-packet', 'result-packet'].includes(args.kind)) {
    fail('missing or invalid --kind');
  }
  if (!args.file) fail('missing input file');
  return args;
}

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(1);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return {
      __parseError: error.message,
    };
  }
}

function hasValue(value) {
  if (value === undefined || value === null) return false;
  if (typeof value === 'string') return value.trim().length > 0;
  if (Array.isArray(value)) return value.length > 0;
  if (typeof value === 'object') return Object.keys(value).length > 0;
  return true;
}

function getPath(obj, dottedPath) {
  return dottedPath.split('.').reduce((current, part) => {
    if (current && Object.prototype.hasOwnProperty.call(current, part)) return current[part];
    return undefined;
  }, obj);
}

function missingFields(obj, fields, prefix = '') {
  return fields
    .map(field => (prefix ? `${prefix}.${field}` : field))
    .filter(field => !hasValue(getPath(obj, field)));
}

function looksLongTask(doc) {
  const scope = doc.scope || {};
  const policy = String(doc.completion_policy || '');
  const workflowType = String(doc.workflow_type || '');
  const risk = String(doc.risk_level || getPath(doc, 'runtime_guard.token_estimate.risk_level') || '');
  const scopeText = JSON.stringify(scope);
  return (
    policy === 'full_auto' ||
    policy === 'stage_then_confirm' ||
    ['long_analyze', 'review', 'long_review', 'import', 'revision', 'scan', 'setup_refresh'].some(token => workflowType.includes(token)) ||
    ['high', 'destructive'].includes(risk) ||
    /book|range|全书|批次|1-\d{2,}|[1-9]\d{2,}/.test(scopeText)
  );
}

function validateRuntimeGuard(doc, findings) {
  if (!looksLongTask(doc)) return;
  if (doc.runtime_guard === 'none') {
    findings.push(finding('blocked_runtime_guard_missing', 'runtime_guard', '长任务不能把 runtime_guard 写成 none。'));
    return;
  }
  if (!hasValue(doc.runtime_guard)) {
    findings.push(finding('blocked_runtime_guard_missing', 'runtime_guard', '长任务缺少 runtime_guard，无法无人值守恢复。'));
    return;
  }
  for (const field of missingFields(doc, RUNTIME_GUARD_FIELDS, 'runtime_guard')) {
    findings.push(finding('blocked_runtime_guard_incomplete', field, 'runtime_guard 缺少必填运行边界字段。'));
  }
  for (const field of missingFields(doc, TOKEN_ESTIMATE_FIELDS, 'runtime_guard.token_estimate')) {
    findings.push(finding('blocked_runtime_guard_incomplete', field, 'token_estimate 缺少预算字段。'));
  }
  for (const field of missingFields(doc, TOKEN_COST_GOVERNANCE_FIELDS, 'runtime_guard.token_cost_governance')) {
    findings.push(finding('blocked_token_cost_governance_missing', field, '长任务缺少 token_cost_governance，无法记录模型错配、工具噪音、上下文膨胀和失败重试成本。'));
  }
}

function validateCurrentTask(doc) {
  const findings = [];
  validateRuntimeGuard(doc, findings);
  return finalize(findings);
}

function validateWorkflowPacket(doc) {
  const findings = [];
  validateRuntimeGuard(doc, findings);
  for (const field of missingFields(doc, ['workflow_id', 'workflow_type', 'book_root', 'scope', 'owner_module', 'completion_policy'])) {
    findings.push(finding('blocked_workflow_packet_incomplete', field, 'workflow packet 缺少基础字段。'));
  }
  return finalize(findings);
}

function validateResultPacket(doc) {
  const findings = [];
  for (const field of missingFields(doc, RESULT_RUNTIME_FIELDS)) {
    findings.push(finding('blocked_result_packet_incomplete', field, 'result packet 缺少运行状态回执字段。'));
  }
  if (hasValue(doc.checkpoint_state)) {
    for (const field of missingFields(doc.checkpoint_state, CHECKPOINT_FIELDS, 'checkpoint_state')) {
      findings.push(finding('blocked_result_packet_incomplete', field, 'checkpoint_state 不足以恢复续跑。'));
    }
  }
  if (String(doc.verification_result || '').toLowerCase() === 'pass') {
    const healthStatus = String(getPath(doc, 'output_health_result.status') || '').toLowerCase();
    if (!healthStatus) {
      findings.push(finding('blocked_result_packet_incomplete', 'output_health_result.status', 'verification_result=pass 时必须有输出健康门结果。'));
    } else if (!['ok', 'pass', 'passed', 'clean'].includes(healthStatus)) {
      findings.push(finding('blocked_output_health_failed', 'output_health_result.status', '输出健康门未通过，不能声明 verification_result=pass。'));
    }
  }
  if (String(doc.verification_result || '').toLowerCase() === 'failed' && ['done', 'completed'].includes(String(doc.step_status || '').toLowerCase())) {
    findings.push(finding('blocked_result_status_conflict', 'step_status', '验证失败时不能把 step_status 标成完成。'));
  }
  return finalize(findings);
}

function finding(status, field, message) {
  return { status, field, message };
}

function finalize(findings) {
  if (findings.length === 0) {
    return { exitCode: 0, result: { status: 'ok', findings: [] } };
  }
  const status = findings.find(item => item.status === 'blocked_output_health_failed')?.status || findings[0].status;
  return { exitCode: 2, result: { status, findings } };
}

function main() {
  const args = parseArgs(process.argv);
  const absFile = path.resolve(args.file);
  const doc = readJson(absFile);
  if (doc.__parseError) {
    const result = {
      status: 'blocked_invalid_json',
      findings: [{ status: 'blocked_invalid_json', field: absFile, message: doc.__parseError }],
    };
    print(result, args.json);
    process.exit(2);
  }

  const validation =
    args.kind === 'current-task'
      ? validateCurrentTask(doc)
      : args.kind === 'workflow-packet'
        ? validateWorkflowPacket(doc)
        : validateResultPacket(doc);

  const result = {
    ...validation.result,
    kind: args.kind,
    file: absFile,
  };
  print(result, args.json);
  process.exit(validation.exitCode);
}

function print(result, json) {
  if (json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  console.log(`${result.status}: ${result.findings.length} finding(s)`);
  for (const item of result.findings) {
    console.log(`- ${item.field}: ${item.message}`);
  }
}

main();
