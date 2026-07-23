'use strict';

const crypto = require('crypto');
const { planReviewRoles } = require('./review-role-policy');
const { reviewEvidencePolicy } = require('./review-target-policy');

const DEFAULT_DIMENSIONS = ['plot', 'hooks', 'character', 'canon', 'prose'];
const CONSERVATIVE_SOURCE_BUDGET_CHARS = 12000;
const CONSERVATIVE_MAX_PRIMARY_CHAPTERS = 24;

function planReviewBatches({ chapters, parentScope, requiredDimensions, budgetPolicy, availableAgents, reviewTarget }) {
  if (reviewTarget) {
    const evidencePolicy = reviewEvidencePolicy(reviewTarget);
    if (!evidencePolicy.use_dynamic_batches) {
      const error = new Error(`review target ${reviewTarget.kind} must use direct asset evidence`);
      error.code = 'REVIEW_TARGET_NOT_BATCHABLE';
      throw error;
    }
  }
  const scope = parseScope(parentScope);
  const normalizedChapters = normalizeChapters(chapters, scope);
  const dimensions = normalizeDimensions(requiredDimensions);
  const policy = normalizeBudgetPolicy(budgetPolicy);
  const dynamicPrimaryChapterLimit = reviewTarget
    ? reviewTargetPrimaryChapterLimit(policy, budgetPolicy)
    : policy.conservative_max_primary_chapters;
  const batches = [];
  let cursor = 0;

  while (cursor < normalizedChapters.length) {
    const primary = [];
    let sourceChars = 0;
    let weightedChars = 0;
    let boundaryReason = 'scope_end';

    while (cursor < normalizedChapters.length) {
      const candidate = normalizedChapters[cursor];
      const candidateWeight = weightedChapterChars(candidate);
      const previous = primary[primary.length - 1];
      const narrativeBoundary = primary.length > 0 ? boundaryBefore(candidate, previous) : '';
      if (primary.length === 0 && (candidate.chars > policy.source_budget_chars || candidateWeight > policy.source_budget_chars)) {
        oversized(candidate, policy.source_budget_chars, candidateWeight);
      }
      if (narrativeBoundary === 'volume_boundary') {
        boundaryReason = narrativeBoundary;
        break;
      }
      if (narrativeBoundary && weightedChars >= policy.source_budget_chars * 0.5) {
        boundaryReason = narrativeBoundary;
        break;
      }
      if (primary.length > 0 && weightedChars + candidateWeight > policy.source_budget_chars) {
        boundaryReason = narrativeBoundary || 'source_budget';
        break;
      }

      primary.push(candidate);
      sourceChars += candidate.chars;
      weightedChars += candidateWeight;
      cursor += 1;

      if (policy.source_budget_origin === 'conservative_fallback'
        && primary.length >= dynamicPrimaryChapterLimit
        && cursor < normalizedChapters.length) {
        boundaryReason = reviewTarget ? 'runtime_unit_window' : 'conservative_safety_bound';
        break;
      }
    }

    const first = primary[0];
    const last = primary[primary.length - 1];
    batches.push({
      id: `batch-${String(batches.length + 1).padStart(3, '0')}`,
      range: `${first.globalDraftOrder}-${last.globalDraftOrder}`,
      primary_chapter_keys: primary.map((chapter) => chapter.chapterKey),
      source_chars: sourceChars,
      weighted_source_chars: Math.ceil(weightedChars),
      source_budget_chars: policy.source_budget_chars,
      risk_density: riskDensity(primary),
      boundary_reason: boundaryReason,
      boundary_context: { before: [], after: [] },
      expected_dimensions: dimensions.slice(),
      evidence_signals: evidenceSignals(primary),
      dispatch_plan: planReviewRoles({
        requiredDimensions: dimensions,
        evidenceSignals: evidenceSignals(primary),
        availableAgents,
        budgetPolicy: policy,
      }),
    });
  }

  for (let index = 0; index < batches.length; index += 1) {
    batches[index].boundary_context = boundaryContext(batches, normalizedChapters, index, policy.boundary_window_chapters);
  }
  validateBatchCoverage({ batches, chapterKeys: normalizedChapters.map((chapter) => chapter.chapterKey) });
  return {
    schemaVersion: '1.0.0',
    visibility: 'internal_only',
    user_visible_batches: false,
    parent_scope: `${scope.start}-${scope.end}`,
    chapters: normalizedChapters,
    budget_policy: reviewTarget
      ? { ...policy, dynamic_primary_chapter_limit: dynamicPrimaryChapterLimit }
      : policy,
    batches,
  };
}

