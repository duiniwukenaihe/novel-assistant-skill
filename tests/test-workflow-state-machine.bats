#!/usr/bin/env bats
# tests/test-workflow-state-machine.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/workflow-state-machine.js"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    SMOKE="$REPO/scripts/production-smoke-matrix.js"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    WORKFLOW_INBOX="$REPO/src/internal-skills/story-workflow/references/task-inbox-protocol.md"
    WORKFLOW_PHASE_INDEX="$REPO/src/internal-skills/story-workflow/references/phase-protocol-index.md"
    CONTRACT="$REPO/src/internal-skills/story-workflow/references/workflow-contract.md"
    README="$REPO/README.md"
    README_EN="$REPO/README_EN.md"
    SCRIPTS_README="$REPO/scripts/README.md"
    BUNDLE="$REPO/skills/novel-assistant"
    export WORKFLOW_TASK_FIXTURE="$REPO/tests/helpers/workflow-task-fixture.js"
    TMP_DIR="$(mktemp -d)"
}

@test "state machine usage documents apply-result workflow authority" {
    run node "$SCRIPT" templates --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apply-result --project-root <book-dir> --workflow-id <id> --result <file>'* ]]
}

@test "short draft stop recommends the concrete section instead of saying continue continue" {
    run node - "$REPO/scripts/lib/workflow-action-renderer.js" <<'NODE'
const { buildShortDraftPendingAction } = require(process.argv[2]);
const pending = buildShortDraftPendingAction({ stage_id: 'draft_next_section', risk_level: 'high' }, { scope: '第7节' });
if (pending.question !== '第 7 节写作提要已通过，推荐下一步') throw new Error(JSON.stringify(pending));
if (pending.options[0].label !== '开始写第 7 节正文（推荐）') throw new Error(JSON.stringify(pending.options));
if (!pending.free_text_enabled) throw new Error('free text must remain enabled');
NODE
    [ "$status" -eq 0 ]
}

@test "short rework menu exposes pending section units and advances them sequentially" {
    run node - "$REPO/scripts/lib/workflow-action-renderer.js" <<'NODE'
const { buildShortRevisionQueueProgress } = require(process.argv[2]);
const task={current_stage:'draft_first_section',feedback_revision_queue:{status:'running',current_section_index:1,items:[1,2,3,8,9].map(section_index=>({section_index,status:'pending'}))}};
const titles=[1,2,3,8,9].map(section_index=>({section_index,title:`标题${section_index}`}));
const progress=buildShortRevisionQueueProgress(task,titles);
if(!progress || progress.total!==5 || progress.completed!==0 || progress.remaining!==5) throw new Error(JSON.stringify(progress));
for(const expected of ['已完成 0/5','第 1 节《标题1》：写作提要已通过，待写正文','第 2 节《标题2》：待回炉','当前节采用后，工作流自动进入下一项']) {
  if(!progress.text.includes(expected)) throw new Error(progress.text);
}
console.log('ok');
NODE
    [ "$status" -eq 0 ]
}

@test "short rework queue exposes grouped phases and chat revision exit" {
  run node - "$REPO/scripts/lib/workflow-action-renderer.js" <<'NODE'
const { buildShortDraftPendingAction, buildShortRevisionQueueProgress, buildShortRevisionTaskOverview } = require(process.argv[2]);
const task={workflow_id:'wf-short',workflow_type:'short_write',current_stage:'draft_section',scope:'第1节',feedback_revision_queue:{status:'running',current_section_index:1,items:[1,2,3,4,5,8,9].map(section_index=>({section_index,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}))}};
const titles=[1,2,3,4,5,8,9].map(section_index=>({section_index,title:`标题${section_index}`}));
const progress=buildShortRevisionQueueProgress(task,titles);
const pending=buildShortDraftPendingAction({stage_id:'draft_section'},task);
const overview=buildShortRevisionTaskOverview(task,titles,9);
if(progress.groups.length!==2) throw new Error(JSON.stringify(progress));
if(progress.groups[0].range_label!=='第 1-5 节') throw new Error(JSON.stringify(progress.groups));
if(progress.groups[1].range_label!=='第 8-9 节') throw new Error(JSON.stringify(progress.groups));
if(!progress.text.includes('阶段 1') || !progress.text.includes('逐节任务')) throw new Error(progress.text);
if(pending.options[0].action_id!=='recheck_existing_section'||pending.options[0].target_stage!=='section_machine_gate') throw new Error(JSON.stringify(pending));
if(pending.options[1].action_id!=='request_revision_input') throw new Error(JSON.stringify(pending));
if(pending.options[2].action_id!=='inspect_current_state') throw new Error(JSON.stringify(pending));
if(overview.current_subtask.label!=='复检并局部回炉第 1 节《标题1》') throw new Error(JSON.stringify(overview.current_subtask));
if(overview.preserved_sections.join(',')!=='6,7') throw new Error(JSON.stringify(overview));
if(!overview.text.includes('全篇收束：重新合稿 → 全篇审阅 → 去 AI 味 → 终检')) throw new Error(overview.text);
console.log('ok');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ok"* ]]
}

