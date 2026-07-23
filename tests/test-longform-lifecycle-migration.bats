#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  MIGRATE="$REPO/scripts/workflow-legacy-migrate.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK"
}

teardown() {
  rm -rf "$TMP_DIR"
}

write_supported_legacy_long_write() {
  mkdir -p "$BOOK/大纲" "$BOOK/设定" "$BOOK/正文" "$BOOK/追踪/workflow/tasks/wf-legacy-long-write"
  printf '# 定位\n' > "$BOOK/设定/定位.md"
  printf '# 世界观\n' > "$BOOK/设定/世界观.md"
  printf '# 总纲\n' > "$BOOK/大纲/总纲.md"
  printf '# 第一章\n\n这是既有正文，不应被迁移改写。\n' > "$BOOK/正文/第001章.md"
  cat > "$BOOK/.story-deployed" <<'JSON'
{"source_repository":"worldwonderer/oh-story-claudecode"}
JSON
  cat > "$BOOK/追踪/workflow/tasks/wf-legacy-long-write/task.json" <<'JSON'
{
  "workflow_id": "wf-legacy-long-write",
  "workflow_type": "long_write",
  "status": "running",
  "task_dir": "追踪/workflow/tasks/wf-legacy-long-write",
  "scope": "第1-50章",
  "legacy_chapter_batch_size": 50,
  "migration_source": "worldwonderer/oh-story-claudecode"
}
JSON
  cp "$BOOK/追踪/workflow/tasks/wf-legacy-long-write/task.json" "$BOOK/追踪/workflow/current-task.json"
}

@test "supported legacy long_write previews and writes only lifecycle metadata with a historical snapshot" {
  write_supported_legacy_long_write
  creative_before="$(find "$BOOK/设定" "$BOOK/大纲" "$BOOK/正文" -type f -exec shasum -a 256 {} \; | sort)"
  task_before="$(shasum -a 256 "$BOOK/追踪/workflow/current-task.json" "$BOOK/追踪/workflow/tasks/wf-legacy-long-write/task.json")"

  node "$MIGRATE" --project-root "$BOOK" --source oh-story --json > "$TMP_DIR/preview.json"

  node - "$TMP_DIR/preview.json" <<'NODE'
const out = require(process.argv[2]);
for (const key of ['source', 'detected_assets', 'inferred_maturity', 'proposed_lifecycle_node', 'unresolved_conflicts', 'creative_files_changed']) {
  if (!(key in out)) throw new Error(`missing ${key}: ${JSON.stringify(out)}`);
}
if (out.source !== 'worldwonderer/oh-story-claudecode') throw new Error(out.source);
if (out.creative_files_changed !== false) throw new Error(JSON.stringify(out));
if (!out.detected_assets.some(asset => asset.id === 'master_outline' && asset.source_path === '大纲/总纲.md')) throw new Error(JSON.stringify(out.detected_assets));
if (out.inferred_maturity !== 'needs_review' || out.proposed_lifecycle_node !== 'master_outline_review') throw new Error(JSON.stringify(out));
if (out.status !== 'migration_preview') throw new Error(out.status);
NODE
  [ "$creative_before" = "$(find "$BOOK/设定" "$BOOK/大纲" "$BOOK/正文" -type f -exec shasum -a 256 {} \; | sort)" ]
  [ "$task_before" = "$(shasum -a 256 "$BOOK/追踪/workflow/current-task.json" "$BOOK/追踪/workflow/tasks/wf-legacy-long-write/task.json")" ]
  [ ! -e "$BOOK/追踪/workflow/longform-lifecycle.json" ]

  node "$REPO/scripts/workflow-state-machine.js" next-candidates --project-root "$BOOK" --json > "$TMP_DIR/legacy-menu.json"
  node - "$TMP_DIR/legacy-menu.json" <<'NODE'
const out = require(process.argv[2]);
if (out.status !== 'blocked_longform_lifecycle_migration_required') throw new Error(JSON.stringify(out));
if (!Array.isArray(out.options) || out.options.length !== 4 || !out.text.includes('1. 迁移旧协议')) throw new Error(JSON.stringify(out));
NODE
  node "$REPO/scripts/workflow-state-machine.js" resolve-action --project-root "$BOOK" --input 1 --json > "$TMP_DIR/legacy-choice.json"
  node - "$TMP_DIR/legacy-choice.json" <<'NODE'
const out = require(process.argv[2]);
if (out.status !== 'legacy_longform_migration_selected') throw new Error(JSON.stringify(out));
if (!String(out.execution_command || '').includes('workflow-legacy-migrate.js') || !out.completion_required_before_reply) throw new Error(JSON.stringify(out));
NODE

  node "$MIGRATE" --project-root "$BOOK" --source oh-story --write --workflow-id wf-legacy-long-write --json > "$TMP_DIR/applied.json"

  node - "$TMP_DIR/applied.json" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const [outFile, root] = process.argv.slice(2);
const out = require(outFile);
if (out.status !== 'lifecycle_migration_applied' || out.creative_files_changed !== false) throw new Error(JSON.stringify(out));
if (!out.successor_workflow_id || out.restart_lifecycle_node !== 'positioning') throw new Error(JSON.stringify(out));
const index = require(path.join(root, '追踪/workflow/longform-lifecycle.json'));
if (!index.assets || index.assets.master_outline !== 'needs_review') throw new Error(JSON.stringify(index));
if (JSON.stringify(index).includes('50')) throw new Error('legacy fixed batch leaked into lifecycle metadata');
const snapshot = path.join(root, '追踪/workflow/archived/wf-legacy-long-write.lifecycle-migration-snapshot.json');
if (!fs.existsSync(snapshot) || !require(snapshot).legacy_task) throw new Error('historical snapshot missing');
const pointer = require(path.join(root, '追踪/workflow/current-task.json'));
const successor = require(path.join(root, pointer.task_dir, 'task.json'));
const predecessor = require(path.join(root, '追踪/workflow/tasks/wf-legacy-long-write/task.json'));
if (pointer.workflow_id !== out.successor_workflow_id || successor.workflow_id !== pointer.workflow_id) throw new Error('focus did not move to the successor');
if (!successor.lifecycle_graph || successor.current_stage !== 'positioning') throw new Error('successor did not restart from the earliest untrusted node');
if (successor.lifecycle.previous_workflow_id !== 'wf-legacy-long-write') throw new Error('successor lineage missing');
if (predecessor.lifecycle.status !== 'superseded' || predecessor.lifecycle.superseded_by !== successor.workflow_id) throw new Error('predecessor was not preserved as superseded history');
if (!out.visible_response || !Array.isArray(out.visible_response.options) || out.visible_response.options.length < 1) throw new Error('successor menu missing');
NODE
  [ "$creative_before" = "$(find "$BOOK/设定" "$BOOK/大纲" "$BOOK/正文" -type f -exec shasum -a 256 {} \; | sort)" ]
}

