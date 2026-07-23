#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    BATCHES="$REPO/scripts/workflow-review-batches.js"
    export WORKFLOW_TASK_FIXTURE="$REPO/tests/helpers/workflow-task-fixture.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "review batches report missing durable authority for an existing focus pointer" {
    mkdir -p "$PROJECT/追踪/workflow"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-missing","task_dir":"追踪/workflow/tasks/wf-missing","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON

    run node "$BATCHES" inspect --project-root "$PROJECT" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'"status": "blocked_task_authority_missing"'* ]]
}

resolve_action() {
    node - "$STATE_MACHINE" "$PROJECT" "${1:-1}" <<'NODE'
const fs=require('fs'), cp=require('child_process');
const script=process.argv[2], root=process.argv[3], input=process.argv[4];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const pending=task.pending_action||{};
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input',input,'--pending-action-id',String(pending.id||''),'--visible-choice-hash',String(pending.visible_choice_hash||''),'--state-version',String(task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
}

write_packet() {
    local file="$1"
    local workflow_id="$2"
    local stage="$3"
    local batch_id="${4:-}"
    local batch_scope=""
    local protocol_version=""
    local source_digest=""
    local full_range_coverage="null"
    if [ "$stage" = "evidence_scan" ]; then
        batch_scope="$(node -e 'const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(task.stage_execution.batch_scope || "");' "$PROJECT")"
        scan_json="$(node "$REPO/scripts/review-batch-evidence-scan.js" --project-root "$PROJECT" --range "$batch_scope" --json)"
        protocol_version="$(printf '%s' "$scan_json" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).protocolVersion||""))')"
        source_digest="$(printf '%s' "$scan_json" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).sourceDigest||""))')"
        full_range_coverage="$(printf '%s' "$scan_json" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(JSON.parse(s).fullRangeCoverage||null)))')"
    fi
    mkdir -p "$(dirname "$file")"
    cat > "$file" <<JSON
{
  "workflow_id":"$workflow_id",
  "workflow_type":"review_repair",
  "stage_id":"$stage",
  "step_id":"$stage",
  "step_status":"completed",
  "batch_id":"$batch_id",
  "batch_scope":"$batch_scope",
  "protocolVersion":"$protocol_version",
  "sourceDigest":"$source_digest",
  "fullRangeCoverage":$full_range_coverage,
  "outputs":[],
  "changed_files":[],
  "evidence":["batch $batch_id evidence"],
  "verification_result":"pass",
  "checkpoint_state":{"completed_stage":"$stage","batch_id":"$batch_id"},
  "output_health_result":"pass",
  "next_recommendation":"继续下一批"
}

JSON
}

@test "review creation only falls back when the requested scope has no candidate assets" {
    mkdir -p "$PROJECT/追踪/schema"
    printf '%s\n' '{"chapterNo":1,"globalDraftOrder":1,"draftPath":"正文/chapter001.md"}' > "$PROJECT/追踪/schema/chapters.jsonl"

    status=0
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-1" --user-goal "审阅 1-1 章" --json > "$TMP_DIR/create.json" 2> "$TMP_DIR/create.err" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_evidence_incomplete"' "$TMP_DIR/create.json"
    grep -q 'blocked_missing_source_file' "$TMP_DIR/create.json"
    [ ! -f "$PROJECT/追踪/workflow/current-task.json" ]
    [ ! -s "$TMP_DIR/create.err" ]
}

current_expected_packet() {
    node -e 'const path=require("path");const root=process.argv[1];const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);process.stdout.write(path.resolve(root,task.stage_execution.expected_result_packet));' "$PROJECT"
}

prepare_evidence_scan() {
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
for (let order=1; order<=8; order+=1) {
  const file=path.join(root,'正文',`chapter${String(order).padStart(3,'0')}.md`);
  fs.mkdirSync(path.dirname(file), {recursive:true});
  fs.writeFileSync(file, `# Chapter ${order}\n\nA short trusted narrative scene for chapter ${order}.\n`);
}
NODE
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-8" --user-goal "审阅 1-8 章" --json > "$TMP_DIR/create.json"
    workflow_id="$(node -e 'const fs=require("fs");const x=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(x.task.workflow_id)' "$TMP_DIR/create.json")"
    resolve_action >/dev/null
    range_packet="$(current_expected_packet)"
    write_packet "$range_packet" "$workflow_id" range_lock
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$range_packet" --json > "$TMP_DIR/range-apply.json"
}

