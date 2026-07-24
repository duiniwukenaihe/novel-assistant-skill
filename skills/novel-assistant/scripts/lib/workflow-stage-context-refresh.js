'use strict';

const { buildStageContextPacket } = require('./workflow-stage-context-packet');
const { mutateTaskAuthority, resolveTaskAuthority } = require('./workflow-task-authority');

function refreshCurrentStageContext(projectRoot, workflowId) {
  const authority = resolveTaskAuthority(projectRoot, workflowId);
  if (authority.status !== 'ok') return { status: authority.status, message: authority.message || '' };
  const task = authority.task;
  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const stageId = String(execution.stage_id || task.current_stage || '');
  if (String(execution.status || '') !== 'running' || !stageId) {
    return { status: 'blocked_stage_execution_not_running', stage_id: stageId };
  }
  const packet = buildStageContextPacket({ projectRoot, task, stage: stageId });
  if (packet.status !== 'assembled') return { status: packet.status, stage_id: stageId, packet };
  try {
    const next = mutateTaskAuthority(projectRoot, workflowId, Number(task.state_version || 0), (draft) => {
      const current = draft.stage_execution && typeof draft.stage_execution === 'object' ? draft.stage_execution : {};
      if (String(current.stage_attempt_id || '') !== String(execution.stage_attempt_id || '')
          || String(current.stage_id || draft.current_stage || '') !== stageId) {
        const error = new Error('stage changed before context refresh');
        error.code = 'WORKFLOW_TASK_CONFLICT';
        throw error;
      }
      current.context_read_command = `node scripts/workflow-stage-context.js read-current --project-root . --workflow-id ${JSON.stringify(workflowId)}`;
      current.stage_context_packet = {
        status: packet.status,
        packet_md: packet.packet_md,
        packet_json: packet.packet_json,
        section_index: packet.section_index,
        estimated_tokens: packet.estimated_tokens,
        token_budget: packet.token_budget,
        source_files: packet.source_files,
        memory_contract: packet.memory_contract || null,
        memory_read_receipt: packet.memory_read_receipt || null,
      };
      current.memory_context = {
        status: 'assembled',
        blocking: false,
        context_source: 'stage_context',
        packet_md: String(packet.packet_md || ''),
        packet_json: String(packet.packet_json || ''),
        estimated_tokens: Number(packet.estimated_tokens || 0),
        memory_contract: packet.memory_contract || null,
        memory_read_receipt: packet.memory_read_receipt || null,
      };
      current.context_refresh_count = Number(current.context_refresh_count || 0) + 1;
      current.context_refreshed_at = new Date().toISOString();
      current.resume_hint = `${String(current.resume_hint || '').trim()} 逐字运行 execution_command；不得追加 2>&1、head、管道、重定向或自行拼接菜单哈希。`.trim();
      draft.stage_execution = current;
      draft.status = 'running';
      draft.pending_action = null;
      return draft;
    }, { owner: 'workflow-stage-context-refresh' });
    return {
      status: 'stage_context_refreshed',
      workflow_id: workflowId,
      stage_id: stageId,
      section_index: packet.section_index,
      context_refresh_count: Number((next.stage_execution || {}).context_refresh_count || 0),
      state_version: Number(next.state_version || 0),
      execution_command: String((next.stage_execution || {}).execution_command || ''),
    };
  } catch (error) {
    return { status: String(error.code || 'stage_context_refresh_failed').toLowerCase(), stage_id: stageId, message: error.message };
  }
}

module.exports = { refreshCurrentStageContext };