@test "short revision groups advance with the accepted section" {
  run node - "$REPO/scripts/lib/short-feedback-revision-queue.js" <<'NODE'
const { initializeShortFeedbackRevisionQueue, acceptShortFeedbackRevisionSection } = require(process.argv[2]);
const task={workflow_type:'short_write',pending_feedback:{feedback_id:'feedback-1'}};
const result={stage_id:'feedback_apply_patch',step_status:'completed',affected_sections:[1,2,5],revision_groups:[
  {group_id:'opening',sections:[1,2],goal:'建立冲突'},
  {group_id:'ending',sections:[5],goal:'兑现结局'},
]};
const created=initializeShortFeedbackRevisionQueue(task,result,{impact_level:'planning',affected_sections:[1,2,5],revision_groups:result.revision_groups});
if(created.status!=='feedback_revision_queue_created') throw new Error(JSON.stringify(created));
if(task.feedback_revision_queue.groups.length!==2) throw new Error(JSON.stringify(task.feedback_revision_queue));
task.feedback_revision_queue.interruption={status:'feedback_analysis_pending',section_index:1};
const advanced=acceptShortFeedbackRevisionSection(task,1,{section_commit_id:'commit-1'});
if(advanced.next_section!==2) throw new Error(JSON.stringify(advanced));
if(task.feedback_revision_queue.interruption!==null) throw new Error('feedback interruption not cleared');
if(task.feedback_revision_queue.groups[0].status!=='running' || task.feedback_revision_queue.groups[0].completed_sections[0]!==1) throw new Error(JSON.stringify(task.feedback_revision_queue.groups));
task.pending_feedback={feedback_id:'feedback-2'};
const merged=initializeShortFeedbackRevisionQueue(task,{stage_id:'feedback_apply_patch',step_status:'completed',affected_sections:[2]},{impact_level:'current_brief',affected_sections:[2]});
if(merged.status!=='feedback_revision_queue_merged') throw new Error(JSON.stringify(merged));
if(task.feedback_revision_queue.current_section_index!==2) throw new Error(JSON.stringify(task.feedback_revision_queue));
if(task.feedback_revision_queue.items.find(item=>item.section_index===1).status!=='accepted') throw new Error('accepted checkpoint lost');
if(!task.feedback_revision_queue.items.some(item=>item.section_index===5&&item.status==='pending')) throw new Error('future queue lost');
console.log('ok');
NODE
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "activation repairs a short revision task that incorrectly jumped to whole-story assembly" {
  run node - "$SCRIPT" "$TMP_DIR/revision-route-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
let run=cp.spawnSync(process.execPath,[script,'create','--workflow-type','short_write','--project-root',root,'--user-goal','整篇回炉','--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const taskFile=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
task.current_stage='full_story_assembly';task.current_step='full_story_assembly';task.scope='全篇';task.status='paused_after_step';
task.stage_execution={status:'contract_blocked',stage_id:'full_story_assembly'};
task.feedback_revision_queue={status:'running',current_section_index:2,affected_sections:[1,2,8,9],items:[
  {section_index:1,status:'accepted',brief_status:'rebuilt_and_used',prose_status:'rechecked_and_accepted'},
  {section_index:2,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'},
  {section_index:8,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'},
  {section_index:9,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'},
]};
fs.mkdirSync(path.join(root,'追踪/private-short-extension'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({accepted_sections:[1,2,3,4,5,6,7,8,9].map(section_index=>({section_index}))},null,2)+'\n');
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
run=cp.spawnSync(process.execPath,[script,'activate','--workflow-id',task.workflow_id,'--project-root',root,'--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const out=JSON.parse(run.stdout);
if(out.task.current_stage!=='next_section_brief'||out.task.scope!=='第2节'||out.task.stage_execution!==null) throw new Error(run.stdout);
const saved=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(saved.current_stage!=='next_section_brief'||saved.short_project_resume.reason!=='active_feedback_revision_queue_has_priority') throw new Error(JSON.stringify(saved));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "next-candidates and resolve-action share the grouped queue menu" {
  run node - "$SCRIPT" "$TMP_DIR/queue-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const create=cp.spawnSync(process.execPath,[script,'create','--workflow-type','short_write','--project-root',root,'--user-goal','整篇回炉','--json'],{encoding:'utf8'});
if(create.status!==0) throw new Error(create.stdout||create.stderr);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const taskFile=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
task.scope='第1节';task.current_stage='draft_section';task.current_step='draft_section';
task.feedback_revision_queue={status:'running',current_section_index:1,items:[1,2,5].map(section_index=>({section_index,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}))};
task.pending_action={id:'pa-draft',question:'第1节写作提要已通过',options:[{number:1,action_id:'continue_next_stage',label:'开始写第1节正文',target_stage:'draft_section'},{number:2,action_id:'pause',label:'暂停'}],free_text_enabled:true};
fs.writeFileSync(path.join(root,'写作Brief_第001节.md'),'# 写作 Brief：第001节《测试标题》\n\n## 承接\n\n- 接住上节钩子。\n\n## 目标与阻力\n\n- 主角要拿到账本，但家人阻拦。\n\n## 因果动作\n\n- 主角拒绝签字，随后失去权限。\n\n## 人物与视角锁\n\n- 第一人称，不越过主角认知。\n\n## 禁写项\n\n- 不提前揭示终局。\n\n## 节尾钩子\n\n- 账本日期对不上。\n');
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const next=cp.spawnSync(process.execPath,[script,'next-candidates','--project-root',root,'--json'],{encoding:'utf8'});
if(next.status!==0) throw new Error(next.stdout||next.stderr);
const menu=JSON.parse(next.stdout);
if(!menu.visible_response.work_queue || menu.visible_response.options[0].action_id!=='recheck_existing_section' || menu.visible_response.options[0].target_stage!=='section_machine_gate' || menu.visible_response.options[1].action_id!=='request_revision_input') throw new Error(next.stdout);
if(!String(menu.visible_response.options[0].execution_command||'').includes('--bind-current')) throw new Error(next.stdout);
if(String(menu.visible_response.options[0].execution_command||'').includes('--visible-choice-hash')) throw new Error(next.stdout);
const pending=menu.pending_action;
const resolve=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','2','--bind-current','--json'],{encoding:'utf8'});
if(resolve.status!==0) throw new Error(resolve.stdout||resolve.stderr);
const result=JSON.parse(resolve.stdout);
if(result.status!=='revision_input_requested') throw new Error(resolve.stdout);
if(result.revision_scope!=='current_section_only'||result.section_index!==1) throw new Error(resolve.stdout);
if(!String((result.visible_response||{}).text||'').includes('第 1 节当前回炉要求')) throw new Error(resolve.stdout);
if(!String((result.visible_response||{}).text||'').includes('主角要拿到账本')) throw new Error(resolve.stdout);
const feedback=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','母亲的语气再克制一些','--json'],{encoding:'utf8'});
if(feedback.status!==0) throw new Error(feedback.stdout||feedback.stderr);
const saved=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const item=(((saved.pending_feedback||{}).items)||[])[0]||{};
if(item.section_index!==1||item.scope_mode!=='current_section_only'||item.impact_level_hint!=='current_brief') throw new Error(JSON.stringify(saved.pending_feedback));
console.log('ok');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ok"* ]]
}

@test "short revision brief menu presents the user task instead of the internal brief step" {
  run node - "$SCRIPT" "$TMP_DIR/revision-brief-menu" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
let run=cp.spawnSync(process.execPath,[script,'create','--workflow-type','short_write','--project-root',root,'--user-goal','整篇回炉','--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const file=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='next_section_brief';task.current_step='next_section_brief';task.scope='第2节';
task.feedback_revision_queue={status:'running',current_section_index:2,items:[{section_index:1,status:'accepted'},{section_index:2,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}]};
task.pending_action={id:'pa-next-section-brief',question:'请选择下一步',options:[{number:1,action_id:'continue_next_stage',label:'继续生成下一节写作 Brief',target_stage:'next_section_brief'},{number:2,action_id:'pause',label:'暂停'}],free_text_enabled:true};
fs.mkdirSync(path.join(root,'追踪/private-short-extension'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({accepted_sections:[{section_index:1}]})+'\n');
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
run=cp.spawnSync(process.execPath,[script,'next-candidates','--project-root',root,'--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const out=JSON.parse(run.stdout);
if(out.visible_response.options[0].label!=='准备并回炉第 2 节（推荐）') throw new Error(run.stdout);
if(out.visible_response.options[1].label!=='调整第 2 节的回炉要求') throw new Error(run.stdout);
if(out.pending_action.question!=='第 2 节待准备并回炉') throw new Error(run.stdout);
const pending=out.pending_action;
run=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',pending.pending_action_id,'--visible-choice-hash',pending.visible_choice_hash,'--state-version',String(pending.state_version),'--book-root','.', '--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const started=JSON.parse(run.stdout);
if(!String(started.stage_execution.expected_result_packet||'').endsWith('next_section_brief.section-002.result.json')) throw new Error(run.stdout);
run=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:revision','--takeover','--confirm','--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const reconciled=JSON.parse(run.stdout);
if(reconciled.current_stage!=='next_section_brief') throw new Error(run.stdout);
const current=JSON.parse(fs.readFileSync(file,'utf8'));
if(current.current_stage!=='next_section_brief'||current.scope!=='第2节'||!String(current.stage_execution.expected_result_packet||'').endsWith('next_section_brief.section-002.result.json')) throw new Error(JSON.stringify(current));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "activating a whole-story revision opens task overview without starting its section" {
  run node - "$SCRIPT" "$TMP_DIR/overview-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const create=cp.spawnSync(process.execPath,[script,'create','--workflow-type','short_write','--project-root',root,'--user-goal','整篇回炉','--json'],{encoding:'utf8'});
if(create.status!==0) throw new Error(create.stdout||create.stderr);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const taskFile=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
task.current_stage='draft_first_section';task.current_step='draft_first_section';task.scope='第1节';
task.feedback_revision_queue={status:'running',current_section_index:1,items:[1,2,3,4,5,8,9].map(section_index=>({section_index,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}))};
task.stage_execution={status:'paused',stop_reason:'focus_switched'};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
fs.mkdirSync(path.join(root,'追踪/private-short-extension'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({working_title:'测试果汁',planned_sections:9}));
fs.writeFileSync(path.join(root,'追踪/private-short-extension/section-title-lock.json'),JSON.stringify({sections:Array.from({length:9},(_,i)=>({section_index:i+1,title:`标题${i+1}`}))}));
const activate=cp.spawnSync(process.execPath,[script,'activate','--project-root',root,'--workflow-id',task.workflow_id,'--compact','--json'],{encoding:'utf8'});
if(activate.status!==0) throw new Error(activate.stdout||activate.stderr);
const out=JSON.parse(activate.stdout);
if(out.status!=='activated'||(out.stage_execution&&out.stage_execution.status==='running')||((out.task||{}).stage_execution||{}).status==='running') throw new Error(activate.stdout);
if(out.task_overview.current_subtask.label!=='复检并局部回炉第 1 节《标题1》') throw new Error(activate.stdout);
if(!out.visible_response.text.includes('第 6-7 节：沿用现稿')) throw new Error(out.visible_response.text);
if(out.visible_response.options[0].action_id!=='open_current_subtask') throw new Error(activate.stdout);
console.log('ok');
NODE
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "portable dot book root resolves against the moved project when selecting a menu" {
    mkdir -p "$TMP_DIR/moved-book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/moved-book" --user-goal "新建长篇" --json >/dev/null
    node - "$SCRIPT" "$TMP_DIR/moved-book" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const script=process.argv[2],root=process.argv[3];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
const pending=task.pending_action;
if(task.book_root!=='.'||pending.book_root!=='.') throw new Error(JSON.stringify({task:task.book_root,pending:pending.book_root}));
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1',
  '--pending-action-id',pending.pending_action_id,'--visible-choice-hash',pending.visible_choice_hash,
  '--state-version',String(pending.state_version),'--book-root','.', '--json'],{encoding:'utf8'});
if(out.status!==0) throw new Error(out.stdout||out.stderr);
const result=JSON.parse(out.stdout);
if(result.status!=='stage_started') throw new Error(out.stdout);
NODE
}

focused_task_file() {
    node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(process.argv[1]))" "$1"
}

assert_pointer_matches_task() {
    node - "$1" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
if(Object.keys(pointer).sort().join(',')!=='focused_at,schemaVersion,state_version,task_dir,workflow_id') throw new Error(JSON.stringify(pointer));
if(pointer.workflow_id!==task.workflow_id||pointer.task_dir!==task.task_dir||pointer.state_version!==task.state_version) throw new Error(JSON.stringify({pointer,task}));
NODE
}

migrate_legacy_fixture() {
    printf '%s\n' 'source=worldwonderer/oh-story-claudecode' > "$1/.story-deployed"
    node "$REPO/scripts/task-family-migrate.js" --project-root "$1" --source oh-story --write --confirm --json >/dev/null
}

teardown() {
    rm -rf "$TMP_DIR"
}

resolve_action() {
    node - "$SCRIPT" "$1" "$2" <<'NODE'
const fs=require('fs'), path=require('path'), cp=require('child_process');
const script=process.argv[2], root=process.argv[3], input=process.argv[4];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const pending=task.pending_action||{};
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input',input,'--pending-action-id',String(pending.id||''),'--visible-choice-hash',String(pending.visible_choice_hash||''),'--state-version',String(task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
}

apply_long_write_v2_result() {
    node - "$SCRIPT" "$1" "${2:-}" "${3:-completed}" "${4-pass}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" <<'NODE'
const fs=require('fs'), path=require('path'), cp=require('child_process');
const [script,root,ownerOverride,stepStatus,verificationResult,nextStage,corruptField,reviewResult,declaredFile]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find(node=>node.id===task.current_stage);
if(!lifecycleNode) throw new Error(`missing lifecycle node ${task.current_stage}`);
const failedResult=['blocked','failed'].includes(String(stepStatus||'').toLowerCase())||/(?:fail|reject|block)/i.test(String(verificationResult||''));
const result={
  workflow_id:task.workflow_id,
  workflow_type:'long_write',
  stage_id:task.current_stage,
  step_id:task.current_step,
  owner_module:ownerOverride||lifecycleNode.owner_module,
  lifecycle_node:lifecycleNode.id,
  asset_target:lifecycleNode.asset_target,
  review_requirement:lifecycleNode.review_requirement,
  step_status:stepStatus,
  outputs:[],
  changed_files:declaredFile?[declaredFile]:[],
  evidence:[],
  verification_result:verificationResult,
  checkpoint_state:{stage:task.current_stage},
  output_health_result:'pass',
  memory_read_receipt:((task.stage_execution||{}).memory_context||{}).memory_read_receipt||null,
  asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},
  review_decision:lifecycleNode.review_requirement.required?'accepted':'not_applicable',
  downstream_effects:[],
  lifecycle_transition_request:failedResult
    ? {action:'return',target:String((lifecycleNode.review_requirement||{}).failure_return||lifecycleNode.id)}
    : {action:'advance',target:lifecycleNode.id},
  result_write_set:declaredFile?[declaredFile]:[]
};
if(reviewResult) result.review_result=reviewResult;
if(nextStage) result.next_stage_id=nextStage;
if(corruptField==='lifecycle_node') result.lifecycle_node='prose';
if(corruptField==='asset_target') result.asset_target={kind:'chapter',id:'wrong-asset'};
if(corruptField==='review_requirement') result.review_requirement={required:true,failure_return:'prose'};
if(['asset_revision','review_decision','downstream_effects','lifecycle_transition_request','result_write_set'].includes(corruptField)) delete result[corruptField];
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify(result,null,2));
const out=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',packet,'--json'],{encoding:'utf8'});
if(out.status) process.stderr.write(out.stdout||'');
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
}

advance_long_write_stage() {
    stage_status="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]); process.stdout.write(String((t.stage_execution||{}).status||''))" "$1")"
    if [ "$stage_status" != "running" ]; then
        resolve_action "$1" 1 >/dev/null
    fi
    apply_long_write_v2_result "$1" "" completed pass "" "" "" "${2:-}" >/dev/null
}

prepare_detail_outline_review() {
    local book="$1"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    for _ in 1 2 3 4 5 6; do
        advance_long_write_stage "$book"
    done
    mkdir -p "$book/大纲/第1卷"
    printf '%s\n' '当前细纲' > "$book/大纲/第1卷/细纲_第001章.md"
    advance_long_write_stage "$book" "大纲/第1卷/细纲_第001章.md"
    stage_status="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]); process.stdout.write(String((t.stage_execution||{}).status||''))" "$book")"
    if [ "$stage_status" != "running" ]; then
        resolve_action "$book" 1 >/dev/null
    fi
}

apply_detail_outline_quality_result() {
    node - "$SCRIPT" "$1" "$2" "${3:-}" "${4:-}" <<'NODE'
const crypto=require('crypto'), fs=require('fs'), path=require('path'), cp=require('child_process');
const [script,root,qualityStatus,projectionMode,identityMode]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find(node=>node.id===task.current_stage);
const outlinePath='大纲/第1卷/细纲_第001章.md';
const outlineFile=path.join(root,outlinePath);
const outlineSha256=qualityStatus==='identity_missing'?'':crypto.createHash('sha256').update(fs.readFileSync(outlineFile)).digest('hex');
const actualStatus=qualityStatus==='identity_missing'?'pass':qualityStatus;
const quality={
  status:actualStatus,
  workflow_id:task.workflow_id,
  stage_id:task.current_stage,
  outline_path:outlinePath,
  outline_sha256:outlineSha256,
  activated_dimensions:actualStatus==='revise'?['C7_payoff_debt']:[],
  findings:actualStatus==='revise'
    ?[{dimension:'C7_payoff_debt',severity:'blocking',message:'反击没有产生可见后果'}]
    :actualStatus==='pass_with_advisory'
      ?[{dimension:'B2_visible_evidence',severity:'advisory',message:'建议补一处可见证据'}]
      :[],
  contract_projection:projectionMode==='nonempty'?[{chapter_id:'001'}]:[],
  memory_projection:[],
  execution:{mode:'fresh',reused_result:false,semantic_review:{status:'accepted',reviewer:'main-session',findings:[],findings_sha256:crypto.createHash('sha256').update('[]').digest('hex'),finding_count:0}}
};
const result={
  workflow_id:task.workflow_id,
  workflow_type:'long_write',
  stage_id:task.current_stage,
  step_id:task.current_step,
  owner_module:lifecycleNode.owner_module,
  lifecycle_node:lifecycleNode.id,
  asset_target:lifecycleNode.asset_target,
  review_requirement:lifecycleNode.review_requirement,
  step_status:'completed',
  outputs:{detail_outline_quality:quality},
  changed_files:[],
  evidence:[{type:'detail_outline',path:identityMode==='evidence_mismatch'?'大纲/第1卷/细纲_第002章.md':outlinePath,outline_sha256:outlineSha256}],
  verification_result:'pass',
  checkpoint_state:{stage_id:task.current_stage,outline_path:outlinePath},
  output_health_result:'pass',
  asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},
  review_decision:'accepted',
  downstream_effects:[],
  lifecycle_transition_request:{action:'advance',target:lifecycleNode.id},
  result_write_set:[]
};
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify(result,null,2));
const out=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',packet,'--json'],{encoding:'utf8'});
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
}

attach_long_lifecycle_graph() {
    node - "$SCRIPT" "$1" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [script,root]=process.argv.slice(2);
const taskFile=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const command=cp.spawnSync(process.execPath,[script,'templates','--no-private-registry','--json'],{encoding:'utf8'});
if(command.status!==0) throw new Error(command.stderr||command.stdout);
const template=JSON.parse(command.stdout).templates.find(item=>item.workflow_type==='long_write');
const current=template.stages.find(stage=>stage.stage_id===task.current_stage);
const completed=(task.machine&&task.machine.completed_stages)||[];
const reviewResults={};
for(const stage of template.stages) {
  if(completed.includes(stage.stage_id)&&stage.review_requirement.required) {
    reviewResults[stage.stage_id]={status:'accepted',verification_result:'pass',result_packet_path:'fixture://accepted'};
  }
}
task.lifecycle_graph={
  version:'1.0.0',
  current_node:task.current_stage,
  asset_target:current.asset_target,
  completed_nodes:completed.slice(),
  invalidated_nodes:[],
  review_results:reviewResults,
  last_transition_validation:null,
  nodes:template.stages.map((stage,order)=>({
    id:stage.stage_id,
    order,
    owner_module:stage.owner_module,
    asset_target:stage.asset_target,
    review_requirement:stage.review_requirement,
    status:completed.includes(stage.stage_id)?'accepted':'missing'
  }))
};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2));
NODE
}

@test "workflow state store creates distinct millisecond workflow ids" {
    node - "$REPO/scripts/lib/workflow-state-store.js" <<'NODE'
const { createWorkflowId } = require(process.argv[2]);
const now = new Date('2026-07-11T01:02:03.456Z');
const first = createWorkflowId('short_write', now);
const second = createWorkflowId('short_write', now);
if (first === second) throw new Error('same-millisecond workflow ids collided');
if (!/^wf-20260711010203456-short_write-[0-9a-f]{8}$/.test(first)) {
  throw new Error(`workflow id does not retain milliseconds and random suffix: ${first}`);
}
NODE
}

@test "state machine attaches a repeated objective to its existing task family" {
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --scope "第1卷第001章" --user-goal "继续写第1章" --json > "$TMP_DIR/family-first.json"
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --scope "第1卷第001章" --user-goal "继续写第1章" --json > "$TMP_DIR/family-second.json"

    node - "$TMP_DIR/family-first.json" "$TMP_DIR/family-second.json" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');const path=require('path');const [firstFile,secondFile,root]=process.argv.slice(2);
const first=JSON.parse(fs.readFileSync(firstFile,'utf8'));const second=JSON.parse(fs.readFileSync(secondFile,'utf8'));
if(second.status!=='attached_existing_family') throw new Error(JSON.stringify(second));
if(first.task.workflow_id!==second.task.workflow_id || first.task.task_family_id!==second.task.task_family_id) throw new Error(JSON.stringify({first,second}));
const family=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/families',first.task.task_family_id,'family.json'),'utf8'));
if(family.branches.length!==1 || family.head_workflow_id!==first.task.workflow_id) throw new Error(JSON.stringify(family));
NODE
}

@test "explicit replan creates a new head branch and rejects old branch result projection" {
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --scope "第1卷第001章" --user-goal "继续写第1章" --json > "$TMP_DIR/branch-first.json"
    node "$SCRIPT" switch-intent --workflow-type long_write --project-root "$TMP_DIR/book" --scope "第1卷第001章" --user-goal "继续写第1章" --reason "重新规划第1章" --json > "$TMP_DIR/branch-second.json"

    node - "$TMP_DIR/branch-first.json" "$TMP_DIR/branch-second.json" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');const path=require('path');const [firstFile,secondFile,root]=process.argv.slice(2);
const first=JSON.parse(fs.readFileSync(firstFile,'utf8'));const second=JSON.parse(fs.readFileSync(secondFile,'utf8'));
if(second.status!=='branched'||first.task.task_family_id!==second.task.task_family_id) throw new Error(JSON.stringify({first,second}));
const family=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/families',first.task.task_family_id,'family.json'),'utf8'));
if(family.branches.length!==2||family.head_workflow_id!==second.task.workflow_id) throw new Error(JSON.stringify(family));
NODE

    first_id="$(node -e "console.log(require('$TMP_DIR/branch-first.json').task.workflow_id)")"
    printf '{"workflow_id":"%s"}\n' "$first_id" > "$TMP_DIR/old-branch-result.json"
    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/old-branch-result.json" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_non_head_branch_projection'* ]]
}

write_long_commit_task() {
    workflow_id="$1"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<JSON
{
  "workflow_id": "$workflow_id",
  "workflow_type": "long_write",
  "scope": "$workflow_id",
  "user_goal": "验证 $workflow_id 章节提交分支",
  "completion_policy": "stage_then_confirm",
  "current_stage": "chapter_commit",
  "current_step": "chapter_commit",
  "status": "running",
  "machine": {
    "completed_stages": ["positioning","story_bible","master_outline","master_outline_review","volume_outline","volume_outline_review","stage_detail_outline","detail_outline_review","chapter_brief","brief_review","prose","prose_acceptance"],
    "remaining_stages": ["chapter_commit","milestone_review","volume_acceptance","book_acceptance"]
  }
}
JSON
    attach_long_lifecycle_graph "$TMP_DIR/book"
    migrate_legacy_fixture "$TMP_DIR/book"
    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.book_root='/legacy-host/old-book';
task.runtime_guard=task.runtime_guard||{};
task.runtime_guard.checkpoint_policy={...(task.runtime_guard.checkpoint_policy||{}),project_root:'/legacy-host/old-book'};
task.pending_action={...(task.pending_action||{}),book_root:'/legacy-host/old-book'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
}

write_accepted_commit() {
    mkdir -p "$TMP_DIR/book/正文/第1卷"
    printf '# 第一章\n可信正文。\n' > "$TMP_DIR/book/正文/第1卷/第001章_起点.md"
    node - "$TMP_DIR/book" <<'NODE'
const crypto=require('crypto');
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const target='正文/第1卷/第001章_起点.md';
const hash=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,target))).digest('hex')}`;
const commit={schemaVersion:'1.0.0',commit_id:'chapter-v12345678-001-abcdef1234',status:'accepted',volume:'第1卷',chapter:1,artifacts:[{role:'chapter_prose',target,after_hash:hash}]};
fs.writeFileSync(path.join(root,'追踪/story-system/commits/chapter-v12345678-001-abcdef1234.json'),JSON.stringify(commit));
NODE
}

write_transactional_commit_result() {
    workflow_id="$1"
    projection_status="$2"
    projection_debt="$3"
    cat > "$TMP_DIR/result.json" <<JSON
{
  "workflow_id": "$workflow_id",
  "workflow_type": "long_write",
  "stage_id": "chapter_commit",
  "step_id": "chapter_commit",
  "step_status": "completed",
  "verification_result": "pass",
  "changed_files": ["正文/第1卷/第001章_起点.md"],
  "chapter_commit": {
    "mode": "transactional",
    "accepted_commit_id": "chapter-v12345678-001-abcdef1234",
    "commit_file": "追踪/story-system/commits/chapter-v12345678-001-abcdef1234.json",
    "projection_status": "$projection_status",
    "projection_debt": $projection_debt,
    "staged_artifacts": ["追踪/story-system/work/$workflow_id/正文.md"]
  }
}
JSON
}

@test "workflow state machine lists public templates without private overlay" {
    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/out.json"

    grep -q '"schemaVersion": "1.0.0"' "$TMP_DIR/out.json"
    grep -q '"templateCount": 15' "$TMP_DIR/out.json"
    grep -q '"privateRegistryCount": 0' "$TMP_DIR/out.json"
    for type in long_startup short_startup project_setup long_write short_write review_repair short_review long_analyze download_import deslop setup_update long_scan short_scan short_analyze cover; do
        grep -q "\"workflow_type\": \"$type\"" "$TMP_DIR/out.json"
    done
    grep -q '"owner_module": "story-short-write"' "$TMP_DIR/out.json"
    grep -q '"owner_module": "story-import"' "$TMP_DIR/out.json"
}

@test "long write advances through layered reviews before prose" {
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --user-goal "开一本新书" --json > "$TMP_DIR/task.json"

    node - "$TMP_DIR/task.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const graph = out.task.lifecycle_graph;
if (!graph) throw new Error('missing lifecycle_graph');
const stages = graph.nodes.map((node) => node.id);
for (const id of ['master_outline_review', 'volume_outline_review', 'detail_outline_review', 'brief_review', 'milestone_review', 'volume_acceptance']) {
  if (!stages.includes(id)) throw new Error(id);
}
if (out.task.machine.remaining_stages.indexOf('prose') < out.task.machine.remaining_stages.indexOf('brief_review')) {
  throw new Error('prose precedes brief review');
}
if (graph.current_node !== 'positioning') throw new Error(`wrong current node: ${graph.current_node}`);
if (JSON.stringify(graph.asset_target) !== JSON.stringify({ kind: 'book', id: 'current-book' })) {
  throw new Error(`wrong initial asset target: ${JSON.stringify(graph.asset_target)}`);
}
if (graph.completed_nodes.length || graph.invalidated_nodes.length) throw new Error('new lifecycle must start clean');
NODE
}

@test "long write lifecycle stages expose module asset and review contracts" {
    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/templates.json"

    node - "$TMP_DIR/templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const long = data.templates.find((item) => item.workflow_type === 'long_write');
const stages = Object.fromEntries(long.stages.map((item) => [item.stage_id, item]));
for (const id of ['master_outline_review', 'volume_outline_review', 'detail_outline_review', 'brief_review', 'prose_acceptance', 'milestone_review', 'volume_acceptance', 'book_acceptance']) {
  const stage = stages[id];
  if (!stage) throw new Error(`missing ${id}`);
  if (stage.owner_module !== 'story-review') throw new Error(`${id} owner: ${stage.owner_module}`);
  if (!stage.review_requirement || stage.review_requirement.required !== true) throw new Error(`${id} missing review requirement`);
  if (!stage.review_requirement.failure_return) throw new Error(`${id} missing failure return`);
}
for (const id of ['positioning', 'story_bible', 'master_outline', 'volume_outline', 'stage_detail_outline', 'chapter_brief', 'prose']) {
  if (stages[id].owner_module !== 'story-long-write') throw new Error(`${id} owner: ${stages[id].owner_module}`);
}
if (stages.chapter_commit.owner_module !== 'story-workflow') throw new Error(`chapter_commit owner: ${stages.chapter_commit.owner_module}`);
for (const stage of long.stages) {
  if (stage.lifecycle_node !== stage.stage_id) throw new Error(`${stage.stage_id} lifecycle_node mismatch`);
  if (!stage.asset_target || !stage.asset_target.kind || !stage.asset_target.id) throw new Error(`${stage.stage_id} missing asset_target`);
}
NODE
}

@test "long write v2 results bind to the active lifecycle stage and reviews require explicit acceptance" {
    wrong_owner_book="$TMP_DIR/wrong-owner-book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$wrong_owner_book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$wrong_owner_book" 1 >/dev/null

    node - "$wrong_owner_book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const node=task.lifecycle_graph.nodes.find(item=>item.id===task.current_stage);
for(const field of ['owner_module','lifecycle_node','asset_target','review_requirement']) {
  const expected=field==='lifecycle_node'?node.id:node[field];
  if(JSON.stringify(task.stage_execution[field])!==JSON.stringify(expected)) throw new Error(`${field}: ${JSON.stringify(task.stage_execution)}`);
}
NODE

    run apply_long_write_v2_result "$wrong_owner_book" story-review completed pass
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_result_contract_mismatch'* ]]
    node - "$wrong_owner_book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
if(task.current_stage!=='positioning') throw new Error(`wrong owner advanced to ${task.current_stage}`);
NODE

    for field in lifecycle_node asset_target review_requirement; do
        run apply_long_write_v2_result "$wrong_owner_book" "" completed pass "" "$field"
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_result_contract_mismatch'* ]]
    done

    review_book="$TMP_DIR/review-book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$review_book" --user-goal "开一本新书" --json >/dev/null
    advance_long_write_stage "$review_book"
    advance_long_write_stage "$review_book"
    advance_long_write_stage "$review_book"
    resolve_action "$review_book" 1 >/dev/null

    run apply_long_write_v2_result "$review_book" "" skipped pass
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_review_acceptance_required'* ]]

    run apply_long_write_v2_result "$review_book" "" completed ""
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_review_acceptance_required'* ]]

    run apply_long_write_v2_result "$review_book" "" completed indeterminate
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_review_acceptance_required'* ]]

    run apply_long_write_v2_result "$review_book" "" completed indeterminate "" "" accepted
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_review_acceptance_required'* ]]

    apply_long_write_v2_result "$review_book" "" completed accepted >/dev/null
    node - "$review_book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
if(task.current_stage!=='volume_outline') throw new Error(`accepted review did not advance: ${task.current_stage}`);
NODE
}

@test "long write v2 results require lifecycle outcome and write declaration fields" {
    book="$TMP_DIR/required-result-fields"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$book" 1 >/dev/null

    for field in asset_revision review_decision downstream_effects lifecycle_transition_request result_write_set; do
        run apply_long_write_v2_result "$book" "" completed pass "" "$field"
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_result_packet_incomplete'* ]]
        [[ "$output" == *"$field"* ]]
    done
}

@test "long write result write set stays inside stage authorization and changed file declaration" {
    for mode in unauthorized undeclared; do
        book="$TMP_DIR/write-set-$mode"
        node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
        resolve_action "$book" 1 >/dev/null
        node - "$book" "$mode" <<'NODE'
const fs=require('fs'),path=require('path');
const [root,mode]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=task.lifecycle_graph.nodes.find(node=>node.id===task.current_stage);
const authorizedFile='设定/定位.md';
const changedFile=mode==='unauthorized'?'正文/越权.md':authorizedFile;
const result={
  workflow_id:task.workflow_id,workflow_type:task.workflow_type,stage_id:task.current_stage,step_id:task.current_step,
  owner_module:lifecycleNode.owner_module,lifecycle_node:lifecycleNode.id,asset_target:lifecycleNode.asset_target,
  review_requirement:lifecycleNode.review_requirement,step_status:'completed',outputs:[],evidence:[],verification_result:'pass',
  checkpoint_state:{stage:task.current_stage},output_health_result:'pass',asset_revision:{status:'verified'},
  review_decision:'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance'},
  result_write_set:mode==='undeclared'?[]:[changedFile],changed_files:[changedFile]
};
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify(result,null,2));
NODE
        packet="$(node -e "const path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask('$book'); console.log(path.resolve('$book',task.stage_execution.expected_result_packet))")"
        run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_result_write_set_violation'* ]]
    done
}

@test "long write apply result compares declarations with the actual stage file changes" {
    for mode in omitted phantom unauthorized; do
        book="$TMP_DIR/actual-write-set-$mode"
        node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
        resolve_action "$book" 1 >/dev/null
        node - "$book" "$mode" <<'NODE'
const fs=require('fs'),path=require('path');
const [root,mode]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
if(!task.stage_execution.write_snapshot) throw new Error('stage execution did not persist a write snapshot');
const lifecycleNode=task.lifecycle_graph.nodes.find(node=>node.id===task.current_stage);
const authorizedFile='设定/定位.md';
if(mode!=='phantom') {
  fs.mkdirSync(path.join(root,'设定'),{recursive:true});
  fs.writeFileSync(path.join(root,authorizedFile),'实际阶段写入\n');
}

if(mode==='unauthorized') {
  fs.mkdirSync(path.join(root,'正文'),{recursive:true});
  fs.writeFileSync(path.join(root,'正文/越权.md'),'越权写入\n');
}

const declared=mode==='omitted'?[]:[authorizedFile];
const result={
  workflow_id:task.workflow_id,workflow_type:task.workflow_type,stage_id:task.current_stage,step_id:task.current_step,
  owner_module:lifecycleNode.owner_module,lifecycle_node:lifecycleNode.id,asset_target:lifecycleNode.asset_target,
  review_requirement:lifecycleNode.review_requirement,step_status:'completed',outputs:[],evidence:[],verification_result:'pass',
  checkpoint_state:{stage:task.current_stage},output_health_result:'pass',asset_revision:{status:'verified'},
  review_decision:'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance'},
  result_write_set:declared,changed_files:declared
};
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify(result,null,2));
NODE
        packet="$(node -e "const path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask('$book'); console.log(path.resolve('$book',task.stage_execution.expected_result_packet))")"
        run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_result_write_set_violation'* ]]
        [[ "$output" == *'actual_changed_files'* ]]
    done
}

@test "long write ignores its expected result receipt in host write declarations" {
    book="$TMP_DIR/receipt-write-set"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$book" 1 >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const node=task.lifecycle_graph.nodes.find(item=>item.id===task.current_stage);
const artifact='设定/定位.md';
fs.mkdirSync(path.join(root,'设定'),{recursive:true});
fs.writeFileSync(path.join(root,artifact),'定位资产\n');
const receipt=task.stage_execution.expected_result_packet;
const result={workflow_id:task.workflow_id,workflow_type:task.workflow_type,stage_id:task.current_stage,step_id:task.current_step,
 owner_module:node.owner_module,lifecycle_node:node.id,asset_target:node.asset_target,review_requirement:node.review_requirement,
 step_status:'completed',outputs:[],changed_files:[artifact,receipt],evidence:[],verification_result:'pass',checkpoint_state:{stage:task.current_stage},output_health_result:'pass',
 asset_revision:{status:'verified',asset_id:node.asset_target.id},review_decision:'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance',target:node.id},result_write_set:[artifact,receipt]};
const packet=path.resolve(root,receipt);fs.mkdirSync(path.dirname(packet),{recursive:true});fs.writeFileSync(packet,JSON.stringify(result,null,2));
NODE
    packet="$(node -e "const path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask('$book'); console.log(path.resolve('$book',task.stage_execution.expected_result_packet))")"
    run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "stage_started"'* ]]
}

@test "long write blocks project tree symlinks at snapshot and acceptance" {
    existing_book="$TMP_DIR/symlink-before-snapshot"
    outside_before="$TMP_DIR/outside-before.md"
    printf 'outside\n' > "$outside_before"
    node "$SCRIPT" create --workflow-type long_write --project-root "$existing_book" --user-goal "开一本新书" --json >/dev/null
    mkdir -p "$existing_book/设定"
    ln -s "$outside_before" "$existing_book/设定/外部链接.md"

    run resolve_action "$existing_book" 1
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_project_symlink'* ]]

    new_book="$TMP_DIR/symlink-after-snapshot"
    outside_after="$TMP_DIR/outside-after.md"
    printf 'outside\n' > "$outside_after"
    node "$SCRIPT" create --workflow-type long_write --project-root "$new_book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$new_book" 1 >/dev/null
    mkdir -p "$new_book/设定"
    ln -s "$outside_after" "$new_book/设定/新建外部链接.md"

    run apply_long_write_v2_result "$new_book" "" completed pass
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_project_symlink'* ]]
}

@test "long write blocks .git symlinks before skipping git contents" {
    existing_book="$TMP_DIR/git-symlink-before-snapshot"
    outside_before="$TMP_DIR/outside-git-before-snapshot"
    mkdir -p "$outside_before"
    node "$SCRIPT" create --workflow-type long_write --project-root "$existing_book" --user-goal "开一本新书" --json >/dev/null
    ln -s "$outside_before" "$existing_book/.git"

    run resolve_action "$existing_book" 1
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_project_symlink'* ]]
    [[ "$output" == *'.git'* ]]

    new_book="$TMP_DIR/git-symlink-after-snapshot"
    outside_after="$TMP_DIR/outside-git-after-snapshot"
    mkdir -p "$outside_after"
    node "$SCRIPT" create --workflow-type long_write --project-root "$new_book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$new_book" 1 >/dev/null
    ln -s "$outside_after" "$new_book/.git"

    run apply_long_write_v2_result "$new_book" "" completed pass
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_project_symlink'* ]]
    [[ "$output" == *'.git'* ]]
}

@test "tampered long write stage execution cannot redefine the active lifecycle contract" {
    book="$TMP_DIR/tampered-stage-execution"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$book" 1 >/dev/null

    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const taskFile=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
task.stage_execution.owner_module='story-review';
task.stage_execution.lifecycle_node='prose';
task.stage_execution.asset_target={kind:'chapter',id:'forged-asset'};
task.stage_execution.review_requirement={required:true,failure_return:'prose'};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2));
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify({
  workflow_id:task.workflow_id,
  workflow_type:task.workflow_type,
  stage_id:task.current_stage,
  step_id:task.current_step,
  owner_module:task.stage_execution.owner_module,
  lifecycle_node:task.stage_execution.lifecycle_node,
  asset_target:task.stage_execution.asset_target,
  review_requirement:task.stage_execution.review_requirement,
  step_status:'completed',
  outputs:[],
  changed_files:[],
  evidence:[],
  verification_result:'pass',
  checkpoint_state:{stage:task.current_stage},
  output_health_result:'pass'
},null,2));
NODE

    packet="$(node -e "const path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask('$book'); console.log(path.resolve('$book',task.stage_execution.expected_result_packet))")"
    run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_result_contract_mismatch'* ]]
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
if(task.current_stage!=='positioning') throw new Error(`forged contract advanced to ${task.current_stage}`);
NODE
}

@test "legacy long write tasks require explicit supported-project lifecycle migration" {
    for shape in missing invalid; do
        book="$TMP_DIR/legacy-$shape"
        mkdir -p "$book/正文"
        printf 'creative asset must stay unchanged\n' > "$book/正文/legacy.md"
        before_hash="$(shasum -a 256 "$book/正文/legacy.md" | awk '{print $1}')"
        node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "续写旧项目" --json >/dev/null
        node - "$book" "$shape" <<'NODE'
const fs=require('fs'),path=require('path');
const [root,shape]=process.argv.slice(2);
for(const file of fs.readdirSync(path.join(root,'追踪/workflow/tasks')).map(id=>path.join(root,'追踪/workflow/tasks',id,'task.json'))) {
  const task=JSON.parse(fs.readFileSync(file,'utf8'));
  if(shape==='missing') delete task.lifecycle_graph;
  else if(shape==='invalid') task.lifecycle_graph={version:'0.9.0',current_node:'positioning',completed_nodes:[],invalidated_nodes:[]};
  fs.writeFileSync(file,JSON.stringify(task,null,2));
}
NODE

        run node "$SCRIPT" next-candidates --project-root "$book" --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]
        [[ "$output" == *'explicit supported-project lifecycle migration'* ]]

        run node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧项目" --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]

        run resolve_action "$book" 1
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]

        printf '{}' > "$book/result.json"
        run node "$SCRIPT" apply-result --project-root "$book" --result "$book/result.json" --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]
        after_hash="$(shasum -a 256 "$book/正文/legacy.md" | awk '{print $1}')"
        [ "$before_hash" = "$after_hash" ]
    done
}

@test "legacy long write migration blocks only requests that continue long write" {
    for command in create switch-intent; do
        book="$TMP_DIR/legacy-unrelated-$command"
        node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "续写旧项目" --json >/dev/null
        node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
for(const file of fs.readdirSync(path.join(root,'追踪/workflow/tasks')).map(id=>path.join(root,'追踪/workflow/tasks',id,'task.json'))) {
  const task=JSON.parse(fs.readFileSync(file,'utf8'));
  delete task.lifecycle_graph;
  fs.writeFileSync(file,JSON.stringify(task,null,2));
}
NODE

        node "$SCRIPT" "$command" --workflow-type short_write --project-root "$book" --scope "短篇新任务" --user-goal "改写一篇短篇" --reason "切换到无关短篇" --json > "$TMP_DIR/$command.json"
        node - "$TMP_DIR/$command.json" <<'NODE'
const fs=require('fs'),out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(!['created','switched'].includes(out.status)) throw new Error(JSON.stringify(out));
if(out.task.workflow_type!=='short_write') throw new Error(JSON.stringify(out.task));
NODE
    done
}

@test "modern long write graph cannot jump past incomplete lifecycle predecessors" {
    book="$TMP_DIR/incomplete-modern-graph"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
for(const file of fs.readdirSync(path.join(root,'追踪/workflow/tasks')).map(id=>path.join(root,'追踪/workflow/tasks',id,'task.json'))) {
  const task=JSON.parse(fs.readFileSync(file,'utf8'));
  task.current_stage='prose';
  task.current_step='prose';
  task.lifecycle_graph.current_node='prose';
  task.lifecycle_graph.asset_target=task.lifecycle_graph.nodes.find(node=>node.id==='prose').asset_target;
  task.lifecycle_graph.completed_nodes=[];
  task.lifecycle_graph.invalidated_nodes=[];
  task.machine.completed_stages=[];
  task.machine.remaining_stages=['prose','prose_acceptance','chapter_commit','milestone_review','volume_acceptance','book_acceptance'];
  fs.writeFileSync(file,JSON.stringify(task,null,2));
}
NODE

    workflow_id="$(node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
process.stdout.write(pointer.workflow_id);
NODE
)"
    printf '{"workflow_id":"%s"}\n' "$workflow_id" > "$book/result.json"
    for command in inspect next-candidates apply-result; do
        if [ "$command" = apply-result ]; then
            run node "$SCRIPT" "$command" --project-root "$book" --result "$book/result.json" --json
        else
            run node "$SCRIPT" "$command" --project-root "$book" --json
        fi
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_lifecycle_incomplete'* ]]
        node - "$output" <<'NODE'
const out=JSON.parse(process.argv[2]);
if(out.first_missing_node!=='positioning') throw new Error(JSON.stringify(out));
NODE
    done
}

@test "failed long write review returns only to its asset and invalidates downstream nodes" {
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --user-goal "开一本新书" --json >/dev/null
    advance_long_write_stage "$TMP_DIR/book"
    advance_long_write_stage "$TMP_DIR/book"
    advance_long_write_stage "$TMP_DIR/book"
    resolve_action "$TMP_DIR/book" 1 >/dev/null
    apply_long_write_v2_result "$TMP_DIR/book" "" failed failed volume_outline > "$TMP_DIR/review-out.json"

    node - "$TMP_DIR/review-out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = out.task;
if (task.current_stage !== 'master_outline') throw new Error(`review escaped to ${task.current_stage}`);
if (task.lifecycle_graph.current_node !== 'master_outline') throw new Error(`graph escaped to ${task.lifecycle_graph.current_node}`);
if (!task.lifecycle_graph.invalidated_nodes.includes('master_outline')) throw new Error('failed asset was not invalidated');
if (task.machine.completed_stages.includes('master_outline')) throw new Error('failed asset remains completed');
if (task.machine.remaining_stages[0] !== 'master_outline') throw new Error(`wrong rollback queue: ${JSON.stringify(task.machine.remaining_stages)}`);
if (task.machine.last_transition !== 'review_failed_return_to_asset') throw new Error(`wrong transition: ${task.machine.last_transition}`);
const validation=task.lifecycle_graph.last_transition_validation;
if(!validation || validation.allowed!==true) throw new Error(`rollback validation was not accepted: ${JSON.stringify(validation)}`);
if(validation.rule!=='required_review_failure_return') throw new Error(`wrong rollback validation rule: ${JSON.stringify(validation)}`);
if(validation.from!=='master_outline_review'||validation.to!=='master_outline') throw new Error(`wrong rollback validation endpoints: ${JSON.stringify(validation)}`);
NODE
}

@test "detail outline quality pass with matching identity advances to chapter brief" {
    book="$TMP_DIR/detail-quality-pass"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass > "$TMP_DIR/detail-quality-pass.json"

    node - "$TMP_DIR/detail-quality-pass.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(!['advanced','stage_started'].includes(out.status) || out.task.current_stage!=='chapter_brief') throw new Error(JSON.stringify(out));
if(out.task.machine.last_transition!=='lifecycle_node_completed') throw new Error(JSON.stringify(out.task.machine));
NODE
}

@test "detail outline quality pass with advisory advances to chapter brief" {
    book="$TMP_DIR/detail-quality-pass-advisory"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass_with_advisory > "$TMP_DIR/detail-quality-pass-advisory.json"

    node - "$TMP_DIR/detail-quality-pass-advisory.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(!['advanced','stage_started'].includes(out.status) || out.task.current_stage!=='chapter_brief') throw new Error(JSON.stringify(out));
NODE
}

@test "detail outline quality CLI writes an applyable long write result packet" {
    book="$TMP_DIR/detail-quality-cli"
    node - "$SCRIPT" "$REPO/scripts/detail-outline-quality-check.js" "$book" <<'NODE'
const crypto=require('crypto'), fs=require('fs'), path=require('path'), cp=require('child_process');
const [script,check,root]=process.argv.slice(2);
cp.execFileSync(process.execPath,[script,'create','--workflow-type','long_write','--project-root',root,'--user-goal','开一本新书','--json']);
const advance=(declaredFiles=[])=>{
  const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
  if(!task.stage_execution || task.stage_execution.status!=='running') {
    const pending=task.pending_action;
    cp.execFileSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',pending.id,'--visible-choice-hash',pending.visible_choice_hash,'--state-version',String(task.state_version),'--book-root',root,'--json']);
  }
  const active=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
  const node=(active.lifecycle_graph.nodes||[]).find(item=>item.id===active.current_stage);
  const packet=path.join(root,active.stage_execution.expected_result_packet);
  const result={workflow_id:active.workflow_id,workflow_type:'long_write',stage_id:active.current_stage,step_id:active.current_step,owner_module:node.owner_module,lifecycle_node:node.id,asset_target:node.asset_target,review_requirement:node.review_requirement,step_status:'completed',outputs:[],changed_files:declaredFiles,evidence:[],verification_result:'pass',checkpoint_state:{stage_id:active.current_stage},output_health_result:'pass',asset_revision:{status:'verified',asset_id:node.asset_target.id},review_decision:node.review_requirement.required?'accepted':'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance',target:node.id},result_write_set:declaredFiles};
  fs.mkdirSync(path.dirname(packet),{recursive:true}); fs.writeFileSync(packet,JSON.stringify(result));
  cp.execFileSync(process.execPath,[script,'apply-result','--project-root',root,'--result',packet,'--json']);
};
for(let i=0;i<6;i+=1) advance();
const outline=path.join(root,'大纲','第1卷','细纲_第001章.md');
fs.mkdirSync(path.dirname(outline),{recursive:true});
fs.writeFileSync(outline,`# 第001章\n- 核心事件：林昭保存调度记录并继续追查。\n- 目标情绪：疑虑转为主动。\n#### 情节安排\n1. 林昭打开手机保存调度记录，因此确认旧账号仍在使用。\n2. 她拨打旧同事电话，拿到需要继续调查的新地址。\n#### 呈现与连续性\n- 可见证据：调度记录和通话录音。\n- 前置承接：承接上一章的异常调度。\n- 本章变化：林昭从怀疑转为掌握追查入口。\n- 后续债务：新地址的主人尚未现身。\n`);
advance(['大纲/第1卷/细纲_第001章.md']);
const reviewTask=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const outlineRel='大纲/第1卷/细纲_第001章.md';
const semanticRel=`追踪/workflow/tasks/${reviewTask.workflow_id}/work/detail-outline-semantic-review.json`;
const outlineHash=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,outlineRel))).digest('hex');
fs.mkdirSync(path.dirname(path.join(root,semanticRel)),{recursive:true});
fs.writeFileSync(path.join(root,semanticRel),JSON.stringify({outline_path:outlineRel,outline_sha256:outlineHash,reviewer:'main-session',findings:[]}));
if(!reviewTask.stage_execution || reviewTask.stage_execution.status!=='running') {
  const reviewPending=reviewTask.pending_action;
  cp.execFileSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',reviewPending.id,'--visible-choice-hash',reviewPending.visible_choice_hash,'--state-version',String(reviewTask.state_version),'--book-root',root,'--json']);
}
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const packet=path.join(root,task.stage_execution.expected_result_packet);
const quality=cp.spawnSync(process.execPath,[check,'--project-root',root,'--outline',outlineRel,'--workflow-id',task.workflow_id,'--semantic-review',semanticRel,'--write-result',task.stage_execution.expected_result_packet,'--json'],{encoding:'utf8'});
if(quality.status!==0) throw new Error(quality.stderr||quality.stdout);
const result=JSON.parse(fs.readFileSync(packet,'utf8'));
if(result.workflow_type!=='long_write'||result.owner_module!=='story-review'||!Array.isArray(result.result_write_set)) throw new Error(JSON.stringify(result));
const applied=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',packet,'--json'],{encoding:'utf8'});
if(applied.status!==0) throw new Error(applied.stderr||applied.stdout);
const out=JSON.parse(applied.stdout);
if(out.task.current_stage!=='chapter_brief') throw new Error(JSON.stringify(out));
NODE
}

@test "detail outline quality revise returns to outline and invalidates downstream nodes" {
    book="$TMP_DIR/detail-quality-revise"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" revise > "$TMP_DIR/detail-quality-revise.json"

    node - "$TMP_DIR/detail-quality-revise.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.task;
if(task.current_stage!=='stage_detail_outline') throw new Error(JSON.stringify(out));
if(task.machine.last_transition!=='review_failed_return_to_asset') throw new Error(JSON.stringify(task.machine));
if(!task.lifecycle_graph.invalidated_nodes.includes('stage_detail_outline')) throw new Error(JSON.stringify(task.lifecycle_graph));
if(task.machine.completed_stages.includes('stage_detail_outline')) throw new Error(JSON.stringify(task.machine));
NODE
}

@test "detail outline quality identity missing remains at review" {
    book="$TMP_DIR/detail-quality-identity-missing"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" identity_missing > "$TMP_DIR/detail-quality-identity-missing.json"

    node - "$TMP_DIR/detail-quality-identity-missing.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.task;
if(task.current_stage!=='detail_outline_review') throw new Error(JSON.stringify(out));
if(task.machine.last_transition!=='detail_outline_quality_identity_missing') throw new Error(JSON.stringify(task.machine));
if(task.machine.completed_stages.includes('detail_outline_review')) throw new Error(JSON.stringify(task.machine));
NODE
}

@test "detail outline quality evidence identity mismatch remains at review" {
    book="$TMP_DIR/detail-quality-identity-mismatch"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass "" evidence_mismatch > "$TMP_DIR/detail-quality-identity-mismatch.json"

    node - "$TMP_DIR/detail-quality-identity-mismatch.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.task;
if(task.current_stage!=='detail_outline_review') throw new Error(JSON.stringify(out));
if(task.machine.last_transition!=='detail_outline_quality_identity_missing') throw new Error(JSON.stringify(task.machine));
if(task.machine.completed_stages.includes('detail_outline_review')) throw new Error(JSON.stringify(task.machine));
NODE
}

@test "outline underfilled packet rejects nonempty contract projection" {
    book="$TMP_DIR/detail-quality-underfilled-projection"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" outline_underfilled nonempty > "$TMP_DIR/detail-quality-underfilled-projection.json"

    node - "$TMP_DIR/detail-quality-underfilled-projection.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.task;
if(task.current_stage!=='detail_outline_review') throw new Error(JSON.stringify(out));
if(task.machine.last_transition!=='detail_outline_underfilled_projection_forbidden') throw new Error(JSON.stringify(task.machine));
if(task.machine.completed_stages.includes('detail_outline_review')) throw new Error(JSON.stringify(task.machine));
NODE
}

@test "outline underfilled without projections returns to detail outline stage" {
    book="$TMP_DIR/detail-quality-underfilled"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" outline_underfilled > "$TMP_DIR/detail-quality-underfilled.json"

    node - "$TMP_DIR/detail-quality-underfilled.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.task;
if(task.current_stage!=='stage_detail_outline') throw new Error(JSON.stringify(out));
if(task.machine.last_transition!=='review_failed_return_to_asset') throw new Error(JSON.stringify(task.machine));
NODE
}

@test "detail outline quality validates the current project outline identity" {
    node - "$REPO/scripts/lib/workflow-transition-service.js" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { validateDetailOutlineQualityResult } = require(process.argv[2]);
const root = process.argv[3];
const rel = '大纲/第1卷/细纲_第001章.md';
const file = path.join(root, rel);
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, '当前细纲');
const actual = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const task = { workflow_type: 'long_write', workflow_id: 'wf-current-outline', current_stage: 'detail_outline_review', book_root: root };
const packet = (outline_path, outline_sha256) => ({
  outputs: { detail_outline_quality: { status: 'pass', workflow_id: task.workflow_id, stage_id: task.current_stage, outline_path, outline_sha256, activated_dimensions: [], findings: [], execution: { semantic_review: { status: 'accepted', reviewer: 'main-session', findings: [], findings_sha256: crypto.createHash('sha256').update('[]').digest('hex'), finding_count: 0 } } } },
  evidence: [{ type: 'detail_outline', path: outline_path, outline_sha256 }],
});
assert.equal(validateDetailOutlineQualityResult(packet(rel, actual), task).status, 'accepted');
assert.equal(validateDetailOutlineQualityResult(packet(rel, 'a'.repeat(64)), task).code, 'detail_outline_quality_outline_sha256_mismatch');
assert.equal(validateDetailOutlineQualityResult(packet('大纲/第1卷/不存在.md', actual), task).code, 'detail_outline_quality_outline_missing');
assert.equal(validateDetailOutlineQualityResult(packet('../细纲.md', actual), task).code, 'detail_outline_quality_outline_path_unsafe');
NODE
}

