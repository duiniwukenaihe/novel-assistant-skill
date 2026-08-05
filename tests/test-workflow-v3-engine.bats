#!/usr/bin/env bats

# Task 3: V3 task store and engine atomicity. The task.json durable snapshot
# is the single source of truth; the engine commits once, rereads committed
# state, and only then renders any interaction. A neutral temp project is used
# so no real project layout is touched.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "V3 createTask persists all three contract versions with task.json as authority" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const task = engine.createTask(root, {
  workflow_id: 'wf-v3-create',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});

// The engine is the single writer: state_version starts at 1 after the first commit.
// The engine also owns the entry stage: createTask stamps it and callers may NOT
// supply current_stage (that ownership is exercised by the Subtask D tests below).
assert.equal(Number(task.state_version), 1);
assert.equal(task.current_stage, 'creative_entry');

// All three contract versions are stamped onto the durable task.json.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-create', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(Number(persisted.engine_version), 3);
assert.equal(Number(persisted.task_schema_version), 3);
assert.equal(Number(persisted.workflow_contract_version), 3);

// readTask returns the same committed snapshot as authority.
const reread = engine.readTask(root, 'wf-v3-create');
assert.equal(reread.workflow_id, 'wf-v3-create');
assert.equal(Number(reread.state_version), 1);
assert.equal(Number(reread.engine_version), 3);
NODE
}

@test "V3 applyStageResult rejects a stage mismatch before any write" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-mismatch', workflow_type: 'short_write',
  current_stage: 'planning_confirmation', user_goal: '写短篇',
});

// A stage result for the wrong stage_id must be rejected.
let threw = false;
try {
  engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: 'done_wrong', stage_id: 'drafting',
  });
} catch (error) {
  threw = true;
  if (!/stage_mismatch/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

// No commit occurred: the durable task is unchanged.
const reread = engine.readTask(root, task.workflow_id);
assert.equal(Number(reread.state_version), 1);
NODE
}

@test "V3 applyStageResult atomically persists pending_action, rereads, and returns Arbiter binding hash" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-apply', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });

const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice',
  code: 'choose_plan',
  stage_id: 'planning_confirmation',
  question: '选择方案',
  options: [
    { action_id: 'accept', label: '采用方案' },
    { action_id: 'chat', label: '进入 Chat 修改' },
  ],
});

// The returned task is the committed snapshot, advanced by exactly one version.
assert.equal(Number(outcome.task.state_version), 2);
assert.ok(outcome.task.pending_action, 'committed task must carry a pending action');

// The visible_response is rendered by the Arbiter off the committed state.
assert.ok(outcome.visible_response, 'applyStageResult must return the rendered visible_response');

// The committed durable task.json carries the same pending action and hash.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-apply', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.deepEqual(persisted.pending_action, outcome.task.pending_action);

// The rendered binding hash must equal the committed pending action's hash.
assert.equal(outcome.visible_response.binding.visible_choice_hash, persisted.pending_action.visible_choice_hash);
assert.equal(outcome.visible_response.binding.pending_action_id, persisted.pending_action.id);
assert.equal(Number(outcome.visible_response.binding.state_version), 2);
NODE
}

@test "V3 replaying the old expectedVersion throws WORKFLOW_TASK_CONFLICT" {
    node - "$REPO" "$PROJECT" <<'NODE'
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-replay', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });

engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: '选哪个',
  options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
});

// Replaying the stale expectedVersion must fail with WORKFLOW_TASK_CONFLICT.
let threw = false;
try {
  engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: '选哪个',
    options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
  });
} catch (error) {
  threw = true;
  if (error.code !== 'WORKFLOW_TASK_CONFLICT') process.exit(1);
}
if (!threw) process.exit(2);
NODE
}

@test "V3 resolveAuthorInput validates the four-field binding, atomically marks resolved, and returns the selection" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-resolve', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: '选择方案',
  options: [
    { action_id: 'accept', label: '采用方案' },
    { action_id: 'chat', label: '进入 Chat 修改' },
  ],
});
const committed = outcome.task;
const binding = outcome.visible_response.binding;

// Valid binding resolves to the chosen selection and advances the version.
const selection = engine.resolveAuthorInput(root, committed.workflow_id, committed.state_version, {
  workflow_id: binding.workflow_id,
  state_version: binding.state_version,
  pending_action_id: binding.pending_action_id,
  visible_choice_hash: binding.visible_choice_hash,
  choice: '1',
});

assert.equal(selection.action_id, 'accept');
assert.equal(selection.label, '采用方案');
assert.equal(Number(selection.number), 1);

// The pending action is now resolved in the durable task.json and advanced.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-resolve', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(persisted.pending_action.status, 'resolved');
assert.equal(Number(persisted.state_version), 3);
NODE
}

@test "V3 resolveAuthorInput rejects replay or tamper without another write" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-tamper', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: '选择方案',
  options: [
    { action_id: 'accept', label: '采用方案' },
    { action_id: 'chat', label: '进入 Chat 修改' },
  ],
});
const committed = outcome.task;
const binding = outcome.visible_response.binding;

function expectReject(label, payload, expectedVersion) {
  let threw = false;
  try {
    engine.resolveAuthorInput(root, committed.workflow_id, expectedVersion, payload);
  } catch (error) {
    threw = true;
    return error;
  }
  if (!threw) {
    console.error(`expected rejection for ${label}`);
    process.exit(1);
  }
  return null;
}

// A tampered visible_choice_hash must be rejected.
const tamperedHash = expectReject('tampered_hash', {
  workflow_id: binding.workflow_id,
  state_version: binding.state_version,
  pending_action_id: binding.pending_action_id,
  visible_choice_hash: 'deadbeef',
  choice: '1',
}, committed.state_version);

// A tampered pending_action_id must be rejected.
expectReject('tampered_pending_id', {
  workflow_id: binding.workflow_id,
  state_version: binding.state_version,
  pending_action_id: 'pa-v3-something-else',
  visible_choice_hash: binding.visible_choice_hash,
  choice: '1',
}, committed.state_version);

// A transplanted workflow_id must be rejected.
expectReject('tampered_workflow_id', {
  workflow_id: 'wf-foreign',
  state_version: binding.state_version,
  pending_action_id: binding.pending_action_id,
  visible_choice_hash: binding.visible_choice_hash,
  choice: '1',
}, committed.state_version);

// A mismatched state_version in the binding must be rejected.
expectReject('tampered_state_version', {
  workflow_id: binding.workflow_id,
  state_version: 999,
  pending_action_id: binding.pending_action_id,
  visible_choice_hash: binding.visible_choice_hash,
  choice: '1',
}, committed.state_version);

// Resolve legitimately once so the pending action becomes resolved.
engine.resolveAuthorInput(root, committed.workflow_id, committed.state_version, {
  workflow_id: binding.workflow_id,
  state_version: binding.state_version,
  pending_action_id: binding.pending_action_id,
  visible_choice_hash: binding.visible_choice_hash,
  choice: '2',
});

