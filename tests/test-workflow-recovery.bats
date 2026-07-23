#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    SUPERVISOR="$REPO/scripts/workflow-runtime-supervisor.js"
    RECOVER="$REPO/scripts/workflow-recover.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

focused_task_path() {
    node - "$PROJECT" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
process.stdout.write(path.join(root,pointer.task_dir,'task.json'));
NODE
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "workflow recovery reports missing durable authority for an existing focus pointer" {
    mkdir -p "$PROJECT/追踪/workflow"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-missing","task_dir":"追踪/workflow/tasks/wf-missing","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON

    run node "$RECOVER" --project-root "$PROJECT" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'"status": "blocked_task_authority_missing"'* ]]
}

resolve_action() {
    node - "$STATE_MACHINE" "$PROJECT" "${1:-1}" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const script=process.argv[2],root=process.argv[3],input=process.argv[4];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
const pending=task.pending_action||{};
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input',input,'--pending-action-id',String(pending.id||''),'--visible-choice-hash',String(pending.visible_choice_hash||''),'--state-version',String(task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
}

@test "stage execution keeps expected result separate from last trusted artifact" {
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-200" --user-goal "审阅 1-200 章" --json > "$TMP_DIR/create.json"
    resolve_action > "$TMP_DIR/resolve.json"

    node - "$(focused_task_path)" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!task.stage_execution.expected_result_packet) throw new Error('expected result packet missing');
if (!task.runtime_guard.heartbeat.latest_trusted_artifact) throw new Error('trusted artifact missing');
if (task.runtime_guard.heartbeat.latest_trusted_artifact === task.stage_execution.expected_result_packet) {
  throw new Error('future result packet was marked trusted');
}
if (task.runtime_guard.checkpoint_policy.expected_result_packet !== task.stage_execution.expected_result_packet) {
  throw new Error('expected result packet not stored in checkpoint policy');
}
NODE
}

@test "an inflight task without a runner lease pauses at its trusted checkpoint" {
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-inflight/result-packets"
    printf '# current task\n' > "$PROJECT/追踪/workflow/current-task.md"
    cat > "$PROJECT/追踪/workflow/tasks/wf-inflight/task.json" <<'JSON'
{
  "workflow_id": "wf-inflight",
  "workflow_type": "review_repair",
  "task_dir": "追踪/workflow/tasks/wf-inflight",
  "status": "running",
  "current_stage": "evidence_scan",
  "current_step": "evidence_scan",
  "stage_execution": {
    "status": "running",
    "expected_result_packet": "追踪/workflow/tasks/wf-inflight/result-packets/evidence_scan.result.json"
  },
  "runtime_guard": {
    "heartbeat": {
      "updated_at": "2026-07-10T09:55:00+08:00",
      "latest_trusted_artifact": "追踪/workflow/current-task.md"
    },
    "stall_policy": {"heartbeat_timeout_minutes": 20, "on_stall": "pause_at_checkpoint"},
    "checkpoint_policy": {
      "checkpoint_path": "追踪/workflow/current-task.json",
      "resume_from": "evidence_scan",
      "expected_result_packet": "追踪/workflow/tasks/wf-inflight/result-packets/evidence_scan.result.json"
    }
  }
}
JSON
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-inflight","task_dir":"追踪/workflow/tasks/wf-inflight","focused_at":"2026-07-12T00:00:00.000Z","state_version":0}
JSON

    node "$SUPERVISOR" --project-root "$PROJECT" --now "2026-07-10T10:00:00+08:00" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'paused') throw new Error(out.status);
if (out.recommended_action !== 'resume_from_checkpoint') throw new Error(out.recommended_action);
NODE
}

@test "workflow recovery reconstructs an embedded completed stage and advances exactly once" {
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-200" --user-goal "审阅 1-200 章" --json > "$TMP_DIR/create.json"
    resolve_action > "$TMP_DIR/resolve.json"

    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const durable = path.join(root, pointer.task_dir, 'task.json');
const task = JSON.parse(fs.readFileSync(durable, 'utf8'));
task.range_lock = {
  status: 'completed',
  summary: '已锁定 1-200 章审阅范围。',
  evidence_artifacts: ['追踪/审查批次计划_1-200.md']
};
task.machine.completed_stages = ['range_lock'];
fs.writeFileSync(durable, JSON.stringify(task, null, 2) + '\n');
NODE

    node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/recover.json"

    node - "$TMP_DIR/recover.json" "$(focused_task_path)" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'recovered_and_advanced') throw new Error(out.status);
