#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { currentReviewBatch, validateReviewBatchPlanMapping } = require('./lib/review-batch-state');
const { readReviewPlan, legacyReadOnlyBlock } = require('./lib/review-plan-contract');
const { readFocusedTask } = require('./lib/workflow-task-authority');

const args = parseArgs(process.argv);
if (!args.projectRoot) fail('missing --project-root');
const root = path.resolve(args.projectRoot);
const focused = readFocusedTask(root);
const task = focused.authority.status === 'ok' ? focused.authority.task : null;
if (!task && focused.pointer) output({ status: focused.authority.status, error: focused.authority.message || 'durable task snapshot is unavailable' }, 2);
if (!task) output({ status: 'no_active_task' }, 0);
if (task.workflow_type !== 'review_repair') output({ status: 'not_review_workflow', workflow_type: task.workflow_type || '' }, 0);

const loadedPlan = loadReviewPlan(root, task);
if (loadedPlan.error) output(loadedPlan.error, 2);
if (loadedPlan.planReadMode === 'legacy_read_only' && args.command !== 'inspect') {
  output(legacyReadOnlyBlock(task), 2);
}

if (!task.review_batches && args.command === 'init') {
  if (loadedPlan.plan) output({ status: 'blocked_review_plan_stale', error: 'review batch state is missing for a persisted review plan' }, 2);
  output({ status: 'blocked_review_plan_missing', error: 'review batch state requires a persisted review plan' }, 2);
}

if (!task.review_batches) output({ status: 'review_batches_missing', scope: task.scope || '' }, 2);
if (loadedPlan.plan) {
  try {
    validateReviewBatchPlanMapping(task.review_batches, loadedPlan.plan);
  } catch (error) {
    output({ status: 'blocked_review_plan_stale', error: error.message }, 2);
  }
}
const next = currentReviewBatch(task.review_batches);
output({
  status: 'ok',
  workflow_id: task.workflow_id,
  parent_scope: task.review_batches.parent_scope,
  aggregate_status: task.review_batches.aggregate_status,
  completed_count: task.review_batches.completed_count,
  total_count: task.review_batches.total_count,
  plan_read_mode: loadedPlan.planReadMode || 'unreferenced_legacy',
  next_batch: next,
  batches: task.review_batches.batches,
}, 0);

function parseArgs(argv) {
  const out = { command: argv[2] || 'inspect', projectRoot: '', write: false, json: false };
  for (let i = 3; i < argv.length; i += 1) {
    if (argv[i] === '--project-root') out.projectRoot = argv[++i] || '';
    else if (argv[i] === '--batch-size') fail('--batch-size is deprecated; persisted review plans own their batch boundaries');
    else if (argv[i] === '--write') out.write = true;
    else if (argv[i] === '--json') out.json = true;
    else fail(`unknown argument: ${argv[i]}`);
  }
  if (!['inspect', 'init'].includes(out.command)) fail('command must be inspect or init');
  return out;
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function loadReviewPlan(projectRoot, taskState) {
  if (!taskState.review_plan_path && !taskState.review_plan_digest) return { plan: null, error: null };
  try {
    const loaded = readReviewPlan(projectRoot, taskState);
    return { plan: loaded.plan, planReadMode: loaded.plan_read_mode || 'current', error: null };
  } catch (error) {
    return { plan: null, error: {
      status: error && error.code === 'REVIEW_PLAN_STALE' ? 'blocked_review_plan_stale' : 'blocked_review_plan_missing',
      error: (error && error.message) || 'review plan is unavailable',
    }};
  }
}

function output(value, code) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  process.exit(code);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
