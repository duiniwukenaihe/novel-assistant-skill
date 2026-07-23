#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-a" "$PROJECT/追踪/workflow/tasks/wf-b" "$PROJECT/追踪/workflow/families/tf-a" "$PROJECT/追踪/staging"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "commit memory lifecycle comes from committing durable task, not current focus" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
const memory = require(path.join(repo, 'scripts/lib/memory-projection.js'));
const commits = require(path.join(repo, 'scripts/lib/chapter-commit-store.js'));

function write(relative, value) {
  const file = path.join(root, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

const taskA = {
  workflow_id: 'wf-a', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-a', state_version: 5,
  task_family_id: 'tf-a', branch_id: 'wf-a', stage_execution: { stage_attempt_id: 'sa-a' },
  lifecycle_context: { node: 'chapter_commit', book_id: 'book-a', volume_id: '第1卷', stage_id: 'prose-a', chapter_id: 'v01-c001', task_family_id: 'tf-a', workflow_id: 'wf-a' },
};
const taskB = {
  workflow_id: 'wf-b', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-b', state_version: 9,
  lifecycle_context: { node: 'chapter_commit', book_id: 'book-b', volume_id: '第2卷', stage_id: 'prose-b', chapter_id: 'v02-c001', workflow_id: 'wf-b' },
};
write('追踪/workflow/tasks/wf-a/task.json', taskA);
write('追踪/workflow/tasks/wf-b/task.json', taskB);
write('追踪/workflow/families/tf-a/family.json', { task_family_id: 'tf-a', head_workflow_id: 'wf-a' });
authority.writeFocusPointer(root, taskA);
authority.writeFocusPointer(root, taskB);

const focusBefore = authority.readFocusedTask(root);
assert.equal(focusBefore.pointer.workflow_id, 'wf-b');
assert.equal(focusBefore.authority.task.workflow_id, 'wf-b');
const mutated = authority.mutateTaskAuthority(root, 'wf-a', 5, (task) => ({ ...task, background_marker: 'only-a' }));
assert.equal(mutated.state_version, 6);
assert.equal(authority.readFocusedTask(root).pointer.workflow_id, 'wf-b');
assert.equal(authority.resolveTaskAuthority(root, 'wf-a').task.background_marker, 'only-a');
assert.equal(authority.resolveTaskAuthority(root, 'wf-b').task.background_marker, undefined);

const lifecycle = memory.resolveLifecycleProjection(root, { provenance: { workflow_id: 'wf-a', task_family_id: 'tf-a' } });
assert.equal(lifecycle.volumeId, '第1卷');
assert.equal(lifecycle.workflowId, 'wf-a');

fs.writeFileSync(path.join(root, '追踪/staging/伏笔.md'), '# 新伏笔\n- F001\n');
write('追踪/staging/manifest.json', {
  schemaVersion: '1.0.0', workflow_id: 'wf-a', volume: '第1卷', chapter: 1,
  artifacts: [{ role: 'hook_ledger', staged: '追踪/staging/伏笔.md', target: '追踪/伏笔.md', required: true }],
  gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
});
const prepared = commits.prepareTransaction(root, path.join(root, '追踪/staging/manifest.json'));
const transaction = JSON.parse(fs.readFileSync(prepared.transaction_file, 'utf8'));
assert.deepEqual(transaction.provenance, { task_family_id: 'tf-a', workflow_id: 'wf-a', branch_id: 'wf-a', stage_attempt_id: 'sa-a', acceptance_status: 'accepted' });
NODE
}

@test "state machine reports a focused pointer without a durable task as authority missing" {
    mkdir -p "$PROJECT/追踪/workflow"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-missing","task_dir":"追踪/workflow/tasks/wf-missing","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON

    run node "$REPO/scripts/workflow-state-machine.js" inspect --project-root "$PROJECT" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'"status": "blocked_task_authority_missing"'* ]]
}

@test "new tasks use durable snapshots rather than the focus pointer as checkpoints" {
    run node "$REPO/scripts/workflow-state-machine.js" create --workflow-type long_write --project-root "$PROJECT" --scope "第1卷/第001章" --user-goal "写第001章" --json

    [ "$status" -eq 0 ]

    node - "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
const durablePath = `${task.task_dir}/task.json`;
assert.equal(task.runtime_guard.checkpoint_policy.checkpoint_path, durablePath);
assert.equal(task.runtime_guard.heartbeat.latest_trusted_artifact, durablePath);
const context = fs.readFileSync(path.join(root, task.task_dir, 'context.jsonl'), 'utf8');
assert.ok(context.includes(`"path":"${durablePath}"`));
assert.ok(!context.includes('追踪/workflow/current-task.json'));
NODE
}

