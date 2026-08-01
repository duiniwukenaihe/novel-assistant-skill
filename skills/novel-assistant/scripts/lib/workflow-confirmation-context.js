'use strict';

function validateWorkflowConfirmation(task = {}, execution = {}, now = Date.now()) {
  const confirmation = execution.confirmation_context || {};
  const selection = task.last_selection || {};
  const pending = task.pending_action || {};
  const expiresAt = Date.parse(String(confirmation.expires_at || ''));
  const resumedConfirmedStage = execution.action_id === 'resume_paused_stage'
    && selection.action_id === 'resume_paused_stage';
  const valid = Boolean(confirmation.confirmation_token)
    && confirmation.status === 'confirmed'
    && confirmation.confirmation_token === execution.confirmation_token
    && confirmation.confirmation_token === selection.confirmation_token
    && confirmation.workflow_id === task.workflow_id
    && confirmation.workflow_type === task.workflow_type
    && confirmation.stage_id === execution.stage_id
    && confirmation.step_id === execution.step_id
    && confirmation.selection_id === pending.id
    && confirmation.selected_number === execution.selected_number
    && confirmation.selected_number === selection.selected_number
    && confirmation.selected_action_id === execution.action_id
    && confirmation.selected_action_id === selection.action_id
    && confirmation.visible_choice_hash === pending.visible_choice_hash
    && confirmation.visible_choice_hash === selection.visible_choice_hash
    && pending.status === 'resolved'
    && (selection.requires_user_confirm === true || resumedConfirmedStage)
    && Number.isFinite(expiresAt)
    && expiresAt > now;
  return { valid, confirmation, selection, pending, expires_at_ms: expiresAt };
}

module.exports = { validateWorkflowConfirmation };