function validateBatchCoverage({ batches, chapterKeys }) {
  if (!Array.isArray(batches) || !Array.isArray(chapterKeys)) invalid('batches and chapterKeys must be arrays');
  const expected = new Set(chapterKeys.map(String));
  const seen = new Map();
  for (const batch of batches) {
    if (!batch || !Array.isArray(batch.primary_chapter_keys)) invalid('each batch requires primary_chapter_keys');
    for (const key of batch.primary_chapter_keys) seen.set(String(key), (seen.get(String(key)) || 0) + 1);
  }
  const missing = Array.from(expected).filter((key) => !seen.has(key));
  const duplicate = Array.from(seen.entries()).filter(([, count]) => count !== 1).map(([key]) => key);
  const unexpected = Array.from(seen).filter(([key]) => !expected.has(key)).map(([key]) => key);
  if (missing.length || duplicate.length || unexpected.length) {
    invalid(`primary batch coverage is invalid (missing=${missing.join(',')}; duplicate=${duplicate.join(',')}; unexpected=${unexpected.join(',')})`);
  }
  return true;
}

function buildSourceIdentity({ chapters, sourceHashes }) {
  const chapterSources = (Array.isArray(chapters) ? chapters : []).map((chapter) => ({
    chapterKey: String(chapter.chapterKey || ''),
    globalDraftOrder: Number(chapter.globalDraftOrder || 0),
    path: String(chapter.path || ''),
    hash: String(chapter.hash || ''),
    sourceStatus: String(chapter.sourceStatus || ''),
  })).sort(compareSourceIdentity);
  const sources = Object.entries(sourceHashes || {}).sort(([left], [right]) => left.localeCompare(right, 'zh-Hans-CN'));
  const identity = { chapter_sources: chapterSources, source_hashes: Object.fromEntries(sources) };
  return { ...identity, digest: digest(identity) };
}

function normalizeBudgetPolicy(policy = {}) {
  const input = policy && typeof policy === 'object' ? policy : {};
  const runtimeEstimate = (input.runtime_guard || {}).token_estimate || {};
  const hostContext = positiveNumber(input.host_context_chars);
  const runtimeContext = positiveNumber(input.runtime_context_chars)
    || positiveNumber(runtimeEstimate.context_chars_budget)
    || positiveNumber(runtimeEstimate.host_context_chars);
  const maxSourceContextRatio = ratio(input.max_source_context_ratio, 0.18);
  const sourceBudgetOrigin = hostContext ? 'host_actual' : (runtimeContext ? 'runtime_estimate' : 'conservative_fallback');
  const contextChars = hostContext || runtimeContext || 0;
  const sourceBudgetChars = contextChars
    ? Math.max(1, Math.floor(contextChars * maxSourceContextRatio))
    : positiveNumber(input.conservative_source_budget_chars) || CONSERVATIVE_SOURCE_BUDGET_CHARS;
  return {
    source_budget_origin: sourceBudgetOrigin,
    source_budget_chars: sourceBudgetChars,
    max_source_context_ratio: maxSourceContextRatio,
    max_parallel_agents: positiveInteger(input.max_parallel_agents) || 2,
    max_escalated_agents: positiveInteger(input.max_escalated_agents) || 4,
    boundary_window_chapters: nonNegativeInteger(input.boundary_window_chapters, 1),
    conservative_max_primary_chapters: positiveInteger(input.conservative_max_primary_chapters) || CONSERVATIVE_MAX_PRIMARY_CHAPTERS,
  };
}

function reviewTargetPrimaryChapterLimit(policy, inputPolicy) {
  const estimatedWindow = positiveInteger(((((inputPolicy || {}).runtime_guard || {}).token_estimate) || {}).estimated_unit_window);
  if (!estimatedWindow) return policy.conservative_max_primary_chapters;
  return Math.max(1, Math.min(policy.conservative_max_primary_chapters, Math.ceil(estimatedWindow / 2)));
}

function normalizeChapters(chapters, scope) {
  if (!Array.isArray(chapters) || chapters.length === 0) invalid('chapter evidence is required to plan review batches');
  const byKey = new Set();
  const byOrder = new Set();
  const normalized = chapters.map((chapter) => ({
    ...chapter,
    chapterKey: String((chapter || {}).chapterKey || ''),
    globalDraftOrder: Number((chapter || {}).globalDraftOrder || 0),
    chars: Math.max(0, Number((chapter || {}).chars || 0)),
    staticRiskTags: Array.isArray((chapter || {}).staticRiskTags) ? chapter.staticRiskTags.map(String).sort() : [],
    boundaryTags: Array.isArray((chapter || {}).boundaryTags) ? chapter.boundaryTags.map(String).sort() : [],
  })).sort((left, right) => left.globalDraftOrder - right.globalDraftOrder || left.chapterKey.localeCompare(right.chapterKey));
  for (const chapter of normalized) {
    if (!chapter.chapterKey || !Number.isInteger(chapter.globalDraftOrder) || chapter.globalDraftOrder < scope.start || chapter.globalDraftOrder > scope.end) {
      invalid('chapter evidence must provide a unique in-scope chapterKey and globalDraftOrder');
    }
    if (byKey.has(chapter.chapterKey) || byOrder.has(chapter.globalDraftOrder)) invalid('chapter evidence contains duplicate chapter keys or orders');
    byKey.add(chapter.chapterKey);
    byOrder.add(chapter.globalDraftOrder);
  }
  for (let order = scope.start; order <= scope.end; order += 1) {
    if (!byOrder.has(order)) invalid(`chapter evidence is missing globalDraftOrder ${order}`);
  }
  return normalized;
}