@test "detail outline quality validates semantic review findings integrity" {
    node - "$REPO/scripts/lib/workflow-transition-service.js" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { validateDetailOutlineQualityResult } = require(process.argv[2]);
const root = process.argv[3];
const rel = '大纲/第1卷/细纲_第002章.md';
const file = path.join(root, rel);
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, '当前细纲');
const outlineHash = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const findings = [{ dimension: 'B1_causality_action', severity: 'advisory', message: '建议补强' }];
const findingsHash = crypto.createHash('sha256').update(JSON.stringify(findings), 'utf8').digest('hex');
const task = { workflow_type: 'long_write', workflow_id: 'wf-semantic-integrity', current_stage: 'detail_outline_review', book_root: root };
const packet = {
  outputs: { detail_outline_quality: {
    status: 'pass_with_advisory', workflow_id: task.workflow_id, stage_id: task.current_stage,
    outline_path: rel, outline_sha256: outlineHash, activated_dimensions: [], findings,
    execution: { semantic_review: { status: 'accepted', reviewer: 'main-session', findings, findings_sha256: findingsHash, finding_count: 1 } },
  } },
  evidence: [{ type: 'detail_outline', path: rel, outline_sha256: outlineHash }],
};
assert.equal(validateDetailOutlineQualityResult(packet, task).status, 'accepted');
packet.outputs.detail_outline_quality.execution.semantic_review.findings_sha256 = 'b'.repeat(64);
assert.equal(validateDetailOutlineQualityResult(packet, task).code, 'detail_outline_quality_semantic_review_integrity_mismatch');
packet.outputs.detail_outline_quality.execution.semantic_review.findings_sha256 = findingsHash;
packet.outputs.detail_outline_quality.findings[0].severity = 'blocking';
packet.outputs.detail_outline_quality.execution.semantic_review.findings[0].severity = 'blocking';
const blockingHash = crypto.createHash('sha256').update(JSON.stringify(packet.outputs.detail_outline_quality.execution.semantic_review.findings), 'utf8').digest('hex');
packet.outputs.detail_outline_quality.execution.semantic_review.findings_sha256 = blockingHash;
assert.equal(validateDetailOutlineQualityResult(packet, task).code, 'detail_outline_quality_status_findings_mismatch');
NODE
}

@test "workflow state machine gives scan analysis and cover first class lifecycle contracts" {
    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/templates.json"

    node - "$TMP_DIR/templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const templates = Object.fromEntries(data.templates.map((item) => [item.workflow_type, item]));
const requiredTypes = ['long_scan', 'short_scan', 'short_analyze', 'cover'];
const requiredLifecycleStages = ['preflight', 'lock', 'execute', 'validation', 'artifact', 'closure'];
const requiredResultFields = ['outputs', 'changed_files', 'evidence', 'verification_result', 'checkpoint_state', 'output_health_result'];

if (data.templates.length !== 15) throw new Error(`expected fifteen first-class workflows, got ${data.templates.length}`);
for (const type of requiredTypes) {
  const template = templates[type];
  if (!template || !template.stages.length) throw new Error(`missing ${type}`);
  if (!template.stages.every((stage) => stage.owner_module && stage.risk_level && typeof stage.requires_user_confirm === 'boolean')) {
    throw new Error(`invalid owner/risk/confirmation contract for ${type}`);
  }
  const stageIds = template.stages.map((stage) => stage.stage_id).join(' ');
  for (const marker of requiredLifecycleStages) {
    if (!stageIds.includes(marker)) throw new Error(`${type} missing ${marker} lifecycle stage: ${stageIds}`);
  }
  if (!template.recovery || !template.recovery.preserve_last_trusted_artifact || !template.recovery.resume_from) {
    throw new Error(`${type} missing recovery contract`);
  }
  if (!template.result_contract || template.result_contract.version !== 2) {
    throw new Error(`${type} missing result contract`);
  }
  for (const field of requiredResultFields) {
    if (!template.result_contract.required_fields.includes(field)) throw new Error(`${type} result contract missing ${field}`);
  }
}

const cover = templates.cover;
const confirmation = cover.stages.find((stage) => stage.stage_id === 'generation_confirmation');
const generation = cover.stages.find((stage) => stage.stage_id === 'generate_cover_execute');
if (!confirmation || !confirmation.requires_user_confirm || !generation || !generation.requires_user_confirm) {
  throw new Error('cover must require confirmation before generation or overwrite');
}
for (const [type, template] of Object.entries(templates)) {
  if (!template.result_contract || template.result_contract.version !== 2) {
    throw new Error(`${type} missing result contract`);
  }
  for (const field of requiredResultFields) {
    if (!template.result_contract.required_fields.includes(field)) throw new Error(`${type} result contract missing ${field}`);
  }
}
NODE
}

@test "scan analysis and cover workflows run real v2 lifecycles through closure" {
    node - "$SCRIPT" "$TMP_DIR" <<'NODE'
const cp = require('child_process');
const fs = require('fs');
const path = require('path');

const script = process.argv[2];
const tmp = process.argv[3];
const templateResult = run(['templates', '--no-private-registry', '--json']);
const templates = Object.fromEntries(templateResult.templates.map((item) => [item.workflow_type, item]));

for (const spec of [
  { type: 'long_scan', goal: '扫描长篇榜单' },
  { type: 'short_scan', goal: '扫描短篇榜单' },
  { type: 'short_analyze', goal: '拆解合法持有的短篇原文' },
  { type: 'cover', goal: '生成新封面', coverOperation: 'generate' },
  { type: 'cover', goal: '覆盖现有封面', coverOperation: 'overwrite' },
]) {
  const project = path.join(tmp, `${spec.type}-${spec.coverOperation || 'closure'}`);
  fs.mkdirSync(project, { recursive: true });
  run(['create', '--workflow-type', spec.type, '--project-root', project, '--user-goal', spec.goal, '--scope', spec.goal, '--json']);
  const confirmationTokens = [];
  const visited = [];

  for (let guard = 0; guard < 20; guard += 1) {
    const task = require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(project);
    if (task.status === 'completed') {
      if (task.lifecycle.status !== 'completed') throw new Error(`${spec.type} lifecycle not completed`);
      if (task.current_stage !== 'closure') throw new Error(`${spec.type} did not close at closure: ${task.current_stage}`);
      if (!task.pending_action || !task.pending_action.options.length) throw new Error(`${spec.type} completion choices missing`);
      break;
    }

    const stage = templates[spec.type].stages.find((item) => item.stage_id === task.current_stage);
    if (!stage) throw new Error(`${spec.type} unknown stage ${task.current_stage}`);
    visited.push(stage.stage_id);
    const alreadyRunning = task.stage_execution && task.stage_execution.status === 'running' && task.stage_execution.stage_id === stage.stage_id;
    const started = alreadyRunning
      ? { status: 'stage_started', stage_execution: task.stage_execution }
      : resolveFirst(project);
    if (started.status !== 'stage_started') throw new Error(`${spec.type}/${stage.stage_id} not started: ${started.status}`);
    const execution = started.stage_execution;
    if (!execution || execution.status !== 'running') throw new Error(`${spec.type}/${stage.stage_id} missing execution lock`);
    if (execution.stage_id !== stage.stage_id || execution.step_id !== stage.stage_id) throw new Error('execution ids drifted');

    if (stage.requires_user_confirm) {
      const confirmation = execution.confirmation_context;
      if (!confirmation || !confirmation.confirmation_token) throw new Error(`${spec.type}/${stage.stage_id} confirmation token missing`);
      if (Date.parse(confirmation.expires_at) <= Date.now()) throw new Error(`${spec.type}/${stage.stage_id} confirmation expired`);
      if (confirmation.stage_id !== stage.stage_id || confirmation.step_id !== stage.stage_id) throw new Error('confirmation ids drifted');
      if (spec.coverOperation && confirmation.operation !== spec.coverOperation) throw new Error(`cover operation not confirmed: ${confirmation.operation}`);
      confirmationTokens.push(confirmation.confirmation_token);
    }

    const packetFile = path.resolve(project, execution.expected_result_packet);
    fs.mkdirSync(path.dirname(packetFile), { recursive: true });
    fs.writeFileSync(packetFile, `${JSON.stringify({
      workflow_id: task.workflow_id,
      workflow_type: spec.type,
      owner_module: execution.owner_module,
      stage_id: execution.stage_id,
      step_id: execution.step_id,
      step_status: 'completed',
      outputs: [],
      changed_files: [],
      evidence: [],
      verification_result: 'pass',
      checkpoint_state: { completed_stage: execution.stage_id },
      output_health_result: 'pass',
      next_recommendation: [],
      result_packet_path: execution.expected_result_packet,
    }, null, 2)}\n`);
    const applied = run(['apply-result', '--project-root', project, '--result', packetFile, '--json']);
    if (!['advanced', 'stage_started'].includes(applied.status)) throw new Error(`${spec.type}/${stage.stage_id} not advanced: ${applied.status}`);
  }

  const expectedStages = templates[spec.type].stages.map((item) => item.stage_id);
  if (JSON.stringify(visited) !== JSON.stringify(expectedStages)) {
    throw new Error(`${spec.type} lifecycle drift: ${JSON.stringify(visited)}`);
  }
  if (spec.coverOperation && confirmationTokens.length !== 2) throw new Error(`${spec.coverOperation} must confirm gate and execution`);
  if (new Set(confirmationTokens).size !== confirmationTokens.length) throw new Error('confirmation token was reused');
}

function run(args) {
  const publicTemplateArgs = args.includes('--no-private-registry') ? args : [...args, '--no-private-registry'];
  const result = cp.spawnSync(process.execPath, [script, ...publicTemplateArgs], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${args[0]} failed: ${result.stdout || result.stderr}`);
  return JSON.parse(result.stdout);
}

function resolveFirst(project) {
  const task = require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(project);
  const pending = task.pending_action || {};
  return run(['resolve-action', '--project-root', project, '--input', '1', '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash, '--state-version', String(task.state_version), '--book-root', project, '--json']);
}
NODE
}

@test "v2 apply result binds running execution ids and safe expected packet path" {
    node - "$SCRIPT" "$TMP_DIR" <<'NODE'
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const script = process.argv[2];
const tmp = process.argv[3];

assertBlockedWithoutRunningExecution();
assertBlockedForUnexpectedPacketFile();
assertBlockedForMismatchedStep();
assertBlockedForUnsafeExpectedPath();

function createProject(name) {
  const project = path.join(tmp, name);
  fs.mkdirSync(project, { recursive: true });
  const created = run(['create', '--workflow-type', 'long_scan', '--project-root', project, '--json']);
  return { project, task: created.task };
}

function packet(task, stageId, stepId, packetPath) {
  return {
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    owner_module: task.stage_execution?.owner_module || 'story-long-scan',
    stage_id: stageId,
    step_id: stepId,
    step_status: 'completed',
    outputs: [], changed_files: [], evidence: [],
    verification_result: 'pass', checkpoint_state: {}, output_health_result: 'pass',
    result_packet_path: packetPath,
  };
}

function writePacket(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function assertBlockedWithoutRunningExecution() {
  const { project, task } = createProject('no-running-execution');
  const rel = `${task.context_paths.result_packets_dir}/${task.current_stage}.result.json`;
  const file = path.join(project, rel);
  writePacket(file, packet(task, task.current_stage, task.current_step, rel));
  expectBlocked(['apply-result', '--project-root', project, '--result', file, '--json'], 'blocked_stage_execution_required');
}

function assertBlockedForUnexpectedPacketFile() {
  const { project } = createProject('unexpected-packet');
  const started = resolveFirst(project);
  const task = readTask(project);
  const file = path.join(project, 'unexpected.result.json');
  writePacket(file, packet(task, started.stage_execution.stage_id, started.stage_execution.step_id, 'unexpected.result.json'));
  expectBlocked(['apply-result', '--project-root', project, '--result', file, '--json'], 'blocked_result_packet_path_mismatch');
}

function assertBlockedForMismatchedStep() {
  const { project } = createProject('mismatched-step');
  const started = resolveFirst(project);
  const task = readTask(project);
  const rel = started.stage_execution.expected_result_packet;
  const file = path.join(project, rel);
  writePacket(file, packet(task, started.stage_execution.stage_id, 'wrong-step', rel));
  expectBlocked(['apply-result', '--project-root', project, '--result', file, '--json'], 'blocked_stage_execution_mismatch');
}

function assertBlockedForUnsafeExpectedPath() {
  const { project } = createProject('unsafe-expected-path');
  const started = resolveFirst(project);
  const taskFile = require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(project);
  const task = readTask(project);
  task.stage_execution.expected_result_packet = '../../outside.result.json';
  fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
  fs.writeFileSync(path.join(project, task.task_dir, 'task.json'), `${JSON.stringify(task, null, 2)}\n`);
  const file = path.resolve(project, '../../outside.result.json');
  writePacket(file, packet(task, started.stage_execution.stage_id, started.stage_execution.step_id, '../../outside.result.json'));
  expectBlocked(['apply-result', '--project-root', project, '--result', file, '--json'], 'blocked_result_packet_path_unsafe');
}

function readTask(project) {
  return require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(project);
}

function run(args) {
  const result = cp.spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${args[0]} failed: ${result.stdout || result.stderr}`);
  return JSON.parse(result.stdout);
}

function resolveFirst(project) {
  const task = readTask(project);
  const pending = task.pending_action || {};
  return run(['resolve-action', '--project-root', project, '--input', '1', '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash, '--state-version', String(task.state_version), '--book-root', project, '--json']);
}

function expectBlocked(args, status) {
  const result = cp.spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  const out = JSON.parse(result.stdout);
  if (result.status !== 2 || out.status !== status) throw new Error(`expected ${status}, got ${result.status}: ${result.stdout || result.stderr}`);
}
NODE
}

@test "evidence scan result packet requires protocol source digest and full range coverage" {
    cp -R "$REPO/tests/fixtures/review-evidence-map/flat/." "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-1" --json >/dev/null
    resolve_action "$TMP_DIR/book" 1 >/dev/null
    task_id="$(node -e 'console.log(require(process.argv[1]).workflow_id)' "$(focused_task_file "$TMP_DIR/book")")"
    range_packet="$TMP_DIR/book/追踪/workflow/tasks/$task_id/result-packets/range_lock.result.json"
    cat > "$range_packet" <<JSON
{"workflow_id":"$task_id","workflow_type":"review_repair","owner_module":"story-workflow","stage_id":"range_lock","step_id":"range_lock","step_status":"completed","outputs":[],"changed_files":[],"evidence":[],"verification_result":"pass","checkpoint_state":{},"output_health_result":"pass"}
JSON
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$range_packet" --json >/dev/null
    resolve_action "$TMP_DIR/book" 1 >/dev/null

    node - "$SCRIPT" "$TMP_DIR/book" <<'NODE'
const cp=require('child_process');
const fs=require('fs');
const path=require('path');
const script=process.argv[2], root=process.argv[3];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const rel=task.stage_execution.expected_result_packet;
const file=path.join(root,rel);
const base={
  workflow_id:task.workflow_id,workflow_type:'review_repair',owner_module:'story-review',stage_id:'evidence_scan',step_id:'evidence_scan',step_status:'completed',
  batch_id:'001',batch_scope:'1-1',outputs:[],changed_files:[],evidence:[],verification_result:'pass',checkpoint_state:{},output_health_result:'pass',result_packet_path:rel,
  protocolVersion:'2.0.0',sourceDigest:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  fullRangeCoverage:{start:1,end:1,coveredChapters:1,complete:true}
};
for(const missing of ['protocolVersion','sourceDigest','fullRangeCoverage']){
  const packet={...base}; delete packet[missing];
  fs.writeFileSync(file,`${JSON.stringify(packet,null,2)}\n`);
  const result=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',file,'--json'],{encoding:'utf8'});
  const out=JSON.parse(result.stdout);
  if(result.status!==2||out.status!=='blocked_review_evidence_protocol_incompatible') throw new Error(`${missing}: ${result.stdout||result.stderr}`);
}
NODE
}

@test "confirmed protocol reset starts at first incompatible batch and preserves old packets and prose" {
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/wf-review-reset"
    packet_dir="$task_dir/result-packets"
    mkdir -p "$packet_dir" "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/正文"
    printf '%s\n' '正文不可修改' > "$TMP_DIR/book/正文/第001章.md"
    cat > "$task_dir/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0","state_version":1,"workflow_id":"wf-review-reset","workflow_type":"review_repair",
  "book_root":"BOOK_ROOT","task_dir":"追踪/workflow/tasks/wf-review-reset","scope":"1-200","status":"completed",
  "current_stage":"closure","current_step":"closure","completion_policy":"stage_then_confirm",
  "lifecycle":{"status":"completed","completed_at":"2026-07-11T00:00:00.000Z"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","closure"],"remaining_stages":[],"allowed_actions":[]},
  "runtime_guard":{"heartbeat":{"latest_trusted_artifact":"追踪/审查报告/旧报告.md"},"checkpoint_policy":{"resume_from":"completed","expected_result_packet":""}},
  "review_batches":{"completed_count":4,"total_count":4,"next_batch_id":"","aggregate_status":"completed","batches":[
    {"id":"001","range":"1-50","status":"completed","accepted_result_packet":"追踪/workflow/tasks/wf-review-reset/result-packets/evidence_scan.batch-001.result.json"},
    {"id":"002","range":"51-100","status":"done","accepted_result_packet":"追踪/workflow/tasks/wf-review-reset/result-packets/evidence_scan.batch-002.result.json"},
    {"id":"003","range":"101-150","status":"completed","accepted_result_packet":"追踪/workflow/tasks/wf-review-reset/result-packets/evidence_scan.batch-003.result.json"},
    {"id":"004","range":"151-200","status":"done","accepted_result_packet":"追踪/workflow/tasks/wf-review-reset/result-packets/evidence_scan.batch-004.result.json"}
  ]}
}

JSON
    sed -i '' "s|BOOK_ROOT|$TMP_DIR/book|" "$task_dir/task.json"
    cp "$task_dir/task.json" "$TMP_DIR/book/追踪/workflow/current-task.json"
    for spec in "001 1 50" "002 51 100"; do
      set -- $spec
      cat > "$packet_dir/evidence_scan.batch-$1.result.json" <<JSON
{"protocolVersion":"2.0.0","sourceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fullRangeCoverage":{"start":$2,"end":$3,"coveredChapters":50,"complete":true}}
JSON
    done
    printf '%s\n' '{"step_status":"completed"}' > "$packet_dir/evidence_scan.batch-003.result.json"
    printf '%s\n' '{"step_status":"completed"}' > "$packet_dir/evidence_scan.batch-004.result.json"

    node "$SCRIPT" reset-incompatible-review-batches --project-root "$TMP_DIR/book" --workflow-id wf-review-reset --confirm --json > "$TMP_DIR/reset.json"

    node - "$TMP_DIR/reset.json" "$task_dir/task.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='review_batches_reset'||out.from_batch_id!=='003') throw new Error(JSON.stringify(out));
if(task.review_batches.completed_count!==2||task.review_batches.next_batch_id!=='003') throw new Error(JSON.stringify(task.review_batches));
if(task.review_batches.batches.map(x=>x.status).join(',')!=='completed,completed,pending,pending') throw new Error(JSON.stringify(task.review_batches));
if(task.current_stage!=='evidence_scan'||task.status!=='running'||task.lifecycle.status!=='active') throw new Error(JSON.stringify(task));
if(task.stage_execution.status!=='running'||task.pending_action.status!=='resolved') throw new Error(JSON.stringify({stage_execution:task.stage_execution,pending_action:task.pending_action}));
if(!/^sa-wf-review-reset-evidence_scan-[0-9a-f]{8}$/.test(String(task.stage_execution.stage_attempt_id||''))) throw new Error(JSON.stringify(task.stage_execution));
if(!task.stage_execution.expected_result_packet.endsWith('evidence_scan.batch-003.protocol-v2.result.json')) throw new Error(JSON.stringify(task.stage_execution));
if(task.runtime_guard.checkpoint_policy.expected_result_packet!==task.stage_execution.expected_result_packet) throw new Error(JSON.stringify(task.runtime_guard));
if(task.machine.completed_stages.includes('evidence_scan')) throw new Error(JSON.stringify(task.machine));
if(out.must_continue!==true||out.continuation_policy!=='finish_authorized_workflow') throw new Error(JSON.stringify(out));
if(!/--range\s+['"]?101-150/.test(String(out.next_command||''))) throw new Error(JSON.stringify(out));
if(JSON.stringify(out.remaining_batch_ranges)!==JSON.stringify(['101-150','151-200'])) throw new Error(JSON.stringify(out));
NODE
    [ "$(cat "$TMP_DIR/book/正文/第001章.md")" = "正文不可修改" ]
    [ -f "$packet_dir/evidence_scan.batch-001.result.json" ]
    [ -f "$packet_dir/evidence_scan.batch-002.result.json" ]
    [ -f "$packet_dir/evidence_scan.batch-003.result.json" ]
    [ -f "$packet_dir/evidence_scan.batch-004.result.json" ]
}

@test "confirmed legacy evidence continuation records quality debt and advances to the next batch" {
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/wf-review-legacy"
    packet_dir="$task_dir/result-packets"
    mkdir -p "$packet_dir" "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/正文"
    printf '%s\n' '正文不可修改' > "$TMP_DIR/book/正文/第001章.md"
    cat > "$task_dir/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0","state_version":1,"workflow_id":"wf-review-legacy","workflow_type":"review_repair",
  "book_root":"BOOK_ROOT","task_dir":"追踪/workflow/tasks/wf-review-legacy","scope":"1-200","status":"running",
  "current_stage":"evidence_scan","current_step":"evidence_scan","completion_policy":"stage_then_confirm",
  "lifecycle":{"status":"active"},
  "machine":{"completed_stages":["range_lock"],"remaining_stages":["evidence_scan","classify_findings","repair_plan","closure"],"allowed_actions":["continue_next_stage","pause"]},
  "runtime_guard":{"heartbeat":{},"checkpoint_policy":{}},
  "review_batches":{"completed_count":0,"total_count":4,"next_batch_id":"001","aggregate_status":"running","batches":[
    {"id":"001","range":"1-50","status":"pending","accepted_result_packet":""},
    {"id":"002","range":"51-100","status":"pending","accepted_result_packet":""},
    {"id":"003","range":"101-150","status":"pending","accepted_result_packet":""},
    {"id":"004","range":"151-200","status":"pending","accepted_result_packet":""}
  ]},
  "review_batch_reacceptance":{"from_batch_id":"001","historical_packets":["追踪/workflow/tasks/wf-review-legacy/result-packets/evidence_scan.batch-001.result.json"]}
}
JSON
    sed -i '' "s|BOOK_ROOT|$TMP_DIR/book|" "$task_dir/task.json"
    cp "$task_dir/task.json" "$TMP_DIR/book/追踪/workflow/current-task.json"
    printf '%s\n' '{"step_status":"completed","outputs":["旧批次摘要"]}' > "$packet_dir/evidence_scan.batch-001.result.json"
    node "$SCRIPT" continue-review-with-legacy-evidence --project-root "$TMP_DIR/book" --workflow-id wf-review-legacy --confirm --json > "$TMP_DIR/legacy.json"
    node - "$TMP_DIR/legacy.json" "$task_dir/task.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='review_legacy_evidence_retained'||out.next_batch!=='51-100') throw new Error(JSON.stringify(out));
if(task.review_batches.completed_count!==1||task.review_batches.next_batch_id!=='002') throw new Error(JSON.stringify(task.review_batches));
if(task.review_batches.batches.map(x=>x.status).join(',')!=='completed_with_warning,pending,pending,pending') throw new Error(JSON.stringify(task.review_batches));
if(!task.review_quality_debt||task.review_quality_debt.status!=='legacy_evidence_accepted_with_warning') throw new Error(JSON.stringify(task.review_quality_debt));
if(JSON.stringify(task.review_quality_debt.ranges)!==JSON.stringify(['1-50'])) throw new Error(JSON.stringify(task.review_quality_debt));
if(task.review_quality_debt.require_final_recheck!==true||task.review_quality_debt.report_disclosure_required!==true) throw new Error(JSON.stringify(task.review_quality_debt));
if(task.stage_execution.batch_id!=='002'||task.stage_execution.batch_scope!=='51-100') throw new Error(JSON.stringify(task.stage_execution));
if(!task.stage_execution.expected_result_packet.endsWith('evidence_scan.batch-002.protocol-v2.result.json')) throw new Error(JSON.stringify(task.stage_execution));
if(out.must_continue!==true||!/--range\s+['"]?51-100/.test(String(out.next_command||''))) throw new Error(JSON.stringify(out));
NODE
    [ "$(cat "$TMP_DIR/book/正文/第001章.md")" = "正文不可修改" ]
}

@test "legacy evidence continuation requires explicit confirmation" {
    run node "$SCRIPT" continue-review-with-legacy-evidence --project-root "$TMP_DIR/book" --workflow-id wf-review-legacy --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_review_legacy_evidence_confirmation_required"* ]]
}

@test "confirmation stages reject missing expired or tampered workflow confirmation" {
    node - "$SCRIPT" "$TMP_DIR" <<'NODE'
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const script = process.argv[2];
const tmp = process.argv[3];

for (const mode of ['missing', 'expired', 'tampered']) {
  const project = path.join(tmp, `cover-confirmation-${mode}`);
  fs.mkdirSync(project, { recursive: true });
  run(['create', '--workflow-type', 'cover', '--project-root', project, '--user-goal', '生成新封面', '--json']);
  for (const stageId of ['cover_preflight', 'input_lock', 'visual_direction']) completeCurrentStage(project, stageId);
  let task = readTask(project);
  if (task.current_stage !== 'generation_confirmation') throw new Error(task.current_stage);

  if (mode === 'missing') {
    const rel = `${task.context_paths.result_packets_dir}/generation_confirmation.result.json`;
    const file = path.join(project, rel);
    writePacket(file, buildPacket(task, 'generation_confirmation', 'generation_confirmation', rel));
    expectBlocked(project, file, 'blocked_confirmation_required');
    continue;
  }

  const started = resolveFirst(project);
  task = readTask(project);
  if (mode === 'expired') task.stage_execution.confirmation_context.expires_at = '2000-01-01T00:00:00.000Z';
  if (mode === 'tampered') task.stage_execution.confirmation_context.confirmation_token = 'tampered-token';
  persistTask(project, task);
  const rel = started.stage_execution.expected_result_packet;
  const file = path.join(project, rel);
  writePacket(file, buildPacket(task, started.stage_execution.stage_id, started.stage_execution.step_id, rel));
  expectBlocked(project, file, 'blocked_confirmation_required');
}

function completeCurrentStage(project, expectedStage) {
  const started = resolveFirst(project);
  if (started.stage_execution.stage_id !== expectedStage) throw new Error(`${expectedStage} did not start`);
  const task = readTask(project);
  const rel = started.stage_execution.expected_result_packet;
  const file = path.join(project, rel);
  writePacket(file, buildPacket(task, started.stage_execution.stage_id, started.stage_execution.step_id, rel));
  run(['apply-result', '--project-root', project, '--result', file, '--json']);
}

function buildPacket(task, stageId, stepId, packetPath) {
  return {
    workflow_id: task.workflow_id, workflow_type: task.workflow_type,
    owner_module: task.stage_execution?.owner_module || 'story-cover',
    stage_id: stageId, step_id: stepId, step_status: 'completed',
    outputs: [], changed_files: [], evidence: [], verification_result: 'pass',
    checkpoint_state: {}, output_health_result: 'pass', result_packet_path: packetPath,
  };
}

function writePacket(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function readTask(project) {
  return require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(project);
}

function persistTask(project, task) {
  fs.writeFileSync(require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(project), `${JSON.stringify(task, null, 2)}\n`);
}

function run(args) {
  const result = cp.spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(`${args[0]} failed: ${result.stdout || result.stderr}`);
  return JSON.parse(result.stdout);
}

function resolveFirst(project) {
  const task = readTask(project);
  const pending = task.pending_action || {};
  return run(['resolve-action', '--project-root', project, '--input', '1', '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash, '--state-version', String(task.state_version), '--book-root', project, '--json']);
}

function expectBlocked(project, file, status) {
  const result = cp.spawnSync(process.execPath, [script, 'apply-result', '--project-root', project, '--result', file, '--json'], { encoding: 'utf8' });
  const out = JSON.parse(result.stdout);
  if (result.status !== 2 || out.status !== status) throw new Error(`expected ${status}, got ${result.status}: ${result.stdout || result.stderr}`);
}
NODE
}

@test "legacy result packets keep the explicit pre-v2 compatibility branch" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-legacy-v1",
  "workflow_type": "setup_update",
  "result_contract_version": 1,
  "current_stage": "version_check",
  "current_step": "legacy-version-step",
  "status": "running",
  "machine": {"completed_stages": [], "remaining_stages": ["version_check", "deployment_check", "refresh_runtime", "migration_decision", "verification"]}
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/legacy-result.json" <<'JSON'
{
  "workflow_id": "wf-legacy-v1",
  "workflow_type": "setup_update",
  "stage_id": "version_check",
  "step_id": "legacy-version-step",
  "step_status": "completed",
  "verification_result": "pass"
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/legacy-result.json" --json > "$TMP_DIR/legacy-out.json"

    grep -Eq '"status": "(advanced|stage_started)"' "$TMP_DIR/legacy-out.json"
    grep -q '"current_stage": "deployment_check"' "$TMP_DIR/legacy-out.json"
}

@test "workflow state machine flushes large template json through spawnSync" {
    node - "$SCRIPT" "$REPO" <<'NODE'
const cp = require('child_process');
const script = process.argv[2];
const cwd = process.argv[3];
const result = cp.spawnSync('node', [script, 'templates', '--json'], {
  cwd,
  encoding: 'utf8',
  maxBuffer: 10 * 1024 * 1024
});
if (result.status !== 0) {
  console.error(result.stderr || result.stdout);
  process.exit(1);
}
const parsed = JSON.parse(result.stdout);
if (!parsed.templates || parsed.templates.length < 10) process.exit(2);
NODE
}

@test "workflow state machine exposes complete new writing workflows" {
    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const byType = Object.fromEntries(data.templates.map((item) => [item.workflow_type, item]));

function assertStages(type, expected) {
  const flow = byType[type];
  if (!flow) throw new Error(`missing ${type}`);
  const ids = flow.stages.map((stage) => stage.stage_id);
  for (const id of expected) {
    if (!ids.includes(id)) throw new Error(`${type} missing ${id}: ${ids.join(',')}`);
  }
  return flow;
}

const long = assertStages('long_startup', [
  'project_type_lock',
  'market_positioning',
  'core_promise',
  'character_design',
  'plot_engine',
  'macro_outline',
  'volume_outline',
  'first_detail_outline',
  'start_ready_handoff',
]);
if (long.stages.some((stage) => stage.stage_id === 'prose')) throw new Error('long_startup must not write prose directly');
if (!long.stages.find((stage) => stage.stage_id === 'first_detail_outline').requires_user_confirm) {
  throw new Error('long_startup first_detail_outline must require user confirmation');
}

const short = assertStages('short_startup', [
  'project_type_lock',
  'material_source_choice',
  'material_card',
  'short_setting',
  'rhythm_pattern_selection',
  'section_outline',
  'section_plan_lock',
  'first_section_brief',
  'start_ready_handoff',
]);
if (short.stages.some((stage) => stage.stage_id === 'draft_section')) throw new Error('short_startup must stop before drafting');
if (!short.stages.find((stage) => stage.stage_id === 'section_plan_lock').requires_user_confirm) {
  throw new Error('short_startup section_plan_lock must require user confirmation');
}

const setup = assertStages('project_setup', [
  'project_type_lock',
  'runtime_setup',
  'directory_schema',
  'workflow_memory_init',
  'start_ready_handoff',
]);
if (setup.stages.some((stage) => stage.risk_level === 'high')) throw new Error('project_setup should not contain high-risk prose edits');
NODE
}

@test "workflow state machine applies private overlay registries generically" {
    mkdir -p "$TMP_DIR/private/private-short" "$TMP_DIR/private/private-download"
    cat > "$TMP_DIR/private/private-short/workflow-registry.json" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "private": true,
  "module": "private-short",
  "workflow_overrides": [
    {"workflow_type": "short_write", "owner_module": "private-short"}
  ]
}
JSON
    cat > "$TMP_DIR/private/private-download/workflow-registry.json" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "private": true,
  "module": "private-download",
  "workflow_overrides": [
    {"workflow_type": "download_import", "owner_module": "private-download"}
  ]
}
JSON

    node "$SCRIPT" templates --no-private-registry --private-registry-root "$TMP_DIR/private" --json > "$TMP_DIR/out.json"

    grep -q '"privateRegistryCount": 2' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "short_write"' "$TMP_DIR/out.json"
    grep -q '"owner_module": "private-short"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "download_import"' "$TMP_DIR/out.json"
    grep -q '"owner_module": "private-download"' "$TMP_DIR/out.json"
}

@test "workflow state machine routes short free text feedback into impact analysis" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "写短篇" --json >/dev/null

    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "这里不合理，人物动机要重做" --json > "$TMP_DIR/out.json"

    grep -q '"status": "short_feedback_impact_started"' "$TMP_DIR/out.json"
    grep -q '"target_stage": "feedback_impact_sync"' "$TMP_DIR/out.json"
    grep -q '"classification": "current_artifact_feedback"' "$TMP_DIR/out.json"
    grep -q '"action_id": "analyze_user_feedback"' "$TMP_DIR/out.json"
}

@test "workflow state machine returns lifecycle replan actions for natural language structure feedback" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --user-goal "写长篇" --json >/dev/null

    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "前期太快，插入一章过渡" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.classification !== 'scope_change') throw new Error(JSON.stringify(out));
if (out.impact_level !== 'detail_outline') throw new Error(JSON.stringify(out));
if (out.return_to !== 'stage_detail_outline') throw new Error(JSON.stringify(out));
if (out.preserve_chapter_names !== true) throw new Error(JSON.stringify(out));
if (!out.downstream_effects || out.downstream_effects.requires_impact_analysis !== true) {
  throw new Error(JSON.stringify(out));
}
NODE
}

@test "structure feedback persists impact metadata and replans without discarding accepted prose" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --user-goal "写长篇" --json >/dev/null

    node - "$TMP_DIR/book" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const taskFile = require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.current_stage = 'prose';
task.current_step = 'prose';
task.lifecycle_graph.current_node = 'prose';
task.lifecycle_graph.asset_target = task.lifecycle_graph.nodes.find(node => node.id === 'prose').asset_target;
task.lifecycle_graph.completed_nodes = task.lifecycle_graph.nodes.slice(0, 11).map(node => node.id);
for (const node of task.lifecycle_graph.nodes) {
  if (task.lifecycle_graph.completed_nodes.includes(node.id)) node.status = 'accepted';
}
fs.writeFileSync(taskFile, JSON.stringify(task, null, 2));
NODE

    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "把第1章和第2章合并" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'free_text_classified' || out.return_to !== 'stage_detail_outline') throw new Error(JSON.stringify(out));
if (task.current_stage !== 'stage_detail_outline' || task.lifecycle_graph.current_node !== 'stage_detail_outline') throw new Error(JSON.stringify(task));
if (!task.lifecycle_impact || task.lifecycle_impact.impact_level !== 'detail_outline') throw new Error(JSON.stringify(task.lifecycle_impact));
if (!task.replan_metadata || task.replan_metadata.return_to !== 'stage_detail_outline') throw new Error(JSON.stringify(task.replan_metadata));
if (!task.lifecycle_impact.downstream_effects || !task.lifecycle_impact.downstream_effects.changed_asset) throw new Error(JSON.stringify(task.lifecycle_impact));
const prose = task.lifecycle_graph.nodes.find(node => node.id === 'prose');
if (!prose || prose.status !== 'accepted') throw new Error(`accepted prose was discarded: ${JSON.stringify(prose)}`);
if (!task.lifecycle_impact.downstream_effects.preserve_until_proven_invalid.includes('prose')) throw new Error(JSON.stringify(task.lifecycle_impact));
NODE
}

@test "workflow stage execution records the professional owner and risk boundary" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "写短篇" --json >/dev/null

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.stage_execution.owner_module !== 'private-short-extension') throw new Error(JSON.stringify(out.stage_execution));
if (out.stage_execution.risk_level !== 'low') throw new Error(JSON.stringify(out.stage_execution));
if (out.stage_execution.requires_user_confirm !== false) throw new Error(JSON.stringify(out.stage_execution));
NODE
}