// Replay with the stale expectedVersion must throw WORKFLOW_TASK_CONFLICT.
let replayError = null;
try {
  engine.resolveAuthorInput(root, committed.workflow_id, committed.state_version, {
    workflow_id: binding.workflow_id,
    state_version: binding.state_version,
    pending_action_id: binding.pending_action_id,
    visible_choice_hash: binding.visible_choice_hash,
    choice: '2',
  });
} catch (error) {
  replayError = error;
}
assert.ok(replayError, 'replay must throw');
assert.equal(replayError.code, 'WORKFLOW_TASK_CONFLICT');

// No further write happened: the durable task remains at version 3, resolved.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-tamper', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(Number(persisted.state_version), 3);
assert.equal(persisted.pending_action.status, 'resolved');
NODE
}

@test "V3 read and commit reject a task whose durable versions are not all 3" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// Seed a legitimate V3 task, then tamper task.json so engine_version drifts
// away from 3. Any subsequent read or apply must reject without writing.
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-versions', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-versions', 'task.json');
const tampered = JSON.parse(fs.readFileSync(file, 'utf8'));
tampered.engine_version = 2;
fs.writeFileSync(file, `${JSON.stringify(tampered, null, 2)}\n`);

// readTask must reject a tampered engine_version.
let readThrew = false;
try {
  engine.readTask(root, task.workflow_id);
} catch (error) {
  readThrew = true;
  if (!/v3_engine_required/.test(error.message)) process.exit(1);
}
if (!readThrew) process.exit(2);

// applyStageResult must reject before any write, leaving the version unchanged.
let applyThrew = false;
try {
  engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: 'q',
    options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
  });
} catch (error) {
  applyThrew = true;
  if (!/v3_engine_required/.test(error.message)) process.exit(3);
}
if (!applyThrew) process.exit(4);

const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(Number(persisted.state_version), 1);
NODE
}

@test "V3 createTask honors an existing project workflow lock" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const stateStore = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));

// Acquire the project workflow lock exactly as another writer would, and hold
// it. createTask must not stomp over it; it must surface WORKFLOW_LOCKED and
// leave the project without a durable task for this workflow.
const release = stateStore.acquireProjectLock(root, 'external-writer');
try {
  let threw = false;
  try {
    engine.createTask(root, { workflow_id: 'wf-v3-locked', workflow_type: 'short_write', user_goal: '写短篇' });
  } catch (error) {
    threw = true;
    if (error.code !== 'WORKFLOW_LOCKED') process.exit(1);
  }
  if (!threw) process.exit(2);

  const dir = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-locked');
  assert.ok(!require('fs').existsSync(path.join(dir, 'task.json')), 'no task.json must be written under contention');
} finally {
  release();
}

// After the lock is released, createTask must succeed normally.
const task = engine.createTask(root, { workflow_id: 'wf-v3-locked', workflow_type: 'short_write', user_goal: '写短篇' });
assert.equal(Number(task.state_version), 1);
NODE
}

@test "named project lock stale takeover cannot delete a newly acquired competitor lock" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const store = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));
const lockDir = path.join(root, '追踪', 'workflow', '.atomic-stale-test.lock');
fs.mkdirSync(lockDir, { recursive: true });
fs.writeFileSync(path.join(lockDir, 'owner.json'), JSON.stringify({
  owner: 'expired-owner', token: 'expired', acquired_at: '2000-01-01T00:00:00.000Z',
}));

const originalRename = fs.renameSync;
fs.renameSync = function simulateCompetitor(source, target) {
  originalRename.call(fs, source, target);
  if (source === lockDir) {
    fs.mkdirSync(lockDir);
    fs.writeFileSync(path.join(lockDir, 'owner.json'), JSON.stringify({
      owner: 'new-competitor', token: 'new-token', acquired_at: new Date().toISOString(),
    }));
  }
};

let failure;
try {
  store.acquireNamedProjectLock(root, {
    relativeDir: path.join('追踪', 'workflow'),
    lockName: '.atomic-stale-test.lock',
    owner: 'stale-contender',
    ttlMs: 1,
    errorCode: 'WORKFLOW_EXECUTION_LOCKED',
    errorLabel: 'atomic stale test lock',
  });
} catch (error) {
  failure = error;
} finally {
  fs.renameSync = originalRename;
}
assert.equal(failure && failure.code, 'WORKFLOW_EXECUTION_LOCKED');
const owner = JSON.parse(fs.readFileSync(path.join(lockDir, 'owner.json'), 'utf8'));
assert.equal(owner.owner, 'new-competitor');
NODE
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
}

@test "V3 applyStageResult cannot overwrite a pending action with another pending action" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-overwrite', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });
const first = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: 'first',
  options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
});

// A second needs_author_choice result for the same stage must be rejected
// before any write; the committed pending action and version stay intact.
let threw = false;
try {
  engine.applyStageResult(root, first.task.workflow_id, first.task.state_version, {
    kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: 'second',
    options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
  });
} catch (error) {
  threw = true;
  if (!/pending_action_already_pending/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-overwrite', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(Number(persisted.state_version), 2);
assert.equal(persisted.pending_action.question, 'first');
NODE
}

@test "V3 resolveAuthorInput durably stores selection fields and resolved_at" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-durable', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: '选择方案',
  options: [{ action_id: 'accept', label: '采用方案' }, { action_id: 'chat', label: '进入 Chat 修改' }],
});
const binding = outcome.visible_response.binding;

const before = Date.now();
const selection = engine.resolveAuthorInput(root, outcome.task.workflow_id, outcome.task.state_version, {
  workflow_id: binding.workflow_id,
  state_version: binding.state_version,
  pending_action_id: binding.pending_action_id,
  visible_choice_hash: binding.visible_choice_hash,
  choice: '1',
});
const after = Date.now();

assert.equal(selection.action_id, 'accept');
assert.equal(selection.label, '采用方案');
assert.equal(Number(selection.number), 1);

// The durable task.json must carry the frozen selection fields and a valid
// resolved_at timestamp taken at resolve time, with the action marked resolved.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-durable', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(persisted.pending_action.status, 'resolved');
assert.deepEqual(persisted.pending_action.selection, { action_id: 'accept', label: '采用方案', number: 1 });
assert.ok(persisted.pending_action.resolved_at, 'resolved_at must be durably stored');
const resolvedAt = new Date(persisted.pending_action.resolved_at).getTime();
assert.ok(resolvedAt >= before && resolvedAt <= after, 'resolved_at must be the resolve moment');
assert.equal(Number(persisted.state_version), 3);
NODE
}

@test "V3 commitTask rereads the causal snapshot while still holding the project lock" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
const stateStore = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));

// Seed a real durable V3 task so commitTask has a snapshot to advance.
const created = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-lock-reread',
  workflow_type: 'short_write',
  current_stage: 'planning_confirmation',
  user_goal: '写短篇',
});

const lockDir = path.join(root, '追踪', 'workflow', '.workflow.lock');
const ownerFile = path.join(lockDir, 'owner.json');

