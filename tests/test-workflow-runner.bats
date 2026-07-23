#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    RUNNER="$REPO/scripts/workflow-runner.js"
    STATE="$REPO/scripts/workflow-state-machine.js"
    FAKE="$REPO/tests/fixtures/fake-workflow-host.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

create_started_task() {
    workflow_type="${1:-short_write}"
    node "$STATE" create --workflow-type "$workflow_type" --project-root "$PROJECT" --user-goal "测试工作流" --json >/dev/null
    resolve_first_action
}

resolve_first_action() {
    node - "$STATE" "$PROJECT" <<'NODE'
const fs = require('fs'); const path = require('path'); const { spawnSync } = require('child_process');
const state = process.argv[2]; const root = process.argv[3];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
const pending = task.pending_action || {};
const out = spawnSync(process.execPath, [state, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', String(pending.id || ''), '--visible-choice-hash', String(pending.visible_choice_hash || ''),
  '--state-version', String(task.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
if (out.status !== 0) { process.stderr.write(out.stdout || out.stderr); process.exit(out.status || 2); }
NODE
}

@test "runner status reports idle without an active task and does not mutate the project" {
    node "$RUNNER" status --project-root "$PROJECT" --json > "$TMP_DIR/out.json"

    grep -q '"status": "idle"' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "runner dry-run writes no packet and launches no host" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --dry-run --json > "$TMP_DIR/out.json"

    grep -q '"status": "dry_run"' "$TMP_DIR/out.json"
    grep -q '"adapter": "fake"' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
    test -z "$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-packets*' -type f -print)"
}

@test "runner packet records the durable task snapshot rather than the UI focus pointer" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const path = require('path');
const { buildRunPreview } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const root = process.argv[3];
const fake = process.argv[4];
const task = {
  workflow_id: 'wf-write', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-write',
  scope: '第1卷/第003章', user_goal: '生成第003章 Brief', lifecycle_graph: { nodes: [] },
};
const execution = { stage_id: 'chapter_brief', expected_result_packet: '追踪/workflow/tasks/wf-write/result-packets/chapter_brief.result.json' };
const run = buildRunPreview(root, task, execution, { adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success' }, 0, {
  mode: 'required', status: 'assembled', packet_md: '追踪/workflow/tasks/wf-write/context-packets/chapter_brief/a/context.md', workflow_id: 'wf-write',
});
assert.equal(run.runnerPacket.workflow_id, 'wf-write');
assert.equal(run.runnerPacket.task_state, '追踪/workflow/tasks/wf-write/task.json');
assert.equal(run.runnerPacket.memory_context.workflow_id, 'wf-write');
assert.notEqual(run.runnerPacket.task_state, '追踪/workflow/current-task.json');
NODE
}

@test "short prose runner prompt reads only the assembled stage packet" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert=require('assert');const path=require('path');
const {buildRunPreview}=require(path.join(process.argv[2],'scripts/lib/workflow-runner-execution.js'));
const root=process.argv[3],fake=process.argv[4];
const task={workflow_id:'wf-short-prose',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short-prose',scope:'第2节',lifecycle_graph:{nodes:[]}};
const execution={stage_id:'draft_next_section',expected_result_packet:'追踪/workflow/tasks/wf-short-prose/result-packets/draft_next_section.result.json'};
const memory={mode:'none',status:'stage_context_packet_only',token_budget:0,packet_md:'',packet_json:'',accepts_memory_updates:false};
const stage={status:'assembled',packet_md:'追踪/workflow/tasks/wf-short-prose/context-packets/section-002/a/context.md',packet_json:'追踪/workflow/tasks/wf-short-prose/context-packets/section-002/a/context.json',section_index:2,estimated_tokens:900,token_budget:1100,source_files:['写作Brief_第002节.md']};
const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory,stage);
assert.equal(run.runnerPacket.memory_context.mode,'none');
assert.equal(run.runnerPacket.stage_context_packet.packet_md,stage.packet_md);
const requirements=run.runnerPacket.requirements.join('\n');
assert(!requirements.includes('先读取 memory_context.packet_md'),requirements);
assert(requirements.includes('先读取 stage_context_packet.packet_md'),requirements);
NODE
}

@test "runner requires an aggregate budget before a non-fake host can start" {
    create_started_task
    mkdir -p "$TMP_DIR/bin"
    cp "$FAKE" "$TMP_DIR/bin/codex"
    chmod +x "$TMP_DIR/bin/codex"

    status=0
    env PATH="$TMP_DIR/bin:$PATH" node "$RUNNER" once --project-root "$PROJECT" --adapter codex --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q 'budget_required' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "runner once executes one started stage and applies its result packet" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json > "$TMP_DIR/out.json"

    grep -q '"status": "stage_applied"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 1 ]
    runner_packet="$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-packets*' -name '*.run.json' | head -1)"
    grep -q '"owner_module": "private-short-extension"' "$runner_packet"
    grep -q '"task_state": "追踪/workflow/tasks/' "$runner_packet"
    grep -q '"packet_mode": "task_immutable"' "$runner_packet"
    grep -q '"workflow_id"' "$PROJECT/追踪/workflow/token-cost-ledger.jsonl"
    grep -q '"status": "summary"' "$PROJECT/追踪/workflow/token-cost-summary.json"
    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const root = process.argv[2];
const event = JSON.parse(fs.readFileSync(`${root}/追踪/workflow/token-cost-ledger.jsonl`, 'utf8').trim());
const summary = JSON.parse(fs.readFileSync(`${root}/追踪/workflow/token-cost-summary.json`, 'utf8'));
    if (event.token_source !== 'estimated' || event.estimated_tokens <= 0) throw new Error(JSON.stringify(event));
    if (summary.estimated.events !== 1 || summary.unavailable.events !== 0) throw new Error(JSON.stringify(summary));
NODE
    node "$STATE" inspect --project-root "$PROJECT" --json > "$TMP_DIR/inspect.json"
    node - "$TMP_DIR/inspect.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.task.machine.completed_stages.length !== 1) throw new Error(JSON.stringify(out.task.machine));
if (out.task.stage_execution && out.task.stage_execution.status === 'running') throw new Error('stage still running');
NODE
}

@test "runner heartbeat refreshes the task-family writer lease" {
    create_started_task
    node - "$REPO/scripts/lib/task-family-store.js" "$PROJECT" <<'NODE'
const fs=require('fs');const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);const pointer=JSON.parse(fs.readFileSync(`${root}/追踪/workflow/current-task.json`,'utf8'));const task=JSON.parse(fs.readFileSync(`${root}/${pointer.task_dir}/task.json`,'utf8'));
store.claimFamilyWriter(root,task.task_family_id,{session_id:'runner:test',host:'runner'},{write:true,hostLiveness:()=> 'unknown'});
const file=store.familyPath(root,task.task_family_id);const family=JSON.parse(fs.readFileSync(file,'utf8'));family.writer_lease.expires_at='2000-01-01T00:00:00.000Z';fs.writeFileSync(file,JSON.stringify(family));
NODE

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json >/dev/null
    node - "$REPO/scripts/lib/task-family-store.js" "$PROJECT" <<'NODE'
const fs=require('fs');const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);const pointer=JSON.parse(fs.readFileSync(`${root}/追踪/workflow/current-task.json`,'utf8'));const task=JSON.parse(fs.readFileSync(`${root}/${pointer.task_dir}/task.json`,'utf8'));const family=store.readTaskFamily(root,task.task_family_id);
if(new Date(family.writer_lease.expires_at).getTime()<=Date.now()||family.writer_lease.holder_session_id!=='runner:test') throw new Error(JSON.stringify(family.writer_lease));
NODE
}

