#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  GATEWAY="$REPO/scripts/lib/workflow-v3/compatibility-gateway.js"
  FIXTURES="$REPO/tests/fixtures/workflow-v3/legacy-v2"
  TMP_DIR="$(mktemp -d)"
  PROJECT="$TMP_DIR/project"
  mkdir -p "$PROJECT"
}

teardown() {
  rm -rf "$TMP_DIR"
}

materialize_fixture() {
  local fixture="$1"
  local workflow_id="$2"
  local focused="${3:-yes}"
  node - "$PROJECT" "$FIXTURES/$fixture" "$workflow_id" "$focused" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, fixtureFile, workflowId, focused] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(fixtureFile, 'utf8'));
task.workflow_id = workflowId;
task.task_dir = `追踪/workflow/tasks/${workflowId}`;
task.stage_execution.stage_attempt_id = `sa-${workflowId}-${task.current_stage}-fixture`;
const taskFile = path.join(root, task.task_dir, 'task.json');
fs.mkdirSync(path.dirname(taskFile), { recursive: true });
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
if (focused === 'yes') {
  const pointerFile = path.join(root, '追踪/workflow/current-task.json');
  fs.mkdirSync(path.dirname(pointerFile), { recursive: true });
  fs.writeFileSync(pointerFile, `${JSON.stringify({
    schemaVersion: '1.0.0', workflow_id: workflowId,
    task_dir: task.task_dir, state_version: task.state_version,
    focused_at: '2026-01-01T00:00:00.000Z',
  }, null, 2)}\n`);
}
NODE
}

write_creative_assets() {
  mkdir -p "$PROJECT/正文" "$PROJECT/大纲" "$PROJECT/设定"
  printf '# 设定\n\n中性人物约束。\n' > "$PROJECT/设定.md"
  printf '# 小节大纲\n\n第1节：发现异常。\n' > "$PROJECT/小节大纲.md"
  printf '# 正文\n\n主角核对记录。\n' > "$PROJECT/正文/第001节.md"
  printf '# 总纲\n\n发现、核对、处理。\n' > "$PROJECT/大纲/总纲.md"
  printf '# 人物\n\n主角坚持复核。\n' > "$PROJECT/设定/人物.md"
}

task_file() {
  printf '%s/追踪/workflow/tasks/%s/task.json' "$PROJECT" "$1"
}

@test "real V2 durable stages map to the four exact V3 checkpoints" {
  run node - "$GATEWAY" "$FIXTURES" <<'NODE'
const fs = require('fs');
const path = require('path');
const gateway = require(process.argv[2]);
const fixtureDir = process.argv[3];
const cases = [
  ['planning-confirmed.json', 'section_brief'],
  ['current-section-brief-ready.json', 'section_draft'],
  ['current-section-gate-failed.json', 'section_repair'],
  ['final-section-accepted.json', 'assembly'],
];
for (const [name, target] of cases) {
  const task = JSON.parse(fs.readFileSync(path.join(fixtureDir, name), 'utf8'));
  const mapped = gateway.mapV2Checkpoint(task, {});
  if (mapped.exact !== true || mapped.target_stage !== target) throw new Error(`${name}: ${JSON.stringify(mapped)}`);
}
const ambiguous = gateway.mapV2Checkpoint({ workflow_type: 'short_write', current_stage: 'startup_scan' }, {});
if (ambiguous.exact !== false) throw new Error(JSON.stringify(ambiguous));
const pendingMenu = gateway.mapV2Checkpoint({
  workflow_type: 'short_write', current_stage: 'next_section_brief',
  pending_action: { question: '等待作者确认' },
}, {});
if (pendingMenu.exact !== true || pendingMenu.target_stage !== 'section_brief'
    || pendingMenu.pending_action_policy !== 'archive_and_resume_stage') {
  throw new Error(JSON.stringify(pendingMenu));
}
const unresolved = gateway.mapV2Checkpoint({
  workflow_type: 'short_write', current_stage: 'next_section_brief',
  pending_action: { question: '旧菜单仍在' },
  pending_feedback: { messages: [{ raw_text: '保留作者原话' }] },
}, {});
if (unresolved.exact !== false || unresolved.reason !== 'unresolved_author_feedback') throw new Error(JSON.stringify(unresolved));
NODE
  [ "$status" -eq 0 ]
}

