#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SUPERVISOR="$REPO/scripts/workflow-supervisor.js"
    STATE="$REPO/scripts/workflow-state-machine.js"
    STORE="$REPO/scripts/lib/workflow-supervisor-store.js"
    FAKE="$REPO/tests/fixtures/fake-workflow-host.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

create_started_task() {
    node "$STATE" create --workflow-type short_startup --project-root "$PROJECT" --user-goal "测试督导器" --json >/dev/null
    next_json="$(node "$STATE" next-candidates --project-root "$PROJECT" --json)"
    pending_id="$(node -e 'const v=JSON.parse(process.argv[1]); process.stdout.write(v.pending_action.id)' "$next_json")"
    choice_hash="$(node -e 'const v=JSON.parse(process.argv[1]); process.stdout.write(v.pending_action.visible_choice_hash)' "$next_json")"
    state_version="$(node -e 'const v=JSON.parse(process.argv[1]); process.stdout.write(String(v.pending_action.state_version))' "$next_json")"
    node "$STATE" resolve-action --project-root "$PROJECT" --input 1 \
      --pending-action-id "$pending_id" --visible-choice-hash "$choice_hash" \
      --state-version "$state_version" --book-root "$PROJECT" --json >/dev/null
}

@test "supervisor once records no active task without launching a host" {
    node "$SUPERVISOR" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --json > "$TMP_DIR/out.json"

    grep -q '"status": "no_active_task"' "$TMP_DIR/out.json"
    node - "$PROJECT/追踪/workflow/supervisor-state.json" <<'NODE'
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (state.status !== 'stopped_no_active_task' || state.cycle_count !== 1) throw new Error(JSON.stringify(state));
NODE
    [ "$(wc -l < "$PROJECT/追踪/workflow/supervisor-events.jsonl" | tr -d ' ')" -ge 2 ]
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "supervisor lease rejects a second live owner and releases cleanly" {
    run node - "$STORE" "$PROJECT" <<'NODE'
const assert = require('assert/strict');
const store = require(process.argv[2]);
const root = process.argv[3];
const release = store.acquireSupervisorLease(root, 'first', 60000);
assert.throws(() => store.acquireSupervisorLease(root, 'second', 60000), { code: 'SUPERVISOR_LOCKED' });
assert.equal(release(), true);
const second = store.acquireSupervisorLease(root, 'second', 60000);
assert.equal(second(), true);
NODE

    [ "$status" -eq 0 ]
    test ! -e "$PROJECT/追踪/workflow/.supervisor.lock"
}

@test "supervisor once delegates one stage then persists a restartable checkpoint" {
    create_started_task

    node "$SUPERVISOR" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json > "$TMP_DIR/first.json"

    grep -q '"status": "stage_applied"' "$TMP_DIR/first.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 1 ]
    node - "$PROJECT/追踪/workflow/supervisor-state.json" <<'NODE'
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (state.status !== 'checkpointed' || state.last_result.status !== 'stage_applied') throw new Error(JSON.stringify(state));
if (!state.last_checkpoint || !state.last_checkpoint.stage_id) throw new Error(JSON.stringify(state));
NODE
}

@test "supervisor restart reuses an existing result packet instead of rerunning its completed stage" {
    create_started_task
    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
const result = {
  workflow_id: task.workflow_id,
  workflow_type: task.workflow_type,
  stage_id: task.current_stage,
  step_id: task.current_stage,
  step_status: 'completed',
  outputs: [], changed_files: [], evidence: [], verification_result: 'pass',
  blocking_reason: '', next_recommendation: '继续', handoff_summary: '可信断点已存在。',
  checkpoint_state: {}, output_health_result: 'pass'
};
const target = path.join(root, task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, JSON.stringify(result));
NODE

    node "$SUPERVISOR" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --json > "$TMP_DIR/out.json"

    grep -q '"status": "stage_applied"' "$TMP_DIR/out.json"
    grep -q '"reused_existing_result": true' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "supervisor stops at confirmation docking without picking an option" {
    node "$STATE" create --workflow-type project_setup --project-root "$PROJECT" --user-goal "初始化" --json >/dev/null

    node "$SUPERVISOR" watch --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --max-runtime-minutes 1 --max-cycles 3 --json > "$TMP_DIR/out.json"

    grep -q '"status": "stopped_needs_confirmation"' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "supervisor watch honors a max-cycle boundary and does not mutate host configuration" {
    create_started_task
    before="$(find "$PROJECT" -maxdepth 2 -name 'settings*.json' -print | sort | xargs -r shasum | shasum)"

    node "$SUPERVISOR" watch --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --max-runtime-minutes 1 --max-cycles 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "stopped_max_cycles"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 1 ]
    after="$(find "$PROJECT" -maxdepth 2 -name 'settings*.json' -print | sort | xargs -r shasum | shasum)"
    [ "$before" = "$after" ]
}

@test "supervisor blocks a paid adapter without explicit per-stage and total budgets" {
    create_started_task
    mkdir -p "$TMP_DIR/bin"
    cp "$FAKE" "$TMP_DIR/bin/codex"
    chmod +x "$TMP_DIR/bin/codex"

    status=0
    env PATH="$TMP_DIR/bin:$PATH" node "$SUPERVISOR" watch --project-root "$PROJECT" --adapter codex --max-runtime-minutes 1 --max-cycles 2 --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 0 ]
    grep -q '"status": "stopped_budget_required"' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "supervisor restart preserves reserved budget instead of reopening a spent watch cap" {
    run node - "$SUPERVISOR" "$PROJECT" <<'NODE'
const assert = require('assert/strict');
const supervisor = require(process.argv[2]);
const root = process.argv[3];
const options = { command: 'watch', adapter: 'codex', maxCycles: 8, maxRuntimeMinutes: 60, maxBudgetUsd: 1, maxTotalBudgetUsd: 2 };
const state = supervisor.createState(root, options, 'test', { reserved_budget_usd: 2 }, Date.now());
assert.equal(state.reserved_budget_usd, 2);
assert.equal(supervisor.hasRemainingReservedBudget(state, options), false);
NODE

    [ "$status" -eq 0 ]
}