@test "background runner keeps heartbeat release and result authority after focus switches" {
    create_started_task

    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
const telemetry = require(path.join(repo, 'scripts/lib/workflow-runner-telemetry.js'));

const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const taskA = authority.resolveTaskAuthority(root, pointer.workflow_id).task;
const taskB = {
  workflow_id: 'wf-focused-b',
  workflow_type: 'review_repair',
  task_dir: '追踪/workflow/tasks/wf-focused-b',
  state_version: 3,
};
fs.mkdirSync(path.join(root, taskB.task_dir), { recursive: true });
fs.writeFileSync(path.join(root, taskB.task_dir, 'task.json'), `${JSON.stringify(taskB, null, 2)}\n`);
authority.writeFocusPointer(root, taskB);

telemetry.refreshRunnerLease(root, taskA.workflow_id, taskA.task_dir, taskA.current_stage, 'run-background-a');
const heartbeated = authority.resolveTaskAuthority(root, taskA.workflow_id).task;
assert.equal(heartbeated.runtime_guard.runner_lease.run_id, 'run-background-a');
assert.equal(authority.readFocusedTask(root).pointer.workflow_id, taskB.workflow_id);

telemetry.releaseRunnerLease(root, taskA.workflow_id, taskA.task_dir, taskA.current_stage, 'run-background-a');
const released = authority.resolveTaskAuthority(root, taskA.workflow_id).task;
assert.equal(released.runtime_guard.runner_lease, undefined);
assert.equal(authority.readFocusedTask(root).pointer.workflow_id, taskB.workflow_id);

const result = {
  workflow_id: taskA.workflow_id,
  workflow_type: taskA.workflow_type,
  stage_id: taskA.current_stage,
  step_id: taskA.current_stage,
  step_status: 'completed',
  outputs: [],
  changed_files: [],
  evidence: [],
  verification_result: 'pass',
  blocking_reason: '',
  next_recommendation: '继续',
  handoff_summary: '后台 runner 合法结果。',
  checkpoint_state: {},
  output_health_result: 'pass',
};
const resultFile = path.join(root, released.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(resultFile), { recursive: true });
fs.writeFileSync(resultFile, `${JSON.stringify(result, null, 2)}\n`);
fs.writeFileSync(path.join(root, 'background-result.json'), `${JSON.stringify({
  workflowId: taskA.workflow_id,
  taskDir: taskA.task_dir,
  resultFile,
}, null, 2)}\n`);
NODE

    workflow_id="$(node -e 'process.stdout.write(require(process.argv[1]).workflowId)' "$PROJECT/background-result.json")"
    result_file="$(node -e 'process.stdout.write(require(process.argv[1]).resultFile)' "$PROJECT/background-result.json")"

    run node "$STATE" apply-result --project-root "$PROJECT" --result "$result_file" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "advanced"'* ]]

    node - "$REPO" "$PROJECT" "$workflow_id" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root, workflowId] = process.argv.slice(2);
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
assert.equal(authority.readFocusedTask(root).pointer.workflow_id, 'wf-focused-b');
const task = authority.resolveTaskAuthority(root, workflowId).task;
assert.equal(task.machine.completed_stages.length, 1);
NODE

    run node "$STATE" apply-result --project-root "$PROJECT" --workflow-id wf-focused-b --result "$result_file" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_result_task_scope_conflict'* ]]
}