@test "task authority consumers block missing and invalid focused durable snapshots" {
    mkdir -p "$PROJECT/追踪/workflow"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-missing","task_dir":"追踪/workflow/tasks/wf-missing","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON

    assert_authority_missing_for_all_consumers || return 1

    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-missing"
    cat > "$PROJECT/追踪/workflow/tasks/wf-missing/task.json" <<'JSON'
{"workflow_id":"wf-other","task_dir":"追踪/workflow/tasks/wf-missing","state_version":1}
JSON

    assert_authority_missing_for_all_consumers || return 1
}

@test "stale focus pointer identity fields remain advisory while durable task stays authoritative" {
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-stale"
    cat > "$PROJECT/追踪/workflow/tasks/wf-stale/task.json" <<'JSON'
{"workflow_id":"wf-stale","task_dir":"追踪/workflow/tasks/wf-stale","state_version":4,"workflow_type":"review_repair"}
JSON

    mkdir -p "$PROJECT/追踪/workflow"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-stale","task_dir":"追踪/workflow/tasks/wrong","focused_at":"2026-07-12T00:00:00.000Z","state_version":4}
JSON
    assert_stale_pointer_is_advisory || return 1

    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-stale","task_dir":"追踪/workflow/tasks/wf-stale","focused_at":"2026-07-12T00:00:00.000Z","state_version":3}
JSON
    assert_stale_pointer_is_advisory || return 1
}

assert_stale_pointer_is_advisory() {
    run node "$REPO/scripts/workflow-state-machine.js" inspect --project-root "$PROJECT" --json
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *'"focus_pointer_status": "stale"'* ]] || return 1
    [[ "$output" == *'"task_dir_mismatch"'* || "$output" == *'"state_version_mismatch"'* ]] || return 1

    run node "$REPO/scripts/context-assembler.js" --project-root "$PROJECT" --task prose --target 第1章 --json
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *'"status": "blocked_task_authority_missing"'* ]] || return 1

    run node "$REPO/scripts/workflow-task-inbox.js" --project-root "$PROJECT" --json
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *'"status": "blocked_task_authority_missing"'* ]] || return 1
}

assert_authority_missing_for_all_consumers() {
    run node "$REPO/scripts/workflow-state-machine.js" reconcile-runtime --project-root "$PROJECT" --workflow-id wf-missing --session-id test-session --json
    [ "$status" -eq 2 ] || return 1
    assert_blocked_task_authority_missing || return 1

    run node "$REPO/scripts/workflow-recover.js" --project-root "$PROJECT" --json
    [ "$status" -eq 2 ] || return 1
    assert_blocked_task_authority_missing || return 1

    run node "$REPO/scripts/workflow-review-batches.js" inspect --project-root "$PROJECT" --json
    [ "$status" -eq 2 ] || return 1
    assert_blocked_task_authority_missing || return 1

    run node "$REPO/scripts/context-assembler.js" --project-root "$PROJECT" --task prose --target 第1章 --json
    [ "$status" -eq 0 ] || return 1
    assert_blocked_task_authority_missing || return 1

    run node "$REPO/scripts/workflow-task-inbox.js" --project-root "$PROJECT" --json
    [ "$status" -eq 0 ] || return 1
    assert_blocked_task_authority_missing || return 1
}

assert_blocked_task_authority_missing() {
    [[ "$output" == *'"status": "blocked_task_authority_missing"'* ]] || return 1
    [[ "$output" != *'"status": "no_active_task"'* ]] || return 1
    [[ "$output" != *'"status": "blocked_invalid_current_task"'* ]] || return 1
}

@test "background task mutation preserves the focused rendered task" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));

function writeTask(id, version) {
  const task = { workflow_id: id, task_dir: `追踪/workflow/tasks/${id}`, state_version: version, workflow_type: 'review_repair' };
  const file = path.join(root, task.task_dir, 'task.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
  return task;
}

const background = writeTask('wf-background', 3);
const focused = writeTask('wf-focused', 7);
authority.writeFocusPointer(root, focused);
const markdown = path.join(root, '追踪/workflow/current-task.md');
fs.writeFileSync(markdown, '# wf-focused\n');

store.mutateTask({
  projectRoot: root,
  workflowId: background.workflow_id,
  expectedStateVersion: background.state_version,
  mutation: (task) => ({ ...task, repaired: true }),
  renderMarkdown: () => '# wf-background\n',
});

assert.equal(fs.readFileSync(markdown, 'utf8'), '# wf-focused\n');
assert.equal(authority.resolveTaskAuthority(root, 'wf-background').task.repaired, true);
assert.equal(authority.readFocusedTask(root).pointer.workflow_id, 'wf-focused');
NODE
}