function normalizeDimensions(dimensions) {
  const normalized = Array.isArray(dimensions) && dimensions.length ? dimensions.map(String) : DEFAULT_DIMENSIONS.slice();
  if (normalized.some((dimension) => !dimension)) invalid('requiredDimensions must contain non-empty values');
  return Array.from(new Set(normalized));
}

function weightedChapterChars(chapter) {
  const score = riskScore(chapter.staticRiskTags);
  return chapter.chars * (1 + Math.min(0.5, score * 0.25));
}

function riskScore(tags) {
  return Array.from(new Set(tags || [])).reduce((score, tag) => score + ({ degeneration: 2, 'ai-pattern': 2, canon: 2, continuity: 2, punctuation: 1, prose: 1 }[tag] || 1), 0);
}

function riskDensity(chapters) {
  if (!chapters.length) return 0;
  return Number((chapters.reduce((sum, chapter) => sum + riskScore(chapter.staticRiskTags), 0) / chapters.length).toFixed(2));
}

function evidenceSignals(chapters) {
  return Array.from(new Set(chapters.flatMap((chapter) => chapter.staticRiskTags || []).map(String))).sort();
}

function boundaryBefore(candidate, previous) {
  if (candidate.volume && previous.volume && candidate.volume !== previous.volume) return 'volume_boundary';
  if (candidate.boundaryTags.some((tag) => /^(arc|volume|chapter)-start|arc-boundary|volume-boundary/.test(tag))) return 'arc_boundary';
  if (previous.boundaryTags.some((tag) => /^(arc|volume|chapter)-end|arc-boundary|volume-boundary/.test(tag))) return 'arc_boundary';
  return '';
}

function boundaryContext(batches, chapters, batchIndex, window) {
  const batch = batches[batchIndex];
  const firstKey = batch.primary_chapter_keys[0];
  const lastKey = batch.primary_chapter_keys[batch.primary_chapter_keys.length - 1];
  const firstIndex = chapters.findIndex((chapter) => chapter.chapterKey === firstKey);
  const lastIndex = chapters.findIndex((chapter) => chapter.chapterKey === lastKey);
  return {
    before: chapters.slice(Math.max(0, firstIndex - window), firstIndex).map((chapter) => chapter.chapterKey),
    after: chapters.slice(lastIndex + 1, lastIndex + 1 + window).map((chapter) => chapter.chapterKey),
  };
}

function parseScope(value) {
  const match = String(value || '').match(/^(\d+)\s*[-到至~]\s*(\d+)$/);
  const start = match ? Number(match[1]) : 0;
  const end = match ? Number(match[2]) : 0;
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) invalid('parentScope must be an ascending numeric range');
  return { start, end };
}

function digest(value) {
  return crypto.createHash('sha256').update(stableJson(value)).digest('hex');
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

function compareSourceIdentity(left, right) {
  return left.globalDraftOrder - right.globalDraftOrder || left.chapterKey.localeCompare(right.chapterKey);
}

function positiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : 0;
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

function nonNegativeInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : fallback;
}

function ratio(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 && number <= 1 ? number : fallback;
}

function invalid(message) {
  const error = new Error(message);
  error.code = 'REVIEW_BATCH_PLAN_INVALID';
  throw error;
}

function oversized(chapter, sourceBudgetChars, weightedChars) {
  const error = new Error(`chapter ${chapter.chapterKey} exceeds the source budget and requires an explicit single-chapter escalation`);
  error.code = 'REVIEW_BATCH_PLAN_OVERSIZED';
  error.chapter_key = chapter.chapterKey;
  error.source_chars = chapter.chars;
  error.weighted_source_chars = Math.ceil(weightedChars);
  error.source_budget_chars = sourceBudgetChars;
  throw error;
}

module.exports = { buildSourceIdentity, planReviewBatches, validateBatchCoverage };
