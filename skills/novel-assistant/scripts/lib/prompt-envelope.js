'use strict';

const crypto = require('crypto');

const STABLE_HARNESS_PREFIX = [
  '你正在 novel-assistant 的受托管非交互执行环境中工作。',
  '只执行当前已确认阶段，不重新路由、不重新规划、不展示候选菜单。',
  '正式写入必须服从阶段写入集；不得提前执行下一阶段。',
  '完整正文、原始工具日志和历史上下文不得复制到最终回复。',
  '失败或退化时停止在最后可信断点，并写出结构化受阻回执。',
].join('\n');

function buildPromptEnvelope(dynamicLines) {
  const dynamicContext = (Array.isArray(dynamicLines) ? dynamicLines : [])
    .map((line) => String(line || '').trim())
    .filter(Boolean)
    .join('\n');
  return {
    schemaVersion: '1.0.0',
    stable_prefix: STABLE_HARNESS_PREFIX,
    stable_prefix_digest: sha256(STABLE_HARNESS_PREFIX),
    dynamic_context: dynamicContext,
    dynamic_context_digest: sha256(dynamicContext),
    prompt: `${STABLE_HARNESS_PREFIX}\n--- 动态任务上下文 ---\n${dynamicContext}`,
  };
}

function sha256(value) {
  return `sha256:${crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex')}`;
}

module.exports = { buildPromptEnvelope, STABLE_HARNESS_PREFIX };
