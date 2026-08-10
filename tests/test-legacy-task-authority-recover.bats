#!/usr/bin/env bats

# Tests for legacy task-authority recovery. Each behavior gets a focused test
# with a readable setup so reviewers can see the contract at a glance.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/legacy-task-authority-recover.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/workflow" \
             "$PROJECT/正文" \
             "$PROJECT/大纲" \
             "$PROJECT/细纲" \
             "$PROJECT/设定"
    # Project-neutral content: short, non-bookish notes that exercise hashing
    # without leaking any real-story wording.
    printf 'story content A\n' > "$PROJECT/正文/a.md"
    printf 'outline content A\n' > "$PROJECT/大纲/a.md"
    printf 'detailed outline A\n' > "$PROJECT/细纲/a.md"
    printf 'setting content A\n' > "$PROJECT/设定/a.md"
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        'legacy_checkpoint_20260101' \
        'legacy continuity repair' \
        'do not use'
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_legacy_task() {
    local file="$1"
    local task_id="$2"
    local task_type="$3"
    local resume_command="$4"
    cat > "$file" <<JSON
{"task_id":"$task_id","task_type":"$task_type","status":"phase_pending","resume_command":"$resume_command","next_steps":[{"step_id":"next","status":"pending"}]}
JSON
}

# Compute a stable, deterministic hash of every byte under the listed
# directories so we can prove preview/confirm never mutate anything.
hash_tree() {
    local root="$1"
    find "$root" -type f ! -path '*/.git/*' -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256
}

hash_creative_tree() {
    local root="$1"
    find "$root/正文" "$root/大纲" "$root/细纲" "$root/设定" -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256
}

run_recover() {
    local command="$1"; shift
    node "$SCRIPT" "$command" --project-root "$PROJECT" "$@" --json
}

# --- (a) preview is read-only, deterministic, and carries 4 numbered options with visible text ---

@test "preview is read-only and deterministic with 4 numbered options and exact confirm command" {
    local tree_before
    tree_before="$(hash_tree "$PROJECT")"

    local preview_a
    local preview_b
    preview_a="$(run_recover preview --resume-intent 'continue the current draft')"
    preview_b="$(run_recover preview --resume-intent 'continue the current draft')"

    local tree_after
    tree_after="$(hash_tree "$PROJECT")"

    if [[ "$tree_before" != "$tree_after" ]]; then
        echo "preview mutated the project tree"
        diff <(echo "$tree_before") <(echo "$tree_after")
        return 1
    fi

    local preview_id_a
    local preview_id_b
    preview_id_a="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview_a")"
    preview_id_b="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview_b")"
    if [[ -z "$preview_id_a" || "$preview_id_a" != "$preview_id_b" ]]; then
        echo "preview_id is not deterministic: $preview_id_a vs $preview_id_b"
        return 1
    fi
    if [[ "$preview_id_a" =~ [^A-Za-z0-9._-] ]]; then
        echo "preview_id contains unsafe characters: $preview_id_a"
        return 1
    fi

    local preview_status
    preview_status="$(node -e 'console.log(JSON.parse(process.argv[1]).status)' "$preview_a")"
    if [[ "$preview_status" != "legacy_task_authority_recovery_preview" ]]; then
        echo "unexpected preview status: $preview_status"
        return 1
    fi

    node - "$preview_a" "$preview_id_a" <<'NODE'
const assert = require('assert');
const [preview, expectedId] = process.argv.slice(2);
const out = JSON.parse(preview);
assert.equal(out.preview_id, expectedId, 'preview_id must round-trip');
assert.equal(out.visible_response.selection_contract, 'execute_command_or_route_intent');
const visible = out.visible_response || {};
assert.ok(typeof visible.text === 'string' && visible.text.length > 0, 'visible_response.text must be renderable');
const options = Array.isArray(visible.options) ? visible.options : [];
assert.equal(options.length, 4, 'preview must carry exactly 4 numbered options');
for (let i = 0; i < options.length; i += 1) {
  assert.equal(options[i].number, i + 1, `option ${i + 1} must be numbered sequentially`);
}
const primary = options[0];
assert.equal(primary.interaction_mode, 'execute_command', 'option 1 must be executable');
assert.ok(primary.execution_command.includes('legacy-task-authority-recover.js confirm'), 'option 1 must include confirm command');
assert.ok(!/并恢复|应用/.test(primary.label || ''), 'preview option 1 must describe confirmation only');
assert.ok(primary.execution_command.includes('--preview-id'), 'option 1 must include --preview-id');
assert.ok(primary.execution_command.includes(expectedId), 'option 1 must include the matching preview_id');
assert.ok(primary.execution_command.includes('--resume-intent'), 'option 1 must echo --resume-intent');
NODE
}

@test "an exact legacy short task recovers as short_write instead of being promoted to long_write" {
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        'legacy_short_checkpoint_20260101' \
        'short_write' \
        'do not use'

    local preview
    preview="$(run_recover preview --resume-intent 'continue the current short draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current short draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local applied
    applied="$(run_recover apply --resume-intent 'continue the current short draft' --snapshot "$snapshot_path")"

    node - "$PROJECT" "$applied" "$snapshot_path" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, output, snapshotRel] = process.argv.slice(2);
const result = JSON.parse(output);
assert.equal(result.status, 'legacy_task_authority_recovered');
assert.equal(result.successor_workflow_type, 'short_write');
const snapshot = JSON.parse(fs.readFileSync(path.join(root, snapshotRel), 'utf8'));
assert.equal(snapshot.successor_workflow_type, 'short_write');
const task = JSON.parse(fs.readFileSync(path.join(root, result.successor_task_dir, 'task.json'), 'utf8'));
assert.equal(task.workflow_type, 'short_write');
NODE
}

@test "an exact legacy review task preserves review_repair through recovery" {
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        'legacy_review_checkpoint_20260101' \
        'review_repair' \
        'do not use'

    local preview
    preview="$(run_recover preview --resume-intent '审阅第1至3章')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent '审阅第1至3章' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    run run_recover apply --resume-intent '审阅第1至3章' --snapshot "$snapshot_path"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    local applied="$output"

    node - "$PROJECT" "$applied" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, output] = process.argv.slice(2);
const result = JSON.parse(output);
assert.equal(result.status, 'legacy_task_authority_recovered');
assert.equal(result.successor_workflow_type, 'review_repair');
const task = JSON.parse(fs.readFileSync(path.join(root, result.successor_task_dir, 'task.json'), 'utf8'));
assert.equal(task.workflow_type, 'review_repair');
NODE
}

@test "a legacy review task without a numeric scope remains read-only at preview" {
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        'legacy_review_scope_missing_20260101' \
        'review_repair' \
        'do not use'

    run run_recover preview --resume-intent '审阅当前正文'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    node - "$output" <<'NODE'
const assert = require('assert');
const out = JSON.parse(process.argv[2]);
assert.equal(out.status, 'blocked_legacy_review_scope_required');
assert.equal(out.read_only, true);
assert.equal(out.visible_response.selection_contract, 'route_intent_only');
assert.equal(JSON.stringify(out.visible_response.options).includes('execution_command'), false);
assert.match(out.visible_response.text, /第.*章|范围/u);
NODE
}

@test "an unrecognized legacy type returns a read-only explanation without a recovery command" {
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        'legacy_unknown_checkpoint_20260101' \
        'unknown prose task' \
        'do not use'

    run run_recover preview --resume-intent 'continue the current draft'
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    node - "$output" <<'NODE'
const assert = require('assert');
const value = JSON.parse(process.argv[2]);
assert.equal(value.status, 'blocked_legacy_task_type_confirmation_required');
assert.equal(value.read_only, true);
assert.equal(value.visible_response.selection_contract, 'route_intent_only');
assert.equal(JSON.stringify(value.visible_response.options).includes('execution_command'), false);
assert.match(value.visible_response.text, /任务类型/u);
NODE
}


# --- (b) unsafe task_id and symlinked root/workflow/archive/snapshot paths fail closed ---

@test "unsafe task_id fails closed before any writes" {
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        '../escape-2026' \
        'legacy continuity repair' \
        'do not use'

    local tree_before
    tree_before="$(hash_tree "$PROJECT")"

    run run_recover preview --resume-intent 'continue the current draft'

    local tree_after
    tree_after="$(hash_tree "$PROJECT")"

    if [[ "$tree_before" != "$tree_after" ]]; then
        echo "preview with unsafe task_id still wrote to the tree"
        return 1
    fi
    if [[ "$status" -eq 0 ]]; then
        echo "unsafe task_id did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "unsafe task_id did not return blocked status: $output"
        return 1
    fi
}

@test "symlinked project root fails closed before writes" {
    # The symlink target must point outside the project so a realpath/lstat
    # containment check has a reason to reject it.
    local outside="$TMP_DIR/outside-project"
    mkdir -p "$outside/正文"
    printf 'outside\n' > "$outside/正文/a.md"
    local linked="$TMP_DIR/book-link"
    ln -s "$outside" "$linked"
    run node "$SCRIPT" preview --project-root "$linked" --resume-intent 'continue the current draft' --json
    if [[ "$status" -eq 0 ]]; then
        echo "symlinked root did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "symlinked root did not return blocked status: $output"
        return 1
    fi
}

@test "symlinked workflow directory fails closed before writes" {
    # Place a current-task.json outside the project and link the workflow dir
    # to that external location. path.resolve alone would still appear
    # contained; only a realpath/lstat check catches this.
    local outside="$TMP_DIR/outside-workflow"
    mkdir -p "$outside/正文"
    printf 'outside\n' > "$outside/正文/a.md"
    printf '{"task_id":"legacy_checkpoint_20260101","task_type":"legacy continuity repair","status":"phase_pending","resume_command":"do not use","next_steps":[{"step_id":"next","status":"pending"}]}' \
        > "$outside/current-task.json"
    rm -f "$PROJECT/追踪/workflow/current-task.json"
    ln -s "$outside" "$PROJECT/追踪/workflow"
    run node "$SCRIPT" preview --project-root "$PROJECT" --resume-intent 'continue the current draft' --json
    if [[ "$status" -eq 0 ]]; then
        echo "symlinked workflow dir did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "symlinked workflow dir did not return blocked status: $output"
        return 1
    fi
}

@test "symlinked snapshot path fails closed before writes" {
    # Apply reads the snapshot via the user-provided --snapshot path. If
    # that path traverses a symlink that escapes the project, recovery
    # must refuse to follow it. We first produce a real snapshot through
    # the canonical path, then build a symlinked alias that points outside
    # and try to apply through it.
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Build an escape symlink inside the project that points outside, and
    # synthesize a snapshot path that traverses it. We then pre-stage a
    # foreign snapshot there so apply has something to try to read.
    local outside="$TMP_DIR/outside-snap"
    mkdir -p "$outside"
    mkdir -p "$PROJECT/追踪/workflow"
    ln -s "$outside" "$PROJECT/追踪/workflow/escape"
    local symlinked_path="追踪/workflow/escape/${snapshot_path##*/}"
    cp "$PROJECT/$snapshot_path" "$outside/${snapshot_path##*/}"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$symlinked_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "symlinked snapshot path did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "symlinked snapshot path did not return blocked status: $output"
        return 1
    fi
}

@test "symlinked archive directory fails closed before writes" {
    mkdir -p "$TMP_DIR/external-archive"
    local rel_archive="$PROJECT/追踪/workflow/archived"
    mkdir -p "$PROJECT/追踪/workflow"
    rmdir "$rel_archive" 2>/dev/null || true
    # Confirm first to try to write a snapshot pointing at a symlinked archive.
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    ln -s "$TMP_DIR/external-archive" "$rel_archive"
    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --preview-id "$preview_id" --confirm --json
    if [[ "$status" -eq 0 ]]; then
        echo "symlinked archive did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "symlinked archive did not return blocked status: $output"
        return 1
    fi
}

