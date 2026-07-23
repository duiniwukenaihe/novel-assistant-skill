#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/workflow-stage-context.js"
    BOOK="$(mktemp -d)/果汁项目"
    WORKFLOW_ID="wf-20260716014257097-private_short_startup-8318de87"
    TASK_DIR="$BOOK/追踪/workflow/tasks/$WORKFLOW_ID"
    PACKET_REL="追踪/workflow/tasks/$WORKFLOW_ID/context-packets/feedback_apply_patch/whole-story/sa-$WORKFLOW_ID-feedback_apply_patch-b5491f6d/stage-context.md"
    mkdir -p "$TASK_DIR" "$(dirname "$BOOK/$PACKET_REL")" "$BOOK/追踪/workflow"
    printf '# 精确阶段包\n只读这份内容。\n' > "$BOOK/$PACKET_REL"
    cat > "$TASK_DIR/task.json" <<JSON
{
  "workflow_id":"$WORKFLOW_ID",
  "workflow_type":"private_short_startup",
  "task_dir":"追踪/workflow/tasks/$WORKFLOW_ID",
  "current_stage":"feedback_apply_patch",
  "stage_execution":{
    "status":"running",
    "stage_id":"feedback_apply_patch",
    "stage_context_packet":{"packet_md":"$PACKET_REL"}
  }
}
JSON
    cat > "$BOOK/追踪/workflow/current-task.json" <<JSON
{"schemaVersion":"1.0.0","workflow_id":"$WORKFLOW_ID","task_dir":"追踪/workflow/tasks/$WORKFLOW_ID"}
JSON
}

teardown() {
    rm -rf "$(dirname "$BOOK")"
}

@test "read-current resolves the authoritative stage packet without a host copying its path" {
    run node "$SCRIPT" read-current --project-root "$BOOK" --workflow-id "$WORKFLOW_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *'# 精确阶段包'* ]]
    [[ "$output" == *'只读这份内容。'* ]]
}

@test "read-current returns structured blocking when the workflow id is unknown" {
    run node "$SCRIPT" read-current --project-root "$BOOK" --workflow-id "wf-unknown" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_task_not_found'* ]]
}
