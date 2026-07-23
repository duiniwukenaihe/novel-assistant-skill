'use strict';

function renderTaskMarkdown(task) {
  const machine = task.machine || {};
  const lifecycle = task.lifecycle || {};
  const remaining = Array.isArray(machine.remaining_stages) ? machine.remaining_stages.join(' -> ') : '';
  const pending = task.pending_action && Array.isArray(task.pending_action.options) ? task.pending_action.options : [];
  const nextLines = pending.length > 0
    ? pending.map((item) => `${item.number || ''}. ${item.label || item.action_id || item.action || '下一步'}`).join('\n')
    : '暂无候选。';
  const stageExecution = task.stage_execution && task.stage_execution.status === 'running'
    ? [
        '',
        '## 当前执行阶段',
        '',
        `- 阶段：${task.stage_execution.stage_id}`,
        '- 状态：执行中，等待 result packet',
        `- 预期回执：${task.stage_execution.expected_result_packet || ''}`,
        `- 恢复提示：${task.stage_execution.resume_hint || ''}`,
      ].join('\n')
    : '';
  const visibleReviewTarget = task.workflow_type === 'review_repair' && task.review_target
    ? task.review_target
    : null;
  const visibleGoal = visibleReviewTarget ? visibleReviewTarget.visible_label : (task.user_goal || lifecycle.user_goal || '');
  const visibleScope = visibleReviewTarget ? visibleReviewTarget.narrative_scope : (task.scope || lifecycle.scope || '');
  const visibleStageExecution = visibleReviewTarget && task.current_stage === 'evidence_scan'
    ? ''
    : stageExecution;
  return [
    '# 当前任务记录',
    '',
    `- 任务编号：${task.workflow_id}`,
    `- 任务类型：${task.workflow_type}`,
    `- 用户目标：${visibleGoal}`,
    `- 范围：${visibleScope}`,
    `- 状态：${task.status}`,
    `- 生命周期：${lifecycle.status || ''}`,
    `- 推进策略：${task.completion_policy}`,
    `- 当前阶段：${task.current_stage}`,
    `- 当前步骤：${task.current_step}`,
    `- 剩余阶段：${remaining}`,
    '',
    '## 下一步候选',
    '',
    nextLines,
    visibleStageExecution,
    '',
  ].join('\n');
}

module.exports = { renderTaskMarkdown };