# --- (c) malformed or already-authoritative records fail closed ---

@test "malformed current-task.json fails closed before any writes" {
    printf 'this is not valid json' > "$PROJECT/追踪/workflow/current-task.json"

    local tree_before
    tree_before="$(hash_tree "$PROJECT")"

    run run_recover preview --resume-intent 'continue the current draft'

    local tree_after
    tree_after="$(hash_tree "$PROJECT")"
    if [[ "$tree_before" != "$tree_after" ]]; then
        echo "malformed preview still wrote to the tree"
        return 1
    fi
    if [[ "$status" -eq 0 ]]; then
        echo "malformed current-task.json did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "malformed current-task.json did not return blocked status: $output"
        return 1
    fi
}

@test "current-task.json that already carries workflow_id fails closed" {
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-existing","task_dir":"追踪/workflow/tasks/wf-existing","focused_at":"2026-08-04T00:00:00.000Z","state_version":3}
JSON

    local tree_before
    tree_before="$(hash_tree "$PROJECT")"

    run run_recover preview --resume-intent 'continue the current draft'

    local tree_after
    tree_after="$(hash_tree "$PROJECT")"
    if [[ "$tree_before" != "$tree_after" ]]; then
        echo "already-authoritative preview still wrote to the tree"
        return 1
    fi
    if [[ "$status" -eq 0 ]]; then
        echo "already-authoritative record did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "already-authoritative record did not return blocked status: $output"
        return 1
    fi
}

@test "missing current-task.json fails closed before writes" {
    rm -f "$PROJECT/追踪/workflow/current-task.json"

    local tree_before
    tree_before="$(hash_tree "$PROJECT")"

    run run_recover preview --resume-intent 'continue the current draft'

    local tree_after
    tree_after="$(hash_tree "$PROJECT")"
    if [[ "$tree_before" != "$tree_after" ]]; then
        echo "missing-source preview still wrote to the tree"
        return 1
    fi
    if [[ "$status" -eq 0 ]]; then
        echo "missing current-task.json did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "missing current-task.json did not return blocked status: $output"
        return 1
    fi
}

# --- (d) confirm creates exactly one non-overwriting snapshot with intent binding ---

@test "confirm creates one snapshot, refuses overwrites, binds the intent" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    # First confirm writes the snapshot.
    local confirm_output
    confirm_output="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"
    local snapshot_path
    snapshot_path="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)' <<<"$confirm_output")"
    if [[ -z "$snapshot_path" ]]; then
        echo "confirm did not return a snapshot_path"
        return 1
    fi
    if [[ ! -f "$PROJECT/$snapshot_path" ]]; then
        echo "snapshot file is missing on disk: $snapshot_path"
        return 1
    fi
    local hash_after_first
    hash_after_first="$(shasum -a 256 "$PROJECT/$snapshot_path" | awk '{print $1}')"

    # Mutating the snapshot file out from under recovery must reject re-confirm.
    printf '{"tampered":true}' > "$PROJECT/$snapshot_path"
    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --preview-id "$preview_id" --confirm --json
    if [[ "$status" -eq 0 ]]; then
        echo "confirm overwrote the existing snapshot: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "confirm conflict did not return blocked status: $output"
        return 1
    fi
    # The tampered bytes must remain — confirm did not rewrite them.
    if [[ "$(cat "$PROJECT/$snapshot_path")" != '{"tampered":true}' ]]; then
        echo "confirm tampered with the existing snapshot file"
        return 1
    fi
    # Restore the original snapshot so the rest of the case can run.
    rm -f "$PROJECT/$snapshot_path"
    local confirm_restore
    confirm_restore="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"
    local snapshot_path_2
    snapshot_path_2="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)' <<<"$confirm_restore")"
    if [[ "$snapshot_path_2" != "$snapshot_path" ]]; then
        echo "snapshot path changed across confirms: $snapshot_path vs $snapshot_path_2"
        return 1
    fi

    # Idempotent re-confirm (without tampering) must not change the
    # canonical snapshot bytes. The implementation must detect the existing
    # snapshot and skip the write step.
    local hash_before_idempotent
    hash_before_idempotent="$(shasum -a 256 "$PROJECT/$snapshot_path" | awk '{print $1}')"
    run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm > /dev/null
    local hash_idempotent
    hash_idempotent="$(shasum -a 256 "$PROJECT/$snapshot_path" | awk '{print $1}')"
    if [[ "$hash_before_idempotent" != "$hash_idempotent" ]]; then
        echo "idempotent confirm mutated the snapshot: $hash_before_idempotent vs $hash_idempotent"
        return 1
    fi

    # Different intent must require a fresh preview.
    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'a different goal' \
        --preview-id "$preview_id" --confirm --json
    if [[ "$status" -eq 0 ]]; then
        echo "different intent did not require a fresh preview: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "different intent did not return blocked status: $output"
        return 1
    fi

    node - "$PROJECT" "$snapshot_path" "continue the current draft" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, snapshotPath, intent] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, snapshotPath), 'utf8'));
if (snap.resume_intent !== intent) throw new Error('intent must be persisted in the snapshot');
if (snap.status !== 'confirmed') throw new Error('snapshot status must be confirmed');
if (!snap.preview_id || !snap.source_hash) throw new Error('snapshot must capture preview_id and source_hash');
NODE
}

# --- (e) apply archives original bytes exactly, creates long_write, uses exact intent ---

@test "apply archives original bytes exactly and creates long_write successor via state machine" {
    local source_bytes
    source_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"

    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    local apply_output
    apply_output="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"

    local apply_status
    apply_status="$(node -e 'console.log(JSON.parse(process.argv[1]).status)' "$apply_output")"
    if [[ "$apply_status" != "legacy_task_authority_recovered" ]]; then
        echo "apply did not report success: $apply_status"
        echo "$apply_output"
        return 1
    fi

    local archive_path="$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json"
    if [[ ! -f "$archive_path" ]]; then
        echo "archive file is missing: $archive_path"
        return 1
    fi

    local archived_bytes
    archived_bytes="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
    if [[ "$source_bytes" != "$archived_bytes" ]]; then
        echo "archive bytes differ from source: $source_bytes vs $archived_bytes"
        return 1
    fi

    node - "$PROJECT" "$apply_output" "continue the current draft" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, applyText, intent] = process.argv.slice(2);
const applied = JSON.parse(applyText);
const successorId = applied.successor_workflow_id;
assert.ok(successorId, 'apply must report successor_workflow_id');
const taskDir = path.join('追踪/workflow/tasks', successorId);
const task = JSON.parse(fs.readFileSync(path.join(root, taskDir, 'task.json'), 'utf8'));
assert.equal(task.workflow_type, 'long_write', 'successor workflow_type must be long_write');
assert.equal(task.user_goal, intent, 'successor user_goal must equal --resume-intent verbatim');
assert.notEqual(task.user_goal, 'do not use', 'successor user_goal must NOT be the legacy resume_command');
assert.equal(task.lifecycle && task.lifecycle.switch_reason, 'legacy_task_authority_recovery',
  'successor must durably identify legacy task authority recovery');
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
assert.equal(pointer.workflow_id, successorId, 'focus pointer must reference the new successor');
assert.equal(pointer.task_dir, taskDir, 'focus pointer must reference the new task_dir');
assert.ok(applied.visible_response && typeof applied.visible_response.text === 'string' && applied.visible_response.text.length > 0,
  'apply must emit a renderable visible_response.text');
NODE
}

@test "allowlisted outline_backfill preview is read-only and apply archives bytes without creative drift" {
    local intent='resume neutral outline maintenance'
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"type":"outline_backfill","action_id":"outline-backfill-action-001","status":"running","target_files":["大纲/第1卷/卷纲.md","大纲/第1卷/章节索引.md"]}
JSON
    mkdir -p "$PROJECT/大纲/第1卷"
    printf 'neutral outline\n' > "$PROJECT/大纲/第1卷/卷纲.md"

    local source_hash creative_before tree_before
    source_hash="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"
    creative_before="$(hash_creative_tree "$PROJECT")"
    tree_before="$(hash_tree "$PROJECT")"

    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    if [[ "$tree_before" != "$(hash_tree "$PROJECT")" ]]; then
        echo "outline_backfill preview mutated the project"
        return 1
    fi
    local preview_id normalized_task_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    normalized_task_id="$(node -e 'console.log(JSON.parse(process.argv[1]).task_id)' "$preview")"
    if [[ ! "$normalized_task_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "generated task_id is unsafe: $normalized_task_id"
        return 1
    fi

    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local apply_output
    apply_output="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"

    local archive_path="$PROJECT/追踪/workflow/archived/$normalized_task_id.current-task.json"
    if [[ ! -f "$archive_path" ]]; then
        echo "outline_backfill archive is missing: $archive_path"
        return 1
    fi
    if [[ "$source_hash" != "$(shasum -a 256 "$archive_path" | awk '{print $1}')" ]]; then
        echo "outline_backfill archive bytes differ from source"
        return 1
    fi
    if [[ "$creative_before" != "$(hash_creative_tree "$PROJECT")" ]]; then
        echo "preview/confirm/apply mutated creative directories"
        return 1
    fi

    node - "$PROJECT" "$snapshot_path" "$apply_output" "$intent" "$normalized_task_id" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, snapshotPath, applyText, intent, normalizedTaskId] = process.argv.slice(2);
const snapshot = JSON.parse(fs.readFileSync(path.join(root, snapshotPath), 'utf8'));
assert.equal(snapshot.source_task_id, normalizedTaskId);
assert.equal(snapshot.source_task_type, 'outline_backfill');
const applied = JSON.parse(applyText);
const successorId = applied.successor_workflow_id;
assert.ok(successorId, 'apply must report successor_workflow_id');
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks', successorId, 'task.json'), 'utf8'));
assert.equal(task.workflow_type, 'long_write');
assert.equal(task.user_goal, intent);
assert.equal(task.lifecycle && task.lifecycle.switch_reason, 'legacy_task_authority_recovery');
NODE
}

@test "outline_backfill with unsafe target path remains blocked" {
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"type":"outline_backfill","action_id":"outline-backfill-action-unsafe","status":"running","target_files":["大纲/../正文/a.md"]}
JSON

    run run_recover preview --resume-intent 'resume neutral outline maintenance'

    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_legacy_task_authority_recovery'* ]]
    [[ "$output" == *'unsafe path'* ]]
}

# --- (f) source drift and protected asset drift reject before mutation ---

@test "current-task.json drift after confirm rejects apply and restores nothing" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Drift the source between confirm and apply.
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        'drifted_checkpoint_20260102' 'legacy continuity repair' 'do not use'

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "drifted source did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "drifted source did not return blocked status: $output"
        return 1
    fi

    # No archive file may have been written; the focus pointer must not be replaced.
    if [[ -f "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" ]]; then
        echo "drifted source wrote an archive file before failing closed"
        return 1
    fi
    if [[ ! -f "$PROJECT/追踪/workflow/current-task.json" ]]; then
        echo "drifted source removed the current-task.json before failing closed"
        return 1
    fi
}

@test "protected asset drift after confirm rejects apply" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    printf 'mutated content\n' > "$PROJECT/正文/a.md"
    printf 'mutated outline\n' > "$PROJECT/大纲/a.md"
    printf 'mutated setting\n' > "$PROJECT/设定/a.md"
    printf 'mutated detailed outline\n' > "$PROJECT/细纲/a.md"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "protected asset drift did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "protected asset drift did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'drift'* ]]; then
        echo "drift error message must mention drift: $output"
        return 1
    fi
}

