'use strict';

const crypto = require('crypto');

const CONTRACT_VERSION = '1.0.0';
const NEEDS = {
  accepted_facts: {
    description: '已采纳的角色、世界观与事件事实，用于保证正文不与已确定内容矛盾',
    maps_to: 'relevant_lore, hard_constraints',
  },
  active_cast: {
    description: '当前在场角色及其状态约束，用于本节对话与行动的连贯',
    maps_to: 'active_cast',
  },
  active_promises: {
    description: '尚未兑现的伏笔与读者期待，用于判断本节是否需要推进或回收',
    maps_to: 'hard_constraints',
  },
  confirmed_style_rules: {
    description: '作者已确认的句法节奏、表达偏好，用于约束正文风格',
    maps_to: 'author_voice, hard_constraints',
  },
  confirmed_quality_rules: {
    description: '已确认的质量门规则（AI 味、退化检测容忍线），用于本节自检',
    maps_to: 'negative_constraints',
  },
  planning_constraints: {
    description: '已确认的规划约束——本节必须达成的目标、禁止偏离的走向',
    maps_to: 'hard_constraints',
  },
  continuity_obligations: {
    description: '跨节连续性义务（上一节留下的悬念、待接的动作），用于衔接',
    maps_to: 'must_inherit, hard_constraints',
  },
  canon_constraints: {
    description: '已确认的规划约束（本节目标、走向边界、已采纳计划派生的硬约束），用于防止偏离既定规划',
    maps_to: 'hard_constraints',
  },
  reader_promise: {
    description: '对读者的核心承诺（爽点节奏、情感线走向），用于 brief 阶段定向',
    maps_to: 'hard_constraints',
  },
  review_dependencies: {
    description: '审阅依赖——上一轮审阅发现的待修项，用于 review/deslop 阶段',
    maps_to: 'task_context',
  },
  user_preferences: {
    description: '作者的通用写作偏好（非作品特定），用于所有阶段的轻量定向',
    maps_to: 'author_voice',
  },
};

const NEED_KEYS = Object.keys(NEEDS);
const NEED_SET = new Set(NEED_KEYS);

function needsForStage(workflowType, stageId) {
  const type = String(workflowType || '');
  const stage = String(stageId || '');
  if (/(?:scan|cover|setup)/u.test(type)) return ['user_preferences'];
  if (/(?:analyze|review|deslop)/u.test(type)) {
    return ['accepted_facts', 'review_dependencies', 'confirmed_quality_rules', 'user_preferences'];
  }
  // short_write / long_write 按阶段裁剪
  const briefStages = ['first_section_brief', 'section_brief', 'next_section_brief'];
  if (briefStages.includes(stage) || /brief/u.test(stage)) {
    return ['planning_constraints', 'reader_promise', 'active_cast', 'confirmed_style_rules', 'active_promises'];
  }
  if (stage === 'draft_section' || stage === 'section_draft' || stage === 'draft_first_section' || stage === 'draft_next_section') {
    return ['active_cast', 'planning_constraints', 'continuity_obligations', 'confirmed_style_rules', 'canon_constraints', 'active_promises'];
  }
  if (stage === 'section_repair_loop' || stage === 'section_repair' || /repair/u.test(stage)) {
    return ['planning_constraints', 'continuity_obligations', 'canon_constraints', 'confirmed_quality_rules'];
  }
  if (stage === 'feedback_impact_sync' || stage === 'feedback_apply_patch') {
    return ['planning_constraints', 'continuity_obligations'];
  }
  // 默认：返回宽集合（向后兼容旧项目/未知阶段）
  return ['accepted_facts', 'active_cast', 'active_promises', 'confirmed_style_rules',
    'confirmed_quality_rules', 'planning_constraints', 'continuity_obligations',
    'canon_constraints', 'user_preferences'];
}

function describeNeeds(needKeys) {
  return unique(needKeys)
    .filter((key) => NEED_SET.has(key))
    .map((key) => ({ key, description: NEEDS[key].description, maps_to: NEEDS[key].maps_to }));
}

