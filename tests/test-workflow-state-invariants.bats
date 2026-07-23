#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    VALIDATE="$REPO/scripts/workflow-state-validate.js"
    TASK_FIXTURE="$REPO/tests/helpers/workflow-task-fixture.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

create_review_task() {
    node "$STATE_MACHINE" create --workflow-type review_repair --project-root "$PROJECT" --scope "1-200" --user-goal "审阅 1-200 章" --json > "$TMP_DIR/create.json"
}

resolve_action() {
    node - "$STATE_MACHINE" "$PROJECT" "${1:-1}" "$TASK_FIXTURE" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const script=process.argv[2],root=process.argv[3],input=process.argv[4],fixture=require(process.argv[5]);
const task=fixture.readFocusedTask(root);
const pending=task.pending_action||{};
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input',input,'--pending-action-id',String(pending.id||''),'--visible-choice-hash',String(pending.visible_choice_hash||''),'--state-version',String(task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
}

@test "workflow validator blocks a stage that is both completed and running" {
    create_review_task
    resolve_action >/dev/null
    node - "$PROJECT" "$TASK_FIXTURE" <<'NODE'
const fs=require('fs'), path=require('path');
const root=process.argv[2],fixture=require(process.argv[3]);
const current=fixture.focusedTaskFile(root);
const task=fixture.readFocusedTask(root);
task.machine.completed_stages.push(task.current_stage);
fs.writeFileSync(current, JSON.stringify(task,null,2)+'\n');
NODE

    status=0
    node "$VALIDATE" --project-root "$PROJECT" --json > "$TMP_DIR/validate.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked"' "$TMP_DIR/validate.json"
    grep -q '"reason_code": "state_invariant"' "$TMP_DIR/validate.json"
    grep -q 'running_stage_already_completed' "$TMP_DIR/validate.json"

    status=0
    node "$STATE_MACHINE" inspect --project-root "$PROJECT" --json > "$TMP_DIR/inspect.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_state_invariant"' "$TMP_DIR/inspect.json"
}

@test "workflow state machine rejects expired numbered choices" {
    create_review_task
    node - "$PROJECT" "$TASK_FIXTURE" <<'NODE'
const fs=require('fs'), path=require('path');
const root=process.argv[2],fixture=require(process.argv[3]);
const current=fixture.focusedTaskFile(root);
const task=fixture.readFocusedTask(root);
task.pending_action.expires_at='2000-01-01T00:00:00.000Z';
fs.writeFileSync(current, JSON.stringify(task,null,2)+'\n');
NODE

    status=0
    resolve_action > "$TMP_DIR/out.json" || status=$?
    [ "$status" -eq 0 ]
    grep -q '"status": "blocked_selection_expired"' "$TMP_DIR/out.json"
}

@test "workflow state machine rejects replaying an already resolved menu" {
    create_review_task
    resolve_action >/dev/null

    status=0
    resolve_action > "$TMP_DIR/out.json" || status=$?
    [ "$status" -eq 0 ]
    grep -q '"status": "blocked_selection_resolved"' "$TMP_DIR/out.json"
}

@test "new workflow requires a complete v2 result packet" {
    create_review_task
    task_id="$(node -e 'const fs=require("fs");const x=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(x.task.workflow_id)' "$TMP_DIR/create.json")"
    mkdir -p "$PROJECT/追踪/workflow/test-packets"
    packet="$PROJECT/追踪/workflow/test-packets/incomplete.json"
    cat > "$packet" <<JSON
{
  "workflow_id": "$task_id",
  "workflow_type": "review_repair",
  "stage_id": "range_lock",
  "step_id": "range_lock",
  "owner_module": "story-workflow",
  "step_status": "completed",
  "verification_result": "pass"
}
JSON

    status=0
    node "$STATE_MACHINE" apply-result --project-root "$PROJECT" --result "$packet" --json > "$TMP_DIR/out.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_result_packet_incomplete"' "$TMP_DIR/out.json"
    grep -q 'checkpoint_state' "$TMP_DIR/out.json"
    grep -q 'output_health_result' "$TMP_DIR/out.json"
}

