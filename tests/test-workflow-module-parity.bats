#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE="$REPO/scripts/workflow-state-machine.js"
    RUNNER="$REPO/scripts/workflow-runner.js"
    FAKE="$REPO/tests/fixtures/fake-workflow-host.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    FIXTURES="$REPO/tests/fixtures/workflow-module-parity"
    mkdir -p "$BOOK"
}

teardown() {
    rm -rf "$TMP_DIR"
}

normalize_json() {
    node -e '
const fs=require("fs");
const value=JSON.parse(fs.readFileSync(0,"utf8"));
const [book,repo]=process.argv.slice(1);
function scrub(v){
  if(Array.isArray(v)) return v.map(scrub);
  if(v&&typeof v==="object"){
    const out={};
    for(const k of Object.keys(v).sort()){
      const val=v[k];
      if(/(?:^|_)at$/.test(k)||/_at$/.test(k)) { out[k]="<timestamp>"; continue; }
      if(k==="workflow_id") { out[k]="<workflow-id>"; continue; }
      if(k==="task_family_id") { out[k]="<task-family-id>"; continue; }
      if(["pending_action_id","visible_choice_hash","sourceTreeId","sourceInputDigest","bundleId","review_plan_digest"].includes(k)) { out[k]=`<${k}>`; continue; }
      if(["started_at_ms","last_activity_at_ms"].includes(k)) { out[k]="<timestamp-ms>"; continue; }
      if(k==="id"&&/^pa-/.test(String(val||""))) { out[k]="<pending-action-id>"; continue; }
      out[k]=scrub(val);
    }
    return out;
  }
  if(typeof v==="string") return v
    .split(book).join("<project-root>")
    .split(repo).join("<repo-root>")
    .replace(/wf-[0-9]{17}-[A-Za-z0-9_-]+-[a-f0-9]{8}/g,"<workflow-id>")
    .replace(/tf-[a-f0-9]{16}/g,"<task-family-id>")
    .replace(/sa-<workflow-id>-[A-Za-z0-9_-]+-[a-f0-9]{8}/g,"<stage-attempt-id>")
    .replace(/run-[A-Za-z0-9._-]+/g,"<run-id>");
  return v;
}
process.stdout.write(JSON.stringify(scrub(value),null,2));
' "$BOOK" "$REPO"
}

assert_fixture() {
    local name="$1"
    local actual="$2"
    local expected="$FIXTURES/$name.json"
    if [ "${UPDATE_WORKFLOW_MODULE_FIXTURES:-0}" = "1" ]; then
        mkdir -p "$FIXTURES"
        cp "$actual" "$expected"
        return 0
    fi
    [ -f "$expected" ]
    cmp -s "$expected" "$actual" || {
        diff -u "$expected" "$actual"
        return 1
    }
}

@test "templates CLI exposes stable workflow inventory and stage order" {
    run node "$STATE" templates --no-private-registry --json
    [ "$status" -eq 0 ]
    echo "$output" | normalize_json > "$TMP_DIR/templates.json"
    assert_fixture templates "$TMP_DIR/templates.json"
}

@test "next-candidates remains stable for a new review workflow" {
    node "$STATE" create --workflow-type review_repair --project-root "$BOOK" --scope "1-200" --user-goal "审阅 1-200 章" --json >/dev/null
    run node "$STATE" next-candidates --project-root "$BOOK" --json
    [ "$status" -eq 0 ]
    echo "$output" | normalize_json > "$TMP_DIR/next.json"
    assert_fixture review-next-candidates "$TMP_DIR/next.json"
}

@test "runner dry-run output remains stable for a created review workflow" {
    node "$STATE" create --workflow-type review_repair --project-root "$BOOK" --scope "1-200" --user-goal "审阅 1-200 章" --json >/dev/null
    node - "$STATE" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [script,root]=process.argv.slice(2);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
const pending=task.pending_action||{};
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',String(pending.id||''),'--visible-choice-hash',String(pending.visible_choice_hash||''),'--state-version',String(task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
    run node "$RUNNER" once --project-root "$BOOK" --adapter fake --fake-executable "$FAKE" --dry-run --json
    [ "$status" -eq 0 ]
    echo "$output" | normalize_json > "$TMP_DIR/runner.json"
    assert_fixture review-runner-dry-run "$TMP_DIR/runner.json"
}