@test "confirmed migration archives a pending V2 menu but never loses pending author feedback" {
  materialize_fixture planning-confirmed.json wf-pending-menu
  write_creative_assets
  node - "$(task_file wf-pending-menu)" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8'));
task.current_stage = 'next_section_brief';
task.current_step = 'next_section_brief';
task.stage_execution.stage_id = 'next_section_brief';
task.pending_action = {
  id: 'pa-neutral-menu',
  question: '当前写作提要需要作者决定收敛方式',
  options: [{ number: 1, action_id: 'retry_current_brief', label: '保留核心因果' }],
};
task.short_section_projection = { current_section_index: 9, applied: true };
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE

  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, gatewayFile] = process.argv.slice(2);
const gateway = require(gatewayFile);
const plan = gateway.buildMigrationPlan(root, 'wf-pending-menu');
if (plan.pending_action_policy !== 'archive_and_resume_stage') throw new Error(JSON.stringify(plan));
const result = gateway.applyMigration(root, plan.plan_digest);
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks/wf-pending-menu/task.json'), 'utf8'));
const archive = JSON.parse(fs.readFileSync(path.join(root, result.archive_path), 'utf8'));
if (Object.prototype.hasOwnProperty.call(task, 'pending_action')) throw new Error('stale menu survived migration');
if (Object.prototype.hasOwnProperty.call(task, 'short_section_projection')) throw new Error('stale section projection survived migration');
if (task.migration.pending_action_policy !== 'archive_and_resume_stage') throw new Error(JSON.stringify(task.migration));
if (!archive.source_task.pending_action || archive.source_task.pending_action.id !== 'pa-neutral-menu') {
  throw new Error('pending menu was not recoverably archived');
}
if (archive.rollback.pending_action_policy !== 'archive_and_resume_stage') throw new Error(JSON.stringify(archive.rollback));
NODE
  [ "$status" -eq 0 ]

  materialize_fixture planning-confirmed.json wf-pending-feedback no
  node - "$(task_file wf-pending-feedback)" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8'));
task.pending_feedback = { messages: [{ raw_text: '必须保留的作者反馈' }] };
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE
  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const gateway = require(process.argv[3]);
gateway.buildMigrationPlan(process.argv[2], 'wf-pending-feedback');
NODE
  [ "$status" -ne 0 ]
  [[ "$output" == *'unresolved_author_feedback'* ]]
}

@test "compatibility inspection uses status and durable authority" {
  materialize_fixture planning-confirmed.json wf-inspect
  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, gatewayFile] = process.argv.slice(2);
const gateway = require(gatewayFile);
let out = gateway.inspectCompatibility(root);
if (out.status !== 'safe_auto_upgrade' || out.target_stage !== 'section_brief') throw new Error(JSON.stringify(out));
const taskFile = path.join(root, '追踪/workflow/tasks/wf-inspect/task.json');
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.engine_version = 3; task.task_schema_version = 3; task.workflow_contract_version = 3;
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
out = gateway.inspectCompatibility(root);
if (out.status !== 'current') throw new Error(JSON.stringify(out));
delete task.engine_version; delete task.task_schema_version;
task.current_stage = 'startup_scan'; task.stage_execution.stage_id = 'startup_scan';
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
out = gateway.inspectCompatibility(root);
if (out.status !== 'preview_required') throw new Error(JSON.stringify(out));
task.workflow_type = 'long_write';
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
out = gateway.inspectCompatibility(root);
if (out.status !== 'unsupported') throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ]
}

@test "migration preview persists a digest-bound plan and protects real short-project layouts" {
  materialize_fixture planning-confirmed.json wf-plan
  write_creative_assets
  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, gatewayFile] = process.argv.slice(2);
const gateway = require(gatewayFile);
const first = gateway.buildMigrationPlan(root, 'wf-plan');
const second = gateway.buildMigrationPlan(root, 'wf-plan');
if (first.plan_digest !== second.plan_digest) throw new Error('plan is not deterministic');
for (const rel of ['设定.md', '小节大纲.md', '正文/第001节.md', '大纲/总纲.md', '设定/人物.md']) {
  if (!first.protected_assets[rel]) throw new Error(`unprotected asset: ${rel}`);
}
if (!first.plan_path || !fs.existsSync(path.join(root, first.plan_path))) throw new Error('durable preview missing');
const stored = JSON.parse(fs.readFileSync(path.join(root, first.plan_path), 'utf8'));
if (stored.plan_digest !== first.plan_digest || stored.workflow_id !== 'wf-plan') throw new Error('stored plan mismatch');
NODE
  [ "$status" -eq 0 ]
}