# --- (g) archive/snapshot conflict rejects without overwrite ---

@test "snapshot conflict rejects without overwriting" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm > /dev/null
    local snapshot_path
    snapshot_path="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)' \
        < <(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm))"

    local hash_before
    hash_before="$(shasum -a 256 "$PROJECT/$snapshot_path" | awk '{print $1}')"

    # Replace the snapshot with a foreign payload and re-confirm with the
    # matching intent; recovery must refuse and not overwrite.
    printf '{"tampered":"yes"}' > "$PROJECT/$snapshot_path"
    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --preview-id "$preview_id" --confirm --json
    if [[ "$status" -eq 0 ]]; then
        echo "snapshot conflict did not fail closed: $output"
        return 1
    fi
    local hash_after
    hash_after="$(shasum -a 256 "$PROJECT/$snapshot_path" | awk '{print $1}')"
    if [[ "$hash_before" == "$hash_after" ]]; then
        echo "snapshot was overwritten despite conflict"
        return 1
    fi
    if [[ "$(cat "$PROJECT/$snapshot_path")" != '{"tampered":"yes"}' ]]; then
        echo "foreign snapshot was modified by confirm attempt"
        return 1
    fi
}

@test "archive conflict rejects apply without overwriting" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    mkdir -p "$PROJECT/追踪/workflow/archived"
    printf '{"archive":"foreign"}' > "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "archive conflict did not fail closed: $output"
        return 1
    fi
    if [[ "$(cat "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json")" != '{"archive":"foreign"}' ]]; then
        echo "apply overwrote the foreign archive entry"
        return 1
    fi
}

# --- (h) injected successor creation failure restores original current-task bytes ---

@test "successor creation failure restores the original current-task bytes" {
    local source_bytes
    source_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"

    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL=successor_create \
        run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
            --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "injected successor failure did not surface: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "injected successor failure did not return blocked status: $output"
        return 1
    fi

    # Original current-task.json bytes must be byte-identical to what we had.
    local restored_bytes
    restored_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"
    if [[ "$source_bytes" != "$restored_bytes" ]]; then
        echo "current-task.json bytes were not restored: $source_bytes vs $restored_bytes"
        return 1
    fi

    # No archive file should exist after a failed apply; nothing may have been
    # promoted to the workflow state machine.
    if [[ -f "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" ]]; then
        echo "failed apply still wrote an archive entry"
        return 1
    fi
}

# --- (i) repeated confirm/apply is idempotent and returns the same successor plus a visible continuation ---

@test "repeated apply is idempotent and returns the same successor plus a visible response" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    local first
    first="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local second
    second="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"

    local first_id
    local second_id
    first_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first")"
    second_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$second")"
    if [[ -z "$first_id" || "$first_id" != "$second_id" ]]; then
        echo "apply is not idempotent: $first_id vs $second_id"
        return 1
    fi

    local first_status
    local second_status
    first_status="$(node -e 'console.log(JSON.parse(process.argv[1]).status)' "$first")"
    second_status="$(node -e 'console.log(JSON.parse(process.argv[1]).status)' "$second")"
    if [[ "$first_status" != "legacy_task_authority_recovered" || "$second_status" != "legacy_task_authority_recovered" ]]; then
        echo "expected both applies to report success: $first_status / $second_status"
        return 1
    fi

    # Focus pointer must continue to resolve through the official authority.
    local tree_after
    tree_after="$(hash_tree "$PROJECT")"
    if [[ -z "$tree_after" ]]; then
        echo "hash_tree failed"
        return 1
    fi

    node - "$PROJECT" "$first_id" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, expectedId] = process.argv.slice(2);
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
assert.equal(pointer.workflow_id, expectedId);
const taskFile = path.join(root, '追踪/workflow/tasks', expectedId, 'task.json');
assert.ok(fs.existsSync(taskFile), 'durable successor task must exist for idempotent reapply');
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
assert.equal(task.workflow_type, 'long_write');
assert.equal(task.user_goal, 'continue the current draft');
NODE

    # Both responses must surface renderable, actionable content.
    node - "$first" "$second" <<'NODE'
const assert = require('assert');
const [a, b] = process.argv.slice(2);
for (const [label, value] of [['first', a], ['second', b]]) {
  const out = JSON.parse(value);
  assert.ok(out.visible_response && typeof out.visible_response.text === 'string' && out.visible_response.text.length > 0,
    `${label} apply must include renderable visible_response.text`);
  const options = (out.visible_response.options || []);
  assert.ok(options.length > 0, `${label} apply must include visible_response.options`);
  const primary = options.find(option => option.number === 1) || options[0];
  assert.equal(primary.interaction_mode, 'execute_command', `${label} primary option must be executable`);
  assert.ok(primary.execution_command && primary.execution_command.length > 0, `${label} primary option must carry execution_command`);
}
NODE
}

# --- (j) Defect 1: symlinked project root must reject by symlink, not by missing source ---

@test "symlinked project root rejects by symlink reason when the target is a complete legacy project" {
    # The previous fixture only had an outside/正文/a.md stub, so the test
    # passed for the wrong reason (missing current-task). Rebuild the target
    # as a complete valid legacy project so the only way the script can
    # reject is by detecting the symlink at the project root.
    local outside="$TMP_DIR/outside-project"
    mkdir -p "$outside/追踪/workflow" \
             "$outside/正文" \
             "$outside/大纲" \
             "$outside/细纲" \
             "$outside/设定"
    printf 'story content A\n' > "$outside/正文/a.md"
    printf 'outline content A\n' > "$outside/大纲/a.md"
    printf 'detailed outline A\n' > "$outside/细纲/a.md"
    printf 'setting content A\n' > "$outside/设定/a.md"
    cat > "$outside/追踪/workflow/current-task.json" <<JSON
{"task_id":"legacy_checkpoint_20260101","task_type":"legacy continuity repair","status":"phase_pending","resume_command":"do not use","next_steps":[{"step_id":"next","status":"pending"}]}
JSON
    local linked="$TMP_DIR/book-link"
    ln -s "$outside" "$linked"

    run node "$SCRIPT" preview --project-root "$linked" --resume-intent 'continue the current draft' --json
    if [[ "$status" -eq 0 ]]; then
        echo "symlinked root with a complete target must fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "symlinked root did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'symlink'* ]]; then
        echo "symlinked root rejection did not mention symlink: $output"
        return 1
    fi
}

# --- (k) Defect 2: idempotent confirm returns a distinct apply visible_response, not a confirm prompt ---

@test "idempotent confirm returns an exact apply visible_response for the same canonical snapshot" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    # First confirm materializes the snapshot.
    local first
    first="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"
    local snapshot_path
    snapshot_path="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)' <<<"$first")"

    # Second confirm with the same canonical snapshot must be idempotent:
    # visible_response must reflect the apply step (option 1 carries an exact
    # apply command referencing --snapshot and the matching --resume-intent),
    # not a third confirm prompt that would loop the user.
    local second
    second="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"

    node - "$second" "$snapshot_path" "continue the current draft" <<'NODE'
const assert = require('assert');
const [confirmText, snapshotPath, intent] = process.argv.slice(2);
const out = JSON.parse(confirmText);
assert.equal(out.status, 'legacy_task_authority_recovery_confirmed');
assert.equal(out.changed, false, 'idempotent confirm must not report changed=true');
assert.ok(out.visible_response, 'idempotent confirm must include visible_response');
const options = out.visible_response.options || [];
const primary = options.find(option => option.number === 1) || options[0];
assert.ok(primary, 'idempotent confirm must surface option 1');
assert.equal(primary.interaction_mode, 'execute_command', 'option 1 must be executable');
assert.ok(primary.execution_command.includes('apply'), 'option 1 must drive the apply step, not another confirm');
assert.ok(primary.execution_command.includes('--snapshot'), 'option 1 must include --snapshot');
assert.ok(primary.execution_command.includes(snapshotPath), 'option 1 must reference the canonical snapshot');
assert.ok(primary.execution_command.includes('--resume-intent'), 'option 1 must include --resume-intent');
assert.ok(primary.execution_command.includes(`'${intent}'`), 'option 1 must echo the original intent verbatim');
assert.ok(out.visible_response.text && out.visible_response.text.includes('apply') || (primary.label || '').includes('应用'),
  'visible_response must say apply, not confirm again');
NODE
}

# --- (l) Defect 3: archive conflict must preflight before any mutation ---

@test "archive conflict preflights before deleting current-task or creating any successor" {
    local source_bytes
    source_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"

    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Plant a foreign archive entry that pre-collides with the recovery archive.
    mkdir -p "$PROJECT/追踪/workflow/archived"
    printf '{"archive":"foreign"}' > "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json"
    local foreign_archive_bytes
    foreign_archive_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" | awk '{print $1}')"
    local tasks_count_before
    tasks_count_before="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    # Capture the project tree AFTER planting the foreign archive but BEFORE
    # running apply. Anything apply does afterwards must be reflected as a
    # delta against this baseline.
    local tree_before
    tree_before="$(hash_tree "$PROJECT")"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "archive conflict did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "archive conflict did not return blocked status: $output"
        return 1
    fi

    # (i) current-task.json bytes must remain identical — preflight refused to delete it.
    local restored_bytes
    restored_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"
    if [[ "$source_bytes" != "$restored_bytes" ]]; then
        echo "current-task.json bytes were mutated before archive preflight: $source_bytes vs $restored_bytes"
        return 1
    fi

    # (ii) the foreign archive entry must NOT have been overwritten.
    local archive_now
    archive_now="$(shasum -a 256 "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" | awk '{print $1}')"
    if [[ "$foreign_archive_bytes" != "$archive_now" ]]; then
        echo "foreign archive entry was overwritten: $foreign_archive_bytes vs $archive_now"
        return 1
    fi

    # (iii) no new task directory may have been created under 追踪/workflow/tasks.
    local tasks_count_after
    tasks_count_after="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$tasks_count_before" != "$tasks_count_after" ]]; then
        echo "apply created a successor task before archive preflight: $tasks_count_before vs $tasks_count_after"
        return 1
    fi

    # (iv) the full project tree must remain byte-identical (excluding the
    # foreign archive that we just planted, which is the only acceptable
    # difference from the pre-apply baseline).
    local tree_after
    tree_after="$(hash_tree "$PROJECT")"
    if [[ "$tree_before" != "$tree_after" ]]; then
        echo "apply mutated the project tree before archive preflight"
        diff <(echo "$tree_before") <(echo "$tree_after")
        return 1
    fi
}

# --- (m) Defect 4: snapshot must bind the exact successor and reapply must not accept a same-goal task ---

@test "apply persists applied/successor_workflow_id and reapply rejects a same-goal but unrelated task" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # First apply materializes the canonical successor and must mark the
    # snapshot applied with the exact successor bound.
    local first_apply
    first_apply="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local first_successor
    first_successor="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first_apply")"

    node - "$PROJECT" "$snapshot_path" "$first_successor" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, snapshotPath, expectedSuccessor] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, snapshotPath), 'utf8'));
assert.equal(snap.status, 'applied', 'successful apply must persist status=applied');
assert.equal(snap.successor_workflow_id, expectedSuccessor,
  'successful apply must persist the exact successor_workflow_id bound to the snapshot');
