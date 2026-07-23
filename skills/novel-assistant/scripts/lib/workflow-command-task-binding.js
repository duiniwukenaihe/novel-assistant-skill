'use strict';

const fs = require('fs');
const path = require('path');

// A write/finalize command may use the UI focus only when the project has one
// unfinished durable task. With multiple tasks or sessions, callers must pass
// --workflow-id; guessing from current-task.json can commit an artifact to the
// wrong task after a focus switch.
function singleUnfinishedWorkflowId(projectRoot) {
  const root = path.resolve(String(projectRoot || ''));
  const tasksDir = path.join(root, '追踪', 'workflow', 'tasks');
  if (!fs.existsSync(tasksDir)) return '';
  const unfinished = [];
  for (const entry of fs.readdirSync(tasksDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const task = readJson(path.join(tasksDir, entry.name, 'task.json'));
    if (!task || !task.workflow_id) continue;
    const status = String(((task.lifecycle || {}).status) || task.status || '').toLowerCase();
    if (!['completed', 'closed', 'cancelled', 'canceled', 'superseded', 'archived'].includes(status)) {
      unfinished.push(String(task.workflow_id));
    }
  }
  return unfinished.length === 1 ? unfinished[0] : '';
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

module.exports = { singleUnfinishedWorkflowId };