@test "unknown long_write provenance remains preview-only and cannot create a lifecycle index" {
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-unknown"
  cat > "$BOOK/追踪/workflow/tasks/wf-unknown/task.json" <<'JSON'
{"workflow_id":"wf-unknown","workflow_type":"long_write","status":"running","task_dir":"追踪/workflow/tasks/wf-unknown"}
JSON
  cp "$BOOK/追踪/workflow/tasks/wf-unknown/task.json" "$BOOK/追踪/workflow/current-task.json"

  status=0
  node "$MIGRATE" --project-root "$BOOK" --source oh-story --write --workflow-id wf-unknown --json > "$TMP_DIR/blocked.json" || status=$?

  [ "$status" -eq 2 ]
  grep -q '"status": "blocked_lifecycle_migration_source_unknown"' "$TMP_DIR/blocked.json"
  [ ! -e "$BOOK/追踪/workflow/longform-lifecycle.json" ]
  [ ! -e "$BOOK/追踪/workflow/archived/wf-unknown.lifecycle-migration-snapshot.json" ]
}

@test "unsafe workflow_id is blocked before it can become a snapshot path" {
  mkdir -p "$BOOK/正文" "$BOOK/追踪/workflow"
  printf '# 第一章\n\n正文不能被迁移改写。\n' > "$BOOK/正文/第001章.md"
  cat > "$BOOK/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id":"../escape",
  "workflow_type":"long_write",
  "status":"running",
  "migration_source":"worldwonderer/oh-story-claudecode"
}
JSON
  prose_before="$(shasum -a 256 "$BOOK/正文/第001章.md")"

  node "$MIGRATE" --project-root "$BOOK" --source oh-story --json > "$TMP_DIR/unsafe-preview.json"

  node - "$TMP_DIR/unsafe-preview.json" <<'NODE'