@test "workflow state machine classifies obvious new intent and keeps current task resumable" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "写短篇" --json >/dev/null

    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "先别写，审阅 1-200 章" --json > "$TMP_DIR/out.json"

    grep -q '"status": "free_text_classified"' "$TMP_DIR/out.json"
    grep -q '"classification": "switch_intent"' "$TMP_DIR/out.json"
    grep -q '"recommended_action": "call_switch_intent"' "$TMP_DIR/out.json"
    grep -q '"suggested_workflow_type": "review_repair"' "$TMP_DIR/out.json"
    grep -q '"must_not_bind_to_pending_number": true' "$TMP_DIR/out.json"
    grep -q '"status": "running"' "$(focused_task_file "$TMP_DIR/book")"
}

@test "workflow state machine task markdown avoids raw engineering jargon in visible summary" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-200" --user-goal "审阅 1-200 章" --json >/dev/null

    grep -q "当前任务记录" "$TMP_DIR/book/追踪/workflow/current-task.md"
    grep -q "下一步候选" "$TMP_DIR/book/追踪/workflow/current-task.md"
    ! grep -q "current-task.json" "$TMP_DIR/book/追踪/workflow/current-task.md"
    ! grep -q "pending_action" "$TMP_DIR/book/追踪/workflow/current-task.md"
    ! grep -q "runtime_guard" "$TMP_DIR/book/追踪/workflow/current-task.md"
}

@test "workflow state machine creates Trellis style task directory with RPD context verify and journal" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-200" --user-goal "审阅 1-200 章情节连贯与钩子回收" --json > "$TMP_DIR/out.json"

    task_id="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(data.task.workflow_id)' "$TMP_DIR/out.json")"
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/$task_id"

    [ -d "$task_dir" ]
    [ -d "$task_dir/result-packets" ]
    [ -d "$task_dir/artifacts" ]
    [ -f "$task_dir/task.json" ]
    [ -f "$task_dir/rpd.md" ]
    [ -f "$task_dir/context.jsonl" ]
    [ -f "$task_dir/verify.jsonl" ]
    [ -f "$task_dir/journal.jsonl" ]

    grep -q '"task_dir": "追踪/workflow/tasks/' "$TMP_DIR/out.json"
    grep -q '"task_dir"' "$TMP_DIR/book/追踪/workflow/current-task.json"
    grep -q '"rpd_path": "追踪/workflow/tasks/' "$task_dir/task.json"
    grep -q "任务需求与读者承诺文档" "$task_dir/rpd.md"
    grep -q "审阅 1-200 章情节连贯与钩子回收" "$task_dir/rpd.md"
    grep -q "读者承诺" "$task_dir/rpd.md"
    grep -q "验收标准" "$task_dir/rpd.md"
    grep -q '"kind":"workflow_state"' "$task_dir/context.jsonl"
    grep -q '"kind":"rpd"' "$task_dir/context.jsonl"
    grep -q '"kind":"state_machine"' "$task_dir/verify.jsonl"
    grep -q '"event":"created"' "$task_dir/journal.jsonl"
    assert_pointer_matches_task "$TMP_DIR/book"
}

@test "workflow state machine keeps task directory in sync after numbered selection and result" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-200" --user-goal "审阅 1-200 章" --json > "$TMP_DIR/create.json"
    task_id="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(data.task.workflow_id)' "$TMP_DIR/create.json")"
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/$task_id"

    resolve_action "$TMP_DIR/book" 1 >/dev/null

    grep -q '"last_selection"' "$task_dir/task.json"
    grep -q '"event":"resolved_action"' "$task_dir/journal.jsonl"

    result_file="$task_dir/result-packets/range_lock.result.json"
    mkdir -p "$(dirname "$result_file")"
    cat > "$result_file" <<JSON
{
  "workflow_id": "$task_id",
  "workflow_type": "review_repair",
  "owner_module": "story-workflow",
  "stage_id": "range_lock",
  "step_id": "range_lock",
  "step_status": "completed",
  "outputs": [],
  "evidence": [],
  "verification_result": "pass",
  "checkpoint_state": {"completed_stage":"range_lock"},
  "output_health_result": "pass",
  "changed_files": [],
  "created_files": [],
  "next_recommendation": ["继续扫描证据"]
}
JSON
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$result_file" --json > "$TMP_DIR/apply.json"

    grep -q '"current_stage": "evidence_scan"' "$task_dir/task.json"
    grep -q '"event":"applied_result"' "$task_dir/journal.jsonl"
    assert_pointer_matches_task "$TMP_DIR/book"
}

@test "workflow state machine locks stage execution before long reads so recap cannot revert to awaiting confirm" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-200" --user-goal "补 1-200 章逐章细纲" --json > "$TMP_DIR/create.json"
    task_id="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(data.task.workflow_id)' "$TMP_DIR/create.json")"
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/$task_id"

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/resolve.json"

    node -e '
const fs = require("fs");
const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const task = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (out.status !== "stage_started") process.exit(1);
if (!out.stage_execution || out.stage_execution.status !== "running") process.exit(2);
if (!out.stage_execution.expected_result_packet) process.exit(3);
if (task.stage_execution.status !== "running") process.exit(4);
if (task.stage_execution.stage_id !== task.current_stage) process.exit(5);
if (task.machine.last_transition !== "stage_started") process.exit(6);
if (task.machine.next_stop_reason !== "stage_running_waiting_result_packet") process.exit(7);
if (task.pending_action.status !== "resolved") process.exit(8);
if (task.runtime_guard.heartbeat.current_batch !== task.current_stage) process.exit(9);
if (task.runtime_guard.heartbeat.latest_trusted_artifact === task.stage_execution.expected_result_packet) process.exit(10);
if (task.runtime_guard.checkpoint_policy.expected_result_packet !== task.stage_execution.expected_result_packet) process.exit(11);
if (!task.runtime_guard.heartbeat.latest_trusted_artifact) process.exit(12);
' "$TMP_DIR/resolve.json" "$task_dir/task.json"

    grep -q '"event":"stage_started"' "$task_dir/journal.jsonl"
    grep -q "当前执行阶段" "$TMP_DIR/book/追踪/workflow/current-task.md"
    grep -q "等待 result packet" "$TMP_DIR/book/追踪/workflow/current-task.md"
    assert_pointer_matches_task "$TMP_DIR/book"
}

@test "workflow state machine switch intent preserves old task directory without losing RPD" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "写短篇《480万红本》" --json > "$TMP_DIR/create.json"
    old_id="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(data.task.workflow_id)' "$TMP_DIR/create.json")"
    old_dir="$TMP_DIR/book/追踪/workflow/tasks/$old_id"

    node "$SCRIPT" switch-intent --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-200" --user-goal "先审阅 1-200 章" --reason manual_new_goal --json > "$TMP_DIR/switch.json"

    [ -f "$old_dir/task.json" ]
    [ -f "$old_dir/rpd.md" ]
    grep -q '"status": "paused"' "$old_dir/task.json"
    ! grep -q '"status": "superseded"' "$old_dir/task.json"
    grep -q '"event":"focus_paused"' "$old_dir/journal.jsonl"
    grep -q "写短篇《480万红本》" "$old_dir/rpd.md"

    new_id="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(data.task.workflow_id)' "$TMP_DIR/switch.json")"
    [ -f "$TMP_DIR/book/追踪/workflow/tasks/$new_id/task.json" ]
    grep -q "$new_id" "$TMP_DIR/book/追踪/workflow/current-task.json"
}

@test "workflow state machine templates expose task centric workflow design markers" {
    grep -q "task-inbox-protocol.md" "$WORKFLOW"
    grep -q "任务中心" "$WORKFLOW_INBOX"
    grep -q "任务记忆" "$WORKFLOW_INBOX"
    grep -q "自由反馈" "$WORKFLOW_INBOX"
    grep -q "用户反馈必须先分类" "$WORKFLOW_INBOX"
    grep -q "专业模块只装配上下文" "$WORKFLOW_INBOX"
    grep -q "RPD 与任务目录持久化" "$WORKFLOW_INBOX"
    grep -q "任务需求与读者承诺文档" "$WORKFLOW_INBOX"
    grep -q "workflow-task-inbox.js.*tasks/\\*/task.json" "$WORKFLOW_INBOX"
    grep -q "durable task directory" "$CONTRACT"
    grep -q "task.json.*rpd.md.*context.jsonl.*verify.jsonl.*journal.jsonl" "$CONTRACT"
}

@test "private shortform overlay fully owns local short workflow while public mode stays public" {
    mkdir -p "$TMP_DIR/private/private-short-extension"
    cat > "$TMP_DIR/private/private-short-extension/workflow-registry.json" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "private": true,
  "module": "private-short-extension",
  "workflow_overrides": [
    {
      "workflow_type": "short_write",
      "owner_module": "private-short-extension"
    }
  ]
}
JSON

    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/public.json"
    node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const short = data.templates.find((item) => item.workflow_type === "short_write");
for (const stage of short.stages) {
  const expected = stage.stage_id === "full_story_review"
    ? "story-review"
    : ["project_type_lock", "feedback_impact_sync"].includes(stage.stage_id) ? "story-workflow" : "story-short-write";
  if (stage.owner_module !== expected) throw new Error(`${stage.stage_id} should stay public ${expected}`);
}
' "$TMP_DIR/public.json"

    node "$SCRIPT" templates --no-private-registry --private-registry-root "$TMP_DIR/private" --json > "$TMP_DIR/out.json"

    node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const short = data.templates.find((item) => item.workflow_type === "short_write");
const owner = Object.fromEntries(short.stages.map((stage) => [stage.stage_id, stage.owner_module]));
if (owner.material_card !== "private-short-extension") throw new Error("material_card owner mismatch");
if (owner.short_setting !== "private-short-extension") throw new Error("short_setting owner mismatch");
if (owner.rhythm_pattern_selection !== "private-short-extension") throw new Error("rhythm_pattern_selection owner mismatch");
if (owner.section_outline !== "private-short-extension") throw new Error("section_outline owner mismatch");
if (owner.section_brief !== "private-short-extension") throw new Error("section_brief must be private private-short-extension");
if (owner.draft_section !== "private-short-extension") throw new Error("draft_section must be private private-short-extension");
if (owner.section_machine_gate !== "private-short-extension") throw new Error("section_machine_gate must be private private-short-extension");
if (owner.story_value_gate !== "private-short-extension") throw new Error("story_value_gate must be private private-short-extension");
if (owner.deslop !== "private-short-extension") throw new Error("deslop must be private private-short-extension");
if (owner.final_check !== "private-short-extension") throw new Error("final_check must be private private-short-extension");
' "$TMP_DIR/out.json"
}

@test "new short tasks keep one workflow identity and select the installed owner profile" {
    mkdir -p "$TMP_DIR/private/private-short-extension" "$TMP_DIR/public-book" "$TMP_DIR/private-book"
    cp "$REPO/src/private-internal-skills/private-short-extension/workflow-registry.json" "$TMP_DIR/private/private-short-extension/workflow-registry.json"

    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/public-book" --no-private-registry --json > "$TMP_DIR/public-create.json"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/private-book" --no-private-registry --private-registry-root "$TMP_DIR/private" --json > "$TMP_DIR/private-create.json"
    node "$SCRIPT" templates --no-private-registry --private-registry-root "$TMP_DIR/private" --json > "$TMP_DIR/private-templates.json"

    grep -q '"workflow_type": "short_write"' "$TMP_DIR/public-create.json"
    grep -q '"workflow_profile": "public"' "$TMP_DIR/public-create.json"
    grep -q '"workflow_owner": "story-short-write"' "$TMP_DIR/public-create.json"
    grep -q '"current_stage": "project_type_lock"' "$TMP_DIR/public-create.json"
    grep -q '"workflow_type": "short_write"' "$TMP_DIR/private-create.json"
    grep -q '"workflow_profile": "private"' "$TMP_DIR/private-create.json"
    grep -q '"workflow_owner": "private-short-extension"' "$TMP_DIR/private-create.json"
    grep -q '"current_stage": "startup_scan"' "$TMP_DIR/private-create.json"
    ! grep -q '"workflow_type": "private_short_startup"' "$TMP_DIR/private-create.json"
    run node "$SCRIPT" create --workflow-type private_short_startup --project-root "$TMP_DIR/private-book-alias" --no-private-registry --private-registry-root "$TMP_DIR/private" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'"status": "blocked_legacy_workflow_alias"'* ]]
    node - "$TMP_DIR/private-templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const short = data.templates.find((item) => item.workflow_type === 'short_write');
if (short.private_overlay.mode !== 'enhance') throw new Error('private short workflow must enhance the public baseline');
if (short.private_overlay.base_workflow_type !== 'short_write') throw new Error('private short baseline identity mismatch');
NODE
}

@test "private shortform startup workflow is explicit and UI friendly" {
    mkdir -p "$TMP_DIR/private/private-short-extension"
    cat > "$TMP_DIR/private/private-short-extension/workflow-registry.json" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "private": true,
  "module": "private-short-extension",
  "workflow_templates": [
    {
      "workflow_type": "private_short_startup",
      "owner_module": "private-short-extension",
      "default_completion_policy": "stage_then_confirm",
      "safe_full_auto": false,
      "stages": [
        {
          "stage_id": "startup_scan",
          "label": "检查未完成短篇项目",
          "description": "只读扫描短篇项目、素材卡、分叉和断点，不写正文。",
          "frontend_surface": "short_project_list",
          "required_inputs": [],
          "allowed_next": ["startup_menu"],
          "risk_level": "low"
        },
        {
          "stage_id": "material_learning",
          "label": "抓取或学习新鲜素材",
          "description": "生成 6-10 张脑洞卡片，不写正文。",
          "frontend_surface": "brainstorm_card_pool",
          "required_inputs": ["startup_scan"],
          "allowed_next": ["project_seed"],
          "risk_level": "medium"
        },
        {
          "stage_id": "draft",
          "label": "写正文",
          "description": "基于设定和小节大纲分批写正文。",
          "frontend_surface": "short_draft_editor",
          "required_inputs": ["project_seed"],
          "allowed_next": [],
          "requires_user_confirm": true,
          "risk_level": "high"
        }
      ]
    }
  ]
}
JSON

    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/public.json"
    ! grep -q '"workflow_type": "private_short_startup"' "$TMP_DIR/public.json"

    node "$SCRIPT" templates --no-private-registry --private-registry-root "$TMP_DIR/private" --json > "$TMP_DIR/out.json"
    grep -q '"workflow_type": "private_short_startup"' "$TMP_DIR/out.json"
    grep -q '"owner_module": "private-short-extension"' "$TMP_DIR/out.json"
    grep -q '"label": "抓取或学习新鲜素材"' "$TMP_DIR/out.json"
    grep -q '"frontend_surface": "brainstorm_card_pool"' "$TMP_DIR/out.json"

    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type private_short_startup --project-root "$TMP_DIR/book" --private-registry-root "$TMP_DIR/private" --no-private-registry --json > "$TMP_DIR/create.json"
    grep -q '"label": "继续检查未完成短篇项目（推荐）"' "$TMP_DIR/create.json"
    grep -q '"frontend_surface": "short_project_list"' "$TMP_DIR/create.json"
    task_file="$(focused_task_file "$TMP_DIR/book")"
    grep -q '"runtime_guard"' "$task_file"
    grep -q '"checkpoint_path": "追踪/workflow/tasks/' "$task_file"
}

