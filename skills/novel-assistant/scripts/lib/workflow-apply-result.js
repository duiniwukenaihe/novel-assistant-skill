'use strict';

function parseJson(value) {
  try {
    return JSON.parse(String(value || '').trim());
  } catch (_) {
    return null;
  }
}

function classifyWorkflowApply(run) {
  const result = parseJson(run && run.stdout) || {};
  const workflowStatus = String(result.status || '');
  const applied = Boolean(run && run.status === 0 && ['advanced', 'stage_started'].includes(workflowStatus));
  const structured = Boolean(workflowStatus);
  const task = result.task && typeof result.task === 'object' ? result.task : {};
  const visibleResponse = result.visible_response && typeof result.visible_response === 'object'
    ? result.visible_response
    : null;
  const stageExecution = result.stage_execution && typeof result.stage_execution === 'object'
    ? result.stage_execution
    : task.stage_execution && typeof task.stage_execution === 'object'
      ? task.stage_execution
      : null;
  const pendingAction = result.pending_action && typeof result.pending_action === 'object'
    ? result.pending_action
    : task.pending_action && typeof task.pending_action === 'object'
      ? task.pending_action
      : null;
  return {
    applied,
    exitCode: applied || structured ? 0 : 2,
    result,
    workflowStatus: workflowStatus || 'workflow_apply_process_failed',
    presentation: {
      stage_execution: stageExecution,
      pending_action: pendingAction,
      next_candidates: Array.isArray(result.next_candidates) ? result.next_candidates : [],
      visible_response: visibleResponse,
      interaction_contract: String(result.interaction_contract || (visibleResponse ? 'render_visible_response_text_verbatim' : '')),
    },
  };
}

function stageRecoveryPresentation(task, options = {}) {
  const execution = task && task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : {};
  const instruction = String(options.instruction || execution.resume_hint || '修复当前阶段后重试一次。');
  const stageExecution = {
    status: 'running',
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    stage_id: String(execution.stage_id || ''),
    step_id: String(execution.step_id || execution.stage_id || ''),
    owner_module: String(execution.owner_module || ''),
    expected_result_packet: String(execution.expected_result_packet || ''),
    write_set: Array.isArray(execution.write_set) ? execution.write_set : [],
    execution_workdir: '.',
    context_read_command: String(execution.context_read_command || ''),
    execution_command: String(execution.execution_command || ''),
    resume_hint: instruction,
    completion_required_before_reply: true,
    stage_completion_contract: 'read_context_edit_write_set_execute_completion_command_consume_result_same_turn',
    execution_sequence: ['read_context', 'edit_write_set', 'execute_completion_command', 'consume_result_presentation'],
  };
  const terminalReplyAllowedOn = ['workflow_choice_required', 'workflow_completed', 'host_tool_call_failed_after_retry', 'retry_budget_exhausted'];
  return {
    stage_execution: stageExecution,
    pending_action: null,
    next_candidates: [],
    visible_response: {
      render_mode: 'silent_resume',
      status: String(options.status || 'stage_recovery_required'),
      selection_contract: 'resume_running_stage',
      interaction_mode: 'resume_stage',
      execution_workdir: '.',
      execution_command: String(execution.execution_command || ''),
      context_read_command: String(execution.context_read_command || ''),
      resume_hint: instruction,
      requires_user_confirm: false,
      completion_required_before_reply: true,
      terminal_reply_allowed_on: terminalReplyAllowedOn,
    },
    interaction_contract: 'continue_confirmed_internal_stage',
    completion_required_before_reply: true,
    terminal_reply_allowed_on: terminalReplyAllowedOn,
  };
}

function recoverableStageResult(task, status, instruction, extra = {}) {
  return {
    status: String(status || 'stage_recovery_required'),
    ...extra,
    instruction: String(instruction || '修复当前阶段后重试一次。'),
    ...stageRecoveryPresentation(task, { status, instruction }),
  };
}

module.exports = {
  classifyWorkflowApply,
  parseJson,
  recoverableStageResult,
  stageRecoveryPresentation,
};