const out = require(process.argv[2]);
const item = out.migration_inventory.items.find(candidate => candidate.workflow_id === '../escape');
if (!item || item.classification !== 'blocked') throw new Error(JSON.stringify(out));
if (item.rollback_snapshot) throw new Error(`unsafe rollback path: ${item.rollback_snapshot}`);
NODE

  status=0
  node "$MIGRATE" --project-root "$BOOK" --source oh-story --write --workflow-id ../escape --json > "$TMP_DIR/unsafe-write.json" || status=$?

  [ "$status" -eq 2 ]
  grep -q '"status": "blocked_migration_selection_invalid"' "$TMP_DIR/unsafe-write.json"
  [ ! -e "$BOOK/追踪/workflow/longform-lifecycle.json" ]
  [ ! -e "$BOOK/追踪/workflow/escape.lifecycle-migration-snapshot.json" ]
  [ "$prose_before" = "$(shasum -a 256 "$BOOK/正文/第001章.md")" ]
}

@test "lifecycle migration library rejects unsafe workflow_id at the write boundary" {
  mkdir -p "$BOOK/正文" "$BOOK/追踪/workflow"
  printf '# 第一章\n\n库调用也不能改正文。\n' > "$BOOK/正文/第001章.md"
  cat > "$BOOK/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id":"../library-escape",
  "workflow_type":"long_write",
  "status":"running",
  "migration_source":"worldwonderer/oh-story-claudecode"
}
JSON
  prose_before="$(shasum -a 256 "$BOOK/正文/第001章.md")"

  node - "$REPO" "$BOOK" <<'NODE'
const path = require('path');
const [repo, root] = process.argv.slice(2);
const migration = require(path.join(repo, 'scripts/lib/workflow-legacy-migration'));
const scan = migration.scanWorkflowMigrations(root);
try {
  migration.applyLifecycleIndexMigration(root, scan.records[0]);
  throw new Error('unsafe workflow_id unexpectedly migrated');
} catch (error) {
  if (error.code !== 'LIFECYCLE_MIGRATION_WORKFLOW_ID_INVALID') throw error;
}
NODE

  [ ! -e "$BOOK/追踪/workflow/longform-lifecycle.json" ]
  [ ! -e "$BOOK/追踪/workflow/library-escape.lifecycle-migration-snapshot.json" ]
  [ "$prose_before" = "$(shasum -a 256 "$BOOK/正文/第001章.md")" ]
}

@test "write requires an explicit workflow_id even when the lifecycle candidate is unique" {
  write_supported_legacy_long_write
  prose_before="$(shasum -a 256 "$BOOK/正文/第001章.md")"

  status=0
  node "$MIGRATE" --project-root "$BOOK" --source oh-story --write --json > "$TMP_DIR/missing-workflow-id.json" || status=$?

  [ "$status" -eq 2 ]
  grep -q '"status": "blocked_migration_confirmation_required"' "$TMP_DIR/missing-workflow-id.json"
  grep -q 'workflow_id' "$TMP_DIR/missing-workflow-id.json"
  [ ! -e "$BOOK/追踪/workflow/longform-lifecycle.json" ]
  [ ! -e "$BOOK/追踪/workflow/archived/wf-legacy-long-write.lifecycle-migration-snapshot.json" ]
  [ "$prose_before" = "$(shasum -a 256 "$BOOK/正文/第001章.md")" ]
}