// Monkeypatch ONLY authority.resolveTaskAuthority so it records whether the
// project workflow lock exists at the instant of each read. The original
// resolution is preserved (super) so task-store still reads real bytes.
const original = authority.resolveTaskAuthority;
const observations = [];
authority.resolveTaskAuthority = function patched(projectRoot, workflowId) {
  observations.push({ exists: fs.existsSync(ownerFile), lockDirExists: fs.existsSync(lockDir) });
  return original.call(this, projectRoot, workflowId);
};

let snapshot;
try {
  // Commit advances state_version to 2 and must reread under the same lock it
  // took for the mutation, returning the causal committed snapshot.
  snapshot = store.commitTask(root, created.workflow_id, created.state_version, (draft) => {
    draft.current_stage = 'drafting';
    return draft;
  });
} finally {
  authority.resolveTaskAuthority = original;
}

// Exactly one observation must have seen the lock present: the post-mutation
// causal read performed by commitTask itself while still holding the lock.
const readsUnderLock = observations.filter((obs) => obs.exists && obs.lockDirExists);
assert.equal(
  readsUnderLock.length,
  1,
  `commitTask must reread the causal snapshot while holding the lock; observations=${JSON.stringify(observations)}`,
);

// The returned snapshot reflects the committed mutation (version advanced).
assert.equal(Number(snapshot.state_version), 2);
assert.equal(snapshot.current_stage, 'drafting');

// After commitTask returns, the project lock is fully released.
assert.ok(!fs.existsSync(lockDir), 'project workflow lock must be released after commitTask returns');
NODE
}

@test "V3 a completed result cannot clear a still-pending action" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// Seed a needs_author_choice so a status=pending action is committed (v2).
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
// Seed onto planning_confirmation via the store layer: only the store may stamp
// current_stage; the engine rejects any caller-supplied value.
const task = store.createTaskRecord(root, { workflow_id: 'wf-v3-clear', workflow_type: 'short_write', current_stage: 'planning_confirmation', user_goal: '写短篇' });
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: '选择方案',
  options: [{ action_id: 'accept', label: '采用方案' }, { action_id: 'chat', label: '进入 Chat 修改' }],
});

const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-clear', 'task.json');
const beforeBytes = fs.readFileSync(file);

// A later completed result, carrying the current expectedVersion, must NOT be
// allowed to delete the in-flight pending action. It must reject before any
// write, leaving task.json state_version and pending_action byte-for-byte intact.
let threw = false;
try {
  engine.applyStageResult(root, outcome.task.workflow_id, outcome.task.state_version, {
    kind: 'completed', code: 'done', stage_id: 'planning_confirmation',
  });
} catch (error) {
  threw = true;
  if (!/pending_action_already_pending/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

const afterBytes = fs.readFileSync(file);
// Byte-for-byte unchanged: no write occurred at all.
assert.ok(beforeBytes.equals(afterBytes), 'task.json must be byte-for-byte unchanged');

const persisted = JSON.parse(afterBytes.toString('utf8'));
assert.equal(Number(persisted.state_version), 2);
assert.equal(persisted.pending_action.status, 'pending');
assert.equal(persisted.pending_action.question, '选择方案');
NODE
}

# Task 4 subtask A: the canonical short lifecycle graph and the engine's
# graph-driven atomic transition. nextNode is the only transition validator;
# Engine applies its verdict inside the same commitTask mutation as the
# StageResult. Wrappers must not write current_stage themselves.

@test "V3 SHORT_GRAPH is frozen and matches the canonical brief structure" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo] = process.argv.slice(2);
const { SHORT_GRAPH } = require(path.join(repo, 'scripts/lib/workflow-v3/short-graph.js'));

assert.ok(Object.isFrozen(SHORT_GRAPH), 'SHORT_GRAPH must be frozen at top level');

// Exact node set, author_phase labels, and next lists from the brief.
assert.deepEqual(Object.keys(SHORT_GRAPH), [
  'creative_entry', 'material_positioning', 'setting', 'section_outline',
  'planning_confirmation', 'section_brief', 'section_draft', 'machine_gate',
  'section_repair', 'story_gate', 'section_accept', 'assembly',
  'editorial_review', 'deslop', 'final_check',
]);
assert.equal(SHORT_GRAPH.creative_entry.author_phase, '创作入口');
assert.deepEqual(SHORT_GRAPH.creative_entry.next, ['material_positioning']);
assert.equal(SHORT_GRAPH.machine_gate.author_phase, '写当前小节');
assert.deepEqual(SHORT_GRAPH.machine_gate.next, ['story_gate', 'section_repair']);
assert.deepEqual(SHORT_GRAPH.story_gate.next, ['section_accept', 'section_repair']);
assert.equal(SHORT_GRAPH.section_accept.author_phase, '采用当前小节');
assert.deepEqual(SHORT_GRAPH.section_accept.next, ['section_brief', 'assembly', 'machine_gate']);
assert.equal(SHORT_GRAPH.editorial_review.author_phase, '全篇收束');
assert.deepEqual(SHORT_GRAPH.editorial_review.next, ['deslop', 'planning_confirmation', 'machine_gate']);
assert.equal(SHORT_GRAPH.final_check.author_phase, '终检');
assert.deepEqual(SHORT_GRAPH.final_check.next, []);

// Every non-terminal next target must be a defined node.
for (const [node, def] of Object.entries(SHORT_GRAPH)) {
  for (const target of def.next) {
    assert.ok(Object.prototype.hasOwnProperty.call(SHORT_GRAPH, target), `dangling edge ${node} -> ${target}`);
  }
}
NODE
}

@test "V3 nextNode advances a single-next node on completed without a target" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo] = process.argv.slice(2);
const { nextNode } = require(path.join(repo, 'scripts/lib/workflow-v3/short-graph.js'));

// Single-next: completed advances automatically, no next_stage required.
assert.equal(
  nextNode({ current_stage: 'creative_entry' }, { kind: 'completed', stage_id: 'creative_entry' }),
  'material_positioning',
);
assert.equal(
  nextNode({ current_stage: 'planning_confirmation' }, { kind: 'completed', stage_id: 'planning_confirmation' }),
  'section_brief',
);
NODE
}

@test "V3 nextNode requires next_stage on a multi-next completed result and rejects outside targets" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo] = process.argv.slice(2);
const { nextNode } = require(path.join(repo, 'scripts/lib/workflow-v3/short-graph.js'));

