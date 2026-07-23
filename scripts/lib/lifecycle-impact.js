'use strict';

const IMPACT_LEVELS = Object.freeze([
  'prose',
  'brief',
  'detail_outline',
  'volume_outline',
  'master_outline',
]);

const IMPACT_ALIASES = Object.freeze({
  prose: 'prose',
  chapter_prose: 'prose',
  brief: 'brief',
  chapter_brief: 'brief',
  detail_outline: 'detail_outline',
  stage_detail_outline: 'detail_outline',
  volume_outline: 'volume_outline',
  master_outline: 'master_outline',
  story_bible: 'master_outline',
});

const RETURN_NODES = Object.freeze({
  prose: 'prose',
  brief: 'chapter_brief',
  detail_outline: 'stage_detail_outline',
  volume_outline: 'volume_outline',
  master_outline: 'master_outline',
});

const STRUCTURE_CHANGE_TYPES = new Set([
  'expand', 'expansion', 'contract', 'contraction', 'shrink',
  'insert', 'insert_chapter', 'merge', 'merge_chapters',
  'delete', 'delete_chapter', 'move', 'reorder',
  '扩容', '缩容', '插章', '合并', '删章', '前移', '后移', '重排',
]);

const TEXT_RULES = [
  ['master_outline', /总纲|全书|整本书|主线|结局|核心承诺|故事核心|创作圣经|master[_ -]?outline/i],
  ['volume_outline', /卷纲|本卷|整卷|跨卷|volume[_ -]?outline/i],
  ['detail_outline', /阶段细纲|细纲|插章|插入.{0,6}章|扩容|缩容|删章|删除.{0,6}章|合并.{0,6}章|章节合并|章节重排|重排章节|detail[_ -]?outline/i],
  ['brief', /章节\s*brief|\bbrief\b|章节契约|场景目标/i],
  ['prose', /正文|润色|措辞|文风|语句|prose/i],
];

function normalizeImpactLevel(value) {
  const key = String(value || '').trim().toLowerCase().replace(/[ -]+/g, '_');
  return IMPACT_ALIASES[key] || null;
}

function classifyFeedbackImpact(feedback) {
  if (feedback && typeof feedback === 'object' && !Array.isArray(feedback)) {
    for (const field of ['impact_level', 'level', 'target', 'kind', 'asset_kind']) {
      const explicit = normalizeImpactLevel(feedback[field]);
      if (explicit) return explicit;
    }
    feedback = feedback.feedback || feedback.text || feedback.message || '';
  }

  const text = String(feedback || '').trim();
  for (const [level, pattern] of TEXT_RULES) {
    if (pattern.test(text)) return level;
  }
  throw new TypeError('feedback must identify one lifecycle impact level');
}

function graphAssets(graph) {
  const source = graph && graph.assets !== undefined ? graph.assets : graph;
  if (Array.isArray(source)) return source.filter(asset => asset && typeof asset === 'object');
  if (!source || typeof source !== 'object') return [];
  return Object.entries(source).map(([id, asset]) => (
    asset && typeof asset === 'object' ? { id, ...asset } : { id, status: asset }
  ));
}

function dependencyIds(asset) {
  const dependencies = asset.depends_on || asset.dependsOn || [];
  return Array.isArray(dependencies) ? dependencies.map(String) : [];
}

function isAcceptedProse(asset) {
  return normalizeImpactLevel(asset.kind || asset.asset_kind) === 'prose'
    && asset.status === 'accepted';
}

function invalidateDownstream(graph, changedAsset) {
  const assets = graphAssets(graph);
  const changedId = typeof changedAsset === 'string'
    ? changedAsset
    : changedAsset && changedAsset.id;
  if (!changedId) throw new TypeError('changedAsset.id is required');

  const affected = new Set([String(changedId)]);
  let expanded = true;
  while (expanded) {
    expanded = false;
    for (const asset of assets) {
      const id = String(asset.id || '');
      if (!id || affected.has(id)) continue;
      if (dependencyIds(asset).some(dependency => affected.has(dependency))) {
        affected.add(id);
        expanded = true;
      }
    }
  }

  const needsRecheck = [];
  const invalidated = [];
  const preserved = [];
  const metadataUpdates = [];

  for (const asset of assets) {
    const id = String(asset.id || '');
    if (!id || id === String(changedId) || !affected.has(id)) continue;
    if (isAcceptedProse(asset)) {
      preserved.push(id);
      metadataUpdates.push({
        id,
        status: 'preserve_until_proven_invalid',
        lifecycle_status: 'accepted',
        invalidated_by: String(changedId),
      });
    } else if (asset.status === 'accepted') {
      needsRecheck.push(id);
      metadataUpdates.push({ id, status: 'needs_recheck', invalidated_by: String(changedId) });
    } else {
      invalidated.push(id);
      metadataUpdates.push({ id, status: 'invalidated', invalidated_by: String(changedId) });
    }
  }

  return {
    changed_asset: String(changedId),
    needs_recheck: needsRecheck,
    invalidated,
    preserve_until_proven_invalid: preserved,
    metadata_updates: metadataUpdates,
    delete_assets: [],
    overwrite_assets: [],
  };
}

function isStructureChange(value) {
  const normalized = String(value || '').trim().toLowerCase().replace(/[ -]+/g, '_');
  return STRUCTURE_CHANGE_TYPES.has(normalized);
}

function higherImpact(a, b) {
  return IMPACT_LEVELS.indexOf(a) >= IMPACT_LEVELS.indexOf(b) ? a : b;
}

function buildReplanActions(impact) {
  const source = impact && typeof impact === 'object' ? impact : { impact_level: impact };
  const structureChange = isStructureChange(source.change_type || source.structure_change || source.operation);
  let impactLevel;
  try {
    impactLevel = classifyFeedbackImpact(source);
  } catch (error) {
    if (!structureChange) throw error;
    impactLevel = 'detail_outline';
  }
  if (structureChange) impactLevel = higherImpact(impactLevel, 'detail_outline');
  const returnTo = RETURN_NODES[impactLevel];

  return {
    impact_level: impactLevel,
    change_type: source.change_type || source.structure_change || source.operation || null,
    return_to: returnTo,
    requires_impact_analysis: true,
    preserve_chapter_names: true,
    preserve_reusable_content: true,
    allow_prose_delete: false,
    allow_prose_overwrite: false,
    downstream_effects: {
      requires_impact_analysis: true,
      return_to: returnTo,
      planning_assets: 'recheck_or_invalidate',
      accepted_prose: 'preserve_until_proven_invalid',
      delete_assets: [],
      overwrite_assets: [],
    },
    actions: [
      'return_to_planning',
      'analyze_downstream_impact',
      'preserve_chapter_names',
      'preserve_reusable_content',
    ],
  };
}

module.exports = {
  IMPACT_LEVELS,
  classifyFeedbackImpact,
  invalidateDownstream,
  buildReplanActions,
};
