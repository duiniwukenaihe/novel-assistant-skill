#!/usr/bin/env bats
# tests/test-workflow-runtime-supervisor.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/workflow-runtime-supervisor.js"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    README="$REPO/README.md"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    BUILD_MANIFEST="$REPO/config/novel-assistant-bundle-files.json"
    SETUP="$REPO/src/internal-skills/story-setup/SKILL.md"
    BUNDLE_NOVEL="$REPO/skills/novel-assistant"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_current_task() {
    workflow_id="$1"
    task_dir="追踪/workflow/tasks/$workflow_id"
    mkdir -p "$TMP_DIR/book/$task_dir"
    cat > "$TMP_DIR/book/$task_dir/task.json"
    node - "$TMP_DIR/book/$task_dir/task.json" "$TMP_DIR/book/追踪/workflow/current-task.json" "$workflow_id" "$task_dir" <<'NODE'
const fs = require('fs');
const [taskFile, pointerFile, workflowId, taskDir] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.schemaVersion ||= '1.0.0';
task.state_version ||= 1;
task.workflow_id = workflowId;
task.task_dir = taskDir;
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
fs.writeFileSync(pointerFile, `${JSON.stringify({
  schemaVersion: '1.0.0',
  workflow_id: workflowId,
  task_dir: taskDir,
  focused_at: '2026-06-29T09:00:00+08:00',
  state_version: task.state_version,
}, null, 2)}\n`);
NODE
}

@test "workflow runtime supervisor reports idle when state is missing" {
    mkdir -p "$TMP_DIR/book"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --now "2026-06-29T10:00:00+08:00" --json > "$TMP_DIR/out.json"

    grep -q '"status": "idle"' "$TMP_DIR/out.json"
    grep -q '"recommended_action": "idle"' "$TMP_DIR/out.json"
}

@test "workflow runtime supervisor allows fresh running heartbeat to continue" {
    write_current_task wf-fresh <<'JSON'
{
  "workflow_id": "wf-fresh",
  "status": "running",
  "current_stage": "stage-2",
  "current_step": "batch-1",
  "runtime_guard": {
    "heartbeat": { "updated_at": "2026-06-29T09:50:00+08:00", "latest_trusted_artifact": "追踪/workflow/current-task.md", "current_batch": "1-30", "completed": 30, "total": 600 },
    "runner_lease": { "workflow_id": "wf-fresh", "stage_id": "stage-2", "run_id": "run-fresh", "process_heartbeat_at": "2026-06-29T09:59:00+08:00", "expires_at": "2026-06-29T10:20:00+08:00" },
    "checkpoint_updated_at": "2026-06-29T09:50:00+08:00",
    "stall_policy": { "heartbeat_timeout_minutes": 20, "on_stall": "pause_at_checkpoint" },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/checkpoints/wf-fresh.json", "resume_from": "31", "reusable_outputs": ["章节/第001章_摘要.md"] }
  }
}
JSON
    printf '# current task\n' > "$TMP_DIR/book/追踪/workflow/current-task.md"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --now "2026-06-29T10:00:00+08:00" --json > "$TMP_DIR/out.json"

    grep -q '"status": "running"' "$TMP_DIR/out.json"
    grep -q '"recommended_action": "continue"' "$TMP_DIR/out.json"
    grep -q '"process_heartbeat_at": "2026-06-29T09:59:00+08:00"' "$TMP_DIR/out.json"
}