@test "runner failure recovery stays bound to the running workflow after focus switches" {
    create_started_task
    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
fs.writeFileSync(path.join(root, 'running-workflow.json'), `${JSON.stringify(pointer)}\n`);
NODE
    node - "$TMP_DIR/focus-switch-failure.js" <<'NODE'
const fs = require('fs');
fs.writeFileSync(process.argv[2], `
const fs = require('fs');
const path = require('path');
const root = process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const task = {
  workflow_id: 'wf-focused-during-failure',
  workflow_type: 'review_repair',
  task_dir: '追踪/workflow/tasks/wf-focused-during-failure',
  state_version: 1,
  status: 'paused_after_step'
};
fs.mkdirSync(path.join(root, task.task_dir), { recursive: true });
fs.writeFileSync(path.join(root, task.task_dir, 'task.json'), JSON.stringify(task));
fs.writeFileSync(path.join(root, '追踪/workflow/current-task.json'), JSON.stringify({
  schemaVersion: '1.0.0', workflow_id: task.workflow_id, task_dir: task.task_dir, state_version: task.state_version
}));
fs.appendFileSync(path.join(root, 'fake-host-invocations.log'), 'focus-switch-failure\\n');
process.stdout.write('修真'.repeat(40) + '\\n');
setTimeout(() => process.exit(0), 20);
`);
NODE

    status=0
    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/focus-switch-failure.js" --max-retries 0 --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 0 ]
    grep -q 'model_degradation_repeated_term' "$TMP_DIR/out.json"
    node - "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const running = JSON.parse(fs.readFileSync(path.join(root, 'running-workflow.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, running.task_dir, 'task.json'), 'utf8'));
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
assert.equal(pointer.workflow_id, 'wf-focused-during-failure');
assert.equal(task.status, 'blocked_model_degradation');
assert.equal(task.stage_execution.status, 'paused');
assert.equal(task.runtime_guard.runner_lease, undefined);
const recoveryDir = path.join(root, running.task_dir, 'runner-recovery');
assert.ok(fs.readdirSync(recoveryDir).some(name => name.endsWith('.final.json')));
NODE
}

