#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  GATEWAY="$REPO/scripts/lib/workflow-v3/compatibility-gateway.js"
  STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
  FIXTURE="$REPO/tests/fixtures/workflow-v3/legacy-v2/planning-confirmed.json"
  TMP_DIR="$(mktemp -d)"
  PROJECT="$TMP_DIR/project"
  mkdir -p "$PROJECT/正文"
  printf '# 正文\n\n中性测试文本。\n' > "$PROJECT/正文/第001节.md"
}

teardown() {
  rm -rf "$TMP_DIR"
}

materialize_v2_task() {
  local workflow_id="$1"
  node - "$PROJECT" "$FIXTURE" "$workflow_id" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, fixtureFile, workflowId] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(fixtureFile, 'utf8'));
task.workflow_id = workflowId;
task.task_dir = `追踪/workflow/tasks/${workflowId}`;
task.stage_execution.stage_attempt_id = `sa-${workflowId}-fixture`;
const taskFile = path.join(root, task.task_dir, 'task.json');
fs.mkdirSync(path.dirname(taskFile), { recursive: true });
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
const pointerFile = path.join(root, '追踪/workflow/current-task.json');
fs.mkdirSync(path.dirname(pointerFile), { recursive: true });
fs.writeFileSync(pointerFile, `${JSON.stringify({
  schemaVersion: '1.0.0',
  workflow_id: workflowId,
  task_dir: task.task_dir,
  state_version: task.state_version,
  focused_at: '2026-01-01T00:00:00.000Z',
}, null, 2)}\n`);
NODE
}

task_file() {
  printf '%s/追踪/workflow/tasks/%s/task.json' "$PROJECT" "$1"
}

@test "the legacy state-machine migration command returns the gateway plan digest" {
  materialize_v2_task wf-preview

  node - "$PROJECT" "$GATEWAY" "$TMP_DIR/expected" <<'NODE'
const fs = require('fs');
const gateway = require(process.argv[3]);
fs.writeFileSync(process.argv[4], gateway.buildMigrationPlan(process.argv[2], 'wf-preview').plan_digest);
NODE

  run node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id wf-preview --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/actual.json"
  node - "$TMP_DIR/actual.json" "$TMP_DIR/expected" <<'NODE'
const fs = require('fs');
const actual = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const expected = fs.readFileSync(process.argv[3], 'utf8');
if (actual.status !== 'v3_migration_preview' || actual.plan_digest !== expected) {
  throw new Error(JSON.stringify(actual));
}
NODE
}

@test "the legacy state-machine migration command applies through the gateway" {
  materialize_v2_task wf-apply

  run node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id wf-apply --confirm --json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/result.json"
  node - "$TMP_DIR/result.json" "$(task_file wf-apply)" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (result.status !== 'v3_migration_applied' || !result.migrated) throw new Error(JSON.stringify(result));
if (task.engine_version !== 3 || task.current_stage !== 'section_brief') throw new Error(JSON.stringify(task));
NODE
}

@test "an ambiguous V2 checkpoint rejects preview and apply without changing the task" {
  materialize_v2_task wf-ambiguous
  node - "$(task_file wf-ambiguous)" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8'));
task.current_stage = 'section_machine_gate';
task.current_step = 'section_machine_gate';
task.stage_execution.stage_id = 'section_machine_gate';
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE
  cp "$(task_file wf-ambiguous)" "$TMP_DIR/ambiguous-before.json"

  run node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id wf-ambiguous --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'blocked_v3_migration_unavailable'* ]]
  cmp -s "$(task_file wf-ambiguous)" "$TMP_DIR/ambiguous-before.json"

  run node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id wf-ambiguous --confirm --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'blocked_v3_migration_unavailable'* ]]
  cmp -s "$(task_file wf-ambiguous)" "$TMP_DIR/ambiguous-before.json"
}

@test "the legacy migration command is idempotently current after V3 migration" {
  materialize_v2_task wf-current
  node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id wf-current --confirm --json > "$TMP_DIR/migrated.json"

  run node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id wf-current --json

  [ "$status" -eq 0 ]
  [[ "$output" == *'v3_migration_current'* ]]
}

