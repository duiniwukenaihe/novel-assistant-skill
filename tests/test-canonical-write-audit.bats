#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/正文/第1卷" "$PROJECT/追踪/workflow/tasks/wf-audit-close"
    printf '# 第一章\n初始正文。\n' > "$PROJECT/正文/第1卷/第001章.md"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "direct canonical body change blocks workflow closure but never reverts user prose" {
    node - "$REPO" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const root = process.argv[3];
const task = {
  workflow_id: 'wf-audit-direct',
  task_dir: '追踪/workflow/tasks/wf-audit-direct',
  canonical_write_set: ['正文/**'],
};
const target = path.join(root, '正文/第1卷/第001章.md');

audit.captureCanonicalBaseline(root, task);
fs.writeFileSync(target, '# 第一章\n用户直接改写后的正文。\n');
const result = audit.auditCanonicalWrites(root, task);

if (result.status !== 'blocked_unreconciled_canonical_write') throw new Error(JSON.stringify(result));
if (!result.unmanaged_paths.includes('正文/第1卷/第001章.md')) throw new Error(JSON.stringify(result));
if (!fs.readFileSync(target, 'utf8').includes('用户直接改写后的正文。')) throw new Error('user prose was changed');
const auditFile = path.join(root, task.task_dir, 'write-audit.json');
if (!fs.existsSync(auditFile)) throw new Error('write audit was not recorded');
NODE
}

@test "current canonical hash accepted by a chapter transaction permits closure" {
    node - "$REPO" "$PROJECT" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const root = process.argv[3];
const task = {
  workflow_id: 'wf-audit-accepted',
  task_dir: '追踪/workflow/tasks/wf-audit-accepted',
  canonical_write_set: ['正文/**'],
};
const relative = '正文/第1卷/第001章.md';
const target = path.join(root, relative);

audit.captureCanonicalBaseline(root, task);
fs.writeFileSync(target, '# 第一章\n已接受事务写入的正文。\n');
const afterHash = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex')}`;
const commits = path.join(root, '追踪/story-system/commits');
fs.mkdirSync(commits, { recursive: true });
fs.writeFileSync(path.join(commits, 'chapter-v00000000-001-audit.json'), JSON.stringify({
  schemaVersion: '1.0.0',
  commit_id: 'chapter-v00000000-001-audit',
  status: 'accepted',
  workflow_id: task.workflow_id,
  accepted_at: new Date().toISOString(),
  artifacts: [{ target: relative, after_hash: afterHash }],
}));

const result = audit.auditCanonicalWrites(root, task);
if (result.status !== 'ok') throw new Error(JSON.stringify(result));
if (!result.accepted_paths.includes(relative) || result.unmanaged_paths.length !== 0) throw new Error(JSON.stringify(result));
NODE
}

@test "stage-scoped audit ignores unrelated historical canonical drift" {
    node - "$REPO" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const root = process.argv[3];
const task = {
  workflow_id: 'wf-stage-scope',
  workflow_type: 'short_write',
  task_dir: '追踪/workflow/tasks/wf-stage-scope',
  canonical_write_set: ['正文.md', '设定.md'],
};
fs.writeFileSync(path.join(root, '正文.md'), '# 正文\n初始。\n');
fs.writeFileSync(path.join(root, '设定.md'), '# 设定\n初始。\n');
audit.captureCanonicalBaseline(root, task);
fs.writeFileSync(path.join(root, '正文.md'), '# 正文\n阶段开始前的历史改动。\n');

const stageAudit = audit.auditCanonicalWrites(root, task, { declaredWriteSet: ['设定.md'] });
if (stageAudit.status !== 'ok') throw new Error(JSON.stringify(stageAudit));
if (stageAudit.changed_paths.includes('正文.md')) throw new Error(JSON.stringify(stageAudit));

const terminalAudit = audit.auditCanonicalWrites(root, task);
if (terminalAudit.status !== 'blocked_unreconciled_canonical_write') throw new Error(JSON.stringify(terminalAudit));
if (!terminalAudit.unmanaged_paths.includes('正文.md')) throw new Error(JSON.stringify(terminalAudit));
NODE
}

