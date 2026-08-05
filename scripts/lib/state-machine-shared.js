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

function compactInspectResult(result) {
  if (!result || String(result.status || '') !== 'ok' || !result.task) return result;
  const task = result.task;
  const machine = task.machine && typeof task.machine === 'object' ? task.machine : {};
  const lifecycle = task.lifecycle && typeof task.lifecycle === 'object' ? task.lifecycle : {};
  const overview = result.task_overview && typeof result.task_overview === 'object'
    ? result.task_overview
    : null;
  return {
    schemaVersion: result.schemaVersion || SCHEMA_VERSION,
    status: String(result.status || ''),
    focus_pointer_status: String(result.focus_pointer_status || ''),
    focus_pointer_findings: compactFindingList(result.focus_pointer_findings),
    task: {
      workflow_id: String(task.workflow_id || ''),
      workflow_type: String(task.workflow_type || ''),
      status: String(task.status || ''),
      state_version: Number(task.state_version || 0),
      current_stage: String(task.current_stage || ''),
      current_step: String(task.current_step || ''),
      scope: String(task.scope || '').slice(0, 320),
      task_dir: String(task.task_dir || ''),
      book_root: String(task.book_root || '.'),
      pending_action: compactPendingActionForConsole(task.pending_action || null),
      machine: {
        template_version: String(machine.template_version || ''),
        completed_stage_count: Array.isArray(machine.completed_stages) ? machine.completed_stages.length : 0,
        remaining_stage_count: Array.isArray(machine.remaining_stages) ? machine.remaining_stages.length : 0,
        next_stage: String((Array.isArray(machine.remaining_stages) && machine.remaining_stages[0]) || ''),
        current_stage_completed: Array.isArray(machine.completed_stages)
          && machine.completed_stages.includes(String(task.current_stage || '')),
        allowed_actions: Array.isArray(machine.allowed_actions) ? machine.allowed_actions.slice(0, 8).map(String) : [],
        last_transition: String(machine.last_transition || ''),
        last_execution_event: String(machine.last_execution_event || ''),
        last_result_packet: String(machine.last_result_packet || ''),
        next_stop_reason: String(machine.next_stop_reason || ''),
      },
      lifecycle: {
        status: String(lifecycle.status || ''),
        started_at: String(lifecycle.started_at || ''),
        updated_at: String(lifecycle.updated_at || ''),
        completed_at: String(lifecycle.completed_at || ''),
        scope: String(lifecycle.scope || '').slice(0, 320),
        previous_workflow_id: String(lifecycle.previous_workflow_id || ''),
        switch_reason: String(lifecycle.switch_reason || '').slice(0, 240),
      },
      stage_execution: compactInspectStageExecution(task.stage_execution || null),
      runtime_guard: compactInspectRuntimeGuard(task.runtime_guard || null),
      recovery_state: compactInspectRecoveryState(task),
    },
    task_overview: overview ? {
      status: String(overview.status || ''),
      workflow_id: String(overview.workflow_id || ''),
      workflow_type: String(overview.workflow_type || ''),
      task_title: String(overview.task_title || '').slice(0, 240),
      task_form: String(overview.task_form || ''),
      phase_count: Array.isArray(overview.phases) ? overview.phases.length : 0,
      execution_point: cloneConsoleValue(overview.execution_point || null),
      current_subtask: compactSubtaskForConsole(overview.current_subtask || null),
    } : null,
    visible_response: compactVisibleResponseForConsole(result.visible_response || null),
  };
}

function compactInspectStageExecution(execution) {
  if (!execution || typeof execution !== 'object') return null;
  const projected = compactExecutionForConsole(execution);
  for (const field of [
    'work_unit_id', 'work_unit_scope', 'owner_module', 'host_execution_mode',
    'result_contract', 'completion_boundary', 'risk_level',
  ]) projected[field] = String(execution[field] || '').slice(0, 320);
  projected.attempt_no = Number(execution.attempt_no || 0);
  projected.requires_user_confirm = Boolean(execution.requires_user_confirm);
  projected.write_set = Array.isArray(execution.write_set) ? execution.write_set.slice(0, 20).map(String) : [];
  projected.canonical_write_set = Array.isArray(execution.canonical_write_set)
    ? execution.canonical_write_set.slice(0, 20).map(String)
    : [];
  for (const field of ['context_packet_blocking', 'character_contract_blocking']) {
    const summary = compactStageBlockerForHost(execution[field]);
    if (summary) projected[field] = summary;
  }
  return projected;
}

