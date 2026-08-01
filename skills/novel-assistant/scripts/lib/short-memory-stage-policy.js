'use strict';

const { validateShortStageMemoryReceipt } = require('./short-memory-snapshot');

function checkShortMemoryStage({ projectRoot, task, execution, sectionIndex, stageId } = {}) {
  const validation = validateShortStageMemoryReceipt(projectRoot, task, execution, { sectionIndex, stageId });
  return classifyShortMemoryStage(validation, stageId);
}

function classifyShortMemoryStage(validation = {}, stageId = '') {
  const status = String(validation.status || 'missing');
  const stage = String(stageId || '');
  if (status === 'current') {
    return {
      status: 'pass',
      blocking: false,
      memory_status: status,
      receipt: validation.current_receipt || null,
      stale_sources: [],
    };
  }
  if (status === 'not_recorded') {
    return {
      status: 'legacy_memory_unverified',
      blocking: false,
      memory_status: status,
      receipt: null,
      stale_sources: [],
      advisory: '旧任务没有阶段记忆回执；本轮兼容继续，下一阶段将生成新版当前作品记忆快照。',
    };
  }
  if (status === 'stale' && stage === 'section_accept_anchor') {
    return {
      status: 'short_memory_context_refresh_required',
      blocking: false,
      refresh_allowed: true,
      memory_status: status,
      receipt: validation.current_receipt || null,
      stale_sources: Array.isArray(validation.stale_sources) ? validation.stale_sources : [],
      resume_stage: 'section_accept_anchor',
      instruction: '采用前检测到当前作品记忆变化；工作流应自动刷新当前阶段上下文并继续采用。刷新失败时才暂停。',
    };
  }
  return {
    status: 'short_memory_context_refresh_required',
    blocking: true,
    memory_status: status,
    receipt: validation.current_receipt || null,
    stale_sources: Array.isArray(validation.stale_sources) ? validation.stale_sources : [],
    resume_stage: String(stageId || '') === 'section_accept_anchor' ? 'quality_gate' : String(stageId || 'quality_gate'),
    instruction: String(stageId || '') === 'section_accept_anchor'
      ? '当前作品事实在采用前变化；保留候选稿，回到当前节故事质量门重建上下文并复核连续性，不得写入正式正文。'
      : '当前作品事实在本阶段启动后变化；保留候选稿，重建当前节上下文并复核，不得重写整篇。',
  };
}

module.exports = {
  checkShortMemoryStage,
  classifyShortMemoryStage,
};
