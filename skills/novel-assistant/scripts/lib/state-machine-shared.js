'use strict';

// 共享层：状态机的无领域依赖纯工具函数（P2.2.a 抽出）
// 这些函数只依赖：fs/常量/彼此。short-write / long-write 拆分时也可共用。
//
// 注意：本文件保持自包含，不引入 workflow-state-machine 内部的领域常量/函数。

const fs = require('fs');
const { atomicWriteJson } = require('./workflow-state-store');

// SCHEMA_VERSION 是结果包 schema 版本。状态机仍在使用，故这里导出 + 状态机 require 复用。
const SCHEMA_VERSION = '1.0.0';

function blocked(status, messageOrFindings) {
  const findings = Array.isArray(messageOrFindings)
    ? messageOrFindings
    : [{ field: status, message: messageOrFindings }];
  return { schemaVersion: SCHEMA_VERSION, status, findings };
}

function blockedTaskTemplate(registryCheck) {
  return blocked(registryCheck.status, [{
    field: 'workflow_registry',
    message: '任务绑定的工作流模板不可用，禁止回落到其他公有或私有模块。',
    workflow_type: registryCheck.workflow_type,
    owner_module: registryCheck.owner_module,
    expected_profile: ((registryCheck.registry || {}).profile) || 'public',
  }]);
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function writeJson(file, data) {
  atomicWriteJson(file, data);
}

function compactActivatedResult(result) {
  if (!result || !['activated', 'stage_started'].includes(String(result.status || '')) || !result.task) return result;
  const task = result.task;
  const execution = task.stage_execution && typeof task.stage_execution === 'object'
    ? task.stage_execution
    : null;
  const context = execution && execution.stage_context_packet && typeof execution.stage_context_packet === 'object'
    ? execution.stage_context_packet
    : null;
  const overview = result.task_overview && typeof result.task_overview === 'object'
    ? result.task_overview
    : null;
  const visible = result.visible_response && typeof result.visible_response === 'object'
    ? result.visible_response
    : null;
  return {
    schemaVersion: result.schemaVersion || SCHEMA_VERSION,
    status: result.status,
    previous_workflow_id: String(result.previous_workflow_id || ''),
    task: {
      workflow_id: String(task.workflow_id || ''),
      workflow_type: String(task.workflow_type || ''),
      status: String(task.status || ''),
      state_version: Number(task.state_version || 0),
      current_stage: String(task.current_stage || ''),
      current_step: String(task.current_step || ''),
      scope: String(task.scope || ''),
      project_identity: task.project_identity || null,
      pending_action: compactPendingActionForConsole(task.pending_action || null),
      stage_execution: execution ? {
        status: String(execution.status || ''),
        stage_id: String(execution.stage_id || ''),
        step_id: String(execution.step_id || ''),
        owner_module: String(execution.owner_module || ''),
        write_set: Array.isArray(execution.write_set) ? execution.write_set : [],
        expected_result_packet: String(execution.expected_result_packet || ''),
        draft_target: String(execution.draft_target || ''),
        repair_target: String(execution.repair_target || ''),
        context_estimated_tokens: context ? Number(context.estimated_tokens || 0) : 0,
        context_token_budget: context ? Number(context.token_budget || 0) : 0,
        context_read_command: String(execution.context_read_command || ''),
        execution_command: String(execution.execution_command || ''),
        resume_hint: String(execution.resume_hint || ''),
      } : null,
    },
    task_overview: overview ? {
      status: String(overview.status || ''),
      task_title: String(overview.task_title || ''),
      task_form: String(overview.task_form || ''),
      phase_count: Array.isArray(overview.phases) ? overview.phases.length : 0,
      current_subtask: compactSubtaskForConsole(overview.current_subtask || null),
    } : null,
    // Keep the compact activation actionable without repeating the full phase
    // payload. Authors still receive the numbered workflow choices.
    visible_response: visible ? {
      render_mode: String(visible.render_mode || 'text_numbers'),
      status: String(visible.status || ''),
      selection_contract: String(visible.selection_contract || ''),
      options: Array.isArray(visible.options) ? visible.options.slice(0, 4).map(compactMenuOptionForConsole) : [],
      text: String(visible.text || ''),
    } : null,
  };
}

function compactPendingActionForConsole(pending) {
  if (!pending || typeof pending !== 'object') return null;
  return {
    id: String(pending.id || pending.pending_action_id || ''),
    question: String(pending.question || ''),
    options: Array.isArray(pending.options) ? pending.options.slice(0, 4).map(compactMenuOptionForConsole) : [],
    free_text_enabled: pending.free_text_enabled !== false,
  };
}

function compactSubtaskForConsole(subtask) {
  if (!subtask || typeof subtask !== 'object') return null;
  return {
    id: String(subtask.id || ''),
    order: Number(subtask.order || 0) || undefined,
    label: String(subtask.label || subtask.internal_label || ''),
    author_phase_label: String(subtask.author_phase_label || ''),
    role: String(subtask.role || ''),
    status: String(subtask.status || ''),
    completion_conditions: Array.isArray(subtask.completion_conditions)
      ? subtask.completion_conditions.slice(0, 4).map(item => String(item || ''))
      : [],
  };
}

function compactApplyResult(result) {
  if (!result || !['advanced', 'stage_started'].includes(String(result.status || ''))) return result;
  const visible = result.visible_response && typeof result.visible_response === 'object'
    ? result.visible_response
    : null;
  const execution = result.stage_execution && typeof result.stage_execution === 'object'
    ? result.stage_execution
    : null;
  const pending = result.pending_action && typeof result.pending_action === 'object'
    ? result.pending_action
    : null;
  return {
    schemaVersion: result.schemaVersion || SCHEMA_VERSION,
    status: String(result.status || ''),
    current_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''),
    remaining_stages: Array.isArray(result.remaining_stages) ? result.remaining_stages : [],
    stage_execution: execution ? compactExecutionForConsole(execution) : null,
    pending_action: pending ? {
      id: String(pending.id || pending.pending_action_id || ''),
      question: String(pending.question || ''),
      options: Array.isArray(pending.options) ? pending.options.slice(0, 4).map(compactMenuOptionForConsole) : [],
    } : null,
    next_candidates: Array.isArray(result.next_candidates) ? result.next_candidates.slice(0, 4).map(compactMenuOptionForConsole) : [],
    visible_response: visible ? {
      render_mode: String(visible.render_mode || 'text_numbers'),
      status: String(visible.status || ''),
      text: String(visible.text || ''),
      options: Array.isArray(visible.options) ? visible.options.slice(0, 4).map(compactMenuOptionForConsole) : [],
      execution_command: String(visible.execution_command || ''),
      context_read_command: String(visible.context_read_command || ''),
      resume_hint: String(visible.resume_hint || ''),
    } : null,
    interaction_contract: String(result.interaction_contract || ''),
  };
}