@test "workflow runtime supervisor exposes a stale running task as a resumable pause" {
    write_current_task wf-stale <<'JSON'
{
  "workflow_id": "wf-stale",
  "status": "running",
  "current_stage": "stage-2",
  "current_step": "batch-4",
  "runtime_guard": {
    "heartbeat": { "updated_at": "2026-06-29T09:00:00+08:00", "latest_trusted_artifact": "章节/第300章_摘要.md", "current_batch": "301-330", "completed": 300, "total": 600 },
    "stall_policy": { "heartbeat_timeout_minutes": 15, "on_stall": "pause_at_checkpoint" },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/checkpoints/wf-stale.json", "resume_from": "301", "reusable_outputs": ["章节/第300章_摘要.md"] }
  }
}
JSON
    mkdir -p "$TMP_DIR/book/章节"
    printf '# 第300章摘要\n' > "$TMP_DIR/book/章节/第300章_摘要.md"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --now "2026-06-29T10:00:00+08:00" --json > "$TMP_DIR/out.json"

    grep -q '"status": "paused"' "$TMP_DIR/out.json"
    grep -q '"recommended_action": "resume_from_checkpoint"' "$TMP_DIR/out.json"
}

@test "workflow runtime supervisor keeps a paused batch paused" {
    write_current_task wf-paused <<'JSON'
{
  "workflow_id": "wf-paused",
  "status": "paused_after_batch",
  "current_stage": "stage-2",
  "current_step": "batch-5",
  "runtime_guard": {
    "heartbeat": { "updated_at": "2026-06-29T09:00:00+08:00", "latest_trusted_artifact": "章节/第360章_摘要.md", "current_batch": "331-360", "completed": 360, "total": 600 },
    "stall_policy": { "heartbeat_timeout_minutes": 15, "on_stall": "pause_at_checkpoint" },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/checkpoints/wf-paused.json", "resume_from": "361", "reusable_outputs": ["章节/第360章_摘要.md"] }
  }
}
JSON
    mkdir -p "$TMP_DIR/book/章节"
    printf '# 第360章摘要\n' > "$TMP_DIR/book/章节/第360章_摘要.md"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --now "2026-06-29T10:00:00+08:00" --json > "$TMP_DIR/out.json"

    grep -q '"status": "paused"' "$TMP_DIR/out.json"
    grep -q '"recommended_action": "resume_from_checkpoint"' "$TMP_DIR/out.json"
    grep -q '"resume_from": "361"' "$TMP_DIR/out.json"
}

@test "workflow runtime supervisor blocks when latest trusted artifact is missing" {
    write_current_task wf-missing-artifact <<'JSON'
{
  "workflow_id": "wf-missing-artifact",
  "status": "running",
  "current_stage": "evidence_scan",
  "current_step": "evidence_scan",
  "runtime_guard": {
    "heartbeat": { "updated_at": "2026-06-29T09:55:00+08:00", "latest_trusted_artifact": "追踪/workflow/tasks/wf-missing-artifact/result-packets/evidence_scan.result.json" },
    "stall_policy": { "heartbeat_timeout_minutes": 20, "on_stall": "pause_at_checkpoint" },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/tasks/wf-missing-artifact/task.json", "resume_from": "evidence_scan" }
  }
}
JSON

    status=0
    node "$SCRIPT" --project-root "$TMP_DIR/book" --now "2026-06-29T10:00:00+08:00" --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked"' "$TMP_DIR/out.json"
    grep -q '"recommended_action": "recover_missing_result_packet"' "$TMP_DIR/out.json"
    grep -q '"trusted_artifact_status": "missing"' "$TMP_DIR/out.json"
    grep -q "evidence_scan.result.json" "$TMP_DIR/out.json"
}

