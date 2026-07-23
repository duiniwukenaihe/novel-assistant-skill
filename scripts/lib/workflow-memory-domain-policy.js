'use strict';

const CONTROL_DOMAIN_VALUES = new Set([
  'control',
  'menu',
  'routing',
  'runtime',
  'session',
  'setup',
  'task',
  'workflow',
]);

const CONTROL_ID_PATTERN = /(?:^|[._-])(bundle|menu|owner|route|routing|runtime|session|setup|task|workflow)(?:[._-]|$)/i;
const CONTROL_CONTENT_PATTERNS = [
  /(?:当前|本地|公开|私有).{0,12}(?:任务|工作流|流程).{0,18}(?:接管|路由|模块|owner|运行|状态)/u,
  /(?:owner_module|workflow_id|task_family_id|bundleId|stage_attempt_id)/i,
  /(?:协作环境|技能包|skill).{0,16}(?:更新|安装|路由|接管|版本)/iu,
  /(?:回复|选择|输入)\s*[1-9](?:\s*[\/、,，]\s*[1-9]){1,}/u,
];

function classifyMemoryUpdateDomain(update) {
  const item = update && typeof update === 'object' ? update : {};
  const explicitDomain = String(item.memory_domain || item.domain || '').trim().toLowerCase();
  const entryId = String(item.entryId || item.entry_id || item.id || '').trim();
  const content = String(item.proposedContent || item.content || '').trim();

  if (CONTROL_DOMAIN_VALUES.has(explicitDomain)) {
    return blocked('explicit_control_domain', explicitDomain, entryId);
  }
  if (CONTROL_ID_PATTERN.test(entryId)) {
    return blocked('control_identity', explicitDomain, entryId);
  }
  if (CONTROL_CONTENT_PATTERNS.some(pattern => pattern.test(content))) {
    return blocked('control_content', explicitDomain, entryId);
  }
  return {
    allowed: true,
    reason: 'story_memory_candidate',
    memory_domain: explicitDomain || inferStoryDomain(item),
    entry_id: entryId,
  };
}

function partitionMemoryUpdates(updates) {
  const accepted = [];
  const quarantined = [];
  for (const update of Array.isArray(updates) ? updates : []) {
    const decision = classifyMemoryUpdateDomain(update);
    if (decision.allowed) accepted.push({ ...update, memory_domain: decision.memory_domain });
    else quarantined.push({ update, decision });
  }
  return { accepted, quarantined };
}

function inferStoryDomain(item) {
  const type = String((item || {}).type || '').toLowerCase();
  if (/(style|voice)/.test(type)) return 'style';
  if (/(preference|author)/.test(type)) return 'preference';
  if (/(planning|constraint|outline)/.test(type)) return 'planning';
  if (/(learning|technique|pattern)/.test(type)) return 'learning';
  return 'story_fact';
}

function blocked(reason, memoryDomain, entryId) {
  return {
    allowed: false,
    reason,
    memory_domain: memoryDomain || 'control',
    entry_id: entryId || '',
  };
}

module.exports = {
  classifyMemoryUpdateDomain,
  partitionMemoryUpdates,
};