@test "a digest can migrate a non-focused workflow in a separate process" {
  materialize_fixture planning-confirmed.json wf-target no
  materialize_fixture current-section-gate-failed.json wf-focus yes
  write_creative_assets
  node - "$PROJECT" "$GATEWAY" "$TMP_DIR/digest" <<'NODE'
const fs = require('fs'); const gateway = require(process.argv[3]);
fs.writeFileSync(process.argv[4], gateway.buildMigrationPlan(process.argv[2], 'wf-target').plan_digest);
NODE
  run node - "$PROJECT" "$GATEWAY" "$TMP_DIR/digest" <<'NODE'
const fs = require('fs');
const path = require('path');
const gateway = require(process.argv[3]);
const root = process.argv[2];
const result = gateway.applyMigration(root, fs.readFileSync(process.argv[4], 'utf8'));
const target = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks/wf-target/task.json'), 'utf8'));
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
if (!result.migrated || target.current_stage !== 'section_brief' || target.engine_version !== 3) throw new Error(JSON.stringify(result));
if (pointer.workflow_id !== 'wf-focus') throw new Error('non-focused migration stole focus');
NODE
  [ "$status" -eq 0 ]
}

@test "all four checkpoints migrate exactly once and preserve creative bytes" {
  run node - "$TMP_DIR" "$GATEWAY" "$FIXTURES" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [base, gatewayFile, fixtureDir] = process.argv.slice(2);
const gateway = require(gatewayFile);
const cases = [
  ['planning-confirmed.json', 'section_brief'],
  ['current-section-brief-ready.json', 'section_draft'],
  ['current-section-gate-failed.json', 'section_repair'],
  ['final-section-accepted.json', 'assembly'],
];
for (const [name, target] of cases) {
  const root = path.join(base, name.replace('.json', ''));
  const workflowId = `wf-${name.replace(/[^a-z]/g, '-')}`;
  const task = JSON.parse(fs.readFileSync(path.join(fixtureDir, name), 'utf8'));
  task.workflow_id = workflowId; task.task_dir = `追踪/workflow/tasks/${workflowId}`;
  task.stage_execution.stage_attempt_id = `sa-${workflowId}-source`;
  const taskFile = path.join(root, task.task_dir, 'task.json');
  fs.mkdirSync(path.dirname(taskFile), { recursive: true });
  fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
  fs.mkdirSync(path.join(root, '正文'), { recursive: true });
  const prose = path.join(root, '正文/第001节.md');
  fs.writeFileSync(prose, '# 正文\n\n中性测试文本。\n');
  const before = crypto.createHash('sha256').update(fs.readFileSync(prose)).digest('hex');
  const plan = gateway.buildMigrationPlan(root, workflowId);
  const first = gateway.applyMigration(root, plan.plan_digest);
  const migrated = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
  const replay = gateway.applyMigration(root, plan.plan_digest);
  const afterReplay = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
  const after = crypto.createHash('sha256').update(fs.readFileSync(prose)).digest('hex');
  if (!first.migrated || migrated.current_stage !== target || migrated.state_version !== task.state_version + 1) throw new Error(name);
  if (![migrated.engine_version, migrated.task_schema_version, migrated.workflow_contract_version].every(v => v === 3)) throw new Error(name);
  if (name === 'planning-confirmed.json') {
    const staleRuntimeFields = [
      'machine', 'unit_lifecycle', 'runtime_guard', 'recommended_next',
      'last_selection', 'navigation', 'next_stop_reason',
      'stage_attempt_history', 'pending_action', 'pending_feedback',
      'short_section_projection',
    ];
    for (const field of staleRuntimeFields) {
      if (Object.prototype.hasOwnProperty.call(migrated, field)) {
        throw new Error(`legacy runtime projection survived: ${field}`);
      }
    }
  }
  if (!replay.idempotent || afterReplay.state_version !== migrated.state_version || before !== after) throw new Error(name);
}
NODE
  [ "$status" -eq 0 ]
}