assert.ok(snap.successor_task_dir, 'successful apply must persist successor_task_dir');
assert.ok(snap.archive_path, 'successful apply must persist archive_path');
assert.ok(snap.archive_sha256, 'successful apply must persist archive_sha256');
NODE

    # Now create a *different* long_write task with the same user_goal and
    # tamper with the focus pointer so it points at this unrelated task.
    # Reapply must refuse this — the snapshot is bound to first_successor,
    # not to any same-goal task.
    local other_id="long_write_unrelated_$(date +%s%N | head -c 14)"
    mkdir -p "$PROJECT/追踪/workflow/tasks/$other_id"
    cat > "$PROJECT/追踪/workflow/tasks/$other_id/task.json" <<JSON
{"workflow_id":"$other_id","workflow_type":"long_write","user_goal":"continue the current draft","task_dir":"追踪/workflow/tasks/$other_id","state_version":1,"status":"running"}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<JSON
{"schemaVersion":"1.0.0","workflow_id":"$other_id","task_dir":"追踪/workflow/tasks/$other_id","focused_at":"2026-08-04T00:00:00.000Z","state_version":1}
JSON

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "reapply accepted a same-goal but unrelated task: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "reapply against unrelated task did not return blocked status: $output"
        return 1
    fi

    # The apply response must NOT claim the unrelated task was recovered:
    # no successor_workflow_id may equal the unrelated id.
    node - "$output" "$other_id" "$first_successor" <<'NODE'
const assert = require('assert');
const [responseText, unrelatedId, expectedSuccessor] = process.argv.slice(2);
const out = JSON.parse(responseText);
assert.notEqual(out.successor_workflow_id, unrelatedId,
  'reapply must not promote the unrelated same-goal task to recovered successor');
assert.notEqual(out.successor_workflow_id, expectedSuccessor,
  'reapply must not pretend the canonical successor was recovered when the pointer disagrees');
NODE
}

# --- (n) Defect 5: official authority delegation rejects malformed focus pointers ---

@test "apply validates the post-create focus pointer through official task authority" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Simulate a stale focus pointer: the durable task.json under the path
    # carries a workflow_id that does not match the directory name, so the
    # official authority (resolveTaskAuthority) must reject it. A naive
    # direct read of task.json would happily accept this.
    local stale_id="long_write_stale_$(date +%s%N | head -c 14)"
    local other_id="long_write_other_$(date +%s%N | head -c 14)"
    mkdir -p "$PROJECT/追踪/workflow/tasks/$stale_id"
    cat > "$PROJECT/追踪/workflow/tasks/$stale_id/task.json" <<JSON
{"workflow_id":"$other_id","workflow_type":"long_write","user_goal":"continue the current draft","task_dir":"追踪/workflow/tasks/$stale_id","state_version":1,"status":"running"}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<JSON
{"schemaVersion":"1.0.0","workflow_id":"$stale_id","task_dir":"追踪/workflow/tasks/$stale_id","focused_at":"2026-08-04T00:00:00.000Z","state_version":1}
JSON

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "stale focus pointer did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "stale focus pointer did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'authority'* && "$output" != *'stale'* && "$output" != *'mismatch'* && "$output" != *'pointer'* ]]; then
        echo "stale pointer error must mention authority/stale/mismatch/pointer: $output"
        return 1
    fi
}

# --- (o) Defect 6: snapshot path is restricted to canonical archived location with full content validation ---

@test "snapshot path validation rejects forged paths and foreign snapshots" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # (i) Forged relative path outside the canonical archive directory.
    mkdir -p "$PROJECT/追踪/workflow/forge"
    cp "$PROJECT/$snapshot_path" "$PROJECT/追踪/workflow/forge/legacy-recovery-${preview_id}.json"
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "追踪/workflow/forge/legacy-recovery-${preview_id}.json" --json
    if [[ "$status" -eq 0 ]]; then
        echo "forged snapshot path did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "forged snapshot path did not return blocked status: $output"
        return 1
    fi

    # (ii) Filename preview id mismatch — use a snapshot at the canonical
    # location but with a different filename preview id. The replacement
    # id must fail the safety check so the script rejects it before reading
    # the file content. macOS HFS+/APFS is case-insensitive by default, so
    # we prepend an underscore to guarantee a distinct file path.
    local wrong_id="_${preview_id}"
    cp "$PROJECT/$snapshot_path" "$PROJECT/追踪/workflow/archived/legacy-recovery-${wrong_id}.json"
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "追踪/workflow/archived/legacy-recovery-${wrong_id}.json" --json
    if [[ "$status" -eq 0 ]]; then
        echo "wrong preview id in filename did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "wrong preview id in filename did not return blocked status: $output"
        return 1
    fi
    rm -f "$PROJECT/追踪/workflow/archived/legacy-recovery-${wrong_id}.json"

    # (iii) Foreign snapshot content: the canonical filename preview id, but
    # the file content carries a foreign project_root and a different source
    # hash. The script must refuse to trust it.
    local foreign="$PROJECT/追踪/workflow/archived/legacy-recovery-${preview_id}.json"
    node - "$PROJECT" "$foreign" "$preview_id" <<'NODE'
const fs = require('fs');
const [root, foreign, previewId] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(foreign, 'utf8'));
snap.project_root = '/var/folders/somewhere/else';
snap.source_hash = 'deadbeef';
fs.writeFileSync(foreign, JSON.stringify(snap, null, 2));
NODE
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "追踪/workflow/archived/legacy-recovery-${preview_id}.json" --json
    if [[ "$status" -eq 0 ]]; then
        echo "foreign snapshot content did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "foreign snapshot content did not return blocked status: $output"
        return 1
    fi
}

# --- (p) Defect 7: no NUL bytes in the JS source ---

@test "legacy-task-authority-recover.js source contains no NUL bytes" {
    node - "$SCRIPT" <<'NODE'
const fs = require('fs');
const [file] = process.argv.slice(2);
const buf = fs.readFileSync(file);
for (let i = 0; i < buf.length; i += 1) {
  if (buf[i] === 0) {
    console.error(`NUL byte at offset ${i} (line ${buf.slice(0, i).toString('utf8').split('\n').length})`);
    process.exit(1);
  }
}
process.exit(0);
NODE
}

# --- (q) Defect 8: dead code removal ---

@test "legacy-task-authority-recover.js no longer exposes a local writeFocusPointer nor a dead visibleResponse null" {
    node - "$SCRIPT" <<'NODE'
const fs = require('fs');
const [file] = process.argv.slice(2);
const src = fs.readFileSync(file, 'utf8');
// Defect 8a: no local function writeFocusPointer — delegation must go
// through the official scripts/lib/workflow-task-authority.js helper.
if (/function\s+writeFocusPointer\s*\(/.test(src)) {
  console.error('local writeFocusPointer function is still defined; must delegate to scripts/lib/workflow-task-authority.js');
  process.exit(1);
}
// Defect 8b: no dead visibleResponse null assignment — apply no longer
// fabricates a null variable.
if (/visibleResponse\s*=\s*\([^)]*\)\s*\?\s*null\s*:\s*null/.test(src)) {
  console.error('dead visibleResponse null assignment is still present in buildApplyResult');
  process.exit(1);
}
process.exit(0);
NODE
}

# --- (r) Defect A control flow: post-create failures must abort and not silently continue ---

@test "post-create authority failure aborts apply instead of silently continuing" {
    # First confirm creates the canonical snapshot, then inject a forced
    # post-create authority failure. The apply must NOT finalize as
    # 'legacy_task_authority_recovered'; it must throw blocked.
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL=successor_authority \
        run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
            --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "injected authority failure did not surface: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "authority failure did not return blocked status: $output"
        return 1
    fi
    # CRITICAL: status must NOT be legacy_task_authority_recovered (which would
    # mean the code happily continued after the failed verification).
    if [[ "$output" == *'legacy_task_authority_recovered'* ]]; then
        echo "apply continued after authority failure and falsely reported success"
        echo "$output"
        return 1
    fi
    # Snapshot must NOT be marked applied; the user must see the failure
    # instead of a fabricated success binding.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
assert.notEqual(snap.status, 'applied', 'apply must NOT mark the snapshot applied when post-create authority verification failed');
NODE
}

@test "post-create focus pointer failure aborts apply instead of silently continuing" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL=successor_pointer \
        run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
            --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "injected focus pointer failure did not surface: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "focus pointer failure did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" == *'legacy_task_authority_recovered'* ]]; then
        echo "apply continued after focus pointer failure and falsely reported success"
        return 1
    fi
}

# --- (s) Defect B: truthful failure metadata after post-create failures ---

@test "post-create failure leaves journal in applying with truthful failure metadata, not confirmed" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL=successor_authority \
        run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
            --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "authority failure did not surface: $output"
        return 1
    fi
    # The journal must be in applying/pending_recovery, NOT silently reverted
    # to confirmed (which would make the next apply believe the predecessor was
    # never created, breaking idempotency and losing the candidate binding).
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
assert.notEqual(snap.status, 'confirmed', 'journal must NOT be reverted to confirmed after a failed post-create verification');
assert.ok(['applying', 'needs_recovery'].includes(snap.status),
  `journal must remain in applying/needs_recovery, got ${snap.status}`);
assert.ok(snap.last_apply_error && snap.last_apply_error.length > 0,
  'journal must record truthful last_apply_error');
assert.ok(snap.last_apply_failed_at,
  'journal must record last_apply_failed_at timestamp');
assert.ok(snap.pending_recovery === true,
  'journal must signal pending_recovery=true for the next apply');
NODE
}

# --- (t) Defect C: runReapply must not bind any long_write pointer; exact candidate only ---

setup_applying_snapshot_with_candidate() {
    local intent="$1"
    local candidate_id="$2"
    local candidate_user_goal="$3"
    local preexisting_arg="${4:-}"
    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    # Plant a status=applying snapshot with an explicit candidate id so we can
    # exercise recovery decisions deterministically.
    node - "$PROJECT" "$snapshot_path" "$candidate_id" "$intent" "$candidate_user_goal" "$preexisting_arg" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, relSnap, candidateId, intent, candidateUserGoal, preexistingIds] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.successor_candidate_workflow_id = candidateId;
snap.successor_candidate_task_dir = `追踪/workflow/tasks/${candidateId}`;
snap.successor_candidate_user_goal = candidateUserGoal;
snap.preexisting_workflow_ids = preexistingIds ? preexistingIds.split(',').filter(Boolean) : [];
// Inject a real source_bytes_base64 if missing (read from current focus legacy).
if (!snap.source_bytes_base64) {
  // Read original legacy source from the archived source file. To keep this
  // helper self-contained, we rebuild it from the bytes that confirm would
  // have stored; tests below use fresh fixtures, so we synthesize from
  // current-task.json. If the focus pointer no longer matches the legacy
  // bytes, recovery should refuse anyway, so this is best-effort.
  delete snap.source_bytes_base64;
}
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    # Plant the candidate task directory if the test wants a bound candidate.
    mkdir -p "$PROJECT/追踪/workflow/tasks/$candidate_id"
    cat > "$PROJECT/追踪/workflow/tasks/$candidate_id/task.json" <<JSON
{"workflow_id":"$candidate_id","workflow_type":"long_write","user_goal":"$candidate_user_goal","task_dir":"追踪/workflow/tasks/$candidate_id","state_version":1,"status":"running"}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<JSON
{"schemaVersion":"1.0.0","workflow_id":"$candidate_id","task_dir":"追踪/workflow/tasks/$candidate_id","focused_at":"2026-08-04T00:00:00.000Z","state_version":1}
JSON
    echo "$snapshot_path"
}