write_task2_legacy_review_task() {
    node - "$PROJECT" <<'NODE'
const crypto=require('crypto');
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const stable=(value)=>Array.isArray(value) ? `[${value.map(stable).join(',')}]` : value && typeof value==='object' ? `{${Object.keys(value).sort().map((key)=>`${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}` : JSON.stringify(value);
const workflowId='wf-task2-persisted';
const taskDir=`追踪/workflow/tasks/${workflowId}`;
const plan={
  schemaVersion:'2.0.0', workflow_id:workflowId, parent_scope:'1-8',
  required_dimensions:['plot','hooks','character','canon','prose'],
  source_identity:{workflow_type:'review_repair',parent_scope:'1-8'},
  budget_policy:{runtime_budget:6400,batch_size:50,risk_level:'medium'},
  batches:[{id:'batch-001',range:'1-8',dispatch_plan:{mode:'agent_dispatch',parent_scope:'1-8',batch_scope:'1-8'}}],
  coverage_policy:{require_all_chapters:true,allow_unexplained_deferred:false},
};
const task={
  workflow_id:workflowId, workflow_type:'review_repair', result_contract_version:1,
  scope:'1-8', task_dir:taskDir, status:'awaiting_selection', current_stage:'range_lock', current_step:'range_lock',
  review_plan_path:`${taskDir}/review-plan.json`,
  review_plan_digest:crypto.createHash('sha256').update(stable(plan)).digest('hex'),
  pending_action:{id:'pa-range-lock',status:'pending',options:[{number:1,action_id:'continue_next_stage',label:'继续锁定范围',target_stage:'range_lock',risk_level:'low',requires_user_confirm:false}]},
  review_batches:{schemaVersion:'2.0.0',workflow_id:workflowId,parent_scope:'1-8',task_dir:taskDir,aggregate_status:'pending',completed_count:0,total_count:1,next_batch_id:'001',batches:[{id:'001',range:'1-8',status:'pending',plan_entry_id:'batch-001',accepted_result_packet:'',unresolved_dimensions:[]}]},
};
fs.rmSync(path.join(root,'追踪','workflow'),{recursive:true,force:true});
fs.mkdirSync(path.join(root,taskDir),{recursive:true});
fs.writeFileSync(path.join(root,task.review_plan_path),JSON.stringify(plan,null,2)+'\n');
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify(task,null,2)+'\n');
fs.writeFileSync(path.join(root,taskDir,'task.json'),JSON.stringify(task,null,2)+'\n');
NODE
}

workflow_tree_digest() {
    node - "$PROJECT/追踪/workflow" <<'NODE'
const crypto=require('crypto');
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const files=[];
function visit(dir) {
  for (const entry of fs.readdirSync(dir,{withFileTypes:true})) {
    const file=path.join(dir,entry.name);
    if (entry.isDirectory()) visit(file);
    else files.push(file);
  }
}
visit(root);
process.stdout.write(files.sort().map((file)=>`${path.relative(root,file)}:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`).join('\n'));
NODE
}

@test "review workflow derives durable narrative batches from persisted evidence" {
    prepare_evidence_scan
    node "$BATCHES" inspect --project-root "$PROJECT" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$PROJECT" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[3]);
if(out.status!=='ok') throw new Error(out.status);
    if(out.parent_scope!=='1-8') throw new Error(out.parent_scope);
    if(out.batches.length < 2) throw new Error(`expected adaptive batches: ${JSON.stringify(out.batches)}`);
    const primary = out.batches.flatMap((batch) => { const [start,end]=batch.range.split('-').map(Number); return Array.from({length:end-start+1}, (_, offset) => start+offset); });
    if(primary.length!==8 || new Set(primary).size!==8 || !primary.every((order) => order>=1 && order<=8)) throw new Error(`primary coverage drifted: ${JSON.stringify(out.batches)}`);
if(out.batches.some(batch=>batch.dispatch_plan && batch.dispatch_plan.agents)) {
  throw new Error('batch state must not embed a second agent authority');
}

if(!task.review_plan_path || !task.review_plan_digest) {
  throw new Error('review plan reference missing');
}
if(!out.batches.every(batch=>batch.plan_entry_id && batch.accepted_result_packet==='')) {
  throw new Error('batch lifecycle contract missing');
}
const allowedKeys=['accepted_result_packet','id','plan_entry_id','range','status','unresolved_dimensions'];
if(!out.batches.every(batch=>JSON.stringify(Object.keys(batch).sort())===JSON.stringify(allowedKeys))) {
  throw new Error('batch state contains fields outside the lifecycle contract');
}
NODE
}

@test "root review state machine persists an adaptive plan before advancing its first evidence batch" {
    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const plan=JSON.parse(fs.readFileSync(path.join(root,task.review_plan_path),'utf8'));
if(plan.batches.some((batch)=>!batch.dispatch_plan || batch.dispatch_plan.mode!=='agent_dispatch' || !batch.primary_chapter_keys.length || !batch.boundary_context)) throw new Error(JSON.stringify(plan.batches));
if(plan.budget_policy.source_budget_origin!=='conservative_fallback') throw new Error(JSON.stringify(plan.budget_policy));
if(!plan.source_identity.digest) throw new Error('source identity digest missing');
NODE
    resolve_action >/dev/null
    batch_packet="$(current_expected_packet)"
    write_packet "$batch_packet" "$workflow_id" evidence_scan 001
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json > "$TMP_DIR/first-batch.json"
    grep -Eq '"status": "(batch_advanced|advanced)"' "$TMP_DIR/first-batch.json"
}

@test "review batches command rejects obsolete fixed batch size input" {
    status=0
    node "$BATCHES" inspect --project-root "$PROJECT" --batch-size 50 --json > "$TMP_DIR/deprecated.json" 2> "$TMP_DIR/deprecated.err" || status=$?
    [ "$status" -eq 1 ]
    grep -q 'deprecated' "$TMP_DIR/deprecated.err"
}

@test "review task blocks when its referenced review plan is missing or stale" {
    prepare_evidence_scan

    plan_path="$(node -e 'const path=require("path");const root=process.argv[1];const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);process.stdout.write(path.join(root,task.review_plan_path));' "$PROJECT")"
    rm -f "$plan_path"
    status=0
    resolve_action > "$TMP_DIR/missing.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_missing"' "$TMP_DIR/missing.json"

    prepare_evidence_scan
    plan_path="$(node -e 'const path=require("path");const root=process.argv[1];const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);process.stdout.write(path.join(root,task.review_plan_path));' "$PROJECT")"
    node - "$plan_path" <<'NODE'
const fs=require('fs');
const plan=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
plan.budget_policy.runtime_budget='tampered';
fs.writeFileSync(process.argv[2], JSON.stringify(plan, null, 2)+'\n');
NODE
    status=0
    resolve_action > "$TMP_DIR/stale.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_stale"' "$TMP_DIR/stale.json"
}

@test "legacy review task without a plan reference remains inspectable" {
    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);
const task=JSON.parse(fs.readFileSync(current,'utf8'));
delete task.review_plan_path;
delete task.review_plan_digest;
fs.writeFileSync(current, JSON.stringify(task, null, 2)+'\n');
NODE
    node "$BATCHES" inspect --project-root "$PROJECT" --json > "$TMP_DIR/legacy.json"
    grep -q '"status": "ok"' "$TMP_DIR/legacy.json"
}

@test "Task 2 persisted review plans are inspect-only and never mutate workflow state" {
    write_task2_legacy_review_task

    node "$BATCHES" inspect --project-root "$PROJECT" --json > "$TMP_DIR/task2-inspect.json"
    grep -q '"status": "ok"' "$TMP_DIR/task2-inspect.json"
    grep -q '"plan_read_mode": "legacy_read_only"' "$TMP_DIR/task2-inspect.json"
    grep -q '"range": "1-8"' "$TMP_DIR/task2-inspect.json"

    before="$(workflow_tree_digest)"
    status=0
    resolve_action > "$TMP_DIR/task2-resolve.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_legacy_read_only"' "$TMP_DIR/task2-resolve.json"
    grep -q '"action_id": "create_new_review_task"' "$TMP_DIR/task2-resolve.json"
    [ "$before" = "$(workflow_tree_digest)" ]

    before="$(workflow_tree_digest)"
    status=0
    node "$STATE_MACHINE" next-candidates --project-root "$PROJECT" --json > "$TMP_DIR/task2-next.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_legacy_read_only"' "$TMP_DIR/task2-next.json"
    [ "$before" = "$(workflow_tree_digest)" ]

    before="$(workflow_tree_digest)"
    status=0
    node "$BATCHES" init --project-root "$PROJECT" --write --json > "$TMP_DIR/task2-init.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_legacy_read_only"' "$TMP_DIR/task2-init.json"
    [ "$before" = "$(workflow_tree_digest)" ]

    cat > "$TMP_DIR/task2-range-lock.json" <<'JSON'
{
  "workflow_id":"wf-task2-persisted",
  "workflow_type":"review_repair",
  "stage_id":"range_lock",
  "step_id":"range_lock",
  "step_status":"completed"
}
JSON
    before="$(workflow_tree_digest)"
    status=0
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$TMP_DIR/task2-range-lock.json" --json > "$TMP_DIR/task2-apply.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_legacy_read_only"' "$TMP_DIR/task2-apply.json"
    grep -q '"action_id": "create_new_review_task"' "$TMP_DIR/task2-apply.json"
    [ "$before" = "$(workflow_tree_digest)" ]

    before="$(workflow_tree_digest)"
    status=0
    node "$STATE_MACHINE" switch-intent --workflow-type short_write --project-root "$PROJECT" --user-goal "写短篇" --reason manual_new_goal --json > "$TMP_DIR/task2-switch.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_legacy_read_only"' "$TMP_DIR/task2-switch.json"
    [ "$before" = "$(workflow_tree_digest)" ]
}

@test "review execution blocks batches whose plan entry or range differs from the verified plan" {
    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);const task=JSON.parse(fs.readFileSync(current,'utf8'));
task.review_batches.batches[0].range='2-2';
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    status=0
    resolve_action > "$TMP_DIR/range-mismatch.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_stale"' "$TMP_DIR/range-mismatch.json"

    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);const task=JSON.parse(fs.readFileSync(current,'utf8'));
task.review_batches.batches[0].plan_entry_id='batch-does-not-exist';
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    status=0
    resolve_action > "$TMP_DIR/id-mismatch.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_stale"' "$TMP_DIR/id-mismatch.json"
}

@test "review execution blocks when state omits a plan-required batch" {
    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);const task=JSON.parse(fs.readFileSync(current,'utf8'));
task.review_batches.batches.pop();
task.review_batches.total_count=task.review_batches.batches.length;
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    status=0
    resolve_action > "$TMP_DIR/missing-batch.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_stale"' "$TMP_DIR/missing-batch.json"
}

@test "review batches command blocks an invalid state-to-plan mapping" {
    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);const task=JSON.parse(fs.readFileSync(current,'utf8'));
task.review_batches.batches[0].range='2-2';
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    status=0
    node "$BATCHES" inspect --project-root "$PROJECT" --json > "$TMP_DIR/cli-mismatch.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_stale"' "$TMP_DIR/cli-mismatch.json"
}

@test "review batches command rejects deprecated caller batch size without rebuilding state" {
    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);const task=JSON.parse(fs.readFileSync(current,'utf8'));
delete task.review_batches;
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    status=0
    node "$BATCHES" init --project-root "$PROJECT" --batch-size 17 --write --json > "$TMP_DIR/cli-init.json" 2> "$TMP_DIR/cli-init.err" || status=$?
    [ "$status" -eq 1 ]
    grep -q 'deprecated' "$TMP_DIR/cli-init.err"
    node - "$PROJECT" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]);
if(task.review_batches) throw new Error('referenced task was rebuilt from caller batch size');
NODE
}

@test "started review task blocks when its persisted source evidence changes" {
    prepare_evidence_scan
    resolve_action >/dev/null
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const chapter=path.join(root,'正文','chapter001.md');
fs.appendFileSync(chapter, '\n源证据已变化。\n');
NODE
    status=0
    resolve_action > "$TMP_DIR/source-stale.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_stale"' "$TMP_DIR/source-stale.json"
}

@test "advancing a legacy-shaped review batch rewrites only lifecycle fields" {
    prepare_evidence_scan
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);const task=JSON.parse(fs.readFileSync(current,'utf8'));
Object.assign(task.review_batches.batches[0], {
  start: 1,
  end: 50,
  result_packet: `${task.task_dir}/result-packets/evidence_scan.batch-001.result.json`,
  dispatch_plan: { agents: ['story-architect', 'character-designer'] },
});
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
NODE
    resolve_action >/dev/null
    batch_packet="$(current_expected_packet)"
    write_packet "$batch_packet" "$workflow_id" evidence_scan 001
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json >/dev/null
    node - "$PROJECT" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]);
const batch=task.review_batches.batches[0];
const allowedKeys=['accepted_result_packet','id','plan_entry_id','range','status','unresolved_dimensions'];
if(JSON.stringify(Object.keys(batch).sort())!==JSON.stringify(allowedKeys)) {
  throw new Error(`legacy batch fields survived: ${JSON.stringify(batch)}`);
}
NODE
}

@test "one completed review batch keeps parent evidence scan active and selects next batch" {
    mkdir -p "$PROJECT/追踪/schema"
    for order in $(seq 1 8); do
        printf '{"chapterNo":%s,"globalDraftOrder":%s,"draftPath":"正文/chapter%03d.md"}\n' "$order" "$order" "$order"
    done > "$PROJECT/追踪/schema/chapters.jsonl"
    prepare_evidence_scan
    resolve_action > "$TMP_DIR/start.json"
    batch_packet="$(current_expected_packet)"
    write_packet "$batch_packet" "$workflow_id" evidence_scan 001
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$PROJECT" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[3]);
if(out.status!=='advanced') throw new Error(out.status);
if(out.progress!=='50%') throw new Error(JSON.stringify(out));
if(!String(out.next_user_action||'').includes('继续')) throw new Error(JSON.stringify(out));
if('next_command' in out) throw new Error('internal batch command leaked to visible result');
if(task.current_stage!=='evidence_scan') throw new Error(task.current_stage);
if(task.review_batches.batches[0].status!=='completed') throw new Error('batch 001 not complete');
if(task.review_batches.batches[1].status!=='pending') throw new Error('batch 002 not pending');
if(task.review_batches.next_batch_id!=='002') throw new Error(task.review_batches.next_batch_id);
if(task.machine.completed_stages.includes('evidence_scan')) throw new Error('parent completed too early');
const batch001Packet=`${task.task_dir}/result-packets/evidence_scan.batch-001.result.json`;
const batch002Packet=`${task.task_dir}/result-packets/evidence_scan.batch-002.result.json`;
if(task.stage_execution.expected_result_packet!==batch002Packet) throw new Error(`stage execution packet drifted: ${task.stage_execution.expected_result_packet}`);
if(task.runtime_guard.checkpoint_policy.expected_result_packet!==batch002Packet) throw new Error(`checkpoint packet drifted: ${task.runtime_guard.checkpoint_policy.expected_result_packet}`);
if(task.runtime_guard.heartbeat.latest_trusted_artifact!==batch001Packet) throw new Error(`trusted artifact drifted: ${task.runtime_guard.heartbeat.latest_trusted_artifact}`);
const allowedKeys=['accepted_result_packet','id','plan_entry_id','range','status','unresolved_dimensions'];
if(JSON.stringify(Object.keys(task.review_batches.batches[0]).sort())!==JSON.stringify(allowedKeys)) {
  throw new Error('completed batch state contains fields outside the lifecycle contract');
}
NODE
}

@test "review evidence scan cannot complete without a batch id" {
    prepare_evidence_scan
    resolve_action >/dev/null
    batch_packet="$(current_expected_packet)"
    write_packet "$batch_packet" "$workflow_id" evidence_scan

    status=0
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json > "$TMP_DIR/out.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_batch_required"' "$TMP_DIR/out.json"
}

@test "one scanner command writes the expected receipt and advances the active review batch" {
    prepare_evidence_scan
    resolve_action >/dev/null
    batch_scope="$(node -e 'const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(task.stage_execution.batch_scope);' "$PROJECT")"

    status=0
    node "$REPO/scripts/review-batch-evidence-scan.js" \
      --project-root "$PROJECT" --workflow-id "$workflow_id" --range "$batch_scope" --write --apply-result --json > "$TMP_DIR/scanner.json" || status=$?

    [ "$status" -eq 0 ]
    node - "$TMP_DIR/scanner.json" <<'NODE'
      const fs=require('fs');
      const x=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
        if(x.status!=="applied" || x.apply_result?.status!=="advanced") process.exit(1);
        if(!String(x.result_packet_path||"").endsWith("evidence_scan.batch-001.result.json")) process.exit(2);
        if((x.packet?.changed_files||[]).length!==0) process.exit(3);
NODE
    node - "$PROJECT" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
if(task.review_batches.batches[0].status!=='completed') throw new Error(JSON.stringify(task.review_batches));
if(task.review_batches.next_batch_id!=='002') throw new Error(JSON.stringify(task.review_batches));
NODE
}

@test "review evidence scan rejects write declarations and a scope that differs from the active batch" {
    prepare_evidence_scan
    resolve_action >/dev/null
    batch_packet="$(current_expected_packet)"
    write_packet "$batch_packet" "$workflow_id" evidence_scan 001
    node - "$batch_packet" <<'NODE'
const fs=require('fs');const file=process.argv[2];const packet=JSON.parse(fs.readFileSync(file,'utf8'));
packet.changed_files=['正文/chapter001.md'];
fs.writeFileSync(file,JSON.stringify(packet,null,2)+'\n');
NODE
    status=0
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json > "$TMP_DIR/readonly-write.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_evidence_scan_read_only"' "$TMP_DIR/readonly-write.json"

    rm -rf "$PROJECT/追踪/workflow"
    prepare_evidence_scan
    resolve_action >/dev/null
    batch_packet="$(current_expected_packet)"
    write_packet "$batch_packet" "$workflow_id" evidence_scan 001
    node - "$batch_packet" <<'NODE'
const fs=require('fs');const file=process.argv[2];const packet=JSON.parse(fs.readFileSync(file,'utf8'));
packet.batch_scope='2-2';
fs.writeFileSync(file,JSON.stringify(packet,null,2)+'\n');
NODE
    status=0
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json > "$TMP_DIR/scope-mismatch.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_batch_scope_mismatch"' "$TMP_DIR/scope-mismatch.json"
}

assert_non_array_write_declaration_rejected() {
    local field="$1"
    prepare_evidence_scan
    resolve_action >/dev/null
    batch_packet="$(current_expected_packet)"
    write_packet "$batch_packet" "$workflow_id" evidence_scan 001
    node - "$batch_packet" "$field" <<'NODE'
const fs=require('fs');
const [file,field]=process.argv.slice(2);
const packet=JSON.parse(fs.readFileSync(file,'utf8'));
packet[field]='正文/chapter001.md';
fs.writeFileSync(file,JSON.stringify(packet,null,2)+'\n');
NODE
    status=0
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json > "$TMP_DIR/non-array-$field.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_evidence_scan_write_declaration_invalid"' "$TMP_DIR/non-array-$field.json"
    node - "$PROJECT" "$field" <<'NODE'
const [root,field]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
if(task.current_stage!=='evidence_scan') throw new Error(`${field}: advanced to ${task.current_stage}`);
if(task.review_batches.batches[0].status!=='pending') throw new Error(`${field}: batch advanced`);
NODE
}

@test "review evidence scan fails closed for string changed_files" {
    assert_non_array_write_declaration_rejected changed_files
}

@test "review evidence scan fails closed for string created_files" {
    assert_non_array_write_declaration_rejected created_files
}

@test "review evidence scan fails closed for string write_actions" {
    assert_non_array_write_declaration_rejected write_actions
}

@test "review evidence scan fails closed for string canonical_writes" {
    assert_non_array_write_declaration_rejected canonical_writes
}

@test "review evidence scan advances only after every persisted batch completes" {
    prepare_evidence_scan
    batch_ids="$(node -e 'const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);console.log(task.review_batches.batches.map(batch=>batch.id).join(" "));' "$PROJECT")"
    for id in $batch_ids; do
        resolve_action >/dev/null
        batch_packet="$(current_expected_packet)"
        write_packet "$batch_packet" "$workflow_id" evidence_scan "$id"
        node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$batch_packet" --json > "$TMP_DIR/out-$id.json"
    done

    last_id="${batch_ids##* }"
    node - "$TMP_DIR/out-$last_id.json" "$PROJECT" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[3]);
if(out.status!=='advanced') throw new Error(out.status);
if(task.current_stage!=='classify_findings') throw new Error(task.current_stage);
if(task.review_batches.aggregate_status!=='completed') throw new Error(task.review_batches.aggregate_status);
if(!task.machine.completed_stages.includes('evidence_scan')) throw new Error('parent not complete');
NODE
}
