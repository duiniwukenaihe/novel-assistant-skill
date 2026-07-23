#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const [stateMachine, projectRoot] = process.argv.slice(2);
if (!stateMachine || !projectRoot) throw new Error('usage: workflow-cli-contract-snapshot.js <state-machine> <project-root>');

function invoke(args) {
  const result = spawnSync(process.execPath, [stateMachine, ...args, '--json'], { encoding: 'utf8' });
  if (result.status !== 0 && result.status !== 2) throw new Error(result.stderr || result.stdout || `command failed: ${args.join(' ')}`);
  return JSON.parse(result.stdout);
}

function focusedTask() {
  const pointer = JSON.parse(fs.readFileSync(path.join(projectRoot, '追踪', 'workflow', 'current-task.json'), 'utf8'));
  return JSON.parse(fs.readFileSync(path.join(projectRoot, pointer.task_dir, 'task.json'), 'utf8'));
}

function resolveCurrent() {
  const task = focusedTask();
  const pending = task.pending_action || {};
  return invoke([
    'resolve-action', '--project-root', projectRoot, '--input', '1',
    '--pending-action-id', String(pending.id || ''),
    '--visible-choice-hash', String(pending.visible_choice_hash || ''),
    '--state-version', String(task.state_version), '--book-root', projectRoot,
  ]);
}

function applyPassingResult() {
  const task = focusedTask();
  const resultPath = path.join(projectRoot, task.stage_execution.expected_result_packet);
  fs.mkdirSync(path.dirname(resultPath), { recursive: true });
  fs.writeFileSync(resultPath, `${JSON.stringify({
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: task.current_stage,
    step_id: task.current_stage,
    owner_module: String((task.stage_execution || {}).owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: [],
    changed_files: [],
    evidence: ['command-facade characterization'],
    verification_result: 'pass',
    blocking_reason: '',
    next_recommendation: '继续下一阶段',
    handoff_summary: 'command-facade characterization',
    checkpoint_state: {},
    output_health_result: 'pass',
    result_write_set: [],
    asset_revision: { status: 'verified', asset_id: '' },
    review_decision: 'not_applicable',
    downstream_effects: [],
    lifecycle_transition_request: { action: 'advance', target: task.current_stage },
  }, null, 2)}\n`);
  return invoke(['apply-result', '--project-root', projectRoot, '--workflow-id', task.workflow_id, '--result', resultPath]);
}

function summary(result) {
  const task = result.task || {};
  const action = result.action || {};
  const pending = result.pending_action || {};
  return {
    status: result.status || '',
    keys: Object.keys(result).sort(),
    workflow_type: task.workflow_type || '',
    task_status: task.status || '',
    current_stage: result.current_stage || task.current_stage || '',
    target_stage: result.target_stage || '',
    action_id: result.action_id || action.action_id || '',
    selected_number: result.selected_number || 0,
    candidate_actions: (result.next_candidates || pending.options || []).map((item) => item.action_id || item.action || '').filter(Boolean),
    migration_item_count: Array.isArray((result.migration_inventory || {}).items) ? result.migration_inventory.items.length : 0,
  };
}

const snapshots = {};
snapshots.templates = summary(invoke(['templates', '--no-private-registry']));
snapshots.create = summary(invoke(['create', '--workflow-type', 'long_startup', '--project-root', projectRoot, '--user-goal', '开新书']));
const firstWorkflowId = focusedTask().workflow_id;
snapshots.inspect = summary(invoke(['inspect', '--project-root', projectRoot]));
snapshots.next_candidates = summary(invoke(['next-candidates', '--project-root', projectRoot]));
snapshots.resolve_action = summary(resolveCurrent());
snapshots.apply_result = summary(applyPassingResult());
snapshots.switch_intent = summary(invoke(['switch-intent', '--workflow-type', 'short_startup', '--project-root', projectRoot, '--user-goal', '开短篇', '--reason', 'contract-snapshot']));
snapshots.activate = summary(invoke(['activate', '--workflow-id', firstWorkflowId, '--project-root', projectRoot]));
snapshots.migrate_legacy = summary(invoke(['migrate-legacy', '--project-root', projectRoot, '--source', 'novel-assistant-previous']));

process.stdout.write(`${JSON.stringify(snapshots, null, 2)}\n`);