function compactInspectRuntimeGuard(runtimeGuard) {
  if (!runtimeGuard || typeof runtimeGuard !== 'object') return null;
  const heartbeat = runtimeGuard.heartbeat && typeof runtimeGuard.heartbeat === 'object'
    ? runtimeGuard.heartbeat
    : {};
  const checkpoint = runtimeGuard.checkpoint_policy && typeof runtimeGuard.checkpoint_policy === 'object'
    ? runtimeGuard.checkpoint_policy
    : {};
  const lease = runtimeGuard.session_lease && typeof runtimeGuard.session_lease === 'object'
    ? runtimeGuard.session_lease
    : null;
  return {
    heartbeat: {
      updated_at: String(heartbeat.updated_at || ''),
      latest_trusted_artifact: String(heartbeat.latest_trusted_artifact || ''),
      workflow_id: String(heartbeat.workflow_id || ''),
      current_batch: String(heartbeat.current_batch || ''),
    },
    checkpoint_policy: {
      resume_from: String(checkpoint.resume_from || ''),
      checkpoint_path: String(checkpoint.checkpoint_path || ''),
      expected_result_packet: String(checkpoint.expected_result_packet || ''),
      project_root: String(checkpoint.project_root || ''),
    },
    session_lease: lease ? {
      holder_id: String(lease.holder_id || ''),
      status: String(lease.status || ''),
      acquired_at: String(lease.acquired_at || ''),
      expires_at: String(lease.expires_at || ''),
    } : null,
  };
}

function compactInspectRecoveryState(task) {
  const projected = {};
  for (const field of [
    'integrity_recovery', 'repair_integrity_recovery', 'longform_target_revalidation',
    'longform_chapter_prose_revalidation', 'longform_chapter_loop_repair',
    'memory_migration', 'migration',
  ]) {
    const source = task[field];
    if (!source || typeof source !== 'object' || Array.isArray(source)) continue;
    const summary = {};
    for (const key of [
      'status', 'reason', 'resume_stage', 'source_stage', 'target_stage', 'previous_stage',
      'recovery_command', 'archive_manifest_path', 'archived_result_packet',
      'source_result_packet', 'restored_at', 'repaired_at', 'applied_at', 'invalidated_at',
    ]) {
      if (Object.prototype.hasOwnProperty.call(source, key)) summary[key] = String(source[key] || '').slice(0, 600);
    }
    for (const key of ['requires_activation', 'requires_confirmation', 'confirmation_required']) {
      if (Object.prototype.hasOwnProperty.call(source, key)) summary[key] = Boolean(source[key]);
    }
    if (Array.isArray(source.missing_stages)) summary.missing_stages = source.missing_stages.slice(0, 16).map(String);
    if (Object.keys(summary).length > 0) projected[field] = summary;
  }
  return Object.keys(projected).length > 0 ? projected : null;
}

function compactFindingList(findings) {
  if (!Array.isArray(findings)) return [];
  return findings.slice(0, 12).map((finding) => {
    if (!finding || typeof finding !== 'object') return { message: String(finding || '').slice(0, 240) };
    const projected = {};
    for (const field of ['field', 'code', 'status', 'message']) {
      if (Object.prototype.hasOwnProperty.call(finding, field)) projected[field] = String(finding[field] || '').slice(0, 240);
    }
    return projected;
  });
}