@test "applying snapshot rejects a same-goal but unrelated long_write pointer" {
    # journal says candidate='wf-candidate'. The pointer is to 'wf-other' which
    # is also long_write with the same user_goal — recovery must refuse because
    # the pointer does not match the exact candidate.
    local snapshot_path
    snapshot_path="$(setup_applying_snapshot_with_candidate 'continue the current draft' 'wf-candidate' 'continue the current draft')"
    local other="wf-other-$(date +%s%N | head -c 14)"
    mkdir -p "$PROJECT/追踪/workflow/tasks/$other"
    cat > "$PROJECT/追踪/workflow/tasks/$other/task.json" <<JSON
{"workflow_id":"$other","workflow_type":"long_write","user_goal":"continue the current draft","task_dir":"追踪/workflow/tasks/$other","state_version":1,"status":"running"}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<JSON
{"schemaVersion":"1.0.0","workflow_id":"$other","task_dir":"追踪/workflow/tasks/$other","focused_at":"2026-08-04T00:00:00.000Z","state_version":1}
JSON

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "applying snapshot recovery accepted unrelated same-goal pointer: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "unrelated same-goal pointer did not return blocked status: $output"
        return 1
    fi
    # Must NOT pretend recovery succeeded by binding the unrelated pointer.
    node - "$output" "$other" <<'NODE'
const assert = require('assert');
const [responseText, otherId] = process.argv.slice(2);
const out = JSON.parse(responseText);
assert.notEqual(out.successor_workflow_id, otherId, 'recovery must NOT bind the unrelated pointer');
NODE
}

@test "applying snapshot only recovers the exact successor_candidate_workflow_id when it officially resolves" {
    local snapshot_path
    snapshot_path="$(setup_applying_snapshot_with_candidate 'continue the current draft' 'wf-candidate-match' 'continue the current draft')"
    # Pointer is already planted by setup at wf-candidate-match with the right
    # user_goal, so recovery should accept and bind.
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -ne 0 ]]; then
        echo "exact candidate recovery failed: $output"
        return 1
    fi
    if [[ "$output" != *'"successor_workflow_id": "wf-candidate-match"'* ]]; then
        echo "recovery did not bind the exact candidate: $output"
        return 1
    fi
}

@test "applying snapshot refuses to bind a candidate whose workflow_type or user_goal drifted" {
    # Plant a candidate with a wrong workflow_type or wrong user_goal so the
    # post-recovery official check has a reason to refuse.
    local snapshot_path
    snapshot_path="$(setup_applying_snapshot_with_candidate 'continue the current draft' 'wf-candidate-mismatch' 'WRONG_INTENT')"
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "user_goal drift was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "user_goal drift did not return blocked status: $output"
        return 1
    fi
}

@test "applying snapshot refuses a candidate that was already in preexisting_workflow_ids" {
    # Pretend the candidate id already existed before apply started; recovery
    # must refuse because the snapshot explicitly recorded it as preexisting.
    local snapshot_path
    snapshot_path="$(setup_applying_snapshot_with_candidate 'continue the current draft' 'wf-pre-existing-cand' 'continue the current draft' 'wf-pre-existing-cand')"
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "preexisting candidate was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "preexisting candidate did not return blocked status: $output"
        return 1
    fi
}

# --- (u) Defect D: first confirm visible text must reference apply step ---

@test "first confirm visible_response text itself contains the apply step" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local first
    first="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"
    node - "$first" <<'NODE'
const assert = require('assert');
const [confirmText] = process.argv.slice(2);
const out = JSON.parse(confirmText);
assert.ok(out.visible_response && typeof out.visible_response.text === 'string', 'visible_response.text must be a string');
const text = out.visible_response.text;
// Defect D: text line 1 MUST itself describe the apply step, not the original
// "确认并恢复任务权威（推荐）" preview label that buildRecoveryOptions baked in.
// The first numbered line of the rendered text must include apply/应用, so a
// user reading only the text understands that executing option 1 does apply,
// not another confirm.
const firstLine = text.split('\n')[0] || '';
assert.ok(/应用|apply/.test(firstLine), `first numbered line must itself say apply, got: ${firstLine}`);
const primary = (out.visible_response.options || []).find(option => option.number === 1) || out.visible_response.options[0];
assert.ok(primary && /应用|apply/.test(primary.label || ''),
  `option 1 label must say apply, got: ${primary && primary.label}`);
// The text's first line must be consistent with option 1's label (no
// stale-text-then-mutate-options[0].label discrepancy).
const normalizedFirstLabel = String(primary.label || '').replace(/\s+/g, ' ').trim();
const normalizedTextFirst = firstLine.replace(/^\s*\d+\.\s*/, '').replace(/\s+/g, ' ').trim();
assert.equal(normalizedTextFirst, normalizedFirstLabel,
  `text first line and option 1 label must match (unified builder)`);
NODE
}

# --- (v) Defect E: confirm after a successful apply reads the canonical snapshot, not legacy ---

@test "confirm after a successful apply reuses the canonical snapshot and returns its continuation" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # First apply succeeds and writes the canonical snapshot to status=applied.
    local first
    first="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local first_successor
    first_successor="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first")"

    # After apply, current-task.json carries a workflow_id. Running the same
    # old confirm command again must NOT trip the "current-task already carries
    # workflow_id" legacy guard. It must consult the canonical snapshot for
    # preview-id and return the same continuation.
    local second
    second="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"
    local second_status
    second_status="$(node -e 'console.log(JSON.parse(process.argv[1]).status)' "$second")"
    # Either "confirmed" (still in confirmed journal state) or "recovered"
    # (already bound to a successor) is acceptable; what matters is that the
    # call did NOT raise the legacy-source "current-task.json already carries
    # workflow_id" guard and returned a continuation anchored to the same
    # canonical snapshot.
    if [[ "$second_status" != "legacy_task_authority_recovery_confirmed" && "$second_status" != "legacy_task_authority_recovered" ]]; then
        echo "confirm after apply returned unexpected status: $second_status"
        echo "$second"
        return 1
    fi
    if [[ "$second" != *"legacy_task_authority_recovered"* && "$second" != *"legacy_task_authority_recovery_confirmed"* ]]; then
        echo "confirm after apply did not surface a continuation indicator: $second"
        return 1
    fi
    # And it must include the same canonical continuation the user already
    # could execute. With Gap 1 semantics, after the snapshot is applied, the
    # outer + visible status is legacy_task_authority_recovered and option 1
    # drives the workflow-entry-guard continuation (recovered/continue), not
    # another apply that would loop the user.
    node - "$first" "$second" "$first_successor" <<'NODE'
const assert = require('assert');
const [firstText, secondText, expectedSuccessor] = process.argv.slice(2);
const first = JSON.parse(firstText);
const second = JSON.parse(secondText);
assert.equal(second.snapshot_path, first.snapshot_path,
  'second confirm must reference the canonical snapshot_path the first apply used');
assert.equal(second.successor_workflow_id || first_successor, expectedSuccessor,
  'second confirm must surface the same successor_workflow_id');
const secondVisible = second.visible_response || {};
const secondPrimary = (secondVisible.options || []).find(option => option.number === 1);
assert.ok(secondPrimary, 'second confirm must include visible_response option 1');
assert.ok(/continue|继续|entry-guard|workflow-entry/i.test(secondPrimary.execution_command || ''),
  `second confirm option 1 must drive the recovered/continue step, got: ${secondPrimary.execution_command}`);
assert.ok(!/legacy-task-authority-recover\.js apply/.test(secondPrimary.execution_command || ''),
  'second confirm option 1 must NOT drive another apply; the snapshot is already applied');
NODE
    # The canonical snapshot must continue to bind the same successor.
    node - "$PROJECT" "$snapshot_path" "$first_successor" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, relSnap, expectedSuccessor] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
assert.equal(snap.successor_workflow_id, expectedSuccessor,
  'confirm after apply must not rebind to a different successor');
assert.equal(snap.status, 'applied', 'snapshot must remain applied after a re-confirm');
NODE
}

# --- (w) Defect F: source_bytes_base64 must be verified against source_hash ---

@test "snapshot with forged source_bytes_base64 fails sha256 verification on apply/recovery" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Forge: keep source_hash as-is but rewrite source_bytes_base64 to point
    # at a different byte payload. The next apply must reject because the
    # sha256 of the bytes doesn't match the recorded source_hash.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
// Pick any byte string that does NOT hash to snap.source_hash.
const forged = Buffer.from('forged-bytes-not-matching-hash');
snap.source_bytes_base64 = forged.toString('base64');
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "forged source_bytes_base64 was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "forged source_bytes_base64 did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'source'* && "$output" != *'hash'* && "$output" != *'sha256'* ]]; then
        echo "forged source_bytes_base64 rejection must mention source/hash/sha256: $output"
        return 1
    fi
}

# --- (x) Defect I: applying crash recovery materializes source archive from snapshot bytes ---

@test "applying crash recovery materializes the source archive from verified snapshot bytes" {
    # Build the canonical applying snapshot including source_bytes_base64 and
    # the candidate binding. Then delete the archive file, simulate crash by
    # leaving status=applying, and run apply. Recovery must materialize the
    # archive byte-exact from the verified snapshot bytes.
    local legacy_source="$PROJECT/追踪/workflow/source.archive.bytes"
    cp "$PROJECT/追踪/workflow/current-task.json" "$legacy_source"
    local legacy_hash
    legacy_hash="$(shasum -a 256 "$legacy_source" | awk '{print $1}')"
    local legacy_bytes
    legacy_bytes="$(cat "$legacy_source")"

    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Stage 1: plant an applying snapshot with a verified candidate and
    # materializable archive bytes.
    node - "$PROJECT" "$snapshot_path" "$legacy_source" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap, legacySource] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.successor_candidate_workflow_id = 'wf-recovery-candidate';
snap.successor_candidate_task_dir = '追踪/workflow/tasks/wf-recovery-candidate';
snap.preexisting_workflow_ids = ['legacy-other'];
const bytes = fs.readFileSync(legacySource);
snap.source_bytes_base64 = bytes.toString('base64');
snap.archive_path = `追踪/workflow/archived/${snap.source_task_id}.current-task.json`;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    # Plant the candidate task so resolveTaskAuthority can succeed.
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-recovery-candidate"
    cat > "$PROJECT/追踪/workflow/tasks/wf-recovery-candidate/task.json" <<'JSON'
{"workflow_id":"wf-recovery-candidate","workflow_type":"long_write","user_goal":"continue the current draft","task_dir":"追踪/workflow/tasks/wf-recovery-candidate","state_version":1,"status":"running"}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-recovery-candidate","task_dir":"追踪/workflow/tasks/wf-recovery-candidate","focused_at":"2026-08-04T00:00:00.000Z","state_version":1}
JSON
    # Make sure no archive file exists yet (simulate a crash before materialization).
    rm -f "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -ne 0 ]]; then
        echo "recovery apply failed: $output"
        return 1
    fi
    local materialized_hash
    materialized_hash="$(shasum -a 256 "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" | awk '{print $1}')"
    if [[ "$legacy_hash" != "$materialized_hash" ]]; then
        echo "recovery did not materialize archive byte-exact: $legacy_hash vs $materialized_hash"
        return 1
    fi
    # Snapshot must transition to applied.
    node - "$PROJECT" "$snapshot_path" 'wf-recovery-candidate' <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, relSnap, expectedSuccessor] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
assert.equal(snap.status, 'applied', 'recovery must transition the snapshot to applied');
assert.equal(snap.successor_workflow_id, expectedSuccessor,
  'recovery must persist the bound successor_workflow_id');
