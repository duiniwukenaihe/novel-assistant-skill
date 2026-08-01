'use strict';

function resolveShortReaderMilestone(options = {}) {
  const sectionIndex = positiveInt(options.sectionIndex);
  const outline = options.outlineContract && typeof options.outlineContract === 'object'
    ? options.outlineContract
    : {};
  const task = options.task && typeof options.task === 'object' ? options.task : {};
  const role = String(outline.section_role || outline.role || '');
  const descriptor = `${role} ${String(outline.title || '')} ${String(outline.structural_function || '')}`;
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : {};
  const explicitRework = String(queue.status || '') === 'running'
    && positiveInt(queue.current_section_index) === sectionIndex;

  if (explicitRework) return policy('user_rework', '用户明确要求回炉，本节需要独立读者反应证据。');
  if (sectionIndex === 1 || /opening|黄金开篇|开场/u.test(descriptor)) {
    return policy('golden_opening', '检查首屏抓力、即时损失、主角行动和继续阅读问题。');
  }
  if (/major_reversal|climax|反转|高潮|权力翻转|重大揭示/u.test(descriptor)) {
    return policy('major_reversal', '检查揭示是否改变人物选择，并在后续留下可见余震。');
  }
  if (/ending|finale|结尾|终局|收束/u.test(descriptor)) {
    return policy('ending_payoff', '检查标题承诺、人物变化和关系代价是否得到终局兑现。');
  }
  return { required: false, kind: 'ordinary_section', reviewer: '', dimensions: [] };
}

function policy(kind, reason) {
  return {
    required: true,
    kind,
    reviewer: 'professional-reader',
    reason,
    dimensions: ['reader_pull', 'character_liveliness', 'promise_progress', 'reveal_aftershock'],
  };
}

function positiveInt(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

module.exports = { resolveShortReaderMilestone };