function normalizeMemoryQuery(value = {}) {
  const needs = unique(value.needs).map(String);
  const unknown = needs.filter(need => !NEED_SET.has(need));
  if (unknown.length) throw invalid(`unsupported memory needs: ${unknown.join(', ')}`);
  if (!needs.length) throw invalid('memory query needs at least one typed need');
  const attemptRaw = String(value.stage_attempt_id || '').trim();
  const workUnitRaw = String(value.work_unit_id || '').trim();
  if (!attemptRaw && workUnitRaw) throw invalid('stage_attempt_id is required when work_unit_id is provided');
  const base = {
    schema_version: CONTRACT_VERSION,
    project_id: required(value.project_id, 'project_id'),
    project_instance_id: String(value.project_instance_id || ''),
    workflow_id: required(value.workflow_id, 'workflow_id'),
    workflow_type: String(value.workflow_type || ''),
    stage_id: required(value.stage_id, 'stage_id'),
    owner_module: String(value.owner_module || ''),
    scope: plainObject(value.scope),
    needs,
    query_text: String(value.query_text || ''),
  };
  if (attemptRaw) base.stage_attempt_id = attemptRaw;
  if (workUnitRaw) base.work_unit_id = workUnitRaw;
  return base;
}

function createMemoryContract(options = {}) {
  const query = normalizeMemoryQuery(options.query || {});
  const body = {
    schema_version: CONTRACT_VERSION,
    provider: String(options.provider || 'story-memory'),
    query,
    memory_revision: required(options.memoryRevision, 'memoryRevision'),
    packet_path: String(options.packetPath || ''),
    packet_digest: String(options.packetDigest || ''),
    token_budget: positive(options.tokenBudget),
    used_tokens: positive(options.usedTokens),
    selected_entry_ids: unique(options.selectedEntryIds),
    omitted_count: Math.max(0, Number(options.omittedCount || 0)),
    read_receipt_required: options.readReceiptRequired !== false,
    accepts_memory_updates: options.acceptsMemoryUpdates !== false,
  };
  return { ...body, contract_digest: digest(body) };
}

function createMemoryReadReceipt(contract) {
  if (!contract || !contract.contract_digest) throw invalid('memory contract is required');
  const query = contract.query || {};
  const receipt = {
    schema_version: CONTRACT_VERSION,
    provider: String(contract.provider || 'story-memory'),
    workflow_id: String(query.workflow_id || ''),
    stage_id: String(query.stage_id || ''),
    contract_digest: String(contract.contract_digest || ''),
    memory_revision: String(contract.memory_revision || ''),
    packet_digest: String(contract.packet_digest || ''),
    selected_entry_ids: unique(contract.selected_entry_ids),
  };
  if (query.stage_attempt_id) receipt.stage_attempt_id = String(query.stage_attempt_id);
  if (query.work_unit_id) receipt.work_unit_id = String(query.work_unit_id);
  return receipt;
}

function validateMemoryReadReceipt(contract, receipt) {
  if (!contract || !contract.read_receipt_required) return { status: 'not_required' };
  if (!receipt || typeof receipt !== 'object') return { status: 'missing' };
  const query = contract.query || {};
  const fields = ['provider', 'contract_digest', 'memory_revision', 'packet_digest'];
  const stale_fields = fields.filter(field => String(receipt[field] || '') !== String(contract[field] || ''));
  if (String(receipt.workflow_id || '') !== String(query.workflow_id || '')) stale_fields.push('workflow_id');
  if (String(receipt.stage_id || '') !== String(query.stage_id || '')) stale_fields.push('stage_id');
  // Execution binding: when the contract was minted with stage_attempt_id +
  // work_unit_id the receipt must echo the same pair. Legacy contracts
  // without binding keep validating by the old fields only — backward
  // compatibility for old projects that never carried execution context.
  if (query.stage_attempt_id) {
    if (String(receipt.stage_attempt_id || '') !== String(query.stage_attempt_id || '')) stale_fields.push('stage_attempt_id');
  }
  if (query.work_unit_id) {
    if (String(receipt.work_unit_id || '') !== String(query.work_unit_id || '')) stale_fields.push('work_unit_id');
  }
  return stale_fields.length ? { status: 'stale', stale_fields: unique(stale_fields) } : { status: 'current' };
}

function digest(value) {
  return `sha256:${crypto.createHash('sha256').update(stableJson(value)).digest('hex')}`;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

function required(value, field) { const text = String(value || '').trim(); if (!text) throw invalid(`${field} is required`); return text; }
function plainObject(value) { return value && typeof value === 'object' && !Array.isArray(value) ? { ...value } : {}; }
function positive(value) { const number = Number(value); return Number.isFinite(number) && number > 0 ? number : 0; }
function unique(values) { return [...new Set((Array.isArray(values) ? values : []).map(item => String(item || '')).filter(Boolean))]; }
function invalid(message) { const error = new Error(message); error.code = 'MEMORY_QUERY_CONTRACT_INVALID'; return error; }

module.exports = {
  CONTRACT_VERSION,
  NEEDS,
  NEED_KEYS,
  needsForStage,
  describeNeeds,
  createMemoryContract,
  createMemoryReadReceipt,
  normalizeMemoryQuery,
  validateMemoryReadReceipt,
};
