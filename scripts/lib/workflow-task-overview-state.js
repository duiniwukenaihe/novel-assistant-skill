'use strict';

const crypto = require('crypto');

function stablePlanShape(task) {
  const queue = task && task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : {};
  const scheduling = task && task.scheduling_contract && typeof task.scheduling_contract === 'object'
    ? task.scheduling_contract
    : {};
  return {
    workflow_id: String((task || {}).workflow_id || ''),
    workflow_type: String((task || {}).workflow_type || ''),
    user_goal: String((task || {}).user_goal || ((task || {}).lifecycle || {}).user_goal || ''),
    scope: String((task || {}).scope || ((task || {}).lifecycle || {}).scope || ''),
    task_form: String(scheduling.task_form || ''),
    queue_groups: (Array.isArray(queue.groups) ? queue.groups : []).map(group => ({
      id: String((group || {}).id || (group || {}).group_id || ''),
      label: String((group || {}).label || (group || {}).title || ''),
      section_indices: (Array.isArray((group || {}).section_indices) ? group.section_indices : []).map(Number),
    })),
    queue_items: (Array.isArray(queue.items) ? queue.items : []).map(item => ({
      id: String((item || {}).id || (item || {}).task_id || ''),
      section_index: Number((item || {}).section_index || 0),
      chapter_index: Number((item || {}).chapter_index || 0),
      title: String((item || {}).title || (item || {}).section_title || (item || {}).label || ''),
    })),
  };
}

function taskOverviewPlanDigest(task) {
  return crypto.createHash('sha256').update(JSON.stringify(stablePlanShape(task))).digest('hex');
}

function taskHasOverview(task) {
  const queue = task && task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  const revisionQueue = Boolean(queue && String(queue.status || '') === 'running'
    && Array.isArray(queue.items) && queue.items.length > 0);
  const scheduling = task && task.scheduling_contract && typeof task.scheduling_contract === 'object'
    ? task.scheduling_contract
    : null;
  return revisionQueue || Boolean(scheduling && scheduling.task_form);
}

function taskOverviewPresentationRequired(task) {
  if (!taskHasOverview(task)) return false;
  const overview = (((task || {}).navigation || {}).task_overview) || {};
  return String(overview.presented_plan_digest || '') !== taskOverviewPlanDigest(task);
}

function markTaskOverviewPresented(task, presentedAt = new Date().toISOString()) {
  task.navigation = task.navigation && typeof task.navigation === 'object' ? task.navigation : {};
  task.navigation.task_overview = {
    ...(task.navigation.task_overview || {}),
    presented_plan_digest: taskOverviewPlanDigest(task),
    presented_at: presentedAt,
  };
  return task.navigation.task_overview;
}

module.exports = {
  markTaskOverviewPresented,
  taskHasOverview,
  taskOverviewPlanDigest,
  taskOverviewPresentationRequired,
};