@test "short_write baselines formal assets without template write_set and preserves them across stage capture" {
    node - "$REPO" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const root = process.argv[3];
const task = {
  workflow_id: 'wf-short-assets',
  workflow_type: 'short_write',
  task_dir: '追踪/workflow/tasks/wf-short-assets',
  stage_execution: { stage_id: 'draft_section', write_set: [] },
};
for (const [target, content] of [
  ['设定.md', '# 设定\n初始。\n'],
  ['小节大纲.md', '# 小节\n初始。\n'],
  ['正文.md', '# 正文\n初始。\n'],
]) fs.writeFileSync(path.join(root, target), content);

const first = audit.captureCanonicalBaseline(root, task);
if (JSON.stringify(first.canonical_paths) !== JSON.stringify(['小节大纲.md', '正文.md', '设定.md'])) throw new Error(JSON.stringify(first));
fs.writeFileSync(path.join(root, '正文.md'), '# 正文\n未受控改写。\n');
task.stage_execution = { stage_id: 'full_story_assembly', write_set: [] };
const second = audit.captureCanonicalBaseline(root, task);
if (second.status !== 'captured_incremental') throw new Error(JSON.stringify(second));
const result = audit.auditCanonicalWrites(root, task);
if (!result.unmanaged_paths.includes('正文.md')) throw new Error(JSON.stringify(result));
NODE
}

@test "long_write retains an earlier declared asset through an empty closure stage" {
    node - "$REPO" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const root = process.argv[3];
const relative = '大纲/第1卷.md';
const target = path.join(root, relative);
const task = {
  workflow_id: 'wf-long-write-stage-union',
  workflow_type: 'long_write',
  task_dir: '追踪/workflow/tasks/wf-long-write-stage-union',
  stage_execution: { stage_id: 'long_write', write_set: ['大纲/**'] },
};
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, '# 第1卷大纲\n初始。\n');

audit.captureCanonicalBaseline(root, task);
fs.writeFileSync(target, '# 第1卷大纲\n未受控改写。\n');
task.stage_execution = { stage_id: 'closure', write_set: [] };
const incremental = audit.captureCanonicalBaseline(root, task);
const result = audit.auditCanonicalWrites(root, task);

if (JSON.stringify(incremental.declared_write_set) !== JSON.stringify(['大纲/**'])) throw new Error(JSON.stringify(incremental));
if (result.status !== 'blocked_unreconciled_canonical_write') throw new Error(JSON.stringify(result));
if (!result.unmanaged_paths.includes(relative)) throw new Error(JSON.stringify(result));
if (JSON.stringify(result.declared_write_set) !== JSON.stringify(['大纲/**'])) throw new Error(JSON.stringify(result));
NODE
}

@test "receipt must be newer than this task baseline and belong to its workflow" {
    node - "$REPO" "$PROJECT" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const root = process.argv[3];
const task = {
  workflow_id: 'wf-receipt-owner',
  task_dir: '追踪/workflow/tasks/wf-receipt-owner',
  canonical_write_set: ['正文/**'],
};
const relative = '正文/第1卷/第001章.md';
const target = path.join(root, relative);
audit.captureCanonicalBaseline(root, task);
fs.writeFileSync(target, '# 第一章\n已写入。\n');
const afterHash = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex')}`;
const commits = path.join(root, '追踪/story-system/commits');
fs.mkdirSync(commits, { recursive: true });
const receipt = path.join(commits, 'chapter-v00000000-001-owner.json');
fs.writeFileSync(receipt, JSON.stringify({
  schemaVersion: '1.0.0', commit_id: 'chapter-v00000000-001-owner', status: 'accepted',
  workflow_id: 'wf-unrelated', accepted_at: '2000-01-01T00:00:00.000Z',
  artifacts: [{ target: relative, after_hash: afterHash }],
}));
const blocked = audit.auditCanonicalWrites(root, task);
if (blocked.status !== 'blocked_unreconciled_canonical_write' || blocked.receipt_retry.status !== 'receipt_pending' || !blocked.unmanaged_paths.includes(relative)) throw new Error(JSON.stringify(blocked));
fs.writeFileSync(receipt, JSON.stringify({
  schemaVersion: '1.0.0', commit_id: 'chapter-v00000000-001-owner', status: 'accepted',
  workflow_id: task.workflow_id, accepted_at: new Date(Date.now() + 1000).toISOString(),
  artifacts: [{ target: relative, after_hash: afterHash }],
}));
const accepted = audit.auditCanonicalWrites(root, task);
if (accepted.status !== 'ok' || !accepted.accepted_paths.includes(relative)) throw new Error(JSON.stringify(accepted));
NODE
}

