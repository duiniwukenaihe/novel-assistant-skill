'use strict';

const { checkShortMemoryStage } = require('./short-memory-stage-policy');
const { refreshCurrentStageContext } = require('./workflow-stage-context-refresh');
const { resolveTaskAuthority } = require('./workflow-task-authority');

function ensureCurrentShortMemoryStage({ projectRoot, workflowId, task, execution, sectionIndex, stageId } = {}) {
  const first = checkShortMemoryStage({ projectRoot, task, execution, sectionIndex, stageId });
  if (!first.blocking && first.refresh_allowed !== true) return ready(task, execution, first, false);
  if (first.status !== 'short_memory_context_refresh_required' || Number((execution || {}).context_refresh_count || 0) >= 1) {
    return blocked(first);
  }
  const refreshed = refreshCurrentStageContext(projectRoot, workflowId);
  if (refreshed.status !== 'stage_context_refreshed') {
    return blocked(first, { refresh_status: refreshed.status, refresh_message: refreshed.message || '' });
  }
  const authority = resolveTaskAuthority(projectRoot, workflowId);
  if (authority.status !== 'ok') return blocked(first, { refresh_status: authority.status });
  const nextTask = authority.task;
  const nextExecution = nextTask.stage_execution || {};
  const second = checkShortMemoryStage({ projectRoot, task: nextTask, execution: nextExecution, sectionIndex, stageId });
  if (second.blocking) return blocked(second, { refresh_status: 'refreshed_but_constraints_changed' });
  return ready(nextTask, nextExecution, second, true);
}

function ready(task, execution, validation, refreshed) {
  return {
    status: refreshed ? 'refreshed_and_current' : 'current',
    blocking: false,
    refreshed,
    task,
    execution,
    validation,
    memory_status: validation.memory_status || '',
    stale_sources: validation.stale_sources || [],
  };
}

function blocked(validation, extra = {}) {
  return {
    status: validation.status || 'short_memory_context_refresh_required',
    blocking: true,
    memory_status: validation.memory_status || '',
    stale_sources: validation.stale_sources || [],
    resume_stage: validation.resume_stage || '',
    instruction: validation.instruction || '当前阶段记忆约束已变化，保留候选制品并等待复核。',
    ...extra,
  };
}

module.exports = { ensureCurrentShortMemoryStage };
