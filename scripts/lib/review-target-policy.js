'use strict';

const fs = require('fs');
const path = require('path');

const REVIEW_TARGET_KINDS = Object.freeze([
  'master_outline',
  'volume_outline',
  'stage_detail_outline',
  'chapter_brief',
  'prose_unit',
  'milestone',
  'volume',
  'book',
]);

const DYNAMIC_REVIEW_TARGETS = new Set(['prose_unit', 'milestone', 'volume', 'book']);

const ASSET_DEPENDENCY_CHAINS = Object.freeze({
  master_outline: ['master_outline'],
  volume_outline: ['master_outline', 'volume_outline'],
  stage_detail_outline: ['master_outline', 'volume_outline', 'stage_detail_outline'],
  chapter_brief: ['master_outline', 'volume_outline', 'stage_detail_outline', 'chapter_brief'],
});

const LIFECYCLE_TARGETS = Object.freeze({
  master_outline: 'master_outline',
  master_outline_review: 'master_outline',
  volume_outline: 'volume_outline',
  volume_outline_review: 'volume_outline',
  stage_detail_outline: 'stage_detail_outline',
  detail_outline_review: 'stage_detail_outline',
  chapter_brief: 'chapter_brief',
  brief_review: 'chapter_brief',
  prose: 'prose_unit',
  prose_acceptance: 'prose_unit',
  chapter_commit: 'prose_unit',
  milestone_review: 'milestone',
  volume_acceptance: 'volume',
  book_acceptance: 'book',
});

function resolveReviewTarget(input = {}, lifecycleState = {}) {
  const source = input && typeof input === 'object' ? input : { text: input };
  const text = String(source.text || source.user_goal || source.userGoal || '').trim();
  const explicitKind = String(source.kind || '');
  const lifecycleNode = String(lifecycleState.current_node || lifecycleState.current_stage || lifecycleState.lifecycle_node || '');
  const kind = REVIEW_TARGET_KINDS.includes(explicitKind)
    ? explicitKind
    : inferKind(text, source, lifecycleNode);
  const narrativeScope = inferNarrativeScope(kind, text, source, lifecycleState);
  return {
    kind,
    visible_label: `审阅${narrativeScope}`,
    narrative_scope: narrativeScope,
    target_ref: inferTargetRef(kind, source, lifecycleState, narrativeScope),
  };
}

function reviewEvidencePolicy(target) {
  const normalized = normalizeTarget(target);
  const dynamic = DYNAMIC_REVIEW_TARGETS.has(normalized.kind);
  const readAssets = dynamic
    ? dynamicReadAssets(normalized.kind)
    : ASSET_DEPENDENCY_CHAINS[normalized.kind].slice();
  return {
    mode: dynamic ? 'dynamic_evidence_plan' : 'asset_dependency_closure',
    use_dynamic_batches: dynamic,
    user_visible_batches: false,
    target_kind: normalized.kind,
    target_ref: normalized.target_ref || '',
    read_assets: readAssets,
    upstream_dependencies: readAssets.slice(0, -1),
    completion_scope: normalized.narrative_scope,
  };
}

function validateAssetDependencyEvidenceReceipt(policy, evidence, options = {}) {
  if (!policy || policy.mode !== 'asset_dependency_closure') {
    return { valid: false, missing_assets: [], invalid_entries: [] };
  }
  const entries = Array.isArray(evidence) ? evidence : [];
  const projectRoot = String(options.project_root || options.projectRoot || '').trim();
  const required = new Set((policy.read_assets || []).map(String));
  const inspected = entries.map((entry) => inspectEvidenceEntry(entry, projectRoot, required));
  const targetEntry = inspected.find((item) => item.valid && item.kind === String(policy.target_kind || ''));
  if (targetEntry && !sourceMatchesTarget(policy, targetEntry.source_ref)) {
    targetEntry.valid = false;
    targetEntry.reason = 'source_ref does not match review target';
  }
  if (targetEntry) validateUpstreamScope(inspected, targetEntry);
  const invalidEntries = inspected.filter((item) => !item.valid).map((item) => ({
    entry: item.entry,
    reason: item.reason,
  }));
  const received = new Set(inspected.filter((item) => item.valid).map((item) => item.kind));
  const missingAssets = (policy.read_assets || []).filter((kind) => !received.has(String(kind)));
  return {
    valid: invalidEntries.length === 0 && missingAssets.length === 0,
    missing_assets: missingAssets,
    invalid_entries: invalidEntries,
  };
}