@test "workflow runtime supervisor includes token cost summary when available" {
    write_current_task wf-cost <<'JSON'
{
  "workflow_id": "wf-cost",
  "status": "running",
  "current_stage": "stage-2",
  "current_step": "batch-2",
  "runtime_guard": {
    "heartbeat": { "updated_at": "2026-06-29T09:50:00+08:00", "latest_trusted_artifact": "追踪/workflow/current-task.md", "current_batch": "31-60", "completed": 60, "total": 600 },
    "runner_lease": { "workflow_id": "wf-cost", "stage_id": "stage-2", "run_id": "run-cost", "process_heartbeat_at": "2026-06-29T09:59:00+08:00", "expires_at": "2026-06-29T10:20:00+08:00" },
    "checkpoint_updated_at": "2026-06-29T09:50:00+08:00",
    "stall_policy": { "heartbeat_timeout_minutes": 20, "on_stall": "pause_at_checkpoint" },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/checkpoints/wf-cost.json", "resume_from": "61", "reusable_outputs": ["章节/第060章_摘要.md"] },
    "token_cost_governance": {
      "cost_ledger_path": "追踪/workflow/token-cost-ledger.jsonl",
      "cost_summary_path": "追踪/workflow/token-cost-summary.json"
    }
  }
}
JSON
    printf '# current task\n' > "$TMP_DIR/book/追踪/workflow/current-task.md"
    cat > "$TMP_DIR/book/追踪/workflow/token-cost-summary.json" <<'JSON'
{
  "status": "summary",
  "workflow_id": "wf-cost",
  "events": 2,
  "totals": { "estimated_tokens": 12000, "tool_calls": 9, "retry_count": 1, "failure_count": 1 },
  "waste_signals": { "tool_noise_waste": 1, "failure_retry_waste": 1 },
  "proactive_alerts": [
    {
      "severity": "warning",
      "type": "abnormal_waste",
      "message": "检测到异常 token 浪费信号",
      "signals": ["tool_noise_waste", "failure_retry_waste"]
    }
  ],
  "token_saving_plan": {
    "mode": "active_and_passive",
    "actions": [
      { "signal": "tool_noise_waste", "action": "filter_tool_output" },
      { "signal": "failure_retry_waste", "action": "stop_retry_and_triage" }
    ]
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --now "2026-06-29T10:00:00+08:00" --json > "$TMP_DIR/out.json"

    grep -q '"status": "running"' "$TMP_DIR/out.json"
    grep -q '"cost_summary_path": "追踪/workflow/token-cost-summary.json"' "$TMP_DIR/out.json"
    grep -q '"estimated_tokens": 12000' "$TMP_DIR/out.json"
    grep -q '"tool_noise_waste": 1' "$TMP_DIR/out.json"
    grep -q '"cost_alerts"' "$TMP_DIR/out.json"
    grep -q '"abnormal_waste"' "$TMP_DIR/out.json"
    grep -q '"should_notify_user": true' "$TMP_DIR/out.json"
    grep -q '"passive_cost_report_available": true' "$TMP_DIR/out.json"
    grep -q '"token_saving_plan"' "$TMP_DIR/out.json"
    grep -q '"filter_tool_output"' "$TMP_DIR/out.json"
}

@test "workflow runtime supervisor keeps terminal tasks completed despite a stale heartbeat" {
    write_current_task wf-terminal <<'JSON'
{
  "workflow_id": "wf-terminal",
  "status": "completed",
  "current_stage": "handoff",
  "runtime_guard": {
    "heartbeat": { "updated_at": "2020-01-01T00:00:00.000Z", "latest_trusted_artifact": "追踪/workflow/tasks/wf-terminal/task.json" },
    "stall_policy": { "heartbeat_timeout_minutes": 1, "on_stall": "pause_at_checkpoint" },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/tasks/wf-terminal/task.json", "resume_from": "handoff" }
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --now "2026-06-29T10:00:00+08:00" --json > "$TMP_DIR/out.json"

    grep -q '"status": "completed"' "$TMP_DIR/out.json"
    grep -q '"recommended_action": "idle"' "$TMP_DIR/out.json"
    ! grep -q 'stalled' "$TMP_DIR/out.json"
}

@test "workflow runtime supervisor is wired into workflow docs and bundles" {
    grep -q "workflow-runtime-supervisor.js" "$WORKFLOW"
    grep -q "workflow-runtime-supervisor.js" "$README"
    grep -q "BUILD_MANIFEST" "$BUILD"
    grep -q '"workflow-runtime-supervisor.js"' "$BUILD_MANIFEST"
    grep -q "workflow-runtime-supervisor.js" "$SETUP"
    test -f "$BUNDLE_NOVEL/scripts/workflow-runtime-supervisor.js"
}
