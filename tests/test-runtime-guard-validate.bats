#!/usr/bin/env bats
# tests/test-runtime-guard-validate.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/runtime-guard-validate.js"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    README="$REPO/scripts/README.md"
    BUILD="$REPO/config/novel-assistant-bundle-files.json"
    SETUP="$REPO/src/internal-skills/story-setup/SKILL.md"
    BUNDLE_NOVEL="$REPO/skills/novel-assistant"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "runtime guard validator blocks long current task without runtime_guard" {
    cat > "$TMP_DIR/current-task.json" <<'JSON'
{
  "workflow_id": "wf-001",
  "workflow_type": "review",
  "scope": { "type": "range", "chapters": "1-400" },
  "completion_policy": "full_auto",
  "status": "running"
}
JSON

    status=0
    node "$SCRIPT" --kind current-task "$TMP_DIR/current-task.json" --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q "blocked_runtime_guard_missing" "$TMP_DIR/out.json"
    grep -q "runtime_guard" "$TMP_DIR/out.json"
}

@test "runtime guard validator accepts checkpointed long current task" {
    cat > "$TMP_DIR/current-task.json" <<'JSON'
{
  "workflow_id": "wf-002",
  "workflow_type": "long_analyze",
  "scope": { "type": "book", "chapters": "1-600" },
  "completion_policy": "full_auto",
  "status": "running",
  "runtime_guard": {
    "token_estimate": { "input_files": 600, "input_chars_estimate": 1800000, "output_chars_budget": 120000, "agent_count": 4, "batch_size": 30, "risk_level": "high" },
    "adaptive_budget_policy": { "batch_chars_soft_limit": 120000, "split_when_over": true },
    "heartbeat": { "latest_trusted_artifact": "追踪/workflow/current-task.md", "updated_at": "2026-06-29T10:00:00+08:00", "current_batch": "1-30", "completed": 30, "total": 600 },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/checkpoints/wf-002.json", "resume_from": "31", "reusable_outputs": ["章节/第001章_摘要.md"] },
    "output_health_gate": { "script": "scripts/output-pollution-check.js", "required": true },
    "max_retry_budget": { "same_failure": 1, "total": 3 },
    "stall_policy": { "heartbeat_timeout_minutes": 15, "on_stall": "pause_at_checkpoint" },
    "token_cost_governance": {
      "cost_ledger_path": "追踪/workflow/token-cost-ledger.jsonl",
      "cost_summary_path": "追踪/workflow/token-cost-summary.json",
      "model_routing_policy": { "cheap_extract": "script", "standard_reasoning": "batch", "deep_reasoning": "arbiter" },
      "tool_output_filter": "file_then_summary",
      "retry_budget_result": "same_failure_once"
    }
  }
}
JSON

    node "$SCRIPT" --kind current-task "$TMP_DIR/current-task.json" --json > "$TMP_DIR/out.json"

    grep -q '"status": "ok"' "$TMP_DIR/out.json"
    node -e "const fs=require('fs'); JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));" "$TMP_DIR/out.json"
}

@test "runtime guard validator blocks long task without token cost governance" {
    cat > "$TMP_DIR/current-task.json" <<'JSON'
{
  "workflow_id": "wf-cost-missing",
  "workflow_type": "review",
  "scope": { "type": "range", "chapters": "1-400" },
  "completion_policy": "full_auto",
  "status": "running",
  "runtime_guard": {
    "token_estimate": { "input_files": 400, "input_chars_estimate": 1000000, "output_chars_budget": 80000, "agent_count": 4, "batch_size": 50, "risk_level": "high" },
    "adaptive_budget_policy": { "batch_chars_soft_limit": 100000, "split_when_over": true },
    "heartbeat": { "latest_trusted_artifact": "追踪/workflow/current-task.md", "updated_at": "2026-06-29T10:00:00+08:00" },
    "checkpoint_policy": { "checkpoint_path": "追踪/workflow/checkpoints/wf-cost-missing.json", "resume_from": "1", "reusable_outputs": [] },
    "output_health_gate": { "script": "scripts/output-pollution-check.js", "required": true },
    "max_retry_budget": { "same_failure": 1, "total": 3 },
    "stall_policy": { "heartbeat_timeout_minutes": 15, "on_stall": "pause_at_checkpoint" }
  }
}
JSON

    status=0
    node "$SCRIPT" --kind current-task "$TMP_DIR/current-task.json" --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q "blocked_token_cost_governance_missing" "$TMP_DIR/out.json"
    grep -q "runtime_guard.token_cost_governance.cost_ledger_path" "$TMP_DIR/out.json"
}

@test "runtime guard validator blocks result packet without checkpoint and health report" {
    cat > "$TMP_DIR/result.json" <<'JSON'
{
  "workflow_id": "wf-003",
  "stage_id": "stage-2",
  "step_id": "batch-1",
  "owner_module": "story-review",
  "step_status": "completed",
  "verification_result": "pass",
  "outputs": ["追踪/审查报告/report.md"],
  "changed_files": ["追踪/审查报告/report.md"]
}
JSON

    status=0
    node "$SCRIPT" --kind result-packet "$TMP_DIR/result.json" --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q "blocked_result_packet_incomplete" "$TMP_DIR/out.json"
    grep -q "checkpoint_state" "$TMP_DIR/out.json"
    grep -q "output_health_result" "$TMP_DIR/out.json"
}

@test "runtime guard validator blocks pass result when output health failed" {
    cat > "$TMP_DIR/result.json" <<'JSON'
{
  "workflow_id": "wf-004",
  "stage_id": "stage-2",
  "step_id": "batch-1",
  "owner_module": "story-review",
  "step_status": "completed",
  "verification_result": "pass",
  "outputs": ["追踪/审查报告/report.md"],
  "changed_files": ["追踪/审查报告/report.md"],
  "checkpoint_state": { "current_stage": "stage-2", "current_batch": "1-50", "completed_range": "1-50", "remaining_range": "51-100", "failed_items": [], "reusable_outputs": ["追踪/审查报告/report.md"], "resume_from": "51" },
  "heartbeat_update": { "latest_trusted_artifact": "追踪/审查报告/report.md", "updated_at": "2026-06-29T10:10:00+08:00" },
  "budget_usage": { "input_files": 50, "output_files": 1, "agent_count": 2, "batch_count": 1 },
  "output_health_result": { "status": "blocked_output_pollution", "script": "scripts/output-pollution-check.js", "findings": 3 },
  "handoff_packet_path": "追踪/workflow/agent-handoff/wf-004/review.json",
  "resume_hint": "继续审阅 51-100"
}
JSON

    status=0
    node "$SCRIPT" --kind result-packet "$TMP_DIR/result.json" --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q "blocked_output_health_failed" "$TMP_DIR/out.json"
}

@test "runtime guard validator is wired into workflow docs and bundles" {
    grep -q "runtime-guard-validate.js" "$WORKFLOW"
    grep -q "runtime-guard-validate.js" "$README"
    grep -q "runtime-guard-validate.js" "$BUILD"
    grep -q "runtime-guard-validate.js" "$SETUP"
    test -f "$BUNDLE_NOVEL/scripts/runtime-guard-validate.js"
}