function compactTaskOverviewResult(result) {
  if (!result || String(result.status || '') !== 'workflow_task_overview') return result;
  const overview = result.task_overview && typeof result.task_overview === 'object'
    ? result.task_overview
    : null;
  const visible = result.visible_response && typeof result.visible_response === 'object'
    ? result.visible_response
    : null;
  return {
    schemaVersion: result.schemaVersion || SCHEMA_VERSION,
    status: String(result.status || ''),
    workflow_id: String(result.workflow_id || ''),
    task_overview: overview ? {
      status: String(overview.status || ''),
      workflow_id: String(overview.workflow_id || ''),
      workflow_type: String(overview.workflow_type || ''),
      task_title: String(overview.task_title || ''),
      task_form: String(overview.task_form || ''),
      phase_count: Array.isArray(overview.phases) ? overview.phases.length : 0,
      execution_point: overview.execution_point || null,
      current_subtask: compactSubtaskForConsole(overview.current_subtask || null),
      text: String(overview.text || ''),
    } : null,
    visible_response: compactVisibleResponseForConsole(visible),
  };
}

function compactNextCandidatesResult(result) {
  if (!result || !['ok', 'requires_user_confirm'].includes(String(result.status || ''))) return result;
  return {
    schemaVersion: result.schemaVersion || SCHEMA_VERSION,
    status: String(result.status || ''),
    target_stage: String(result.target_stage || ''),
    pending_action: compactPendingActionForConsole(result.pending_action || null),
    next_candidates: Array.isArray(result.next_candidates) ? result.next_candidates.slice(0, 4).map(compactMenuOptionForConsole) : [],
    visible_response: compactVisibleResponseForConsole(result.visible_response || null),
  };
}

function compactVisibleResponseForConsole(visible) {
  if (!visible || typeof visible !== 'object') return null;
  return {
    render_mode: String(visible.render_mode || 'text_numbers'),
    status: String(visible.status || ''),
    selection_contract: String(visible.selection_contract || ''),
    text: String(visible.text || ''),
    options: Array.isArray(visible.options) ? visible.options.slice(0, 4).map(compactMenuOptionForConsole) : [],
  };
}

function compactExecutionForConsole(execution) {
  return {
    status: String(execution.status || ''),
    stage_id: String(execution.stage_id || ''),
    step_id: String(execution.step_id || ''),
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    expected_result_packet: String(execution.expected_result_packet || ''),
    execution_command: String(execution.execution_command || ''),
    context_read_command: String(execution.context_read_command || ''),
    resume_hint: String(execution.resume_hint || ''),
  };
}

function compactMenuOptionForConsole(option) {
  return {
    number: Number(option.number || 0) || undefined,
    action_id: String(option.action_id || option.action || ''),
    label: String(option.label || ''),
    target_stage: String(option.target_stage || ''),
    recommended: Boolean(option.recommended),
    interaction_mode: String(option.interaction_mode || ''),
    execution_command: compactWorkflowCommand(String(option.execution_command || '')),
  };
}

function compactWorkflowCommand(command) {
  const value = String(command || '');
  if (!value || value.includes('--compact')) return value;
  if (/workflow-state-machine\.js\s+(?:next-candidates|task-overview|activate|apply-result)\b/u.test(value)) {
    return value.includes('--json')
      ? value.replace(/\s--json\b/u, ' --compact --json')
      : `${value} --compact`;
  }
  return value;
}

module.exports = {
  SCHEMA_VERSION,
  blocked,
  blockedTaskTemplate,
  readJson,
  writeJson,
  compactActivatedResult,
  compactPendingActionForConsole,
  compactSubtaskForConsole,
  compactApplyResult,
  compactTaskOverviewResult,
  compactNextCandidatesResult,
  compactVisibleResponseForConsole,
  compactExecutionForConsole,
  compactMenuOptionForConsole,
  compactWorkflowCommand,
};