@test "real private shortform workflow requires hook retention before drafting" {
    node "$SCRIPT" templates --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const flow = data.templates.find((item) => item.workflow_type === 'short_write');
if (!flow || flow.private_overlay?.module !== 'private-short-extension') throw new Error('missing active private short_write workflow');
const stages = Object.fromEntries(flow.stages.map((stage) => [stage.stage_id, stage]));
  for (const id of ['freshness_window', 'info_source_pool', 'short_setting', 'platform_genre_lock', 'rhythm_pattern_selection', 'section_outline', 'section_plan_lock', 'short_structure_impact_audit', 'hook_retention_gate', 'first_section_brief', 'draft_first_section', 'section_machine_gate', 'section_repair_loop', 'quality_gate', 'section_candidate_compare', 'section_accept_anchor', 'next_section_brief', 'draft_next_section', 'full_story_assembly']) {
    if (!stages[id]) throw new Error(`missing ${id}`);
  }
  if (!stages.startup_menu.allowed_next.includes('freshness_window') || stages.startup_menu.allowed_next.includes('info_source_pool')) {
    throw new Error(`startup_menu must ask for time window before fetching: ${JSON.stringify(stages.startup_menu.allowed_next)}`);
  }
  if (!stages.freshness_window.requires_user_confirm || !stages.freshness_window.allowed_next.includes('info_source_pool')) {
    throw new Error(`freshness_window must be a visible confirmation stage: ${JSON.stringify(stages.freshness_window)}`);
  }
  if (!/24 小时/.test(stages.freshness_window.description) || !/3 天/.test(stages.freshness_window.description) || !/7 天/.test(stages.freshness_window.description)) {
    throw new Error(`freshness_window options are incomplete: ${stages.freshness_window.description}`);
  }
  if (!stages.info_source_pool.required_inputs.includes('freshness_window')) {
    throw new Error(`info_source_pool must require freshness_window: ${JSON.stringify(stages.info_source_pool.required_inputs)}`);
  }
  if (!stages.short_setting.allowed_next.includes('platform_genre_lock')) {
    throw new Error(`short_setting must go to platform_genre_lock: ${JSON.stringify(stages.short_setting.allowed_next)}`);
  }
  if (!stages.platform_genre_lock.required_inputs.includes('short_setting') || !stages.platform_genre_lock.requires_user_confirm) {
    throw new Error(`platform_genre_lock contract invalid: ${JSON.stringify(stages.platform_genre_lock)}`);
  }
  if (!stages.platform_genre_lock.allowed_next.includes('rhythm_pattern_selection')) {
    throw new Error(`platform_genre_lock must go to rhythm_pattern_selection: ${JSON.stringify(stages.platform_genre_lock.allowed_next)}`);
  }
  if (!stages.rhythm_pattern_selection.required_inputs.includes('platform_genre_lock')) {
    throw new Error(`rhythm_pattern_selection must require platform_genre_lock: ${JSON.stringify(stages.rhythm_pattern_selection.required_inputs)}`);
  }
  if (!stages.rhythm_pattern_selection.allowed_next.includes('section_outline')) {
    throw new Error(`rhythm_pattern_selection must go to section_outline: ${JSON.stringify(stages.rhythm_pattern_selection.allowed_next)}`);
  }
  if (!/节奏/.test(stages.rhythm_pattern_selection.description) || !/爽点/.test(stages.rhythm_pattern_selection.description) || !/反转/.test(stages.rhythm_pattern_selection.description)) {
    throw new Error(`rhythm_pattern_selection description too weak: ${stages.rhythm_pattern_selection.description}`);
  }
  if (!stages.section_outline.required_inputs.includes('rhythm_pattern_selection')) {
    throw new Error(`section_outline must require rhythm_pattern_selection: ${JSON.stringify(stages.section_outline.required_inputs)}`);
  }
  if (!stages.section_outline.allowed_next.includes('section_plan_lock')) {
    throw new Error(`section_outline must go to section_plan_lock: ${JSON.stringify(stages.section_outline.allowed_next)}`);
  }
  if (!stages.section_plan_lock.required_inputs.includes('section_outline')) {
    throw new Error(`section_plan_lock must require section_outline: ${JSON.stringify(stages.section_plan_lock.required_inputs)}`);
  }
  if (!/总小节/.test(stages.section_plan_lock.description) || !/全篇完成/.test(stages.section_plan_lock.description)) {
    throw new Error(`section_plan_lock description must lock total sections and completion branch: ${stages.section_plan_lock.description}`);
  }
  if (!stages.section_plan_lock.allowed_next.includes('short_structure_impact_audit')) {
    throw new Error(`section_plan_lock must go to short_structure_impact_audit: ${JSON.stringify(stages.section_plan_lock.allowed_next)}`);
  }
  if (!stages.short_structure_impact_audit.required_inputs.includes('section_plan_lock')) {
    throw new Error(`short_structure_impact_audit must require section_plan_lock: ${JSON.stringify(stages.short_structure_impact_audit.required_inputs)}`);
  }
  for (const word of ['素材卡', '设定', '小节大纲', 'Brief', '采用锚点', '扩容', '缩容']) {
    if (!stages.short_structure_impact_audit.description.includes(word)) {
      throw new Error(`short_structure_impact_audit description must mention ${word}: ${stages.short_structure_impact_audit.description}`);
    }
  }
  if (!stages.short_structure_impact_audit.allowed_next.includes('hook_retention_gate')) {
    throw new Error(`short_structure_impact_audit must go to hook_retention_gate: ${JSON.stringify(stages.short_structure_impact_audit.allowed_next)}`);
  }
  if (!stages.hook_retention_gate.required_inputs.includes('short_structure_impact_audit')) {
    throw new Error(`hook_retention_gate must require short_structure_impact_audit: ${JSON.stringify(stages.hook_retention_gate.required_inputs)}`);
  }
  if (!stages.hook_retention_gate.allowed_next.includes('first_section_brief')) {
    throw new Error(`hook_retention_gate must go to first_section_brief: ${JSON.stringify(stages.hook_retention_gate.allowed_next)}`);
  }
  if (!stages.first_section_brief.required_inputs.includes('hook_retention_gate')) {
    throw new Error(`first_section_brief must require hook_retention_gate: ${JSON.stringify(stages.first_section_brief.required_inputs)}`);
  }
  if (stages.first_section_brief.requires_user_confirm) throw new Error('first brief generation must be internal; user confirms the resulting prose action');
  if (!stages.draft_first_section.required_inputs.includes('first_section_brief')) {
    throw new Error(`draft_first_section must require first_section_brief: ${JSON.stringify(stages.draft_first_section.required_inputs)}`);
  }
  if (!stages.draft_first_section.allowed_next.includes('section_machine_gate')) {
    throw new Error(`draft_first_section must go to section_machine_gate: ${JSON.stringify(stages.draft_first_section.allowed_next)}`);
  }
  if (!stages.section_machine_gate.required_inputs.includes('current_section_draft')) {
    throw new Error(`section_machine_gate must require current_section_draft: ${JSON.stringify(stages.section_machine_gate.required_inputs)}`);
  }
  if (!/short-section-machine-gate\.js/.test(stages.section_machine_gate.description) || !/不得拆开调用检查器/.test(stages.section_machine_gate.description)) {
    throw new Error(`section_machine_gate must use the unified deterministic gate: ${stages.section_machine_gate.description}`);
  }
  if (!stages.section_machine_gate.allowed_next.includes('quality_gate')) {
    throw new Error(`section_machine_gate must go to quality_gate after pass: ${JSON.stringify(stages.section_machine_gate.allowed_next)}`);
  }
  if (!stages.section_machine_gate.allowed_next.includes('section_repair_loop')) {
    throw new Error(`section_machine_gate must go to section_repair_loop after blocking: ${JSON.stringify(stages.section_machine_gate.allowed_next)}`);
  }
  if (!stages.section_repair_loop.required_inputs.includes('section_machine_gate')) {
    throw new Error(`section_repair_loop must require section_machine_gate: ${JSON.stringify(stages.section_repair_loop.required_inputs)}`);
  }
  if (!stages.section_repair_loop.allowed_next.includes('section_machine_gate')) {
    throw new Error(`section_repair_loop must return to section_machine_gate: ${JSON.stringify(stages.section_repair_loop.allowed_next)}`);
  }
  if (!stages.quality_gate.required_inputs.includes('section_machine_gate')) {
    throw new Error(`quality_gate must require section_machine_gate: ${JSON.stringify(stages.quality_gate.required_inputs)}`);
  }
  if (stages.quality_gate.allowed_next.includes('next_section_brief')) {
    throw new Error(`quality_gate must not directly unlock next_section_brief: ${JSON.stringify(stages.quality_gate.allowed_next)}`);
  }
  if (stages.quality_gate.requires_user_confirm) {
    throw new Error('quality_gate must run as an internal section acceptance check');
  }
  if (!stages.quality_gate.allowed_next.includes('section_accept_anchor') || !stages.quality_gate.allowed_next.includes('section_candidate_compare')) {
    throw new Error(`quality_gate must support direct acceptance and optional comparison: ${JSON.stringify(stages.quality_gate.allowed_next)}`);
  }
  if (!stages.section_candidate_compare.required_inputs.includes('quality_gate')) {
    throw new Error(`section_candidate_compare must require quality_gate: ${JSON.stringify(stages.section_candidate_compare.required_inputs)}`);
  }
  if (!stages.section_candidate_compare.allowed_next.includes('section_accept_anchor')) {
    throw new Error(`section_candidate_compare must go to section_accept_anchor: ${JSON.stringify(stages.section_candidate_compare.allowed_next)}`);
  }
  if (!stages.section_accept_anchor.required_inputs.includes('quality_gate')) {
    throw new Error(`section_accept_anchor must require accepted quality gate: ${JSON.stringify(stages.section_accept_anchor.required_inputs)}`);
  }
  if (!stages.section_accept_anchor.allowed_next.includes('next_section_brief')) {
    throw new Error(`section_accept_anchor must unlock next_section_brief: ${JSON.stringify(stages.section_accept_anchor.allowed_next)}`);
  }
  if (!stages.section_accept_anchor.allowed_next.includes('full_story_assembly')) {
    throw new Error(`section_accept_anchor must unlock full_story_assembly when all sections are done: ${JSON.stringify(stages.section_accept_anchor.allowed_next)}`);
  }
  if (!stages.next_section_brief.required_inputs.includes('section_accept_anchor')) {
    throw new Error(`next_section_brief must require section_accept_anchor: ${JSON.stringify(stages.next_section_brief.required_inputs)}`);
  }
  if (stages.next_section_brief.requires_user_confirm) throw new Error('next brief generation must be internal and stop before prose');
  if (!stages.draft_next_section.required_inputs.includes('next_section_brief')) {
    throw new Error(`draft_next_section must require next_section_brief: ${JSON.stringify(stages.draft_next_section.required_inputs)}`);
  }
  if (!stages.draft_next_section.allowed_next.includes('section_machine_gate')) {
    throw new Error(`draft_next_section must return to section_machine_gate: ${JSON.stringify(stages.draft_next_section.allowed_next)}`);
  }
  if (!stages.full_story_assembly.required_inputs.includes('section_accept_anchor')) {
    throw new Error(`full_story_assembly must require last section accept anchor: ${JSON.stringify(stages.full_story_assembly.required_inputs)}`);
  }
  if (!stages.full_story_assembly.allowed_next.includes('full_story_review')) {
    throw new Error(`full_story_assembly must go to full_story_review: ${JSON.stringify(stages.full_story_assembly.allowed_next)}`);
  }
  if (!stages.full_story_review.allowed_next.includes('short_deslop') || !stages.full_story_review.allowed_next.includes('feedback_impact_sync')) {
    throw new Error(`full_story_review must pass to deslop or return to feedback: ${JSON.stringify(stages.full_story_review.allowed_next)}`);
  }
  if (stages.hook_retention_gate.frontend_surface !== 'short_quality_panel') {
    throw new Error(`hook gate frontend mismatch: ${stages.hook_retention_gate.frontend_surface}`);
  }
if (!/3-5/.test(stages.hook_retention_gate.description) || !/黄金阅读/.test(stages.hook_retention_gate.description)) {
  throw new Error(`hook gate description too weak: ${stages.hook_retention_gate.description}`);
}
NODE
}

@test "private shortform visible workflow has no dangling stage references" {
    node "$SCRIPT" templates --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const flow = data.templates.find((item) => item.workflow_type === 'private_short_startup');
if (!flow) throw new Error('missing private_short_startup workflow');
const stageIds = new Set(flow.stages.map((stage) => stage.stage_id));
const externalInputs = new Set(['current_section_draft']);
for (const stage of flow.stages) {
  for (const next of stage.allowed_next || []) {
    if (!stageIds.has(next)) throw new Error(`${stage.stage_id}.allowed_next references missing stage ${next}`);
  }
  for (const input of stage.required_inputs || []) {
    if (!stageIds.has(input) && !externalInputs.has(input)) {
      throw new Error(`${stage.stage_id}.required_inputs references missing stage/input ${input}`);
    }
  }
}
const material = flow.stages.find((stage) => stage.stage_id === 'material_learning');
if (JSON.stringify(material.allowed_next) !== JSON.stringify(['project_seed'])) {
  throw new Error(`material_learning must stop at card pool before project_seed only: ${JSON.stringify(material.allowed_next)}`);
}
const deslop = flow.stages.find((stage) => stage.stage_id === 'short_deslop');
if (!deslop.required_inputs.includes('full_story_review')) {
  throw new Error(`short_deslop must require full_story_review: ${JSON.stringify(deslop.required_inputs)}`);
}
if (deslop.required_inputs.includes('draft')) {
  throw new Error('short_deslop must not depend on dangling draft stage');
}
const planLock = flow.stages.find((stage) => stage.stage_id === 'section_plan_lock');
if (!/扩容/.test(planLock.description) || !/缩容/.test(planLock.description) || !/合并/.test(planLock.description) || !/删节/.test(planLock.description)) {
  throw new Error(`section_plan_lock must cover expansion/merge/delete: ${planLock.description}`);
}
const feedback = flow.stages.find((stage) => stage.stage_id === 'feedback_impact_sync');
if (JSON.stringify(feedback.allowed_next) !== JSON.stringify(['feedback_apply_patch'])) {
  throw new Error(`feedback impact analysis must stop before creative writes: ${JSON.stringify(feedback.allowed_next)}`);
}
const feedbackApply = flow.stages.find((stage) => stage.stage_id === 'feedback_apply_patch');
if (!feedbackApply) throw new Error('missing feedback_apply_patch stage');
for (const expected of ['section_repair_loop', 'first_section_brief', 'next_section_brief', 'short_setting', 'section_outline', 'section_plan_lock']) {
  if (!feedbackApply.allowed_next.includes(expected)) {
    throw new Error(`feedback_apply_patch missing ${expected}: ${JSON.stringify(feedbackApply.allowed_next)}`);
  }
}
NODE
}

@test "short feedback patch cannot bypass upstream planning" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-feedback",
  "workflow_type": "private_short_startup",
  "workflow_profile": "private",
  "workflow_owner": "private-short-extension",
  "scope": "第2节",
  "current_stage": "feedback_apply_patch",
  "current_step": "feedback_apply_patch",
  "status": "running",
  "pending_feedback": {
    "feedback_id": "feedback-plan-001",
    "received_at": "2026-07-20T00:00:00.000Z",
    "text": "调整人物动机并同步设定与小节大纲。"
  },
  "short_feedback_impact": {
    "impact_level": "planning"
  },
  "machine": {
    "completed_stages": ["quality_gate", "feedback_impact_sync"],
    "remaining_stages": ["feedback_apply_patch", "section_outline", "section_plan_lock", "next_section_brief", "draft_next_section"]
  }
}

JSON
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    printf '%s\n' '{"project_id":"short-feedback-project","project_title":"果汁事件","plan_revision":2}' > "$TMP_DIR/book/追踪/private-short-extension/project-state.json"
    printf '%s\n' '旧设定。' > "$TMP_DIR/book/设定.md"
    printf '%s\n' \
      '# 小节大纲' \
      '- 总小节数：2节' \
      '- 目标总字数：3000-4000字' \
      '- 发布形态：短篇单篇合并稿' \
      '## 第1节：开场' \
      '- 结构功能：建立冲突并留下承接钩子。' \
      '## 第2节：调整' \
      '- 结构功能：完成高潮、责任后果与终局收束。' > "$TMP_DIR/book/小节大纲.md"
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/invalid-feedback.json" <<'JSON'
{
  "workflow_id": "wf-short-feedback",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "feedback_apply_patch",
  "step_id": "feedback_apply_patch",
  "step_status": "completed",
  "verification_result": "pass",
  "feedback_id": "feedback-plan-001",
  "impact_level": "planning",
  "changed_assets": ["设定.md", "小节大纲.md"],
  "brief_invalidated": false,
  "next_stage_id": "section_repair_loop",
  "changed_files": ["设定.md", "小节大纲.md"]
}
JSON
    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/invalid-feedback.json" --json
    [ "$status" -eq 2 ]
    printf '%s' "$output" | grep -q 'blocked_feedback_impact_contract'

    cat > "$TMP_DIR/valid-feedback.json" <<'JSON'
{
  "workflow_id": "wf-short-feedback",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "feedback_apply_patch",
  "step_id": "feedback_apply_patch",
  "step_status": "completed",
  "verification_result": "pass",
  "feedback_id": "feedback-plan-001",
  "impact_level": "planning",
  "changed_assets": ["设定.md", "小节大纲.md"],
  "affected_sections": [1, 2],
  "downstream_impact": {"invalidate_briefs": [1, 2], "recheck_prose": [1, 2]},
  "brief_invalidated": true,
  "changed_files": ["设定.md", "小节大纲.md"]
}
JSON
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/valid-feedback.json" --json > "$TMP_DIR/valid-feedback-out.json"
    node - "$TMP_DIR/valid-feedback-out.json" "$(focused_task_file "$TMP_DIR/book")" "$TMP_DIR/book/追踪/integration/outbox.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.current_stage!=='section_plan_lock' || task.current_stage!=='section_plan_lock') throw new Error(JSON.stringify(out));
if(!task.feedback_revision_queue||task.feedback_revision_queue.current_section_index!==1||task.feedback_revision_queue.items.length!==2||task.scope!=='全篇'||task.unit_lifecycle.current_scope!=='全篇') throw new Error(JSON.stringify({queue:task.feedback_revision_queue,scope:task.scope,unit:task.unit_lifecycle}));
const events=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
if(events.length!==1||events[0].event_type!=='user_feedback_accepted'||events[0].workflow_id!=='wf-short-feedback'||events[0].project_id!=='short-feedback-project') throw new Error(JSON.stringify(events));
NODE

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/section-plan-lock-start.json"
    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const execution=task.stage_execution||{};
if(task.current_stage!=='section_plan_lock'||execution.status!=='running') throw new Error(JSON.stringify(task));
if(!/short-section-title-lock\.js/.test(String(execution.execution_command||''))) throw new Error(JSON.stringify(execution));
if(String(execution.context_read_command||'')) throw new Error(`section_plan_lock must not request a nonexistent context packet: ${JSON.stringify(execution)}`);
if(!/标题/.test(String(execution.resume_hint||''))) throw new Error(JSON.stringify(execution));
NODE

    workflow_id="$(jq -r '.workflow_id' "$(focused_task_file "$TMP_DIR/book")")"
    node "$REPO/scripts/short-section-title-lock.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --json > "$TMP_DIR/title-preview.json"
    digest="$(jq -r '.digest' "$TMP_DIR/title-preview.json")"
    node "$REPO/scripts/short-section-title-lock.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --digest "$digest" --confirm --json > "$TMP_DIR/title-confirm.json"
    [ "$(jq -r '.next_stage' "$TMP_DIR/title-confirm.json")" = "short_structure_impact_audit" ]
    task_file="$(focused_task_file "$TMP_DIR/book")"
    [ "$(jq -r '.stage_execution.context_read_command // empty' "$task_file")" = "" ]
    [[ "$(jq -r '.stage_execution.execution_command' "$task_file")" == *'short-structure-impact-finalize.js'* ]]

    node "$REPO/scripts/short-structure-impact-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json > "$TMP_DIR/impact.json"
    [ "$(jq -r '.status' "$TMP_DIR/impact.json")" = "short_structure_impact_completed" ]
    [ "$(jq -r '.visible_response.options[0].target_stage' "$TMP_DIR/impact.json")" = "hook_retention_gate" ]

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/hook-start.json"
    task_file="$(focused_task_file "$TMP_DIR/book")"
    [ "$(jq -r '.current_stage' "$task_file")" = "hook_retention_gate" ]
    [ "$(jq -r '.stage_execution.context_read_command // empty' "$task_file")" = "" ]
    [[ "$(jq -r '.stage_execution.execution_command' "$task_file")" == *'short-hook-value-finalize.js'* ]]
    node "$REPO/scripts/short-hook-value-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json > "$TMP_DIR/hook-review.json"
    [ "$(jq -r '.status' "$TMP_DIR/hook-review.json")" = "short_hook_value_review_required" ]
    [ -f "$TMP_DIR/book/$(jq -r '.evidence_pack' "$TMP_DIR/hook-review.json")" ]
    evidence_digest="$(jq -r '.review_card_schema.evidence_digest' "$TMP_DIR/hook-review.json")"
    review_card="$TMP_DIR/book/$(jq -r '.review_card' "$TMP_DIR/hook-review.json")"
    mkdir -p "$(dirname "$review_card")"
    node - "$review_card" "$workflow_id" <<'NODE'
const fs=require('fs');const [file,workflowId]=process.argv.slice(2);
fs.writeFileSync(file,JSON.stringify({schemaVersion:'1.0.0',workflow_id:workflowId,evidence_digest:'stale-outline-digest',decision:'pass',repair_layer:'none',summary:'旧规划结论。',checks:[]},null,2)+'\n');
NODE
    node "$REPO/scripts/short-hook-value-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json > "$TMP_DIR/hook-stale.json"
    [ "$(jq -r '.status' "$TMP_DIR/hook-stale.json")" = "short_hook_value_review_required" ]
    [ "$(jq -r '.reason' "$TMP_DIR/hook-stale.json")" = "planning_evidence_changed" ]
    [ -f "$TMP_DIR/book/$(jq -r '.stale_review_card' "$TMP_DIR/hook-stale.json")" ]
    [ ! -f "$review_card" ]
    evidence_digest="$(jq -r '.review_card_schema.evidence_digest' "$TMP_DIR/hook-stale.json")"
    node - "$review_card" "$workflow_id" "$evidence_digest" <<'NODE'
const fs=require('fs');const [file,workflowId,digest]=process.argv.slice(2);
const ids=['title_promise','opening_pressure','plot_spikes','golden_reading_map','section_breakpoints','dropoff_risk','protagonist_agency','causal_chain'];
fs.writeFileSync(file,JSON.stringify({schemaVersion:'1.0.0',workflow_id:workflowId,evidence_digest:digest,decision:'pass',repair_layer:'none',summary:'看点价值门通过。',checks:ids.map(id=>({id,status:'pass',evidence:`${id} 已在规划证据中明确。`,repair_direction:''}))},null,2)+'\n');
NODE
    node "$REPO/scripts/short-hook-value-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json > "$TMP_DIR/hook-pass.json"
    [ "$(jq -r '.status' "$TMP_DIR/hook-pass.json")" = "short_hook_value_completed" ]
    task_file="$(focused_task_file "$TMP_DIR/book")"
    [ "$(jq -r '.current_stage' "$task_file")" = "first_section_brief" ]
    [ "$(jq -r '.stage_execution.status' "$task_file")" = "contract_blocked" ]
    [ "$(jq '.pending_action.options | length' "$task_file")" -eq 4 ]
    [ "$(jq -r '.pending_action.options[0].label' "$task_file")" = "重新准备当前阶段（推荐）" ]
}

@test "whole story short feedback uses a story result packet instead of the last section suffix" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    run node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json
    [ "$status" -eq 0 ]

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "根据总结开始整篇修改" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/whole-story-feedback.json"
    node - "$TMP_DIR/whole-story-feedback.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='short_feedback_impact_started') throw new Error(JSON.stringify(out));
const packet=String((out.stage_execution||{}).expected_result_packet||'');
if(!/\/feedback_impact_sync\.feedback-batch-[a-f0-9]+\.result\.json$/.test(packet) || /section-\d+/.test(packet)) throw new Error(packet);
NODE
}

@test "natural whole story rework feedback enters the existing short workflow" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    run node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json
    [ "$status" -eq 0 ]
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.status='completed';task.lifecycle.status='completed';task.lifecycle.completed_at='2026-07-20T00:00:00.000Z';task.recommended_next=[{number:1,label:'可发布'}];
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉规划反馈：请先更新设定和小节大纲，再修改受影响正文。" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'short_feedback_impact_started'* ]]
    [[ "$output" == *'feedback-inbox.jsonl'* ]]
    [ "$(jq -r '.scope' "$task_file")" = "全篇" ]
    [ "$(jq -r '.unit_lifecycle.unit_type' "$task_file")" = "story" ]
    [ "$(jq -r '.status' "$task_file")" = "running" ]
    [ "$(jq -r '.lifecycle.status' "$task_file")" = "active" ]
    [ "$(jq -r '.lifecycle.completed_at' "$task_file")" = "" ]
    [ "$(jq '.recommended_next | length' "$task_file")" -eq 0 ]
}

@test "pending short feedback recovery ignores an older feedback impact result" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：更新结局和人物关系。" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.short_feedback_impact={status:'ok',feedback_id:'feedback-old',impact_level:'expression_only'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    local workflow_id
    workflow_id="$(jq -r '.workflow_id' "$task_file")"
    run node "$SCRIPT" resume-pending-short-feedback --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"target_stage": "feedback_impact_sync"'* ]]
}

@test "new short feedback invalidates an older completed impact stage and gets a batch-scoped packet" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：重做结局。" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='feedback_apply_patch';task.current_step='feedback_apply_patch';
task.stage_execution={...task.stage_execution,status:'completed',stage_id:'feedback_impact_sync',step_id:'feedback_impact_sync',result_packet:task.stage_execution.expected_result_packet};
task.machine.completed_stages=[...(task.machine.completed_stages||[]),'feedback_impact_sync'];
task.machine.last_result_packet=task.stage_execution.result_packet;
task.short_feedback_impact={status:'ok',feedback_id:task.pending_feedback.feedback_id,impact_level:'planning'};
task.pending_action=null;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "宿舍关系也要贯穿第1、2、8、9节。" --json > "$TMP_DIR/reanalysis.json"
    node - "$TMP_DIR/reanalysis.json" "$task_file" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='short_feedback_impact_started'||task.current_stage!=='feedback_impact_sync'||task.stage_execution.status!=='running') throw new Error(JSON.stringify(out));
if(task.machine.completed_stages.includes('feedback_impact_sync')) throw new Error(JSON.stringify(task.machine));
if(!task.stage_execution.expected_result_packet.includes(task.pending_feedback.feedback_id)||!task.stage_execution.expected_result_packet.endsWith('.result.json')) throw new Error(task.stage_execution.expected_result_packet);
if(task.machine.last_result_packet) throw new Error(JSON.stringify(task.machine));
NODE
}

@test "continue an accepted feedback plan does not become a second feedback item" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：更新设定和小节大纲。" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    local feedback_id
    feedback_id="$(jq -r '.pending_feedback.feedback_id' "$task_file")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='feedback_apply_patch';task.current_step='feedback_apply_patch';task.stage_execution={status:'completed',stage_id:'feedback_impact_sync',step_id:'feedback_impact_sync'};
task.pending_action={id:'pa-feedback-apply',question:'请选择下一步',options:[{number:1,action_id:'continue_next_stage',label:'继续确认并回写反馈影响（推荐）',target_stage:'feedback_apply_patch',risk_level:'high',requires_user_confirm:true,recommended:true},{number:2,action_id:'pause',label:'暂停',target_stage:'',risk_level:'low',requires_user_confirm:false}],free_text_enabled:true};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "根据已确认的方案继续执行规划回写" --json
    [ "$status" -eq 0 ]
    [ "$(jq -r '.pending_feedback.feedback_id' "$task_file")" = "$feedback_id" ]
    [ "$(wc -l < "$(dirname "$task_file")/feedback-inbox.jsonl" | tr -d ' ')" -eq 1 ]
    [ "$(jq -r '.current_stage' "$task_file")" = "feedback_apply_patch" ]
}

@test "a repeated numeric reply resumes the running stage instead of reopening the resolved menu" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：更新结局和人物关系。" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');const file=process.argv[2],root=process.argv[3];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.pending_action={id:'pa-old',status:'resolved',options:[{number:1,action_id:'continue_next_stage',target_stage:task.current_stage}]};
task.stage_execution.execution_command=`node scripts/short-planning-stage-finalize.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(task.workflow_id)} --apply --json`;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 1 --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/repeated-selection.json"
    node - "$TMP_DIR/repeated-selection.json" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),root=process.argv[3];