// Multi-next: completed without next_stage is rejected.
let threw = false;
try {
  nextNode({ current_stage: 'machine_gate' }, { kind: 'completed', stage_id: 'machine_gate' });
} catch (error) {
  threw = true;
  if (!/next_stage_required/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

// Multi-next: a target outside the node's next list is rejected.
threw = false;
try {
  nextNode({ current_stage: 'machine_gate' }, { kind: 'completed', stage_id: 'machine_gate', next_stage: 'section_brief' });
} catch (error) {
  threw = true;
  if (!/next_stage_outside_node/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(3);

// Multi-next: a valid in-list target advances.
assert.equal(
  nextNode({ current_stage: 'machine_gate' }, { kind: 'completed', stage_id: 'machine_gate', next_stage: 'story_gate' }),
  'story_gate',
);
assert.equal(
  nextNode({ current_stage: 'machine_gate' }, { kind: 'completed', stage_id: 'machine_gate', next_stage: 'section_repair' }),
  'section_repair',
);
assert.equal(
  nextNode({ current_stage: 'story_gate' }, { kind: 'completed', stage_id: 'story_gate', next_stage: 'section_repair' }),
  'section_repair',
);
NODE
}

@test "V3 nextNode keeps retryable_internal, needs_author_choice, and blocked on the current node" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo] = process.argv.slice(2);
const { nextNode } = require(path.join(repo, 'scripts/lib/workflow-v3/short-graph.js'));

// Non-completed results never advance; the node stays put regardless of next list.
assert.equal(
  nextNode({ current_stage: 'machine_gate' }, { kind: 'retryable_internal', stage_id: 'machine_gate' }),
  'machine_gate',
);
assert.equal(
  nextNode({ current_stage: 'planning_confirmation' }, { kind: 'needs_author_choice', stage_id: 'planning_confirmation' }),
  'planning_confirmation',
);
assert.equal(
  nextNode({ current_stage: 'section_draft' }, { kind: 'blocked', stage_id: 'section_draft' }),
  'section_draft',
);
NODE
}

@test "V3 applyStageResult advances a single-next completed node inside the same single version commit" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// Start on the engine's canonical entry node (creative_entry) so the transition
// is graph-driven. The engine stamps the entry stage; callers must NOT supply it.
const task = engine.createTask(root, {
  workflow_id: 'wf-v4-advance',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
assert.equal(task.current_stage, 'creative_entry', 'createTask must stamp the entry stage');
const startVersion = Number(task.state_version);

const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'material_ready', stage_id: 'creative_entry',
});

// The committed current_stage advanced to the single next node, and the
// version advanced by exactly one in the SAME commit mutation.
assert.equal(outcome.task.current_stage, 'material_positioning');
assert.equal(Number(outcome.task.state_version), startVersion + 1);
assert.equal(outcome.visible_response, null, 'a completed result carries no visible_response');

// The durable task.json reflects the single advanced version and stage.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v4-advance', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(persisted.current_stage, 'material_positioning');
assert.equal(Number(persisted.state_version), startVersion + 1);
NODE
}

@test "V3 applyStageResult rejects a multi-next completed result without next_stage without writing" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// machine_gate is a multi-next node: completed without next_stage must reject.
// Seed onto the non-entry node via the store layer; the engine owns the entry
// stage and rejects any caller-supplied current_stage.
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-v4-multinext',
  workflow_type: 'short_write',
  current_stage: 'machine_gate',
  user_goal: '写短篇',
});
const startVersion = Number(task.state_version);
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v4-multinext', 'task.json');
const beforeBytes = fs.readFileSync(file);

let threw = false;
try {
  engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: 'gate_decision', stage_id: 'machine_gate',
  });
} catch (error) {
  threw = true;
  if (!/next_stage_required/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

// No write occurred: the durable task is byte-for-byte unchanged.
const afterBytes = fs.readFileSync(file);
assert.ok(beforeBytes.equals(afterBytes), 'task.json must be byte-for-byte unchanged');
const persisted = JSON.parse(afterBytes.toString('utf8'));
assert.equal(persisted.current_stage, 'machine_gate');
assert.equal(Number(persisted.state_version), startVersion);
NODE
}

@test "V3 applyStageResult rejects a multi-next completed result with an outside target without writing" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// section_accept is a multi-next node whose next list is [section_brief, assembly].
// A target outside that list must be rejected without writing. Seed onto the
// non-entry node via the store layer; the engine owns the entry stage.
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-v4-outside',
  workflow_type: 'short_write',
  current_stage: 'section_accept',
  user_goal: '写短篇',
});
const startVersion = Number(task.state_version);
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v4-outside', 'task.json');
const beforeBytes = fs.readFileSync(file);

let threw = false;
try {
  engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: 'accept_decision', stage_id: 'section_accept', next_stage: 'final_check',
  });
} catch (error) {
  threw = true;
  if (!/next_stage_outside_node/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

const afterBytes = fs.readFileSync(file);
assert.ok(beforeBytes.equals(afterBytes), 'task.json must be byte-for-byte unchanged');
const persisted = JSON.parse(afterBytes.toString('utf8'));
assert.equal(persisted.current_stage, 'section_accept');
assert.equal(Number(persisted.state_version), startVersion);

// A valid in-list multi-next target advances inside a single version commit.
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'accept_decision', stage_id: 'section_accept', next_stage: 'assembly',
});
assert.equal(outcome.task.current_stage, 'assembly');
assert.equal(Number(outcome.task.state_version), startVersion + 1);
NODE
}

@test "V3 section acceptance marks the accepted feedback plan as applied" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));

const created = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-feedback-applied',
  workflow_type: 'short_write',
  current_stage: 'section_accept',
  user_goal: '写短篇',
});
const accepted = store.commitTask(root, created.workflow_id, created.state_version, (task) => ({
  ...task,
  pending_feedback: {
    id: 'feedback-neutral',
    status: 'accepted',
    section_index: 1,
    accepted_plan: {
      summary: '只修当前小节并保持既定结局。',
      affected_sections: [1],
    },
  },
  feedback_revision_queue: {
    status: 'running', current_section_index: 1, affected_sections: [1],
    completed_sections: [], items: [{ section_index: 1, status: 'pending' }],
  },
}));
const outcome = engine.applyStageResult(root, accepted.workflow_id, accepted.state_version, {
  kind: 'completed',
  code: 'short_section_accepted',
  stage_id: 'section_accept',
  section_index: 1,
  next_stage: 'assembly',
});

assert.equal(outcome.task.current_stage, 'assembly');
assert.equal(outcome.task.pending_feedback.status, 'applied');
assert.ok(outcome.task.pending_feedback.applied_at);
assert.equal(outcome.task.pending_feedback.applied_section_index, 1);
assert.equal(outcome.task.feedback_revision_queue.status, 'completed');
assert.equal(outcome.task.feedback_revision_queue.current_section_index, null);
assert.deepEqual(outcome.task.feedback_revision_queue.completed_sections, [1]);
assert.equal(outcome.task.feedback_revision_queue.items[0].status, 'accepted');
assert.equal(outcome.task.feedback_revision_queue.items[0].accepted_commit_id, '');

const multi = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-feedback-multi', workflow_type: 'short_write',
  current_stage: 'section_accept', user_goal: '逐节回炉两节',
});
const multiAccepted = store.commitTask(root, multi.workflow_id, multi.state_version, (task) => ({
  ...task,
  pending_feedback: { id: 'feedback-multi', status: 'accepted', section_index: 1,
    accepted_plan: { affected_sections: [1, 2] } },
  feedback_revision_queue: {
    status: 'running', feedback_id: 'feedback-multi', current_section_index: 1,
    affected_sections: [1, 2], completed_sections: [],
    items: [{ section_index: 1, status: 'pending' }, { section_index: 2, status: 'pending' }],
  },
}));
const firstOfTwo = engine.applyStageResult(root, multiAccepted.workflow_id, multiAccepted.state_version, {
  kind: 'completed', code: 'short_section_accepted', stage_id: 'section_accept',
  section_index: 1, next_section: 2, next_stage: 'section_brief',
});
assert.equal(firstOfTwo.task.feedback_revision_queue.status, 'running');
assert.equal(firstOfTwo.task.feedback_revision_queue.current_section_index, 2);
assert.equal(firstOfTwo.task.pending_feedback.status, 'accepted',
  'a multi-section accepted plan remains active until the final affected section is accepted');

