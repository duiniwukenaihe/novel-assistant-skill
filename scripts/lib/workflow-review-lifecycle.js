'use strict';

const { normalizeReviewBatchState, reviewBatchResultPacket, validateReviewBatchPlanMapping } = require('./review-batch-state');
const { readReviewPlan } = require('./review-plan-contract');
const { buildEvidenceMap, writeEvidenceMap } = require('./review-evidence');
const { buildSourceIdentity, planReviewBatches } = require('./review-batch-planner');
const { resolveReviewTarget } = require('./review-target-policy');
const { scanWorkflowMigrations } = require('./workflow-legacy-migration');
const { BASE_TEMPLATES } = require('./workflow-template-registry');

const SCHEMA_VERSION = '1.0.0';
const SCRIPT_DIR = require('path').resolve(__dirname, '..');

function buildInitialReviewPlan(root, task, options = {}) {
  const scope = parseNumericScope(task.scope);
  if (!scope) throw new Error('review plan requires an immutable numeric chapter scope');
  const evidence = reviewPlanningEvidence(root, scope);
  const planned = planReviewBatches({
    chapters: evidence.chapters,
    parentScope: task.scope,
    requiredDimensions: ['plot', 'hooks', 'character', 'canon', 'prose'],
    budgetPolicy: reviewPlannerBudgetPolicy(task.runtime_guard),
    reviewTarget: task.review_target,
  });
  if (options.writeEvidence !== false && evidence.evidenceMap.status === 'ok') writeEvidenceMap(root, evidence.evidenceMap);
  return {
    schemaVersion: '2.0.0',
    workflow_id: task.workflow_id,
    parent_scope: planned.parent_scope,
    visibility: 'internal_only',
    user_visible_batches: false,
    review_target: task.review_target,
    evidence_policy: task.review_evidence_policy,
    required_dimensions: ['plot', 'hooks', 'character', 'canon', 'prose'],
    source_identity: evidence.sourceIdentity,
    budget_policy: {
      ...planned.budget_policy,
      runtime_guard_token_estimate: ((task.runtime_guard || {}).token_estimate || {}),
    },
    batches: planned.batches,
    coverage_policy: {
      require_all_chapters: true,
      allow_unexplained_deferred: false,
    },
  };
}

function validateTaskReviewPlan(root, task) {
  if (task.workflow_type !== 'review_repair') return { blocked: null, legacy: false, planEntriesById: new Map() };
  const migrationItem = scanWorkflowMigrations(root).inventory.items.find(item => item.workflow_id === task.workflow_id
    && item.migration_adapter === 'legacy_fixed_review_batches');
  if (migrationItem) {
    return {
      blocked: blocked('blocked_legacy_review_migration_required', '旧固定批次审阅必须先通过 workflow-legacy-migrate.js 预演并迁移；禁止继续派发旧批次。'),
      legacy: false,
      planEntriesById: new Map(),
    };
  }
  if (task.review_batches) normalizeReviewBatchState(task.review_batches);
  if (!task.review_plan_path && !task.review_plan_digest) {
    return { blocked: null, legacy: false, plan_read_mode: 'unreferenced_legacy', planEntriesById: new Map() };
  }
  try {
    const loaded = readReviewPlan(root, task);
    if (loaded.plan.workflow_id !== task.workflow_id
      || loaded.plan.parent_scope !== ((task.review_batches || {}).parent_scope || task.scope)) {
      return { blocked: blocked('blocked_review_plan_stale', 'review plan does not match the active review task.') };
    }
    if (loaded.plan_read_mode !== 'legacy_read_only') {
      const currentIdentity = reviewPlanningEvidence(root, parseNumericScope(task.scope), { skipChapterChecks: true, skipPriorReports: true }).sourceIdentity;
      if (currentIdentity.digest !== ((loaded.plan.source_identity || {}).digest || '')) {
        return { blocked: blocked('blocked_review_plan_stale', 'review plan source evidence differs from the persisted plan.') };
      }
    }
    return { blocked: null, legacy: loaded.plan_read_mode === 'legacy_read_only', plan_read_mode: loaded.plan_read_mode, ...validateReviewBatchPlanMapping(task.review_batches, loaded.plan) };
  } catch (error) {
    if (error && error.code === 'REVIEW_PLAN_STALE') return { blocked: blocked('blocked_review_plan_stale', error.message) };
    return { blocked: blocked('blocked_review_plan_missing', (error && error.message) || 'review plan reference is missing.') };
  }
}