assert.ok(snap.archive_sha256, 'recovery must persist archive_sha256');
assert.equal(snap.archive_sha256, require('crypto').createHash('sha256').update(Buffer.from(snap.source_bytes_base64, 'base64')).digest('hex'),
  'archive_sha256 must equal sha256(source_bytes_base64)');
NODE
    # Cleanup the test fixture file.
    rm -f "$legacy_source"
}

# --- (y) Defect H: concurrent apply serializes through a recovery lock ---

@test "concurrent applies serialize through a legacy recovery lock; only one successor is created" {
    # First confirmed snapshot, then run apply twice sequentially. The second
    # apply must converge to the same successor without creating a second
    # task directory. A separately-injected stuck lock (pretending a previous
    # apply is still in flight) must surface as a precise lock refusal.
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Inject a stuck lock as if a previous apply were still running.
    mkdir -p "$PROJECT/追踪/workflow/legacy-recovery.lock"
    cat > "$PROJECT/追踪/workflow/legacy-recovery.lock/owner.json" <<JSON
{"pid":99999,"owner":"stuck-apply","token":"abc","acquired_at":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"}
JSON
    local before_count
    before_count="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "stuck lock did not surface as a blocked lock refusal: $output"
        return 1
    fi
    if [[ "$output" != *'LEGACY_RECOVERY_LOCKED'* && "$output" != *'legacy_recovery_locked'* && "$output" != *'recovery lock'* ]]; then
        echo "lock refusal did not mention the recovery lock: $output"
        return 1
    fi

    local after_count
    after_count="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$before_count" != "$after_count" ]]; then
        echo "apply under a stuck lock created a new task: $before_count vs $after_count"
        return 1
    fi

    # Now release the stuck lock and rerun; apply must proceed and produce
    # exactly one successor.
    rm -rf "$PROJECT/追踪/workflow/legacy-recovery.lock"
    local first
    first="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local first_id
    first_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first")"

    local tasks_after_first
    tasks_after_first="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    # Idempotent re-apply must NOT create another directory.
    local second
    second="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local tasks_after_second
    tasks_after_second="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    local second_id
    second_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$second")"

    if [[ "$first_id" != "$second_id" ]]; then
        echo "two applies yielded different successors: $first_id vs $second_id"
        return 1
    fi
    if [[ "$tasks_after_first" != "$tasks_after_second" ]]; then
        echo "second apply created an additional task directory: $tasks_after_first vs $tasks_after_second"
        return 1
    fi
}

# --- (z) Defect J: visible_response text is numbered with actionable commands on apply and reapply ---

@test "apply and reapply visible_response carry readable numbered text and actionable commands" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local first
    first="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local second
    second="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"

    node - "$first" "$second" <<'NODE'
const assert = require('assert');
const [aText, bText] = process.argv.slice(2);
for (const [label, payload] of [['first', aText], ['second', bText]]) {
  const out = JSON.parse(payload);
  assert.ok(out.visible_response && typeof out.visible_response.text === 'string',
    `${label} apply must include visible_response.text`);
  const text = out.visible_response.text;
  // Must contain numbered items at minimum 1, 2, 3, 4 to be considered readable.
  for (const n of [1, 2, 3, 4]) {
    const re = new RegExp(`(^|\\n)\\s*${n}\\.`);
    assert.ok(re.test(text), `${label} apply text must include numbered option ${n}: ${text.slice(0, 200)}`);
  }
  const options = out.visible_response.options || [];
  const primary = options.find(option => option.number === 1) || options[0];
  assert.ok(primary && primary.interaction_mode === 'execute_command',
    `${label} apply primary option must be executable`);
  assert.ok(primary.execution_command && /legacy-task-authority-recover\.js|workflow-entry-guard\.js/.test(primary.execution_command),
    `${label} apply primary execution_command must reference an actionable script, got: ${primary.execution_command}`);
  assert.ok(primary.execution_command.includes('--resume-intent') || primary.execution_command.includes('--user-intent'),
    `${label} apply primary execution_command must carry the intent, got: ${primary.execution_command}`);
}
NODE
}

# --- (aa) Apply crash recovery refuses when archive conflict exists at materialization time ---

@test "recovery refuses to materialize archive when an unrelated entry already exists at the target path" {
    # Plant canonical snapshot + candidate, then plant a foreign archive entry.
    # Recovery must check for conflict BEFORE materializing from snapshot bytes
    # so we never overwrite an existing foreign archive.
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.successor_candidate_workflow_id = 'wf-recovery-with-foreign';
snap.successor_candidate_task_dir = '追踪/workflow/tasks/wf-recovery-with-foreign';
snap.preexisting_workflow_ids = [];
snap.archive_path = `追踪/workflow/archived/${snap.source_task_id}.current-task.json`;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    mkdir -p "$PROJECT/追踪/workflow/archived"
    printf '{"archive":"foreign"}' > "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json"
    local foreign_hash
    foreign_hash="$(shasum -a 256 "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" | awk '{print $1}')"
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "foreign archive conflict was overwritten: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "foreign archive conflict did not return blocked status: $output"
        return 1
    fi
    local archive_now
    archive_now="$(shasum -a 256 "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" | awk '{print $1}')"
    if [[ "$foreign_hash" != "$archive_now" ]]; then
        echo "foreign archive was overwritten: $foreign_hash vs $archive_now"
        return 1
    fi
}

# --- (bb) Gap 1: confirm fast path must run the full validator, not just kind/id/intent ---

@test "confirm fast path rejects a canonical-path snapshot whose project_root, source_hash, or base64 drifted" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    # First materialize the canonical snapshot so the fast-path file exists.
    run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm > /dev/null

    # Forge a foreign snapshot at the canonical filename path. kind/id/intent
    # all match, but project_root, source_hash, and source_bytes_base64 are
    # tampered so any trust on those alone would bypass the full validator.
    node - "$PROJECT" "$preview_id" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, previewId] = process.argv.slice(2);
const snapshotPath = path.join(root, '追踪/workflow/archived', `legacy-recovery-${previewId}.json`);
const original = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));
const foreign = {
  ...original,
  project_root: '/var/folders/somewhere/else',
  source_hash: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
  source_bytes_base64: Buffer.from('forged-bytes-not-matching-hash').toString('base64'),
};
fs.writeFileSync(snapshotPath, `${JSON.stringify(foreign, null, 2)}\n`);
NODE

    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --preview-id "$preview_id" --confirm --json

    if [[ "$status" -eq 0 ]]; then
        echo "forged canonical-path snapshot was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "forged canonical-path snapshot did not return blocked status: $output"
        return 1
    fi
}

@test "confirm fast path for confirmed snapshot requires current legacy source_hash still matches" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    # First confirm materializes the canonical snapshot.
    run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm > /dev/null

    # Drift the legacy source AFTER confirm. Re-confirm must fail closed
    # because the snapshot is still status=confirmed and the legacy bytes
    # no longer match source_hash.
    write_legacy_task "$PROJECT/追踪/workflow/current-task.json" \
        'drifted_after_confirm_20260102' \
        'legacy continuity repair' \
        'do not use'

    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --preview-id "$preview_id" --confirm --json

    if [[ "$status" -eq 0 ]]; then
        echo "re-confirm accepted drifted legacy source on a confirmed snapshot: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "drifted legacy re-confirm did not return blocked status: $output"
        return 1
    fi
}

@test "re-confirm on an applied snapshot surfaces recovered/continue outer and visible status, not confirmed" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    # Apply once so the snapshot is bound and current pointer is the successor.
    local first
    first="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local first_successor
    first_successor="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first")"

    # Now re-run the original confirm command. The outer response must reflect
    # recovered/continue, and visible_response must also be semantically
    # consistent with that — text and option 1 must describe continuation,
    # not another confirm.
    local second
    second="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"

    node - "$second" "$first_successor" <<'NODE'
const assert = require('assert');
const [secondText, expectedSuccessor] = process.argv.slice(2);
const out = JSON.parse(secondText);
assert.equal(out.status, 'legacy_task_authority_recovered',
  'outer status must say recovered when snapshot is applied, not confirmed');
assert.ok(out.successor_workflow_id === expectedSuccessor,
  'outer status must surface the bound successor_workflow_id');
const visible = out.visible_response || {};
assert.equal(visible.status, 'legacy_task_authority_recovered',
  'visible_response.status must match outer recovered status');
const options = visible.options || [];
const primary = options.find(option => option.number === 1) || options[0];
assert.ok(primary, 'visible_response must include option 1');
assert.ok(/继续|continue|apply|应用/.test(primary.label || ''),
  `primary option label must describe continuation, got: ${primary && primary.label}`);
const text = String(visible.text || '');
assert.ok(/继续|continue|apply|应用/.test(text.split('\n')[0] || ''),
  `first numbered line of visible text must describe continuation, got: ${text.split('\n')[0]}`);
NODE
}

# --- (cc) Gap 2: runReapply status=applied must verify type/goal/task_dir on the durable task ---

@test "applying recovery refuses to rebind when the bound successor's task_dir drifted" {
    # First do a normal apply to bind the canonical successor and mark the
    # snapshot applied with the right successor_task_dir. Then tamper with
    # the snapshot's recorded successor_task_dir so the reapply verification
    # catches the drift between the snapshot binding and the durable task.
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local first_apply
    first_apply="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local first_successor
    first_successor="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first_apply")"

    # Tamper: rewrite the snapshot's recorded successor_task_dir to a different
    # path while leaving the durable task.json untouched. Recovery must
    # refuse to rebind because durable.task_dir !== snapshot.successor_task_dir.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.successor_task_dir = '追踪/workflow/tasks/some_other_dir';
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "task_dir drift on the applied snapshot was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "task_dir drift did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'task_dir'* && "$output" != *'directory'* && "$output" != *'mismatch'* ]]; then
        echo "task_dir drift rejection must mention task_dir/directory/mismatch: $output"
        return 1
    fi
}

@test "applying recovery refuses to rebind when the bound successor's user_goal drifted" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local first_apply
    first_apply="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local first_successor
    first_successor="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first_apply")"

    # Tamper: rewrite user_goal in the durable task.json. The focus pointer
    # is left alone, but resolveTaskAuthority must surface the goal drift.
    local task_file="$PROJECT/追踪/workflow/tasks/$first_successor/task.json"
    node - "$task_file" <<'NODE'
const fs = require('fs');
const [taskFile] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.user_goal = 'a different goal now';
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "user_goal drift on applied snapshot was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "user_goal drift did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'user_goal'* && "$output" != *'intent'* && "$output" != *'mismatch'* ]]; then
        echo "user_goal drift rejection must mention user_goal/intent/mismatch: $output"
        return 1
    fi
}

@test "applying recovery refuses to rebind when the bound successor's workflow_type drifted" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local first_apply
    first_apply="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local first_successor
    first_successor="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first_apply")"

    local task_file="$PROJECT/追踪/workflow/tasks/$first_successor/task.json"
    node - "$task_file" <<'NODE'
const fs = require('fs');
const [taskFile] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.workflow_type = 'short_write';
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "workflow_type drift on applied snapshot was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "workflow_type drift did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'workflow_type'* && "$output" != *'long_write'* ]]; then
        echo "workflow_type drift rejection must mention workflow_type: $output"
        return 1
    fi
}

# --- (dd) Gap 3: crash window with no pointer and no candidate restores legacy ---