@test "runHost blocks before spawn when durable authority or task_dir is missing" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, fake] = process.argv.slice(2);
const { runHost } = require(path.join(repo, 'scripts/lib/workflow-runner-execution.js'));

function invocation() {
  return {
    command: process.execPath,
    args: [fake, 'no-result'],
    cwd: root,
    env: {
      ...process.env,
      NOVEL_ASSISTANT_PROJECT_ROOT: root,
      NOVEL_ASSISTANT_RUNNER_PACKET: 'missing-runner.json',
      NOVEL_ASSISTANT_RESULT_PACKET: 'missing-result.json'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  };
}

async function check(task, runId) {
  const result = await runHost(root, task, { stage_id: 'stage-a' }, {
    runId,
    attempt: 0,
    invocation: invocation()
  }, { adapter: 'fake', idleTimeoutMs: 1000, maxBudgetUsd: 0 });
  assert.equal(result.status, task.task_dir ? 'blocked_task_authority_missing' : 'blocked_runner_task_dir_missing');
  assert.equal(result.host_started, false);
}

(async () => {
  await check({ workflow_id: 'wf-missing', workflow_type: 'review_repair', task_dir: '追踪/workflow/tasks/wf-missing' }, 'run-missing-authority');
  await check({ workflow_id: 'wf-missing-dir', workflow_type: 'review_repair', task_dir: '' }, 'run-missing-task-dir');
  assert.equal(fs.existsSync(path.join(root, 'fake-host-invocations.log')), false);
})().catch(error => { console.error(error.stack || error); process.exit(1); });
NODE
}

@test "runHost blocks before spawn when the durable stage drifts during lease refresh" {
    create_started_task
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
const { runHost } = require(path.join(repo, 'scripts/lib/workflow-runner-execution.js'));

const focused = authority.readFocusedTask(root);
const task = focused.authority.task;
const originalStage = task.current_stage;
const durableFile = path.join(root, task.task_dir, 'task.json');
const durable = JSON.parse(fs.readFileSync(durableFile, 'utf8'));
durable.current_stage = `${originalStage}-drifted`;
fs.writeFileSync(durableFile, `${JSON.stringify(durable, null, 2)}\n`);

const invocationLog = path.join(root, 'fake-host-invocations.log');
const options = { adapter: 'codex', idleTimeoutMs: 1000, maxBudgetUsd: 1 };
const run = {
  runId: 'run-stage-drift',
  attempt: 0,
  invocation: {
    command: process.execPath,
    args: ['-e', `require('fs').appendFileSync(${JSON.stringify(invocationLog)}, 'spawned\\n')`],
    cwd: root,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe']
  }
};

(async () => {
  const result = await runHost(root, task, { stage_id: originalStage }, run, options);
  assert.equal(result.status, 'blocked_runner_stage_drift');
  assert.equal(result.host_started, false);
  assert.equal(fs.existsSync(invocationLog), false);
  assert.equal(options.budgetState.reserved, 0);
  assert.equal(options.budgetState.actual, 0);
  assert.equal(fs.existsSync(path.join(root, '追踪/workflow/.workflow.lock')), false);
})().catch(error => { console.error(error.stack || error); process.exit(1); });
NODE
}

