#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    VALIDATOR="$REPO/scripts/workflow-state-validate.js"
    SUPERVISOR="$REPO/scripts/workflow-runtime-supervisor.js"
    RUNNER="$REPO/scripts/workflow-runner.js"
    ENTRY_GUARD="$REPO/scripts/workflow-entry-guard.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/workflow/tasks/wf-authority"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_pending_legacy_review() {
    mkdir -p "$BOOK/正文"
    printf '# 第001章\n\n正文。\n' > "$BOOK/正文/chapter001.md"
    printf '# current task\n' > "$BOOK/追踪/workflow/current-task.md"
    printf '{"source_repository":"worldwonderer/oh-story-claudecode"}\n' > "$BOOK/.story-deployed"
    cat > "$BOOK/追踪/workflow/tasks/wf-authority/task.json" <<'JSON'
{
  "workflow_id": "wf-authority",
  "workflow_type": "review_repair",
  "status": "running",
  "state_version": 1,
  "task_dir": "追踪/workflow/tasks/wf-authority",
  "scope": "1-200",
  "current_stage": "evidence_scan",
  "runtime_guard": {
    "heartbeat": { "updated_at": "2099-01-01T00:00:00.000Z", "latest_trusted_artifact": "追踪/workflow/current-task.md" },
    "stall_policy": { "heartbeat_timeout_minutes": 1, "on_stall": "pause_at_checkpoint" },
    "checkpoint_policy": { "resume_from": "evidence_scan", "checkpoint_path": "追踪/workflow/current-task.json" }
  },
  "review_batches": { "batch_size": 50, "agent_count": 4, "agents": ["plot", "character", "canon", "prose"] }
}
JSON
    cat > "$BOOK/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-authority","task_dir":"追踪/workflow/tasks/wf-authority","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON
}

@test "task authority converges while entry guard renders the pending migration as an inbox card" {
    write_pending_legacy_review

    node "$VALIDATOR" --project-root "$BOOK" --json > "$TMP_DIR/validator.json" || true
    node "$SUPERVISOR" --project-root "$BOOK" --json > "$TMP_DIR/supervisor.json" || true
    node "$RUNNER" status --project-root "$BOOK" --json > "$TMP_DIR/runner.json" || true
    node "$ENTRY_GUARD" --project-root "$BOOK" --json > "$TMP_DIR/entry-guard.json" || true

    node - "$TMP_DIR/validator.json" "$TMP_DIR/supervisor.json" "$TMP_DIR/runner.json" "$TMP_DIR/entry-guard.json" <<'NODE'
const fs = require('fs');
const results = process.argv.slice(2).map((file) => JSON.parse(fs.readFileSync(file, 'utf8')));
for (const result of results.slice(0, 3)) {
  if (result.workflow_id !== 'wf-authority') throw new Error(JSON.stringify(result));
  if (result.status !== 'migration_pending' || result.recommended_action !== 'migrate_legacy_review_and_continue') throw new Error(JSON.stringify(result));
}
const entry = results[3];
if (entry.status !== 'task_inbox_ready') throw new Error(JSON.stringify(entry));
if (entry.workflow_id !== 'wf-authority') throw new Error(JSON.stringify(entry));
if (entry.recommended_action !== 'show_task_inbox_only') throw new Error(JSON.stringify(entry));
if (entry.runner_contract.task_family_migration_pending_count !== 1) throw new Error(JSON.stringify(entry));
if (entry.task_inbox.migration_task_count !== 1) throw new Error(JSON.stringify(entry));
if (!entry.task_inbox.candidates.some((candidate) => candidate.id === 'wf-authority' && candidate.status === 'migration_pending')) {
  throw new Error(JSON.stringify(entry));
}
NODE
}