@test "applying crash with no pointer and no candidate restores legacy current-task atomically and clears backup" {
    local source_bytes
    source_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"

    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Stage the crash: snapshot status=applying, NO successor_candidate_workflow_id,
    # focus pointer is gone, AND the .legacy-recovery-backup is still present.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.preexisting_workflow_ids = [];
delete snap.successor_candidate_workflow_id;
delete snap.successor_candidate_task_dir;
delete snap.successor_candidate_user_goal;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    # Stage the crash state on disk.
    cp "$PROJECT/追踪/workflow/current-task.json" "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup"
    rm -f "$PROJECT/追踪/workflow/current-task.json"
    local tasks_before
    tasks_before="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -ne 0 ]]; then
        echo "crash recovery did not succeed: $output"
        return 1
    fi

    # (i) Focus pointer must be byte-identical to the original.
    local restored
    restored="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"
    if [[ "$source_bytes" != "$restored" ]]; then
        echo "legacy current-task was not restored byte-exact: $source_bytes vs $restored"
        return 1
    fi
    # (ii) Backup file must be cleaned up.
    if [[ -f "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup" ]]; then
        echo "legacy-recovery-backup was not cleaned up after restoration"
        return 1
    fi
    # (iii) No successor task directory may have been created during restoration.
    local tasks_after
    tasks_after="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$tasks_before" != "$tasks_after" ]]; then
        echo "crash recovery created a task directory: $tasks_before vs $tasks_after"
        return 1
    fi
    # (iv) Journal must be back to confirmed with truthful interrupted metadata.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
assert.equal(snap.status, 'confirmed', 'crash recovery must revert journal to confirmed');
assert.ok(snap.last_apply_error && /interrupted|crash/i.test(snap.last_apply_error),
  'crash recovery must record truthful interrupted metadata');
assert.ok(snap.last_apply_failed_at, 'crash recovery must stamp last_apply_failed_at');
assert.equal(snap.pending_recovery, undefined,
  'crash recovery must clear any pending_recovery flag once the legacy pointer is restored');
assert.equal(snap.applying_started_at, undefined,
  'crash recovery must clear applying_started_at');
NODE
    # (v) Outer status must reflect recovered/retry/continue, not confirm.
    node - "$output" "$snapshot_path" <<'NODE'
const assert = require('assert');
const [applyText, snapPath] = process.argv.slice(2);
const out = JSON.parse(applyText);
assert.notEqual(out.status, 'legacy_task_authority_recovery_preview',
  'crash recovery must not surface a preview status');
assert.notEqual(out.status, 'blocked_legacy_task_authority_recovery',
  'crash recovery must not surface a blocked status; it succeeded');
assert.ok(out.apply_command || (out.visible_response && out.visible_response.options && out.visible_response.options.some(o => /apply/.test(o.execution_command || ''))),
  'crash recovery must surface a precise retry/apply continuation');
NODE
}

@test "applying crash with a candidate but no pointer fails closed with candidate-specific diagnostics" {
    local source_bytes
    source_bytes="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" | awk '{print $1}')"

    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Stage crash: candidate exists, but the focus pointer was deleted.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.preexisting_workflow_ids = [];
snap.successor_candidate_workflow_id = 'wf-maybe-created';
snap.successor_candidate_task_dir = '追踪/workflow/tasks/wf-maybe-created';
snap.successor_candidate_user_goal = 'continue the current draft';
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    # No backup present, no pointer present. The candidate may or may not
    # actually exist on disk; we MUST NOT touch it from the recovery path.
    rm -f "$PROJECT/追踪/workflow/current-task.json"
    rm -f "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "candidate-but-no-pointer crash did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "candidate-but-no-pointer crash did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'candidate'* && "$output" != *'wf-maybe-created'* ]]; then
        echo "candidate crash rejection must mention candidate id: $output"
        return 1
    fi
    # We must NOT restore the legacy pointer over a possibly-created task.
    if [[ -f "$PROJECT/追踪/workflow/current-task.json" ]]; then
        echo "candidate crash restored legacy pointer over a possibly-created task"
        return 1
    fi
}

# --- (ee) Gap 4: archiveOriginalBytes must be atomic and clean temp files on failure ---

@test "archiveOriginalBytes is atomic: a write failure leaves no partial archive on disk" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Inject a write failure so archiveOriginalBytes blows up mid-way. The
    # archive file must not be left as a partial / temp file.
    local archive_path="$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json"
    # Sanity: archive doesn't exist yet.
    [[ -f "$archive_path" ]] && { echo "pre-existing archive unexpectedly present"; return 1; }

    NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL=archive_write \
        run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
            --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "injected archive write failure did not surface: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "archive write failure did not return blocked status: $output"
        return 1
    fi
    # The canonical archive file must NOT exist as a partial.
    if [[ -f "$archive_path" ]]; then
        echo "partial archive file was left at canonical path"
        return 1
    fi
    # No temp files under the archive dir may be left behind.
    local stray
    stray="$(find "$PROJECT/追踪/workflow/archived" -maxdepth 1 -name '*.tmp-*' 2>/dev/null | head -n 5)"
    if [[ -n "$stray" ]]; then
        echo "stray archive temp files left behind: $stray"
        return 1
    fi
}

# --- (ff) Gap 5: readRecoverySnapshot must require nonempty source_bytes_base64 ---

@test "snapshot missing source_bytes_base64 cannot be applied" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Strip source_bytes_base64 from the snapshot. Recovery must refuse to
    # apply because crash recovery would be impossible without the embedded
    # bytes.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
delete snap.source_bytes_base64;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "snapshot without source_bytes_base64 was applied: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "snapshot without source_bytes_base64 did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'source_bytes_base64'* && "$output" != *'embedded'* && "$output" != *'crash recovery'* && "$output" != *'base64'* ]]; then
        echo "rejection must mention source_bytes_base64/embedded/crash recovery/base64: $output"
        return 1
    fi
}

# --- (gg) Defect 1 (runConfirm): full-validator failures must propagate, not be swallowed ---

@test "confirm fast path rejects a canonical-path snapshot whose ONLY project_root is forged" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    # First confirm materializes the canonical snapshot so the fast-path file exists.
    run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm > /dev/null

    # Forge ONLY project_root on the canonical snapshot. kind/id/source_hash/
    # source_path/base64/intent all match, so the slow path's shallow accept
    # branch would happily take it (no overwrite, no error) — recovery must
    # fail closed instead, because the snapshot is no longer bound to this
    # project tree.
    node - "$PROJECT" "$preview_id" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, previewId] = process.argv.slice(2);
const snapshotPath = path.join(root, '追踪/workflow/archived', `legacy-recovery-${previewId}.json`);
const original = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));
const foreign = { ...original, project_root: '/var/folders/somewhere/else' };
fs.writeFileSync(snapshotPath, `${JSON.stringify(foreign, null, 2)}\n`);
NODE

    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --preview-id "$preview_id" --confirm --json

    if [[ "$status" -eq 0 ]]; then
        echo "forged project_root on canonical-path snapshot was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "forged project_root did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'project_root'* ]]; then
        echo "rejection must mention project_root mismatch: $output"
        return 1
    fi
}

@test "confirm fast path rejects a canonical-path snapshot whose ONLY source_path is forged" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm > /dev/null

    # Forge ONLY source_path on the canonical snapshot. The slow path's
    # idempotent-reconfirm branch would otherwise accept it because
    # preview_id/source_hash/intent still match and the file just looks like
    # another cached recovery for this project.
    node - "$PROJECT" "$preview_id" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, previewId] = process.argv.slice(2);
const snapshotPath = path.join(root, '追踪/workflow/archived', `legacy-recovery-${previewId}.json`);
const original = JSON.parse(fs.readFileSync(snapshotPath, 'utf8'));
const foreign = { ...original, source_path: '追踪/workflow/another-current-task.json' };
fs.writeFileSync(snapshotPath, `${JSON.stringify(foreign, null, 2)}\n`);
NODE

    run node "$SCRIPT" confirm --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --preview-id "$preview_id" --confirm --json

    if [[ "$status" -eq 0 ]]; then
        echo "forged source_path on canonical-path snapshot was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "forged source_path did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'source_path'* ]]; then
        echo "rejection must mention source_path mismatch: $output"
        return 1
    fi
}

@test "confirm fast path preserves confirmed-snapshot retry behavior when the snapshot is valid" {
    # Sanity baseline: a fully-valid canonical snapshot MUST keep its apply
    # retry behavior — the fix must not regress the legitimate cached path.
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"

    local first
    first="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"
    local second
    second="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm)"

    node - "$first" "$second" <<'NODE'
const assert = require('assert');
const [firstText, secondText] = process.argv.slice(2);
const firstOut = JSON.parse(firstText);
const secondOut = JSON.parse(secondText);
assert.equal(firstOut.status, 'legacy_task_authority_recovery_confirmed',
  'first confirm must surface confirmed status');
assert.equal(secondOut.status, 'legacy_task_authority_recovery_confirmed',
  're-confirm of a valid canonical snapshot must also surface confirmed status (retry preserved)');
assert.equal(secondOut.changed, false, 're-confirm of a valid canonical snapshot must NOT mark changed');
assert.ok(secondOut.apply_command && secondOut.apply_command.includes('legacy-task-authority-recover.js apply'),
  're-confirm must still emit an apply command so the user can proceed');
assert.equal(firstOut.snapshot_path, secondOut.snapshot_path, 'snapshot path must be stable across re-confirms');
NODE
}

# --- (hh) Defect 2 (runCrashRecovery): validate backup and inventory BEFORE writing the focus pointer ---

@test "runCrashRecovery fails closed when backup exists with mismatched bytes: focus pointer must remain absent and backup untouched" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Stage crash: applying snapshot with no candidate, no focus pointer,
    # AND a .legacy-recovery-backup whose bytes differ from the embedded
    # source bytes. Recovery must NOT write the focus pointer (a foreign
    # recovery was racing on this project), and must NOT touch the backup.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.preexisting_workflow_ids = [];
delete snap.successor_candidate_workflow_id;
delete snap.successor_candidate_task_dir;
delete snap.successor_candidate_user_goal;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    rm -f "$PROJECT/追踪/workflow/current-task.json"
    # Backup carries bytes that DO NOT match the embedded snapshot bytes.
    printf '{"task_id":"foreign_recovery","task_type":"legacy continuity repair","status":"phase_pending","resume_command":"do not use","next_steps":[{"step_id":"next","status":"pending"}]}' \
        > "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup"
    local backup_before
    backup_before="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup" | awk '{print $1}')"

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "mismatched backup crash did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "mismatched backup crash did not return blocked status: $output"
        return 1
    fi
    # Focus pointer must NOT have been written — the foreign backup means a
    # racing recovery was in flight on this project.
    if [[ -f "$PROJECT/追踪/workflow/current-task.json" ]]; then
        echo "focus pointer was written despite mismatched backup: $PROJECT/追踪/workflow/current-task.json"
        return 1
    fi
    # Backup must remain untouched.
    if [[ ! -f "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup" ]]; then
        echo "backup was removed despite mismatched bytes"
        return 1
    fi
    local backup_after
    backup_after="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup" | awk '{print $1}')"
    if [[ "$backup_before" != "$backup_after" ]]; then
        echo "backup bytes changed despite failure: $backup_before vs $backup_after"
        return 1
    fi
}

@test "runCrashRecovery fails closed when a new workflow task appeared while pointer and candidate are missing" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # Stage crash: applying snapshot with NO candidate, NO pointer, AND a
    # current task inventory that includes a brand-new workflow directory
    # the snapshot never recorded as preexisting. child create() may have
    # succeeded; restoring the legacy pointer over that task would corrupt
    # the workflow state.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.preexisting_workflow_ids = [];   // intentionally empty: inventory check must catch the new task