const recovery = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-feedback-recovery', workflow_type: 'short_write',
  current_stage: 'section_accept', user_goal: '写短篇',
});
const recoveryAccepted = store.commitTask(root, recovery.workflow_id, recovery.state_version, (task) => ({
  ...task,
  pending_feedback: { id: 'feedback-recovery', status: 'accepted', section_index: 1,
    accepted_plan: { affected_sections: [1] } },
}));
const recovered = engine.applyStageResult(root, recoveryAccepted.workflow_id, recoveryAccepted.state_version, {
  kind: 'completed', code: 'accept_candidate_changed_after_gates',
  stage_id: 'section_accept', section_index: 1, next_stage: 'machine_gate',
});
assert.equal(recovered.task.current_stage, 'machine_gate');
assert.equal(recovered.task.pending_feedback.status, 'accepted');

const assemblyRecovery = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-assembly-recheck-next', workflow_type: 'short_write',
  current_stage: 'section_accept', user_goal: '逐节复验旧项目现稿',
});
const assemblyQueued = store.commitTask(root, assemblyRecovery.workflow_id, assemblyRecovery.state_version, (task) => ({
  ...task,
  feedback_revision_queue: {
    status: 'running', source_stage: 'full_story_assembly', current_section_index: 1,
    affected_sections: [1, 2], completed_sections: [],
    items: [
      { section_index: 1, status: 'pending' },
      { section_index: 2, status: 'pending' },
    ],
  },
  stage_execution: { status: 'running', stage_id: 'section_accept', section_index: 1 },
}));
const nextRecheck = engine.applyStageResult(root, assemblyQueued.workflow_id, assemblyQueued.state_version, {
  kind: 'completed', code: 'short_section_accepted', stage_id: 'section_accept',
  section_index: 1, next_section: 2, next_stage: 'machine_gate',
});
assert.equal(nextRecheck.task.current_stage, 'machine_gate');
assert.equal(nextRecheck.task.stage_execution.section_index, 2,
  'the next gate must bind the queue cursor, not the section just accepted');
assert.equal(nextRecheck.task.feedback_revision_queue.current_section_index, 2);
assert.deepEqual(nextRecheck.task.feedback_revision_queue.completed_sections, [1]);
NODE
}

@test "V3 applyStageResult keeps the current node on needs_author_choice and records the pending action" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));

// needs_author_choice must NOT advance current_stage; the node stays put and a
// pending action is recorded inside the single version commit. Seed the
// non-entry node through the internal store so this test does not reopen the
// public createTask entry-stage contract.
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-v4-stay',
  workflow_type: 'short_write',
  current_stage: 'planning_confirmation',
  user_goal: '写短篇',
});
const startVersion = Number(task.state_version);

const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_plan', stage_id: 'planning_confirmation', question: '选择方案',
  options: [
    { action_id: 'accept', label: '采用方案' },
    { action_id: 'chat', label: '进入 Chat 修改' },
  ],
});

assert.equal(outcome.task.current_stage, 'planning_confirmation');
assert.equal(Number(outcome.task.state_version), startVersion + 1);
assert.ok(outcome.task.pending_action, 'pending action must be recorded without advancing the node');
assert.equal(outcome.task.pending_action.status, 'pending');

const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v4-stay', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(persisted.current_stage, 'planning_confirmation');
NODE
}

# ---------------------------------------------------------------------------
# Subtask D: Engine-owned entry and terminal completion. The graph exports the
# entry stage; createTask is the only authority that stamps it and rejects any
# caller-supplied current_stage; the CLI no longer owns the entry stage; and a
# completed result on the terminal final_check node completes the lifecycle in
# one atomic state-version commit, while retryable/blocked at final_check do not.
# ---------------------------------------------------------------------------

# The canonical short entry stage lives on the graph module, not the CLI.

@test "V3 SHORT_ENTRY_STAGE is exported from short-graph and equals creative_entry" {
    node - "$REPO" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo] = process.argv.slice(2);
const { SHORT_ENTRY_STAGE, SHORT_GRAPH } = require(path.join(repo, 'scripts/lib/workflow-v3/short-graph.js'));

assert.equal(SHORT_ENTRY_STAGE, 'creative_entry', 'SHORT_ENTRY_STAGE must be creative_entry');
assert.ok(
  Object.prototype.hasOwnProperty.call(SHORT_GRAPH, SHORT_ENTRY_STAGE),
  'SHORT_ENTRY_STAGE must be a real graph node',
);
NODE
}

# createTask is the only authority over the entry stage. Any caller-supplied
# current_stage must be rejected before task.json is written.

@test "V3 createTask rejects a caller-supplied current_stage and stamps the engine entry stage" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// A caller that supplies current_stage must be rejected outright.
let threw = false;
try {
  engine.createTask(root, {
    workflow_id: 'wf-v3-reject-stage',
    workflow_type: 'short_write',
    current_stage: 'planning_confirmation',
    user_goal: '写短篇',
  });
} catch (error) {
  threw = true;
  if (!/current_stage_owned_by_engine/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

// No durable task may be written for a rejected creation.
const dir = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-reject-stage');
assert.ok(!fs.existsSync(path.join(dir, 'task.json')), 'rejected createTask must not write task.json');

// A caller that supplies the canonical entry value must STILL be rejected: the
// engine owns the field, so even a correct caller value must not pass through.
threw = false;
try {
  engine.createTask(root, {
    workflow_id: 'wf-v3-reject-entry',
    workflow_type: 'short_write',
    current_stage: 'creative_entry',
    user_goal: '写短篇',
  });
} catch (error) {
  threw = true;
  if (!/current_stage_owned_by_engine/.test(error.message)) process.exit(3);
}
if (!threw) process.exit(4);

// Omitting current_stage lands on the engine entry stage.
const task = engine.createTask(root, {
  workflow_id: 'wf-v3-stamp-entry',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
assert.equal(task.current_stage, 'creative_entry');

const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-stamp-entry', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(persisted.current_stage, 'creative_entry');
NODE
}

# The terminal final_check node has no outgoing edge. A completed result there
# is legal: it stays the current node and completes the lifecycle in the same
# single state-version commit. Only a completed result completes the task;
# retryable_internal and blocked at final_check must not.

@test "V3 applyStageResult completes the task and lifecycle on a final_check completed result in one version commit" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// Reach the terminal node through REAL graph transitions: a public short
// enters at creative_entry and the engine drives every hop via nextNode.
// creative_entry -> ... -> deslop -> final_check.
const task = engine.createTask(root, {
  workflow_id: 'wf-v3-terminal',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});

// Single-next chain: creative_entry -> material_positioning -> setting ->
// section_outline -> planning_confirmation -> section_brief -> section_draft.
let current = task;
const singleChain = ['creative_entry', 'material_positioning', 'setting', 'section_outline', 'planning_confirmation', 'section_brief', 'section_draft'];
for (const stage of singleChain) {
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'advance', stage_id: stage,
  }).task;
}

// machine_gate is multi-next: choose story_gate (-> section_accept).
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'gate_pass', stage_id: 'machine_gate', next_stage: 'story_gate',
}).task;
// story_gate is multi-next: choose section_accept after a passing review.
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'story_pass', stage_id: 'story_gate', next_stage: 'section_accept',
}).task;
// section_accept is multi-next: choose assembly (-> editorial_review).
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'accept_assembly', stage_id: 'section_accept', next_stage: 'assembly',
}).task;
// assembly -> editorial_review (single next).
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'assembled', stage_id: 'assembly', next_stage: 'editorial_review',
}).task;
// editorial_review is multi-next: choose deslop (-> final_check).
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'review_deslop', stage_id: 'editorial_review', next_stage: 'deslop',
}).task;
// deslop -> final_check (single next, terminal node).
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'deslop_done', stage_id: 'deslop',
}).task;
assert.equal(current.current_stage, 'final_check', 'graph must land on the terminal node');