@test "an arbitrary bundle id alone is not trusted migration provenance" {
  mkdir -p "$BOOK/正文" "$BOOK/追踪/workflow/tasks/wf-untrusted-bundle"
  printf '# 第一章\n\n来源不可信时也不能改正文。\n' > "$BOOK/正文/第001章.md"
  printf '%s\n' '{"novel_assistant_bundle_id":"attacker-controlled"}' > "$BOOK/.story-deployed"
  cat > "$BOOK/追踪/workflow/tasks/wf-untrusted-bundle/task.json" <<'JSON'
{
  "workflow_id":"wf-untrusted-bundle",
  "workflow_type":"long_write",
  "status":"running",
  "task_dir":"追踪/workflow/tasks/wf-untrusted-bundle"
}
JSON
  cp "$BOOK/追踪/workflow/tasks/wf-untrusted-bundle/task.json" "$BOOK/追踪/workflow/current-task.json"
  prose_before="$(shasum -a 256 "$BOOK/正文/第001章.md")"

  status=0
  node "$MIGRATE" --project-root "$BOOK" --source novel-assistant-previous --write --workflow-id wf-untrusted-bundle --json > "$TMP_DIR/untrusted-bundle.json" || status=$?

  [ "$status" -eq 2 ]
  grep -q '"status": "blocked_lifecycle_migration_source_unknown"' "$TMP_DIR/untrusted-bundle.json"
  [ ! -e "$BOOK/追踪/workflow/longform-lifecycle.json" ]
  [ ! -e "$BOOK/追踪/workflow/archived/wf-untrusted-bundle.lifecycle-migration-snapshot.json" ]
  [ "$prose_before" = "$(shasum -a 256 "$BOOK/正文/第001章.md")" ]
}

@test "forged story-deployed provenance never enables lifecycle migration" {
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-forged-marker"
  cat > "$BOOK/.story-deployed" <<'JSON'
{"source_repository":"worldwonderer/oh-story-claudecode","novel_assistant_bundle_name":"novel-assistant","novel_assistant_bundle_id":"bundle-4f272998c19b"}
JSON
  cat > "$BOOK/追踪/workflow/tasks/wf-forged-marker/task.json" <<'JSON'
{
  "workflow_id":"wf-forged-marker",
  "workflow_type":"long_write",
  "status":"running",
  "task_dir":"追踪/workflow/tasks/wf-forged-marker",
  "migration_source":"worldwonderer/oh-story-claudecode"
}
JSON
  cp "$BOOK/追踪/workflow/tasks/wf-forged-marker/task.json" "$BOOK/追踪/workflow/current-task.json"

  status=0
  node "$MIGRATE" --project-root "$BOOK" --source oh-story --write --workflow-id wf-forged-marker --json > "$TMP_DIR/forged-marker.json" || status=$?

  [ "$status" -eq 2 ]
  grep -q '"status": "blocked_lifecycle_migration_source_unknown"' "$TMP_DIR/forged-marker.json"
  [ ! -e "$BOOK/追踪/workflow/longform-lifecycle.json" ]
  [ ! -e "$BOOK/追踪/workflow/archived/wf-forged-marker.lifecycle-migration-snapshot.json" ]
}

@test "explicit source reaches the state machine migrate legacy write scan" {
  workflow_id="wf-explicit-source-review"
  mkdir -p "$BOOK/正文" "$BOOK/追踪/workflow/tasks/$workflow_id"
  for chapter in 1 2 3 4 5 6 7 8; do
    printf '# 第%s章\n\n可信的既有正文 %s。\n' "$chapter" "$chapter" > "$BOOK/正文/chapter$(printf '%03d' "$chapter").md"
  done
  cat > "$BOOK/追踪/workflow/tasks/$workflow_id/task.json" <<JSON
{
  "workflow_id":"$workflow_id",
  "workflow_type":"review_repair",
  "status":"running",
  "task_dir":"追踪/workflow/tasks/$workflow_id",
  "scope":"1-8",
  "current_stage":"evidence_scan",
  "current_step":"evidence_scan",
  "review_batches":{"batch_size":50,"agent_count":4,"agents":["plot","character","canon","prose"]}
}
JSON
  cat > "$BOOK/追踪/workflow/current-task.json" <<JSON
{"workflow_id":"$workflow_id","task_dir":"追踪/workflow/tasks/$workflow_id"}
JSON

  node "$REPO/scripts/workflow-state-machine.js" migrate-legacy \
    --project-root "$BOOK" --source oh-story --write --workflow-id "$workflow_id" --confirm --json > "$TMP_DIR/state-machine-source.json"

  grep -q '"status": "migration_applied"' "$TMP_DIR/state-machine-source.json"
  node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = require(path.join(root, '追踪/workflow/current-task.json'));
const task = require(path.join(root, pointer.task_dir, 'task.json'));
if (pointer.workflow_type || pointer.user_goal || pointer.workflow_id !== task.workflow_id || pointer.task_dir !== task.task_dir) throw new Error(JSON.stringify({ pointer, task }));
if (task.migration.source !== 'worldwonderer/oh-story-claudecode') throw new Error(JSON.stringify(task.migration));
NODE
}