@test "archive can restore the exact source bytes and migration uses task authority" {
  materialize_fixture planning-confirmed.json wf-archive
  write_creative_assets
  cp "$(task_file wf-archive)" "$TMP_DIR/source-task"
  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const gateway = require(process.argv[3]);
const plan = gateway.buildMigrationPlan(process.argv[2], 'wf-archive');
gateway.applyMigration(process.argv[2], plan.plan_digest);
NODE
  [ "$status" -eq 0 ]
  run node - "$PROJECT" "$TMP_DIR/source-task" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, sourceFile] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks/wf-archive/task.json'), 'utf8'));
const archive = JSON.parse(fs.readFileSync(path.join(root, task.migration.archive_path), 'utf8'));
const restored = Buffer.from(archive.source_task_bytes_base64, 'base64');
if (!restored.equals(fs.readFileSync(sourceFile))) throw new Error('archive cannot restore exact source bytes');
if (archive.rollback.workflow_id !== 'wf-archive' || archive.rollback.source_task_digest !== task.migration.source_task_digest) throw new Error('rollback metadata incomplete');
NODE
  [ "$status" -eq 0 ]
  grep -q "mutateTaskAuthority" "$GATEWAY"
  ! grep -q "writeFileSync(durable.taskFile" "$GATEWAY"
}

@test "a stale task plan fails before migration writes" {
  materialize_fixture planning-confirmed.json wf-stale
  write_creative_assets
  node - "$PROJECT" "$GATEWAY" "$TMP_DIR/digest" <<'NODE'
const fs = require('fs'); const gateway = require(process.argv[3]);
fs.writeFileSync(process.argv[4], gateway.buildMigrationPlan(process.argv[2], 'wf-stale').plan_digest);
NODE
  node - "$(task_file wf-stale)" <<'NODE'
const fs = require('fs'); const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8')); task.user_goal = '中性的新目标';
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE
  cp "$(task_file wf-stale)" "$TMP_DIR/expected-task"
  run node - "$PROJECT" "$GATEWAY" "$TMP_DIR/digest" <<'NODE'
const fs = require('fs'); const gateway = require(process.argv[3]);
gateway.applyMigration(process.argv[2], fs.readFileSync(process.argv[4], 'utf8'));
NODE
  [ "$status" -ne 0 ]
  cmp -s "$(task_file wf-stale)" "$TMP_DIR/expected-task"
  [ ! -e "$PROJECT/追踪/workflow/archived/wf-stale.pre-v3.json" ]
}

@test "a protected creative change fails before task or archive writes" {
  materialize_fixture planning-confirmed.json wf-asset
  write_creative_assets
  node - "$PROJECT" "$GATEWAY" "$TMP_DIR/digest" <<'NODE'
const fs = require('fs'); const gateway = require(process.argv[3]);
fs.writeFileSync(process.argv[4], gateway.buildMigrationPlan(process.argv[2], 'wf-asset').plan_digest);
NODE
  printf '\n外部变更。\n' >> "$PROJECT/正文/第001节.md"
  cp "$(task_file wf-asset)" "$TMP_DIR/expected-task"
  run node - "$PROJECT" "$GATEWAY" "$TMP_DIR/digest" <<'NODE'
const fs = require('fs'); const gateway = require(process.argv[3]);
gateway.applyMigration(process.argv[2], fs.readFileSync(process.argv[4], 'utf8'));
NODE
  [ "$status" -ne 0 ]
  cmp -s "$(task_file wf-asset)" "$TMP_DIR/expected-task"
  [ ! -e "$PROJECT/追踪/workflow/archived/wf-asset.pre-v3.json" ]
}

@test "unsafe task directories and forged digests are rejected" {
  materialize_fixture planning-confirmed.json wf-unsafe
  write_creative_assets
  node - "$(task_file wf-unsafe)" <<'NODE'
const fs = require('fs'); const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8')); task.task_dir = '../escape';
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE
  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const gateway = require(process.argv[3]); gateway.buildMigrationPlan(process.argv[2], 'wf-unsafe');
NODE
  [ "$status" -ne 0 ]
  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const gateway = require(process.argv[3]); gateway.applyMigration(process.argv[2], 'sha256:forged');
NODE
  [ "$status" -ne 0 ]
}