@test "the compatibility gateway rejects a non-short task without changing it" {
  node "$STATE_MACHINE" create --workflow-type long_write \
    --project-root "$PROJECT" --user-goal "中性长篇" --no-private-registry --json > "$TMP_DIR/long.json"
  local workflow_id
  workflow_id="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).task.workflow_id)" "$TMP_DIR/long.json")"
  cp "$(task_file "$workflow_id")" "$TMP_DIR/long-before.json"

  run node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id "$workflow_id" --json

  [ "$status" -eq 2 ]
  [[ "$output" == *'blocked_v3_migration_unavailable'* ]]
  cmp -s "$(task_file "$workflow_id")" "$TMP_DIR/long-before.json"
}

@test "a V3 task rejects V2 apply-result before any durable write" {
  materialize_v2_task wf-v3-freeze
  node "$STATE_MACHINE" migrate-short-lean-workflow \
    --project-root "$PROJECT" --workflow-id wf-v3-freeze --confirm --json > "$TMP_DIR/migrated.json"
  cp "$(task_file wf-v3-freeze)" "$TMP_DIR/expected-task.json"
  printf '%s\n' '{"kind":"completed","stage_id":"section_brief"}' > "$TMP_DIR/result.json"

  run node "$STATE_MACHINE" apply-result --project-root "$PROJECT" \
    --workflow-id wf-v3-freeze --result "$TMP_DIR/result.json" --json

  [ "$status" -eq 2 ]
  [[ "$output" == *'blocked_v3_task_requires_v3_engine'* ]]
  cmp -s "$(task_file wf-v3-freeze)" "$TMP_DIR/expected-task.json"
}

@test "an unmigrated V2 short task is read-only and must migrate before resolve-action" {
  materialize_v2_task wf-v2-freeze
  cp "$(task_file wf-v2-freeze)" "$TMP_DIR/expected-task.json"

  run node "$STATE_MACHINE" resolve-action \
    --project-root "$PROJECT" --input 1 --bind-current --json

  [ "$status" -eq 2 ]
  [[ "$output" == *'blocked_v2_short_task_migration_required'* ]]
  cmp -s "$(task_file wf-v2-freeze)" "$TMP_DIR/expected-task.json"
}

@test "direct V2 short creation is frozen while non-short creation remains available" {
  run node "$STATE_MACHINE" create --workflow-type short_write \
    --project-root "$PROJECT" --user-goal "中性短篇" --no-private-registry --json
  [ "$status" -eq 2 ]
  [[ "$output" == *'blocked_v2_short_write_frozen'* ]]
  [ ! -e "$PROJECT/追踪/workflow/current-task.json" ]

  run node "$STATE_MACHINE" create --workflow-type long_write \
    --project-root "$PROJECT" --user-goal "中性长篇" --no-private-registry --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "created"'* ]]
}

@test "legacy migration facades import the single compatibility gateway" {
  grep -q "compatibility-gateway" "$REPO/scripts/legacy-short-project-migrate.js"
  grep -q "compatibility-gateway" "$REPO/scripts/short-state-storage-migrate.js"
  ! grep -q "function inspectLegacyShort" "$REPO/scripts/legacy-short-project-migrate.js"
  ! grep -q "function mapAsset" "$REPO/scripts/legacy-short-project-migrate.js"
}

@test "the compatibility gateway detects an asset-only legacy short project" {
  mkdir -p "$PROJECT/大纲"
  printf '# 设定\n\n中性人物。\n' > "$PROJECT/设定.md"
  printf '# 小节大纲\n## 第1节：开场\n' > "$PROJECT/大纲/小节大纲.md"
  printf '# 完整正文\n\n中性旧稿。\n' > "$PROJECT/正文/正文.md"

  run node - "$PROJECT" "$GATEWAY" <<'NODE'
const gateway = require(process.argv[3]);
const result = gateway.inspectCompatibility(process.argv[2]);
if (result.status !== 'preview_required'
    || result.compatibility_kind !== 'legacy_short_project'
    || result.reason !== 'legacy_project_import_required') {
  throw new Error(JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ]
}
