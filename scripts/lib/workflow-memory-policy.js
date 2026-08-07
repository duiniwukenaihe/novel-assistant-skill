'use strict';

const { isShortWorkflowType } = require('./short-workflow-types');

const POLICIES = Object.freeze({
  long_startup: required(3600, true),
  short_startup: required(3000, true),
  long_write: required(4200, true),
  short_write: required(3600, true),
  // Migration-only alias for local tasks created before private short writing
  // converged on the canonical short_write workflow identity.
  private_short_startup: required(3600, true),
  review_repair: required(4200, true),
  // 只读审阅以 canonical 正文/设定/大纲为事实源。旧记忆失效时应隔离并提示，
  // 不能阻止审阅，也不能诱导宿主反复迁移记忆；修复写回阶段再使用 required。
  short_review: optional(2400, true),
  long_analyze: required(3200, true),
  short_analyze: required(2800, true),
  deslop: required(3000, true),
  long_scan: optional(1800, true),
  short_scan: optional(1800, true),
  cover: optional(1600, false),
  download_import: optional(2600, true),
  project_setup: none(),
  setup_update: none(),
});

const SHORT_STAGE_CONTEXT_ONLY = new Set([
  'first_section_brief',
  'section_brief',
  'next_section_brief',
  'draft_first_section',
  'draft_section',
  'draft_next_section',
  'section_repair_loop',
  'quality_gate',
  'story_value_gate',
  'section_accept_anchor',
  'feedback_impact_sync',
  'feedback_apply_patch',
  'full_story_review',
]);

const SHORT_NO_MEMORY_STAGES = new Set([
  'startup_scan',
  'startup_menu',
  'freshness_window',
  'info_source_pool',
  'info_source_selection',
  'material_learning',
  'project_seed',
  'section_machine_gate',
  'full_story_assembly',
  'short_deslop',
  'deslop',
  'final_check',
]);

function required(tokenBudget, acceptsUpdates) {
  return Object.freeze({ mode: 'required', token_budget: tokenBudget, accepts_memory_updates: acceptsUpdates });
}

function optional(tokenBudget, acceptsUpdates) {
  return Object.freeze({ mode: 'optional', token_budget: tokenBudget, accepts_memory_updates: acceptsUpdates });
}

function none(reason = '') {
  return Object.freeze({ mode: 'none', token_budget: 0, accepts_memory_updates: false, ...(reason ? { reason } : {}) });
}

function resolveWorkflowMemoryPolicy(workflowType, stageId = '') {
  const type = String(workflowType || '');
  const stage = String(stageId || '');
  if (isShortWorkflowType(type) && SHORT_NO_MEMORY_STAGES.has(stage)) {
    return none('short_preflight_or_discovery_uses_direct_source_evidence');
  }
  if (isShortWorkflowType(type) && SHORT_STAGE_CONTEXT_ONLY.has(stage)) {
    return none('current_story_snapshot_in_stage_context_packet');
  }
  const policy = POLICIES[type];
  if (!policy) return Object.freeze({ mode: 'missing', token_budget: 0, accepts_memory_updates: false });
  return policy;
}

function resolveStageMemoryPolicy(template, stageId = '') {
  const stage = template && Array.isArray(template.stages)
    ? template.stages.find((item) => String((item || {}).stage_id || '') === String(stageId || ''))
    : null;
  const contract = stage && stage.memory_contract && typeof stage.memory_contract === 'object'
    ? stage.memory_contract
    : null;
  return resolveMemoryContractPolicy(contract);
}

function resolveExecutionMemoryPolicy(execution) {
  const contract = execution && execution.memory_contract && typeof execution.memory_contract === 'object'
    ? execution.memory_contract
    : null;
  return resolveMemoryContractPolicy(contract);
}

function resolveMemoryContractPolicy(contract) {
  if (!contract) {
    return Object.freeze({
      mode: 'missing',
      token_budget: 0,
      accepts_memory_updates: false,
      context_source: 'none',
      update_mode: 'none',
      projection_mode: 'none',
      receipt_required: false,
      needs: [],
    });
  }
  return Object.freeze({
    mode: String(contract.read_mode || 'missing'),
    token_budget: Number(contract.token_budget || 0),
    accepts_memory_updates: String(contract.update_mode || 'none') === 'suggest',
    context_source: String(contract.context_source || 'none'),
    profile: String(contract.profile || ''),
    needs: Array.isArray(contract.needs) ? contract.needs.slice() : [],
    budget_policy: String(contract.budget_policy || ''),
    receipt_required: contract.receipt_required === true,
    update_mode: String(contract.update_mode || 'none'),
    projection_mode: String(contract.projection_mode || 'none'),
  });
}

module.exports = {
  POLICIES,
  SHORT_STAGE_CONTEXT_ONLY,
  SHORT_NO_MEMORY_STAGES,
  resolveExecutionMemoryPolicy,
  resolveMemoryContractPolicy,
  resolveStageMemoryPolicy,
  resolveWorkflowMemoryPolicy,
};