@test "workflow validator blocks stale short section result packet at checkpoint" {
    mkdir -p "$PROJECT/追踪/workflow"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$PROJECT" --scope "第6节" --user-goal "继续短篇" --json >/dev/null

    node - "$PROJECT" "$TASK_FIXTURE" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const fixture = require(process.argv[3]);
const taskFile = fixture.focusedTaskFile(root);
const task = fixture.readFocusedTask(root);
const packetRel = `${task.task_dir}/result-packets/quality_gate.result.json`;
const packetAbs = path.join(root, packetRel);
task.scope = '第6节';
task.current_stage = 'quality_gate';
task.current_step = 'quality_gate';
task.status = 'running';
task.unit_lifecycle = {
  ...(task.unit_lifecycle || {}),
  unit_type: 'section',
  status: 'active',
  current_scope: '第6节',
  current_stage: 'quality_gate'
};
task.stage_execution = {
  status: 'running',
  stage_id: 'quality_gate',
  step_id: 'quality_gate',
  expected_result_packet: packetRel
};
task.runtime_guard = task.runtime_guard || {};
task.runtime_guard.checkpoint_policy = {
  ...(task.runtime_guard.checkpoint_policy || {}),
  resume_from: 'quality_gate',
  checkpoint_path: `${task.task_dir}/task.json`,
  expected_result_packet: packetRel,
  project_root: '.'
};
fs.mkdirSync(path.dirname(packetAbs), { recursive: true });
fs.writeFileSync(packetAbs, JSON.stringify({
  workflow_id: task.workflow_id,
  workflow_type: task.workflow_type,
  stage_id: 'quality_gate',
  step_id: 'quality_gate',
  step_status: 'completed',
  outputs: [],
  changed_files: [],
  evidence: [],
  verification_result: 'pass',
  checkpoint_state: {},
  output_health_result: 'pass',
  current_section_index: 5
}, null, 2));
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE

    status=0
    node "$VALIDATE" --project-root "$PROJECT" --json > "$TMP_DIR/validate.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked"' "$TMP_DIR/validate.json"
    grep -q '"reason_code": "stale_result_packet_scope"' "$TMP_DIR/validate.json"
    grep -q 'blocked_result_packet_unit_mismatch' "$TMP_DIR/validate.json"
}

@test "workflow validator keeps analyzed short feedback blocked until repair and reacceptance finish" {
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$PROJECT" --scope "第6节" --user-goal "继续短篇" --json >/dev/null

    node - "$PROJECT" "$TASK_FIXTURE" <<'NODE'
const fs = require('fs');
const fixture = require(process.argv[3]);
const root = process.argv[2];
const taskFile = fixture.focusedTaskFile(root);
const task = fixture.readFocusedTask(root);
task.scope = '第6节';
task.current_stage = 'quality_gate';
task.current_step = 'quality_gate';
task.status = 'running';
task.unit_lifecycle = {
  ...(task.unit_lifecycle || {}),
  unit_type: 'section',
  status: 'active',
  current_scope: '第6节',
  current_stage: 'quality_gate'
};
task.stage_execution = {
  status: 'running',
  stage_id: 'quality_gate',
  step_id: 'quality_gate',
  expected_result_packet: `${task.task_dir}/result-packets/quality_gate.result.json`
};
task.runtime_guard = task.runtime_guard || {};
task.runtime_guard.checkpoint_policy = {
  ...(task.runtime_guard.checkpoint_policy || {}),
  resume_from: 'quality_gate',
  checkpoint_path: `${task.task_dir}/task.json`,
  expected_result_packet: task.stage_execution.expected_result_packet,
  project_root: '.'
};
task.pending_feedback = {
  feedback_id: 'feedback-test-section-6',
  text: '第6节AI味有点重',
  classification: 'current_artifact_feedback',
  received_at: '2026-07-17T11:52:40.471Z'
};
task.short_feedback_impact = {
  status: 'ok',
  feedback_id: 'feedback-test-section-6',
  impact_level: 'expression_only',
  invalidates_brief: true,
  invalidates_draft: true,
  requires_reacceptance: true,
  applied_at: '2026-07-17T12:00:27.651Z'
};
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE

    status=0
    node "$VALIDATE" --project-root "$PROJECT" --json > "$TMP_DIR/validate.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"reason_code": "pending_feedback_unreconciled"' "$TMP_DIR/validate.json"
    grep -q 'blocked_short_feedback_unreconciled' "$TMP_DIR/validate.json"
}