@test "runHost fails closed before spawn when lease refresh hits WORKFLOW_LOCKED" {
    create_started_task
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
const { runHost } = require(path.join(repo, 'scripts/lib/workflow-runner-execution.js'));

const task = authority.readFocusedTask(root).authority.task;
const lockDir = path.join(root, '追踪/workflow/.workflow.lock');
fs.mkdirSync(lockDir, { recursive: true });
fs.writeFileSync(path.join(lockDir, 'owner.json'), `${JSON.stringify({
  pid: process.pid,
  owner: 'competing-writer',
  token: 'competing-lock-token',
  acquired_at: new Date().toISOString()
}, null, 2)}\n`);

const invocationLog = path.join(root, 'fake-host-invocations.log');
const options = { adapter: 'codex', idleTimeoutMs: 1000, maxBudgetUsd: 1 };
const run = {
  runId: 'run-workflow-locked',
  attempt: 0,
  invocation: {
    command: process.execPath,
    args: ['-e', `require('fs').appendFileSync(${JSON.stringify(invocationLog)}, 'spawned\\n')`],
    cwd: root,
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe']
  }
};

(async () => {
  const result = await runHost(root, task, { stage_id: task.current_stage }, run, options);
  assert.equal(result.status, 'blocked_workflow_locked');
  assert.equal(result.code, 'WORKFLOW_LOCKED');
  assert.equal(result.host_started, false);
  assert.equal(fs.existsSync(invocationLog), false);
  assert.equal(options.budgetState.reserved, 0);
  assert.equal(options.budgetState.actual, 0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(lockDir, 'owner.json'), 'utf8')).token, 'competing-lock-token');
})().catch(error => { console.error(error.stack || error); process.exit(1); });
NODE
}

@test "runner records a terminal cumulative usage snapshot once" {
    create_started_task
    node - "$TMP_DIR/cumulative-usage.js" <<'NODE'
const fs = require('fs');
fs.writeFileSync(process.argv[2], `
const fs = require('fs'); const path = require('path'); const root = process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const packet = JSON.parse(fs.readFileSync(path.join(root, process.env.NOVEL_ASSISTANT_RUNNER_PACKET), 'utf8'));
const result = { workflow_id: packet.workflow_id, workflow_type: packet.workflow_type, stage_id: packet.stage_id, step_id: packet.stage_id, step_status: 'completed', outputs: [], changed_files: [], evidence: [], verification_result: 'pass', blocking_reason: '', next_recommendation: '继续', handoff_summary: 'cumulative', checkpoint_state: {}, output_health_result: 'pass' };
const target = path.join(root, process.env.NOVEL_ASSISTANT_RESULT_PACKET); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, JSON.stringify(result));
process.stdout.write(JSON.stringify({ usage: { input_tokens: 20, output_tokens: 8 } }) + '\\n');
process.stdout.write(JSON.stringify({ type: 'result', status: 'completed', usage: { input_tokens: 50, output_tokens: 12 } }) + '\\n');
`);
NODE
    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/cumulative-usage.js" --json >/dev/null
    node - "$PROJECT/追踪/workflow/token-cost-ledger.jsonl" <<'NODE'
const fs = require('fs'); const event = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').trim());
if (event.input_tokens !== 50 || event.output_tokens !== 12) throw new Error(JSON.stringify(event));
NODE
}