// The task is not yet completed before the final result.
assert.notEqual(current.status, 'completed');
const preVersion = Number(current.state_version);
const before = Date.now();

// A completed result on the terminal node completes the lifecycle atomically:
// current_stage STAYS final_check, status and lifecycle.status become completed,
// completed_at is stamped, and state_version advances exactly once.
const outcome = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'final_ok', stage_id: 'final_check',
});
const after = Date.now();

assert.equal(outcome.task.current_stage, 'final_check', 'terminal node stays current');
assert.equal(Number(outcome.task.state_version), preVersion + 1, 'single version bump');
assert.equal(outcome.task.status, 'completed');
assert.ok(outcome.task.lifecycle, 'lifecycle object must be present');
assert.equal(outcome.task.lifecycle.status, 'completed');
assert.equal(outcome.task.stage_execution.status, 'completed');
assert.equal(outcome.task.stage_execution.stage_id, 'final_check');
assert.ok(outcome.task.stage_execution.completed_at, 'terminal stage_execution must be closed');
assert.ok(outcome.task.completed_at, 'completed_at must be stamped');
const completedAt = new Date(outcome.task.completed_at).getTime();
assert.ok(completedAt >= before && completedAt <= after, 'completed_at is the completion moment');
assert.equal(outcome.visible_response, null, 'a completed terminal result carries no interaction');

// The durable task.json carries the same completed lifecycle.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-terminal', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(persisted.current_stage, 'final_check');
assert.equal(persisted.status, 'completed');
assert.equal(persisted.lifecycle.status, 'completed');
assert.equal(persisted.stage_execution.status, 'completed');
assert.equal(persisted.stage_execution.completed_at, outcome.task.stage_execution.completed_at);
assert.equal(persisted.completed_at, outcome.task.completed_at);
assert.equal(Number(persisted.state_version), preVersion + 1);
NODE
}

@test "V3 applyStageResult does not complete the task on retryable_internal or blocked at final_check" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// Reach the terminal node through the REAL graph chain.
const task = engine.createTask(root, {
  workflow_id: 'wf-v3-no-complete',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
let current = task;
const singleChain = ['creative_entry', 'material_positioning', 'setting', 'section_outline', 'planning_confirmation', 'section_brief', 'section_draft'];
for (const stage of singleChain) {
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'advance', stage_id: stage,
  }).task;
}
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'gate_pass', stage_id: 'machine_gate', next_stage: 'story_gate',
}).task;
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'story_pass', stage_id: 'story_gate', next_stage: 'section_accept',
}).task;
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'accept_assembly', stage_id: 'section_accept', next_stage: 'assembly',
}).task;
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'assembled', stage_id: 'assembly', next_stage: 'editorial_review',
}).task;
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'review_deslop', stage_id: 'editorial_review', next_stage: 'deslop',
}).task;
current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'completed', code: 'deslop_done', stage_id: 'deslop',
}).task;
assert.equal(current.current_stage, 'final_check');

const preVersion = Number(current.state_version);
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-no-complete', 'task.json');

// A retryable_internal result at final_check must NOT complete the task.
let retry = engine.applyStageResult(root, current.workflow_id, current.state_version, {
  kind: 'retryable_internal', code: 'retry_deslop', stage_id: 'final_check',
});
assert.equal(retry.task.current_stage, 'final_check');
assert.notEqual(retry.task.status, 'completed');
assert.ok(!retry.task.completed_at, 'retryable_internal must not stamp completed_at');
assert.equal(Number(retry.task.state_version), preVersion + 1, 'retry still bumps the version');

// A blocked result at final_check must NOT complete the task either.
let blocked = engine.applyStageResult(root, retry.task.workflow_id, retry.task.state_version, {
  kind: 'blocked', code: 'final_blocked', stage_id: 'final_check',
});
assert.equal(blocked.task.current_stage, 'final_check');
assert.notEqual(blocked.task.status, 'completed');
assert.ok(!blocked.task.completed_at, 'blocked must not stamp completed_at');

// The durable task.json confirms the lifecycle was never completed.
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.notEqual(persisted.status, 'completed');
assert.ok(!persisted.completed_at, 'durable task must not carry completed_at');
NODE
}

# ---------------------------------------------------------------------------
# Task 4 review fix D3: terminal closure is final. Once a completed result has
# closed the lifecycle on the terminal final_check node, no further result and
# no resolve may mutate the task — the lifecycle is over. Applying another
# completed result, a needs_author_choice result, or resolving on the completed
# task must throw workflow_already_completed and leave task.json byte-for-byte
# unchanged. Each case drives the REAL graph chain to a completed final_check,
# then replays against the LATEST committed version so the rejection is the
# completion guard, not a stale-version conflict.
# ---------------------------------------------------------------------------

@test "V3 applyStageResult rejects a second completed result after final_check completion without writing" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// Drive the REAL graph chain to a completed terminal final_check. The same
// sequence the terminal-completion test uses: single-next chain to
// section_draft, then the multi-next hops, deslop -> final_check, then the
// closing completed result on the terminal node.
function reachCompleted(id) {
  let current = engine.createTask(root, { workflow_id: id, workflow_type: 'short_write', user_goal: '写短篇' });
  const singleChain = ['creative_entry', 'material_positioning', 'setting', 'section_outline', 'planning_confirmation', 'section_brief', 'section_draft'];
  for (const stage of singleChain) {
    current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
      kind: 'completed', code: 'advance', stage_id: stage,
    }).task;
  }
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'gate_pass', stage_id: 'machine_gate', next_stage: 'story_gate',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'story_pass', stage_id: 'story_gate', next_stage: 'section_accept',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'accept_assembly', stage_id: 'section_accept', next_stage: 'assembly',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'assembled', stage_id: 'assembly', next_stage: 'editorial_review',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'review_deslop', stage_id: 'editorial_review', next_stage: 'deslop',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'deslop_done', stage_id: 'deslop',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'final_ok', stage_id: 'final_check',
  }).task;
  return current;
}