@test "pending short feedback resumes through one deterministic recovery command" {
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$PROJECT" --scope "第6节" --user-goal "继续短篇" --json >/dev/null

    mkdir -p "$PROJECT/追踪/private-short-extension"
    cat > "$PROJECT/追踪/private-short-extension/project-state.json" <<'JSON'
{"project_id":"resume-feedback","plan_revision":1,"working_title":"恢复测试","narrative":{"planned_sections":6},"current_section_index":6}
JSON
    cat > "$PROJECT/小节大纲.md" <<'EOF'
# 小节大纲
## 第6节：当面对质
- 结构功能：中段判断翻转。
- 承接上节：伪造签名疑点迫使主角对质。
- 场景动作：主角把合同推到对方面前。
- 子事件：
  1. 对手抢走合同。
  2. 主角出示原始邮件。
- 情绪目标：怀疑转为决绝。
- 压力变化：私下怀疑升级为公开冲突。
- 因果链：发现异常 -> 当面对质 -> 抢夺合同 -> 留下备份。
- 角色选择：主角拒绝删除备份。
- 可见阻力：对手停掉她的工作权限。
- 本节兑现：伪造签名成为可验证事实。
- 关系变化：双方从暗中怀疑转为公开对抗。
- 代价升级：主角失去工作保护。
- 节尾钩子：邮件抄送栏还有另一名家人。
EOF
    cat > "$PROJECT/写作Brief_第006节.md" <<'EOF'
# 第6节写作提要
## 本节任务
主角当面对质并保住原始邮件。
## 视角与称谓
第一人称，主角称“我”。
## 禁止漂移
不改变人物动机，不引入外部救场。
## 验收标准
完成公开冲突、可验证证据和失去工作保护的代价。
EOF
    printf '# 第6节\n\n我把合同推到他面前。\n' > "$PROJECT/草稿_第006节_候选.md"

    node - "$PROJECT" "$TASK_FIXTURE" <<'NODE'
const fs = require('fs'), path = require('path');
const fixture = require(process.argv[3]);
const root = process.argv[2];
const taskFile = fixture.focusedTaskFile(root);
const task = fixture.readFocusedTask(root);
const gateRel = `${task.task_dir}/result-packets/section_machine_gate.section-006.result.json`;
fs.mkdirSync(path.dirname(path.join(root, gateRel)), { recursive: true });
fs.writeFileSync(path.join(root, gateRel), JSON.stringify({ machine_gate_result: 'blocking', blocking_findings: [{ code: 'ai-style', message: '修订表达。' }] }, null, 2) + '\n');
task.current_stage = 'draft_next_section';
task.current_step = 'draft_next_section';
task.machine.last_result_packet = gateRel;
task.pending_feedback = { feedback_id: 'feedback-resume', text: '第6节AI味有点重', section_index: 6, scope_snapshot: '第6节', received_at: new Date().toISOString() };
task.short_feedback_impact = { status: 'ok', feedback_id: 'feedback-resume', impact_level: 'expression_only', invalidates_draft: true, requires_reacceptance: true, applied_at: new Date().toISOString() };
task.pending_action = { id: 'pa-stale-next', status: 'pending', options: [{ number: 1, target_stage: 'draft_next_section' }] };
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE

    workflow_id="$(node -e 'const f=require(process.argv[1]);console.log(f.readFocusedTask(process.argv[2]).workflow_id)' "$TASK_FIXTURE" "$PROJECT")"
    run node "$STATE_MACHINE" resume-pending-short-feedback --project-root "$PROJECT" --workflow-id "$workflow_id" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "pending_short_feedback_resumed"'* ]]
    [[ "$output" == *'"target_stage": "section_repair_loop"'* ]]
    node - "$PROJECT" "$TASK_FIXTURE" <<'NODE'
const fixture = require(process.argv[3]);
const task = fixture.readFocusedTask(process.argv[2]);
if (task.current_stage !== 'section_repair_loop' || task.stage_execution.status !== 'running' || task.scope !== '第6节') throw new Error(JSON.stringify(task));
NODE
}

@test "state version increases after each successful mutation" {
    create_review_task
    before="$(node -e 'const fixture=require(process.argv[1]);console.log(fixture.readFocusedTask(process.argv[2]).state_version)' "$TASK_FIXTURE" "$PROJECT")"
    resolve_action >/dev/null
    after="$(node -e 'const fixture=require(process.argv[1]);console.log(fixture.readFocusedTask(process.argv[2]).state_version)' "$TASK_FIXTURE" "$PROJECT")"
    [ "$before" -ge 1 ]
    [ "$after" -gt "$before" ]
}