if(out.status!=='stage_execution_resume_ready'||out.selection_status!=='resume') throw new Error(JSON.stringify(out));
if((out.visible_response||{}).selection_contract!=='resume_running_stage') throw new Error(JSON.stringify(out.visible_response));
if(out.completion_required_before_reply!==true||(out.visible_response||{}).completion_required_before_reply!==true) throw new Error(JSON.stringify(out));
if(!((out.stage_execution||{}).execution_sequence||[]).includes('execute_completion_command')) throw new Error(JSON.stringify(out.stage_execution));
if(!String(out.execution_command||'').includes('--project-root .')||JSON.stringify(out).includes(root)) throw new Error(JSON.stringify(out));
if(!String((out.stage_execution||{}).context_read_command||'').includes('workflow-stage-context.js read-current --project-root .')) throw new Error(JSON.stringify(out.stage_execution));
if(out.refreshed_menu) throw new Error('resolved menu must not be reopened');
NODE
}

@test "next-candidates silently resumes a running stage without an active menu" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.pending_action=null;
task.status='running';
task.stage_execution={status:'running',stage_id:task.current_stage,execution_command:'node scripts/test-stage.js --json'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    run node "$SCRIPT" next-candidates --project-root "$TMP_DIR/book" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'stage_execution_resume_ready'* ]]
    [[ "$output" == *'silent_resume'* ]]
    [[ "$output" != *'回复 1/2/3/4'* ]]
}

@test "running stage menu keeps inspect pause and free text distinct from resume" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：更新结局和人物关系。" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 2 --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.status')" = "current_stage_inspected" ]
    [ "$(jq -r '.stage_execution.status' "$task_file")" = "running" ]
    printf '%s\n' "$output" | grep -q '1. 继续当前阶段（推荐）'
    printf '%s\n' "$output" | grep -q '4. 输入其他要求'

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 4 --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.status')" = "free_text_requested" ]
    [ "$(jq -r '.stage_execution.status' "$task_file")" = "running" ]

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 3 --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -r '.status')" = "stage_paused" ]
    [ "$(jq -r '.stage_execution.status' "$task_file")" = "paused" ]
    [ "$(jq -r '.lifecycle.status' "$task_file")" = "paused" ]
}

@test "discarding a host continuation echo restores the matching trusted feedback analysis" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：重做结局和宿舍关系。" --json >/dev/null
    local task_file workflow_id original_batch result_dir packet_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    workflow_id="$(jq -r '.workflow_id' "$task_file")"
    original_batch="$(jq -r '.pending_feedback.feedback_id' "$task_file")"
    result_dir="$(dirname "$task_file")/result-packets"
    packet_file="$result_dir/feedback_impact_sync.result.json"
    cat > "$packet_file" <<JSON
{"schemaVersion":"1.0.0","workflow_id":"$workflow_id","workflow_type":"short_write","stage_id":"feedback_impact_sync","step_id":"feedback_impact_sync","step_status":"completed","verification_result":"pass","output_health_result":"pass","feedback_id":"$original_batch","impact_level":"planning","affected_sections":[1,9],"affected_assets":["设定.md","小节大纲.md"],"downstream_impact":{"replan":["小节大纲.md"]},"result_packet_path":"追踪/workflow/tasks/$workflow_id/result-packets/feedback_impact_sync.result.json"}
JSON
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "宿舍线补充到第1、2、8、9节。" --json >/dev/null
    local echo_id
    echo_id="$(jq -r '.pending_feedback.items[-1].feedback_id' "$task_file")"

    run node "$SCRIPT" discard-short-feedback-item --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --feedback-id "$echo_id" --confirm --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'trusted_impact_restored'* ]]
    [ "$(jq -r '.pending_feedback.feedback_id' "$task_file")" = "$original_batch" ]
    [ "$(jq -r '.current_stage' "$task_file")" = "feedback_apply_patch" ]
    [ "$(jq -r '.stage_execution.status' "$task_file")" = "completed" ]
    [ "$(jq -r '.short_feedback_impact.feedback_id' "$task_file")" = "$original_batch" ]
    [ "$(jq -r '.pending_action.options[0].target_stage' "$task_file")" = "feedback_apply_patch" ]
    [ "$(jq '.state_findings | length' <<< "$output")" -eq 0 ]
    grep -q '"event_type":"feedback_discarded"' "$(dirname "$task_file")/feedback-inbox.jsonl"
}

@test "free text short feedback starts impact analysis instead of binding an old menu" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-free-feedback",
  "workflow_type": "private_short_startup",
  "scope": "第2节",
  "current_stage": "section_accept_anchor",
  "current_step": "section_accept_anchor",
  "status": "running",
  "machine": {
    "completed_stages": ["quality_gate"],
    "remaining_stages": ["section_accept_anchor", "next_section_brief", "draft_next_section"]
  },
  "pending_action": {
    "id": "pa-old-menu",
    "question": "请选择下一步",
    "options": [{"number":1,"action_id":"accept_current_section","target_stage":"section_accept_anchor"}],
    "free_text_enabled": true
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "哥哥的动机与小节大纲冲突，先改设定和小节大纲再重写本节" --json > "$TMP_DIR/free-feedback.json"
    node - "$TMP_DIR/free-feedback.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='short_feedback_impact_started' || out.target_stage!=='feedback_impact_sync') throw new Error(JSON.stringify(out));
if(task.current_stage!=='feedback_impact_sync' || task.stage_execution.status!=='running') throw new Error(JSON.stringify(task));
if(!task.pending_feedback || !/哥哥的动机/.test(task.pending_feedback.text)) throw new Error(JSON.stringify(task.pending_feedback));
NODE
}

@test "short structure feedback is detected before generic edit feedback" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-structure-feedback",
  "workflow_type": "private_short_startup",
  "scope": "第2节",
  "current_stage": "section_accept_anchor",
  "current_step": "section_accept_anchor",
  "status": "running",
  "machine": {"completed_stages":["quality_gate"],"remaining_stages":["section_accept_anchor","next_section_brief","draft_next_section"]},
  "pending_action": {"id":"pa-structure","options":[{"number":1,"action_id":"accept_current_section","target_stage":"section_accept_anchor"}],"free_text_enabled":true}
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "修改小节大纲，把第 4 节拆成两节并后移后续小节" --json > "$TMP_DIR/structure-feedback.json"
    node - "$TMP_DIR/structure-feedback.json" <<'NODE'
const fs=require('fs'); const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='short_feedback_impact_started' || out.feedback.impact_hint!=='structure') throw new Error(JSON.stringify(out));
NODE
}

@test "deleting one sentence remains artifact feedback instead of structure feedback" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-sentence-feedback",
  "workflow_type": "private_short_startup",
  "scope": "第2节",
  "current_stage": "section_accept_anchor",
  "current_step": "section_accept_anchor",
  "status": "running",
  "machine": {"completed_stages":["quality_gate"],"remaining_stages":["section_accept_anchor","next_section_brief","draft_next_section"]},
  "pending_action": {"id":"pa-sentence","options":[{"number":1,"action_id":"accept_current_section","target_stage":"section_accept_anchor"}],"free_text_enabled":true}
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "删除正文里这一句话，其他情节不变" --json > "$TMP_DIR/sentence-feedback.json"
    node - "$TMP_DIR/sentence-feedback.json" <<'NODE'
const fs=require('fs'); const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='short_feedback_impact_started' || out.feedback.impact_hint!=='analyze') throw new Error(JSON.stringify(out));
NODE
}

@test "story-workflow documents free chat feedback and replanning at every visible stage" {
    grep -q "task-inbox-protocol.md" "$WORKFLOW"
    grep -q "每个阶段都允许用户 chat 介入" "$WORKFLOW_INBOX"
    grep -q "要求重构" "$WORKFLOW_INBOX"
    grep -q "free_text_enabled=true" "$WORKFLOW_INBOX"
    grep -q "提交人工修改" "$WORKFLOW_INBOX"
    grep -q "switch-intent" "$WORKFLOW_PHASE_INDEX"
}

@test "workflow state machine branches private short section machine gate by pass or blocking result" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-gate-pass",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "scope": "第1节",
  "user_goal": "验证第1节机器门通过分支",
  "completion_policy": "stage_then_confirm",
  "current_stage": "section_machine_gate",
  "current_step": "section_machine_gate",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["startup_scan", "startup_menu", "material_learning", "project_seed", "short_setting", "section_outline", "hook_retention_gate", "first_section_brief", "draft_first_section"],
    "remaining_stages": ["section_machine_gate", "section_repair_loop", "quality_gate", "section_candidate_compare", "section_accept_anchor", "next_section_brief", "draft_next_section", "short_deslop", "final_check"],
    "allowed_actions": ["continue_next_stage", "pause"]
  }
}

JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/pass-result.json" <<'JSON'
{
  "workflow_id": "wf-short-gate-pass",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "section_machine_gate",
  "step_id": "section_machine_gate",
  "step_status": "completed",
  "verification_result": "pass",
  "machine_gate_result": "pass",
  "changed_files": ["追踪/质量门/第001节.json"]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/pass-result.json" --json > "$TMP_DIR/pass-out.json"

    node - "$TMP_DIR/pass-out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.current_stage !== 'quality_gate') throw new Error(`pass must route to quality_gate, got ${out.current_stage}`);
if (task.machine.remaining_stages.includes('section_repair_loop')) {
  throw new Error(`pass must skip section_repair_loop: ${JSON.stringify(task.machine.remaining_stages)}`);
}
if (task.machine.remaining_stages.includes('next_section_brief') && !task.machine.remaining_stages.includes('section_accept_anchor')) {
  throw new Error('next_section_brief must remain behind section_accept_anchor');
}
NODE

    cat > "$TMP_DIR/quality-result.json" <<'JSON'
{
  "workflow_id": "wf-short-gate-pass",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "quality_gate",
  "step_id": "quality_gate",
  "step_status": "completed",
  "verification_result": "pass",
  "candidate_count": 1,
  "changed_files": []
}
JSON
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/quality-result.json" --json > "$TMP_DIR/quality-out.json"
    node - "$TMP_DIR/quality-out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.current_stage !== 'section_accept_anchor') throw new Error(`single candidate must skip comparison, got ${out.current_stage}`);
const labels = (task.pending_action.options || []).map((item) => item.label);
if (labels.length !== 4) throw new Error(JSON.stringify(labels));
for (const expected of ['采用；自动提交本节并生成下一节 Brief（推荐）', '修改第 1 节；完成后继续后续任务', '查看本轮修订队列与依据', '暂停并保存断点']) {
  if (!labels.includes(expected)) throw new Error(`missing ${expected}: ${JSON.stringify(labels)}`);
}
const recommended = (task.pending_action.options || []).filter((item) => item.recommended === true);
if (recommended.length !== 1 || recommended[0].number !== 1) throw new Error(`invalid recommendation: ${JSON.stringify(task.pending_action.options)}`);
NODE

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/accept-start.json"
    node - "$TMP_DIR/accept-start.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'stage_started' || out.target_stage !== 'section_accept_anchor') throw new Error(JSON.stringify(out));
NODE

    cat > "$TMP_DIR/anchor-result-missing-proof.json" <<'JSON'
{
  "workflow_id": "wf-short-gate-pass",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "section_accept_anchor",
  "step_id": "section_accept_anchor",
  "step_status": "completed",
  "verification_result": "pass",
  "changed_files": []
}
JSON
    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/anchor-result-missing-proof.json" --json
    [ "$status" -eq 2 ]
    printf '%s' "$output" | grep -q 'short_section_acceptance_proof_missing'

    printf '%s\n' '第一节正式正文' > "$TMP_DIR/book/正文.md"
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    canonical_hash="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    mkdir -p "$TMP_DIR/book/追踪/story-system/commits"
    accepted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$TMP_DIR/book/追踪/story-system/commits/section-001.json" <<JSON
{"workflow_id":"wf-short-gate-pass","status":"accepted","accepted_at":"$accepted_at","artifacts":[{"target":"正文.md","after_hash":"sha256:$canonical_hash"}]}
JSON
    cat > "$TMP_DIR/book/追踪/private-short-extension/section-001-anchor.json" <<JSON
{"workflow_id":"wf-short-gate-pass","section_index":1,"status":"accepted","canonical_path":"正文.md","canonical_sha256":"$canonical_hash","quality_result":{"machine_gate":"pass","story_value_gate":"pass","repetition_gate":"pass","length_policy":{"blocking":false,"verdict":"baseline_not_established"}}}
JSON
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{"current_section_index":2,"accepted_sections":[{"section_index":1,"anchor_path":"追踪/private-short-extension/section-001-anchor.json"}]}
JSON
    cat > "$TMP_DIR/anchor-result.json" <<JSON
{
  "workflow_id": "wf-short-gate-pass",
  "workflow_type": "private_short_startup",
  "stage_id": "section_accept_anchor",
  "step_id": "section_accept_anchor",
  "step_status": "completed",
  "verification_result": "pass",
  "section_acceptance": {
    "workflow_id": "wf-short-gate-pass",
    "section_index": 1,
    "anchor_path": "追踪/private-short-extension/section-001-anchor.json",
    "canonical_path": "正文.md",
    "canonical_sha256": "$canonical_hash"
  },
  "changed_files": ["正文.md", "追踪/private-short-extension/section-001-anchor.json"]
}
JSON
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/anchor-result.json" --json > "$TMP_DIR/anchor-out.json"
    node - "$TMP_DIR/anchor-out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'stage_started' || out.current_stage !== 'next_section_brief') throw new Error(JSON.stringify(out));
if (!out.stage_execution || out.stage_execution.action_id !== 'auto_continue_internal') throw new Error(JSON.stringify(out.stage_execution));
NODE
    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (task.scope !== '第2节') throw new Error(JSON.stringify({ scope: task.scope }));
if (!task.unit_lifecycle || task.unit_lifecycle.current_scope !== '第2节') throw new Error(JSON.stringify(task.unit_lifecycle));
NODE

    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-gate-block",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "scope": "第2节",
  "user_goal": "验证第2节机器门阻断分支",
  "completion_policy": "stage_then_confirm",
  "current_stage": "section_machine_gate",
  "current_step": "section_machine_gate",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["startup_scan", "startup_menu", "material_learning", "project_seed", "short_setting", "section_outline", "hook_retention_gate", "first_section_brief", "draft_first_section"],
    "remaining_stages": ["section_machine_gate", "section_repair_loop", "quality_gate", "section_candidate_compare", "section_accept_anchor", "next_section_brief", "draft_next_section", "short_deslop", "final_check"],
    "allowed_actions": ["continue_next_stage", "pause"]
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension" "$TMP_DIR/book/追踪/workflow/tasks/wf-short-gate-block/result-packets"
    printf '%s\n' '{"working_title":"测试短篇","current_section_index":2}' > "$TMP_DIR/book/追踪/private-short-extension/project-state.json"
    printf '# 第2节写作提要\n\n## 本节任务\n保留事实，只修机器门问题。\n\n## 视角与称谓\n第一人称。\n\n## 禁止漂移\n不得改变人物和情节。\n\n## 验收标准\n机器门问题清零。\n' > "$TMP_DIR/book/写作Brief_第002节.md"
    printf '# 第2节\n\n这不是误会，是欺骗。\n' > "$TMP_DIR/book/草稿_第002节_候选.md"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-gate-block/result-packets/section_machine_gate.result.json" <<'JSON'
{
  "workflow_id": "wf-short-gate-block",
  "workflow_type": "private_short_startup",
  "stage_id": "section_machine_gate",
  "step_id": "section_machine_gate",
  "step_status": "blocked",
  "verification_result": "blocking",
  "machine_gate_result": "blocking",
  "blocking_findings": [{"code": "not-is-comparison", "count": 17}],
  "result_packet_path": "追踪/workflow/tasks/wf-short-gate-block/result-packets/section_machine_gate.result.json"
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/book/追踪/workflow/tasks/wf-short-gate-block/result-packets/section_machine_gate.result.json" --json > "$TMP_DIR/block-out.json"

    node - "$TMP_DIR/block-out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.current_stage !== 'section_repair_loop') throw new Error(`blocking must route to section_repair_loop, got ${out.current_stage}`);
if (out.status !== 'stage_started') throw new Error(`repair loop must auto-start: ${JSON.stringify(out)}`);
if ((task.stage_execution || {}).status !== 'running' || task.stage_execution.stage_id !== 'section_repair_loop') {
  throw new Error(`repair execution must be running: ${JSON.stringify(task.stage_execution)}`);
}
if (!String(task.stage_execution.execution_command || '').includes('short-section-repair-finalize.js')) {
  throw new Error(`repair finalizer missing: ${JSON.stringify(task.stage_execution)}`);
}
const sourceKinds = ((task.stage_execution.stage_context_packet || {}).source_files || []).map((item) => item.kind);
if (JSON.stringify(sourceKinds) !== JSON.stringify(['gate_findings','repair_constraints','current_draft'])) {
  throw new Error(`repair context is not minimal: ${JSON.stringify(sourceKinds)}`);
}
if (task.machine.completed_stages.includes('section_machine_gate')) {
  throw new Error('blocking section machine gate must not be marked completed');
}
const expectedPrefix = ['section_repair_loop', 'section_machine_gate', 'quality_gate'];
for (let i = 0; i < expectedPrefix.length; i += 1) {
  if (task.machine.remaining_stages[i] !== expectedPrefix[i]) {
    throw new Error(`blocking remaining stages wrong: ${JSON.stringify(task.machine.remaining_stages)}`);
  }
}
NODE
}

@test "workflow state machine migrates a legacy single-candidate short task without changing creative assets" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/workflow/tasks/wf-short-legacy/result-packets"
    printf '%s\n' '唯一候选正文' > "$TMP_DIR/book/正文.md"
    before="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-legacy",
  "workflow_type": "private_short_startup",
  "scope": "第1节",
  "current_stage": "section_candidate_compare",
  "current_step": "section_candidate_compare",
  "status": "running",
  "machine": {
    "completed_stages": ["section_machine_gate", "quality_gate"],
    "remaining_stages": ["section_candidate_compare", "section_accept_anchor", "next_section_brief", "draft_next_section"]
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-legacy/result-packets/section_machine_gate.result.json" <<'JSON'
{"step_status":"completed","verification_result":"pass","machine_gate_result":"pass","blocking_findings":[]}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-legacy/result-packets/quality_gate.result.json" <<'JSON'
{"step_status":"completed","verification_result":"pass","quality_gate_result":"pass","candidate_count":1,"blocking_findings":[]}
JSON

    node "$SCRIPT" migrate-short-lean-workflow --project-root "$TMP_DIR/book" --workflow-id wf-short-legacy --json > "$TMP_DIR/dry.json"
    grep -q '"status": "eligible_single_candidate_skip"' "$TMP_DIR/dry.json"
    grep -q '"creative_assets_modified": false' "$TMP_DIR/dry.json"

    node "$SCRIPT" migrate-short-lean-workflow --project-root "$TMP_DIR/book" --workflow-id wf-short-legacy --confirm --json > "$TMP_DIR/migrated.json"
    after="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
    node - "$TMP_DIR/migrated.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='short_lean_workflow_migrated') throw new Error(JSON.stringify(out));
if(task.workflow_type!=='short_write' || task.current_stage!=='section_accept_anchor') throw new Error(JSON.stringify(task));
if((task.pending_action.options||[]).length!==4) throw new Error(JSON.stringify(task.pending_action));
NODE
}

@test "workflow state machine rejects stale short section result packet" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "第6节" --user-goal "继续短篇" --no-private-registry --json >/dev/null

    node - "$TMP_DIR/book" <<'NODE'
const fs = require('fs');
const path = require('path');
const fixture = require(process.env.WORKFLOW_TASK_FIXTURE);
const root = process.argv[2];
const taskFile = fixture.focusedTaskFile(root);
const task = fixture.readFocusedTask(root);
const packetRel = `${task.task_dir}/result-packets/quality_gate.result.json`;
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
const packetAbs = path.join(root, packetRel);
fs.mkdirSync(path.dirname(packetAbs), { recursive: true });
fs.writeFileSync(packetAbs, JSON.stringify({
  workflow_id: task.workflow_id,
  workflow_type: task.workflow_type,
  owner_module: 'story-short-write',
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

    result_file="$(node -e 'const fixture=require(process.env.WORKFLOW_TASK_FIXTURE);const task=fixture.readFocusedTask(process.argv[1]);process.stdout.write(`${process.argv[1]}/${task.stage_execution.expected_result_packet}`)' "$TMP_DIR/book")"
    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$result_file" --json
    [ "$status" -eq 2 ]
    printf '%s' "$output" | grep -q 'blocked_result_packet_unit_mismatch'
    printf '%s' "$output" | grep -q '"expected_section_index": 6'
    printf '%s' "$output" | grep -q '"actual_section_index": 5'
}

@test "workflow state machine creates review repair task with remaining stages" {
    mkdir -p "$TMP_DIR/book"

    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-200" --json > "$TMP_DIR/out.json"

    grep -q '"status": "created"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "review_repair"' "$TMP_DIR/out.json"
    grep -q '"current_stage": "range_lock"' "$TMP_DIR/out.json"
    grep -q '"remaining_stages"' "$TMP_DIR/out.json"
    grep -q '"pending_action"' "$TMP_DIR/out.json"
    test -f "$TMP_DIR/book/追踪/workflow/current-task.json"
    test -f "$TMP_DIR/book/追踪/workflow/current-task.md"
}

@test "review creation maps an oversized chapter to a stable blocked JSON response" {
    mkdir -p "$TMP_DIR/book/正文"
    head -c 160050 /dev/zero | tr '\0' '章' > "$TMP_DIR/book/正文/chapter001.md"

    status=0
    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-1" --json > "$TMP_DIR/oversized.json" 2> "$TMP_DIR/oversized.err" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_oversized_chapter"' "$TMP_DIR/oversized.json"
    grep -q '"chapter_key": "v01-c001"' "$TMP_DIR/oversized.json"
    grep -q '"source_budget_chars": 160000' "$TMP_DIR/oversized.json"
    grep -q '"action_id": "escalate_single_chapter_review"' "$TMP_DIR/oversized.json"
    [ ! -s "$TMP_DIR/oversized.err" ]
}

@test "review repair workflow requires staged prose repair and recheck after user scope choice" {
    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/templates.json"

    node - "$TMP_DIR/templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const review = data.templates.find((item) => item.workflow_type === 'review_repair');
if (!review) throw new Error('missing review_repair template');
const stages = Object.fromEntries(review.stages.map((stage) => [stage.stage_id, stage]));
for (const id of ['repair_execution_plan', 'staged_repair_candidate', 'repair_machine_gate']) {
  if (!stages[id]) throw new Error(`review_repair missing ${id}`);
}
if (!stages.user_scope_choice.allowed_next.includes('repair_execution_plan')) {
  throw new Error(`user_scope_choice must go to repair_execution_plan: ${JSON.stringify(stages.user_scope_choice.allowed_next)}`);
}
if (!stages.repair_execution_plan.allowed_next.includes('staged_repair_candidate')) {
  throw new Error(`repair_execution_plan must stage candidate before edits: ${JSON.stringify(stages.repair_execution_plan.allowed_next)}`);
}
if (!stages.staged_repair_candidate.allowed_next.includes('repair_machine_gate')) {
  throw new Error(`staged_repair_candidate must route to repair_machine_gate: ${JSON.stringify(stages.staged_repair_candidate.allowed_next)}`);
}
if (!stages.repair_machine_gate.allowed_next.includes('staged_repair_candidate')) {
  throw new Error(`blocking repair_machine_gate must return to staged_repair_candidate: ${JSON.stringify(stages.repair_machine_gate.allowed_next)}`);
}
if (!stages.repair_machine_gate.allowed_next.includes('execute_repair')) {
  throw new Error(`passing repair_machine_gate must unlock execute_repair: ${JSON.stringify(stages.repair_machine_gate.allowed_next)}`);
}
NODE
}

@test "workflow state machine exposes reusable production unit lifecycle" {
    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/templates.json"

    node - "$TMP_DIR/templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const byType = Object.fromEntries(data.templates.map((item) => [item.workflow_type, item]));

const long = byType.long_write;
if (!long.unit_lifecycle_contract) throw new Error('long_write missing unit_lifecycle_contract');
if (long.unit_lifecycle_contract.unit_type !== 'book_lifecycle') throw new Error(`long unit_type mismatch: ${long.unit_lifecycle_contract.unit_type}`);
for (const [stage, role] of Object.entries({
  master_outline: 'macro_contract',
  master_outline_review: 'quality_gate',
  volume_outline_review: 'quality_gate',
  stage_detail_outline: 'macro_contract',
  detail_outline_review: 'quality_gate',
  chapter_brief: 'brief_or_contract',
  brief_review: 'quality_gate',
  prose: 'draft_or_execute',
  prose_acceptance: 'machine_quality_gate',
  chapter_commit: 'state_integration',
  milestone_review: 'quality_gate',
  volume_acceptance: 'quality_gate',
  book_acceptance: 'handoff_and_next',
})) {
  if (long.unit_lifecycle_contract.stage_roles[stage] !== role) {
    throw new Error(`long stage ${stage} should map to ${role}, got ${long.unit_lifecycle_contract.stage_roles[stage]}`);
  }
}
const longStages = Object.fromEntries(long.stages.map((stage) => [stage.stage_id, stage]));
for (const id of ['chapter_brief', 'brief_review', 'prose', 'prose_acceptance', 'chapter_commit', 'milestone_review', 'volume_acceptance', 'book_acceptance']) {
  if (!longStages[id]) throw new Error(`long_write missing stage ${id}`);
}
if (!longStages.prose.allowed_next.includes('prose_acceptance')) {
  throw new Error(`long prose must go to prose_acceptance: ${JSON.stringify(longStages.prose.allowed_next)}`);
}
if (!longStages.prose_acceptance.required_inputs.includes('prose')) {
  throw new Error(`prose_acceptance must require prose: ${JSON.stringify(longStages.prose_acceptance.required_inputs)}`);
}
if (!longStages.prose_acceptance.allowed_next.includes('prose')) {
  throw new Error(`prose_acceptance must return blocking findings to prose: ${JSON.stringify(longStages.prose_acceptance.allowed_next)}`);
}
if (!longStages.prose_acceptance.allowed_next.includes('chapter_commit')) {
  throw new Error(`prose_acceptance must unlock chapter_commit after pass: ${JSON.stringify(longStages.prose_acceptance.allowed_next)}`);
}
if (!longStages.chapter_commit.allowed_next.includes('chapter_brief') || !longStages.chapter_commit.allowed_next.includes('milestone_review')) {
  throw new Error(`chapter_commit must continue the chapter loop or enter milestone review: ${JSON.stringify(longStages.chapter_commit.allowed_next)}`);
}

const short = byType.short_write;
if (!short.unit_lifecycle_contract) throw new Error('short_write missing unit_lifecycle_contract');
if (short.unit_lifecycle_contract.unit_type !== 'section') throw new Error(`short unit_type mismatch: ${short.unit_lifecycle_contract.unit_type}`);
if (short.unit_lifecycle_contract.stage_roles.section_outline !== 'brief_or_contract') throw new Error('short section_outline must be brief_or_contract');
if (short.unit_lifecycle_contract.stage_roles.section_plan_lock !== 'brief_or_contract') throw new Error('short section_plan_lock must be brief_or_contract');
if (short.unit_lifecycle_contract.stage_roles.short_structure_impact_audit !== 'quality_gate') throw new Error('short structure impact audit must be a quality gate');
if (short.unit_lifecycle_contract.stage_roles.rhythm_pattern_selection !== 'brief_or_contract') throw new Error('short rhythm_pattern_selection must be brief_or_contract');
if (short.unit_lifecycle_contract.stage_roles.section_brief !== 'brief_or_contract') throw new Error('short section_brief must be brief_or_contract');
if (short.unit_lifecycle_contract.stage_roles.draft_section !== 'draft_or_execute') throw new Error('short draft_section must be draft_or_execute');
if (short.unit_lifecycle_contract.stage_roles.section_machine_gate !== 'machine_quality_gate') throw new Error('short section_machine_gate must be machine_quality_gate');
if (short.unit_lifecycle_contract.stage_roles.story_value_gate !== 'quality_gate') throw new Error('short story_value_gate must be quality_gate');
if (short.unit_lifecycle_contract.stage_roles.full_story_assembly !== 'state_integration') throw new Error('short full_story_assembly must integrate whole story');
if (short.unit_lifecycle_contract.stage_roles.final_check !== 'handoff_and_next') throw new Error('short final_check must handoff');
NODE

    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --scope "第1卷第001章" --json > "$TMP_DIR/create.json"
    task_file="$(focused_task_file "$TMP_DIR/book")"
    grep -q '"unit_lifecycle"' "$task_file"
    grep -q '"unit_type": "book_lifecycle"' "$task_file"
    grep -q '"brief_or_contract"' "$task_file"
}

@test "private workflow registry authority: moved book still resumes private overlay; unavailable registry blocks instead of degrading" {
    # 场景 A: 私有短篇任务, 书目目录已移动, 不传 --private-registry-root,
    # 但源码 checkout 仍能自动加载 private-short-extension overlay.
    # apply-result 推进 draft_first_section 应进入 section_machine_gate, 私有 overlay 仍在.
    # (draft_first_section 线性推进到 section_machine_gate; draft_next_section 的回环路由属 Task 3 stage controller.)
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-authority",
  "workflow_type": "short_write",
  "workflow_profile": "private",
  "workflow_owner": "private-short-extension",
  "workflow_registry": {
    "profile": "private",
    "owner_module": "private-short-extension",
    "registry_id": "private-short-extension",
    "registry_digest": "src/private-internal-skills/private-short-extension/workflow-registry.json"
  },
  "scope": "第6节",
  "user_goal": "验证私有 registry 身份绑定",
  "completion_policy": "stage_then_confirm",
  "current_stage": "draft_first_section",
  "current_step": "draft_first_section",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["startup_scan", "startup_menu", "material_learning", "project_seed", "short_setting", "section_outline", "hook_retention_gate", "first_section_brief"],
    "remaining_stages": ["draft_first_section", "section_machine_gate", "quality_gate", "section_accept_anchor", "next_section_brief", "draft_next_section", "short_deslop", "final_check"],
    "allowed_actions": ["continue_next_stage", "pause"]
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/draft-result.json" <<'JSON'
{
  "workflow_id": "wf-short-authority",
  "workflow_type": "short_write",
  "stage_id": "draft_first_section",
  "step_id": "draft_first_section",
  "step_status": "completed",
  "owner_module": "private-short-extension",
  "verification_result": "pass",
  "output_health_result": "pass",
  "current_section_index": 1,
  "checkpoint_state": {},
  "outputs": [],
  "changed_files": ["正文.md"]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/draft-result.json" --json > "$TMP_DIR/authority-out.json"
    grep -q '"current_stage": "section_machine_gate"' "$TMP_DIR/authority-out.json"
    # status 是 advanced 或 stage_started(section_machine_gate 是内部阶段会自动启动); 关键是不被 blocked.
    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (task.current_stage !== 'section_machine_gate') throw new Error(`scenario A must land on section_machine_gate, got ${task.current_stage}`);
if (!task.workflow_registry || task.workflow_registry.profile !== 'private' || task.workflow_registry.owner_module !== 'private-short-extension') {
  throw new Error(`task must record private registry authority: ${JSON.stringify(task.workflow_registry)}`);
}
NODE

    # 场景 B: 同一任务, 但 registry 被禁用 (--no-private-registry),
    # 模拟换机器没装私有包. apply-result 必须返回 blocked_private_workflow_registry_unavailable,
    # 不得降级到公开 short_write 模板, 不得推进.
    cat > "$TMP_DIR/draft-result-2.json" <<'JSON'
{
  "workflow_id": "wf-short-authority",
  "workflow_type": "short_write",
  "stage_id": "section_machine_gate",
  "step_id": "section_machine_gate",
  "step_status": "completed",
  "verification_result": "pass",
  "changed_files": ["正文.md"]
}
JSON
    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/draft-result-2.json" --no-private-registry --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_private_workflow_registry_unavailable'* ]]
    # 任务快照不得被降级推进, 仍停留在 scenario A 推进后的 section_machine_gate
    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (task.current_stage !== 'section_machine_gate') throw new Error(`scenario B must not mutate task stage, got ${task.current_stage}`);
NODE
}

@test "public short_write fallback has production gates without private brainstorm pool" {
    node "$SCRIPT" templates --no-private-registry --json > "$TMP_DIR/templates.json"

    node - "$TMP_DIR/templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const short = data.templates.find((item) => item.workflow_type === 'short_write');
if (!short) throw new Error('missing short_write');
if (short.private_overlay) throw new Error('public short_write must not depend on private overlay');
const stages = Object.fromEntries(short.stages.map((stage) => [stage.stage_id, stage]));
for (const id of [
  'material_card',
  'short_setting',
  'platform_genre_lock',
  'rhythm_pattern_selection',
  'section_outline',
  'section_plan_lock',
  'short_structure_impact_audit',
  'hook_value_gate',
  'section_brief',
  'draft_section',
  'section_machine_gate',
  'section_repair_loop',
  'story_value_gate',
  'section_accept_anchor',
  'next_section_brief',
  'full_story_assembly',
  'deslop',
  'final_check',
]) {
  if (!stages[id]) throw new Error(`missing public short stage ${id}`);
}
for (const forbidden of ['startup_scan', 'startup_menu', 'material_learning', 'project_seed', 'brainstorm_card_pool']) {
  if (stages[forbidden]) throw new Error(`public short_write must not include private stage ${forbidden}`);
}
if (!stages.short_setting.allowed_next.includes('platform_genre_lock')) throw new Error('setting must enter platform_genre_lock');
if (!stages.platform_genre_lock.requires_user_confirm) throw new Error('platform_genre_lock must require confirmation');
if (!stages.platform_genre_lock.allowed_next.includes('rhythm_pattern_selection')) throw new Error('platform_genre_lock must enter rhythm selection');
if (!stages.rhythm_pattern_selection.required_inputs.includes('platform_genre_lock')) throw new Error('rhythm pattern must require platform_genre_lock');
if (!stages.rhythm_pattern_selection.allowed_next.includes('section_outline')) throw new Error('rhythm pattern must enter outline');
if (!/爽点/.test(stages.rhythm_pattern_selection.description) || !/打脸/.test(stages.rhythm_pattern_selection.description) || !/火葬场/.test(stages.rhythm_pattern_selection.description)) {
  throw new Error(`rhythm pattern description too weak: ${stages.rhythm_pattern_selection.description}`);
}
if (!stages.section_outline.required_inputs.includes('rhythm_pattern_selection')) throw new Error('outline must require rhythm pattern selection');
if (!stages.section_outline.allowed_next.includes('section_plan_lock')) throw new Error('outline must enter section_plan_lock');
if (!stages.section_plan_lock.required_inputs.includes('section_outline')) throw new Error('section_plan_lock must require section_outline');
if (!/总小节/.test(stages.section_plan_lock.description) || !/全篇完成/.test(stages.section_plan_lock.description)) {
  throw new Error(`section_plan_lock description too weak: ${stages.section_plan_lock.description}`);
}
if (!stages.section_plan_lock.allowed_next.includes('short_structure_impact_audit')) throw new Error('section_plan_lock must enter short_structure_impact_audit');
if (!stages.short_structure_impact_audit.required_inputs.includes('section_plan_lock')) throw new Error('short_structure_impact_audit must require section_plan_lock');
if (!/素材卡/.test(stages.short_structure_impact_audit.description) || !/采用锚点/.test(stages.short_structure_impact_audit.description) || !/缩容/.test(stages.short_structure_impact_audit.description)) {
  throw new Error(`short_structure_impact_audit description too weak: ${stages.short_structure_impact_audit.description}`);
}
if (!stages.short_structure_impact_audit.allowed_next.includes('hook_value_gate')) throw new Error('short_structure_impact_audit must enter hook_value_gate');
if (!stages.hook_value_gate.allowed_next.includes('section_brief')) throw new Error('hook gate must enter section_brief');
if (stages.section_brief.requires_user_confirm) throw new Error('public section brief generation must run internally and stop before prose');
if (!stages.section_brief.allowed_next.includes('draft_section')) throw new Error('brief must enter draft_section');
if (!stages.draft_section.allowed_next.includes('section_machine_gate')) throw new Error('draft must enter section_machine_gate');
if (!stages.section_machine_gate.allowed_next.includes('section_repair_loop')) throw new Error('machine gate must route blockers to repair loop');
if (!stages.section_machine_gate.allowed_next.includes('story_value_gate')) throw new Error('machine gate pass must unlock story_value_gate');
if (stages.story_value_gate.requires_user_confirm) throw new Error('story value gate must be internal and surface one combined section decision');
if (stages.story_value_gate.allowed_next.includes('next_section_brief')) throw new Error('story value gate must not directly unlock next section');
if (!stages.story_value_gate.allowed_next.includes('section_accept_anchor')) throw new Error('story value gate must require accept anchor');
if (!stages.section_accept_anchor.allowed_next.includes('next_section_brief')) throw new Error('accept anchor must unlock next brief');
if (stages.next_section_brief.requires_user_confirm) throw new Error('next brief must generate automatically and stop before prose');
if (!stages.section_accept_anchor.allowed_next.includes('full_story_assembly')) throw new Error('accept anchor must unlock full_story_assembly after last section');
if (!stages.full_story_assembly.required_inputs.includes('section_accept_anchor')) throw new Error('full_story_assembly must require section_accept_anchor');
if (!stages.full_story_assembly.allowed_next.includes('full_story_review')) throw new Error('full_story_assembly must enter full_story_review');
if (!stages.full_story_review.allowed_next.includes('deslop') || !stages.full_story_review.allowed_next.includes('feedback_impact_sync')) throw new Error('full_story_review must pass to deslop or return to feedback');
if (!/人物动机/.test(stages.story_value_gate.description) || !/爽点/.test(stages.story_value_gate.description) || !/现实因果/.test(stages.story_value_gate.description)) {
  throw new Error(`story value gate description too weak: ${stages.story_value_gate.description}`);
}
NODE
}

@test "workflow state machine blocks ambiguous machine gate result packets" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-short-ambiguous-gate",
  "workflow_type": "private_short_startup",
  "scope": "第3节",
  "user_goal": "验证短篇机器门歧义结果阻断",
  "completion_policy": "stage_then_confirm",
  "current_stage": "section_machine_gate",
  "current_step": "section_machine_gate",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["startup_scan", "startup_menu", "material_learning", "project_seed", "short_setting", "section_outline", "hook_retention_gate", "first_section_brief", "draft_first_section"],
    "remaining_stages": ["section_machine_gate", "section_repair_loop", "quality_gate", "section_candidate_compare", "section_accept_anchor", "next_section_brief", "draft_next_section", "short_deslop", "final_check"],
    "allowed_actions": ["continue_next_stage", "pause"]
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/ambiguous-result.json" <<'JSON'
{
  "workflow_id": "wf-short-ambiguous-gate",
  "workflow_type": "private_short_startup",
  "stage_id": "section_machine_gate",
  "step_id": "section_machine_gate",
  "step_status": "completed"
}
JSON

    set +e
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/ambiguous-result.json" --json > "$TMP_DIR/out.json" 2>&1
    status="$?"
    set -e

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_machine_gate_result_ambiguous"' "$TMP_DIR/out.json"
    grep -q 'machine_gate_result' "$TMP_DIR/out.json"
}

@test "workflow state machine resolves numbered selection from pending action" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --scope "第1章" --user-goal "写第一章" --json >/dev/null

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/out.json"

    grep -q '"status": "stage_started"' "$TMP_DIR/out.json"
    grep -q '"selection_status": "resolved"' "$TMP_DIR/out.json"
    grep -q '"selected_number": 1' "$TMP_DIR/out.json"
    grep -q '"action_id": "continue_next_stage"' "$TMP_DIR/out.json"
    grep -q '"target_stage": "positioning"' "$TMP_DIR/out.json"
    ! grep -q '重新推理' "$TMP_DIR/out.json"

    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!task.last_selection) throw new Error('last_selection not persisted');
if (task.last_selection.selected_number !== 1) throw new Error('selected_number mismatch');
if (task.last_selection.action_id !== 'continue_next_stage') throw new Error('action_id mismatch');
if (task.pending_action.status !== 'resolved') throw new Error('pending_action should be marked resolved');
NODE
}

@test "workflow state machine locks one-section-and-stop option boundaries" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "第6节" --user-goal "继续短篇" --json >/dev/null
    node - "$TMP_DIR/book" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto'); const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root); const task=JSON.parse(fs.readFileSync(current,'utf8'));
task.current_stage='draft_section'; task.current_step='draft_section';
task.pending_action={
    id:'pa-short-next', question:'请选择下一步', options:[
      {
        number:1, action_id:'write_sections', label:'继续写第 6-7 节', target_scope:'第6-7节', max_units:2,
        stop_after:'第7节', completion_boundary:'stop_after_target_scope', risk_level:'high'
      },
      {
        number:2, action_id:'write_one_section_then_stop', label:'只写第 6 节，写完停下让我看', target_scope:'第6节',
        target_files:['正文.md'], max_units:1, stop_after:'第6节', completion_boundary:'stop_after_target_scope',
        forbidden_interpretations:['pause_before_writing','review_sections_4_5','write_sections_6_7'], risk_level:'high'
      },
      {
        number:3, action_id:'review_sections', label:'先看 4-5 节，有意见再继续', target_scope:'第4-5节',
        max_units:0, stop_after:'review_only', risk_level:'low'
      }
    ], free_text_enabled:true
};
const stable=JSON.stringify({id:task.pending_action.id,question:task.pending_action.question,options:task.pending_action.options.map(x=>({number:x.number,action_id:x.action_id,label:x.label,target_stage:x.target_stage||'',target_scope:x.target_scope||''}))});
task.pending_action.visible_choice_hash=crypto.createHash('sha256').update(stable).digest('hex');
task.pending_action.pending_action_id=task.pending_action.id; task.pending_action.state_version=task.state_version; task.pending_action.book_root=root;
const text=JSON.stringify(task,null,2)+'\n'; fs.writeFileSync(current,text);
NODE

    resolve_action "$TMP_DIR/book" 2 > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'stage_started') throw new Error(`stage not started: ${out.status}`);