@test "runner redacts output and blocks stage application when ledger accounting fails" {
    create_started_task
    mkdir -p "$PROJECT/追踪/workflow/token-cost-ledger.jsonl"
    node - "$TMP_DIR/secret-output.js" <<'NODE'
const fs = require('fs');
fs.writeFileSync(process.argv[2], `
const fs = require('fs'); const path = require('path'); const root = process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const packet = JSON.parse(fs.readFileSync(path.join(root, process.env.NOVEL_ASSISTANT_RUNNER_PACKET), 'utf8'));
const target = path.join(root, process.env.NOVEL_ASSISTANT_RESULT_PACKET); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, JSON.stringify({ workflow_id: packet.workflow_id, workflow_type: packet.workflow_type, stage_id: packet.stage_id, step_id: packet.stage_id, step_status: 'completed', outputs: [], changed_files: [], evidence: [], verification_result: 'pass', blocking_reason: '', next_recommendation: '继续', handoff_summary: 'secret', checkpoint_state: {}, output_health_result: 'pass' }));
process.stdout.write('Bearer sk-super-secret-token\\n'); process.stdout.write(JSON.stringify({ type: 'result', status: 'completed' }) + '\\n');
`);
NODE
    status=0
    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/secret-output.js" --json > "$TMP_DIR/out.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q 'accounting_failure' "$TMP_DIR/out.json"
    ! grep -R -q 'sk-super-secret-token' "$PROJECT/追踪/workflow/tasks"
    grep -R -q '\[REDACTED\]' "$PROJECT/追踪/workflow/tasks"
    node "$STATE" inspect --project-root "$PROJECT" --json > "$TMP_DIR/inspect.json"
    ! grep -q 'stage_applied' "$TMP_DIR/out.json"
}

@test "runner records complete host usage without replacing it with a character estimate" {
    create_started_task
    node - "$TMP_DIR/usage-host.js" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
fs.writeFileSync(file, `
const fs = require('fs');
const path = require('path');
const root = process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const packet = JSON.parse(fs.readFileSync(path.join(root, process.env.NOVEL_ASSISTANT_RUNNER_PACKET), 'utf8'));
const result = { workflow_id: packet.workflow_id, workflow_type: packet.workflow_type, stage_id: packet.stage_id, step_id: packet.stage_id, step_status: 'completed', outputs: [], changed_files: [], evidence: [], verification_result: 'pass', blocking_reason: '', next_recommendation: '继续', handoff_summary: 'usage fixture', checkpoint_state: {}, output_health_result: 'pass' };
const target = path.join(root, process.env.NOVEL_ASSISTANT_RESULT_PACKET);
fs.mkdirSync(path.dirname(target), { recursive: true });
fs.writeFileSync(target, JSON.stringify(result));
process.stdout.write(JSON.stringify({ type: 'result', status: 'completed', usage: { input_tokens: 321, output_tokens: 123, cache_read_input_tokens: 11, cache_creation_input_tokens: 7 } }) + '\\n');
`);
NODE

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/usage-host.js" --json > "$TMP_DIR/out.json"

    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const root = process.argv[2];
const event = JSON.parse(fs.readFileSync(`${root}/追踪/workflow/token-cost-ledger.jsonl`, 'utf8').trim());
const summary = JSON.parse(fs.readFileSync(`${root}/追踪/workflow/token-cost-summary.json`, 'utf8'));
if (event.token_source !== 'host' || event.estimated_tokens !== 0) throw new Error(JSON.stringify(event));
if (event.input_tokens !== 321 || event.output_tokens !== 123 || event.cache_read_tokens !== 11 || event.cache_write_tokens !== 7) throw new Error(JSON.stringify(event));
if (summary.actual.events !== 1 || summary.actual.input_tokens !== 321 || summary.actual.output_tokens !== 123) throw new Error(JSON.stringify(summary.actual));
if (summary.estimated.events !== 0 || summary.unavailable.events !== 0) throw new Error(JSON.stringify(summary));
NODE
}

@test "runner applies an existing expected result without invoking the host again" {
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
  blocking_reason: '', next_recommendation: '继续', handoff_summary: '已有结果。',
  checkpoint_state: {}, output_health_result: 'pass'
};
const file = path.join(root, task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(file), {recursive:true});
fs.writeFileSync(file, JSON.stringify(result));
NODE

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --json > "$TMP_DIR/out.json"

    grep -q '"reused_existing_result": true' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "runner stops at an unconfirmed stage instead of selecting for the user" {
    node "$STATE" create --workflow-type project_setup --project-root "$PROJECT" --user-goal "初始化" --json >/dev/null

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --json > "$TMP_DIR/out.json"

    grep -q '"status": "needs_confirmation"' "$TMP_DIR/out.json"
    grep -q '"target_stage": "project_type_lock"' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}