@test "review batch advance output remains stable with explicit workflow authority" {
    node - "$STATE" "$BOOK" <<'NODE' > "$TMP_DIR/review-batch-raw.json"
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const [state, root] = process.argv.slice(2);

function run(args) {
  const result = spawnSync(process.execPath, [state, ...args, '--json'], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stdout || result.stderr);
  return JSON.parse(result.stdout);
}
function task() {
  const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
  return JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
}
function resolve() {
  const current = task();
  const pending = current.pending_action || {};
  return run(['resolve-action', '--project-root', root, '--input', '1', '--pending-action-id', String(pending.id || ''), '--visible-choice-hash', String(pending.visible_choice_hash || ''), '--state-version', String(current.state_version), '--book-root', root]);
}
function packet(current, extras = {}) {
  return {
    workflow_id: current.workflow_id,
    workflow_type: current.workflow_type,
    stage_id: current.current_stage,
    step_id: current.current_stage,
    owner_module: String(((current.stage_execution || {}).owner_module) || 'story-workflow'),
    step_status: 'completed',
    outputs: [],
    changed_files: [],
    evidence: ['normalized parity evidence'],
    verification_result: 'pass',
    blocking_reason: '',
    next_recommendation: '继续下一批',
    handoff_summary: 'characterization fixture',
    checkpoint_state: { completed_stage: current.current_stage },
    output_health_result: 'pass',
    ...extras,
  };
}
function apply(current, value) {
  const file = path.join(root, current.stage_execution.expected_result_packet);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  return run(['apply-result', '--project-root', root, '--workflow-id', current.workflow_id, '--result', file]);
}

for (let order = 1; order <= 8; order += 1) {
  const file = path.join(root, '正文', `chapter${String(order).padStart(3, '0')}.md`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `# Chapter ${order}\n\nTrusted narrative evidence for chapter ${order}.\n`);
}
run(['create', '--workflow-type', 'review_repair', '--project-root', root, '--scope', '1-8', '--user-goal', '审阅 1-8 章']);
resolve();
let current = task();
apply(current, packet(current));
resolve();
current = task();
const scan = spawnSync(process.execPath, [path.join(path.dirname(state), 'review-batch-evidence-scan.js'), '--project-root', root, '--range', current.stage_execution.batch_scope, '--json'], { encoding: 'utf8' });
if (scan.status !== 0) throw new Error(scan.stdout || scan.stderr);
const evidence = JSON.parse(scan.stdout);
const result = apply(current, packet(current, {
  batch_id: current.stage_execution.batch_id,
  batch_scope: current.stage_execution.batch_scope,
  protocolVersion: evidence.protocolVersion,
  sourceDigest: evidence.sourceDigest,
  fullRangeCoverage: evidence.fullRangeCoverage,
}));
process.stdout.write(JSON.stringify(result));
NODE
    normalize_json < "$TMP_DIR/review-batch-raw.json" > "$TMP_DIR/review-batch.json"
    assert_fixture review-batch-advance "$TMP_DIR/review-batch.json"
}

@test "stream health stop output remains stable" {
    node - "$REPO/scripts/lib/workflow-stream-health.js" <<'NODE' | normalize_json > "$TMP_DIR/health-stop.json"
const { createStreamHealthMonitor } = require(process.argv[2]);
const monitor = createStreamHealthMonitor();
monitor.start(1000);
monitor.ingest('stdout', '修真'.repeat(40), 1100);
process.stdout.write(JSON.stringify(monitor.snapshot(1200)));
NODE
    assert_fixture health-stop "$TMP_DIR/health-stop.json"
}

@test "complete token cost event remains stable" {
    node "$REPO/scripts/token-cost-ledger.js" append \
      --project-root "$BOOK" \
      --workflow-id wf-token-parity \
      --workflow-type review_repair \
      --stage evidence_scan \
      --module story-review \
      --model-class deep_reasoning \
      --task-complexity low \
      --input-files 55 \
      --input-chars 130000 \
      --output-chars 5000 \
      --tool-calls 7 \
      --retry-count 1 \
      --failure-count 1 \
      --cache-hit true \
      --status failed \
      --token-source host \
      --input-tokens 321 \
      --output-tokens 123 \
      --cache-read-tokens 11 \
      --cache-write-tokens 7 \
      --duration-ms 4567 \
      --finding-code invalid_host_usage_metric \
      --event-id event-token-parity \
      --created-at 2026-07-12T00:00:00.000Z \
      --json | normalize_json > "$TMP_DIR/token-event.json"
    assert_fixture token-event "$TMP_DIR/token-event.json"
}
