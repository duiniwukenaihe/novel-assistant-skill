'use strict';

const SUPPORTED_TARGET_STAGES = Object.freeze([
  'section_brief', 'section_draft', 'section_repair', 'assembly',
]);

// These fields are V2 engine projections, not creative or author-owned facts.
// Keeping them beside a migrated V3 current_stage creates two contradictory
// workflow views (for example current_stage=section_brief while
// runtime_guard.resume_from=next_section_brief). The exact V2 bytes remain in
// the recovery archive; the live V3 task must have only one runtime authority.
const LEGACY_RUNTIME_PROJECTION_FIELDS = Object.freeze([
  'machine',
  'unit_lifecycle',
  'runtime_guard',
  'recommended_next',
  'last_selection',
  'navigation',
  'next_stop_reason',
  'stage_attempt_history',
  'pending_action',
  'pending_feedback',
  'short_section_projection',
]);

const EXACT_CHECKPOINTS = Object.freeze([
  Object.freeze({
    checkpoint: 'planning_confirmed',
    source_stages: Object.freeze(['first_section_brief', 'section_brief', 'next_section_brief']),
    target_stage: 'section_brief',
  }),
  Object.freeze({
    checkpoint: 'current_section_brief_ready',
    source_stages: Object.freeze(['draft_first_section', 'draft_section', 'draft_next_section']),
    target_stage: 'section_draft',
  }),
  Object.freeze({
    checkpoint: 'current_section_gate_failed',
    source_stages: Object.freeze(['section_repair_loop']),
    target_stage: 'section_repair',
  }),
  Object.freeze({
    checkpoint: 'final_section_accepted',
    source_stages: Object.freeze(['full_story_assembly']),
    target_stage: 'assembly',
  }),
]);

// These stages were published in the V2 short workflow but do not carry
// enough durable evidence to select a V3 continuation automatically. They
// must remain explicit in the matrix: an unknown or mid-gate stage is not a
// licence to route the author into an arbitrary repair or acceptance stage.
const UNSUPPORTED_V2_SOURCE_STAGES = Object.freeze([
  'startup_scan', 'startup_menu', 'freshness_window', 'info_source_pool',
  'short_review', 'info_source_selection', 'material_learning', 'project_seed',
  'short_setting', 'platform_genre_lock', 'rhythm_pattern_selection',
  'section_outline', 'section_plan_lock', 'short_structure_impact_audit',
  'hook_retention_gate', 'hook_value_gate', 'section_machine_gate',
  'quality_gate', 'story_value_gate', 'section_candidate_compare',
  'section_accept_anchor', 'feedback_apply_patch', 'feedback_impact_sync',
  'full_story_review', 'short_deslop', 'deslop', 'final_check',
]);

function mapV2Checkpoint(task) {
  if (!task || typeof task !== 'object') return ambiguous('', 'task_not_object');
  const stage = String(task.current_stage || task.current_step || '');
  if (task.pending_feedback && typeof task.pending_feedback === 'object') {
    return ambiguous(stage, 'unresolved_author_feedback');
  }
  const pendingActionPolicy = task.pending_action && typeof task.pending_action === 'object'
    ? 'archive_and_resume_stage' : '';
  const executionStage = String(((task.stage_execution || {}).stage_id) || '');
  if (executionStage && stage && executionStage !== stage) {
    return ambiguous(stage, 'durable_stage_execution_mismatch');
  }
  for (const checkpoint of EXACT_CHECKPOINTS) {
    if (!checkpoint.source_stages.includes(stage)) continue;
    return {
      exact: true,
      checkpoint: checkpoint.checkpoint,
      source_stage: stage,
      target_stage: checkpoint.target_stage,
      reason: 'durable_v2_stage_exact_match',
      ...(pendingActionPolicy ? { pending_action_policy: pendingActionPolicy } : {}),
    };
  }
  if (UNSUPPORTED_V2_SOURCE_STAGES.includes(stage)) {
    return ambiguous(stage, 'unsupported_requires_author_choice');
  }
  return ambiguous(stage, 'v2_checkpoint_not_exact');
}

function ambiguous(stage, reason) {
  return { exact: false, checkpoint: '', source_stage: stage, target_stage: '', reason };
}

function stripLegacyRuntimeProjections(task) {
  const migrated = { ...(task || {}) };
  for (const field of LEGACY_RUNTIME_PROJECTION_FIELDS) delete migrated[field];
  return migrated;
}

module.exports = {
  EXACT_CHECKPOINTS,
  LEGACY_RUNTIME_PROJECTION_FIELDS,
  SUPPORTED_TARGET_STAGES,
  UNSUPPORTED_V2_SOURCE_STAGES,
  mapV2Checkpoint,
  stripLegacyRuntimeProjections,
};