@test "runner stops cover before image generation until the user confirms it" {
    node "$STATE" create --workflow-type cover --project-root "$PROJECT" --user-goal "制作书籍封面" --json >/dev/null

    node "$RUNNER" run --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --max-stages 8 --json > "$TMP_DIR/out.json"

    grep -q '"status": "needs_confirmation"' "$TMP_DIR/out.json"
    grep -q '"target_stage": "generation_confirmation"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 3 ]
    ! grep -q 'generate_cover' "$PROJECT/fake-host-invocations.log"
}

@test "runner retries model degradation once then preserves the checkpoint" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode repeat-term --max-retries 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "model_degradation_repeated_term"' "$TMP_DIR/out.json"
    grep -q '"attempts": 2' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 2 ]
    [ "$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-recovery*' -type f | wc -l | tr -d ' ')" -ge 2 ]
    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path'); const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
if (task.status !== 'blocked_model_degradation') throw new Error(task.status);
if (task.stage_execution.status !== 'paused') throw new Error(task.stage_execution.status);
if (!task.runtime_guard.heartbeat.latest_trusted_artifact) throw new Error('trusted checkpoint missing');
NODE
}

@test "runner stops repeated tool failures instead of starting an unbounded retry loop" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode tool-loop --max-retries 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "tool_failure_loop"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 2 ]
}

@test "runner treats a healthy host without a result packet as a blocked contract violation" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode no-result --max-retries 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "missing_result_packet"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 1 ]
}

@test "runner stops a silent host after the configured idle timeout" {
    create_started_task
    node - "$TMP_DIR/silent-host.js" <<'NODE'
const fs = require('fs');
fs.writeFileSync(process.argv[2], 'setTimeout(() => process.exit(0), 5000);\n');
NODE

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$TMP_DIR/silent-host.js" --idle-timeout-ms 100 --json > "$TMP_DIR/out.json"

    grep -q '"status": "idle_timeout"' "$TMP_DIR/out.json"
    grep -q '"stop_reason": "idle_timeout"' "$TMP_DIR/out.json"
}

@test "runner run advances safe stages until the configured stage limit" {
    create_started_task

    node "$RUNNER" run --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --max-stages 2 --json > "$TMP_DIR/out.json"

    grep -q '"status": "stage_limit"' "$TMP_DIR/out.json"
    grep -q '"stage_count": 2' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 2 ]
}

@test "runner executes a high-risk stage only after the state machine records user confirmation" {
    node "$STATE" create --workflow-type project_setup --project-root "$PROJECT" --user-goal "初始化" --json >/dev/null
    resolve_first_action

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json > "$TMP_DIR/out.json"

    grep -q '"status": "stage_applied"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$PROJECT/fake-host-invocations.log" | tr -d ' ')" -eq 1 ]
}

@test "runner recovers the professional owner for a legacy in-flight task" {
    create_started_task
    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
for (const file of fs.readdirSync(path.join(root, '追踪/workflow/tasks')).map((id) => path.join(root, '追踪/workflow/tasks', id, 'task.json'))) {
  const task = JSON.parse(fs.readFileSync(file, 'utf8'));
  delete task.stage_execution.owner_module;
  fs.writeFileSync(file, JSON.stringify(task));
}
NODE

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json >/dev/null

    runner_packet="$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-packets*' -name '*.run.json' | head -1)"
    grep -q '"owner_module": "private-short-extension"' "$runner_packet"
}

@test "runner rejects a result packet path that escapes through a symlink" {
    create_started_task
    task_dir="$(find "$PROJECT/追踪/workflow/tasks" -mindepth 1 -maxdepth 1 -type d | head -1)"
    outside="$TMP_DIR/outside"
    mkdir -p "$outside"
    rm -rf "$task_dir/result-packets"
    ln -s "$outside" "$task_dir/result-packets"

    status=0
    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --dry-run --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "runner_error"' "$TMP_DIR/out.json"
    grep -q 'escapes project through symlink' "$TMP_DIR/out.json"
    test ! -e "$PROJECT/fake-host-invocations.log"
}