if (out.selection_status !== 'resolved') throw new Error(`selection not resolved: ${out.selection_status}`);
if (out.action_id !== 'write_one_section_then_stop') throw new Error(`wrong action: ${out.action_id}`);
if (out.action.target_scope !== '第6节') throw new Error(`wrong scope: ${out.action.target_scope}`);
if (out.execution_contract.max_units !== 1) throw new Error(`wrong max_units: ${out.execution_contract.max_units}`);
if (out.execution_contract.stop_after !== '第6节') throw new Error(`wrong stop_after: ${out.execution_contract.stop_after}`);
if (!out.execution_contract.forbidden_interpretations.includes('review_sections_4_5')) {
  throw new Error('missing forbidden interpretation guard');
}
if (task.last_selection.action_id !== 'write_one_section_then_stop') throw new Error('last_selection action not persisted');
if (task.last_selection.target_scope !== '第6节') throw new Error('last_selection scope not persisted');
if (task.pending_action.status !== 'resolved') throw new Error('pending_action not resolved');
NODE
}

@test "workflow state machine keeps remaining stages after completing current stage" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/result-packets"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-review-001",
  "workflow_type": "review_repair",
  "completion_policy": "stage_then_confirm",
  "current_stage": "classify_findings",
  "current_step": "classify_s1_s4",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["range_lock", "evidence_scan"],
    "remaining_stages": ["classify_findings", "repair_plan", "user_scope_choice", "execute_repair", "recheck", "closure"],
    "allowed_actions": ["continue_next_stage", "pause"]
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/result.json" <<'JSON'
{
  "workflow_id": "wf-review-001",
  "workflow_type": "review_repair",
  "stage_id": "classify_findings",
  "step_id": "classify_s1_s4",
  "step_status": "completed",
  "changed_files": ["追踪/审查报告/report.md"],
  "verification_result": "pass",
  "blocking_reason": null,
  "remaining_work": ["repair_plan", "user_scope_choice", "execute_repair", "recheck", "closure"]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json > "$TMP_DIR/out.json"

    grep -Eq '"status": "(advanced|stage_started)"' "$TMP_DIR/out.json"
    grep -q '"visible_label"' "$TMP_DIR/out.json"
    grep -q '"progress"' "$TMP_DIR/out.json"
    grep -q '"next_user_action"' "$TMP_DIR/out.json"
    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (task.current_stage !== 'repair_plan') throw new Error(JSON.stringify(task));
for (const stage of ['repair_plan', 'user_scope_choice', 'execute_repair', 'recheck', 'closure']) {
  if (!task.machine.remaining_stages.includes(stage)) throw new Error(JSON.stringify(task.machine));
}
NODE
}

@test "workflow state machine branches long prose acceptance by pass or blocking result" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-long-accept-pass",
  "workflow_type": "long_write",
  "scope": "第1章",
  "user_goal": "验证第1章正文接受通过分支",
  "completion_policy": "stage_then_confirm",
  "current_stage": "prose_acceptance",
  "current_step": "prose_acceptance",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["positioning", "story_bible", "master_outline", "master_outline_review", "volume_outline", "volume_outline_review", "stage_detail_outline", "detail_outline_review", "chapter_brief", "brief_review", "prose"],
    "remaining_stages": ["prose_acceptance", "chapter_commit", "milestone_review", "volume_acceptance", "book_acceptance"],
    "allowed_actions": ["continue_next_stage", "pause"]
  }
}
JSON
    attach_long_lifecycle_graph "$TMP_DIR/book"
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/pass-result.json" <<'JSON'
{
  "workflow_id": "wf-long-accept-pass",
  "workflow_type": "long_write",
  "stage_id": "prose_acceptance",
  "step_id": "prose_acceptance",
  "step_status": "completed",
  "verification_result": "pass",
  "machine_gate_result": "pass",
  "changed_files": ["追踪/质量门/第001章.json"]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/pass-result.json" --json > "$TMP_DIR/pass-out.json"

    node - "$TMP_DIR/pass-out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'stage_started') throw new Error(`chapter commit should auto-start, got ${out.status}`);
if (out.current_stage !== 'chapter_commit') throw new Error(`pass must route to chapter_commit, got ${out.current_stage}`);
if ((out.visible_response||{}).selection_contract !== 'resume_running_stage') throw new Error(JSON.stringify(out.visible_response));
if (!task.machine.completed_stages.includes('prose_acceptance')) {
  throw new Error('passing prose acceptance should be marked completed');
}
for (const id of ['chapter_brief', 'brief_review', 'prose', 'prose_acceptance']) {
  if (!task.lifecycle_graph.completed_nodes.includes(id)) throw new Error(`source migration lost ${id}`);
}
NODE

    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-long-accept-block",
  "workflow_type": "long_write",
  "scope": "第2章",
  "user_goal": "验证第2章正文接受阻断分支",
  "completion_policy": "stage_then_confirm",
  "current_stage": "prose_acceptance",
  "current_step": "prose_acceptance",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["positioning", "story_bible", "master_outline", "master_outline_review", "volume_outline", "volume_outline_review", "stage_detail_outline", "detail_outline_review", "chapter_brief", "brief_review", "prose"],
    "remaining_stages": ["prose_acceptance", "chapter_commit", "milestone_review", "volume_acceptance", "book_acceptance"],
    "allowed_actions": ["continue_next_stage", "pause"]
  }
}
JSON
    attach_long_lifecycle_graph "$TMP_DIR/book"
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/block-result.json" <<'JSON'
{
  "workflow_id": "wf-long-accept-block",
  "workflow_type": "long_write",
  "stage_id": "prose_acceptance",
  "step_id": "prose_acceptance",
  "step_status": "blocked",
  "verification_result": "blocking",
  "machine_gate_result": "blocking",
  "blocking_findings": [{"code": "not-is-comparison", "count": 17}]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/block-result.json" --json > "$TMP_DIR/block-out.json"

    node - "$TMP_DIR/block-out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'advanced') throw new Error(`prose repair must wait for author choice, got ${out.status}`);
if (out.current_stage !== 'prose') throw new Error(`blocking must return to prose, got ${out.current_stage}`);
if ((out.visible_response||{}).selection_contract !== 'execute_command_or_route_intent') throw new Error(JSON.stringify(out.visible_response));
if (!Array.isArray(out.next_candidates) || out.next_candidates.length < 1) throw new Error(JSON.stringify(out.next_candidates));
if (task.machine.completed_stages.includes('prose_acceptance')) {
  throw new Error('blocking prose acceptance must not be marked completed');
}
const expectedPrefix = ['prose', 'prose_acceptance', 'chapter_commit'];
for (let i = 0; i < expectedPrefix.length; i += 1) {
  if (task.machine.remaining_stages[i] !== expectedPrefix[i]) {
    throw new Error(`blocking remaining stages wrong: ${JSON.stringify(task.machine.remaining_stages)}`);
  }
}
NODE
}

@test "long write chapter loop requeues brief review prose acceptance and commit" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-long-next-chapter",
  "workflow_type": "long_write",
  "completion_policy": "stage_then_confirm",
  "current_stage": "chapter_commit",
  "current_step": "chapter_commit",
  "status": "running",
  "lifecycle_graph": {
    "version": "1.0.0",
    "current_node": "chapter_commit",
    "asset_target": {"kind": "chapter", "id": "current-chapter"},
    "completed_nodes": ["positioning", "story_bible", "master_outline", "master_outline_review", "volume_outline", "volume_outline_review", "stage_detail_outline", "detail_outline_review", "chapter_brief", "brief_review", "prose", "prose_acceptance"],
    "invalidated_nodes": []
  },
  "machine": {
    "completed_stages": ["positioning", "story_bible", "master_outline", "master_outline_review", "volume_outline", "volume_outline_review", "stage_detail_outline", "detail_outline_review", "chapter_brief", "brief_review", "prose", "prose_acceptance"],
    "remaining_stages": ["chapter_commit", "milestone_review", "volume_acceptance", "book_acceptance"]
  }
}
JSON
    attach_long_lifecycle_graph "$TMP_DIR/book"
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/next-chapter-result.json" <<'JSON'
{
  "workflow_id": "wf-long-next-chapter",
  "workflow_type": "long_write",
  "stage_id": "chapter_commit",
  "step_id": "chapter_commit",
  "step_status": "completed",
  "verification_result": "pass",
  "changed_files": ["正文/第1卷/第001章.md"],
  "next_stage_id": "chapter_brief",
  "chapter_commit": {
    "mode": "legacy_nontransactional",
    "legacy_reason": "旧项目仅迁移来源状态",
    "risk_acknowledged": true
  }
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/next-chapter-result.json" --json > "$TMP_DIR/next-chapter-out.json"

    node - "$TMP_DIR/next-chapter-out.json" <<'NODE'
const fs = require('fs');
const task = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).task;
const expected = ['chapter_brief', 'brief_review', 'prose', 'prose_acceptance', 'chapter_commit'];
if (JSON.stringify(task.machine.remaining_stages.slice(0, expected.length)) !== JSON.stringify(expected)) {
  throw new Error(`chapter loop did not requeue production nodes: ${JSON.stringify(task.machine.remaining_stages)}`);
}
for (const id of expected) {
  if (task.machine.completed_stages.includes(id)) throw new Error(`${id} remained completed`);
}
if (task.lifecycle_graph.current_node !== 'chapter_brief') throw new Error(`wrong graph node: ${task.lifecycle_graph.current_node}`);
NODE
}

@test "workflow state machine switches manual new intent into a new lifecycle" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-review-old",
  "workflow_type": "review_repair",
  "user_goal": "审阅第12章",
  "scope": "第12章",
  "completion_policy": "stage_then_confirm",
  "current_stage": "repair_plan",
  "current_step": "build_plan",
  "status": "running",
  "lifecycle": {
    "status": "active",
    "started_at": "2026-07-05T10:00:00.000Z",
    "updated_at": "2026-07-05T10:10:00.000Z",
    "user_goal": "审阅第12章",
    "scope": "第12章"
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"

    node "$SCRIPT" switch-intent --project-root "$TMP_DIR/book" --workflow-type long_write --scope "第13章" --user-goal "写第13章" --reason "manual_new_goal" --json > "$TMP_DIR/out.json"

    grep -q '"status": "switched"' "$TMP_DIR/out.json"
    grep -q '"previous_workflow_id": "wf-review-old"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "long_write"' "$TMP_DIR/out.json"
    grep -q '"user_goal": "写第13章"' "$TMP_DIR/out.json"
    grep -q '"scope": "第13章"' "$TMP_DIR/out.json"

    grep -q '"status": "paused"' "$TMP_DIR/book/追踪/workflow/tasks/wf-review-old/task.json"
    grep -q '"focus_switched_to"' "$TMP_DIR/book/追踪/workflow/tasks/wf-review-old/task.json"
    grep -q '"event":"focus_switched_from"' "$TMP_DIR/book/追踪/workflow/history.jsonl"
    grep -q '"event":"created"' "$TMP_DIR/book/追踪/workflow/history.jsonl"
}

@test "workflow state machine closes completed lifecycle with recommended next actions" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/result-packets"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-review-close",
  "workflow_type": "review_repair",
  "user_goal": "审阅第12章并修复",
  "scope": "第12章",
  "completion_policy": "stage_then_confirm",
  "current_stage": "closure",
  "current_step": "closure",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["range_lock", "evidence_scan", "classify_findings", "repair_plan", "user_scope_choice", "execute_repair", "recheck"],
    "remaining_stages": ["closure"]
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/result.json" <<'JSON'
{
  "workflow_id": "wf-review-close",
  "workflow_type": "review_repair",
  "stage_id": "closure",
  "step_id": "closure",
  "step_status": "completed",
  "changed_files": ["追踪/审查报告/第12章.md"],
  "verification_result": "pass",
  "next_recommendation": [
    {"number": 1, "action_id": "start_new_workflow", "label": "继续审阅第13章", "workflow_type": "review_repair", "scope": "第13章"},
    {"number": 2, "action_id": "start_new_workflow", "label": "写第13章", "workflow_type": "long_write", "scope": "第13章"},
    {"number": 3, "action_id": "finish_session", "label": "结束本轮"}
  ]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json > "$TMP_DIR/out.json"

    grep -Eq '"status": "(advanced|stage_started)"' "$TMP_DIR/out.json"
    task_file="$(focused_task_file "$TMP_DIR/book")"
    grep -q '"status": "completed"' "$task_file"
    grep -q '"question": "流程已完成，请选择下一步"' "$task_file"
    grep -q '"label": "继续审阅第13章"' "$task_file"
    grep -q '"label": "结束本轮"' "$task_file"
    grep -q '"event":"completed"' "$TMP_DIR/book/追踪/workflow/history.jsonl"
}

@test "workflow state machine blocks mismatched result packet" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-review-002",
  "workflow_type": "review_repair",
  "completion_policy": "stage_then_confirm",
  "current_stage": "repair_plan",
  "current_step": "build_plan",
  "status": "running"
}

JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/result.json" <<'JSON'
{
  "workflow_id": "wf-review-002",
  "workflow_type": "review_repair",
  "stage_id": "execute_repair",
  "step_id": "build_plan",
  "step_status": "completed",
  "verification_result": "pass",
  "remaining_work": []
}
JSON

    status=0
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json > "$TMP_DIR/out.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_result_packet_invalid"' "$TMP_DIR/out.json"
    grep -q '"field": "stage_id"' "$TMP_DIR/out.json"
}

@test "invalid explicit next stage cannot falsely complete a workflow" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "写短篇" --no-private-registry --json > "$TMP_DIR/create.json"
    node - "$TMP_DIR/book" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const current=require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root);const task=JSON.parse(fs.readFileSync(current,'utf8'));
task.current_stage='section_machine_gate'; task.current_step='section_machine_gate'; task.status='running';
task.machine.completed_stages=['material_card','short_setting','rhythm_pattern_selection','section_outline','section_plan_lock','short_structure_impact_audit','hook_value_gate','section_brief','draft_section'];
task.machine.remaining_stages=['section_machine_gate','section_repair_loop','story_value_gate','section_accept_anchor','next_section_brief','full_story_assembly','deslop','final_check'];
task.stage_execution={status:'running',stage_id:'section_machine_gate',step_id:'section_machine_gate',expected_result_packet:`${task.task_dir}/result-packets/section_machine_gate.result.json`};
task.runtime_guard=task.runtime_guard||{};task.runtime_guard.checkpoint_policy={expected_result_packet:task.stage_execution.expected_result_packet};
fs.writeFileSync(current,JSON.stringify(task,null,2)+'\n');
const packet={workflow_id:task.workflow_id,workflow_type:task.workflow_type,owner_module:'story-short-write',stage_id:'section_machine_gate',step_id:'section_machine_gate',step_status:'completed',result_packet_path:task.stage_execution.expected_result_packet,outputs:[],changed_files:[],evidence:[],verification_result:'pass',checkpoint_state:{},output_health_result:'pass',next_stage_id:'final_check'};
const target=path.join(root,packet.result_packet_path);fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,JSON.stringify(packet,null,2)+'\n');
NODE
    status=0
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/book/追踪/workflow/tasks/$(node -e 'const x=require(process.argv[1]);process.stdout.write(x.workflow_id)' "$(focused_task_file "$TMP_DIR/book")")/result-packets/section_machine_gate.result.json" --json > "$TMP_DIR/out.json" || status=$?
    [ "$status" -eq 0 ]
    node - "$TMP_DIR/out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(!['advanced','stage_started'].includes(out.status)||task.status!=='running'||task.current_stage!=='section_machine_gate') throw new Error(JSON.stringify({out,task}));
