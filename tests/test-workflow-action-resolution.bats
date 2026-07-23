#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/workflow-state-machine.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    TASK_DIR="$BOOK/追踪/workflow/tasks/wf-menu-version-test"
    mkdir -p "$TASK_DIR"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_task() {
    local version="$1"
    local pending_id="$2"
    local choice_hash="$3"
    local action_id="$4"
    cat > "$TASK_DIR/task.json" <<JSON
{
  "workflow_id": "wf-menu-version-test",
  "workflow_type": "short_write",
  "task_dir": "追踪/workflow/tasks/wf-menu-version-test",
  "book_root": "$BOOK",
  "state_version": $version,
  "completion_policy": "stage_then_confirm",
  "current_stage": "positioning",
  "current_step": "positioning",
  "status": "running",
  "pending_action": {
    "id": "$pending_id",
    "question": "请选择下一步",
    "visible_choice_hash": "$choice_hash",
    "status": "pending",
    "options": [
      {"number": 1, "action_id": "$action_id", "label": "继续当前阶段", "target_stage": "positioning", "risk_level": "low"},
      {"number": 2, "action_id": "pause", "label": "停止并保存断点", "risk_level": "low"}
    ],
    "free_text_enabled": true
  }
}
JSON
    cat > "$BOOK/追踪/workflow/current-task.json" <<JSON
{
  "schemaVersion": "1.0.0",
  "workflow_id": "wf-menu-version-test",
  "task_dir": "追踪/workflow/tasks/wf-menu-version-test",
  "state_version": $version,
  "focused_at": "2026-07-12T00:00:00.000Z"
}
JSON
}

@test "workflow action resolution rejects a stale visible choice instead of executing a newer option" {
    write_task 10 "pa-session-a" "hash-session-a" "continue_next_stage"

    # Session A receives this binding alongside the visible Chinese menu.
    pending_action_id="pa-session-a"
    visible_choice_hash="hash-session-a"
    state_version=10

    # Session B refreshes the task before A replies with the visible text "1".
    write_task 11 "pa-session-b" "hash-session-b" "pause"

    run node "$SCRIPT" resolve-action --project-root "$BOOK" --input 1 \
        --pending-action-id "$pending_action_id" \
        --visible-choice-hash "$visible_choice_hash" \
        --state-version "$state_version" \
        --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'"status":"blocked_stale_visible_choice"'* ]]
    [[ "$output" == *'"pending_action_id":"pa-session-b"'* ]]
    [[ "$output" == *'"state_version": 11'* ]]
    [[ "$output" != *'"action_id":"pause"'* ]]

    node - "$TASK_DIR/task.json" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (task.state_version !== 11) throw new Error(`stale selection mutated state: ${task.state_version}`);
if (task.pending_action.status === 'resolved') throw new Error('stale selection resolved the newer menu');
if (task.pending_action.options[0].action_id !== 'pause') throw new Error('session B menu was changed');
if (task.stage_execution) throw new Error('stale selection started a stage');
NODE
}

@test "workflow action resolution requires the visible menu binding for numeric input" {
    write_task 10 "pa-session-a" "hash-session-a" "continue_next_stage"

    run node "$SCRIPT" resolve-action --project-root "$BOOK" --input 1 --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'"status":"blocked_missing_visible_choice_binding"'* ]]
    [[ "$output" == *'"pending_action_id":"pa-session-a"'* ]]
    [[ "$output" == *'"visible_choice_hash":"hash-session-a"'* ]]
    node - "$output" <<'NODE'
const out = JSON.parse(process.argv[2]);
if (out.refreshed_menu?.state_version !== 10) {
  throw new Error(`wrong refreshed menu version: ${JSON.stringify(out.refreshed_menu)}`);
}
NODE
}

@test "workflow action resolution fails closed for resolved expired hash and book mismatches" {
    for mismatch in resolved expired hash book; do
        write_task 10 "pa-session-a" "hash-session-a" "continue_next_stage"
        args=(--pending-action-id pa-session-a --visible-choice-hash hash-session-a --state-version 10)
        case "$mismatch" in
            resolved)
                node - "$TASK_DIR/task.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8'));
task.pending_action.status = 'resolved';
fs.writeFileSync(file, JSON.stringify(task));
NODE
                expected="blocked_selection_resolved"
                ;;
            expired)
                node - "$TASK_DIR/task.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8'));
task.pending_action.expires_at = '2000-01-01T00:00:00.000Z';
fs.writeFileSync(file, JSON.stringify(task));
NODE
                expected="blocked_selection_expired"
                ;;
            hash)
                args=(--pending-action-id pa-session-a --visible-choice-hash wrong-hash --state-version 10)
                expected="blocked_visible_choice_hash_mismatch"
                ;;
            book)
                args+=(--book-root "$TMP_DIR/another-book")
                expected="blocked_pending_action_project_mismatch"
                ;;
        esac

        run node "$SCRIPT" resolve-action --project-root "$BOOK" --input 1 "${args[@]}" --json

        [ "$status" -eq 2 ]
        [[ "$output" == *"\"status\":\"$expected\""* ]]
        [[ "$output" == *'"refreshed_menu"'* ]]
        [[ "$output" != *'"selection_status":"resolved"'* ]]
    done
}
