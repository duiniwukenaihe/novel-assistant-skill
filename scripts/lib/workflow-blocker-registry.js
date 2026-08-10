'use strict';

const READ_ONLY_INSPECT = 'node scripts/workflow-state-machine.js inspect --project-root . --json';

const RECOVERY_BY_REASON = Object.freeze({
  story_gate: Object.freeze({
    action_id: 'resume_section_repair',
    interaction_mode: 'execute_command',
    execution_command: 'node scripts/workflow-state-machine.js next-candidates --project-root . --json',
    visible_reason: '当前小节的故事质量检查未通过；请按已记录的反馈修订正文后重新复检。',
  }),
  runtime_guard_missing: Object.freeze({
    action_id: 'repair_runtime_guard',
    interaction_mode: 'execute_command',
    execution_command: READ_ONLY_INSPECT,
    visible_reason: '任务缺少运行边界；请先查看可信断点和需要补齐的运行记录。',
  }),
  task_authority_missing: Object.freeze({
    action_id: 'recover_task_authority',
    interaction_mode: 'route_intent',
    execution_command: '',
    visible_reason: '当前任务的权威断点缺失；需要先由作者说明要恢复的具体任务和范围。',
  }),
  state_invariant: Object.freeze({
    action_id: 'repair_task_state',
    interaction_mode: 'execute_command',
    execution_command: READ_ONLY_INSPECT,
    visible_reason: '任务状态存在不一致；请先查看保留证据后的修复方案。',
  }),
  trusted_artifact_missing: Object.freeze({
    action_id: 'recover_missing_result_packet',
    interaction_mode: 'execute_command',
    execution_command: READ_ONLY_INSPECT,
    visible_reason: '最后可信产物缺失；请先查看可恢复的结果回执范围。',
  }),
});

function normalizeReason(value) {
  return String(value || '').trim().toLowerCase().replace(/^blocked_/u, '');
}

function resolveRecoveryAction(input = {}) {
  const reasonCode = normalizeReason(input.reason_code || input.task_status || input.status);
  const known = RECOVERY_BY_REASON[reasonCode];
  if (known) return { ...known, reason_code: reasonCode };
  return {
    action_id: 'inspect_blocker_details',
    interaction_mode: 'read_only',
    execution_command: READ_ONLY_INSPECT,
    visible_reason: '当前阻断原因无法安全判断，已停止自动修复；请先只读查看任务状态与依据。',
    reason_code: reasonCode || 'unknown_blocker',
  };
}

module.exports = {
  RECOVERY_BY_REASON,
  resolveRecoveryAction,
};
