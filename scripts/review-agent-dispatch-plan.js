#!/usr/bin/env node
'use strict';

const fs = require('fs');
const { planReviewRoles } = require('./lib/review-role-policy');

const args = parseArgs(process.argv);
const scope = args.scope || '';
const batch = args.batch || scope;
const availableAgents = new Set(args.agentsAvailable);
const riskTags = args.risk.split(',').map((item) => item.trim()).filter(Boolean);
const existingReports = Number(args.existingReports || 0);

if (!scope) die('--scope is required');

const persistedPlan = args.dispatchPlan ? readDispatchPlan(args.dispatchPlan) : null;
const selectedPlan = persistedPlan || planReviewRoles({
  requiredDimensions: args.requiredDimensions,
  evidenceSignals: riskTags,
  availableAgents: Array.from(availableAgents),
  budgetPolicy: {},
});
const executionPlan = {
  mode: selectedPlan.mode,
  dispatch_reason: dispatchReason(scope, batch, riskTags),
  agents: (selectedPlan.roles || []).filter((role) => availableAgents.has(role.subagent_type)),
  deferred_dimensions: selectedPlan.deferredDimensions || [],
  retry_policy: selectedPlan.retryPolicy || 'missing_dimension_once',
  merge_policy: 'single_writer_merge',
  handoff_policy: 'write_file_then_handoff',
};
if (!executionPlan.agents.length) executionPlan.mode = 'solo_fallback';

const result = {
  status: 'ok',
  parent_scope: scope,
  batch_scope: batch,
  chapter_span: chapterSpan(scope),
  user_decision_required: false,
  existing_reports_policy: existingReports > 0 ? 'use_as_evidence_then_verify' : 'none',
  execution_plan: executionPlan,
  next_state: {
    parent_scope_preserved: true,
    batch_scope_preserved: true,
    stage: 'classify_findings',
    should_write_result_packet: true,
  },
  visible_options: buildVisibleOptions(scope, batch, executionPlan, existingReports),
};

if (args.json) console.log(JSON.stringify(result, null, 2));
else {
  console.log(`status: ${result.status}`);
  console.log(`mode: ${result.execution_plan.mode}`);
}

function parseArgs(argv) {
  const out = {
    scope: '',
    batch: '',
    risk: '',
    requiredDimensions: ['plot', 'hooks', 'character', 'canon', 'prose'],
    existingReports: 0,
    agentsAvailable: [],
    dispatchPlan: '',
    json: false,
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--scope') out.scope = argv[++i] || '';
    else if (arg === '--batch') out.batch = argv[++i] || '';
    else if (arg === '--risk') out.risk = argv[++i] || 'normal';
    else if (arg === '--dimensions') out.requiredDimensions = String(argv[++i] || '').split(',').map((item) => item.trim()).filter(Boolean);
    else if (arg === '--existing-reports') out.existingReports = Number(argv[++i] || 0);
    else if (arg === '--agents-available') out.agentsAvailable = String(argv[++i] || '').split(',').map((item) => item.trim()).filter(Boolean);
    else if (arg === '--dispatch-plan') out.dispatchPlan = argv[++i] || '';
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') {
      console.log('Usage: node review-agent-dispatch-plan.js --scope <range> [--batch <range>] [--risk tags] [--dimensions a,b] [--dispatch-plan file] [--existing-reports n] [--agents-available a,b,c] [--json]');
      process.exit(0);
    } else {
      die(`unknown argument: ${arg}`);
    }
  }
  return out;
}

function buildVisibleOptions(scopeValue, batchValue, plan, reportCount) {
  const autoText = plan.mode === 'agent_dispatch'
    ? `自动分派 ${plan.agents.length} 个 reviewer agent；父范围 ${scopeValue} 保留，本批只处理 ${batchValue}。`
    : `agent 不可用，自动降级 solo；父范围 ${scopeValue} 保留，本批只处理 ${batchValue}。`;
  const reportText = reportCount > 0 ? '旧报告作为证据输入并复核，不直接当本次结论。' : '无旧报告输入。';
  return [
    {
      number: 1,
      action_id: 'continue_current_review_batch',
      label: `继续审阅 ${batchValue}`,
      description: `${autoText}${reportText}`,
    },
    {
      number: 2,
      action_id: 'narrow_current_batch',
      label: '临时缩小本批高风险点',
      description: `只窄化当前批次，不丢失父任务 ${scopeValue}。`,
    },
    {
      number: 3,
      action_id: 'pause',
      label: '停止并保存断点',
      description: '保存父范围、当前批次、已发现风险和下一步恢复入口。',
    },
  ];
}

function dispatchReason(scopeValue, batchValue, risks) {
  const reasons = [];
  if (scopeValue) reasons.push('review_scope');
  if (batchValue) reasons.push('batch_review');
  if (risks.some((risk) => /ai|prose|conflict/.test(risk))) reasons.push('evidence_risk');
  return reasons.join(',') || 'review_batch';
}

function chapterSpan(value) {
  const nums = String(value || '').match(/\d{1,4}/g);
  if (!nums || nums.length === 0) return 0;
  if (nums.length === 1) return 1;
  return Math.abs(Number(nums[nums.length - 1]) - Number(nums[0])) + 1;
}

function readDispatchPlan(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || !Array.isArray(parsed.roles)) throw new Error('roles are required');
    return parsed;
  } catch (error) {
    die(`invalid --dispatch-plan: ${error.message}`);
  }
}

function die(message) {
  console.error(message);
  process.exit(2);
}