function inspectEvidenceEntry(entry, projectRoot, required) {
  const kind = String((entry || {}).asset_kind || (entry || {}).kind || '').trim();
  const sourceRef = String((entry || {}).source_ref || (entry || {}).path || (entry || {}).asset_ref || '').trim();
  if (!entry || typeof entry !== 'object' || !kind || !sourceRef) {
    return { entry, kind, source_ref: sourceRef, valid: false, reason: 'asset_kind and source_ref are required' };
  }
  if (!required.has(kind)) return { entry, kind, source_ref: sourceRef, valid: false, reason: 'unexpected asset kind' };
  const trusted = trustedProjectFile(projectRoot, sourceRef);
  if (!trusted.valid) return { entry, kind, source_ref: sourceRef, valid: false, reason: trusted.reason };
  if (!sourceMatchesAssetKind(kind, sourceRef)) {
    return { entry, kind, source_ref: sourceRef, valid: false, reason: 'source_ref does not identify the declared asset kind' };
  }
  return { entry, kind, source_ref: sourceRef, valid: true };
}

function trustedProjectFile(projectRoot, sourceRef) {
  if (!projectRoot) return { valid: false, reason: 'project_root is required' };
  try {
    const realRoot = fs.realpathSync(path.resolve(projectRoot));
    const candidate = path.isAbsolute(sourceRef) ? path.resolve(sourceRef) : path.resolve(realRoot, sourceRef);
    const realFile = fs.realpathSync(candidate);
    const inside = realFile === realRoot || realFile.startsWith(`${realRoot}${path.sep}`);
    if (!inside || !fs.statSync(realFile).isFile()) return { valid: false, reason: 'source_ref is not a project file' };
    return { valid: true };
  } catch (_error) {
    return { valid: false, reason: 'source_ref is not a real project file' };
  }
}

function sourceMatchesAssetKind(kind, sourceRef) {
  const base = path.basename(sourceRef).replace(/\.md$/i, '');
  if (kind === 'master_outline') return /^(?:总纲|大纲|主纲|全书大纲)(?:[._-]|$)/.test(base);
  if (kind === 'volume_outline') return /卷纲|分卷大纲/.test(base);
  if (kind === 'stage_detail_outline') return /细纲|阶段大纲/.test(base);
  if (kind === 'chapter_brief') return /brief|章纲|章节说明/i.test(base);
  return false;
}

function sourceMatchesTarget(policy, sourceRef) {
  const target = canonicalOrdinals(String(policy.target_ref || policy.completion_scope || ''));
  const source = canonicalOrdinals(sourceRef);
  const volume = target.match(/第\d+卷/);
  const chapter = target.match(/第\d+章/);
  if (volume && !source.includes(volume[0])) return false;
  if (chapter && !source.includes(chapter[0])) return false;
  return true;
}

function validateUpstreamScope(inspected, targetEntry) {
  const target = canonicalOrdinals(targetEntry.source_ref);
  const targetVolume = (target.match(/第\d+卷/) || [])[0];
  const targetChapter = (target.match(/第\d+章/) || [])[0];
  for (const item of inspected) {
    if (!item.valid || item === targetEntry || item.kind === 'master_outline') continue;
    const source = canonicalOrdinals(item.source_ref);
    const sourceVolume = (source.match(/第\d+卷/) || [])[0];
    const sourceChapter = (source.match(/第\d+章/) || [])[0];
    if ((targetVolume && sourceVolume && targetVolume !== sourceVolume)
      || (item.kind === 'stage_detail_outline' && targetChapter && sourceChapter && targetChapter !== sourceChapter)) {
      item.valid = false;
      item.reason = 'upstream asset does not belong to the review target';
    }
  }
}

function canonicalOrdinals(value) {
  return String(value).replace(/第([零〇一二两三四五六七八九十百千万]+)([卷章])/g, (_match, numeral, unit) => `第${chineseNumber(numeral)}${unit}`);
}

