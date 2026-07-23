#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    RECOVER="$REPO/scripts/workflow-recover.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "same-type workflow creation keeps unique durable task directories and pauses the former focus" {
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$PROJECT" --user-goal "写短篇甲" --json > "$TMP_DIR/first.json"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$PROJECT" --user-goal "写短篇乙" --json > "$TMP_DIR/second.json"

    node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const [firstFile, secondFile, root] = process.argv.slice(2);
const first = JSON.parse(fs.readFileSync(firstFile, 'utf8')).task.workflow_id;
const second = JSON.parse(fs.readFileSync(secondFile, 'utf8')).task.workflow_id;
if (first === second) throw new Error(`workflow ids collided: ${first}`);
for (const id of [first, second]) {
  const taskFile = path.join(root, '追踪', 'workflow', 'tasks', id, 'task.json');
  if (!fs.existsSync(taskFile)) throw new Error(`missing durable task: ${taskFile}`);
}
const firstTask=JSON.parse(fs.readFileSync(path.join(root,'追踪','workflow','tasks',first,'task.json'),'utf8'));
const current=JSON.parse(fs.readFileSync(path.join(root,'追踪','workflow','current-task.json'),'utf8'));
const focusedTask=JSON.parse(fs.readFileSync(path.join(root,current.task_dir,'task.json'),'utf8'));
if(firstTask.status!=='paused'||firstTask.lifecycle?.focus_switched_to!==second) throw new Error(JSON.stringify(firstTask));
if(Object.keys(current).sort().join(',')!=='focused_at,schemaVersion,state_version,task_dir,workflow_id') throw new Error(JSON.stringify(current));
if(current.workflow_id!==second||focusedTask.lifecycle?.previous_workflow_id!==first) throw new Error(JSON.stringify({current,focusedTask}));
NODE
}

@test "stale recovery cannot resurrect a task replaced by switch intent" {
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$PROJECT" --user-goal "写短篇" --json > "$TMP_DIR/create.json"
    old_id="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).task.workflow_id)' "$TMP_DIR/create.json")"

    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const durable = path.join(root, pointer.task_dir, 'task.json');
const task = JSON.parse(fs.readFileSync(durable, 'utf8'));
task.runtime_guard.heartbeat.latest_trusted_artifact = `${task.task_dir}/result-packets/missing.result.json`;
const text = JSON.stringify(task, null, 2) + '\n';
fs.writeFileSync(durable, text);
NODE

    cat > "$TMP_DIR/interleave-switch.js" <<'NODE'
const child = require('child_process');
const fs = require('fs');
const originalRead = fs.readFileSync;
let switched = false;
fs.readFileSync = function(file, ...args) {
  const value = originalRead.call(this, file, ...args);
  if (!switched && String(file).endsWith('/追踪/workflow/current-task.json')) {
    switched = true;
    const run = child.spawnSync(process.execPath, [process.env.WORKFLOW_STATE_MACHINE, 'switch-intent', '--project-root', process.env.WORKFLOW_PROJECT, '--workflow-type', 'long_write', '--scope', '第1章', '--user-goal', '写第1章', '--json'], {
      encoding: 'utf8',
      env: { ...process.env, NODE_OPTIONS: '' },
    });
    if (run.status !== 0) throw new Error(run.stderr || run.stdout);
  }
  return value;
};
NODE

    NODE_OPTIONS="--require $TMP_DIR/interleave-switch.js" WORKFLOW_STATE_MACHINE="$STATE_MACHINE" WORKFLOW_PROJECT="$PROJECT" \
      node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/recover.json"

    node - "$PROJECT/追踪/workflow/current-task.json" "$old_id" "$PROJECT" <<'NODE'
const fs = require('fs');
const pointer = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(`${process.argv[4]}/${pointer.task_dir}/task.json`, 'utf8'));
if (task.workflow_id === process.argv[3]) throw new Error('stale recovery resurrected the superseded task');
if (task.workflow_type !== 'long_write') throw new Error(`expected switched workflow, got ${task.workflow_type}`);
NODE
}

@test "invalid result packet leaves the focus pointer and durable lifecycle unchanged" {
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$PROJECT" --user-goal "写短篇" --json > "$TMP_DIR/create.json"
    task_id="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).task.workflow_id)' "$TMP_DIR/create.json")"
    current="$PROJECT/追踪/workflow/current-task.json"
    durable="$PROJECT/追踪/workflow/tasks/$task_id/task.json"
    invalid_result="$PROJECT/追踪/workflow/tasks/$task_id/result-packets/invalid-result.json"
    cp "$current" "$TMP_DIR/current-before.json"
    cp "$durable" "$TMP_DIR/durable-before.json"
    cat > "$invalid_result" <<JSON
{
  "workflow_id": "$task_id",
  "workflow_type": "short_write",
  "stage_id": "not-the-current-stage",
  "step_id": "not-the-current-stage",
  "step_status": "completed",
  "outputs": [],
  "changed_files": [],
  "evidence": [],
  "verification_result": "pass",
  "checkpoint_state": {},
  "output_health_result": "pass"
}
JSON

    status=0
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$invalid_result" --json > "$TMP_DIR/apply.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_result_packet_invalid"' "$TMP_DIR/apply.json"
    cmp -s "$current" "$TMP_DIR/current-before.json"
    cmp -s "$durable" "$TMP_DIR/durable-before.json"
    node - "$current" "$durable" "$task_id" <<'NODE'
const fs=require('fs');const [pointerFile,durableFile,id]=process.argv.slice(2);
const pointer=JSON.parse(fs.readFileSync(pointerFile,'utf8'));const task=JSON.parse(fs.readFileSync(durableFile,'utf8'));
if(Object.keys(pointer).sort().join(',')!=='focused_at,schemaVersion,state_version,task_dir,workflow_id') throw new Error(JSON.stringify(pointer));
if(pointer.workflow_id!==id||task.workflow_id!==id||task.status!=='running') throw new Error(JSON.stringify({pointer,task}));
NODE
}