function compactNextCandidatesResult(result) {
  if (result && String(result.status || '') === 'stage_execution_resume_ready') {
    return {
      ...result,
      stage_execution: compactRunningStageExecutionForHost(result.stage_execution || null),
    };
  }
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

function compactResolveActionResult(result) {
  if (!result || String(result.status || '') !== 'stage_started') return result;
  const execution = result.stage_execution && typeof result.stage_execution === 'object'
    ? result.stage_execution
    : null;
  const compactExecution = execution ? compactExecutionForConsole(execution) : null;
  if (compactExecution) {
    for (const field of ['work_unit_id', 'owner_module']) {
      compactExecution[field] = String(execution[field] || '').slice(0, 320);
    }
    compactExecution.chapter_target = compactChapterTargetIdentity(execution.chapter_target || null);
    compactExecution.resume_hint = String(compactExecution.resume_hint || '').slice(0, 1600);
    for (const field of ['context_packet_blocking', 'character_contract_blocking']) {
      const summary = compactStageBlockerForHost(execution[field]);
      if (summary) compactExecution[field] = summary;
    }
    if (Object.prototype.hasOwnProperty.call(execution, 'context_packet_warning')) {
      compactExecution.context_packet_warning = String(execution.context_packet_warning || '').slice(0, 240);
    }
  }
  const visible = compactVisibleResponseForConsole(result.visible_response || null) || (compactExecution ? {
    render_mode: 'silent_execute',
    status: 'stage_started',
    selection_contract: 'execute_current_stage_contract',
    text: '',
    options: [],
  } : null);
  if (visible) visible.text = String(visible.text || ((compactExecution || {}).resume_hint) || '').slice(0, 1600);
  const resultTemplate = execution && execution.result_packet_template && typeof execution.result_packet_template === 'object'
    ? execution.result_packet_template
    : {};
  return {
    schemaVersion: result.schemaVersion || SCHEMA_VERSION,
    status: 'stage_started',
    workflow_id: String(result.workflow_id || resultTemplate.workflow_id || ''),
    workflow_type: String(result.workflow_type || resultTemplate.workflow_type || ''),
    selection_status: String(result.selection_status || ''),
    selected_number: Number(result.selected_number || 0) || undefined,
    action_id: String(result.action_id || ''),
    target_stage: String(result.target_stage || ''),
    selection_locked: Boolean(result.selection_locked),
    semantic_continuation_bound: Boolean(result.semantic_continuation_bound),
    stage_execution: compactExecution,
    visible_response: visible,
  };
}

function compactChapterTargetIdentity(target) {
  if (!target || typeof target !== 'object') return null;
  const projected = {};
  for (const field of [
    'target_version', 'target_id', 'chapter_id', 'volume', 'volume_chapter_no',
    'global_chapter_no', 'global_draft_order', 'outline_path', 'outline_sha256',
    'contract_path', 'draft_path', 'candidate_draft_path', 'target_chinese_chars',
    'min_chinese_chars', 'max_chinese_chars',
  ]) {
    if (!Object.prototype.hasOwnProperty.call(target, field)) continue;
    projected[field] = typeof target[field] === 'string'
      ? String(target[field]).slice(0, 600)
      : cloneConsoleValue(target[field]);
  }
  return Object.keys(projected).length > 0 ? projected : null;
}

function compactRunningStageExecutionForHost(execution) {
  if (!execution || typeof execution !== 'object') return null;
  const projected = {};
  const hostFields = [
    'status', 'stage_attempt_id', 'work_unit_id', 'work_unit_scope', 'attempt_no',
    'supersedes_attempt_id', 'repeat_scope', 'stage_id', 'step_id', 'action_id',
    'selected_number', 'started_at', 'expected_result_packet', 'owner_module',
    'stage_description', 'required_inputs', 'lifecycle_node', 'asset_target',
    'review_requirement', 'write_set', 'canonical_write_set', 'planning_targets',
    'planning_revision_targets', 'revision_targets', 'result_contract', 'review_targets',
    'chapter_target', 'chapter_targets', 'risk_level', 'requires_user_confirm',
    'confirmation_token', 'confirmation_context', 'completion_boundary', 'batch_id',
    'batch_scope', 'resume_hint', 'host_execution_mode', 'execution_boundary',
    'execution_workdir', 'memory_contract_version', 'memory_contract',
    'context_read_command', 'execution_command', 'quality_command',
    'stage_completion_command', 'current_required_action', 'after_write_action',
    'completion_required_before_reply', 'stage_completion_contract',
    'execution_sequence', 'result_packet_template',
  ];
  for (const field of hostFields) {
    if (Object.prototype.hasOwnProperty.call(execution, field)) {
      projected[field] = cloneConsoleValue(execution[field]);
    }
  }

  const memory = execution.memory_context && typeof execution.memory_context === 'object'
    ? execution.memory_context
    : null;
  if (memory) {
    projected.memory_context = {
      status: String(memory.status || ''),
      blocking: Boolean(memory.blocking),
      context_source: String(memory.context_source || ''),
      memory_contract: cloneConsoleValue(memory.memory_contract || execution.memory_contract || null),
      memory_read_receipt: cloneConsoleValue(memory.memory_read_receipt || null),
      packet_digest: String(memory.packet_digest || ''),
    };
  }

  if (Object.prototype.hasOwnProperty.call(execution, 'context_packet_warning')) {
    projected.context_packet_warning = String(execution.context_packet_warning || '').slice(0, 240);
  }
  for (const field of ['context_packet_blocking', 'character_contract_blocking']) {
    const summary = compactStageBlockerForHost(execution[field]);
    if (summary) projected[field] = summary;
  }

  const cooperativeChapterBrief = String(execution.host_execution_mode || '') === 'cooperative_interactive'
    && String(execution.stage_id || '') === 'chapter_brief';
  if (cooperativeChapterBrief) {
    const activeTarget = execution.chapter_target && typeof execution.chapter_target === 'object'
      ? cloneConsoleValue(execution.chapter_target)
      : null;
    projected.chapter_targets = activeTarget ? [activeTarget] : [];
    if (projected.result_packet_template && typeof projected.result_packet_template === 'object') {
      projected.result_packet_template.chapter_target = activeTarget;
      projected.result_packet_template.chapter_targets = activeTarget ? [cloneConsoleValue(activeTarget)] : [];
    }
  }
  return projected;
}

function compactStageBlockerForHost(blocker) {
  if (!blocker || typeof blocker !== 'object') return null;
  const summary = {};
  for (const field of ['status', 'blocking', 'reason', 'resume_stage']) {
    if (!Object.prototype.hasOwnProperty.call(blocker, field)) continue;
    summary[field] = typeof blocker[field] === 'string'
      ? String(blocker[field]).slice(0, 240)
      : Boolean(blocker[field]);
  }
  if (Array.isArray(blocker.missing_fields)) {
    summary.missing_fields = blocker.missing_fields.slice(0, 20).map(item => String(item).slice(0, 120));
  }
  if (Array.isArray(blocker.findings)) {
    summary.findings = blocker.findings.slice(0, 12).map((finding) => {
      if (!finding || typeof finding !== 'object') return { message: String(finding || '').slice(0, 240) };
      const compact = {};
      for (const field of ['field', 'code', 'status', 'message']) {
        if (Object.prototype.hasOwnProperty.call(finding, field)) compact[field] = String(finding[field] || '').slice(0, 240);
      }
      return compact;
    });
  }
  return summary;
}

function cloneConsoleValue(value) {
  if (value === undefined) return undefined;
  return value === null ? null : JSON.parse(JSON.stringify(value));
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
  if (/workflow-state-machine\.js["']?\s+["']?(?:next-candidates|task-overview|activate|apply-result|resolve-action)\b/u.test(value)) {
    if (value.includes('"--json"')) return value.replace(/\s"--json"/u, ' "--compact" "--json"');
    if (value.includes("'--json'")) return value.replace(/\s'--json'/u, " '--compact' '--json'");
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
  compactInspectResult,
  compactTaskOverviewResult,
  compactNextCandidatesResult,
  compactResolveActionResult,
  compactRunningStageExecutionForHost,
  compactVisibleResponseForConsole,
  compactExecutionForConsole,
  compactMenuOptionForConsole,
  compactWorkflowCommand,
};
