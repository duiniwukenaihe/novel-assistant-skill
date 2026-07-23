#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE="$REPO/scripts/workflow-state-machine.js"
    COMMIT="$REPO/scripts/chapter-commit.js"
    POLLUTION="$REPO/scripts/output-pollution-check.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "review repair blocks polluted candidates and requires an accepted transaction before canonical repair" {
    node - "$STATE" "$COMMIT" "$POLLUTION" "$BOOK" <<'NODE'
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const [state, commit, pollution, root] = process.argv.slice(2);

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  return { status: result.status, output: result.stdout || '', error: result.stderr || '' };
}
function json(result) {
  try { return JSON.parse(result.output); } catch (error) { throw new Error(`${error.message}: ${result.output}\n${result.error}`); }
}
function read(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function write(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`); }
function taskFile() { return path.join(root, '追踪/workflow/current-task.json'); }
function configureStage(stageId, requiresConfirmation) {
  const task = read(taskFile());
  const expected = `${task.context_paths.result_packets_dir}/${stageId}.result.json`;
  const now = new Date().toISOString();
  task.current_stage = stageId;
  task.current_step = stageId;
  task.status = 'running';
  task.machine = task.machine || {};
  task.machine.remaining_stages = [stageId, ...(stageId === 'repair_machine_gate' ? ['execute_repair', 'recheck', 'closure'] : ['recheck', 'closure'])];
  task.stage_execution = {
    status: 'running', stage_id: stageId, step_id: stageId,
    expected_result_packet: expected, owner_module: stageId === 'repair_machine_gate' ? 'story-workflow' : 'story-long-write',
    requires_user_confirm: requiresConfirmation, selected_number: 1, action_id: 'continue_next_stage',
  };
  task.runtime_guard.checkpoint_policy.expected_result_packet = expected;
  if (requiresConfirmation) {
    task.pending_action = { id: `pa-${stageId}`, status: 'resolved', visible_choice_hash: 'fixture-hash', expires_at: '2099-01-01T00:00:00.000Z', options: [] };
    task.last_selection = {
      confirmation_token: 'fixture-token', selection_id: task.pending_action.id, selected_number: 1,
      action_id: 'continue_next_stage', visible_choice_hash: 'fixture-hash', requires_user_confirm: true,
    };
    task.stage_execution.confirmation_token = 'fixture-token';
    task.stage_execution.confirmation_context = {
      status: 'confirmed', confirmation_token: 'fixture-token', workflow_id: task.workflow_id,
      workflow_type: task.workflow_type, stage_id: stageId, step_id: stageId,
      selection_id: task.pending_action.id, selected_number: 1, selected_action_id: 'continue_next_stage',
      visible_choice_hash: 'fixture-hash', expires_at: '2099-01-01T00:00:00.000Z', confirmed_at: now,
    };
  }
  write(taskFile(), task);
  write(path.join(root, task.task_dir, 'task.json'), task);
  return { task, expected };
}
function writeResult(stage, packet) {
  const task = read(taskFile());
  const file = path.join(root, task.stage_execution.expected_result_packet);
  write(file, {
    workflow_id: task.workflow_id, workflow_type: task.workflow_type, stage_id: stage, step_id: stage,
    step_status: 'completed', outputs: [], changed_files: [], evidence: ['fixture'], verification_result: 'pass',
    blocking_reason: '', next_recommendation: '', handoff_summary: 'fixture', checkpoint_state: {},
    output_health_result: 'pass', result_packet_path: task.stage_execution.expected_result_packet,
    ...packet,
  });
  return file;
}
function apply(file) { return run(process.execPath, [state, 'apply-result', '--project-root', root, '--result', file, '--json']); }

fs.mkdirSync(path.join(root, '正文/第1卷'), { recursive: true });
fs.mkdirSync(path.join(root, '追踪/story-system'), { recursive: true });
const canonical = path.join(root, '正文/第1卷/第001章.md');
fs.writeFileSync(canonical, '# 第一章\n原始正文。\n');
fs.writeFileSync(path.join(root, '追踪/story-system/write-policy.json'), JSON.stringify({ schemaVersion: '1.0.0', mode: 'strict' }));

const created = run(process.execPath, [state, 'create', '--workflow-type', 'review_repair', '--project-root', root, '--scope', '第1章', '--user-goal', '修复第一章', '--json']);
if (created.status !== 0) throw new Error(created.output || created.error);

const polluted = path.join(root, '追踪/staging/polluted.md');
fs.mkdirSync(path.dirname(polluted), { recursive: true });
fs.writeFileSync(polluted, `${'修真高潮 '.repeat(20)}\n`);
const pollutionResult = run(process.execPath, [pollution, polluted, '--json']);
if (pollutionResult.status === 0 || !pollutionResult.output.includes('domain-token-flood')) throw new Error(`pollution gate did not block: ${pollutionResult.output}`);

const gate = configureStage('repair_machine_gate', false);
const blockedPacket = writeResult('repair_machine_gate', {
  step_status: 'blocked', outputs: ['追踪/staging/polluted.md'], verification_result: 'blocked',
  output_health_result: 'blocked', blocking_reason: 'domain-token-flood',
  blocking_findings: [{ code: 'domain-token-flood', phrase: '修真高潮' }],
});
const blocked = apply(blockedPacket);
if (blocked.status !== 0) throw new Error(blocked.output || blocked.error);
const afterBlocked = read(taskFile());
if (afterBlocked.current_stage !== 'staged_repair_candidate') throw new Error(`expected staged candidate, got ${afterBlocked.current_stage}`);
if (fs.readFileSync(canonical, 'utf8') !== '# 第一章\n原始正文。\n') throw new Error('polluted candidate changed canonical prose');

configureStage('execute_repair', true);
const uncommittedPacket = writeResult('execute_repair', { changed_files: ['正文/第1卷/第001章.md'] });
const uncommitted = apply(uncommittedPacket);
if (uncommitted.status === 0) throw new Error(`canonical repair advanced without transaction: ${uncommitted.output}`);
if (!uncommitted.output.includes('blocked_canonical_transaction_required')) throw new Error(uncommitted.output || uncommitted.error);
if (fs.readFileSync(canonical, 'utf8') !== '# 第一章\n原始正文。\n') throw new Error('uncommitted repair changed canonical prose');

const repaired = path.join(root, '追踪/staging/repaired.md');
fs.writeFileSync(repaired, '# 第一章\n修正后的正文。\n');
const workflowId = read(taskFile()).workflow_id;
const manifest = path.join(root, '追踪/staging/repair-manifest.json');
write(manifest, {
  workflow_id: workflowId, volume: '1', chapter: 1,
  gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
  artifacts: [{ role: 'canonical_prose', staged: '追踪/staging/repaired.md', target: '正文/第1卷/第001章.md' }],
});
const prepared = run(process.execPath, [commit, 'prepare', '--project-root', root, '--manifest', manifest, '--json']);
if (prepared.status !== 0) throw new Error(prepared.output || prepared.error);
const accepted = run(process.execPath, [commit, 'accept', '--project-root', root, '--transaction', json(prepared).transaction_id, '--json']);
if (accepted.status !== 0) throw new Error(accepted.output || accepted.error);
const acceptedData = json(accepted);

configureStage('execute_repair', true);
const acceptedCommit = read(acceptedData.commit_file);
const acceptedPacket = writeResult('execute_repair', {
  changed_files: ['正文/第1卷/第001章.md'],
  chapter_commit: {
    mode: 'transactional', accepted_commit_id: acceptedData.commit_id,
    commit_file: path.relative(root, acceptedData.commit_file).split(path.sep).join('/'),
    staged_artifacts: acceptedCommit.artifacts.map((item) => item.target),
    projection_status: acceptedData.projection_status, projection_debt: false,
  },
});
const applied = apply(acceptedPacket);
if (applied.status !== 0) throw new Error(applied.output || applied.error);
if (read(taskFile()).current_stage !== 'recheck') throw new Error(`expected recheck, got ${read(taskFile()).current_stage}`);
if (fs.readFileSync(canonical, 'utf8') !== '# 第一章\n修正后的正文。\n') throw new Error('accepted transaction was not projected to canonical prose');

configureStage('recheck', false);
const recheckPacket = writeResult('recheck', { outputs: ['追踪/审查报告/第1章.md'], verification_result: 'pass', output_health_result: 'pass' });
const rechecked = apply(recheckPacket);
if (rechecked.status !== 0) throw new Error(rechecked.output || rechecked.error);
if (read(taskFile()).current_stage !== 'closure') throw new Error(`expected closure, got ${read(taskFile()).current_stage}`);
NODE
}
