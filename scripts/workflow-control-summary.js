#!/usr/bin/env node
'use strict';

const path = require('path');
const { WorkflowTaskRepository } = require('./lib/workflow-task-repository');
const { StoryMemoryRepository } = require('./lib/story-memory-repository');
const { UserProfileRepository } = require('./lib/user-profile-repository');

function buildWorkflowControlSummary(projectRoot, options = {}) {
  const root = path.resolve(projectRoot || '');
  const tasks = options.taskStore || new WorkflowTaskRepository(root, { adapter: options.taskAdapter });
  const memory = options.storyMemory || new StoryMemoryRepository(root, { backend: options.storageBackend });
  const profile = options.userProfile || new UserProfileRepository(root, { backend: options.storageBackend });
  const unfinished = tasks.unfinishedTasks();
  const focused = tasks.focusedTask();
  const memorySummary = memory.summary();
  const profileSummary = profile.summary();
  return {
    schema_version: '1.0.0',
    status: 'ok',
    project: {
      project_id: String(((memorySummary || {}).project || {}).project_id || ''),
      project_title: String(((memorySummary || {}).project || {}).project_title || ((memorySummary || {}).project || {}).title || ''),
      project_instance_id: String(((memorySummary || {}).identity || {}).project_instance_id || ''),
    },
    task_store: {
      unfinished_count: unfinished.length,
      focused_workflow_id: String((focused || {}).workflow_id || ''),
      tasks: unfinished.map(task => ({
        workflow_id: task.workflow_id,
        workflow_type: task.workflow_type,
        current_stage: task.current_stage,
        status: task.status,
        pending_feedback_count: Number((((task || {}).pending_feedback || {}).item_count) || 0),
        proposed_plan_status: String((((task || {}).proposed_plan || {}).status) || ''),
        accepted_plan_status: String((((task || {}).accepted_plan || {}).status) || ''),
        revision_queue_status: String((((task || {}).feedback_revision_queue || {}).status) || ''),
        updated_at: String(task.updated_at || ''),
      })),
    },
    user_profile: profileSummary,
    story_memory: {
      status: 'summary_only',
      active_facts: Number(memorySummary.active_facts || 0),
      active_promises: Number(memorySummary.active_promises || 0),
      confirmed_style_rules: Number(memorySummary.confirmed_style_rules || 0),
      planning_constraints: Number(memorySummary.planning_constraints || 0),
      quality_rules: Number(memorySummary.quality_rules || 0),
      pending_memory_suggestions: Number(memorySummary.pending_memory_suggestions || 0),
      domain_learning_records: Number(memorySummary.domain_learning_records || 0),
      backend: String(memorySummary.backend || ''),
    },
  };
}

function parseArgs(argv) {
  const out = { projectRoot: '', writeIdentity: false };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--project-root') out.projectRoot = argv[++i] || '';
    else if (argv[i] === '--write-identity') out.writeIdentity = true;
    else if (argv[i] === '--json') continue;
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return out;
}

module.exports = { buildWorkflowControlSummary };

if (require.main === module) {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (!args.projectRoot) throw new Error('--project-root is required');
    if (args.writeIdentity) {
      const { LocalStorageBackend } = require('./lib/local-storage-backend');
      new LocalStorageBackend(args.projectRoot).ensureProjectIdentity({ write: true });
    }
    process.stdout.write(`${JSON.stringify(buildWorkflowControlSummary(args.projectRoot), null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
}