delete snap.successor_candidate_workflow_id;
delete snap.successor_candidate_task_dir;
delete snap.successor_candidate_user_goal;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    rm -f "$PROJECT/追踪/workflow/current-task.json"
    rm -f "$PROJECT/追踪/workflow/current-task.json.legacy-recovery-backup"

    # Create a new task dir that was NOT preexisting at apply time.
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-new-survivor"
    cat > "$PROJECT/追踪/workflow/tasks/wf-new-survivor/task.json" <<'JSON'
{"workflow_id":"wf-new-survivor","workflow_type":"long_write","task_dir":"追踪/workflow/tasks/wf-new-survivor","user_goal":"continue the current draft","state_version":1}
JSON

    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
        --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "new-survivor-task crash did not fail closed: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "new-survivor-task crash did not return blocked status: $output"
        return 1
    fi
    if [[ "$output" != *'wf-new-survivor'* && "$output" != *'preexist'* && "$output" != *'inventory'* ]]; then
        echo "new-survivor crash rejection must mention the new task id / preexisting / inventory: $output"
        return 1
    fi
    # Legacy focus pointer must NOT have been written — would overwrite the
    # newly-created workflow.
    if [[ -f "$PROJECT/追踪/workflow/current-task.json" ]]; then
        echo "legacy focus pointer was written over a possibly-created successor"
        return 1
    fi
}

# --- (ii) Defect 3 (runReapply): archive materialization must use the atomic helper ---

@test "runReapply archive materialization uses the atomic helper: injected write failure leaves no partial archive and journal stays applying" {
    local preview
    preview="$(run_recover preview --resume-intent 'continue the current draft')"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent 'continue the current draft' --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"

    # First do a normal apply so we have a real successor workflow id.
    local first
    first="$(run_recover apply --resume-intent 'continue the current draft' --snapshot "$snapshot_path")"
    local successor_id
    successor_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first")"
    if [[ -z "$successor_id" ]]; then
        echo "setup: first apply did not return a successor id: $first"
        return 1
    fi

    # Now rewind the journal to status=applying with the exact same
    # candidate, and DELETE the archive file so runReapply will try to
    # materialize it from the verified snapshot bytes. Inject
    # archive_write failure so the atomic helper throws mid-way.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.status = 'applying';
snap.applying_started_at = new Date().toISOString();
snap.successor_candidate_workflow_id = snap.successor_workflow_id;
snap.successor_candidate_task_dir = snap.successor_task_dir;
snap.successor_candidate_user_goal = snap.resume_intent;
snap.preexisting_workflow_ids = [];
delete snap.successor_workflow_id;
delete snap.successor_task_dir;
delete snap.archive_path;
delete snap.archive_sha256;
delete snap.applied_at;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    rm -f "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json"
    [[ -f "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" ]] \
        && { echo "archive unexpectedly present after rm"; return 1; }

    NOVEL_ASSISTANT_LEGACY_RECOVER_FAIL=archive_write \
        run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent 'continue the current draft' \
            --snapshot "$snapshot_path" --json

    if [[ "$status" -eq 0 ]]; then
        echo "injected archive write failure during applying recovery did not surface: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "archive write failure did not return blocked status: $output"
        return 1
    fi

    # No canonical archive may exist.
    if [[ -f "$PROJECT/追踪/workflow/archived/legacy_checkpoint_20260101.current-task.json" ]]; then
        echo "partial archive was left at canonical path after injected write failure"
        return 1
    fi
    # No temp files in the archive directory.
    local stray
    stray="$(find "$PROJECT/追踪/workflow/archived" -maxdepth 1 -name '*.tmp-*' 2>/dev/null | head -n 5)"
    if [[ -n "$stray" ]]; then
        echo "stray archive temp files left behind: $stray"
        return 1
    fi

    # Journal MUST remain applying — the user must be able to retry the
    # recovery once the underlying write issue is resolved.
    node - "$PROJECT" "$snapshot_path" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const [root, relSnap] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
assert.equal(snap.status, 'applying',
  'journal must remain applying after archive write failure during runReapply');
assert.equal(snap.applied_at, undefined,
  'applied_at must NOT be stamped when archive materialization failed');
assert.equal(snap.successor_workflow_id, undefined,
  'successor_workflow_id must NOT be bound when archive materialization failed');
NODE
}

# --- (jj) Scope extraction: explicit Chinese chapter range in resume_intent ---
# Defect: callStateMachineCreate hardcoded --scope to '未指定' even when the
# confirmed resume_intent explicitly named a chapter range. The successor
# long_write task must inherit a readable scope token so its chapter targeting
# stays aligned with the user's confirmed intent.

assert_scope_equals() {
    # Args: <project_root> <successor_id> <expected_scope>
    local root="$1"
    local successor_id="$2"
    local expected_scope="$3"
    local task_file="$root/追踪/workflow/tasks/$successor_id/task.json"
    if [[ ! -f "$task_file" ]]; then
        echo "successor task.json missing: $task_file"
        return 1
    fi
    local actual_scope
    actual_scope="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).scope || "")' "$task_file")"
    if [[ "$actual_scope" != "$expected_scope" ]]; then
        echo "successor scope mismatch: expected [$expected_scope], got [$actual_scope]"
        return 1
    fi
}

@test "scope: apply extracts explicit chinese chapter range from resume_intent as successor scope" {
    local intent='第12至14章'
    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local apply_output
    apply_output="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"
    local successor_id
    successor_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$apply_output")"
    if [[ -z "$successor_id" ]]; then
        echo "apply did not return a successor id: $apply_output"
        return 1
    fi
    assert_scope_equals "$PROJECT" "$successor_id" "$intent"
    # The snapshot must also persist the scope so a later reapply never
    # relabels the successor under a different scope token.
    node - "$PROJECT" "$snapshot_path" "$intent" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const [root, relSnap, expected] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
assert.equal(snap.scope, expected, 'snapshot must persist the extracted scope so reapply cannot relabel');
NODE
}

@test "scope: apply defaults successor scope to unspecified when resume_intent has no range" {
    local intent='继续当前草稿，不要映射剧情'
    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local apply_output
    apply_output="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"
    local successor_id
    successor_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$apply_output")"
    if [[ -z "$successor_id" ]]; then
        echo "apply did not return a successor id: $apply_output"
        return 1
    fi
    assert_scope_equals "$PROJECT" "$successor_id" "未指定"
}

@test "scope: apply extracts volume-prefixed chinese chapter range preserving readability" {
    local intent='第2卷第1至3章'
    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local apply_output
    apply_output="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"
    local successor_id
    successor_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$apply_output")"
    if [[ -z "$successor_id" ]]; then
        echo "apply did not return a successor id: $apply_output"
        return 1
    fi
    assert_scope_equals "$PROJECT" "$successor_id" "$intent"
}

@test "scope: apply extracts volume-prefixed padded-digit chinese chapter range" {
    local intent='第2卷第001-003章'
    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local apply_output
    apply_output="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"
    local successor_id
    successor_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$apply_output")"
    if [[ -z "$successor_id" ]]; then
        echo "apply did not return a successor id: $apply_output"
        return 1
    fi
    assert_scope_equals "$PROJECT" "$successor_id" "$intent"
}

@test "scope: apply refuses to copy freeform narrative into scope and falls back to unspecified" {
    # Very long, narrative intent with no chapter/section/volume range token
    # must NOT become the scope; fallback is 未指定.
    local intent
    intent="$(printf 'A%.0s' {1..2000})"
    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local apply_output
    apply_output="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"
    local successor_id
    successor_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$apply_output")"
    if [[ -z "$successor_id" ]]; then
        echo "apply did not return a successor id: $apply_output"
        return 1
    fi
    assert_scope_equals "$PROJECT" "$successor_id" "未指定"
}

@test "idempotent reapply does not rebind the successor scope to a different value" {
    # First apply binds an explicit scope. A second apply through the same
    # canonical snapshot must NOT change the durable successor's scope — the
    # snapshot's bound scope is the source of truth on reapply.
    local intent='第27至29章'
    local preview
    preview="$(run_recover preview --resume-intent "$intent")"
    local preview_id
    preview_id="$(node -e 'console.log(JSON.parse(process.argv[1]).preview_id)' "$preview")"
    local snapshot_path
    snapshot_path="$(run_recover confirm --resume-intent "$intent" --preview-id "$preview_id" --confirm \
        | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).snapshot_path)')"
    local first
    first="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"
    local successor_id
    successor_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$first")"
    assert_scope_equals "$PROJECT" "$successor_id" "$intent"

    # Force the snapshot-bound scope to a different value AFTER first apply
    # so reapply must reject drift instead of silently relabeling on whatever
    # the script would re-derive.
    node - "$PROJECT" "$snapshot_path" 'WRONG_SCOPE' <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap, wrong] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.scope = wrong;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    run node "$SCRIPT" apply --project-root "$PROJECT" --resume-intent "$intent" \
        --snapshot "$snapshot_path" --json
    if [[ "$status" -eq 0 ]]; then
        echo "drifted snapshot scope on reapply was accepted: $output"
        return 1
    fi
    if [[ "$output" != *'blocked_legacy_task_authority_recovery'* ]]; then
        echo "drifted snapshot scope did not return blocked status: $output"
        return 1
    fi
    # Restore the snapshot's bound scope and confirm reapply still produces
    # the same successor with the same scope.
    node - "$PROJECT" "$snapshot_path" "$intent" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, relSnap, expected] = process.argv.slice(2);
const snap = JSON.parse(fs.readFileSync(path.join(root, relSnap), 'utf8'));
snap.scope = expected;
fs.writeFileSync(path.join(root, relSnap), `${JSON.stringify(snap, null, 2)}\n`);
NODE
    local second
    second="$(run_recover apply --resume-intent "$intent" --snapshot "$snapshot_path")"
    local second_id
    second_id="$(node -e 'console.log(JSON.parse(process.argv[1]).successor_workflow_id)' "$second")"
    if [[ "$second_id" != "$successor_id" ]]; then
        echo "reapply rebound the successor: $successor_id vs $second_id"
        return 1
    fi
    assert_scope_equals "$PROJECT" "$successor_id" "$intent"
}

@test "extractResumeScope helper returns the matched range and ignores legacy task_type or resume_command" {
    # Direct unit test of the helper exported by the script. The helper MUST
    # only consume the resume_intent argument; it MUST NOT inspect any other
    # source (e.g. legacy resume_command, task_type, or freeform narrative).
    node - "$SCRIPT" <<'NODE'
const path = require('path');
const [script] = process.argv.slice(2);
const mod = require(script);
if (typeof mod.extractResumeScope !== 'function') {
  console.error('extractResumeScope is not exported from legacy-task-authority-recover.js');
  process.exit(1);
}
const f = mod.extractResumeScope;

const cases = [
  { input: '第12至14章', expected: '第12至14章' },
  { input: '请接着写第12至14章', expected: '第12至14章' },
  { input: '第2卷第1至3章', expected: '第2卷第1至3章' },
  { input: '第2卷第001-003章', expected: '第2卷第001-003章' },
  { input: '12-14章', expected: '12-14章' },
  { input: '第 12 至 14 章', expected: '第12至14章' },
  { input: '继续当前草稿', expected: '未指定' },
  { input: 'legacy continuity repair', expected: '未指定' },
  { input: 'do not use', expected: '未指定' },
  { input: 'A'.repeat(2000), expected: '未指定' },
  { input: '', expected: '未指定' },
];

for (const c of cases) {
  const actual = f(c.input);
  if (actual !== c.expected) {
    console.error(`extractResumeScope mismatch: input=${JSON.stringify(c.input)} expected=${JSON.stringify(c.expected)} got=${JSON.stringify(actual)}`);
    process.exit(1);
  }
}
process.exit(0);
NODE
}