if(task.machine.completed_stages.includes('section_machine_gate')) throw new Error(JSON.stringify(task.machine));
if(out.status==='stage_started' && (!task.stage_execution || task.stage_execution.status!=='running' || task.stage_execution.stage_id!=='section_machine_gate')) throw new Error(JSON.stringify(task.stage_execution));
NODE
}

@test "completed review missing execute_repair can be restored without changing the active task" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-incomplete-review/artifacts/staged_repair_candidate"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-incomplete-review/task.json" <<'JSON'
{
  "workflow_id":"wf-incomplete-review","workflow_type":"review_repair","status":"completed","scope":"1-200",
  "task_dir":"追踪/workflow/tasks/wf-incomplete-review","current_stage":"closure","current_step":"closure",
  "lifecycle":{"status":"completed"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","user_scope_choice","repair_execution_plan","staged_repair_candidate","repair_machine_gate","recheck","closure"],"remaining_stages":[]}
}

JSON
    printf '%s\n' '# staged draft' > "$TMP_DIR/book/追踪/workflow/tasks/wf-incomplete-review/artifacts/staged_repair_candidate/A1.draft.md"
    node "$SCRIPT" restore-incomplete-workflow --project-root "$TMP_DIR/book" --workflow-id wf-incomplete-review --confirm --json > "$TMP_DIR/restore.json"
    node - "$TMP_DIR/restore.json" "$TMP_DIR/book/追踪/workflow/tasks/wf-incomplete-review/task.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='workflow_integrity_restored'||out.resume_stage!=='execute_repair') throw new Error(JSON.stringify(out));
if(task.status!=='paused'||task.current_stage!=='execute_repair'||task.lifecycle.status!=='paused') throw new Error(JSON.stringify(task));
if(task.machine.completed_stages.includes('execute_repair')||task.machine.completed_stages.includes('recheck')||task.machine.remaining_stages[0]!=='execute_repair') throw new Error(JSON.stringify(task.machine));
if(task.integrity_recovery?.missing_stages?.join(',')!=='execute_repair') throw new Error(JSON.stringify(task.integrity_recovery));
NODE
}

@test "unmanaged repair recovery archives stale candidates and returns to execution planning" {
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/wf-unmanaged-repair"
    mkdir -p "$task_dir/artifacts/staged_repair_candidate" "$TMP_DIR/book/追踪/workflow"
    printf '%s\n' '# stale candidate' > "$task_dir/artifacts/staged_repair_candidate/A1.draft.md"
    cat > "$task_dir/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0","state_version":2,"workflow_id":"wf-unmanaged-repair","workflow_type":"review_repair","status":"running","scope":"1-200",
  "task_dir":"追踪/workflow/tasks/wf-unmanaged-repair","current_stage":"execute_repair","current_step":"execute_repair",
  "lifecycle":{"status":"active"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","user_scope_choice","repair_execution_plan","staged_repair_candidate","repair_machine_gate"],"remaining_stages":["execute_repair","recheck","closure"]},
  "runtime_guard":{"heartbeat":{},"checkpoint_policy":{}}
}
JSON
    cp "$task_dir/task.json" "$TMP_DIR/book/追踪/workflow/current-task.json"

    node "$SCRIPT" reset-unmanaged-review-repair --project-root "$TMP_DIR/book" --workflow-id wf-unmanaged-repair --reason "发现临时脚本直写" --confirm --json > "$TMP_DIR/recover.json"

    node - "$TMP_DIR/recover.json" "$task_dir/task.json" <<'NODE'
const fs=require('fs');const path=require('path');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));const root=path.resolve(path.dirname(process.argv[3]),'..','..','..','..');
if(out.status!=='review_repair_candidates_invalidated'||out.resume_stage!=='repair_execution_plan') throw new Error(JSON.stringify(out));
if(task.current_stage!=='repair_execution_plan'||task.status!=='running'||task.lifecycle.status!=='active') throw new Error(JSON.stringify(task));
if(task.machine.completed_stages.includes('repair_execution_plan')||task.machine.remaining_stages[0]!=='repair_execution_plan') throw new Error(JSON.stringify(task.machine));
if(task.pending_action.options[0].label!=='重新生成受控修复方案（推荐）') throw new Error(JSON.stringify(task.pending_action));
if(!task.repair_integrity_recovery?.untrusted_artifact_globs?.includes('scripts/apply-*.js')) throw new Error(JSON.stringify(task.repair_integrity_recovery));
if(!task.repair_integrity_recovery?.archived_candidate_dir || fs.existsSync(path.join(path.dirname(process.argv[3]),'artifacts/staged_repair_candidate'))) throw new Error(JSON.stringify(task.repair_integrity_recovery));
if(!fs.existsSync(path.join(root,task.repair_integrity_recovery.archived_candidate_dir))) throw new Error('archived candidate missing');
NODE

    node "$SCRIPT" reset-unmanaged-review-repair --project-root "$TMP_DIR/book" --workflow-id wf-unmanaged-repair --reason "重复恢复" --confirm --json > "$TMP_DIR/recover-again.json"
    node - "$TMP_DIR/recover-again.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(!out.archived_candidate_dir || !out.archived_candidate_dir.includes('staged_repair_candidate.archived-')) throw new Error(JSON.stringify(out));
NODE
}

@test "runtime reconciliation resets a contradictory repair lifecycle and records a session lease" {
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/wf-reconcile-repair"
    mkdir -p "$task_dir" "$TMP_DIR/book/追踪/workflow"
    cat > "$task_dir/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0","state_version":7,"workflow_id":"wf-reconcile-repair","workflow_type":"review_repair","status":"running","scope":"1-200章 范围审阅",
  "task_dir":"追踪/workflow/tasks/wf-reconcile-repair","current_stage":"repair_execution_plan","current_step":"repair_execution_plan",
  "lifecycle":{"status":"active"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","user_scope_choice"],"remaining_stages":["repair_execution_plan","staged_repair_candidate","repair_machine_gate","execute_repair","recheck","closure"]},
  "unit_lifecycle":{"status":"completed","current_stage":"closure","current_role":"handoff_and_next","completed_roles":["workflow_preflight","source_or_material","quality_gate","brief_or_contract","draft_or_execute","machine_quality_gate","handoff_and_next"]},
  "runtime_guard":{"heartbeat":{"latest_trusted_artifact":"追踪/workflow/tasks/wf-reconcile-repair/artifacts/staged_repair_candidate.archived-2026-07-11/"},"checkpoint_policy":{}},
  "repair_integrity_recovery":{"reason":"检测到临时修复脚本绕过候选稿和事务接受链","archived_candidate_dir":"追踪/workflow/tasks/wf-reconcile-repair/artifacts/staged_repair_candidate.archived-2026-07-11"},
  "pending_action":{"id":"pa-rebuild","status":"pending","options":[{"number":1,"label":"重新生成受控修复方案","action_id":"continue_next_stage"}]}
}
JSON
    cp "$task_dir/task.json" "$TMP_DIR/book/追踪/workflow/current-task.json"

    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-reconcile-repair --session-id claude-100 --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "runtime_reconciled"'* ]]

    node - "$task_dir/task.json" <<'NODE'
const fs=require('fs'); const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(task.unit_lifecycle.status!=='running'||task.unit_lifecycle.current_stage!=='repair_execution_plan'||task.unit_lifecycle.current_role!=='brief_or_contract') throw new Error(JSON.stringify(task.unit_lifecycle));
if(task.runtime_guard.session_lease.holder_id!=='claude-100') throw new Error(JSON.stringify(task.runtime_guard.session_lease));
if(task.runtime_guard.heartbeat.latest_trusted_artifact.includes('archived-')) throw new Error(JSON.stringify(task.runtime_guard.heartbeat));
if(task.pending_action.options[0].label!=='重新生成受控修复方案') throw new Error(JSON.stringify(task.pending_action));
NODE
}

@test "runtime reconciliation refuses a second live session unless takeover is confirmed" {
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/wf-session-lease"
    mkdir -p "$task_dir" "$TMP_DIR/book/追踪/workflow"
    cat > "$task_dir/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0","state_version":1,"workflow_id":"wf-session-lease","workflow_type":"long_write","status":"running","scope":"第1卷第001章",
  "task_dir":"追踪/workflow/tasks/wf-session-lease","current_stage":"chapter_brief","current_step":"chapter_brief",
  "lifecycle":{"status":"active"},"machine":{"completed_stages":["positioning","story_bible","master_outline","master_outline_review","volume_outline","volume_outline_review","stage_detail_outline","detail_outline_review"],"remaining_stages":["chapter_brief","brief_review","prose","prose_acceptance","chapter_commit","milestone_review","volume_acceptance","book_acceptance"]},
  "runtime_guard":{"heartbeat":{},"checkpoint_policy":{}},"pending_action":{"id":"pa-chapter","status":"pending","options":[]}
}
JSON
    cp "$task_dir/task.json" "$TMP_DIR/book/追踪/workflow/current-task.json"

    node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-session-lease --session-id claude-older --json > "$TMP_DIR/first.json"
    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-session-lease --session-id claude-newer --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'workflow_session_takeover_required'* ]]
    [[ "$output" == *'确认接管当前任务'* ]]
    [[ "$output" == *'只读查看当前进度'* ]]
    [[ "$output" == *'暂不接管'* ]]

    node - "$task_dir/task.json" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(task.runtime_guard.session_lease.holder_id!=='claude-older') throw new Error(JSON.stringify(task.runtime_guard.session_lease));
if(task.machine.last_transition==='runtime_reconciled' && task.updated_by_session==='claude-newer') throw new Error('observer session mutated task');
NODE

    node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-session-lease --session-id claude-newer --takeover --confirm --json > "$TMP_DIR/takeover.json"
    node - "$TMP_DIR/takeover.json" "$task_dir/task.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='runtime_reconciled'||out.session_takeover!==true) throw new Error(JSON.stringify(out));
if(task.runtime_guard.session_lease.holder_id!=='claude-newer') throw new Error(JSON.stringify(task.runtime_guard.session_lease));
NODE
}

@test "runtime reconciliation resumes a private short project from its latest accepted section and brief" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id":"wf-short-cross-host","workflow_type":"short_write","status":"running","scope":"",
  "current_stage":"section_plan_lock","current_step":"section_plan_lock",
  "machine":{"completed_stages":["short_setting","platform_genre_lock","rhythm_pattern_selection","section_outline"],"remaining_stages":["section_plan_lock"]},
  "runtime_guard":{"heartbeat":{},"checkpoint_policy":{}},
  "pending_action":{"id":"pa-stale-plan","options":[{"number":1,"target_stage":"section_plan_lock"}]}
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{
  "workflow_type":"short_write","status":"section_005_brief_ready","current_stage":"section_draft_ready",
  "accepted_sections":[
    {"section_index":1,"anchor_path":"追踪/private-short-extension/section-001-anchor.json"},
    {"section_index":2,"anchor_path":"追踪/private-short-extension/section-002-anchor.json"},
    {"section_index":3,"anchor_path":"追踪/private-short-extension/section-003-anchor.json"},
    {"section_index":4,"anchor_path":"追踪/private-short-extension/section-004-anchor.json"}
  ]
}
JSON
    for index in 001 002 003 004; do printf '{"status":"accepted"}\n' > "$TMP_DIR/book/追踪/private-short-extension/section-$index-anchor.json"; done
    cat > "$TMP_DIR/book/追踪/private-short-extension/section-title-lock.json" <<'JSON'
{"status":"confirmed","sections":[{"section_index":5,"title":"第五节","confirmed":true}]}
JSON
    printf '%s\n' '# 第005节 Brief' > "$TMP_DIR/book/写作Brief_第005节.md"

    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-short-cross-host --session-id claude-switch --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"project_progress_reconciled": true'* ]]

    node - "$(focused_task_file "$TMP_DIR/book")" "$REPO/src/private-internal-skills/private-short-extension/workflow-registry.json" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const expectedStage=fs.existsSync(process.argv[3])?'draft_next_section':'draft_section';
if(task.current_stage!==expectedStage||task.scope!=='第5节') throw new Error(JSON.stringify({stage:task.current_stage,scope:task.scope,expectedStage}));
if(task.short_project_resume.latest_brief!=='写作Brief_第005节.md') throw new Error(JSON.stringify(task.short_project_resume));
if(!task.pending_action||task.pending_action.options[0].target_stage!==expectedStage) throw new Error(JSON.stringify(task.pending_action));
if(task.book_root!=='.'||task.runtime_guard.checkpoint_policy.project_root!=='.'||task.pending_action.book_root!=='.') throw new Error(JSON.stringify({book_root:task.book_root,checkpoint:task.runtime_guard.checkpoint_policy,pending:task.pending_action}));
NODE
}

@test "runtime reconciliation rejects a stale accepted-section brief and returns to next title confirmation" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id":"wf-short-stale-brief","workflow_type":"short_write","status":"running","scope":"第6节",
  "current_stage":"draft_next_section","current_step":"draft_next_section",
  "machine":{"completed_stages":["short_setting","platform_genre_lock","rhythm_pattern_selection","section_outline","next_section_brief"],"remaining_stages":["draft_next_section"]},
  "runtime_guard":{"heartbeat":{},"checkpoint_policy":{}},
  "stage_execution":{"status":"completed","stage_id":"next_section_brief"}
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{
  "status":"section_006_brief_ready","current_stage":"section_draft_ready","current_section_index":6,
  "narrative":{"planned_sections":8},
  "accepted_sections":[
    {"section_index":1,"anchor_path":"追踪/private-short-extension/section-001-anchor.json"},
    {"section_index":2,"anchor_path":"追踪/private-short-extension/section-002-anchor.json"},
    {"section_index":3,"anchor_path":"追踪/private-short-extension/section-003-anchor.json"},
    {"section_index":4,"anchor_path":"追踪/private-short-extension/section-004-anchor.json"},
    {"section_index":5,"anchor_path":"追踪/private-short-extension/section-005-anchor.json"},
    {"section_index":6,"anchor_path":"追踪/private-short-extension/section-006-anchor.json"}
  ]
}
JSON
    for index in 001 002 003 004 005 006; do printf '{"status":"accepted"}\n' > "$TMP_DIR/book/追踪/private-short-extension/section-$index-anchor.json"; done

    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-short-stale-brief --session-id claude-switch --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"project_progress_reconciled": true'* ]]

    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(task.current_stage!=='next_section_brief'||task.scope!=='第7节') throw new Error(JSON.stringify({stage:task.current_stage,scope:task.scope}));
if(task.short_project_resume.reason!=='section_title_confirmation_required') throw new Error(JSON.stringify(task.short_project_resume));
if(!task.pending_action||task.pending_action.options[0].target_stage!=='next_section_brief') throw new Error(JSON.stringify(task.pending_action));
NODE
}

@test "runtime reconciliation prefers the current section quality receipt over a stale brief-ready project status" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id":"wf-short-quality-resume","workflow_type":"short_write","status":"running","scope":"第5节",
  "current_stage":"draft_next_section","current_step":"draft_next_section",
  "machine":{"completed_stages":["short_setting","platform_genre_lock","rhythm_pattern_selection","section_outline","next_section_brief"],"remaining_stages":["draft_next_section","section_machine_gate","quality_gate","section_accept_anchor"]},
  "runtime_guard":{"heartbeat":{},"checkpoint_policy":{}},
  "pending_action":{"id":"pa-draft","options":[{"number":1,"target_stage":"draft_next_section"}]}
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    task_file="$(focused_task_file "$TMP_DIR/book")"
    task_dir="$(node -e 'const x=require(process.argv[1]);process.stdout.write(x.task_dir)' "$task_file")"
    mkdir -p "$TMP_DIR/book/$task_dir/result-packets"
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{
  "workflow_type":"short_write","status":"section_005_brief_ready","current_stage":"section_draft_ready",
  "narrative":{"planned_sections":8},
  "accepted_sections":[
    {"section_index":1,"anchor_path":"追踪/private-short-extension/section-001-anchor.json"},
    {"section_index":2,"anchor_path":"追踪/private-short-extension/section-002-anchor.json"},
    {"section_index":3,"anchor_path":"追踪/private-short-extension/section-003-anchor.json"},
    {"section_index":4,"anchor_path":"追踪/private-short-extension/section-004-anchor.json"}
  ]
}
JSON
    for index in 001 002 003 004; do printf '{"status":"accepted"}\n' > "$TMP_DIR/book/追踪/private-short-extension/section-$index-anchor.json"; done
    printf '%s\n' '# 第005节 Brief' > "$TMP_DIR/book/写作Brief_第005节.md"
    cat > "$TMP_DIR/book/$task_dir/result-packets/quality_gate.result.json" <<'JSON'
{"workflow_id":"wf-short-quality-resume","stage_id":"quality_gate","current_section_index":5,"verification_result":"pass","quality_gate_result":"pass","blocking_findings":[],"next_stage_id":"section_accept_anchor"}
JSON

    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-short-quality-resume --session-id claude-switch --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"project_progress_reconciled": true'* ]]

    node - "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(task.current_stage!=='section_accept_anchor'||task.scope!=='第5节') throw new Error(JSON.stringify({stage:task.current_stage,scope:task.scope}));
if(task.short_project_resume.evidence_stage!=='quality_gate') throw new Error(JSON.stringify(task.short_project_resume));
if(!task.runtime_guard.heartbeat.latest_trusted_artifact.endsWith('/quality_gate.result.json')) throw new Error(JSON.stringify(task.runtime_guard.heartbeat));
NODE
}

@test "runtime reconciliation closes a nine-section plan instead of inventing section ten" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id":"wf-short-plan-complete","workflow_type":"short_write","status":"running","scope":"第10节",
  "current_stage":"next_section_brief","current_step":"next_section_brief",
  "machine":{"completed_stages":["short_setting","platform_genre_lock","rhythm_pattern_selection","section_outline","section_accept_anchor"],"remaining_stages":["next_section_brief"]},
  "runtime_guard":{"heartbeat":{},"checkpoint_policy":{}},
  "stage_execution":{"status":"running","stage_id":"next_section_brief"}
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"
    node - "$TMP_DIR/book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const accepted=Array.from({length:9},(_,i)=>({section_index:i+1,anchor_path:`追踪/private-short-extension/section-${String(i+1).padStart(3,'0')}-anchor.json`}));
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({
  workflow_type:'short_write',status:'section_009_brief_ready',current_stage:'section_draft_ready',current_section_index:9,
  narrative:{planned_sections:9},accepted_sections:accepted,remaining_sections:[]
},null,2));
fs.writeFileSync(path.join(root,'追踪/private-short-extension/section-title-lock.json'),JSON.stringify({
  status:'confirmed',sections:Array.from({length:9},(_,i)=>({section_index:i+1,title:`第${i+1}节`,confirmed:true}))
},null,2));
for(const item of accepted) fs.writeFileSync(path.join(root,item.anchor_path),JSON.stringify({status:'accepted',section_index:item.section_index}));
fs.writeFileSync(path.join(root,'小节大纲.md'),'- 总小节数：9节。\n\n## 第9节：结尾\n');
NODE

    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id wf-short-plan-complete --session-id claude-switch --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"project_progress_reconciled": true'* ]]
    [[ "$output" == *'"reason": "planned_story_complete"'* ]]

    node - "$(focused_task_file "$TMP_DIR/book")" "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'NODE'
const fs=require('fs');
const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const state=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(task.current_stage!=='full_story_assembly'||task.scope!=='全篇') throw new Error(JSON.stringify({stage:task.current_stage,scope:task.scope}));
if(task.short_project_resume.reason!=='planned_story_complete') throw new Error(JSON.stringify(task.short_project_resume));
if(state.status!=='all_sections_accepted'||state.current_section_index!==9||state.remaining_sections.length!==0) throw new Error(JSON.stringify(state));
NODE
    [ ! -e "$TMP_DIR/book/写作Brief_第010节.md" ]
}

@test "long-write chapter commit cannot advance without an accepted transaction" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-long-commit",
  "workflow_type": "long_write",
  "completion_policy": "stage_then_confirm",
  "current_stage": "chapter_commit",
  "current_step": "chapter_commit",
  "status": "running",
  "machine": {
    "completed_stages": ["positioning","story_bible","master_outline","master_outline_review","volume_outline","volume_outline_review","stage_detail_outline","detail_outline_review","chapter_brief","brief_review","prose","prose_acceptance"],
    "remaining_stages": ["chapter_commit","milestone_review","volume_acceptance","book_acceptance"]
  }
}
JSON
    attach_long_lifecycle_graph "$TMP_DIR/book"
    migrate_legacy_fixture "$TMP_DIR/book"
    cat > "$TMP_DIR/result.json" <<'JSON'
{
  "workflow_id": "wf-long-commit",
  "workflow_type": "long_write",
  "stage_id": "chapter_commit",
  "step_id": "chapter_commit",
  "step_status": "completed",
  "verification_result": "pass",
  "changed_files": ["正文/第1卷/第001章_起点.md"]
}
JSON

    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_chapter_commit_missing'* ]]
}

@test "long-write chapter commit validates the immutable commit file before advancing" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/story-system/commits"
    write_long_commit_task "wf-long-commit"
    write_accepted_commit
    write_transactional_commit_result "wf-long-commit" "projection_current" false

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json > "$TMP_DIR/out.json"
    grep -Eq '"status": "(advanced|stage_started)"' "$TMP_DIR/out.json"
    grep -q '"current_stage": "milestone_review"' "$(focused_task_file "$TMP_DIR/book")"

    write_long_commit_task "wf-long-commit-tampered"
    write_transactional_commit_result "wf-long-commit-tampered" "projection_current" false
    printf '会话外篡改\n' >> "$TMP_DIR/book/正文/第1卷/第001章_起点.md"
    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_chapter_commit_invalid'* ]]
}

@test "long-write chapter commit blocks projection debt but preserves explicit legacy compatibility" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/story-system/commits"
    write_long_commit_task "wf-long-projection"
    write_accepted_commit
    write_transactional_commit_result "wf-long-projection" "projection_failed" true

    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_chapter_projection_debt'* ]]

    write_long_commit_task "wf-long-projection-legacy"
    write_transactional_commit_result "wf-long-projection-legacy" "projection_failed" true
    node -e '
      const fs=require("fs"); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p,"utf8"));
      x.chapter_commit={mode:"legacy_nontransactional",legacy_reason:"旧项目保留平铺直写结构",risk_acknowledged:true};
      fs.writeFileSync(p,JSON.stringify(x));
    ' "$TMP_DIR/result.json"
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json > "$TMP_DIR/legacy.json"
    grep -Eq '"status": "(advanced|stage_started)"' "$TMP_DIR/legacy.json"
}

@test "workflow state machine stops full auto before high risk write stage" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_id": "wf-setup-001",
  "workflow_type": "setup_update",
  "completion_policy": "full_auto",
  "current_stage": "refresh_runtime",
  "current_step": "sync_runtime",
  "status": "running",
  "machine": {
    "template_version": "1.0.0",
    "completed_stages": ["version_check", "deployment_check"],
    "remaining_stages": ["refresh_runtime", "migration_decision", "verification"]
  }
}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"

    node "$SCRIPT" next-candidates --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"status": "requires_user_confirm"' "$TMP_DIR/out.json"
    grep -q '"target_stage": "refresh_runtime"' "$TMP_DIR/out.json"
}

@test "workflow state machine is documented bundled and smoke covered" {
    grep -q '"workflow-state-machine.js"' "$REPO/config/novel-assistant-bundle-files.json"
    grep -q "workflow_state_machine" "$SMOKE"
    grep -q "workflow-state-machine.js" "$WORKFLOW"
    grep -q "state machine" "$CONTRACT"
    grep -q "创作单元生命周期" "$WORKFLOW"
    grep -q "phase-protocol-index.md" "$WORKFLOW"
    grep -q "## lifecycle" "$CONTRACT"
    grep -q "switch-intent" "$CONTRACT"
    grep -q "switch-intent" "$SCRIPT"
    grep -q "workflow-state-machine.js" "$SCRIPTS_README"
    test -x "$BUNDLE/scripts/workflow-state-machine.js"
    grep -q "switch-intent" "$BUNDLE/scripts/workflow-state-machine.js"
    grep -q "创作单元生命周期" "$BUNDLE/references/internal-skills/story-workflow/SKILL.md"
    grep -q "switch-intent" "$BUNDLE/references/internal-skills/story-workflow/references/phase-protocol-index.md"
}

@test "compact task activation returns only the current execution contract" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "新开短篇" --json > "$TMP_DIR/create.json"
    workflow_id="$(node -e 'console.log(require(process.argv[1]).task.workflow_id)' "$TMP_DIR/create.json")"

    node "$SCRIPT" activate --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --compact --json > "$TMP_DIR/activate.json"

    node - "$TMP_DIR/activate.json" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const raw=fs.readFileSync(file,'utf8');
const out=JSON.parse(raw);
if(!['activated','stage_started'].includes(out.status)||!out.task||out.task.workflow_id==='') throw new Error(raw);
if(raw.length>12000) throw new Error(`compact activation too large: ${raw.length}`);
for(const forbidden of ['runtime_guard','task_family','result_packets','history','journal']) {
  if(Object.prototype.hasOwnProperty.call(out.task,forbidden)) throw new Error(raw);
}

NODE
}

@test "short review starts with one deterministic context and advance command" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_review --project-root "$TMP_DIR/book" --user-goal "验收短篇" --json > "$TMP_DIR/create.json"
    workflow_id="$(node -e 'console.log(require(process.argv[1]).task.workflow_id)' "$TMP_DIR/create.json")"

    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 1 --bind-current --json > "$TMP_DIR/start.json"

    node - "$TMP_DIR/start.json" <<'NODE'
const out=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));
const execution=out.stage_execution || (out.task||{}).stage_execution || {};
if(execution.stage_id!=='scope_lock') throw new Error(JSON.stringify(out));
if(!String(execution.context_read_command||'').includes('workflow-stage-context.js read-current')) throw new Error(JSON.stringify(execution));
if(!String(execution.execution_command||'').includes('workflow-stage-controller.js advance')) throw new Error(JSON.stringify(execution));
if(!String(execution.execution_command||'').includes('--result')) throw new Error(JSON.stringify(execution));
if(!String(execution.resume_hint||'').includes('不猜脚本参数')) throw new Error(JSON.stringify(execution));
NODE
}

@test "v2 result packet cannot omit the authoritative owner module" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "新开短篇" --no-private-registry --json >/dev/null
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.result_contract_version=2;
task.current_stage='material_card';task.current_step='material_card';task.status='running';
task.stage_execution={status:'running',stage_id:'material_card',step_id:'material_card',owner_module:'story-short-write',expected_result_packet:`${task.task_dir}/result-packets/material_card.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    result_file="$(dirname "$task_file")/result-packets/material_card.result.json"
    mkdir -p "$(dirname "$result_file")"
    cat > "$result_file" <<JSON
{"workflow_id":"$(jq -r .workflow_id "$task_file")","workflow_type":"short_write","stage_id":"material_card","step_id":"material_card","step_status":"completed"}
JSON

    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --workflow-id "$(jq -r .workflow_id "$task_file")" --result "$result_file" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_result_packet_invalid'* ]]
    [[ "$output" == *'owner_module'* ]]
}

@test "feedback audit reclassification binds only to the accepted plan" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "新开短篇" --json >/dev/null
    task_file="$(focused_task_file "$TMP_DIR/book")"
    workflow_id="$(jq -r .workflow_id "$task_file")"
    inbox="$(dirname "$task_file")/feedback-inbox.jsonl"
    printf '%s\n' '{"event_type":"feedback_discarded","feedback_id":"feedback-summary","workflow_id":"'"$workflow_id"'"}' > "$inbox"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.accepted_plan={plan_id:'accepted-plan.feedback-final',status:'accepted'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" reclassify-short-feedback-item --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --feedback-id feedback-summary --plan-id accepted-plan.wrong --confirm --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_short_accepted_plan_mismatch'* ]]

    run node "$SCRIPT" reclassify-short-feedback-item --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --feedback-id feedback-summary --confirm --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'feedback_item_reclassified'* ]]
    grep -q '"preserved_by_plan_id":"accepted-plan.feedback-final"' "$inbox"
}