@test "workflow mutation stops when another process holds the project lock" {
    create_review_task
    mkdir -p "$PROJECT/追踪/workflow/.workflow.lock"
    cat > "$PROJECT/追踪/workflow/.workflow.lock/owner.json" <<'JSON'
{"pid":99999,"owner":"other-session","acquired_at":"2099-01-01T00:00:00.000Z"}
JSON

    status=0
    resolve_action > "$TMP_DIR/out.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_workflow_locked"' "$TMP_DIR/out.json"
}

@test "new long workflow passes the repository runtime guard validator" {
    create_review_task
    node "$REPO/scripts/runtime-guard-validate.js" --kind current-task "$PROJECT/追踪/workflow/current-task.json" --json > "$TMP_DIR/out.json"
    grep -q '"status": "ok"' "$TMP_DIR/out.json"
}

@test "completed workflow cannot hide an unprojected accepted plan or active revision queue" {
    node - "$REPO/scripts/lib/workflow-state-store.js" <<'NODE'
const {validateTaskState}=require(process.argv[2]);
const base={status:'completed',lifecycle:{status:'completed'},current_stage:'final_check',machine:{completed_stages:['final_check']},stage_execution:{status:'completed'},state_version:1,book_root:'.'};
const plan=validateTaskState({...base,accepted_plan:{status:'accepted_pending_projection',projection_status:'pending'}});
if(!plan.some(item=>item.code==='completed_with_unprojected_accepted_plan')) throw new Error(JSON.stringify(plan));
const queue=validateTaskState({...base,feedback_revision_queue:{status:'running',current_section_index:2}});
if(!queue.some(item=>item.code==='completed_with_active_feedback_revision_queue')) throw new Error(JSON.stringify(queue));
NODE
}

@test "mutating finalizers cannot infer a workflow from UI focus when multiple tasks are unfinished" {
    node - "$REPO/scripts/lib/workflow-command-task-binding.js" "$PROJECT" <<'NODE'
const fs=require('fs'),path=require('path');
const {singleUnfinishedWorkflowId}=require(process.argv[2]);
const root=process.argv[3], base=path.join(root,'追踪/workflow/tasks');
for(const id of ['wf-a','wf-b']){const dir=path.join(base,id);fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'task.json'),JSON.stringify({workflow_id:id,status:'running',lifecycle:{status:'active'}}));}
fs.mkdirSync(path.join(root,'追踪/workflow'),{recursive:true});fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify({workflow_id:'wf-a',task_dir:'追踪/workflow/tasks/wf-a'}));
if(singleUnfinishedWorkflowId(root)!=='') throw new Error('focus pointer was incorrectly treated as write authority');
const second=path.join(base,'wf-b','task.json');const task=JSON.parse(fs.readFileSync(second,'utf8'));task.status='completed';task.lifecycle.status='completed';fs.writeFileSync(second,JSON.stringify(task));
if(singleUnfinishedWorkflowId(root)!=='wf-a') throw new Error('single durable task was not recovered');
NODE
}

@test "private short workflow audits formal assets before terminal completion" {
    node - "$REPO/scripts/lib/canonical-write-audit.js" "$PROJECT" <<'NODE'
const fs=require('fs'),path=require('path');
const {captureCanonicalBaseline,auditCanonicalWrites}=require(process.argv[2]);
const root=process.argv[3];
const task={workflow_id:'wf-private-short',workflow_type:'private_short_startup',task_dir:'追踪/workflow/tasks/wf-private-short'};
fs.mkdirSync(path.join(root,task.task_dir),{recursive:true});
fs.writeFileSync(path.join(root,'设定.md'),'旧设定\n');
const baseline=captureCanonicalBaseline(root,task);
if(!baseline.declared_write_set.includes('设定.md')) throw new Error(JSON.stringify(baseline));
fs.writeFileSync(path.join(root,'设定.md'),'绕过事务的新设定\n');
const audit=auditCanonicalWrites(root,task);
if(audit.status!=='blocked_unreconciled_canonical_write'||!audit.unmanaged_paths.includes('设定.md')) throw new Error(JSON.stringify(audit));
NODE
}