const completed = reachCompleted('wf-v3-closed-completed');
assert.equal(completed.status, 'completed', 'setup must reach a completed lifecycle');
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-closed-completed', 'task.json');
const beforeBytes = fs.readFileSync(file);

// A second completed result, carrying the LATEST expectedVersion, must be
// rejected as workflow_already_completed — not applied, not a version conflict.
let threw = false;
try {
  engine.applyStageResult(root, completed.workflow_id, completed.state_version, {
    kind: 'completed', code: 'final_again', stage_id: 'final_check',
  });
} catch (error) {
  threw = true;
  if (!/workflow_already_completed/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

// Byte-for-byte unchanged: no write occurred at all.
const afterBytes = fs.readFileSync(file);
assert.ok(beforeBytes.equals(afterBytes), 'task.json must be byte-for-byte unchanged');
NODE
}

@test "V3 applyStageResult rejects a needs_author_choice result after final_check completion without writing" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

function reachCompleted(id) {
  let current = engine.createTask(root, { workflow_id: id, workflow_type: 'short_write', user_goal: '写短篇' });
  const singleChain = ['creative_entry', 'material_positioning', 'setting', 'section_outline', 'planning_confirmation', 'section_brief', 'section_draft'];
  for (const stage of singleChain) {
    current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
      kind: 'completed', code: 'advance', stage_id: stage,
    }).task;
  }
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'gate_pass', stage_id: 'machine_gate', next_stage: 'story_gate',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'story_pass', stage_id: 'story_gate', next_stage: 'section_accept',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'accept_assembly', stage_id: 'section_accept', next_stage: 'assembly',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'assembled', stage_id: 'assembly', next_stage: 'editorial_review',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'review_deslop', stage_id: 'editorial_review', next_stage: 'deslop',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'deslop_done', stage_id: 'deslop',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'final_ok', stage_id: 'final_check',
  }).task;
  return current;
}

const completed = reachCompleted('wf-v3-closed-choice');
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-closed-choice', 'task.json');
const beforeBytes = fs.readFileSync(file);

// A needs_author_choice result after completion must be rejected the same way:
// the lifecycle is closed, so no new pending action may be opened. Two valid
// options are used (the valid count) so the rejection must come from the
// completion guard, not a secondary option-count check.
let threw = false;
try {
  engine.applyStageResult(root, completed.workflow_id, completed.state_version, {
    kind: 'needs_author_choice', code: 'choose_after_done', stage_id: 'final_check',
    question: '完成后还能选吗', options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
  });
} catch (error) {
  threw = true;
  if (!/workflow_already_completed/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

const afterBytes = fs.readFileSync(file);
assert.ok(beforeBytes.equals(afterBytes), 'task.json must be byte-for-byte unchanged');
NODE
}

@test "V3 resolveAuthorInput rejects a resolve after final_check completion without writing" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

function reachCompleted(id) {
  let current = engine.createTask(root, { workflow_id: id, workflow_type: 'short_write', user_goal: '写短篇' });
  const singleChain = ['creative_entry', 'material_positioning', 'setting', 'section_outline', 'planning_confirmation', 'section_brief', 'section_draft'];
  for (const stage of singleChain) {
    current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
      kind: 'completed', code: 'advance', stage_id: stage,
    }).task;
  }
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'gate_pass', stage_id: 'machine_gate', next_stage: 'story_gate',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'story_pass', stage_id: 'story_gate', next_stage: 'section_accept',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'accept_assembly', stage_id: 'section_accept', next_stage: 'assembly',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'assembled', stage_id: 'assembly', next_stage: 'editorial_review',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'review_deslop', stage_id: 'editorial_review', next_stage: 'deslop',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'deslop_done', stage_id: 'deslop',
  }).task;
  current = engine.applyStageResult(root, current.workflow_id, current.state_version, {
    kind: 'completed', code: 'final_ok', stage_id: 'final_check',
  }).task;
  return current;
}

const completed = reachCompleted('wf-v3-closed-resolve');
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-closed-resolve', 'task.json');
const beforeBytes = fs.readFileSync(file);

// Resolving on a completed task (which has no pending action) must surface the
// SAME terminal-closure error, not pending_action_missing, so closure is the
// consistent reason regardless of which entry point is replayed.
let threw = false;
try {
  engine.resolveAuthorInput(root, completed.workflow_id, completed.state_version, {
    workflow_id: completed.workflow_id,
    state_version: completed.state_version,
    pending_action_id: 'pa-v3-anything',
    visible_choice_hash: 'deadbeef',
    choice: '1',
  });
} catch (error) {
  threw = true;
  if (!/workflow_already_completed/.test(error.message)) process.exit(1);
}
if (!threw) process.exit(2);

const afterBytes = fs.readFileSync(file);
assert.ok(beforeBytes.equals(afterBytes), 'task.json must be byte-for-byte unchanged');
NODE
}

# ---------------------------------------------------------------------------
# Task 5: Engine persistence of a compact retry_state for retryable_internal.
# task.json remains the sole source of truth — there is no retry sidecar. A
# retryable_internal result records {stage_id, failure_family, count} in the
# SAME single state-version commit; the same stage+family accumulates, a
# different family resets count to 1, and any non-retryable result clears it.
# failure_family comes from the structured StageResult field, falling back to
# code when missing.
# ---------------------------------------------------------------------------

@test "V3 retryable_internal persists retry_state in the same single version commit and accumulates by family" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));

// Seed onto setting via the store layer; the engine owns the entry stage.
let task = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-retry', workflow_type: 'short_write',
  current_stage: 'setting', user_goal: '写短篇',
});
const startVersion = Number(task.state_version);

// A retryable_internal result carrying a structured failure_family records
// retry_state with count=1 inside the SAME commit that bumps the version.
const first = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'retryable_internal', code: 'missing_protagonist_identity', stage_id: 'setting',
  failure_family: 'character_contract',
});
assert.equal(Number(first.task.state_version), startVersion + 1, 'retry bumps version once');
assert.ok(first.task.retry_state, 'retry_state must be persisted');
assert.equal(first.task.retry_state.stage_id, 'setting');
assert.equal(first.task.retry_state.failure_family, 'character_contract');
assert.equal(Number(first.task.retry_state.count), 1);
assert.equal(first.visible_response, null, 'retryable carries no interaction');

// The durable task.json mirrors the committed retry_state exactly.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-retry', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.deepEqual(persisted.retry_state, first.task.retry_state);

// A second identical-family failure on the same stage accumulates to count=2.
const second = engine.applyStageResult(root, first.task.workflow_id, first.task.state_version, {
  kind: 'retryable_internal', code: 'missing_protagonist_identity', stage_id: 'setting',
  failure_family: 'character_contract',
});
assert.equal(Number(second.task.state_version), startVersion + 2);
assert.equal(second.task.retry_state.failure_family, 'character_contract');
assert.equal(Number(second.task.retry_state.count), 2, 'same family accumulates');
NODE
}

@test "V3 retryable_internal falls back to code for failure_family and resets on a different family" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));

let task = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-fallback', workflow_type: 'short_write',
  current_stage: 'setting', user_goal: '写短篇',
});

