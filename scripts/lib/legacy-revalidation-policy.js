'use strict';

const LEGACY_REVALIDATION_STAGES = new Set(['positioning', 'story_bible', 'master_outline']);

function effectiveLegacyRevalidationPolicy(task, stageId, writeSet, canonicalWriteSet) {
  const lifecycleGraph = ((task || {}).lifecycle_graph) || {};
  const transitionValidation = lifecycleGraph.last_transition_validation || {};
  const confirmedReviewRevision = String(lifecycleGraph.current_node || '') === String(stageId || '')
    && transitionValidation.allowed === true
    && String(transitionValidation.rule || '') === 'required_review_failure_return';
  const applies = String((task || {}).workflow_type || '') === 'long_write'
    && String((((task || {}).lifecycle || {}).switch_reason) || '') === 'legacy_task_authority_recovery'
    && LEGACY_REVALIDATION_STAGES.has(String(stageId || ''))
    && !confirmedReviewRevision;
  const existingAssetPolicy = applies ? {
    mode: 'existing_asset_revalidation',
    canonical_assets: 'read_only',
    result_artifacts: 'result_packet_only',
    pass_condition: '既有资产足以支撑当前 scope；无关的全局缺失不阻断。',
    block_condition: '仅影响当前 scope 的矛盾或关键缺失可以阻断，并须列出确切缺口。',
  } : null;
  return {
    existing_asset_policy: existingAssetPolicy,
    write_set: applies ? [] : (Array.isArray(writeSet) ? writeSet.slice() : []),
    canonical_write_set: applies ? [] : (Array.isArray(canonicalWriteSet) ? canonicalWriteSet.slice() : []),
  };
}

module.exports = { effectiveLegacyRevalidationPolicy };