function reviewPlanningEvidence(root, scope, options = {}) {
  const evidenceMap = buildEvidenceMap(root, scope, {
    scriptDir: SCRIPT_DIR,
    skipChapterChecks: Boolean(options.skipChapterChecks),
    skipPriorReports: Boolean(options.skipPriorReports),
  });
  if (evidenceMap.status === 'ok') {
    return { chapters: evidenceMap.chapters, evidenceMap, sourceIdentity: buildSourceIdentity(evidenceMap) };
  }
  if (evidenceMap.status === 'partial' && evidenceMap.chapters.length === 0 && evidenceMap.summary.blockingSignals === 0) {
    const chapters = Array.from({ length: scope.end - scope.start + 1 }, (_, index) => ({
      chapterKey: `scope-c${String(scope.start + index).padStart(6, '0')}`,
      globalDraftOrder: scope.start + index,
      volume: '',
      chars: 3000,
      staticRiskTags: [],
      boundaryTags: ['scope-fallback'],
      sourceStatus: 'scope_fallback',
    }));
    return {
      chapters,
      evidenceMap,
      sourceIdentity: buildSourceIdentity({
        chapters,
        sourceHashes: { [`scope:${scope.start}-${scope.end}`]: 'scope-fallback-v1' },
      }),
    };
  }
  const error = new Error(`review plan requires complete trusted chapter evidence: ${evidenceMap.status}`);
  error.code = 'REVIEW_PLAN_EVIDENCE_INCOMPLETE';
  error.evidence_status = evidenceMap.status;
  throw error;
}

function reviewPlannerBudgetPolicy(runtimeGuard) {
  const tokenEstimate = (runtimeGuard || {}).token_estimate || {};
  return {
    runtime_guard: runtimeGuard,
    host_context_chars: tokenEstimate.host_context_chars,
    runtime_context_chars: tokenEstimate.context_chars_budget,
    conservative_source_budget_chars: 160000,
    conservative_max_primary_chapters: 50,
  };
}

function parseNumericScope(scope) {
  const match = String(scope || '').match(/(\d+)\s*[-到至~]\s*(\d+)/);
  if (!match) return null;
  const start = Number(match[1]);
  const end = Number(match[2]);
  return Number.isInteger(start) && Number.isInteger(end) && start > 0 && end >= start ? { start, end } : null;
}

function reviewBatchContinuation(root, task, batch) {
  const batches = (((task || {}).review_batches || {}).batches || []);
  const index = batches.findIndex(item => String(item.id) === String(batch.id));
  const remainingBatchRanges = (index >= 0 ? batches.slice(index) : [batch]).map(item => String(item.range || '')).filter(Boolean);
  return {
    must_continue: true,
    continuation_policy: 'finish_authorized_workflow',
    next_action: 'scan_current_review_batch',
    next_command: `node scripts/review-batch-evidence-scan.js --project-root ${shellQuote(root)} --workflow-id ${shellQuote(String(task.workflow_id || ''))} --range ${shellQuote(String(batch.range || ''))} --write --apply-result --json`,
    expected_result_packet: expectedReviewBatchResultPacket(task, batch.id),
    remaining_batch_ranges: remainingBatchRanges,
    stop_only_on: ['workflow_completed', 'requires_user_decision', 'blocked_quality_or_runtime'],
  };
}

function shellQuote(value) {
  return `'${String(value || '').replace(/'/g, `'"'"'`)}'`;
}

function terminalReviewBatch(batch) {
  return ['completed', 'completed_verified', 'done'].includes(String((batch || {}).status || '').toLowerCase());
}

function protocolV2ReviewBatchResultPacket(taskDirPath, batchId) {
  return `${taskDirPath}/result-packets/evidence_scan.batch-${batchId}.protocol-v2.result.json`;
}

function expectedReviewBatchResultPacket(task, batchId) {
  return String(((((task || {}).review_batch_reacceptance || {}).expected_packets || {})[String(batchId)])
    || reviewBatchResultPacket(task.task_dir, batchId));
}

function reviewCompletionPercent(task, activeTemplates = BASE_TEMPLATES) {
  if (!(task.review_evidence_policy || {}).use_dynamic_batches) {
    const tpl = activeTemplates[task.workflow_type];
    const completed = Array.isArray((task.machine || {}).completed_stages) ? task.machine.completed_stages.length : 0;
    const total = Math.max(1, Array.isArray((tpl || {}).stages) ? tpl.stages.length : 1);
    return Math.min(100, Math.floor((completed / total) * 100));
  }
  const completed = Number(((task.review_batches || {}).completed_count) || 0);
  const total = Math.max(1, Number(((task.review_batches || {}).total_count) || 1));
  return Math.min(100, Math.floor((completed / total) * 100));
}

function buildReviewAdvanceSummary(task, activeTemplates = BASE_TEMPLATES) {
  const target = task.review_target || resolveReviewTarget({ text: task.user_goal, scope: task.scope }, {});
  const nextAction = ((((task.pending_action || {}).options || [])[0] || {}).label || '');
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'advanced',
    visible_label: String(target.visible_label || '审阅当前作品'),
    narrative_scope: String(target.narrative_scope || ''),
    progress: `${reviewCompletionPercent(task, activeTemplates)}%`,
    next_user_action: String(nextAction),
  };
}

function blocked(status, messageOrFindings) {
  const findings = Array.isArray(messageOrFindings)
    ? messageOrFindings
    : [{ field: status, message: String(messageOrFindings || status) }];
  return { schemaVersion: SCHEMA_VERSION, status, findings };
}

module.exports = {
  buildInitialReviewPlan,
  buildReviewAdvanceSummary,
  expectedReviewBatchResultPacket,
  parseNumericScope,
  protocolV2ReviewBatchResultPacket,
  reviewBatchContinuation,
  reviewCompletionPercent,
  shellQuote,
  terminalReviewBatch,
  validateTaskReviewPlan,
};