function chineseNumber(value) {
  const digits = { 零: 0, '〇': 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const units = { 十: 10, 百: 100, 千: 1000, 万: 10000 };
  let total = 0;
  let current = 0;
  for (const char of value) {
    if (Object.prototype.hasOwnProperty.call(digits, char)) current = digits[char];
    else if (units[char] === 10000) { total = (total + current) * 10000; current = 0; }
    else if (units[char]) { total += (current || 1) * units[char]; current = 0; }
  }
  return total + current;
}

function inferKind(text, input, lifecycleNode) {
  if (/全书|整本|全本|完本/.test(text)) return 'book';
  if (/总纲|主纲|全书大纲/.test(text)) return 'master_outline';
  if (/卷纲|分卷大纲/.test(text)) return 'volume_outline';
  if (/细纲|阶段大纲/.test(text)) return 'stage_detail_outline';
  if (/brief|章节说明|章纲/i.test(text)) return 'chapter_brief';
  if (/正文|当前章|本章|第\s*[零一二三四五六七八九十百千万两\d]+\s*章/.test(text)) return 'prose_unit';
  if (/里程碑|阶段复盘|当前阶段|本阶段|阶段验收/.test(text)) return 'milestone';
  if (/第\s*[零一二三四五六七八九十百千万两\d]+\s*卷|当前卷|本卷|卷级/.test(text) || input.volume) return 'volume';
  if (LIFECYCLE_TARGETS[lifecycleNode]) return LIFECYCLE_TARGETS[lifecycleNode];
  return 'prose_unit';
}

function inferNarrativeScope(kind, text, input, lifecycleState) {
  const fromText = text
    .replace(/^(?:请|帮我|麻烦)?\s*(?:审阅|审查|复检|检查)\s*/, '')
    .trim();
  const assetTarget = lifecycleState.asset_target && typeof lifecycleState.asset_target === 'object'
    ? lifecycleState.asset_target
    : {};
  const volume = String(input.volume || assetTarget.id || '').trim();
  const stage = String(input.stage || '').trim();
  const chapter = String(input.chapter || '').trim();
  if (fromText && !/^(?:当前资产|这个资产|该资产)$/.test(fromText)) return fromText;
  if (kind === 'master_outline') return '总纲';
  if (kind === 'volume_outline') return `${volume && volume !== 'current-volume' ? volume : '当前卷'}卷纲`;
  if (kind === 'stage_detail_outline') return `${stage || '当前阶段'}细纲`;
  if (kind === 'chapter_brief') return `${chapter || '当前章'} Brief`;
  if (kind === 'prose_unit') return `${chapter || input.scope || '当前正文'}`;
  if (kind === 'milestone') return stage || '当前阶段';
  if (kind === 'volume') return volume && volume !== 'current-volume' ? volume : '当前卷';
  return '全书';
}

function inferTargetRef(kind, input, lifecycleState, narrativeScope) {
  const assetTarget = lifecycleState.asset_target && typeof lifecycleState.asset_target === 'object'
    ? lifecycleState.asset_target
    : {};
  return String(input.asset_ref || input.assetRef || input.volume || input.stage || input.chapter || assetTarget.id || narrativeScope || kind);
}

function dynamicReadAssets(kind) {
  const planningAssets = ['master_outline', 'volume_outline', 'stage_detail_outline', 'chapter_brief'];
  if (kind === 'prose_unit') return [...planningAssets, 'prose_unit'];
  if (kind === 'milestone') return [...planningAssets, 'prose_unit', 'milestone'];
  if (kind === 'volume') return [...planningAssets, 'prose_unit', 'milestone', 'volume'];
  return [...planningAssets, 'prose_unit', 'milestone', 'volume', 'book'];
}

function normalizeTarget(target) {
  if (!target || typeof target !== 'object' || !REVIEW_TARGET_KINDS.includes(String(target.kind || ''))) {
    const error = new Error('review target kind is required and must be supported');
    error.code = 'REVIEW_TARGET_INVALID';
    throw error;
  }
  return {
    ...target,
    kind: String(target.kind),
    narrative_scope: String(target.narrative_scope || target.visible_label || target.kind),
  };
}

module.exports = {
  DYNAMIC_REVIEW_TARGETS,
  REVIEW_TARGET_KINDS,
  resolveReviewTarget,
  reviewEvidencePolicy,
  validateAssetDependencyEvidenceReceipt,
};
