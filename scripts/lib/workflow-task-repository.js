'use strict';

const fs = require('fs');
const path = require('path');

const TERMINAL = new Set(['completed', 'complete', 'cancelled', 'canceled', 'abandoned', 'archived']);

class WorkflowTaskRepository {
  constructor(projectRoot, options = {}) {
    this.projectRoot = path.resolve(String(projectRoot || ''));
    this.adapter = options.adapter || null;
  }

  listTasks() {
    if (this.adapter && typeof this.adapter.listWorkflowTasks === 'function') {
      return normalizeTasks(this.adapter.listWorkflowTasks());
    }
    const tasksRoot = path.join(this.projectRoot, '追踪', 'workflow', 'tasks');
    if (!fs.existsSync(tasksRoot)) return [];
    return normalizeTasks(fs.readdirSync(tasksRoot, { withFileTypes: true })
      .filter(entry => entry.isDirectory())
      .map(entry => readJson(path.join(tasksRoot, entry.name, 'task.json')))
      .filter(Boolean));
  }

  unfinishedTasks() {
    return this.listTasks().filter(task => !TERMINAL.has(String(task.status || '').toLowerCase()));
  }

  focusedTask() {
    if (this.adapter && typeof this.adapter.focusedWorkflowTask === 'function') return this.adapter.focusedWorkflowTask() || null;
    const pointer = readJson(path.join(this.projectRoot, '追踪', 'workflow', 'current-task.json')) || {};
    const workflowId = String(pointer.workflow_id || pointer.active_workflow_id || '');
    return workflowId ? this.listTasks().find(task => task.workflow_id === workflowId) || null : null;
  }
}

function normalizeTasks(tasks) {
  return (Array.isArray(tasks) ? tasks : []).filter(task => task && task.workflow_id).map(task => ({
    ...task,
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || ''),
    current_stage: String(task.current_stage || task.current_step || ''),
    status: String(task.status || 'running'),
  })).sort((left, right) => String(right.updated_at || '').localeCompare(String(left.updated_at || '')) || left.workflow_id.localeCompare(right.workflow_id));
}

function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }

module.exports = { TERMINAL, WorkflowTaskRepository };