if (out.recovered_stage !== 'range_lock') throw new Error(out.recovered_stage);
if (!fs.existsSync(out.result_packet_path)) throw new Error('packet not written');
if (task.current_stage !== 'evidence_scan') throw new Error(task.current_stage);
NODE

    node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/recover-again.json"
    node - "$TMP_DIR/recover-again.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!['no_recovery_needed', 'stage_not_recoverable'].includes(out.status)) throw new Error(out.status);
NODE
}

@test "recovery rebuilds missing review batch state from the persisted dynamic review plan" {
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-200" --user-goal "审阅 1-200 章" --json > "$TMP_DIR/create.json"

    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const durable = path.join(root, pointer.task_dir, 'task.json');
const task = JSON.parse(fs.readFileSync(durable, 'utf8'));
    delete task.review_batches;
task.status = 'running';
task.current_stage = 'evidence_scan';
task.current_step = 'evidence_scan';
task.stage_execution = {
  stage_id: 'evidence_scan',
  status: 'running',
  expected_result_packet: `${task.task_dir}/result-packets/evidence_scan.result.json`
};
task.evidence_scan = {
  batch_status: 'completed',
  batch_no: '001',
  batch_range: '1-200',
  summary: '只抽样检查了第 1 章和第 50 章，其余章节尚未逐章审阅。',
  evidence_artifacts: ['追踪/边界抽样.md']
};
task.machine.completed_stages = ['range_lock', 'evidence_scan'];
task.machine.remaining_stages = ['classify_findings', 'design_fix_plan', 'apply_fix', 'verification', 'final_acceptance'];
fs.writeFileSync(durable, JSON.stringify(task, null, 2) + '\n');
NODE

    node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/recover-review.json"

    node - "$TMP_DIR/recover-review.json" "$(focused_task_path)" <<'NODE'
const fs = require('fs');
const path = require('path');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'review_batches_initialized') throw new Error(out.status);
if (!task.review_batches || task.review_batches.total_count < 1) throw new Error('review batches not initialized');
const root=process.argv[3].split('/追踪/workflow/tasks/')[0];
const plan=JSON.parse(fs.readFileSync(path.join(root,task.review_plan_path),'utf8'));
if (task.review_batches.total_count!==plan.batches.length) throw new Error('recovery ignored persisted plan batches');
if (task.review_batches.batches.some(batch=>!plan.batches.some(entry=>entry.id===batch.plan_entry_id && entry.range===batch.range))) throw new Error('batch state was not rebuilt from the persisted plan');
if (plan.batches.some(batch=>batch.range==='1-50') && task.review_batches.total_count===4) throw new Error('legacy fixed four-batch plan was rebuilt');
if (task.review_batches.completed_count !== 0) throw new Error('sampled batch was falsely completed');
if (task.current_stage !== 'evidence_scan') throw new Error(task.current_stage);
if (task.machine.completed_stages.includes('evidence_scan')) throw new Error('evidence_scan remained completed');
if (task.stage_execution.status !== 'paused') throw new Error(task.stage_execution.status);
if (!task.review_batches.legacy_evidence_snapshot) throw new Error('legacy evidence snapshot not preserved');
const durableCheckpoint = `${task.task_dir}/task.json`;
if (task.runtime_guard.heartbeat.latest_trusted_artifact !== durableCheckpoint) {
  throw new Error(`unexpected trusted artifact: ${task.runtime_guard.heartbeat.latest_trusted_artifact}`);
}
if (!fs.existsSync(path.join(root, durableCheckpoint))) {
  throw new Error('trusted checkpoint does not exist');
}
const allowedKeys=['accepted_result_packet','id','plan_entry_id','range','status','unresolved_dimensions'];
if (!task.review_batches.batches.every(batch => JSON.stringify(Object.keys(batch).sort()) === JSON.stringify(allowedKeys))) {
  throw new Error('legacy migration persisted fields outside the lifecycle contract');
}
NODE
}

