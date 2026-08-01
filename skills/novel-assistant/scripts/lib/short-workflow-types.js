'use strict';

/**
 * 短篇工作流类型的单一事实来源。
 *
 * 历史：['short_write', 'short_startup', 'private_short_startup'] 曾在 scripts/ 下
 * 重复 13 处（数组内联 .includes() 与本地 Set 常量两种风格并存），新增 workflow_type
 * 时存在静默失配风险。本模块将其收敛为唯一来源。
 */

const SHORT_WORKFLOW_TYPES = new Set(['short_write', 'short_startup', 'private_short_startup']);

function isShortWorkflowType(type) {
  return SHORT_WORKFLOW_TYPES.has(String(type || ''));
}

module.exports = {
  SHORT_WORKFLOW_TYPES,
  isShortWorkflowType,
};