// A retryable_internal result WITHOUT a structured failure_family falls back to
// the result code as the family, so retry_state is still recorded.
const first = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'retryable_internal', code: 'missing_protagonist_identity', stage_id: 'setting',
});
assert.equal(first.task.retry_state.failure_family, 'missing_protagonist_identity',
  'family falls back to code');

// A different family on the same stage resets count to 1.
const second = engine.applyStageResult(root, first.task.workflow_id, first.task.state_version, {
  kind: 'retryable_internal', code: 'outline_blocked', stage_id: 'setting',
  failure_family: 'outline_narrative',
});
assert.equal(second.task.retry_state.failure_family, 'outline_narrative');
assert.equal(Number(second.task.retry_state.count), 1, 'different family resets count');
NODE
}

@test "V3 a non-retryable result clears retry_state and a completed result does not carry it" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));

let task = store.createTaskRecord(root, {
  workflow_id: 'wf-v3-clear-retry', workflow_type: 'short_write',
  current_stage: 'setting', user_goal: '写短篇',
});

// Establish a durable retry_state via a retryable_internal result.
task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'retryable_internal', code: 'missing_protagonist_identity', stage_id: 'setting',
  failure_family: 'character_contract',
}).task;
assert.ok(task.retry_state, 'precondition: retry_state present');

// A completed result leaves the retryable path: retry_state MUST be cleared in
// the same commit that advances the node.
const completed = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'setting_accepted', stage_id: 'setting',
});
assert.equal(completed.task.current_stage, 'section_outline');
assert.ok(!completed.task.retry_state, 'leaving the retry path clears retry_state');

// A needs_author_choice result also clears retry_state (it is a different path).
task = engine.applyStageResult(root, completed.task.workflow_id, completed.task.state_version, {
  kind: 'retryable_internal', code: 'missing_protagonist_identity', stage_id: 'section_outline',
  failure_family: 'character_contract',
}).task;
assert.ok(task.retry_state, 'precondition: retry_state present on section_outline');
const choice = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'needs_author_choice', code: 'choose_fix', stage_id: 'section_outline', question: '如何修',
  options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
});
assert.ok(!choice.task.retry_state, 'needs_author_choice clears retry_state');

// The durable task.json confirms retry_state is gone after the choice.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-clear-retry', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.ok(!persisted.retry_state, 'durable task must not retain retry_state off the path');
NODE
}

# Task 5 Step 6 RED: the Engine OWNS stage_execution.stage_attempt_id. A plain
# createTask (no caller-injected stage_execution) must persist a non-empty
# attempt id at the entry node; a completed result that advances to a DIFFERENT
# graph node must atomically replace it with a minimal ready execution carrying
# a different attempt id; retryable / blocked / author-choice results stay on
# the same node and KEEP the same attempt id. No caller supplies provenance.

@test "V3 Engine owns stage_attempt_id: plain create stamps it and a graph hop rotates it; same-node results keep it" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

// Plain create with NO stage_execution: the Engine must own and stamp the
// entry-node attempt id itself.
const created = engine.createTask(root, {
  workflow_id: 'wf-v3-attempt-own',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
const entryAttempt = String((created.stage_execution || {}).stage_attempt_id || '');
assert.ok(entryAttempt, 'plain createTask must stamp a non-empty stage_attempt_id at the entry node');
assert.equal(String((created.stage_execution || {}).stage_id || ''), 'creative_entry',
  'stage_execution.stage_id must match the entry node');
assert.equal(created.current_stage, 'creative_entry');

// A completed result advances creative_entry -> material_positioning (different
// node). The Engine must replace the execution with a ready one for the new
// node carrying a DIFFERENT attempt id.
const hop = engine.applyStageResult(root, created.workflow_id, created.state_version, {
  kind: 'completed', code: 'advance', stage_id: 'creative_entry',
});
assert.equal(hop.task.current_stage, 'material_positioning');
const nextAttempt = String((hop.task.stage_execution || {}).stage_attempt_id || '');
assert.ok(nextAttempt, 'advanced node must carry a non-empty stage_attempt_id');
assert.notEqual(nextAttempt, entryAttempt, 'a graph hop must rotate the attempt id');
assert.equal(String((hop.task.stage_execution || {}).stage_id || ''), 'material_positioning',
  'stage_execution.stage_id must follow the new node');

// A retryable_internal result on the SAME node keeps the attempt id.
const retry = engine.applyStageResult(root, hop.task.workflow_id, hop.task.state_version, {
  kind: 'retryable_internal', code: 'transient_check', stage_id: 'material_positioning',
  failure_family: 'transient',
});
assert.equal(retry.task.current_stage, 'material_positioning');
assert.equal(String((retry.task.stage_execution || {}).stage_attempt_id || ''), nextAttempt,
  'retryable_internal on the same node keeps the attempt id');

// A blocked result on the SAME node keeps the attempt id.
const blocked = engine.applyStageResult(root, retry.task.workflow_id, retry.task.state_version, {
  kind: 'blocked', code: 'still_blocked', stage_id: 'material_positioning',
});
assert.equal(blocked.task.current_stage, 'material_positioning');
assert.equal(String((blocked.task.stage_execution || {}).stage_attempt_id || ''), nextAttempt,
  'blocked on the same node keeps the attempt id');

// A needs_author_choice result on the SAME node keeps the attempt id.
const choice = engine.applyStageResult(root, blocked.task.workflow_id, blocked.task.state_version, {
  kind: 'needs_author_choice', code: 'pick', stage_id: 'material_positioning',
  question: '选哪个', options: [{ action_id: 'a', label: '甲' }, { action_id: 'b', label: '乙' }],
});
assert.equal(choice.task.current_stage, 'material_positioning');
assert.equal(String((choice.task.stage_execution || {}).stage_attempt_id || ''), nextAttempt,
  'needs_author_choice on the same node keeps the attempt id');

// The durable task.json carries the same attempt id the engine stamped.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-v3-attempt-own', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.equal(String((persisted.stage_execution || {}).stage_attempt_id || ''), nextAttempt,
  'durable task must persist the engine-stamped attempt id');
NODE
}

# Task 5 Step 6 RED: a caller-injected stage_execution.stage_attempt_id is
# ignored — the Engine owns the value. A plain create must not let the caller
# control provenance.
@test "V3 Engine ignores caller-supplied stage_execution.stage_attempt_id and owns the value" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));

const created = engine.createTask(root, {
  workflow_id: 'wf-v3-attempt-ignore',
  workflow_type: 'short_write',
  user_goal: '写短篇',
  stage_execution: { stage_attempt_id: 'caller-injected-attempt', stage_id: 'setting' },
});
const attempt = String((created.stage_execution || {}).stage_attempt_id || '');
assert.notEqual(attempt, 'caller-injected-attempt',
  'the Engine must not accept a caller-supplied stage_attempt_id');
assert.ok(attempt, 'the Engine must stamp its own attempt id');
assert.equal(String((created.stage_execution || {}).stage_id || ''), 'creative_entry',
  'the Engine must set stage_id to the entry node, not a caller value');
NODE
}
