'use strict';

const { renderCommittedInteraction } = require('./interaction-arbiter');

const VISIBLE_STAGE_LABELS = Object.freeze({
  creative_entry: '确认创作方向',
  material_positioning: '整理素材卡',
  setting: '完善设定与人物',
  section_outline: '确认全篇小节方案',
  planning_confirmation: '确认写作方案',
  feedback_apply_patch: '回写已确认方案',
  section_brief: '生成当前小节 Brief',
  section_draft: '写当前小节',
  machine_gate: '检查当前小节',
  section_repair: '修订当前小节',
  story_gate: '复核当前小节',
  section_accept: '采用当前小节',
  assembly: '合稿',
  editorial_review: '全篇审阅',
  deslop: '精修表达',
  final_check: '终检',
});

function visibleStageLabel(stage) {
  return VISIBLE_STAGE_LABELS[String(stage || '')] || '继续当前任务';
}

function projectV3TaskActions({ projectRoot, task } = {}) {
  const current = task && typeof task === 'object' ? task : {};
  const workflowId = String(current.workflow_id || '');
  if (!workflowId) throw new Error('workflow_id_required');
  const pending = current.pending_action && typeof current.pending_action === 'object'
    ? current.pending_action
    : null;
  if (pending && String(pending.status || '') === 'pending') {
    const interaction = renderCommittedInteraction(current);
    return {
      selection_contract: 'v3_committed_binding',
      options: pending.options.map((option) => ({
        number: Number(option.number),
        label: String(option.label || ''),
        action_id: String(option.action_id || ''),
        interaction_mode: 'resolve_committed_binding',
      })),
      action_resolution: interaction.binding,
      visible_response: interaction,
    };
  }

  if (planningChatInputRequested(current, pending)) {
    return planningChatInputProjection({ projectRoot, current, workflowId });
  }

  const stage = String(current.current_stage || '');
  const stageLabel = visibleStageLabel(stage);
  const quotedWorkflowId = JSON.stringify(workflowId);
  const options = [
    {
      number: 1,
      label: `继续${stageLabel}（推荐）`,
      action_id: 'resume_current_v3_stage',
      interaction_mode: 'execute_command',
      execution_command: stage === 'planning_confirmation'
        ? `node scripts/workflow-v3.js run-current-stage --project-root . --workflow-id ${quotedWorkflowId} --expected-version ${Number(current.state_version || 0)} --json`
        : `node scripts/workflow-v3.js describe-stage --project-root . --workflow-id ${quotedWorkflowId} --json`,
    },
    {
      number: 2,
      label: '查看当前进度与依据',
      action_id: 'inspect_current_v3_state',
      interaction_mode: 'execute_command',
      execution_command: `node scripts/workflow-v3.js show --project-root . --workflow-id ${quotedWorkflowId} --json`,
    },
    {
      number: 3,
      label: '暂停并保存断点',
      action_id: 'pause',
      interaction_mode: 'semantic_only',
      execution_command: '',
    },
    {
      number: 4,
      label: '输入其他要求',
      action_id: 'free_text',
      interaction_mode: 'semantic_only',
      execution_command: '',
    },
  ];
  const title = String(current.task_display_title || current.user_goal || '当前短篇任务');
  return {
    selection_contract: 'v3_task_action_projection',
    options,
    action_resolution: null,
    visible_response: [
      `当前任务：${title}`,
      `当前阶段：${stageLabel}`,
      '',
      ...options.map((option) => `${option.number}. ${option.label}`),
      '',
      '回复数字选择，也可以直接输入你的意见。',
    ].join('\n'),
    project_root: projectRoot ? String(projectRoot) : '',
  };
}

function planningChatInputRequested(task, pending) {
  return String((task || {}).current_stage || '') === 'planning_confirmation'
    && String((pending || {}).status || '') === 'resolved'
    && String((((pending || {}).selection || {}).action_id) || '') === 'modify_planning_in_chat';
}

function planningChatInputProjection({ projectRoot, current, workflowId }) {
  const quotedWorkflowId = JSON.stringify(workflowId);
  const version = Number(current.state_version || 0);
  const options = [
    {
      number: 1,
      label: '在 Chat 中输入对方案的修改要求（推荐）',
      action_id: 'submit_planning_feedback',
      interaction_mode: 'chat_input',
      execution_command: '',
    },
    {
      number: 2,
      label: '查看当前规划与依据',
      action_id: 'inspect_current_v3_state',
      interaction_mode: 'execute_command',
      execution_command: `node scripts/workflow-v3.js describe-stage --project-root . --workflow-id ${quotedWorkflowId} --json`,
    },
    {
      number: 3,
      label: '返回采用或修改选择',
      action_id: 'reopen_planning_confirmation',
      interaction_mode: 'execute_command',
      execution_command: `node scripts/workflow-v3.js run-current-stage --project-root . --workflow-id ${quotedWorkflowId} --expected-version ${version} --json`,
    },
  ];
  const title = String(current.task_display_title || current.user_goal || '当前短篇任务');
  return {
    selection_contract: 'v3_planning_chat_input',
    options,
    action_resolution: null,
    visible_response: [
      `当前任务：${title}`,
      '当前阶段：确认写作方案',
      '',
      '请直接在 Chat 中说明要改哪一节、要保留什么、希望怎样调整；系统会先生成可确认的回写方案。',
      '',
      ...options.map((option) => `${option.number}. ${option.label}`),
    ].join('\n'),
    project_root: projectRoot ? String(projectRoot) : '',
  };
}

module.exports = { projectV3TaskActions, visibleStageLabel };
