'use strict';

const LIFECYCLE_NODES = [
  ['positioning', '创作定位'], ['story_bible', '故事核心与创作圣经'],
  ['master_outline', '总纲设计'], ['master_outline_review', '总纲审阅'],
  ['volume_outline', '卷纲设计'], ['volume_outline_review', '卷纲审阅'],
  ['stage_detail_outline', '阶段细纲设计'], ['detail_outline_review', '细纲审阅'],
  ['chapter_brief', '章节 Brief'], ['brief_review', 'Brief 审阅'],
  ['prose', '正文生产'], ['prose_acceptance', '正文验收'],
  ['chapter_commit', '事实与记忆提交'], ['milestone_review', '阶段复盘'],
  ['volume_acceptance', '卷级验收与跨卷交接'], ['book_acceptance', '全书验收'],
].map(([id, label], order) => ({ id, label, order }));

const ASSET_STATUSES = new Set([
  'missing', 'draft', 'needs_review', 'accepted', 'needs_recheck', 'invalidated',
]);

function lifecycleSource(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return {};
  if (input.assets && typeof input.assets === 'object' && !Array.isArray(input.assets)) return input.assets;
  return input;
}

function normalizeStatus(value) {
  const status = value && typeof value === 'object' ? value.status : value;
  return ASSET_STATUSES.has(status) ? status : 'missing';
}

function normalizeLifecycleState(input) {
  const source = lifecycleSource(input);
  return Object.fromEntries(LIFECYCLE_NODES.map(node => [node.id, normalizeStatus(source[node.id])]));
}

function deriveMaturity(state) {
  const normalized = normalizeLifecycleState(state);
  const statuses = Object.values(normalized);
  if (statuses.includes('invalidated')) return 'invalidated';
  if (statuses.includes('needs_recheck')) return 'needs_recheck';
  if (statuses.includes('needs_review')) return 'needs_review';
  if (statuses.includes('draft')) return 'draft';
  if (statuses.every(status => status === 'accepted')) return 'accepted';
  return 'missing';
}

function allowedLoop(from, to) {
  return (from === 'chapter_commit' && ['chapter_brief', 'milestone_review'].includes(to))
    || (from === 'milestone_review' && ['stage_detail_outline', 'chapter_brief', 'volume_acceptance'].includes(to))
    || (from === 'volume_acceptance' && ['volume_outline', 'book_acceptance'].includes(to));
}

function validateLifecycleTransition(from, to) {
  const a = LIFECYCLE_NODES.find(node => node.id === from);
  const b = LIFECYCLE_NODES.find(node => node.id === to);
  return { allowed: Boolean(a && b && (b.order === a.order + 1 || allowedLoop(from, to))), from, to };
}

function nextLifecycleActions(state) {
  const normalized = normalizeLifecycleState(state);
  const repair = LIFECYCLE_NODES.find(node => ['invalidated', 'needs_recheck'].includes(normalized[node.id]));
  if (repair) return [repair.id];

  const next = LIFECYCLE_NODES.find(node => normalized[node.id] !== 'accepted');
  return next ? [next.id] : [];
}

module.exports = {
  LIFECYCLE_NODES,
  normalizeLifecycleState,
  deriveMaturity,
  nextLifecycleActions,
  validateLifecycleTransition,
};
