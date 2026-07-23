'use strict';

function parseNumericRange(scope) {
  const match = String(scope || '').match(/(\d+)\s*[-到至~]\s*(\d+)/);
  if (!match) return null;
  const start = Number(match[1]);
  const end = Number(match[2]);
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end < start) return null;
  return { start, end };
}

function buildReviewBatchState(workflowId, scope, taskDir, reviewPlan) {
  const range = parseNumericRange(scope);
  if (!range || !reviewPlan || !Array.isArray(reviewPlan.batches) || reviewPlan.batches.length === 0) return null;
  if (String(reviewPlan.parent_scope || '') !== `${range.start}-${range.end}`) return null;
  const batches = reviewPlan.batches.map((entry, index) => {
    const id = String(entry.id || '').replace(/^batch-/, '') || String(index + 1).padStart(3, '0');
    return {
      status: 'pending',
      id,
      range: String(entry.range || ''),
      plan_entry_id: String(entry.id || `batch-${id}`),
      accepted_result_packet: '',
      unresolved_dimensions: [],
    };
  });
  return {
    schemaVersion: '2.0.0',
    workflow_id: workflowId,
    parent_scope: `${range.start}-${range.end}`,
    task_dir: taskDir,
    aggregate_status: 'pending',
    completed_count: 0,
    total_count: batches.length,
    next_batch_id: batches[0] ? batches[0].id : '',
    batches,
  };
}

function rebuildReviewBatchStateFromPlan(task, reviewPlan) {
  return buildReviewBatchState(
    String((task || {}).workflow_id || ''),
    String((task || {}).scope || ''),
    String((task || {}).task_dir || `追踪/workflow/tasks/${(task || {}).workflow_id || ''}`),
    reviewPlan,
  );
}

function currentReviewBatch(state) {
  if (!state || !Array.isArray(state.batches)) return null;
  normalizeReviewBatchState(state);
  const batch = state.batches.find(item => item.status !== 'completed') || null;
  return hydrateBatch(state, batch);
}

function completeReviewBatch(state, batchId, resultPacket, acceptance) {
  if (!state || !Array.isArray(state.batches)) return { status: 'not_configured' };
  const current = currentReviewBatch(state);
  if (!current) return { status: 'already_completed' };
  if (!batchId) return { status: 'blocked_review_batch_required', expected_batch_id: current.id };
  if (String(batchId) !== String(current.id)) {
    return { status: 'blocked_review_batch_out_of_order', expected_batch_id: current.id, received_batch_id: String(batchId) };
  }
  if (acceptance && acceptance.status === 'partial_evidence') {
    if (current.status === 'awaiting_retry') {
      return { status: 'blocked_review_batch_retry_exhausted', batch_id: current.id, unresolved_dimensions: current.unresolved_dimensions };
    }
    current.status = 'awaiting_retry';
    current.accepted_result_packet = resultPacket || current.accepted_result_packet || '';
    current.unresolved_dimensions = Array.isArray(acceptance.unresolvedDimensions) ? acceptance.unresolvedDimensions.slice() : [];
    state.aggregate_status = 'running';
    state.next_batch_id = current.id;
    return {
      status: 'partial_evidence_retry',
      partial_batch: current,
      retry_roles: Array.isArray(acceptance.retryRoles) ? acceptance.retryRoles.slice() : [],
    };
  }
  if (acceptance && acceptance.status && acceptance.status !== 'accepted') {
    return { status: 'blocked_review_batch_result_invalid', batch_id: current.id };
  }
  current.status = 'completed';
  current.accepted_result_packet = resultPacket || current.accepted_result_packet || '';
  state.completed_count = state.batches.filter(batch => batch.status === 'completed').length;
  const next = currentReviewBatch(state);
  state.next_batch_id = next ? next.id : '';
  state.aggregate_status = next ? 'running' : 'completed';
  return { status: next ? 'batch_advanced' : 'all_batches_completed', completed_batch: current, next_batch: next };
}

function reviewBatchResultPacket(taskDir, batchId) {
  return `${taskDir}/result-packets/evidence_scan.batch-${batchId}.result.json`;
}

function normalizeReviewBatchState(state) {
  if (!state || !Array.isArray(state.batches)) return state;
  state.batches = state.batches.map(normalizeReviewBatch);
  return state;
}

function validateReviewBatchPlanMapping(state, plan) {
  if (!state || !Array.isArray(state.batches)) reviewPlanStale('review batch state is missing');
  normalizeReviewBatchState(state);
  if (!plan || !Array.isArray(plan.batches)) reviewPlanStale('review plan batches are missing');
  if (String(state.parent_scope || '') !== String(plan.parent_scope || '')) {
    reviewPlanStale('review batch parent scope does not match the review plan');
  }

  const planEntriesById = new Map();
  for (const entry of plan.batches) planEntriesById.set(String(entry.id || ''), entry);
  const mappedEntryIds = new Set();
  for (const batch of state.batches) {
    const entryId = String(batch.plan_entry_id || '');
    const entry = planEntriesById.get(entryId);
    if (!entry) reviewPlanStale(`review batch ${batch.id} references an unknown plan entry`);
    if (mappedEntryIds.has(entryId)) reviewPlanStale(`review plan entry ${entryId} is mapped by more than one batch`);
    if (String(batch.range || '') !== String(entry.range || '')) {
      reviewPlanStale(`review batch ${batch.id} range does not match plan entry ${entryId}`);
    }
    mappedEntryIds.add(entryId);
  }
  if (mappedEntryIds.size !== planEntriesById.size) {
    reviewPlanStale('review batch state does not cover every review plan entry');
  }
  return { planEntriesById };
}

function normalizeReviewBatch(batch) {
  const id = String((batch || {}).id || '');
  return {
    id,
    range: String((batch || {}).range || ''),
    status: String((batch || {}).status || 'pending'),
    plan_entry_id: String((batch || {}).plan_entry_id || `batch-${id}`),
    accepted_result_packet: String((batch || {}).accepted_result_packet || (batch || {}).result_packet || ''),
    unresolved_dimensions: Array.isArray((batch || {}).unresolved_dimensions)
      ? (batch || {}).unresolved_dimensions.slice()
      : [],
  };
}

function reviewPlanStale(message) {
  const error = new Error(message);
  error.code = 'REVIEW_PLAN_STALE';
  throw error;
}

function hydrateBatch(state, batch) {
  if (!batch) return batch;
  Object.defineProperty(batch, 'result_packet', {
    configurable: true,
    enumerable: false,
    value: reviewBatchResultPacket(state.task_dir || '', batch.id),
  });
  return batch;
}

module.exports = {
  buildReviewBatchState,
  completeReviewBatch,
  currentReviewBatch,
  normalizeReviewBatchState,
  parseNumericRange,
  rebuildReviewBatchStateFromPlan,
  reviewBatchResultPacket,
  validateReviewBatchPlanMapping,
};