@test "audit blocks are durable, actionable, and same result packet can converge after receipt appears" {
    node - "$REPO" "$STATE_MACHINE" "$PROJECT" <<'NODE'
const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const stateMachine = process.argv[3];
const root = process.argv[4];
const task = {
  workflow_id: 'wf-audit-recover', workflow_type: 'long_scan', result_contract_version: 1,
  task_dir: '追踪/workflow/tasks/wf-audit-recover', current_stage: 'closure', current_step: 'closure',
  status: 'running', state_version: 0,
  machine: { completed_stages: ['scan_preflight', 'source_lock', 'scan_execute', 'trend_validation', 'artifact_assembly'], remaining_stages: ['closure'] },
  canonical_write_set: ['正文/**'],
};
const taskFile = path.join(root, task.task_dir, 'task.json');
fs.mkdirSync(path.dirname(taskFile), { recursive: true });
fs.writeFileSync(taskFile, JSON.stringify(task, null, 2));
fs.mkdirSync(path.join(root, '追踪/workflow'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/workflow/current-task.json'), JSON.stringify({ workflow_id: task.workflow_id, task_dir: task.task_dir, state_version: 0 }));
audit.captureCanonicalBaseline(root, task);
const relative = '正文/第1卷/第001章.md';
const target = path.join(root, relative);
fs.writeFileSync(target, '# 第一章\n等待受控提交。\n');
const resultFile = path.join(root, 'result-recover.json');
fs.writeFileSync(resultFile, JSON.stringify({ workflow_id: task.workflow_id, workflow_type: task.workflow_type, stage_id: 'closure', step_id: 'closure', step_status: 'completed', verification_result: 'pass' }));
const first = childProcess.spawnSync(process.execPath, [stateMachine, 'apply-result', '--project-root', root, '--result', resultFile, '--no-private-registry', '--json'], { encoding: 'utf8' });
if (first.status !== 2 || !first.stdout.includes('blocked_unreconciled_canonical_write')) throw new Error(`${first.status}: ${first.stdout || first.stderr}`);
const blockedTask = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
if (blockedTask.status !== 'blocked' || !blockedTask.canonical_write_audit_block || !blockedTask.canonical_write_audit || !Array.isArray(blockedTask.pending_action.options)) throw new Error(JSON.stringify(blockedTask));
if (!blockedTask.pending_action.options.some(item => item.action_id === 'controlled_commit') || !blockedTask.pending_action.options.some(item => item.action_id === 'recheck_canonical_audit')) throw new Error(JSON.stringify(blockedTask.pending_action));
const afterHash = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(target)).digest('hex')}`;
const commits = path.join(root, '追踪/story-system/commits');
fs.mkdirSync(commits, { recursive: true });
fs.writeFileSync(path.join(commits, 'chapter-v00000000-001-recover.json'), JSON.stringify({
  schemaVersion: '1.0.0', commit_id: 'chapter-v00000000-001-recover', status: 'accepted', workflow_id: task.workflow_id,
  accepted_at: new Date(Date.now() + 1000).toISOString(), artifacts: [{ target: relative, after_hash: afterHash }],
}));
const second = childProcess.spawnSync(process.execPath, [stateMachine, 'apply-result', '--project-root', root, '--result', resultFile, '--no-private-registry', '--json'], { encoding: 'utf8' });
if (second.status !== 0 || !second.stdout.includes('"status": "advanced"')) throw new Error(`${second.status}: ${second.stdout || second.stderr}`);
const completed = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
if (completed.status !== 'completed' || completed.canonical_write_audit_block.status !== 'resolved') throw new Error(JSON.stringify(completed));
NODE
}

@test "audit task directory rejects symbolic links that escape the project" {
    node - "$REPO" "$PROJECT" "$TMP_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const root = process.argv[3];
const outside = path.join(process.argv[4], 'outside');
fs.mkdirSync(outside, { recursive: true });
fs.mkdirSync(path.join(root, '追踪/workflow/tasks'), { recursive: true });
fs.symlinkSync(outside, path.join(root, '追踪/workflow/tasks/wf-escape'));
try {
  audit.captureCanonicalBaseline(root, { workflow_id: 'wf-escape', task_dir: '追踪/workflow/tasks/wf-escape', canonical_write_set: ['正文/**'] });
  throw new Error('symlink escape was accepted');
} catch (error) {
  if (!/safe task_dir/.test(String(error.message))) throw error;
}
NODE
}

@test "state-machine closure audits declared canonical paths and leaves scan workflows unblocked" {
    node - "$REPO" "$STATE_MACHINE" "$PROJECT" <<'NODE'
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');
const audit = require(path.join(process.argv[2], 'scripts/lib/canonical-write-audit.js'));
const stateMachine = process.argv[3];
const root = process.argv[4];
const templates = JSON.parse(childProcess.execFileSync(process.execPath, [stateMachine, 'templates', '--no-private-registry', '--json'], { encoding: 'utf8' }));
const template = templates.templates.find((item) => item.workflow_type === 'long_write');
const finalStage = template.stages.at(-1);
const completed = template.stages.slice(0, -1).map((stage) => stage.stage_id);
const reviewResults = {};
for (const stage of template.stages) {
  if (completed.includes(stage.stage_id) && stage.review_requirement.required) {
    reviewResults[stage.stage_id] = { status: 'accepted', verification_result: 'pass', result_packet_path: 'fixture://accepted' };
  }
}
const task = {
  workflow_id: 'wf-audit-close',
  workflow_type: 'long_write',
  result_contract_version: 1,
  task_dir: '追踪/workflow/tasks/wf-audit-close',
  current_stage: finalStage.stage_id,
  current_step: finalStage.stage_id,
  status: 'running',
  state_version: 0,
  machine: { completed_stages: completed, remaining_stages: [finalStage.stage_id] },
  canonical_write_set: ['正文/**'],
  lifecycle_graph: {
    version: '1.0.0',
    current_node: finalStage.stage_id,
    asset_target: finalStage.asset_target,
    completed_nodes: completed,
    invalidated_nodes: [],
    review_results: reviewResults,
    nodes: template.stages.map((stage, order) => ({
      id: stage.stage_id,
      order,
      owner_module: stage.owner_module,
      asset_target: stage.asset_target,
      review_requirement: stage.review_requirement,
      status: completed.includes(stage.stage_id) ? 'accepted' : 'missing',
    })),
  },
};
const taskFile = path.join(root, task.task_dir, 'task.json');
fs.writeFileSync(taskFile, JSON.stringify(task, null, 2));
fs.mkdirSync(path.join(root, '追踪/workflow'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/workflow/current-task.json'), JSON.stringify({
  schemaVersion: '1.0.0', workflow_id: task.workflow_id, task_dir: task.task_dir, focused_at: new Date().toISOString(), state_version: 0,
}, null, 2));
audit.captureCanonicalBaseline(root, task);
const target = path.join(root, '正文/第1卷/第001章.md');
fs.writeFileSync(target, '# 第一章\n终态前的直接改写。\n');
const resultFile = path.join(root, 'result.json');
fs.writeFileSync(resultFile, JSON.stringify({
  workflow_id: task.workflow_id,
  workflow_type: task.workflow_type,
  stage_id: finalStage.stage_id,
  step_id: finalStage.stage_id,
  step_status: 'completed',
  verification_result: 'pass',
}));
const closed = childProcess.spawnSync(process.execPath, [stateMachine, 'apply-result', '--project-root', root, '--result', resultFile, '--json'], { encoding: 'utf8' });
if (closed.status !== 2 || !closed.stdout.includes('blocked_unreconciled_canonical_write')) {
  throw new Error(`${closed.status}: ${closed.stdout || closed.stderr}`);
}
if (!fs.readFileSync(target, 'utf8').includes('终态前的直接改写。')) throw new Error('state-machine reverted user prose');
if (!fs.existsSync(path.join(root, task.task_dir, 'write-audit.json'))) throw new Error('closure did not write audit');

const scanTask = { workflow_id: 'wf-scan', task_dir: '追踪/workflow/tasks/wf-scan', workflow_type: 'long_scan' };
audit.captureCanonicalBaseline(root, scanTask);
const scanResult = audit.auditCanonicalWrites(root, scanTask);
if (scanResult.status !== 'ok' || scanResult.unmanaged_paths.length !== 0) throw new Error(JSON.stringify(scanResult));
NODE
}