@test "recovery blocks missing and stale plans before legacy review migration" {
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-200" --user-goal "审阅 1-200 章" --json >/dev/null
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));const current=path.join(root,pointer.task_dir,'task.json');const task=JSON.parse(fs.readFileSync(current,'utf8'));
fs.rmSync(path.join(root,task.review_plan_path));
delete task.review_batches;
task.current_stage='evidence_scan';task.current_step='evidence_scan';
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    status=0
    node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/missing-plan.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_missing"' "$TMP_DIR/missing-plan.json"

    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-200" --user-goal "审阅 1-200 章" --json >/dev/null
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));const current=path.join(root,pointer.task_dir,'task.json');const task=JSON.parse(fs.readFileSync(current,'utf8'));
const planPath=path.join(root,task.review_plan_path);const plan=JSON.parse(fs.readFileSync(planPath,'utf8'));
plan.budget_policy.runtime_budget='tampered';
fs.writeFileSync(planPath,JSON.stringify(plan,null,2)+'\n');
delete task.review_batches;
task.current_stage='evidence_scan';task.current_step='evidence_scan';
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    status=0
    node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/stale-plan.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_stale"' "$TMP_DIR/stale-plan.json"
}

@test "recovery keeps Task 2 persisted review plans read-only" {
    node - "$PROJECT" <<'NODE'
const crypto=require('crypto');
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const stable=(value)=>Array.isArray(value) ? `[${value.map(stable).join(',')}]` : value && typeof value==='object' ? `{${Object.keys(value).sort().map((key)=>`${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}` : JSON.stringify(value);
const workflowId='wf-task2-recovery';
const taskDir=`追踪/workflow/tasks/${workflowId}`;
const plan={
  schemaVersion:'2.0.0', workflow_id:workflowId, parent_scope:'1-8',
  required_dimensions:['plot','hooks','character','canon','prose'], source_identity:{}, budget_policy:{},
  batches:[{id:'batch-001',range:'1-8',dispatch_plan:{mode:'agent_dispatch'}}],
  coverage_policy:{require_all_chapters:true,allow_unexplained_deferred:false},
};
const task={
  workflow_id:workflowId, workflow_type:'review_repair', scope:'1-8', task_dir:taskDir,
  review_plan_path:`${taskDir}/review-plan.json`, review_plan_digest:crypto.createHash('sha256').update(stable(plan)).digest('hex'),
  status:'running', current_stage:'evidence_scan', current_step:'evidence_scan',
  review_batches:{schemaVersion:'2.0.0',workflow_id:workflowId,parent_scope:'1-8',task_dir:taskDir,aggregate_status:'pending',completed_count:0,total_count:1,next_batch_id:'001',batches:[{id:'001',range:'1-8',status:'pending',plan_entry_id:'batch-001',accepted_result_packet:'',unresolved_dimensions:[]}]},
};
fs.mkdirSync(path.join(root,taskDir),{recursive:true});
fs.mkdirSync(path.join(root,'追踪/workflow'),{recursive:true});
fs.writeFileSync(path.join(root,task.review_plan_path),JSON.stringify(plan,null,2)+'\n');
fs.writeFileSync(path.join(root,taskDir,'task.json'),JSON.stringify(task,null,2)+'\n');
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify({schemaVersion:'1.0.0',workflow_id:workflowId,task_dir:taskDir,focused_at:'2026-07-12T00:00:00.000Z',state_version:1},null,2)+'\n');
NODE
    before_pointer="$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json")"
    before_durable="$(shasum -a 256 "$PROJECT/追踪/workflow/tasks/wf-task2-recovery/task.json")"
    status=0
    node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/task2-recover.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_legacy_read_only"' "$TMP_DIR/task2-recover.json"
    grep -q '"action_id": "create_new_review_task"' "$TMP_DIR/task2-recover.json"
    [ "$before_pointer" = "$(shasum -a 256 "$PROJECT/追踪/workflow/current-task.json")" ]
    [ "$before_durable" = "$(shasum -a 256 "$PROJECT/追踪/workflow/tasks/wf-task2-recovery/task.json")" ]
}

@test "recovery repairs a missing trusted artifact pointer to the real checkpoint" {
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-200" --user-goal "审阅 1-200 章" --json > "$TMP_DIR/create.json"

    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const current = path.join(root, pointer.task_dir, 'task.json');
const task = JSON.parse(fs.readFileSync(current, 'utf8'));
task.runtime_guard.heartbeat.latest_trusted_artifact = `${task.task_dir}/result-packets/not-created.result.json`;
fs.writeFileSync(current, JSON.stringify(task, null, 2) + '\n');
NODE

    node "$RECOVER" --project-root "$PROJECT" --write --json > "$TMP_DIR/recover-trusted.json"

    node - "$TMP_DIR/recover-trusted.json" "$(focused_task_path)" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'trusted_checkpoint_repaired') throw new Error(out.status);
if (task.runtime_guard.heartbeat.latest_trusted_artifact !== `${task.task_dir}/task.json`) {
  throw new Error(task.runtime_guard.heartbeat.latest_trusted_artifact);
}
NODE
}
