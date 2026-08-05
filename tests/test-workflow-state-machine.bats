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

    # V2 short creation and mutation are intentionally frozen.  These cases
    # exercise the retired V2-only menus/state transitions, whose production
    # replacements live in test-workflow-v3-{new-project,interaction,feedback,
    # section-loop,closure,new-short-e2e}.bats.  Keep the skip list exact so
    # generic state-machine and migration-facade assertions still run here.
    case "$BATS_TEST_DESCRIPTION" in
      "activation repairs a short revision task that incorrectly jumped to whole-story assembly"|\
      "activation skips a legacy plan relock when a planning revision queue already identifies current sections"|\
      "next-candidates and resolve-action share the grouped queue menu"|\
      "short revision brief menu presents the user task instead of the internal brief step"|\
      "confirmed feedback revision skips the redundant prose entry confirmation"|\
      "activating a whole-story revision opens task overview without starting its section"|\
      "task overview adjustment enters chat impact analysis instead of resolving to nowhere"|\
      "workflow state machine routes short free text feedback into impact analysis"|\
      "new short tasks keep one workflow identity and select the installed owner profile"|\
      "private shortform startup workflow is explicit and UI friendly"|\
      "new private short startup shows freshness menu before bounded discovery"|\
      "material learning stage always carries a bounded deterministic execution contract"|\
      "project seed uses one numeric card namespace and promotes the selected card directly"|\
      "project seed multi selection creates isolated child projects"|\
      "project seed text commands inspect reject and regenerate without a second menu namespace"|\
      "legacy project seed cards must re-enter material learning before selection"|\
      "private short startup restart preserves old workflow and creates a clean successor"|\
      "private short free text can restart info discovery without reading skill internals"|\
      "short feedback patch cannot bypass upstream planning"|\
      "whole story short feedback uses a story result packet instead of the last section suffix"|\
      "short feedback impact stage exposes a writable completion contract"|\
      "stale running feedback impact contract returns one deterministic recovery command"|\
      "feedback impact completion rejects a result from another feedback batch"|\
      "running feedback impact normalizes a stale host command to the authoritative completion command"|\
      "natural whole story rework feedback enters the existing short workflow"|\
      "pending short feedback recovery ignores an older feedback impact result"|\
      "pending planning feedback recovery returns to the bound proposal menu before canonical writes"|\
      "feedback proposal choice rejects a proposal changed after the menu was rendered"|\
      "pending expression-only short feedback resumes section repair without impact reanalysis"|\
      "new short feedback invalidates an older completed impact stage and gets a batch-scoped packet"|\
      "continue an accepted feedback plan does not become a second feedback item"|\
      "a repeated numeric reply resumes the running stage instead of reopening the resolved menu"|\
      "next-candidates silently resumes a running stage without an active menu"|\
      "running stage menu keeps inspect pause and free text distinct from resume"|\
      "discarding a host continuation echo restores the matching trusted feedback analysis"|\
      "free text short feedback starts impact analysis instead of binding an old menu"|\
      "short structure feedback is detected before generic edit feedback"|\
      "deleting one sentence remains artifact feedback instead of structure feedback"|\
      "workflow state machine branches private short section machine gate by pass or blocking result"|\
      "workflow state machine rejects stale short section result packet"|\
      "private workflow registry authority: moved book still resumes private overlay; unavailable registry blocks instead of degrading"|\
      "workflow state machine blocks ambiguous machine gate result packets"|\
      "workflow state machine locks one-section-and-stop option boundaries"|\
      "invalid explicit next stage cannot falsely complete a workflow"|\
      "runtime reconciliation resumes a private short project from its latest accepted section and brief"|\
      "runtime reconciliation rejects a stale accepted-section brief and returns to next title confirmation"|\
      "runtime reconciliation prefers the current section quality receipt over a stale brief-ready project status"|\
      "runtime reconciliation closes a nine-section plan instead of inventing section ten"|\
      "v2 result packet cannot omit the authoritative owner module"|\
      "feedback audit reclassification binds only to the accepted plan"|\
      "internal short planning stages receive an applying completion command"|\
      "fresh short setting candidate still stops before applying"|\
      "short revision queue advances to next pending section after accepting current section"|\
      "short revision queue routes to whole-story assembly after accepting the last pending section")
        skip "retired V2 short-only behavior; covered by the dedicated V3 short workflow suites"
        ;;
    esac
}

@test "source checkout prefers canonical src private registry before generated bundle copies" {
    run node - "$REPO/scripts/lib/workflow-template-registry.js" "$REPO/src/private-internal-skills" <<'NODE'
const path=require('path');
const registry=require(process.argv[2]);
const roots=registry.registryRoots('',false);
if(path.resolve(roots[0])!==path.resolve(process.argv[3])) throw new Error(JSON.stringify(roots));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "state machine usage documents apply-result workflow authority" {
    run node "$SCRIPT" templates --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'apply-result --project-root <book-dir> --workflow-id <id> --result <file>'* ]]
}

@test "reconcile repairs premature longform volume acceptance with one coherent continuation scope" {
    run node - "$SCRIPT" "$TMP_DIR/book" "$REPO" <<'NODE'
const cp=require('child_process'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3],repo=process.argv[4];
const created=cp.spawnSync(process.execPath,[script,'create','--workflow-type','long_write','--project-root',root,'--user-goal','继续长篇','--json'],{encoding:'utf8'});
if(created.status!==0) throw new Error(created.stdout||created.stderr);
const task=JSON.parse(created.stdout).task;
const taskFile=path.join(root,task.task_dir,'task.json');
const stageIds=task.lifecycle_graph.nodes.map((node)=>node.id);
const volumeIndex=stageIds.indexOf('volume_acceptance');
const reviewIndex=stageIds.indexOf('detail_outline_review');
const outlineDir=path.join(root,'大纲','第2卷');
fs.mkdirSync(outlineDir,{recursive:true});
for(let chapter=3;chapter<=5;chapter+=1) fs.writeFileSync(path.join(outlineDir,`细纲_第${String(chapter).padStart(3,'0')}章.md`),`# 第${chapter}章\n\n中性细纲 ${chapter}\n`);
fs.mkdirSync(path.join(root,'追踪/schema'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/schema/chapters.jsonl'),[3,4,5].map((chapter)=>JSON.stringify({
  chapterId:`第${String(chapter+26).padStart(3,'0')}章`,chapterNo:chapter+26,volume:'第2卷',volumeChapterNo:chapter,globalDraftOrder:chapter+26,
  outlinePath:`大纲/第2卷/细纲_第${String(chapter).padStart(3,'0')}章.md`,contractPath:`追踪/章节契约/第2卷/第${String(chapter).padStart(3,'0')}章.md`,
  draftPath:chapter<5?`正文/第2卷/第${String(chapter).padStart(3,'0')}章.md`:''
})).join('\n')+'\n');
const acceptedRel='大纲/第2卷/细纲_第003章.md';
task.current_stage='volume_acceptance';task.current_step='volume_acceptance';task.status='running';
task.scope='第2卷验收';
task.accepted_detail_outline_targets=[{
  outline_path:acceptedRel,
  outline_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(root,acceptedRel))).digest('hex'),
  volume_chapter_no:3,
}];
task.machine={...task.machine,completed_stages:stageIds.slice(0,volumeIndex),remaining_stages:stageIds.slice(volumeIndex)};
task.lifecycle={...(task.lifecycle||{}),scope:'第2卷验收'};
task.lifecycle_graph.current_node='volume_acceptance';
task.lifecycle_graph.completed_nodes=stageIds.slice(0,volumeIndex);
task.lifecycle_graph.invalidated_nodes=[];
task.lifecycle_graph.review_results={
  master_outline_review:{status:'accepted',verification_result:'pass',result_packet_path:`${task.task_dir}/result-packets/master_outline_review.result.json`},
  volume_outline_review:{status:'accepted',verification_result:'pass',result_packet_path:`${task.task_dir}/result-packets/volume_outline_review.result.json`},
};
fs.mkdirSync(path.join(root,task.task_dir,'result-packets'),{recursive:true});
for(const stageId of ['master_outline_review','volume_outline_review']) {
  const packetRel=`${task.task_dir}/result-packets/${stageId}.result.json`;
  fs.writeFileSync(path.join(root,packetRel),JSON.stringify({workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:stageId,step_id:stageId,step_status:'completed',verification_result:'pass',review_decision:'accepted'}));
}
const staleDetailRel=`${task.task_dir}/result-packets/detail_outline_review.result.json`;
fs.writeFileSync(path.join(root,staleDetailRel),JSON.stringify({workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'detail_outline_review',step_id:'detail_outline_review',step_status:'completed',verification_result:'pass',review_decision:'accepted',outputs:{detail_outline_quality:{version:'detail_outline_quality_v2',identities:[{outline_path:acceptedRel}]}}}));
task.stage_attempt_history=['master_outline_review','volume_outline_review'].map(stageId=>({stage_attempt_id:`sa-${stageId}`,work_unit_id:`wu-${stageId}`,stage_id:stageId,status:'completed',accepted_result_packet:`${task.task_dir}/result-packets/${stageId}.result.json`,expected_result_packet:`${task.task_dir}/result-packets/${stageId}.result.json`}));
task.stage_execution={
  status:'running',stage_id:'volume_acceptance',step_id:'volume_acceptance',
  stage_attempt_id:'sa-premature-volume',work_unit_id:'wu-premature-volume',
  work_unit_scope:'第2卷验收',requires_user_confirm:true,
  expected_result_packet:`${task.task_dir}/result-packets/volume_acceptance.result.json`,
  write_set:[],result_contract:'long_write_result_v2',
};
task.longform_target_revalidation={status:'running',previous_scope:'第27至29章',write_snapshot_refreshed_at:'2026-08-03T00:00:00.000Z'};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const repaired=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:scope-continuation','--json'],{encoding:'utf8'});
if(repaired.status!==0) throw new Error(repaired.stdout||repaired.stderr);
const out=JSON.parse(repaired.stdout),next=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(out.status!=='runtime_reconciled'||out.premature_volume_acceptance_repaired!==true) throw new Error(JSON.stringify(out));
const expected='后续阶段细纲复核（2项）';
const scopes=[next.scope,next.lifecycle&&next.lifecycle.scope,next.unit_lifecycle&&next.unit_lifecycle.current_scope];
if(scopes.some((scope)=>scope!==expected)) throw new Error(JSON.stringify({expected,scopes}));
if(next.current_stage!=='detail_outline_review'||next.stage_execution!==null||!next.pending_action||!String((next.pending_action.options||[])[0]?.label||'').includes('复核后续阶段细纲')) throw new Error(JSON.stringify(next));
if(String(((next.longform_target_revalidation||{}).status)||'')==='running') throw new Error(JSON.stringify(next.longform_target_revalidation));
if((next.machine.completed_stages||[]).length!==reviewIndex) throw new Error(JSON.stringify(next.machine));
if(!next.lifecycle_graph.review_results.master_outline_review||!next.lifecycle_graph.review_results.volume_outline_review) throw new Error(JSON.stringify(next.lifecycle_graph.review_results));
if(fs.existsSync(path.join(root,staleDetailRel))||!next.longform_scope_continuation.archived_result_packet||!fs.existsSync(path.join(root,next.longform_scope_continuation.archived_result_packet))) throw new Error(JSON.stringify(next.longform_scope_continuation));
const started=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--bind-current','--json'],{encoding:'utf8'});
if(started.status!==0) throw new Error(started.stdout||started.stderr);
const running=JSON.parse(fs.readFileSync(taskFile,'utf8')),runningExecution=running.stage_execution||{};
const runningScopes=[running.scope,running.lifecycle&&running.lifecycle.scope,running.unit_lifecycle&&running.unit_lifecycle.current_scope,runningExecution.work_unit_scope,runningExecution.confirmation_context&&runningExecution.confirmation_context.target_scope,runningExecution.memory_context&&runningExecution.memory_context.memory_contract&&runningExecution.memory_context.memory_contract.query&&runningExecution.memory_context.memory_contract.query.scope&&runningExecution.memory_context.memory_contract.query.scope.target];
if(runningScopes.some((scope)=>scope!==expected)||runningExecution.stage_id!=='detail_outline_review'||(runningExecution.review_targets||[]).length!==2) throw new Error(JSON.stringify({runningScopes,runningExecution}));
const schemaRows=fs.readFileSync(path.join(root,'追踪/schema/chapters.jsonl'),'utf8').trim().split(/\r?\n/).map(JSON.parse);
const planned=schemaRows.find((row)=>row.outlinePath==='大纲/第2卷/细纲_第005章.md');
if(!planned||planned.draftPath!==''||planned.plannedDraftPath!=='正文/第2卷/第005章.md'||((runningExecution.schema_migration||{}).changed_count)!==1) throw new Error(JSON.stringify({planned,migration:runningExecution.schema_migration}));
running.longform_target_revalidation={status:'running',previous_scope:'第27至29章',write_snapshot_refreshed_at:'2026-08-03T00:00:00.000Z'};
running.lifecycle.scope='全书第029章 / 第2卷第003章';
running.stage_execution.work_unit_scope='全书第029章 / 第2卷第003章';
running.stage_execution.confirmation_context={status:'confirmed',confirmation_token:'legacy-invalid',target_scope:'全书第029章 / 第2卷第003章'};
running.stage_execution.confirmation_token='legacy-invalid';
running.stage_execution.memory_context.memory_contract.query.scope.target='全书第029章 / 第2卷第003章';
running.lifecycle_graph.review_results={};
fs.writeFileSync(taskFile,JSON.stringify(running,null,2)+'\n');
const second=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:scope-continuation','--json'],{encoding:'utf8'});
if(second.status!==0) throw new Error(second.stdout||second.stderr);
const secondOut=JSON.parse(second.stdout);
if(secondOut.status!=='runtime_reconciled') throw new Error(JSON.stringify(secondOut));
const migrated=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const migratedScopes=[migrated.scope,migrated.lifecycle&&migrated.lifecycle.scope,migrated.unit_lifecycle&&migrated.unit_lifecycle.current_scope];
if(migratedScopes.some((scope)=>scope!==expected)||String(((migrated.longform_target_revalidation||{}).status)||'')==='running'||migrated.stage_execution!==null||!migrated.pending_action||secondOut.scope_continuation_confirmation_reset!==true||!migrated.lifecycle_graph.review_results.master_outline_review||!migrated.lifecycle_graph.review_results.volume_outline_review) throw new Error(JSON.stringify({migratedScopes,revalidation:migrated.longform_target_revalidation,review_results:migrated.lifecycle_graph.review_results,secondOut}));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
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

@test "short setting candidate menu keeps author control before canonical write" {
    run node - "$REPO/scripts/lib/workflow-action-renderer.js" <<'NODE'
const { buildShortSettingCandidatePendingAction } = require(process.argv[2]);
const pending = buildShortSettingCandidatePendingAction({workflow_id:'wf-setting',short_setting_candidate:{revision:2}});
const actions = pending.options.map(item => item.action_id);
if (actions.join(',') !== 'accept_short_setting_candidate,inspect_short_setting_candidate,request_short_setting_revision_input,pause') throw new Error(JSON.stringify(pending));
if (!pending.options[0].label.includes('推荐') || pending.options[0].requires_user_confirm !== true) throw new Error(JSON.stringify(pending.options[0]));
if (!pending.free_text_enabled) throw new Error('setting candidate must remain chat interruptible');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "visible menu never duplicates inspect when it is already the primary action" {
    run node - "$REPO/scripts/lib/workflow-action-renderer.js" <<'NODE'
const { decoratePendingAction } = require(process.argv[2]);
const pending = decoratePendingAction({
  id: 'pa-paused',
  question: '请选择下一步',
  options: [
    { action_id: 'inspect_current_state', label: '查看当前进度与依据', recommended: true },
    { action_id: 'pause', label: '暂停并保存断点' },
    { action_id: 'free_text', label: '输入其他要求' },
  ],
  free_text_enabled: true,
});
const inspectCount = pending.options.filter(item => item.action_id === 'inspect_current_state').length;
if (inspectCount !== 1) throw new Error(JSON.stringify(pending.options));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "activating a paused review stage recommends resuming that stage" {
  run node - "$SCRIPT" "$TMP_DIR/paused-review-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const create=cp.spawnSync(process.execPath,[script,'create','--workflow-type','long_write','--project-root',root,'--user-goal','继续长篇','--json'],{encoding:'utf8'});
if(create.status!==0) throw new Error(create.stdout||create.stderr);
const task=create.stdout?JSON.parse(create.stdout).task:null;
const taskFile=path.join(root,task.task_dir,'task.json');
task.current_stage='master_outline_review';task.current_step='master_outline_review';task.status='running';
task.stage_execution={status:'paused',stage_id:'master_outline_review',step_id:'master_outline_review',stop_reason:'user_paused_from_running_stage_menu'};
task.pending_action={id:'pa-stale-long-menu',question:'请选择下一步',options:[{number:1,action_id:'resume_paused_stage',target_stage:'master_outline_review',label:'继续总纲审阅（推荐）',description:'这是一段不应出现在 compact 控制台输出中的长描述'.repeat(30),recommended:true}],free_text_enabled:true};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const activate=cp.spawnSync(process.execPath,[script,'activate','--project-root',root,'--workflow-id',task.workflow_id,'--compact','--json'],{encoding:'utf8'});
if(activate.status!==0) throw new Error(activate.stdout||activate.stderr);
const out=JSON.parse(activate.stdout);
const options=((out.task||{}).pending_action||{}).options||[];
if(!options.length) throw new Error(activate.stdout);
if(options[0].action_id!=='resume_paused_stage'||options[0].target_stage!=='master_outline_review') throw new Error(activate.stdout);
if(!options[0].label.includes('继续当前任务')) throw new Error(activate.stdout);
if(JSON.stringify(out.task.pending_action).includes('长描述')) throw new Error(activate.stdout);
if(JSON.stringify(out.task_overview || {}).includes('description')) throw new Error(activate.stdout);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "compact activation never prints stage context packet prose" {
  run node - "$SCRIPT" "$TMP_DIR/running-context-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const create=cp.spawnSync(process.execPath,[script,'create','--workflow-type','long_write','--project-root',root,'--user-goal','继续长篇','--json'],{encoding:'utf8'});
if(create.status!==0) throw new Error(create.stdout||create.stderr);
const task=JSON.parse(create.stdout).task;
const taskFile=path.join(root,task.task_dir,'task.json');
task.current_stage='master_outline';task.current_step='master_outline';task.status='running';
task.stage_execution={
  status:'running',
  stage_id:'master_outline',
  step_id:'master_outline',
  expected_result_packet:'追踪/workflow/tasks/'+task.workflow_id+'/result-packets/master_outline.result.json',
  context_read_command:'node scripts/workflow-stage-context.js read-current --project-root . --json',
  execution_command:'node scripts/long-planning-stage-finalize.js --project-root . --workflow-id '+task.workflow_id+' --json',
  stage_context_packet:{
    packet_md:'这是一段不应出现在 compact 输出中的长上下文'.repeat(200),
    estimated_tokens:3200,
    token_budget:3600
  }
};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const activate=cp.spawnSync(process.execPath,[script,'activate','--project-root',root,'--workflow-id',task.workflow_id,'--compact','--json'],{encoding:'utf8'});
if(activate.status!==0) throw new Error(activate.stdout||activate.stderr);
const out=JSON.parse(activate.stdout);
const raw=JSON.stringify(out);
if(raw.includes('stage_context_packet')) throw new Error(activate.stdout);
if(raw.includes('不应出现在 compact 输出')) throw new Error(activate.stdout);
const execution=((out.task||{}).stage_execution)||{};
if(!String(execution.context_read_command||'').includes('workflow-stage-context.js')) throw new Error(activate.stdout);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "compact task overview uses compact follow-up commands and hides phase contracts" {
  run node - "$SCRIPT" "$TMP_DIR/compact-overview-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const create=cp.spawnSync(process.execPath,[script,'create','--workflow-type','long_write','--project-root',root,'--user-goal','写长篇','--json'],{encoding:'utf8'});
if(create.status!==0) throw new Error(create.stdout||create.stderr);
const task=JSON.parse(create.stdout).task;
const taskFile=path.join(root,task.task_dir,'task.json');
task.current_stage='master_outline_review';task.current_step='master_outline_review';task.status='running';
task.stage_execution={status:'paused',stage_id:'master_outline_review',step_id:'master_outline_review'};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
const overview=cp.spawnSync(process.execPath,[script,'task-overview','--project-root',root,'--compact','--json'],{encoding:'utf8'});
if(overview.status!==0) throw new Error(overview.stdout||overview.stderr);
const out=JSON.parse(overview.stdout);
const raw=JSON.stringify(out);
if(raw.includes('transition_contract')||raw.includes('interaction_contract')||raw.includes('stage_context_packet')) throw new Error(overview.stdout);
const commands=(out.visible_response.options||[]).map(item=>String(item.execution_command||'')).filter(Boolean);
if(!commands.some(cmd=>cmd.includes('next-candidates')&&cmd.includes('--compact'))) throw new Error(overview.stdout);
if(!commands.some(cmd=>cmd.includes('task-overview')&&cmd.includes('--compact'))) throw new Error(overview.stdout);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
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

@test "activation skips a legacy plan relock when a planning revision queue already identifies current sections" {
  run node - "$SCRIPT" "$TMP_DIR/revision-plan-relock-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
let run=cp.spawnSync(process.execPath,[script,'create','--workflow-type','short_write','--project-root',root,'--user-goal','整篇回炉','--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const taskFile=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
task.current_stage='section_plan_lock';task.current_step='section_plan_lock';task.scope='全篇';task.status='paused_after_step';
task.stage_execution={status:'contract_blocked',stage_id:'section_plan_lock'};
task.short_feedback_impact={status:'ok',impact_level:'planning',requires_structure_audit:false,affected_sections:[1,4,8,9]};
task.feedback_revision_queue={status:'running',impact_level:'planning',current_section_index:1,affected_sections:[1,4,8,9],items:[1,4,8,9].map(section_index=>({section_index,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}))};
fs.mkdirSync(path.join(root,'追踪/private-short-extension'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({accepted_sections:[1,2,3,4,5,6,7,8,9].map(section_index=>({section_index}))},null,2)+'\n');
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
run=cp.spawnSync(process.execPath,[script,'activate','--workflow-id',task.workflow_id,'--project-root',root,'--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const out=JSON.parse(run.stdout);const saved=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(out.task.current_stage!=='next_section_brief'||saved.current_stage!=='next_section_brief') throw new Error(run.stdout);
if(saved.scope!=='第1节'||saved.stage_execution!==null) throw new Error(JSON.stringify(saved));
if(saved.short_project_resume.reason!=='active_feedback_revision_queue_has_priority'||saved.short_project_resume.previous_stage!=='section_plan_lock') throw new Error(JSON.stringify(saved.short_project_resume));
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
const feedback=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','负责人的语气再克制一些','--json'],{encoding:'utf8'});
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

@test "confirmed feedback revision skips the redundant prose entry confirmation" {
  run node - "$SCRIPT" "$TMP_DIR/confirmed-revision" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
let run=cp.spawnSync(process.execPath,[script,'create','--workflow-type','short_write','--project-root',root,'--user-goal','回炉现有短篇','--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const file=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='draft_next_section';task.current_step='draft_next_section';task.scope='第2节';task.stage_execution=null;
task.accepted_plan={plan_id:'accepted-plan.generic-revision',proposal_id:'proposal.generic-revision',feedback_id:'feedback-generic-revision',status:'completed',projection_status:'completed'};
task.proposed_plan={proposal_id:'proposal.generic-revision',feedback_id:'feedback-generic-revision',status:'accepted'};
task.feedback_revision_queue={status:'running',feedback_id:'feedback-generic-revision',current_section_index:2,items:[{section_index:2,status:'current',brief_status:'rebuilt_and_used',prose_status:'pending_recheck'}]};
task.pending_action={id:'pa-draft-next-section',question:'第 2 节写作提要已通过，推荐下一步',options:[{number:1,action_id:'recheck_existing_section',label:'复检并局部回炉第 2 节现有正文（推荐）',target_stage:'section_machine_gate',requires_user_confirm:true},{number:2,action_id:'pause',label:'暂停并保存断点'}],free_text_enabled:true};
task.machine={completed_stages:['next_section_brief'],remaining_stages:['draft_next_section','section_machine_gate','section_repair_loop','quality_gate','story_value_gate','section_accept_anchor']};
fs.mkdirSync(path.join(root,'正文'),{recursive:true});
fs.writeFileSync(path.join(root,'写作Brief_第002节.md'),'# 写作提要：第 2 节\n\n## 承接\n接住上一节。\n\n## 目标与阻力\n主角核对证据，负责人阻拦。\n\n## 因果动作\n拒绝签字后失去权限。\n\n## 人物与视角锁\n第一人称。\n\n## 禁写项\n不提前揭底。\n\n## 节尾钩子\n新证据出现。\n');
fs.writeFileSync(path.join(root,'正文','第002节.md'),'现有正文。\n');
fs.mkdirSync(path.join(root,'追踪/private-short-extension'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({current_section_index:2,accepted_sections:[{section_index:1}]})+'\n');
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
run=cp.spawnSync(process.execPath,[script,'next-candidates','--project-root',root,'--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const out=JSON.parse(run.stdout),saved=JSON.parse(fs.readFileSync(file,'utf8')),execution=saved.stage_execution||{};
if(out.status!=='stage_execution_resume_ready'||saved.current_stage!=='section_machine_gate') throw new Error(run.stdout);
if(execution.action_id!=='auto_recheck_confirmed_feedback_revision'||execution.completion_boundary!=='section_reaccepted') throw new Error(JSON.stringify(execution));
if(saved.pending_action!==null||((out.visible_response||{}).user_visible)!==false) throw new Error(JSON.stringify(out));
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
fs.writeFileSync(path.join(root,'追踪/private-short-extension/project-state.json'),JSON.stringify({working_title:'测试档案复核',planned_sections:9}));
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

@test "task overview adjustment enters chat impact analysis instead of resolving to nowhere" {
  run node - "$SCRIPT" "$TMP_DIR/task-adjust-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const create=cp.spawnSync(process.execPath,[script,'create','--workflow-type','short_write','--project-root',root,'--user-goal','新开短篇','--json'],{encoding:'utf8'});
if(create.status!==0) throw new Error(create.stdout||create.stderr);
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const taskFile=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
task.pending_action={id:'pa-adjust-task',question:'请选择下一步',options:[{number:1,action_id:'request_task_revision_input',label:'调整当前任务目标或范围'}],free_text_enabled:true};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
fs.writeFileSync(path.join(root,'素材卡.md'),'# 素材卡\n\n- 暂定作品名：AI秘密广告\n');
const overviewRun=cp.spawnSync(process.execPath,[script,'task-overview','--project-root',root,'--json'],{encoding:'utf8'});
if(overviewRun.status!==0) throw new Error(overviewRun.stdout||overviewRun.stderr);
const overview=JSON.parse(overviewRun.stdout);
if(!String(((overview.visible_response||{}).text)||'').includes('当前任务：创作《AI秘密广告》')) throw new Error(overviewRun.stdout);
const run=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--bind-current','--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
const out=JSON.parse(run.stdout);
if(out.status!=='task_revision_input_requested'||(out.visible_response||{}).render_mode!=='free_text_revision') throw new Error(run.stdout);
const current=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if((current.task_revision_input||{}).status!=='awaiting_chat') throw new Error(JSON.stringify(current.task_revision_input));
const feedback=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','把主角改成主动举报，并让这个变化先回写设定和全篇大纲','--json'],{encoding:'utf8'});
if(feedback.status!==0) throw new Error(feedback.stdout||feedback.stderr);
const feedbackOut=JSON.parse(feedback.stdout);
if(feedbackOut.status!=='short_feedback_impact_started'||feedbackOut.target_stage!=='feedback_impact_sync') throw new Error(feedback.stdout);
const after=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if((after.task_revision_input||{}).status!=='feedback_received'||String(((((after.pending_feedback||{}).items||[])[0]||{}).source_kind)||'')!=='task_revision_requirement') throw new Error(JSON.stringify(after));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
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
    node - "$SCRIPT" "$1" "${2:-}" "${3:-completed}" "${4-pass}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" <<'NODE'
const fs=require('fs'), path=require('path'), cp=require('child_process');
const [script,root,ownerOverride,stepStatus,verificationResult,nextStage,corruptField,reviewResult,declaredFile,targetCorruptField]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find(node=>node.id===task.current_stage);
if(!lifecycleNode) throw new Error(`missing lifecycle node ${task.current_stage}`);
const failedResult=['blocked','failed'].includes(String(stepStatus||'').toLowerCase())||/(?:fail|reject|block)/i.test(String(verificationResult||''));
let effectiveDeclaredFile=declaredFile;
if(task.current_stage==='story_bible'&&!failedResult&&!effectiveDeclaredFile){
  effectiveDeclaredFile='设定/故事圣经.md';
  const target=path.join(root,effectiveDeclaredFile);
  fs.mkdirSync(path.dirname(target),{recursive:true});
  fs.writeFileSync(target,`# 主角：林川\n身份：二十二岁调查员，第三人称叙事。\n外部目标：查清失踪案并保住证人。\n内在渴望：害怕再次失去家人。\n缺陷：习惯独自承担并误信权威。\n能力边界：不懂金融，越权调查会付出停职代价。\n第一卷成长里程碑：从独断到主动信任同伴。\n\n# 主要对手：赵衡\n目标：为了保住集团控制权而封锁证据。\n资源：拥有渠道、权限和人脉。\n边界与代价：不能公开杀人，失败会失去董事会支持。\n升级路径：从试探、施压到断供证据。\n\n# 关键配角：周宁\n目标：争取公开真相。\n行动边界：不能牺牲无辜证人，越界会失去职业资格。\n\n# 人物关系与责任债\n林川欠周宁一次救命责任，赵衡利用林川对家人的愧疚持续施压。\n\n# 成长里程碑\n第一卷完成从独断到协作的变化；终局主动选择公开证据并承担代价。\n`);
}
const result={
  workflow_id:task.workflow_id,
  workflow_type:'long_write',
  stage_id:task.current_stage,
  stage_attempt_id:task.stage_execution.stage_attempt_id,
  work_unit_id:task.stage_execution.work_unit_id,
  step_id:task.current_step,
  owner_module:ownerOverride||lifecycleNode.owner_module,
  lifecycle_node:lifecycleNode.id,
  asset_target:lifecycleNode.asset_target,
  review_requirement:lifecycleNode.review_requirement,
  step_status:stepStatus,
  outputs:[],
  changed_files:effectiveDeclaredFile?[effectiveDeclaredFile]:[],
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
  result_write_set:effectiveDeclaredFile?[effectiveDeclaredFile]:[]
};
if(failedResult&&['master_outline_review','volume_outline_review'].includes(task.current_stage)) {
  result.planning_revision_plan={
    version:'planning_revision_plan_v1',
    summary:'统一当前规划资产中的阶段边界与编号口径。',
    requirements:['保留已确认故事核，只修正冲突的阶段边界。'],
    targets:[task.current_stage==='master_outline_review'?'大纲/总纲.md':'大纲/第1卷/卷纲.md'],
  };
}
if(corruptField==='unsafe_planning_revision_plan'&&result.planning_revision_plan) {
  result.planning_revision_plan.targets=['../总纲.md'];
}
const chapterTarget=((task.stage_execution||{}).chapter_target)||null;
if(chapterTarget) {
  result.chapter_target={...chapterTarget};
  if(targetCorruptField) {
    if(targetCorruptField==='global_chapter_no') result.chapter_target.global_chapter_no=Number(result.chapter_target.global_chapter_no||0)+1;
    else result.chapter_target[targetCorruptField]=`tampered-${String(result.chapter_target[targetCorruptField]||'')}`;
  }
}
if(reviewResult) result.review_result=reviewResult;
if(nextStage) result.next_stage_id=nextStage;
if(corruptField==='lifecycle_node') result.lifecycle_node='prose';
if(corruptField==='asset_target') result.asset_target={kind:'chapter',id:'wrong-asset'};
if(corruptField==='review_requirement') result.review_requirement={required:true,failure_return:'prose'};
if(['asset_revision','review_decision','downstream_effects','lifecycle_transition_request','result_write_set','planning_revision_plan'].includes(corruptField)) delete result[corruptField];
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
    mkdir -p "$book/追踪/schema"
    cat > "$book/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第001章","chapterNo":1,"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":1,"outlinePath":"大纲/第1卷/细纲_第001章.md","contractPath":"追踪/章节契约/第1卷/第001章.md","draftPath":"正文/第1卷/第001章.md"}
EOF
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    for _ in 1 2 3 4 5 6; do
        advance_long_write_stage "$book"
    done
    mkdir -p "$book/大纲/第1卷"
    printf '%s\n' '当前细纲' > "$book/大纲/第1卷/细纲_第001章.md"
    advance_long_write_stage "$book" "大纲/第1卷/细纲_第001章.md"
    mkdir -p "$book/追踪/story-system"
    printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$book/追踪/story-system/write-policy.json"
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
  verification_result:['revise','outline_underfilled'].includes(actualStatus)?'revise':'pass',
  checkpoint_state:{stage_id:task.current_stage,outline_path:outlinePath},
  output_health_result:'pass',
  asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},
  review_decision:['revise','outline_underfilled'].includes(actualStatus)?'revise':'accepted',
  downstream_effects:[],
  lifecycle_transition_request:['revise','outline_underfilled'].includes(actualStatus)
    ?{action:'return',target:'stage_detail_outline'}
    :{action:'advance',target:lifecycleNode.id},
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

bind_active_long_chapter_target() {
    node - "$(focused_task_file "$TMP_DIR/book")" "$1" "$2" <<'NODE'
const fs=require('fs'),file=process.argv[2],outline_path=process.argv[3],outline_sha256=process.argv[4],task=JSON.parse(fs.readFileSync(file,'utf8'));
const target={outline_path,outline_sha256};
task.accepted_detail_outline_targets=[target];
task.active_chapter_target=target;
task.consumed_detail_outline_targets=[];
task.stage_execution={...(task.stage_execution||{}),chapter_target:target};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
}

prepare_long_chapter_v2_targets() {
    node - "$REPO" "$1" "$2" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const [repo,root,countRaw]=process.argv.slice(2),count=Number(countRaw)||1;
const fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
const schemaDir=path.join(root,'追踪/schema');
fs.mkdirSync(schemaDir,{recursive:true});
const rows=[];
for(let chapter=1;chapter<=count;chapter+=1){
  const padded=String(chapter).padStart(3,'0');
  const outlinePath=`大纲/第2卷/细纲_第${padded}章.md`,outline=`# 第${chapter}章细纲\n\n当前章只验证章节循环。\n`;
  fs.mkdirSync(path.dirname(path.join(root,outlinePath)),{recursive:true});
  fs.writeFileSync(path.join(root,outlinePath),outline);
  rows.push({
    chapterId:`第${padded}章`,chapterNo:chapter,volume:'第2卷',volumeChapterNo:chapter,globalDraftOrder:chapter,
    outlinePath,contractPath:`追踪/章节契约/第2卷/第${padded}章.md`,draftPath:`正文/第2卷/第${padded}章.md`,
  });
}
fs.writeFileSync(path.join(schemaDir,'chapters.jsonl'),`${rows.map((row)=>JSON.stringify(row)).join('\n')}\n`);
const {buildLongChapterTargetV2}=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const targets=rows.map((row)=>{
  const outline=fs.readFileSync(path.join(root,row.outlinePath));
  const built=buildLongChapterTargetV2({projectRoot:root,outlinePath:row.outlinePath,outlineSha256:crypto.createHash('sha256').update(outline).digest('hex'),workflowId:task.workflow_id});
  if(built.status!=='ok') throw new Error(JSON.stringify(built));
  fs.mkdirSync(path.dirname(path.join(root,built.target.contract_path)),{recursive:true});
  fs.writeFileSync(path.join(root,built.target.contract_path),'# 当前章 Brief\n\n- 目标字数：100\n- 合法区间：90—120\n');
  fs.mkdirSync(path.dirname(path.join(root,built.target.candidate_draft_path)),{recursive:true});
  fs.writeFileSync(path.join(root,built.target.candidate_draft_path),'汉'.repeat(100));
  return built.target;
});
task.accepted_detail_outline_targets=targets;
task.active_chapter_target=targets[0];
task.consumed_detail_outline_targets=[];
task.stage_execution={
  ...(task.stage_execution||{}),status:'running',stage_id:task.current_stage,step_id:task.current_step,
  stage_attempt_id:String(((task.stage_execution||{}).stage_attempt_id)||`sa-${task.current_stage}-fixture`),
  work_unit_id:String(((task.stage_execution||{}).work_unit_id)||`wu-${task.current_stage}-fixture`),
  chapter_target:targets[0],
};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
}

write_v2_transactional_commit_result() {
    node - "$1" "$2" "${3:-chapter_brief}" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const [root,resultFile,nextStage]=process.argv.slice(2),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),target=task.active_chapter_target;
if(!target||!target.target_id) throw new Error(`missing V2 active target: ${JSON.stringify(target)}`);
const candidate=fs.readFileSync(path.join(root,target.candidate_draft_path)),hash=`sha256:${crypto.createHash('sha256').update(candidate).digest('hex')}`;
fs.mkdirSync(path.dirname(path.join(root,target.draft_path)),{recursive:true});fs.writeFileSync(path.join(root,target.draft_path),candidate);
const suffix=String(target.volume_chapter_no).padStart(3,'0'),transactionId=`tx-${task.workflow_id}-${suffix}`,commitId=`chapter-${task.workflow_id}-${suffix}`;
const transactionDir=path.join(root,'追踪/story-system/transactions',transactionId),stagedRel=`追踪/story-system/transactions/${transactionId}/staged/chapter-${suffix}.md`;
fs.mkdirSync(path.dirname(path.join(root,stagedRel)),{recursive:true});fs.writeFileSync(path.join(root,stagedRel),candidate);
const provenance={workflow_id:task.workflow_id,task_family_id:task.task_family_id,branch_id:task.branch_id||task.workflow_id,stage_attempt_id:task.stage_execution.stage_attempt_id};
const transaction={schemaVersion:'1.0.0',transaction_id:transactionId,commit_id:commitId,status:'accepted',workflow_id:task.workflow_id,volume:target.volume,chapter:target.volume_chapter_no,provenance,artifacts:[{source_staged:target.candidate_draft_path,target:target.draft_path,staged:stagedRel,content_hash:hash}]};
fs.mkdirSync(transactionDir,{recursive:true});fs.writeFileSync(path.join(transactionDir,'transaction.json'),JSON.stringify(transaction,null,2)+'\n');
const commitRel=`追踪/story-system/commits/${commitId}.json`,commit={schemaVersion:'1.0.0',commit_id:commitId,transaction_id:transactionId,status:'accepted',workflow_id:task.workflow_id,volume:target.volume,chapter:target.volume_chapter_no,provenance,artifacts:[{role:'chapter_prose',target:target.draft_path,after_hash:hash}]};
fs.mkdirSync(path.dirname(path.join(root,commitRel)),{recursive:true});fs.writeFileSync(path.join(root,commitRel),JSON.stringify(commit,null,2)+'\n');
const result={workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'chapter_commit',step_id:'chapter_commit',step_status:'completed',verification_result:'pass',changed_files:[],result_write_set:[],next_stage_id:nextStage,chapter_target:target,chapter_commit:{mode:'transactional',accepted_commit_id:commitId,commit_file:commitRel,projection_status:'projection_current',projection_debt:false,staged_artifacts:[target.candidate_draft_path]}};
fs.writeFileSync(resultFile,JSON.stringify(result,null,2)+'\n');
NODE
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

@test "long story bible cannot advance before the character contract passes" {
    book="$TMP_DIR/long-character-contract-book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    advance_long_write_stage "$book"
    mkdir -p "$book/设定"
    printf '%s\n' '# 人物' '- 主角：陆川，杂役。' '- 对手：韩岳，内门弟子。' > "$book/设定/人物.md"

    run apply_long_write_v2_result "$book" "" completed pass "" "" "" "设定/人物.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_character_contract_revision_required'* ]]

    cat > "$book/设定/人物.md" <<'EOF'
# 人物设计
## 主角：陆川
十九岁杂役。目标是脱离杂役身份，最怕失去亲近的人，误区是凡事独自承担；能力边界是不懂阵法和宗门政治。第一卷从被动自保到主动结盟，终局必须选择新秩序。
## 主要对手：韩岳
他要保住资源权，认为牺牲少数人能维持秩序；拥有执法名义和修为资源，但不能公开违背门规，失败会失去师门信用，压力从断供升级到围杀。
## 关键配角：苏禾
她想查清兄长死因，掌握药堂账册但不能无代价盗取档案。
## 人物关系与责任债
- 三人因救命债和资源权形成持续利益冲突。
## 出场与成长里程碑
- 第一卷主动结盟；第二卷公开站队；第三卷承担领袖责任；终局选择新秩序。
EOF
    run apply_long_write_v2_result "$book" "" completed pass "" "" "" "设定/人物.md"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(jq -r '.source_kind' "$book/追踪/memory/active-cast.json")" = "canonical_story_bible" ]
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
if (stages.volume_acceptance.requires_user_confirm !== true) {
  throw new Error('volume_acceptance must stop for explicit volume-boundary confirmation');
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

@test "managed runner with read-only stage_contract blocks canonical writes in result packet" {
    book="$TMP_DIR/managed-runner-read-only"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$book" 1 >/dev/null
    canonical_file="追踪/伏笔.md"
    node - "$book" "$canonical_file" <<'NODE'
const fs=require('fs'),path=require('path');
const [root,canonicalFile]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find(node=>node.id===task.current_stage);
if(!lifecycleNode) throw new Error(`missing lifecycle node ${task.current_stage}`);

// Persist a managed runner packet whose stage_contract.write_set is empty
// (read-only canonical_assets). This mirrors the legacy task authority
// recovery revalidation runner pattern. Note: task.stage_execution.write_set
// stays at its template-derived value (e.g. ["设定/**", "追踪/**"]) so the
// existing write-set matcher would otherwise accept the canonical claim.
const runnerRel=`${task.task_dir}/runner-packets/${task.current_stage}.attempt-1.run.json`;
const runnerAbs=path.resolve(root,runnerRel);
fs.mkdirSync(path.dirname(runnerAbs),{recursive:true});
const runnerPacket={
  schemaVersion:'1.0.0',
  run_id:`${task.workflow_id}-${task.current_stage}-read-only`,
  workflow_id:task.workflow_id,
  workflow_type:task.workflow_type,
  stage_id:task.current_stage,
  stage_attempt_id:task.stage_execution.stage_attempt_id,
  work_unit_id:task.stage_execution.work_unit_id,
  owner_module:lifecycleNode.owner_module,
  project_root:root,
  task_state:`${task.task_dir}/task.json`,
  host_execution_mode:'managed_runner',
  expected_result_packet:task.stage_execution.expected_result_packet,
  stage_contract:{
    owner_module:lifecycleNode.owner_module,
    lifecycle_node:lifecycleNode.id,
    asset_target:{...(lifecycleNode.asset_target||{})},
    review_requirement:{...(lifecycleNode.review_requirement||{})},
    write_set:[],
    existing_asset_policy:{
      mode:'existing_asset_revalidation',
      canonical_assets:'read_only',
      result_artifacts:'result_packet_only',
      pass_condition:'既有资产足以支撑当前 scope。',
      block_condition:'仅影响当前 scope 的矛盾或关键缺失可以阻断。',
    },
    memory_contract:null,
  },
  result_packet_template:{
    schemaVersion:'1.0.0',
    workflow_id:task.workflow_id,
    workflow_type:task.workflow_type,
    stage_id:task.current_stage,
    changed_files:[],
    result_write_set:[],
  },
};
fs.writeFileSync(runnerAbs,JSON.stringify(runnerPacket,null,2));

// Pre-create the canonical file so the file actually exists on disk; the
// apply-result path matches actual changes against the declared write set.
fs.mkdirSync(path.dirname(path.join(root,canonicalFile)),{recursive:true});
fs.writeFileSync(path.join(root,canonicalFile),'# 既有资产\n');

// Build a result packet that pretends to write a canonical file even though
// the runner was declared read-only.
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
  outputs:[],
  changed_files:[canonicalFile],
  evidence:[],
  verification_result:'pass',
  checkpoint_state:{stage_id:task.current_stage},
  output_health_result:'pass',
  asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},
  review_decision:'not_applicable',
  downstream_effects:[],
  lifecycle_transition_request:{action:'advance',target:lifecycleNode.id},
  result_write_set:[canonicalFile],
  host_execution_mode:'managed_runner',
  runner_packet_path:runnerRel,
  result_packet_path:task.stage_execution.expected_result_packet,
  memory_read_receipt:((task.stage_execution||{}).memory_context||{}).memory_read_receipt||null,
};
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify(result,null,2));
NODE
    packet="$(node -e "const path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]); console.log(path.resolve(process.argv[1],task.stage_execution.expected_result_packet))" "$book")"
    run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_managed_runner_read_only_canonical_write'* ]]

    node - "$book" "$REPO" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const runnerRel=`${task.task_dir}/runner-packets/${task.current_stage}.attempt-1.run.json`;
task.runtime_guard=task.runtime_guard||{};
task.runtime_guard.last_runner_attempt={
  workflow_id:task.workflow_id,stage_id:task.current_stage,
  stage_attempt_id:task.stage_execution.stage_attempt_id,
  work_unit_id:task.stage_execution.work_unit_id,
  run_id:`${task.workflow_id}-${task.current_stage}-read-only`,runner_packet_path:runnerRel,
  expected_result_packet:task.stage_execution.expected_result_packet,
};
fs.writeFileSync(path.join(root,task.task_dir,'task.json'),JSON.stringify(task,null,2));
const packet=path.join(root,task.stage_execution.expected_result_packet);
const result=JSON.parse(fs.readFileSync(packet,'utf8'));
result.host_execution_mode='cooperative_interactive';
delete result.runner_packet_path;
fs.writeFileSync(packet,JSON.stringify(result,null,2));
NODE
    run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_managed_runner_execution_mode_mismatch'* ]]
}

@test "managed runner ignores its rejected-result audit archive on a retry" {
    book="$TMP_DIR/managed-runner-audit-retry"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$book" 1 >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find(node=>node.id===task.current_stage);
const runnerRel=`${task.task_dir}/runner-packets/${task.current_stage}.attempt-1.run.json`;
const runnerAbs=path.resolve(root,runnerRel);fs.mkdirSync(path.dirname(runnerAbs),{recursive:true});
fs.writeFileSync(runnerAbs,JSON.stringify({workflow_id:task.workflow_id,stage_id:task.current_stage,stage_attempt_id:task.stage_execution.stage_attempt_id,work_unit_id:task.stage_execution.work_unit_id,expected_result_packet:task.stage_execution.expected_result_packet,stage_contract:{write_set:task.stage_execution.write_set,canonical_write_set:task.stage_execution.canonical_write_set||[]}},null,2));
const auditFile=path.join(root,task.task_dir,'audit/rejected-managed-results',`${task.current_stage}.old.json`);
fs.mkdirSync(path.dirname(auditFile),{recursive:true});fs.writeFileSync(auditFile,'{}');
const machineGateFile=path.join(root,task.task_dir,'artifacts/chapter-001-machine-gate.json');
fs.mkdirSync(path.dirname(machineGateFile),{recursive:true});fs.writeFileSync(machineGateFile,'{}');
for(const [file,content] of [
  ['scripts/workflow-runner.js','runtime'],
  ['.claude/agent-references/novel-assistant/rule.md','runtime'],
  ['.story-runtime-managed.json','{}'],
  ['追踪/runtime-snapshots/20260804T000000000Z/manifest.json','{}'],
]) { const absolute=path.join(root,file);fs.mkdirSync(path.dirname(absolute),{recursive:true});fs.writeFileSync(absolute,content); }
const result={workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:task.current_stage,step_id:task.current_step,owner_module:lifecycleNode.owner_module,lifecycle_node:lifecycleNode.id,asset_target:lifecycleNode.asset_target,review_requirement:lifecycleNode.review_requirement,step_status:'completed',outputs:[],changed_files:[],evidence:[],verification_result:'pass',checkpoint_state:{stage_id:task.current_stage},output_health_result:'pass',asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},review_decision:'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance',target:lifecycleNode.id},result_write_set:[],host_execution_mode:'managed_runner',runner_packet_path:runnerRel,result_packet_path:task.stage_execution.expected_result_packet,memory_read_receipt:((task.stage_execution||{}).memory_context||{}).memory_read_receipt||null};
const packet=path.resolve(root,task.stage_execution.expected_result_packet);fs.mkdirSync(path.dirname(packet),{recursive:true});fs.writeFileSync(packet,JSON.stringify(result,null,2));
NODE
    packet="$(node -e "const path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]); console.log(path.resolve(process.argv[1],task.stage_execution.expected_result_packet))" "$book")"
    run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
    [ "$status" -eq 0 ]
    [[ "$output" != *'blocked_managed_runner_read_only_canonical_write'* ]]
}

@test "rejected managed stage restart requires confirmation and captures a fresh auditable attempt" {
    book="$TMP_DIR/rejected-stage-restart"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧长篇" --json >/dev/null
    resolve_action "$book" 1 >/dev/null

    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const execution=task.stage_execution||{};
task.current_stage='detail_outline_review';
task.current_step='detail_outline_review';
execution.stage_id='detail_outline_review';
execution.step_id='detail_outline_review';
execution.expected_result_packet=`${task.task_dir}/result-packets/detail_outline_review.result.json`;
execution.result_contract='detail_outline_quality_v2';
execution.requires_user_confirm=true;
task.pending_action=null;
task.last_selection={};
fs.writeFileSync(require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
const auditDir=path.join(root,task.task_dir,'audit','rejected-managed-results');
fs.mkdirSync(auditDir,{recursive:true});
fs.writeFileSync(path.join(auditDir,`${execution.stage_id}.rejected.json`),JSON.stringify({
  workflow_id:task.workflow_id,
  stage_id:execution.stage_id,
  stage_attempt_id:execution.stage_attempt_id,
  host_execution_mode:'managed_runner',
},null,2));
const canonical=path.join(root,'设定','世界观.md');
fs.mkdirSync(path.dirname(canonical),{recursive:true});
fs.writeFileSync(canonical,'# 当前可信世界观\n');
fs.writeFileSync(path.join(root,'before.json'),JSON.stringify({
  workflow_id:task.workflow_id,
  stage_attempt_id:execution.stage_attempt_id,
  captured_at:execution.write_snapshot.captured_at,
  canonical_sha:`sha256:${require('crypto').createHash('sha256').update(fs.readFileSync(canonical)).digest('hex')}`,
}));
NODE

    workflow_id="$(node -e "console.log(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    run node "$SCRIPT" restart-rejected-stage --project-root "$book" --workflow-id "$workflow_id" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_rejected_stage_restart_confirmation_required'* ]]

    run node "$SCRIPT" restart-rejected-stage --project-root "$book" --workflow-id "$workflow_id" --confirm --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'rejected_stage_restarted'* ]]
    node - "$book" "$REPO" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const before=JSON.parse(fs.readFileSync(path.join(root,'before.json'),'utf8'));
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const execution=task.stage_execution||{};
if(execution.stage_attempt_id===before.stage_attempt_id) throw new Error('stage attempt was reused');
if(Number(execution.attempt_no)<1) throw new Error(JSON.stringify(execution));
if(execution.write_snapshot.captured_at===before.captured_at) throw new Error('write snapshot was reused');
if(execution.write_snapshot.files['设定/世界观.md']!==before.canonical_sha) throw new Error(JSON.stringify(execution.write_snapshot.files));
const previous=(task.stage_attempt_history||[]).find(item=>item.stage_attempt_id===before.stage_attempt_id);
if(!previous||previous.status!=='rejected'||!previous.failed_result_packet) throw new Error(JSON.stringify(task.stage_attempt_history));
if(execution.requires_user_confirm===true) {
  const {validateWorkflowConfirmation}=require(path.join(process.argv[3],'scripts','lib','workflow-confirmation-context.js'));
  if(!validateWorkflowConfirmation(task,execution).valid) throw new Error(JSON.stringify({execution,last_selection:task.last_selection,pending_action:task.pending_action}));
}
NODE
}

@test "managed runner with non-empty stage_contract write_set accepts a matching task artifact" {
    book="$TMP_DIR/managed-runner-writable"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    resolve_action "$book" 1 >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find(node=>node.id===task.current_stage);
if(!lifecycleNode) throw new Error(`missing lifecycle node ${task.current_stage}`);
const authorizedFile=`${task.task_dir}/artifacts/runner-note.md`;

// Persist a managed runner packet whose stage_contract.write_set matches the
// template authorization for this stage (non-read-only).
const runnerRel=`${task.task_dir}/runner-packets/${task.current_stage}.attempt-1.run.json`;
const runnerAbs=path.resolve(root,runnerRel);
fs.mkdirSync(path.dirname(runnerAbs),{recursive:true});
const runnerPacket={
  schemaVersion:'1.0.0',
  run_id:`${task.workflow_id}-${task.current_stage}-writable`,
  workflow_id:task.workflow_id,
  workflow_type:task.workflow_type,
  stage_id:task.current_stage,
  stage_attempt_id:'sa-stale-managed-runner',
  work_unit_id:'wu-stale-managed-runner',
  owner_module:lifecycleNode.owner_module,
  project_root:root,
  task_state:`${task.task_dir}/task.json`,
  host_execution_mode:'managed_runner',
  expected_result_packet:task.stage_execution.expected_result_packet,
  stage_contract:{
    owner_module:lifecycleNode.owner_module,
    lifecycle_node:lifecycleNode.id,
    asset_target:{...(lifecycleNode.asset_target||{})},
    review_requirement:{...(lifecycleNode.review_requirement||{})},
    write_set:Array.isArray(task.stage_execution.write_set)?task.stage_execution.write_set.slice():[],
    existing_asset_policy:null,
    memory_contract:null,
  },
  result_packet_template:{
    schemaVersion:'1.0.0',
    workflow_id:task.workflow_id,
    workflow_type:task.workflow_type,
    stage_id:task.current_stage,
    changed_files:[],
    result_write_set:[],
  },
};
fs.writeFileSync(runnerAbs,JSON.stringify(runnerPacket,null,2));

// Build a result packet that legitimately writes a task artifact matching
// the runner's authorized write_set.
fs.mkdirSync(path.dirname(path.join(root,authorizedFile)),{recursive:true});
fs.writeFileSync(path.join(root,authorizedFile),'定位资产\n');
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
  outputs:[],
  changed_files:[authorizedFile],
  evidence:[],
  verification_result:'pass',
  checkpoint_state:{stage_id:task.current_stage},
  output_health_result:'pass',
  asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},
  review_decision:'not_applicable',
  downstream_effects:[],
  lifecycle_transition_request:{action:'advance',target:lifecycleNode.id},
  result_write_set:[authorizedFile],
  host_execution_mode:'managed_runner',
  runner_packet_path:runnerRel,
  result_packet_path:task.stage_execution.expected_result_packet,
  memory_read_receipt:((task.stage_execution||{}).memory_context||{}).memory_read_receipt||null,
};
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify(result,null,2));
NODE
    packet="$(node -e "const path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]); console.log(path.resolve(process.argv[1],task.stage_execution.expected_result_packet))" "$book")"
    run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_managed_runner_receipt_scope_mismatch'* ]]
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const result=JSON.parse(fs.readFileSync(path.resolve(root,task.stage_execution.expected_result_packet),'utf8'));
const runner=JSON.parse(fs.readFileSync(path.resolve(root,result.runner_packet_path),'utf8'));
runner.stage_attempt_id=task.stage_execution.stage_attempt_id;
runner.work_unit_id=task.stage_execution.work_unit_id;
fs.writeFileSync(path.resolve(root,result.runner_packet_path),JSON.stringify(runner,null,2));
NODE
    run node "$SCRIPT" apply-result --project-root "$book" --result "$packet" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "stage_started"'* ]]
}

@test "long write ignores host startup and runner observability files" {
    book="$TMP_DIR/runtime-restart-marker"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null
    mkdir -p "$book/.claude"
    : > "$book/.claude/.agents-pending-restart"
    resolve_action "$book" 1 >/dev/null

    rm "$book/.claude/.agents-pending-restart"
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const outputDir=path.join(root,task.task_dir,'runner-output');
fs.mkdirSync(outputDir,{recursive:true});
fs.writeFileSync(path.join(outputDir,'host.stdout.log'),'runner-owned output\n');
fs.writeFileSync(path.join(root,task.task_dir,'tool-events.jsonl'),'{"event":"runner"}\n');
NODE
    apply_long_write_v2_result "$book" >/dev/null

    current_stage="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]); process.stdout.write(t.current_stage)" "$book")"
    [ "$current_stage" = "story_bible" ]
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

@test "long write accepts a canonical outline transaction alongside its internal evidence" {
    book="$TMP_DIR/canonical-outline-transaction"
    mkdir -p "$book/大纲/卷一" "$book/追踪/staging" "$book/追踪/story-system"
    printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$book/追踪/story-system/write-policy.json"
    printf '%s\n' '旧版大纲资产' > "$book/大纲/卷一/总纲.md"
    printf '%s\n' '新版大纲资产' > "$book/追踪/staging/总纲.md"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "验证规范事务写入" --json >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
fs.writeFileSync(path.join(root,'追踪/staging/outline-manifest.json'),JSON.stringify({
  workflow_id:task.workflow_id,
  volume:'卷一',chapter:1,
  gates:{output_health:'pass',prose_quality:'pass',story_drift:'pass'},
  artifacts:[{role:'outline',staged:'追踪/staging/总纲.md',target:'大纲/卷一/总纲.md'}]
}));
NODE
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"

    node - "$book" "$SCRIPT" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [root,script]=process.argv.slice(2);
const fixture=require(process.env.WORKFLOW_TASK_FIXTURE);
const task=fixture.readFocusedTask(root);
if(task.current_stage!=='master_outline') throw new Error(`expected master_outline, got ${task.current_stage}`);
const manifest=path.join(root,'追踪/staging/outline-manifest.json');
const manifestData=JSON.parse(fs.readFileSync(manifest,'utf8'));
manifestData.provenance={task_family_id:task.task_family_id,workflow_id:task.workflow_id,branch_id:task.branch_id||task.workflow_id,stage_attempt_id:task.stage_execution.stage_attempt_id,acceptance_status:'accepted'};
fs.writeFileSync(manifest,JSON.stringify(manifestData));
task.stage_execution.write_snapshot.files['追踪/staging/outline-manifest.json']=`sha256:${require('crypto').createHash('sha256').update(fs.readFileSync(manifest)).digest('hex')}`;
fs.writeFileSync(fixture.focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
const commitScript=path.join(path.dirname(script),'chapter-commit.js');
const prepared=cp.spawnSync(process.execPath,[commitScript,'prepare','--project-root',root,'--manifest',manifest,'--json'],{encoding:'utf8'});
if(prepared.status!==0) throw new Error(prepared.stdout||prepared.stderr);
const tx=JSON.parse(prepared.stdout).transaction_id;
const accepted=cp.spawnSync(process.execPath,[commitScript,'accept','--project-root',root,'--transaction',tx,'--json'],{encoding:'utf8'});
if(accepted.status!==0) throw new Error(accepted.stdout||accepted.stderr);
const acceptedOutput=JSON.parse(accepted.stdout);
for(const relative of [
  `追踪/story-system/transactions/${tx}/transaction.json`,
  `追踪/story-system/transactions/${tx}/staged/001-总纲.md`,
  `追踪/story-system/transactions/${tx}/backup/001-总纲.md`,
  `追踪/story-system/commits/${JSON.parse(accepted.stdout).commit_id}.json`,
  '追踪/story-system/projection-log.jsonl'
]) if(!fs.existsSync(path.join(root,relative))) throw new Error(`missing internal evidence: ${relative}`);
const resultPacket=path.resolve(root,task.stage_execution.expected_result_packet);
const node=task.lifecycle_graph.nodes.find(item=>item.id===task.current_stage);
const result={workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:task.current_stage,step_id:task.current_step,
 owner_module:node.owner_module,lifecycle_node:node.id,asset_target:node.asset_target,review_requirement:node.review_requirement,
 step_status:'completed',outputs:[],changed_files:['大纲/卷一/总纲.md'],evidence:[],verification_result:'pass',checkpoint_state:{stage:task.current_stage},output_health_result:'pass',
 asset_revision:{status:'verified',asset_id:node.asset_target.id},review_decision:'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance',target:node.id},result_write_set:['大纲/卷一/总纲.md'],chapter_commit:{mode:'transactional',accepted_commit_id:acceptedOutput.commit_id,commit_file:path.relative(root,acceptedOutput.commit_file).replace(/\\/g,'/'),projection_status:acceptedOutput.projection_status,projection_debt:false,staged_artifacts:[`追踪/story-system/transactions/${tx}/staged/001-总纲.md`]}};
fs.mkdirSync(path.dirname(resultPacket),{recursive:true});
fs.writeFileSync(resultPacket,JSON.stringify(result));
const commitFile=acceptedOutput.commit_file,commitData=JSON.parse(fs.readFileSync(commitFile,'utf8')),originalAttempt=commitData.provenance.stage_attempt_id;
commitData.provenance.stage_attempt_id='sa-old-accepted-attempt';fs.writeFileSync(commitFile,JSON.stringify(commitData));
const rejected=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',resultPacket,'--json'],{encoding:'utf8'});
if(rejected.status!==2||!String(rejected.stdout||rejected.stderr).includes('blocked_canonical_transaction_attempt_mismatch')) throw new Error(rejected.stdout||rejected.stderr);
commitData.provenance.stage_attempt_id=originalAttempt;fs.writeFileSync(commitFile,JSON.stringify(commitData));
const applied=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',resultPacket,'--json'],{encoding:'utf8'});
if(applied.status!==0) throw new Error(applied.stdout||applied.stderr);
const output=JSON.parse(applied.stdout);
if(!['advanced','stage_started'].includes(output.status)) throw new Error(applied.stdout);
NODE
}

@test "long write accepts canonical transaction when persisted snapshot predates internal evidence exclusion" {
    book="$TMP_DIR/canonical-outline-transaction-legacy-snapshot"
    mkdir -p "$book/大纲/卷一" "$book/追踪/staging" "$book/追踪/story-system"
    printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$book/追踪/story-system/write-policy.json"
    printf '%s\n' '旧版大纲资产' > "$book/大纲/卷一/总纲.md"
    printf '%s\n' '新版大纲资产' > "$book/追踪/staging/总纲.md"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "验证旧快照下规范事务写入" --json >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
fs.writeFileSync(path.join(root,'追踪/staging/outline-manifest.json'),JSON.stringify({
  workflow_id:task.workflow_id,
  volume:'卷一',chapter:1,
  gates:{output_health:'pass',prose_quality:'pass',story_drift:'pass'},
  artifacts:[{role:'outline',staged:'追踪/staging/总纲.md',target:'大纲/卷一/总纲.md'}]
}));
NODE
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    # Simulate a snapshot persisted before the canonical transaction exclusions
    # existed: drop the three internal-evidence paths from excluded_paths and
    # keep the snapshot.files payload untouched.
    node - "$book" <<'NODE'
const fs=require('fs');
const fixture=require(process.env.WORKFLOW_TASK_FIXTURE);
const taskFile=fixture.focusedTaskFile(process.argv[2]);
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const snapshot=((task.stage_execution||{}).write_snapshot)||{};
const internals=['追踪/story-system/transactions','追踪/story-system/commits','追踪/story-system/projection-log.jsonl'];
const legacyExcluded=(Array.isArray(snapshot.excluded_paths)?snapshot.excluded_paths:[])
  .filter(item=>!internals.some(internal=>item===internal||item.startsWith(`${internal}/`)));
snapshot.excluded_paths=legacyExcluded;
if(task.stage_execution) task.stage_execution.write_snapshot=snapshot;
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE

    run node - "$book" "$SCRIPT" <<'NODE'
const fs=require('fs'),path=require('path'),cp=require('child_process');
const [root,script]=process.argv.slice(2);
const fixture=require(process.env.WORKFLOW_TASK_FIXTURE);
const task=fixture.readFocusedTask(root);
if(task.current_stage!=='master_outline') throw new Error(`expected master_outline, got ${task.current_stage}`);
const manifest=path.join(root,'追踪/staging/outline-manifest.json');
const manifestData=JSON.parse(fs.readFileSync(manifest,'utf8'));
manifestData.provenance={task_family_id:task.task_family_id,workflow_id:task.workflow_id,branch_id:task.branch_id||task.workflow_id,stage_attempt_id:task.stage_execution.stage_attempt_id,acceptance_status:'accepted'};
fs.writeFileSync(manifest,JSON.stringify(manifestData));
task.stage_execution.write_snapshot.files['追踪/staging/outline-manifest.json']=`sha256:${require('crypto').createHash('sha256').update(fs.readFileSync(manifest)).digest('hex')}`;
fs.writeFileSync(fixture.focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
const commitScript=path.join(path.dirname(script),'chapter-commit.js');
const prepared=cp.spawnSync(process.execPath,[commitScript,'prepare','--project-root',root,'--manifest',manifest,'--json'],{encoding:'utf8'});
if(prepared.status!==0) throw new Error(prepared.stdout||prepared.stderr);
const tx=JSON.parse(prepared.stdout).transaction_id;
const accepted=cp.spawnSync(process.execPath,[commitScript,'accept','--project-root',root,'--transaction',tx,'--json'],{encoding:'utf8'});
if(accepted.status!==0) throw new Error(accepted.stdout||accepted.stderr);
const acceptedOutput=JSON.parse(accepted.stdout);
const resultPacket=path.resolve(root,task.stage_execution.expected_result_packet);
const node=task.lifecycle_graph.nodes.find(item=>item.id===task.current_stage);
const result={workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:task.current_stage,step_id:task.current_step,
 owner_module:node.owner_module,lifecycle_node:node.id,asset_target:node.asset_target,review_requirement:node.review_requirement,
 step_status:'completed',outputs:[],changed_files:['大纲/卷一/总纲.md'],evidence:[],verification_result:'pass',checkpoint_state:{stage:task.current_stage},output_health_result:'pass',
 asset_revision:{status:'verified',asset_id:node.asset_target.id},review_decision:'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance',target:node.id},result_write_set:['大纲/卷一/总纲.md'],chapter_commit:{mode:'transactional',accepted_commit_id:acceptedOutput.commit_id,commit_file:path.relative(root,acceptedOutput.commit_file).replace(/\\/g,'/'),projection_status:acceptedOutput.projection_status,projection_debt:false,staged_artifacts:[`追踪/story-system/transactions/${tx}/staged/001-总纲.md`]}};
fs.mkdirSync(path.dirname(resultPacket),{recursive:true});
fs.writeFileSync(resultPacket,JSON.stringify(result));
const applied=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',resultPacket,'--json'],{encoding:'utf8'});
if(applied.status!==0) throw new Error(applied.stdout||applied.stderr);
const output=JSON.parse(applied.stdout);
if(!['advanced','stage_started'].includes(output.status)) throw new Error(applied.stdout);
NODE
    [ "$status" -eq 0 ]
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
        [ "$status" -eq 0 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]
        [[ "$output" == *'explicit supported-project lifecycle migration'* ]]

        run node "$SCRIPT" task-overview --project-root "$book" --compact --json
        [ "$status" -eq 0 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]
        [[ "$output" != *'workflow_task_overview'* ]]
        [[ "$output" != *'继续当前阶段'* ]]

        run node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧项目" --json
        [ "$status" -eq 0 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]

        run resolve_action "$book" 1
        [ "$status" -eq 0 ]
        [[ "$output" == *'blocked_longform_lifecycle_migration_required'* ]]

        printf '{"workflow_id":"%s"}' "$(jq -r '.workflow_id' "$(focused_task_file "$book")")" > "$book/result.json"
        run node "$SCRIPT" apply-result --project-root "$book" --result "$book/result.json" --json
        [ "$status" -eq 0 ]
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

        node "$SCRIPT" "$command" --workflow-type review_repair --project-root "$book" --scope "1-10" --user-goal "审阅另一个范围" --reason "切换到无关审阅" --json > "$TMP_DIR/$command.json"
        node - "$TMP_DIR/$command.json" <<'NODE'
const fs=require('fs'),out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(!['created','switched'].includes(out.status)) throw new Error(JSON.stringify(out));
if(out.task.workflow_type!=='review_repair') throw new Error(JSON.stringify(out.task));
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
    mkdir -p "$TMP_DIR/book/大纲"
    printf '%s\n' '# 总纲' > "$TMP_DIR/book/大纲/总纲.md"
    resolve_action "$TMP_DIR/book" 1 >/dev/null
    apply_long_write_v2_result "$TMP_DIR/book" "" failed failed > "$TMP_DIR/review-out.json"

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
if(task.stage_execution) throw new Error(`review failure must stop before canonical revision: ${JSON.stringify(task.stage_execution)}`);
if(!task.pending_action||!Array.isArray(task.pending_action.options)||task.pending_action.options.length<2) throw new Error(`review failure must expose an author decision menu: ${JSON.stringify(task.pending_action)}`);
if(task.pending_action.options.length!==4||task.pending_action.free_text_enabled!==true) throw new Error(`review failure must expose the normal 1-4 author menu: ${JSON.stringify(task.pending_action)}`);
if(!task.planning_revision||task.planning_revision.status!=='awaiting_author_confirmation'||!/^sha256:[0-9a-f]{64}$/.test(task.planning_revision.plan_digest)) throw new Error(`validated plan was not frozen: ${JSON.stringify(task.planning_revision)}`);
if(out.status!=='advanced'||!out.visible_response||out.visible_response.user_visible===false) throw new Error(`review failure must return visible feedback: ${JSON.stringify(out)}`);
NODE

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/revision-started.json"
    node - "$TMP_DIR/book" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]),execution=task.stage_execution||{};
if(task.current_stage!=='master_outline'||execution.stage_id!=='master_outline'||execution.status!=='running') throw new Error(JSON.stringify(task));
if(JSON.stringify(execution.canonical_write_set)!==JSON.stringify(['大纲/总纲.md'])) throw new Error(JSON.stringify(execution));
if(!Array.isArray(execution.planning_targets)||execution.planning_targets.length!==1||execution.planning_targets[0].canonical!=='大纲/总纲.md'||!execution.planning_targets[0].staged.startsWith('追踪/workflow/staging/')) throw new Error(JSON.stringify(execution));
if(JSON.stringify(execution.write_set)!==JSON.stringify([execution.planning_targets[0].staged])) throw new Error(JSON.stringify(execution));
if(execution.planning_revision_digest!==task.planning_revision.plan_digest||execution.success_transition?.target!=='master_outline_review') throw new Error(JSON.stringify(execution));
NODE
}

@test "active master outline review exposes its exact result template and completion command" {
    local book="$TMP_DIR/master-outline-review-contract"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续当前长篇" --json >/dev/null
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    mkdir -p "$book/大纲"
    printf '%s\n' '# 总纲' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8'));
const stale='node scripts/workflow-stage-controller.js advance --project-root . --workflow-id "stale" --result "stale.json" --json';
delete task.stage_execution.result_packet_template;
task.stage_execution.execution_command=stale;
task.stage_execution.stage_completion_command=stale;
task.stage_execution.after_write_action={command:stale};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/master-outline-review-contract.json"
    node - "$TMP_DIR/master-outline-review-contract.json" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]),execution=out.stage_execution||{};
assert.equal(out.status,'stage_execution_resume_ready');
assert.equal(execution.stage_id,'master_outline_review');
assert.deepEqual((execution.result_packet_template||{}).planning_revision_plan,{
  version:'planning_revision_plan_v1',
  summary:'REPLACE_WITH_READABLE_REVISION_SUMMARY',
  requirements:['REPLACE_WITH_EXACT_REVISION_REQUIREMENT'],
  targets:['大纲/总纲.md'],
});
assert.equal(execution.result_packet_template.host_execution_mode,'cooperative_interactive');
assert.equal(execution.result_packet_template.runner_packet_path,'');
assert.deepEqual(execution.result_packet_template.memory_read_receipt,execution.memory_context.memory_read_receipt);
const command=`node scripts/workflow-state-machine.js apply-result --project-root . --workflow-id ${JSON.stringify(out.workflow_id)} --result ${JSON.stringify(execution.expected_result_packet)} --compact --json`;
assert.equal(execution.execution_command,command);
assert.equal(execution.stage_completion_command,command);
assert.equal((execution.after_write_action||{}).command,command);
NODE
}

@test "failed planning review rejects a missing or unsafe revision plan without starting a writer" {
    node - "$REPO/scripts/lib/long-planning-revision.js" "$TMP_DIR" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path');
const api=require(process.argv[2]),root=process.argv[3];
fs.mkdirSync(path.join(root,'大纲'),{recursive:true});fs.writeFileSync(path.join(root,'大纲/总纲.md'),'# 总纲\n');
const task={workflow_id:'wf-plan',current_stage:'master_outline_review',stage_execution:{stage_id:'master_outline_review'}};
const base={workflow_id:'wf-plan',stage_id:'master_outline_review',step_status:'failed',verification_result:'failed',lifecycle_transition_request:{action:'return',target:'master_outline'}};
assert.equal(api.validatePlanningRevisionPlan(root,task,base).status,'blocked_long_planning_revision_plan_missing');
assert.equal(api.validatePlanningRevisionPlan(root,task,{...base,planning_revision_plan:{version:'planning_revision_plan_v1',summary:'修订摘要',requirements:['修订要求'],targets:['../总纲.md']}}).status,'blocked_long_planning_revision_plan_invalid');
assert.equal(api.validatePlanningRevisionPlan(root,task,{...base,planning_revision_plan:{version:'planning_revision_plan_v1',summary:'修订摘要',requirements:['修订要求'],targets:['大纲/*.md']}}).status,'blocked_long_planning_revision_plan_invalid');
assert.equal(api.validatePlanningRevisionPlan(root,task,{...base,planning_revision_plan:{version:'planning_revision_plan_v1',summary:'修订摘要',requirements:['修订要求'],targets:['大纲/其他.md']}}).status,'blocked_long_planning_revision_target_mismatch');
assert.equal(api.validatePlanningRevisionPlan(root,task,{...base,planning_revision_plan:{version:'planning_revision_plan_v1',summary:{text:'修订摘要'},requirements:['修订要求'],targets:['大纲/总纲.md']}}).status,'blocked_long_planning_revision_plan_invalid');
assert.equal(api.validatePlanningRevisionPlan(root,task,{...base,planning_revision_plan:{version:'planning_revision_plan_v1',summary:'修订摘要',requirements:[{text:'修订要求'}],targets:['大纲/总纲.md']}}).status,'blocked_long_planning_revision_plan_invalid');
NODE
}

@test "runtime reconciliation persists the cooperative long review contract and retires a stale packet" {
    local book="$TMP_DIR/reconcile-master-review-contract"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧长篇" --json >/dev/null
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    mkdir -p "$book/大纲"
    printf '%s\n' '# 总纲' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    local workflow_id
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8')),execution=task.stage_execution;
const stale='node scripts/workflow-stage-controller.js advance --project-root . --workflow-id "stale" --result "stale.json" --json';
delete execution.result_packet_template;
execution.execution_command=stale;
execution.stage_completion_command=stale;
execution.after_write_action={command:stale};
const staleAttempt='sa-stale-master-outline-review',packet=execution.expected_result_packet;
task.stage_attempt_history=[...(task.stage_attempt_history||[]),{stage_id:'master_outline_review',stage_attempt_id:staleAttempt,work_unit_id:'wu-stale-master-outline-review',status:'failed',expected_result_packet:packet,failed_result_packet:packet}];
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),JSON.stringify({workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'master_outline_review',stage_attempt_id:staleAttempt,work_unit_id:'wu-stale-master-outline-review',memory_read_receipt:{contract_digest:'sha256:stale',memory_revision:'sha256:stale',packet_digest:'sha256:stale'}},null,2)+'\n');
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:cooperative-contract --json > "$TMP_DIR/reconcile-master-review-contract.json"
    node - "$TMP_DIR/reconcile-master-review-contract.json" "$book" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),out=require(process.argv[2]),root=process.argv[3],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),execution=task.stage_execution||{},template=execution.result_packet_template||{};
assert.equal(out.status,'runtime_reconciled');
assert.equal((out.stale_stage_result_retired||{}).status,'accepted_stage_result_retired');
assert.equal(fs.existsSync(path.join(root,execution.expected_result_packet)),false);
assert.equal(fs.existsSync(path.join(root,out.stale_stage_result_retired.accepted_result_packet)),true);
assert.deepEqual(template.memory_read_receipt,execution.memory_context.memory_read_receipt);
assert.equal(template.host_execution_mode,'cooperative_interactive');
assert.equal(template.runner_packet_path,'');
const command=`node scripts/workflow-state-machine.js apply-result --project-root . --workflow-id ${JSON.stringify(task.workflow_id)} --result ${JSON.stringify(execution.expected_result_packet)} --compact --json`;
assert.equal(execution.execution_command,command);
assert.equal(execution.stage_completion_command,command);
assert.equal((execution.after_write_action||{}).command,command);
NODE
}

@test "runtime reconciliation rolls back stale packet retirement when task persistence fails" {
    local book="$TMP_DIR/reconcile-retirement-rollback"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧长篇" --json >/dev/null
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    mkdir -p "$book/大纲"
    printf '%s\n' '# 总纲' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    local workflow_id
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    node - "$book" "$TMP_DIR/reconcile-retirement-rollback-baseline.json" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],baselineFile=process.argv[3],file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8')),execution=task.stage_execution;
const staleAttempt='sa-stale-persist-failure',packet=execution.expected_result_packet;
task.stage_attempt_history=[...(task.stage_attempt_history||[]),{stage_id:task.current_stage,stage_attempt_id:staleAttempt,work_unit_id:'wu-stale-persist-failure',status:'failed',expected_result_packet:packet,failed_result_packet:packet}];
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),JSON.stringify({workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:task.current_stage,stage_attempt_id:staleAttempt,work_unit_id:'wu-stale-persist-failure'},null,2)+'\n');
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
fs.writeFileSync(baselineFile,JSON.stringify({task_text:fs.readFileSync(file,'utf8'),packet_text:fs.readFileSync(path.join(root,packet),'utf8'),packet}));
NODE

    run env NOVEL_ASSISTANT_TEST_FAIL_RECONCILE_PERSIST=1 node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:reconcile-rollback --json
    [ "$status" -eq 2 ] || { echo "$output"; false; }
    [[ "$output" == *'blocked_runtime_reconcile_persist_failed'* ]]
    node - "$book" "$TMP_DIR/reconcile-retirement-rollback-baseline.json" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],baseline=require(process.argv[3]),file=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
assert.equal(fs.readFileSync(file,'utf8'),baseline.task_text);
assert.equal(fs.readFileSync(path.join(root,baseline.packet),'utf8'),baseline.packet_text);
const attempt=(task.stage_attempt_history||[]).find(item=>item.stage_attempt_id==='sa-stale-persist-failure');
assert.equal(attempt.failed_result_packet,baseline.packet);
NODE
}

@test "unsafe failed planning review does not advertise the missing-plan restart command" {
    book="$TMP_DIR/unsafe-planning-review"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续当前长篇" --json >/dev/null
    advance_long_write_stage "$book"; advance_long_write_stage "$book"; advance_long_write_stage "$book"
    mkdir -p "$book/大纲"; printf '%s\n' '# 总纲旧稿' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    run apply_long_write_v2_result "$book" "" failed failed "" unsafe_planning_revision_plan
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_long_planning_revision_plan_invalid'* ]]
    [[ "$output" != *'recovery_command'* ]]
    [[ "$output" != *'reconcile-runtime'* ]]
}

@test "failed volume outline review freezes the accepted predecessor target before confirmation" {
    book="$TMP_DIR/volume-plan-return"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续当前长篇" --json >/dev/null
    for _ in 1 2 3 4; do advance_long_write_stage "$book"; done
    mkdir -p "$book/大纲/第1卷"
    printf '%s\n' '# 第一卷卷纲' > "$book/大纲/第1卷/卷纲.md"
    resolve_action "$book" 1 >/dev/null
    apply_long_write_v2_result "$book" "" completed pass "" "" "" "大纲/第1卷/卷纲.md" >/dev/null
    resolve_action "$book" 1 >/dev/null
    apply_long_write_v2_result "$book" "" failed failed > "$TMP_DIR/volume-plan-return.json"
    node - "$TMP_DIR/volume-plan-return.json" <<'NODE'
const out=require(process.argv[2]),task=out.task;
if(task.current_stage!=='volume_outline'||task.stage_execution||task.planning_revision?.target_authority!=='accepted_predecessor_result') throw new Error(JSON.stringify(out));
if(JSON.stringify(task.planning_revision?.plan?.targets)!==JSON.stringify(['大纲/第1卷/卷纲.md'])) throw new Error(JSON.stringify(task.planning_revision));
NODE
    resolve_action "$book" 1 >/dev/null
    node - "$book" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]),execution=task.stage_execution||{};
if(execution.stage_id!=='volume_outline'||execution.success_transition?.target!=='volume_outline_review') throw new Error(JSON.stringify(execution));
if(JSON.stringify(execution.canonical_write_set)!==JSON.stringify(['大纲/第1卷/卷纲.md'])||execution.planning_targets?.[0]?.canonical!=='大纲/第1卷/卷纲.md') throw new Error(JSON.stringify(execution));
NODE
}

@test "master and volume planning finalizer atomically advance to their exact review and replay idempotently" {
    finalizer="$REPO/scripts/long-planning-stage-finalize.js"
    for kind in master volume; do
        book="$TMP_DIR/finalize-$kind"
        node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续当前长篇" --json >/dev/null
        if [ "$kind" = master ]; then
            advance_long_write_stage "$book"
            advance_long_write_stage "$book"
            advance_long_write_stage "$book"
            mkdir -p "$book/大纲"
            printf '%s\n' '# 总纲旧稿' > "$book/大纲/总纲.md"
            resolve_action "$book" 1 >/dev/null
            apply_long_write_v2_result "$book" "" failed failed >/dev/null
            mkdir -p "$book/追踪/story-system"
            printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$book/追踪/story-system/write-policy.json"
        else
            for _ in 1 2 3 4; do advance_long_write_stage "$book"; done
            mkdir -p "$book/大纲/第1卷"
            printf '%s\n' '# 卷纲旧稿' > "$book/大纲/第1卷/卷纲.md"
            resolve_action "$book" 1 >/dev/null
            apply_long_write_v2_result "$book" "" completed pass "" "" "" "大纲/第1卷/卷纲.md" >/dev/null
            mkdir -p "$book/追踪/story-system"
            printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$book/追踪/story-system/write-policy.json"
            resolve_action "$book" 1 >/dev/null
            apply_long_write_v2_result "$book" "" failed failed >/dev/null
        fi
        resolve_action "$book" 1 >/dev/null
        node - "$book" "$kind" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],kind=process.argv[3];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),pair=task.stage_execution.planning_targets[0];
const execution=task.stage_execution||{},template=execution.result_packet_template||{};
if(!String(execution.execution_command||'').includes('long-planning-stage-finalize.js')||String(execution.execution_command||'').includes('workflow-state-machine.js apply-result')) throw new Error(JSON.stringify(execution));
if(template.host_execution_mode!=='cooperative_interactive'||template.runner_packet_path!=='') throw new Error(JSON.stringify(template));
fs.writeFileSync(path.join(root,pair.staged),kind==='master'?'# 总纲修订稿\n':'# 卷纲修订稿\n');
if(kind==='master') {
  const runnerRel=`${task.task_dir}/runner-packets/${execution.stage_id}.managed.run.json`,runnerFile=path.join(root,runnerRel);
  fs.mkdirSync(path.dirname(runnerFile),{recursive:true});
  fs.writeFileSync(runnerFile,JSON.stringify({workflow_id:task.workflow_id,stage_id:execution.stage_id,stage_attempt_id:execution.stage_attempt_id,work_unit_id:execution.work_unit_id,run_id:'run-master-planning-managed',expected_result_packet:execution.expected_result_packet,stage_contract:{write_set:execution.write_set,canonical_write_set:execution.canonical_write_set},memory_context:execution.memory_context||null},null,2));
  task.runtime_guard=task.runtime_guard||{};task.runtime_guard.last_runner_attempt={workflow_id:task.workflow_id,stage_id:execution.stage_id,stage_attempt_id:execution.stage_attempt_id,work_unit_id:execution.work_unit_id,run_id:'run-master-planning-managed',runner_packet_path:runnerRel,expected_result_packet:execution.expected_result_packet};
  fs.writeFileSync(path.join(root,task.task_dir,'task.json'),JSON.stringify(task,null,2)+'\n');
}
NODE
        node "$finalizer" --project-root "$book" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")" --apply --json > "$TMP_DIR/finalize-$kind.json" || { cat "$TMP_DIR/finalize-$kind.json"; false; }
        if [ "$kind" = master ]; then
            result_packet="$(node -e "process.stdout.write(require(process.argv[1]).result_packet)" "$TMP_DIR/finalize-$kind.json")"
            node "$SCRIPT" apply-result --project-root "$book" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")" --result "$book/$result_packet" --json > "$TMP_DIR/managed-master-apply.json" || { cat "$TMP_DIR/managed-master-apply.json"; false; }
        fi
        node - "$TMP_DIR/finalize-$kind.json" "$book" "$kind" <<'NODE'
const fs=require('fs'),path=require('path'),out=require(process.argv[2]),root=process.argv[3],kind=process.argv[4];
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),review=kind==='master'?'master_outline_review':'volume_outline_review',canonical=kind==='master'?'大纲/总纲.md':'大纲/第1卷/卷纲.md';
const expectedStatus=kind==='master'?'long_planning_result_ready':'long_planning_applied';
if(out.status!==expectedStatus||task.current_stage!==review) throw new Error(JSON.stringify({out,current:task.current_stage}));
if(kind==='master'&&out.host_execution_mode!=='managed_runner') throw new Error(JSON.stringify(out));
const packet=require(path.join(root,out.result_packet));
if(packet.stage_id!==(kind==='master'?'master_outline':'volume_outline')||packet.next_stage_id!==review||packet.lifecycle_transition_request?.target!==(kind==='master'?'master_outline':'volume_outline')) throw new Error(JSON.stringify(packet));
if(!fs.readFileSync(path.join(root,canonical),'utf8').includes('修订稿')) throw new Error('canonical target was not committed');
NODE
        node "$finalizer" --project-root "$book" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")" --apply --json > "$TMP_DIR/replay-$kind.json"
        node - "$TMP_DIR/replay-$kind.json" <<'NODE'
const out=require(process.argv[2]);if(out.status!=='long_planning_already_applied'||out.reused_accepted_result!==true) throw new Error(JSON.stringify(out));
NODE
    done
}

@test "confirmed planning revision fails closed when the frozen plan digest drifts" {
    book="$TMP_DIR/planning-digest-drift"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续当前长篇" --json >/dev/null
    advance_long_write_stage "$book"; advance_long_write_stage "$book"; advance_long_write_stage "$book"
    mkdir -p "$book/大纲"; printf '%s\n' '# 总纲旧稿' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    apply_long_write_v2_result "$book" "" failed failed >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8'));
task.planning_revision.plan.summary='未经过菜单确认的替换摘要';
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    run resolve_action "$book" 1
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    node - "$book" "$output" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]),out=JSON.parse(process.argv[3]),execution=task.stage_execution||{};
if(out.status!=='stage_execution_contract_required'||execution.status!=='contract_blocked') throw new Error(JSON.stringify({out,execution}));
if((execution.write_set||[]).length||(execution.canonical_write_set||[]).length||(execution.planning_targets||[]).length) throw new Error(`drift retained a writable planning contract: ${JSON.stringify(execution)}`);
NODE
}

@test "current review missing-plan result uses urgent invalid-result recovery without mutating the outline" {
    book="$TMP_DIR/legacy-review-plan-restart"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧长篇" --json >/dev/null
    advance_long_write_stage "$book"; advance_long_write_stage "$book"; advance_long_write_stage "$book"
    mkdir -p "$book/大纲"; printf '%s\n' '# 不得改动的总纲' > "$book/大纲/总纲.md"
    before="$(shasum -a 256 "$book/大纲/总纲.md" | awk '{print $1}')"
    resolve_action "$book" 1 >/dev/null
    run apply_long_write_v2_result "$book" "" failed failed "" planning_revision_plan
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_long_planning_revision_plan_missing'* ]]
    [[ "$output" == *'reconcile-runtime'* ]]
    [[ "$output" == *'--session-id'* ]]
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:legacy-plan --json > "$TMP_DIR/legacy-plan-restart.json"
    node - "$TMP_DIR/legacy-plan-restart.json" "$book" <<'NODE'
const fs=require('fs'),path=require('path'),out=require(process.argv[2]),root=process.argv[3],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),execution=task.stage_execution||{};
const retired=out.stale_stage_result_retired||{};
if(out.status!=='runtime_reconciled'||retired.status!=='invalid_stage_result_contract_retired'||task.current_stage!=='master_outline_review'||execution.stage_id!=='master_outline_review'||execution.status!=='running') throw new Error(JSON.stringify({out,task}));
if((execution.write_set||[]).length||(execution.canonical_write_set||[]).length||(execution.planning_targets||[]).length) throw new Error(JSON.stringify(execution));
if(execution.legacy_review_restart) throw new Error(`urgent recovery must not masquerade as legacy restart: ${JSON.stringify(execution.legacy_review_restart)}`);
if(!retired.accepted_result_packet||!fs.existsSync(path.join(root,retired.accepted_result_packet))) throw new Error(JSON.stringify(out));
NODE
    after="$(shasum -a 256 "$book/大纲/总纲.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
}

@test "legacy review already returned to producer restarts the same review read only" {
    book="$TMP_DIR/legacy-returned-producer-plan-restart"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧长篇" --json >/dev/null
    advance_long_write_stage "$book"; advance_long_write_stage "$book"; advance_long_write_stage "$book"
    mkdir -p "$book/大纲"; printf '%s\n' '# 不得改动的总纲' > "$book/大纲/总纲.md"
    before="$(shasum -a 256 "$book/大纲/总纲.md" | awk '{print $1}')"
    resolve_action "$book" 1 >/dev/null
    apply_long_write_v2_result "$book" "" failed failed >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const reviewFile=path.join(root,task.task_dir,'result-packets','master_outline_review.result.json'),review=JSON.parse(fs.readFileSync(reviewFile,'utf8'));
delete review.planning_revision_plan;
fs.writeFileSync(reviewFile,JSON.stringify(review,null,2)+'\n');
delete task.planning_revision;
task.pending_action=null;
task.current_stage='master_outline'; task.current_step='master_outline'; task.status='running';
task.machine.last_transition='runtime_reconciled';
task.stage_execution={
  status:'running',stage_attempt_id:'sa-legacy-master-revision',work_unit_id:'wu-legacy-master-revision',
  stage_id:'master_outline',step_id:'master_outline',expected_result_packet:`${task.task_dir}/result-packets/master_outline.result.json`,
  write_set:['大纲/**','追踪/**'],canonical_write_set:[],planning_targets:[],revision_targets:[]
};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:legacy-returned-plan --json > "$TMP_DIR/legacy-returned-plan-restart.json"
    node - "$TMP_DIR/legacy-returned-plan-restart.json" "$book" <<'NODE'
const fs=require('fs'),path=require('path'),out=require(process.argv[2]),root=process.argv[3],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),execution=task.stage_execution||{};
if(out.status!=='long_planning_review_restarted_read_only'||task.current_stage!=='master_outline_review'||execution.stage_id!=='master_outline_review'||execution.status!=='running') throw new Error(JSON.stringify({out,task}));
if((execution.write_set||[]).length||(execution.canonical_write_set||[]).length||(execution.planning_targets||[]).length) throw new Error(JSON.stringify(execution));
const graph=task.lifecycle_graph||{},nodes=graph.nodes||[],producer=nodes.find((node)=>node.id==='master_outline')||{},review=nodes.find((node)=>node.id==='master_outline_review')||{},reviewIndex=nodes.findIndex((node)=>node.id==='master_outline_review');
if(graph.current_node!=='master_outline_review'||JSON.stringify(graph.asset_target)!==JSON.stringify(review.asset_target)) throw new Error(`lifecycle graph did not follow restarted review: ${JSON.stringify(graph)}`);
if(producer.status!=='accepted'||review.status!=='draft') throw new Error(`producer/review status mismatch: ${JSON.stringify({producer,review})}`);
if(!(graph.completed_nodes||[]).includes('master_outline')||(graph.completed_nodes||[]).includes('master_outline_review')) throw new Error(`completed nodes mismatch: ${JSON.stringify(graph.completed_nodes)}`);
if(JSON.stringify(graph.invalidated_nodes)!==JSON.stringify(nodes.slice(reviewIndex).map((node)=>node.id))) throw new Error(`invalidated nodes mismatch: ${JSON.stringify(graph.invalidated_nodes)}`);
if((graph.review_results||{}).master_outline_review) throw new Error(`restart forged an accepted review receipt: ${JSON.stringify(graph.review_results)}`);
if(!(task.machine.completed_stages||[]).includes('master_outline')||task.machine.remaining_stages[0]!=='master_outline_review') throw new Error(`machine mismatch: ${JSON.stringify(task.machine)}`);
if(task.lifecycle.status!=='active'||task.unit_lifecycle.current_stage!=='master_outline_review'||task.unit_lifecycle.current_role!=='quality_gate'||!(task.unit_lifecycle.completed_roles||[]).includes('macro_contract')) throw new Error(`lifecycle mismatch: ${JSON.stringify({lifecycle:task.lifecycle,unit:task.unit_lifecycle})}`);
const producerAttempt=(task.stage_attempt_history||[]).find((item)=>item.stage_attempt_id==='sa-legacy-master-revision');
if(!producerAttempt||producerAttempt.status!=='rejected') throw new Error(JSON.stringify(task.stage_attempt_history));
if(!out.archived_result_packet||!fs.existsSync(path.join(root,out.archived_result_packet))) throw new Error(JSON.stringify(out));
NODE
    node - "$book" <<'NODE'
const fs=require('fs'),root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8'));
const graph=task.lifecycle_graph,nodes=graph.nodes||[],producer=nodes.find((node)=>node.id==='master_outline'),review=nodes.find((node)=>node.id==='master_outline_review');
graph.current_node='master_outline';graph.asset_target={...producer.asset_target};graph.completed_nodes=(graph.completed_nodes||[]).filter((id)=>id!=='master_outline');
producer.status='invalidated';review.status='invalidated';task.machine.completed_stages=(task.machine.completed_stages||[]).filter((id)=>id!=='master_outline');
task.unit_lifecycle.completed_roles=(task.unit_lifecycle.completed_roles||[]).filter((role)=>role!=='macro_contract');
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:legacy-returned-plan --json > "$TMP_DIR/legacy-partial-plan-repaired.json"
    node - "$TMP_DIR/legacy-partial-plan-repaired.json" "$book" <<'NODE'
const out=require(process.argv[2]),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[3]),graph=task.lifecycle_graph||{},nodes=graph.nodes||[],producer=nodes.find((node)=>node.id==='master_outline')||{},review=nodes.find((node)=>node.id==='master_outline_review')||{};
if(out.status!=='long_planning_review_restart_state_reconciled'||graph.current_node!=='master_outline_review'||producer.status!=='accepted'||review.status!=='draft') throw new Error(JSON.stringify({out,task}));
if(!(task.machine.completed_stages||[]).includes('master_outline')||!(task.unit_lifecycle.completed_roles||[]).includes('macro_contract')) throw new Error(JSON.stringify({machine:task.machine,unit:task.unit_lifecycle}));
NODE
    task_file="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).focusedTaskFile(process.argv[1]))" "$book")"
    node - "$task_file" <<'NODE'
const fs=require('fs'),file=process.argv[2],task=JSON.parse(fs.readFileSync(file,'utf8')),execution=task.stage_execution||{};
for(const holder of [execution.memory_context&&execution.memory_context.memory_contract,execution.stage_context_packet&&execution.stage_context_packet.memory_contract]) {
  if(holder&&holder.query) { delete holder.query.stage_attempt_id; delete holder.query.work_unit_id; }
}
for(const receipt of [execution.memory_context&&execution.memory_context.memory_read_receipt,execution.stage_context_packet&&execution.stage_context_packet.memory_read_receipt,(execution.result_packet_template||{}).memory_read_receipt]) {
  if(receipt) { delete receipt.stage_attempt_id; delete receipt.work_unit_id; }
}
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:legacy-returned-plan --json > "$TMP_DIR/legacy-partial-plan-replay.json"
    node - "$TMP_DIR/legacy-partial-plan-replay.json" "$book" <<'NODE'
const out=require(process.argv[2]),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[3]),execution=task.stage_execution||{},contract=((execution.memory_context||{}).memory_contract||{}).query||{},receipt=(execution.memory_context||{}).memory_read_receipt||{};
if(out.status!=='long_planning_review_restart_state_reconciled'||out.memory_context_refreshed!==true) throw new Error(JSON.stringify(out));
if(contract.stage_attempt_id!==execution.stage_attempt_id||contract.work_unit_id!==execution.work_unit_id) throw new Error(JSON.stringify({contract,execution}));
if(receipt.stage_attempt_id!==execution.stage_attempt_id||receipt.work_unit_id!==execution.work_unit_id) throw new Error(JSON.stringify({receipt,execution}));
NODE
    stable_hash="$(shasum -a 256 "$task_file" | awk '{print $1}')"
    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:legacy-returned-plan --json > "$TMP_DIR/legacy-partial-plan-stable.json"
    node - "$TMP_DIR/legacy-partial-plan-stable.json" <<'NODE'
const out=require(process.argv[2]);if(out.status!=='long_planning_review_already_restarted_read_only') throw new Error(JSON.stringify(out));
NODE
    [ "$stable_hash" = "$(shasum -a 256 "$task_file" | awk '{print $1}')" ]
    after="$(shasum -a 256 "$book/大纲/总纲.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
}

@test "legacy planning review restart keeps the source result when the replacement attempt cannot start" {
    book="$TMP_DIR/legacy-review-restart-atomic"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续旧长篇" --json >/dev/null
    advance_long_write_stage "$book"; advance_long_write_stage "$book"; advance_long_write_stage "$book"
    mkdir -p "$book/大纲"; printf '%s\n' '# 不得改动的总纲' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    apply_long_write_v2_result "$book" "" failed failed >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const reviewFile=path.join(root,task.task_dir,'result-packets','master_outline_review.result.json'),review=JSON.parse(fs.readFileSync(reviewFile,'utf8'));
delete review.planning_revision_plan;fs.writeFileSync(reviewFile,JSON.stringify(review,null,2)+'\n');
delete task.planning_revision;task.pending_action=null;task.current_stage='master_outline';task.current_step='master_outline';task.status='running';task.machine.last_transition='runtime_reconciled';
task.stage_execution={status:'running',stage_attempt_id:'sa-legacy-atomic-revision',work_unit_id:'wu-legacy-atomic-revision',stage_id:'master_outline',step_id:'master_outline',expected_result_packet:`${task.task_dir}/result-packets/master_outline.result.json`,write_set:['大纲/**','追踪/**'],canonical_write_set:[],planning_targets:[],revision_targets:[]};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
    archive_dir="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(t.task_dir+'/audit/archive/legacy-planning-review')" "$book")"
    mkdir -p "$book/$archive_dir"
    chmod 500 "$book/$archive_dir"
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    source_result="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(t.task_dir+'/result-packets/master_outline_review.result.json')" "$book")"
    source_hash="$(shasum -a 256 "$book/$source_result" | awk '{print $1}')"

    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:atomic-restart --json
    chmod 700 "$book/$archive_dir"
    [ "$status" -ne 0 ]
    [[ "$output" == *'EACCES'* || "$output" == *'permission denied'* ]]
    [ -f "$book/$source_result" ]
    [ "$source_hash" = "$(shasum -a 256 "$book/$source_result" | awk '{print $1}')" ]
}

@test "detail outline quality pass with matching identity advances to chapter brief" {
    book="$TMP_DIR/detail-quality-pass"
    mkdir -p "$book/大纲/第1卷"
    printf '%s\n' '# 第1卷卷纲' '第001章完成线索确认。' > "$book/大纲/第1卷/卷纲.md"
    prepare_detail_outline_review "$book"
    node "$SCRIPT" next-candidates --project-root "$book" --compact --json >/dev/null
    node - "$book" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]);
const targets=(task.stage_execution||{}).review_targets||[];
if((task.stage_execution||{}).result_contract!=='detail_outline_quality_v2') throw new Error(JSON.stringify(task.stage_execution));
if(targets.length!==1||targets[0].outline_path!=='大纲/第1卷/细纲_第001章.md'||!/^[0-9a-f]{64}$/.test(targets[0].outline_sha256)) throw new Error(JSON.stringify(targets));
const hint=String((task.stage_execution||{}).resume_hint||'');
if(!hint||/undefined/.test(hint)||/第\s*章/.test(hint)) throw new Error(JSON.stringify({resume_hint:hint}));
NODE
    apply_detail_outline_quality_result "$book" pass > "$TMP_DIR/detail-quality-pass.json"

    node - "$TMP_DIR/detail-quality-pass.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(!['advanced','stage_started'].includes(out.status) || out.task.current_stage!=='chapter_brief') throw new Error(JSON.stringify(out));
if(out.task.machine.last_transition!=='lifecycle_node_completed') throw new Error(JSON.stringify(out.task.machine));
const accepted=out.task.accepted_detail_outline_targets||[];
const chapterTargets=(out.task.stage_execution||{}).chapter_targets||[];
if(accepted.length!==1||accepted[0].outline_path!=='大纲/第1卷/细纲_第001章.md') throw new Error(JSON.stringify(accepted));
if(JSON.stringify(chapterTargets)!==JSON.stringify(accepted)) throw new Error(JSON.stringify(out.task.stage_execution));
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

@test "active chapter brief exposes a frozen receipt template and exact completion command" {
    local book="$TMP_DIR/chapter-brief-contract"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8'));
const stale='node scripts/workflow-stage-controller.js advance --project-root . --workflow-id "stale" --result "stale.json" --json';
delete task.stage_execution.result_packet_template;
task.stage_execution.execution_command=stale;
task.stage_execution.stage_completion_command=stale;
task.stage_execution.after_write_action={command:stale};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/chapter-brief-contract.json"
    node - "$TMP_DIR/chapter-brief-contract.json" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]),execution=out.stage_execution||{},template=execution.result_packet_template||{};
assert.equal(out.status,'stage_execution_resume_ready');
assert.equal(execution.stage_id,'chapter_brief');
assert.equal(template.workflow_id,out.workflow_id);
assert.equal(template.workflow_type,'long_write');
assert.equal(template.stage_id,'chapter_brief');
assert.equal(template.result_packet_path,execution.expected_result_packet);
assert.equal(template.host_execution_mode,'cooperative_interactive');
assert.equal(template.runner_packet_path,'');
assert.deepEqual(template.memory_read_receipt,execution.memory_context.memory_read_receipt);
for(const field of ['outputs','changed_files','evidence','checkpoint_state','lifecycle_transition_request']) assert.ok(Object.hasOwn(template,field),field);
const command=`node scripts/workflow-state-machine.js apply-result --project-root . --workflow-id ${JSON.stringify(out.workflow_id)} --result ${JSON.stringify(execution.expected_result_packet)} --compact --json`;
assert.equal(execution.execution_command,command);
assert.equal(execution.stage_completion_command,command);
assert.equal((execution.after_write_action||{}).command,command);
NODE
}

@test "brief review compactness return keeps one durable producer continuation" {
    local book="$TMP_DIR/brief-review-return-continuation"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null

    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2];
const task=fixture.readFocusedTask(root),target=task.active_chapter_target;
if(!target||!target.contract_path||task.current_stage!=='chapter_brief') throw new Error(JSON.stringify(task));
fs.mkdirSync(path.dirname(path.join(root,target.contract_path)),{recursive:true});
fs.writeFileSync(path.join(root,target.contract_path),`# 当前章 Brief\n\n- 目标字数：3200（合法区间 2880—3840）\n\n${'中性情节说明。'.repeat(520)}\n`);
NODE
    brief_path="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).active_chapter_target.contract_path)" "$book")"
    apply_long_write_v2_result "$book" "" completed pass "" "" "" "$brief_path" >/dev/null
    resolve_action "$book" 1 >/dev/null

    apply_long_write_v2_result "$book" > "$TMP_DIR/brief-review-return-apply.json"
    node - "$TMP_DIR/brief-review-return-apply.json" "$book" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),task=fixture.readFocusedTask(process.argv[3]);
assert.equal(out.current_stage,'chapter_brief');
assert.equal(task.current_stage,'chapter_brief');
assert.equal(task.stage_execution,null);
assert.ok(task.pending_action,'review return must persist one producer continuation menu');
assert.equal((task.pending_action.options||[]).length,4);
assert.equal(task.machine.last_execution_event,'awaiting_review_repair');
assert.equal((out.next_candidates||[]).length,4);
assert.match(String((out.visible_response||{}).text||''),/Brief 约为目标正文的 \d+%/u);
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/brief-review-return-next.json"
    node - "$TMP_DIR/brief-review-return-next.json" "$book" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),task=fixture.readFocusedTask(process.argv[3]);
const running=task.stage_execution&&task.stage_execution.status==='running';
const pending=task.pending_action&&task.pending_action.status!=='resolved';
assert.ok(running||pending,'durable authority must be resumable or expose a pending menu');
if(!running) {
  assert.equal((task.pending_action.options||[]).length,4);
  assert.equal((out.next_candidates||[]).length,4);
}
assert.ok(out.status==='stage_execution_resume_ready'||(out.next_candidates||[]).length===4,'next-candidates must not return an empty continuation');
assert.match(String((out.visible_response||{}).text||''),/Brief 约为目标正文的 \d+%/u);
NODE
}

@test "compact running chapter brief projects one safe host target without durable snapshots" {
    local book="$TMP_DIR/compact-running-chapter-brief"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null
    prepare_long_chapter_v2_targets "$book" 4
    node - "$book" <<'NODE'
const fs=require('fs'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8'));
const execution=task.stage_execution,targets=task.accepted_detail_outline_targets;
execution.stage_id='chapter_brief';execution.step_id='chapter_brief';execution.host_execution_mode='cooperative_interactive';
execution.chapter_target=targets[0];execution.chapter_targets=targets;execution.write_set=[targets[0].contract_path];
execution.context_read_command=`node scripts/workflow-stage-context.js read-current --project-root . --workflow-id ${JSON.stringify(task.workflow_id)}`;
execution.resume_hint='只读取当前阶段包，只修改冻结活动章，完成后执行阶段完成命令。';
execution.canonical_write_set=[];
execution.canonical_write_baseline={files:Object.fromEntries(Array.from({length:100},(_,i)=>[`canonical-${i}.md`,'sha256:'+'a'.repeat(64)]))};
execution.write_audit_snapshot={files:Object.fromEntries(Array.from({length:100},(_,i)=>[`audit-${i}.md`,'sha256:'+'b'.repeat(64)]))};
execution.write_snapshot={version:1,captured_at:'2026-08-05T00:00:00.000Z',authorized_write_set:execution.write_set,excluded_paths:['正文/**'],files:Object.fromEntries(Array.from({length:900},(_,i)=>[`正文/第${String(i+1).padStart(3,'0')}章.md`,'sha256:'+'c'.repeat(64)]))};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/compact-running-chapter-brief.json"
    node - "$TMP_DIR/compact-running-chapter-brief.json" "$book" <<'NODE'
const assert=require('assert'),fs=require('fs'),outFile=process.argv[2],root=process.argv[3],raw=fs.readFileSync(outFile),out=JSON.parse(raw),execution=out.stage_execution||{},template=execution.result_packet_template||{},durable=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),saved=durable.stage_execution||{};
assert.equal(out.status,'stage_execution_resume_ready');
assert.ok(raw.byteLength<25*1024,`compact resume output too large: ${raw.byteLength} bytes`);
for(const field of ['write_snapshot','canonical_write_baseline','write_audit_snapshot']) assert.equal(Object.hasOwn(execution,field),false,field);
for(const field of ['stage_attempt_id','work_unit_id','expected_result_packet','write_set','chapter_target','context_read_command','execution_command','stage_completion_command','result_packet_template','resume_hint']) assert.ok(Object.hasOwn(execution,field),field);
assert.equal(execution.execution_command,execution.stage_completion_command);
assert.equal((execution.after_write_action||{}).command,execution.stage_completion_command);
assert.deepEqual(execution.chapter_targets,[execution.chapter_target]);
assert.deepEqual(template.chapter_targets,[execution.chapter_target]);
assert.deepEqual(template.chapter_target,execution.chapter_target);
assert.deepEqual(template.memory_read_receipt,(execution.memory_context||{}).memory_read_receipt);
for(const field of ['outputs','changed_files','evidence','checkpoint_state','lifecycle_transition_request','result_write_set']) assert.ok(Object.hasOwn(template,field),field);
assert.ok(saved.write_snapshot&&Object.keys(saved.write_snapshot.files||{}).length===900,'durable write_snapshot was removed');
assert.ok(saved.canonical_write_baseline&&saved.write_audit_snapshot,'durable baselines were removed');
assert.equal((saved.chapter_targets||[]).length,4,'durable pending chapter targets were shortened');
NODE
}

@test "same-attempt packet with a stale frozen receipt requires one recovery command and is safely retired" {
    local book="$TMP_DIR/chapter-brief-stale-receipt"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null
    local workflow_id
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    node - "$book" "$TMP_DIR/chapter-brief-creative-baseline.txt" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],baseline=process.argv[3],file=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(file,'utf8')),execution=task.stage_execution,packet=execution.expected_result_packet;
const creative='大纲/第1卷/细纲_第001章.md';
fs.writeFileSync(baseline,fs.readFileSync(path.join(root,creative)));
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),JSON.stringify({
  workflow_id:task.workflow_id,
  workflow_type:'long_write',
  stage_id:task.current_stage,
  stage_attempt_id:execution.stage_attempt_id,
  work_unit_id:execution.work_unit_id,
  step_status:'completed',
  host_execution_mode:'cooperative_interactive',
  memory_read_receipt:{contract_digest:'sha256:stale',memory_revision:'sha256:stale',packet_digest:'sha256:stale'},
},null,2)+'\n');
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/chapter-brief-stale-receipt-recovery.json"
    node - "$TMP_DIR/chapter-brief-stale-receipt-recovery.json" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]);
assert.equal(out.status,'stage_result_contract_recovery_ready');
assert.equal(out.interaction_mode,'execute_command');
assert.equal(out.presentation_allowed,false);
assert.match(out.execution_command,/workflow-state-machine\.js reconcile-runtime/u);
assert.equal(out.stage_execution,undefined);
assert.equal(out.current_required_action,undefined);
NODE

    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:stale-receipt --json > "$TMP_DIR/chapter-brief-stale-receipt-reconciled.json"
    node - "$TMP_DIR/chapter-brief-stale-receipt-reconciled.json" "$book" "$TMP_DIR/chapter-brief-creative-baseline.txt" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),out=require(process.argv[2]),root=process.argv[3],baseline=process.argv[4],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),execution=task.stage_execution;
assert.equal(out.status,'runtime_reconciled');
assert.equal((out.stale_stage_result_retired||{}).status,'invalid_stage_result_contract_retired');
assert.equal(fs.existsSync(path.join(root,execution.expected_result_packet)),false);
assert.equal(fs.existsSync(path.join(root,out.stale_stage_result_retired.accepted_result_packet)),true);
assert.equal(fs.readFileSync(path.join(root,'大纲/第1卷/细纲_第001章.md'),'utf8'),fs.readFileSync(baseline,'utf8'));
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/chapter-brief-stale-receipt-resumed.json"
    node - "$TMP_DIR/chapter-brief-stale-receipt-resumed.json" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]),execution=out.stage_execution||{};
assert.equal(out.status,'stage_execution_resume_ready');
assert.deepEqual(execution.result_packet_template.memory_read_receipt,execution.memory_context.memory_read_receipt);
NODE
}

@test "same-attempt planning review packet with an invalid required schema is safely retired" {
    local book="$TMP_DIR/master-review-invalid-plan-packet"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续当前长篇" --json >/dev/null
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    mkdir -p "$book/大纲"
    printf '%s\n' '# 总纲' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    local workflow_id
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],task=fixture.readFocusedTask(root),execution=task.stage_execution,packet=execution.expected_result_packet;
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),JSON.stringify({
  ...(execution.result_packet_template||{}),
  workflow_id:task.workflow_id,
  workflow_type:'long_write',
  stage_id:task.current_stage,
  stage_attempt_id:execution.stage_attempt_id,
  work_unit_id:execution.work_unit_id,
  step_status:'failed',
  verification_result:'failed',
  planning_revision_plan:{version:'planning_revision_plan_v1',summary:{text:'错误类型'},requirements:['修订要求'],targets:['大纲/总纲.md']},
},null,2)+'\n');
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/master-review-invalid-plan-recovery.json"
    node - "$TMP_DIR/master-review-invalid-plan-recovery.json" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]);
assert.equal(out.status,'stage_result_contract_recovery_ready');
assert.match(out.execution_command,/reconcile-runtime/u);
assert.equal(out.presentation_allowed,false);
NODE
    node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:invalid-plan --json > "$TMP_DIR/master-review-invalid-plan-reconciled.json"
    node - "$TMP_DIR/master-review-invalid-plan-reconciled.json" "$book" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),out=require(process.argv[2]),root=process.argv[3],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
assert.equal(out.status,'runtime_reconciled');
assert.equal(out.stale_stage_result_retired.status,'invalid_stage_result_contract_retired');
assert.equal(out.stale_stage_result_retired.validation_status,'blocked_long_planning_revision_plan_invalid');
assert.equal(fs.existsSync(path.join(root,task.stage_execution.expected_result_packet)),false);
assert.equal(fs.existsSync(path.join(root,out.stale_stage_result_retired.accepted_result_packet)),true);
NODE
}

@test "recorded accepted same-attempt packet is never offered to automatic retirement" {
    local book="$TMP_DIR/master-review-accepted-packet-protected"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "继续当前长篇" --json >/dev/null
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    advance_long_write_stage "$book"
    mkdir -p "$book/大纲"
    printf '%s\n' '# 总纲' > "$book/大纲/总纲.md"
    resolve_action "$book" 1 >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root),execution=task.stage_execution,packet=execution.expected_result_packet;
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),JSON.stringify({workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:task.current_stage,stage_attempt_id:execution.stage_attempt_id,work_unit_id:execution.work_unit_id,step_status:'failed',verification_result:'failed',planning_revision_plan:{summary:{invalid:true}}},null,2)+'\n');
task.stage_attempt_history=[...(task.stage_attempt_history||[]),{stage_id:task.current_stage,stage_attempt_id:execution.stage_attempt_id,work_unit_id:execution.work_unit_id,status:'completed',expected_result_packet:packet,accepted_result_packet:packet}];
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/master-review-accepted-packet-protected.json"
    node - "$TMP_DIR/master-review-accepted-packet-protected.json" "$book" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),out=require(process.argv[2]),root=process.argv[3],task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
assert.equal(out.status,'stage_execution_resume_ready');
assert.equal(fs.existsSync(path.join(root,task.stage_execution.expected_result_packet)),true);
NODE
}

@test "same attempt can retire multiple different invalid packets into immutable versioned archives" {
    local book="$TMP_DIR/chapter-brief-repeated-invalid"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null
    local workflow_id
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"

    local first_archive=""
    for marker in first second; do
        node - "$book" "$marker" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],marker=process.argv[3],task=fixture.readFocusedTask(root),execution=task.stage_execution,packet=execution.expected_result_packet;
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),JSON.stringify({
  workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:execution.stage_id,
  stage_attempt_id:execution.stage_attempt_id,work_unit_id:execution.work_unit_id,
  step_status:'completed',marker,
  memory_read_receipt:{contract_digest:`sha256:${marker}`,memory_revision:`sha256:${marker}`,packet_digest:`sha256:${marker}`},
},null,2)+'\n');
NODE
        node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/repeated-invalid-$marker-next.json"
        node - "$TMP_DIR/repeated-invalid-$marker-next.json" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]);
assert.equal(out.status,'stage_result_contract_recovery_ready');
NODE
        node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:repeated-invalid --json > "$TMP_DIR/repeated-invalid-$marker-reconcile.json"
        if [ "$marker" = first ]; then
            first_archive="$(node -e "process.stdout.write(require(process.argv[1]).stale_stage_result_retired.accepted_result_packet)" "$TMP_DIR/repeated-invalid-$marker-reconcile.json")"
        fi
    done

    node - "$book" "$first_archive" "$TMP_DIR/repeated-invalid-second-reconcile.json" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),root=process.argv[2],first=process.argv[3],secondOut=require(process.argv[4]),second=secondOut.stale_stage_result_retired.accepted_result_packet;
assert.notEqual(first,second);
for(const rel of [first,second]) {
  assert.equal(fs.existsSync(path.join(root,rel)),true,rel);
  assert.equal(fs.existsSync(path.join(root,`${rel}.manifest.json`)),true,`${rel}.manifest.json`);
}
assert.equal(JSON.parse(fs.readFileSync(path.join(root,first),'utf8')).marker,'first');
assert.equal(JSON.parse(fs.readFileSync(path.join(root,second),'utf8')).marker,'second');
NODE
}

@test "malformed or identity-less current packet is conservatively recoverable" {
    for variant in malformed identityless; do
        local book="$TMP_DIR/chapter-brief-$variant"
        prepare_detail_outline_review "$book"
        apply_detail_outline_quality_result "$book" pass >/dev/null
        local workflow_id
        workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
        node - "$book" "$variant" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],variant=process.argv[3],task=fixture.readFocusedTask(root),packet=task.stage_execution.expected_result_packet;
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),variant==='malformed'?'{"workflow_id":':JSON.stringify({step_status:'completed'},null,2)+'\n');
NODE
        node "$SCRIPT" next-candidates --project-root "$book" --compact --json > "$TMP_DIR/$variant-next.json"
        node - "$TMP_DIR/$variant-next.json" <<'NODE'
const assert=require('assert'),out=require(process.argv[2]);
assert.equal(out.status,'stage_result_contract_recovery_ready');
NODE
        node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id "test:$variant" --json > "$TMP_DIR/$variant-reconcile.json" || { cat "$TMP_DIR/$variant-reconcile.json"; false; }
        node - "$book" "$TMP_DIR/$variant-reconcile.json" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),root=process.argv[2],out=require(process.argv[3]),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
assert.equal(out.status,'runtime_reconciled');
assert.equal(out.stale_stage_result_retired.status,'invalid_stage_result_contract_retired');
assert.equal(fs.existsSync(path.join(root,task.stage_execution.expected_result_packet)),false);
assert.equal(fs.existsSync(path.join(root,out.stale_stage_result_retired.accepted_result_packet)),true);
NODE
    done
}

@test "explicit foreign packet identity fails closed and is never archived" {
    local book="$TMP_DIR/chapter-brief-foreign-identity"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null
    for field in workflow_id workflow_type stage_id stage_attempt_id work_unit_id; do
        node - "$book" "$field" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],field=process.argv[3],task=fixture.readFocusedTask(root),execution=task.stage_execution,packet=execution.expected_result_packet;
const body={workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:execution.stage_id,stage_attempt_id:execution.stage_attempt_id,work_unit_id:execution.work_unit_id,step_status:'completed'};
body[field]=`foreign-${field}`;
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});fs.writeFileSync(path.join(root,packet),JSON.stringify(body,null,2)+'\n');
NODE
        run node "$SCRIPT" next-candidates --project-root "$book" --compact --json
        [ "$status" -eq 2 ] || { echo "$field: $output"; false; }
        [[ "$output" == *'blocked_invalid_stage_result_identity_mismatch'* ]]
        node - "$book" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]);
assert.equal(fs.existsSync(path.join(process.argv[2],task.stage_execution.expected_result_packet)),true);
NODE
    done
}

@test "invalid packet retirement rolls back archive and task when manifest persistence fails" {
    local book="$TMP_DIR/chapter-brief-manifest-rollback"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null
    local workflow_id
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"
    node - "$book" "$TMP_DIR/manifest-rollback-baseline.json" <<'NODE'
const fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],baseline=process.argv[3],file=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root),execution=task.stage_execution,packet=execution.expected_result_packet;
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),'{"workflow_id":');
fs.writeFileSync(baseline,JSON.stringify({task_text:fs.readFileSync(file,'utf8'),packet_text:fs.readFileSync(path.join(root,packet),'utf8'),packet}));
NODE

    run env NOVEL_ASSISTANT_TEST_FAIL_RESULT_ARCHIVE_MANIFEST=1 node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:manifest-rollback --json
    [ "$status" -eq 2 ] || { echo "$output"; false; }
    [[ "$output" == *'blocked_runtime_reconcile_archive_failed'* ]]
    node - "$book" "$TMP_DIR/manifest-rollback-baseline.json" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],baseline=require(process.argv[3]),file=fixture.focusedTaskFile(root);
assert.equal(fs.readFileSync(file,'utf8'),baseline.task_text);
assert.equal(fs.readFileSync(path.join(root,baseline.packet),'utf8'),baseline.packet_text);
const archiveRoot=path.join(root,fixture.readFocusedTask(root).task_dir,'audit/archive/stage-result-invalid');
const files=fs.existsSync(archiveRoot)?fs.readdirSync(archiveRoot,{recursive:true}).filter((name)=>fs.statSync(path.join(archiveRoot,name)).isFile()):[];
assert.deepEqual(files,[]);
NODE
}

@test "compact running execution retains bounded blocker summaries" {
    run node - "$REPO/scripts/lib/state-machine-shared.js" <<'NODE'
const assert=require('assert'),{compactRunningStageExecutionForHost}=require(process.argv[2]);
const huge='x'.repeat(10000);
const out=compactRunningStageExecutionForHost({
  status:'running',stage_id:'chapter_brief',context_packet_warning:'legacy warning',
  context_packet_blocking:{status:'blocked_legacy_context',blocking:true,reason:'missing trusted outline',missing_fields:['review_targets'],huge},
  character_contract_blocking:{status:'blocked_long_character_contract_upgrade_required',blocking:true,reason:'missing character contract',resume_stage:'story_bible',findings:[{field:'goal'}],huge},
});
assert.equal(out.context_packet_warning,'legacy warning');
assert.deepEqual(out.context_packet_blocking,{status:'blocked_legacy_context',blocking:true,reason:'missing trusted outline',missing_fields:['review_targets']});
assert.deepEqual(out.character_contract_blocking,{status:'blocked_long_character_contract_upgrade_required',blocking:true,reason:'missing character contract',resume_stage:'story_bible',findings:[{field:'goal'}]});
assert.ok(Buffer.byteLength(JSON.stringify(out))<2048);
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "legacy running execution with a context blocker fails closed instead of resuming" {
    local book="$TMP_DIR/legacy-running-context-blocked"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
task.stage_execution.context_packet_warning='旧项目上下文缺少可信细纲。';
task.stage_execution.context_packet_blocking={status:'blocked_legacy_context',blocking:true,reason:'旧项目上下文缺少可信细纲。',missing_fields:['review_targets']};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    run node "$SCRIPT" next-candidates --project-root "$book" --compact --json
    [ "$status" -eq 2 ] || { echo "$output"; false; }
    [[ "$output" == *'blocked_stage_execution_context'* ]]
    [[ "$output" == *'旧项目上下文缺少可信细纲'* ]]
}

@test "detail outline quality CLI writes an applyable long write result packet" {
    book="$TMP_DIR/detail-quality-cli"
    node - "$SCRIPT" "$REPO/scripts/detail-outline-quality-check.js" "$book" <<'NODE'
const crypto=require('crypto'), fs=require('fs'), path=require('path'), cp=require('child_process');
const [script,check,root]=process.argv.slice(2);
const schemaDir=path.join(root,'追踪/schema');
fs.mkdirSync(schemaDir,{recursive:true});
fs.writeFileSync(path.join(schemaDir,'chapters.jsonl'),JSON.stringify({chapterId:'第001章',chapterNo:1,volume:'第1卷',volumeChapterNo:1,globalDraftOrder:1,outlinePath:'大纲/第1卷/细纲_第001章.md',contractPath:'追踪/章节契约/第1卷/第001章.md',draftPath:'正文/第1卷/第001章.md'})+'\n');
cp.execFileSync(process.execPath,[script,'create','--workflow-type','long_write','--project-root',root,'--user-goal','开一本新书','--json']);
const advance=(declaredFiles=[])=>{
  const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
  if(!task.stage_execution || task.stage_execution.status!=='running') {
    const pending=task.pending_action;
    cp.execFileSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',pending.id,'--visible-choice-hash',pending.visible_choice_hash,'--state-version',String(task.state_version),'--book-root',root,'--json']);
  }
  const active=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
  let effectiveDeclaredFiles=declaredFiles.slice();
  if(active.current_stage==='story_bible'&&!effectiveDeclaredFiles.length){
    const bible='设定/故事圣经.md';
    const target=path.join(root,bible);
    fs.mkdirSync(path.dirname(target),{recursive:true});
    fs.writeFileSync(target,`# 主角：林川\n身份：二十二岁调查员。\n外部目标：查清失踪案。\n内在渴望：害怕失去家人。\n缺陷：误信权威。\n能力边界：不懂金融，越权会付出停职代价。\n第一卷成长里程碑：从独断到协作。\n\n# 主要对手：赵衡\n目标：为了保住集团控制权。\n资源：拥有权限、人脉和渠道。\n边界与代价：不能公开杀人，失败会失去董事会。\n升级路径：从试探、施压到断供。\n\n# 关键配角：周宁\n目标：争取公开真相。\n行动边界：不能牺牲证人。\n\n# 人物关系与责任债\n林川欠周宁救命责任，赵衡利用他的家人软肋。\n\n# 成长里程碑\n第一卷完成人物变化；终局主动选择公开证据并承担代价。\n`);
    effectiveDeclaredFiles=[bible];
  }
  const node=(active.lifecycle_graph.nodes||[]).find(item=>item.id===active.current_stage);
  const packet=path.join(root,active.stage_execution.expected_result_packet);
  const result={workflow_id:active.workflow_id,workflow_type:'long_write',stage_id:active.current_stage,step_id:active.current_step,owner_module:node.owner_module,lifecycle_node:node.id,asset_target:node.asset_target,review_requirement:node.review_requirement,step_status:'completed',outputs:[],changed_files:effectiveDeclaredFiles,evidence:[],verification_result:'pass',checkpoint_state:{stage_id:active.current_stage},output_health_result:'pass',asset_revision:{status:'verified',asset_id:node.asset_target.id},review_decision:node.review_requirement.required?'accepted':'not_applicable',downstream_effects:[],lifecycle_transition_request:{action:'advance',target:node.id},result_write_set:effectiveDeclaredFiles};
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

@test "batch detail outline CLI revise packet applies as a scoped negative review" {
    book="$TMP_DIR/detail-quality-batch-revise"
    prepare_detail_outline_review "$book"

    node - "$book" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
for(const chapter of [1,2,3]) {
  const rel=`大纲/第1卷/细纲_第${String(chapter).padStart(3,'0')}章.md`,file=path.join(root,rel);
  fs.writeFileSync(file,'# 过渡章\n- 核心事件：值班员保存记录并继续核查。\n- 目标情绪：疑虑转为主动。\n#### 情节安排\n1. 值班员保存截图，因此确认编号异常。\n2. 他拨打电话，却拿到需要继续检查的新地址。\n#### 呈现与连续性\n- 可见证据：巡检记录。\n- 前置承接：承接上一章异常。\n- 本章变化：从怀疑转为主动核查。\n- 后续债务：地址主人尚未现身。\n');
}
fs.writeFileSync(path.join(root,'大纲/第1卷/卷纲.md'),'# 第1卷卷纲\n第002章必须让反击产生可见后果。\n');
task.stage_execution.write_snapshot.files['大纲/第1卷/卷纲.md']=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'大纲/第1卷/卷纲.md'))).digest('hex')}`;
for(const chapter of [2,3]) fs.appendFileSync(path.join(root,`大纲/第1卷/细纲_第${String(chapter).padStart(3,'0')}章.md`),'\n#### 质量触发\n- 激活标签：爽点兑现\n');
const targets=[1,2,3].map((chapter)=>{const outline_path=`大纲/第1卷/细纲_第${String(chapter).padStart(3,'0')}章.md`,file=path.join(root,outline_path);return {outline_path,outline_sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')};});
task.detail_outline_review_targets=targets;task.stage_execution.review_targets=targets;
for(const target of targets) task.stage_execution.write_snapshot.files[target.outline_path]=`sha256:${target.outline_sha256}`;
fs.writeFileSync(taskFile,JSON.stringify(task,null,2));
NODE

    node - "$SCRIPT" "$REPO/scripts/detail-outline-quality-check.js" "$book" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),cp=require('child_process');
const [script,check,root]=process.argv.slice(2),task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root),args=['--project-root',root];
for(const chapter of [1,2,3]) {
  const outline=`大纲/第1卷/细纲_第${String(chapter).padStart(3,'0')}章.md`,file=path.join(root,outline),hash=crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const semantic=`追踪/workflow/tasks/${task.workflow_id}/work/detail-outline-semantic-review-${chapter}.json`,semanticFile=path.join(root,semantic);
  fs.mkdirSync(path.dirname(semanticFile),{recursive:true});
  const findings=[2,3].includes(chapter)?[{dimension:'C7_payoff_debt',severity:'blocking',message:'兑现没有产生可见后果'}]:[];
  fs.writeFileSync(semanticFile,JSON.stringify({outline_path:outline,outline_sha256:hash,reviewer:'main-session',findings}));
  args.push('--outline',outline,'--semantic-review',semantic);
}
args.push('--workflow-id',task.workflow_id,'--write-result',task.stage_execution.expected_result_packet,'--json');
const quality=cp.spawnSync(process.execPath,[check,...args],{encoding:'utf8'});
if(quality.status!==2) throw new Error(quality.stderr||quality.stdout);
const packet=JSON.parse(quality.stdout);
if(packet.step_status!=='completed'||packet.verification_result!=='revise'||packet.review_decision!=='revise'||packet.outputs.detail_outline_quality.status!=='revise') throw new Error(JSON.stringify(packet));
if(packet.lifecycle_transition_request.action!=='return'||packet.lifecycle_transition_request.target!=='stage_detail_outline') throw new Error(JSON.stringify(packet.lifecycle_transition_request));
const applied=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',path.join(root,task.stage_execution.expected_result_packet),'--json'],{encoding:'utf8'});
if(applied.status!==0) throw new Error(applied.stderr||applied.stdout);
const out=JSON.parse(applied.stdout),failure=out.task.detail_outline_review_failure||{};
if(out.task.current_stage!=='stage_detail_outline'||out.task.machine.completed_stages.includes('detail_outline_review')) throw new Error(JSON.stringify(out));
if(JSON.stringify(failure.failed_targets)!==JSON.stringify(['大纲/第1卷/细纲_第002章.md','大纲/第1卷/细纲_第003章.md'])) throw new Error(JSON.stringify(failure));
if(out.task.stage_execution) throw new Error(`review failure must stop before canonical revision: ${JSON.stringify(out.task.stage_execution)}`);
const pending=out.task.pending_action||{};
if(!Array.isArray(pending.options)||pending.options.length<2||pending.free_text_enabled!==true) throw new Error(`review failure must expose an author decision menu: ${JSON.stringify(pending)}`);
if(JSON.stringify((out.visible_response||{}).failed_targets)!==JSON.stringify(failure.failed_targets)) throw new Error(JSON.stringify(out.visible_response));
const started=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',String(pending.id||''),'--visible-choice-hash',String(pending.visible_choice_hash||''),'--state-version',String(out.task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
if(started.status!==0) throw new Error(started.stderr||started.stdout);
const confirmed=JSON.parse(started.stdout),execution=confirmed.stage_execution||{};
if(!Array.isArray(execution.planning_targets)||execution.planning_targets.length===0) throw new Error(JSON.stringify({confirmed,execution,failure}));
const stagedTargets=execution.planning_targets.map((item)=>item.staged);
if(JSON.stringify(execution.write_set)!==JSON.stringify(stagedTargets)||JSON.stringify((execution.write_snapshot||{}).authorized_write_set)!==JSON.stringify(stagedTargets)) throw new Error(JSON.stringify({execution,failure}));
if(((execution.stage_context_packet||{}).status)!=='assembled'||execution.stage_context_packet.revision_target_count!==2||!String(execution.resume_hint||'').includes('2 个暂存细纲')||!String(execution.resume_hint||'').includes('完成后逐字运行 execution_command')) throw new Error(JSON.stringify(execution));
// Task 1: longform planning revisions expose exact staged candidates plus an
// exact frozen canonical target set, and point at the planning finalizer. The
// host never writes formal outlines directly.
if(JSON.stringify(execution.canonical_write_set||[])!==JSON.stringify(failure.failed_targets)) throw new Error(JSON.stringify({canonical_write_set:execution.canonical_write_set,failure}));
if(String(execution.planning_stage_attempt_id||'')!==String(execution.stage_attempt_id||'')) throw new Error(JSON.stringify({planning_stage_attempt_id:execution.planning_stage_attempt_id,stage_attempt_id:execution.stage_attempt_id}));
if(!Array.isArray(execution.planning_targets)||execution.planning_targets.length!==failure.failed_targets.length) throw new Error(JSON.stringify({planning_targets:execution.planning_targets,failure}));
const expectedStaged=execution.planning_targets.map((item)=>item.staged);
if(JSON.stringify(execution.write_set||[])!==JSON.stringify(expectedStaged)) throw new Error(JSON.stringify({write_set:execution.write_set,expectedStaged}));
if(JSON.stringify((execution.write_snapshot||{}).authorized_write_set||[])!==JSON.stringify(expectedStaged)) throw new Error(JSON.stringify({authorized_write_set:(execution.write_snapshot||{}).authorized_write_set,expectedStaged}));
for(const item of execution.planning_targets) {
  if(String(item.canonical||'')!==String(failure.failed_targets[execution.planning_targets.indexOf(item)]||'')) throw new Error(JSON.stringify({planning_target_canonical:item,failure}));
  if(!String(item.staged||'').startsWith('追踪/workflow/staging/')) throw new Error(JSON.stringify({staged:item.staged}));
  if(!String(item.staged||'').endsWith(String(path.posix.basename(item.canonical)||''))) throw new Error(JSON.stringify({staged:item.staged,canonical:item.canonical}));
  const stagedFile=path.join(root,item.staged);
  if(!fs.existsSync(stagedFile)||!fs.statSync(stagedFile).isFile()) throw new Error(`staged candidate not seeded: ${item.staged}`);
  const canonicalFile=path.join(root,item.canonical);
  if(!fs.existsSync(canonicalFile)) throw new Error(`canonical missing: ${item.canonical}`);
  if(fs.readFileSync(stagedFile,'utf8')!==fs.readFileSync(canonicalFile,'utf8')) throw new Error(`staged candidate not seeded from canonical: ${item.staged}`);
}
if(!/long-planning-stage-finalize\.js/.test(String(execution.execution_command||''))) throw new Error(JSON.stringify({execution_command:execution.execution_command}));

const fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),legacy=JSON.parse(fs.readFileSync(taskFile,'utf8'));
// Task 3: legacy pre-fix running attempt had broad direct canonical write_set
// and no staged/canonical pair contract.
const preservedCandidates=new Map(execution.planning_targets.map((item,index)=>[item.canonical,`保持第${index+1}份已经写好的暂存修订，不得在 reconcile 时被正式稿覆盖。\n`]));
for(const item of execution.planning_targets) fs.writeFileSync(path.join(root,item.staged),preservedCandidates.get(item.canonical));
legacy.stage_execution.write_set=['大纲/**','追踪/**'];
legacy.stage_execution.revision_targets=[];
delete legacy.stage_execution.planning_targets;
delete legacy.stage_execution.canonical_write_set;
delete legacy.stage_execution.execution_command;
legacy.stage_execution.write_snapshot.authorized_write_set=['大纲/**','追踪/**'];
fs.writeFileSync(taskFile,JSON.stringify(legacy,null,2));
const holder=String(((((legacy.runtime_guard||{}).session_lease)||{}).holder_id)||'test:detail-reconcile');
const reconciled=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',legacy.workflow_id,'--session-id',holder,'--json'],{encoding:'utf8'});
if(reconciled.status!==0) throw new Error(reconciled.stderr||reconciled.stdout);
const repair=JSON.parse(reconciled.stdout),repaired=fixture.readFocusedTask(root),repairedExecution=repaired.stage_execution||{};
if(repair.detail_outline_revision_scope_repaired!==true) throw new Error(JSON.stringify({repair,repairedExecution}));
if(JSON.stringify(repairedExecution.canonical_write_set||[])!==JSON.stringify(failure.failed_targets)) throw new Error(JSON.stringify({canonical_write_set:repairedExecution.canonical_write_set,failure}));
const repairedStaged=(repairedExecution.planning_targets||[]).map((item)=>String(item.staged||''));
if(JSON.stringify(repairedExecution.write_set||[])!==JSON.stringify(repairedStaged)) throw new Error(JSON.stringify({write_set:repairedExecution.write_set,repairedStaged}));
if(JSON.stringify(repairedExecution.revision_targets||[])!==JSON.stringify(failure.failed_targets)) throw new Error(JSON.stringify({revision_targets:repairedExecution.revision_targets,failure}));
for(const item of (repairedExecution.planning_targets||[])) {
  const stagedFile=path.join(root,String(item.staged||'')),canonicalFile=path.join(root,String(item.canonical||''));
  if(!fs.existsSync(stagedFile)||!fs.existsSync(canonicalFile)) throw new Error(`repaired staged/canonical missing: ${item.staged}`);
  if(fs.readFileSync(stagedFile,'utf8')!==preservedCandidates.get(item.canonical)) throw new Error(`reconcile overwrote an existing staged candidate: ${item.staged}`);
}
if(!/long-planning-stage-finalize\.js/.test(String(repairedExecution.execution_command||''))) throw new Error(JSON.stringify({execution_command:repairedExecution.execution_command}));
// No canonical outline hash changes during reconciliation (recovery only).
if(((repairedExecution.stage_context_packet||{}).status)!=='assembled'||repairedExecution.stage_context_packet.revision_target_count!==2) throw new Error(JSON.stringify(repairedExecution));

const pairs=repairedExecution.planning_targets,revisedByCanonical=new Map(pairs.map((item,index)=>[item.canonical,`# 修订后细纲 ${index+1}\n反击已经产生可见后果，并留下下一章责任债。\n`]));
for(const item of pairs) fs.writeFileSync(path.join(root,item.staged),revisedByCanonical.get(item.canonical));
const finalizer=path.join(path.dirname(script),'long-planning-stage-finalize.js');
const canonicalBefore=new Map(pairs.map((item)=>[item.canonical,fs.readFileSync(path.join(root,item.canonical),'utf8')]));
const runFailureCase=(name,mutate,expectedStatus,extraEnv={})=>{
  const clone=`${root}-${name}`;
  fs.cpSync(root,clone,{recursive:true});
  const cloneTaskFile=fixture.focusedTaskFile(clone),cloneTask=JSON.parse(fs.readFileSync(cloneTaskFile,'utf8'));
  mutate(clone,cloneTask);
  fs.writeFileSync(cloneTaskFile,JSON.stringify(cloneTask,null,2));
  const result=cp.spawnSync(process.execPath,[finalizer,'--project-root',clone,'--workflow-id',cloneTask.workflow_id,'--apply','--json'],{encoding:'utf8',env:{...process.env,...extraEnv}});
  const payload=JSON.parse(result.stdout||'{}');
  if(result.status!==2||payload.status!==expectedStatus) throw new Error(JSON.stringify({name,status:result.status,payload,stderr:result.stderr}));
  for(const item of pairs) if(fs.readFileSync(path.join(clone,item.canonical),'utf8')!==canonicalBefore.get(item.canonical)) throw new Error(`${name} changed canonical output: ${item.canonical}`);
};
runFailureCase('missing-staged',(clone,task)=>{fs.rmSync(path.join(clone,task.stage_execution.planning_targets[0].staged));},'long_planning_staged_artifact_missing');
runFailureCase('symlink-staged',(clone,task)=>{const item=task.stage_execution.planning_targets[0],stagedFile=path.join(clone,item.staged);fs.rmSync(stagedFile);fs.symlinkSync(path.join(clone,item.canonical),stagedFile);},'long_planning_staged_artifact_missing');
runFailureCase('outside-target',(_clone,task)=>{task.stage_execution.planning_targets[0].canonical='../outside.md';task.stage_execution.canonical_write_set=['../outside.md'];task.stage_execution.revision_targets=['../outside.md'];task.detail_outline_review_failure.failed_targets=['../outside.md'];},'long_planning_target_mapping_invalid');
runFailureCase('duplicate-target',(_clone,task)=>{const item={...task.stage_execution.planning_targets[0]};task.stage_execution.planning_targets=[item,{...item}];task.stage_execution.write_set=[item.staged,item.staged];task.stage_execution.canonical_write_set=[item.canonical,item.canonical];task.stage_execution.revision_targets=[item.canonical,item.canonical];task.detail_outline_review_failure.failed_targets=[item.canonical,item.canonical];},'long_planning_target_mapping_invalid');
runFailureCase('stale-attempt',(_clone,task)=>{task.stage_execution.planning_stage_attempt_id='sa-stale-attempt';},'long_planning_stage_attempt_mismatch');
runFailureCase('commit-rollback',()=>{},'long_planning_commit_failed',{NOVEL_ASSISTANT_TEST_FAIL_AFTER_WRITES:'1'});

// If the canonical transaction succeeds but workflow apply is blocked by an
// unrelated file-diff violation, rerunning after that violation is removed
// must reuse the accepted commit and finish the same stage. This is the
// durable recovery path for old projects; it must not reject the now-equal
// staged/canonical pair as an unchanged candidate or create a second commit.
const recoveryRoot=`${root}-accepted-commit-recovery`;
fs.cpSync(root,recoveryRoot,{recursive:true});
const recoveryTask=fixture.readFocusedTask(recoveryRoot);
const unauthorizedFile=path.join(recoveryRoot,'正文/越权.md');
fs.mkdirSync(path.dirname(unauthorizedFile),{recursive:true});
fs.writeFileSync(unauthorizedFile,'runtime apply 前的无关越权变更\n');
const firstRecoveryRun=cp.spawnSync(process.execPath,[finalizer,'--project-root',recoveryRoot,'--workflow-id',recoveryTask.workflow_id,'--apply','--json'],{encoding:'utf8'});
const firstRecoveryPayload=JSON.parse(firstRecoveryRun.stdout||'{}');
if(firstRecoveryRun.status!==2||firstRecoveryPayload.status!=='long_planning_apply_blocked') throw new Error(JSON.stringify({firstRecoveryStatus:firstRecoveryRun.status,firstRecoveryPayload,stderr:firstRecoveryRun.stderr}));
const recoveryCommitsDir=path.join(recoveryRoot,'追踪/story-system/commits');
const planningCommitCount=()=>fs.readdirSync(recoveryCommitsDir).filter((name)=>name.endsWith('.json')).map((name)=>JSON.parse(fs.readFileSync(path.join(recoveryCommitsDir,name),'utf8'))).filter((commit)=>commit.volume==='长篇规划').length;
const recoveryCommitCountBefore=planningCommitCount();
for(const item of pairs) if(fs.readFileSync(path.join(recoveryRoot,item.canonical),'utf8')!==revisedByCanonical.get(item.canonical)) throw new Error(`accepted transaction did not update canonical target before recovery: ${item.canonical}`);
fs.rmSync(unauthorizedFile);
const secondRecoveryRun=cp.spawnSync(process.execPath,[finalizer,'--project-root',recoveryRoot,'--workflow-id',recoveryTask.workflow_id,'--apply','--json'],{encoding:'utf8'});
const secondRecoveryPayload=JSON.parse(secondRecoveryRun.stdout||'{}');
const recoveredTask=fixture.readFocusedTask(recoveryRoot);
const recoveryCommitCountAfter=planningCommitCount();
if(secondRecoveryRun.status!==0||secondRecoveryPayload.status!=='long_planning_applied'||secondRecoveryPayload.reused_accepted_commit!==true||recoveredTask.current_stage!=='detail_outline_review'||recoveryCommitCountAfter!==recoveryCommitCountBefore) throw new Error(JSON.stringify({secondRecoveryStatus:secondRecoveryRun.status,secondRecoveryPayload,currentStage:recoveredTask.current_stage,recoveryCommitCountBefore,recoveryCommitCountAfter,stderr:secondRecoveryRun.stderr}));

const runnerRel=`${repaired.task_dir}/runner-packets/stage_detail_outline.attempt-managed.run.json`;
const runnerFile=path.join(root,runnerRel);
fs.mkdirSync(path.dirname(runnerFile),{recursive:true});
fs.writeFileSync(runnerFile,JSON.stringify({workflow_id:repaired.workflow_id,stage_id:'stage_detail_outline',stage_attempt_id:repairedExecution.stage_attempt_id,work_unit_id:repairedExecution.work_unit_id,run_id:'run-detail-planning-managed',expected_result_packet:repairedExecution.expected_result_packet,stage_contract:{write_set:repairedExecution.write_set,canonical_write_set:repairedExecution.canonical_write_set}}));
repaired.runtime_guard.last_runner_attempt={stage_id:'stage_detail_outline',stage_attempt_id:repairedExecution.stage_attempt_id,work_unit_id:repairedExecution.work_unit_id,run_id:'run-detail-planning-managed',expected_result_packet:repairedExecution.expected_result_packet,runner_packet_path:runnerRel};
fs.writeFileSync(taskFile,JSON.stringify(repaired,null,2));
const finalized=cp.spawnSync(process.execPath,[finalizer,'--project-root',root,'--workflow-id',repaired.workflow_id,'--apply','--json'],{encoding:'utf8'});
if(finalized.status!==0) throw new Error(finalized.stderr||finalized.stdout);
const finalOutput=JSON.parse(finalized.stdout);
if(finalOutput.status!=='long_planning_result_ready') throw new Error(JSON.stringify(finalOutput));
const managedApplied=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--workflow-id',repaired.workflow_id,'--result',path.join(root,repairedExecution.expected_result_packet),'--json'],{encoding:'utf8'});
if(managedApplied.status!==0) throw new Error(managedApplied.stderr||managedApplied.stdout);
const advanced=fixture.readFocusedTask(root);
if(advanced.current_stage!=='detail_outline_review') throw new Error(JSON.stringify({managedApplied:managedApplied.stdout,stage:advanced.current_stage}));
for(const item of pairs) if(fs.readFileSync(path.join(root,item.canonical),'utf8')!==revisedByCanonical.get(item.canonical)) throw new Error(`canonical detail outline was not atomically updated: ${item.canonical}`);
const acceptedPacketPath=String(((advanced.result_history||{}).path)||((advanced.stage_execution||{}).accepted_result_packet)||((advanced.stage_execution||{}).result_packet)||'');
if(!acceptedPacketPath||!fs.existsSync(path.join(root,acceptedPacketPath))) throw new Error(JSON.stringify({result_history:advanced.result_history,stage_execution:advanced.stage_execution}));
const acceptedPacket=JSON.parse(fs.readFileSync(path.join(root,acceptedPacketPath),'utf8'));
const canonicalTargets=pairs.map((item)=>item.canonical);
if(JSON.stringify(acceptedPacket.changed_files)!==JSON.stringify(canonicalTargets)||JSON.stringify(acceptedPacket.result_write_set)!==JSON.stringify(canonicalTargets)) throw new Error(JSON.stringify(acceptedPacket));
if(!acceptedPacket.chapter_commit||!acceptedPacket.chapter_commit.accepted_commit_id) throw new Error(JSON.stringify(acceptedPacket.chapter_commit));
const commitsDir=path.join(root,'追踪/story-system/commits'),commitCountBefore=fs.readdirSync(commitsDir).filter((name)=>name.endsWith('.json')).length;
const replay=cp.spawnSync(process.execPath,[finalizer,'--project-root',root,'--workflow-id',repaired.workflow_id,'--apply','--json'],{encoding:'utf8'}),replayPayload=JSON.parse(replay.stdout||'{}');
const commitCountAfter=fs.readdirSync(commitsDir).filter((name)=>name.endsWith('.json')).length;
if(replay.status!==0||replayPayload.status!=='long_planning_already_applied'||commitCountAfter!==commitCountBefore) throw new Error(JSON.stringify({replayStatus:replay.status,replayPayload,commitCountBefore,commitCountAfter}));

// Starting a new attempt of the same review stage must retire the fixed-path
// packet from the accepted previous attempt. Otherwise the canonical write
// guard correctly refuses to overwrite it and the workflow deadlocks.
const beforeRetry=fixture.readFocusedTask(root),retryPending=beforeRetry.pending_action||{};
const staleReviewPacket=path.join(root,beforeRetry.task_dir,'result-packets/detail_outline_review.result.json');
if(!fs.existsSync(staleReviewPacket)) throw new Error('expected prior accepted review packet before retry');
const retryStart=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',String(retryPending.id||''),'--visible-choice-hash',String(retryPending.visible_choice_hash||''),'--state-version',String(beforeRetry.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
if(retryStart.status!==0) throw new Error(retryStart.stderr||retryStart.stdout);
const retryTask=fixture.readFocusedTask(root),archivedReviewAttempt=(retryTask.stage_attempt_history||[]).slice().reverse().find((item)=>item.stage_id==='detail_outline_review'&&(item.accepted_result_packet||item.failed_result_packet));
const archivedReviewPacket=String((archivedReviewAttempt||{}).accepted_result_packet||(archivedReviewAttempt||{}).failed_result_packet||'');
if(retryTask.current_stage!=='detail_outline_review'||(retryTask.stage_execution||{}).status!=='running'||fs.existsSync(staleReviewPacket)||!archivedReviewAttempt||!archivedReviewPacket||archivedReviewPacket===path.relative(root,staleReviewPacket)||!fs.existsSync(path.join(root,archivedReviewPacket))) throw new Error(JSON.stringify({retryTaskStage:retryTask.current_stage,retryExecution:retryTask.stage_execution,staleExists:fs.existsSync(staleReviewPacket),archivedReviewAttempt,archivedReviewPacket}));
NODE
}

@test "detail outline quality revise returns to outline and invalidates downstream nodes" {
    book="$TMP_DIR/detail-quality-revise"
    prepare_detail_outline_review "$book"
    run apply_detail_outline_quality_result "$book" revise
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" > "$TMP_DIR/detail-quality-revise.json"

    node - "$TMP_DIR/detail-quality-revise.json" "$book" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.task;
if(task.current_stage!=='stage_detail_outline') throw new Error(JSON.stringify(out));
if(task.machine.last_transition!=='review_failed_return_to_asset') throw new Error(JSON.stringify(task.machine));
if(!task.lifecycle_graph.invalidated_nodes.includes('stage_detail_outline')) throw new Error(JSON.stringify(task.lifecycle_graph));
if(task.machine.completed_stages.includes('stage_detail_outline')) throw new Error(JSON.stringify(task.machine));
if(task.machine.completed_stages.includes('detail_outline_review')) throw new Error(JSON.stringify(task.machine));
if(task.stage_execution) throw new Error(`review failure must stop before canonical revision: ${JSON.stringify(task.stage_execution)}`);
if(!task.pending_action||!Array.isArray(task.pending_action.options)||task.pending_action.options.length<2||task.pending_action.free_text_enabled!==true) throw new Error(`review failure must expose an author decision menu: ${JSON.stringify(task.pending_action)}`);
const failedAttempt=(task.stage_attempt_history||[]).find((item)=>item.stage_id==='detail_outline_review');
if(!failedAttempt||failedAttempt.accepted_result_packet||!failedAttempt.failed_result_packet) throw new Error(JSON.stringify(task.stage_attempt_history));
if(String((((task.runtime_guard||{}).heartbeat||{}).latest_trusted_artifact)||'')===failedAttempt.failed_result_packet) throw new Error(JSON.stringify(task.runtime_guard));
if(!fs.existsSync(require('path').join(process.argv[3],failedAttempt.failed_result_packet))) throw new Error(JSON.stringify(failedAttempt));
NODE
}

@test "detail outline quality identity missing fails before result acceptance" {
    book="$TMP_DIR/detail-quality-identity-missing"
    prepare_detail_outline_review "$book"
    run apply_detail_outline_quality_result "$book" identity_missing
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_detail_outline_quality_identity_missing'* ]]

    node - "$book" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]);
if(task.current_stage!=='detail_outline_review') throw new Error(JSON.stringify(task));
if((task.stage_execution||{}).status!=='running') throw new Error(JSON.stringify(task.stage_execution));
if(task.machine.completed_stages.includes('detail_outline_review')) throw new Error(JSON.stringify(task.machine));
NODE
}

@test "detail outline quality evidence identity mismatch fails before result acceptance" {
    book="$TMP_DIR/detail-quality-identity-mismatch"
    prepare_detail_outline_review "$book"
    run apply_detail_outline_quality_result "$book" pass "" evidence_mismatch
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_detail_outline_quality_identity_missing'* ]]

    node - "$book" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]);
if(task.current_stage!=='detail_outline_review') throw new Error(JSON.stringify(task));
if((task.stage_execution||{}).status!=='running') throw new Error(JSON.stringify(task.stage_execution));
if(task.machine.completed_stages.includes('detail_outline_review')) throw new Error(JSON.stringify(task.machine));
NODE
}

@test "outline underfilled packet with nonempty contract projection fails before result acceptance" {
    book="$TMP_DIR/detail-quality-underfilled-projection"
    prepare_detail_outline_review "$book"
    run apply_detail_outline_quality_result "$book" outline_underfilled nonempty
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_detail_outline_underfilled_projection_forbidden'* ]]

    node - "$book" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]);
if(task.current_stage!=='detail_outline_review') throw new Error(JSON.stringify(task));
if((task.stage_execution||{}).status!=='running') throw new Error(JSON.stringify(task.stage_execution));
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
const task = { workflow_type: 'long_write', workflow_id: 'wf-current-outline', current_stage: 'detail_outline_review', book_root: root,
  stage_execution: { review_targets: [{ outline_path: rel, outline_sha256: actual }] } };
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

@test "detail outline quality v2 accepts three matching identities as one stage review" {
    node - "$REPO/scripts/lib/workflow-transition-service.js" "$TMP_DIR" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const {validateDetailOutlineQualityResult,validateLifecycleTransitionRequest,validateReviewRevisionReturn}=require(process.argv[2]);
const root=process.argv[3];
const targets=[1,2,3].map((chapter)=>{
  const outline_path=`大纲/第1卷/细纲_第${String(chapter).padStart(3,'0')}章.md`;
  const file=path.join(root,outline_path); fs.mkdirSync(path.dirname(file),{recursive:true}); fs.writeFileSync(file,`中性细纲 ${chapter}`);
  return {outline_path,outline_sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')};
});
const task={workflow_type:'long_write',workflow_id:'wf-batch-pass',current_stage:'detail_outline_review',book_root:root,stage_execution:{review_targets:targets}};
const identities=targets.map((target)=>({
  status:'pass',workflow_id:task.workflow_id,stage_id:task.current_stage,...target,activated_dimensions:[],findings:[],contract_projection:[],memory_projection:[],
  execution:{semantic_review:{status:'accepted',reviewer:'main-session',findings:[],findings_sha256:crypto.createHash('sha256').update('[]').digest('hex'),finding_count:0}},
}));
const packet={outputs:{detail_outline_quality:{version:'detail_outline_quality_v2',workflow_id:task.workflow_id,stage_id:task.current_stage,identities}},evidence:targets.map((target)=>({type:'detail_outline',path:target.outline_path,outline_sha256:target.outline_sha256}))};
assert.deepEqual(validateDetailOutlineQualityResult(packet,task),{status:'accepted',code:''});
NODE
}

@test "detail outline quality v2 rejects an incomplete target manifest" {
    node - "$REPO/scripts/lib/workflow-transition-service.js" "$TMP_DIR" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const {validateDetailOutlineQualityResult}=require(process.argv[2]);
const root=process.argv[3];
const targets=[1,2,3].map((chapter)=>{const outline_path=`大纲/阶段/细纲_${chapter}.md`;const file=path.join(root,outline_path);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,`细纲 ${chapter}`);return {outline_path,outline_sha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}});
const task={workflow_type:'long_write',workflow_id:'wf-batch-missing',current_stage:'detail_outline_review',book_root:root,stage_execution:{review_targets:targets}};
const identities=targets.slice(0,2).map((target)=>({status:'pass',workflow_id:task.workflow_id,stage_id:task.current_stage,...target,activated_dimensions:[],findings:[],contract_projection:[],memory_projection:[],execution:{semantic_review:{status:'accepted',reviewer:'main-session',findings:[],findings_sha256:crypto.createHash('sha256').update('[]').digest('hex'),finding_count:0}}}));
const packet={outputs:{detail_outline_quality:{version:'detail_outline_quality_v2',workflow_id:task.workflow_id,stage_id:task.current_stage,identities}},evidence:identities.map((item)=>({type:'detail_outline',path:item.outline_path,outline_sha256:item.outline_sha256}))};
assert.equal(validateDetailOutlineQualityResult(packet,task).code,'detail_outline_quality_coverage_missing');
NODE
}

@test "detail outline quality v2 reports one stale or revise identity precisely" {
    node - "$REPO/scripts/lib/workflow-transition-service.js" "$TMP_DIR" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const {validateDetailOutlineQualityResult,validateLifecycleTransitionRequest,validateReviewRevisionReturn}=require(process.argv[2]);
const root=process.argv[3],outline_path='大纲/阶段/细纲_1.md',file=path.join(root,outline_path);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,'中性细纲');
const hash=crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const target={outline_path,outline_sha256:hash};
const task={workflow_type:'long_write',workflow_id:'wf-batch-failure',current_stage:'detail_outline_review',book_root:root,stage_execution:{review_targets:[target]}};
const quality=(status,outline_sha256,findings=[])=>({status,workflow_id:task.workflow_id,stage_id:task.current_stage,outline_path,outline_sha256,activated_dimensions:[],findings,contract_projection:[],memory_projection:[],execution:{semantic_review:{status:'accepted',reviewer:'main-session',findings,findings_sha256:crypto.createHash('sha256').update(JSON.stringify(findings)).digest('hex'),finding_count:findings.length}}});
const packet=(identity)=>({outputs:{detail_outline_quality:{version:'detail_outline_quality_v2',workflow_id:task.workflow_id,stage_id:task.current_stage,identities:[identity]}},evidence:[{type:'detail_outline',path:outline_path,outline_sha256:identity.outline_sha256}]});
assert.equal(validateDetailOutlineQualityResult(packet(quality('pass','a'.repeat(64))),task).code,'detail_outline_quality_outline_sha256_mismatch');
const findings=[{dimension:'B1_causality_action',severity:'blocking',message:'缺少可见因果动作'}];
assert.equal(validateDetailOutlineQualityResult(packet(quality('revise',hash,findings)),task).status,'review_failed');
const returnResult={...packet(quality('revise',hash,findings)),step_status:'completed',verification_result:'revise',review_decision:'revise',lifecycle_transition_request:{action:'return',target:'stage_detail_outline'}};
returnResult.outputs.detail_outline_quality.status='revise';
const transition=validateLifecycleTransitionRequest({allowed_next:['stage_detail_outline','chapter_brief'],review_requirement:{required:true,failure_return:'stage_detail_outline'}},'detail_outline_review',returnResult);
assert.equal(transition.status,'valid');
assert.equal(transition.requested_next,'stage_detail_outline');
assert.equal(validateReviewRevisionReturn({allowed_next:['stage_detail_outline','chapter_brief'],review_requirement:{required:true,failure_return:'stage_detail_outline'}},'detail_outline_review',returnResult).valid,true);
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
  let task = readTask(project);
  if (task.stage_execution && task.stage_execution.status === 'running') {
    return { stage_execution: task.stage_execution };
  }
  let pending = task.pending_action || {};
  let result = run(['resolve-action', '--project-root', project, '--input', '1', '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash, '--state-version', String(task.state_version), '--book-root', project, '--json']);
  if (result.stage_execution) return result;
  task = readTask(project);
  pending = task.pending_action || {};
  result = run(['resolve-action', '--project-root', project, '--input', '1', '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash, '--state-version', String(task.state_version), '--book-root', project, '--json']);
  return result;
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

for (const mode of ['missing', 'expired', 'tampered', 'resumed']) {
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
  if (mode === 'resumed') {
    task.stage_execution.action_id = 'resume_paused_stage';
    task.stage_execution.confirmation_context.selected_action_id = 'resume_paused_stage';
    task.last_selection.action_id = 'resume_paused_stage';
    task.last_selection.requires_user_confirm = false;
  }
  persistTask(project, task);
  const rel = started.stage_execution.expected_result_packet;
  const file = path.join(project, rel);
  writePacket(file, buildPacket(task, started.stage_execution.stage_id, started.stage_execution.step_id, rel));
  if (mode === 'resumed') {
    run(['apply-result', '--project-root', project, '--result', file, '--json']);
    continue;
  }
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
  if (task.stage_execution && task.stage_execution.status === 'running') {
    return { stage_execution: task.stage_execution };
  }
  const pending = task.pending_action || {};
  const first = run(['resolve-action', '--project-root', project, '--input', '1', '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash, '--state-version', String(task.state_version), '--book-root', project, '--json']);
  if (first.stage_execution) return first;
  const refreshed = readTask(project);
  if (refreshed.stage_execution && refreshed.stage_execution.status === 'running') {
    return { stage_execution: refreshed.stage_execution };
  }
  const next = refreshed.pending_action || {};
  return run(['resolve-action', '--project-root', project, '--input', '1', '--pending-action-id', next.id, '--visible-choice-hash', next.visible_choice_hash, '--state-version', String(refreshed.state_version), '--book-root', project, '--json']);
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
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --user-goal "写长篇" --json >/dev/null

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.stage_execution.owner_module !== 'story-long-write') throw new Error(JSON.stringify(out.stage_execution));
if (out.stage_execution.risk_level !== 'low') throw new Error(JSON.stringify(out.stage_execution));
if (out.stage_execution.requires_user_confirm !== false) throw new Error(JSON.stringify(out.stage_execution));
NODE
}

@test "workflow state machine classifies obvious new intent and keeps current task resumable" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --user-goal "写长篇" --json >/dev/null

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
    node "$SCRIPT" create --workflow-type review_repair --project-root "$TMP_DIR/book" --scope "1-10" --user-goal "审阅旧任务 1-10 章" --json > "$TMP_DIR/create.json"
    old_id="$(node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(data.task.workflow_id)' "$TMP_DIR/create.json")"
    old_dir="$TMP_DIR/book/追踪/workflow/tasks/$old_id"

    node "$SCRIPT" switch-intent --workflow-type long_write --project-root "$TMP_DIR/book" --scope "第1章" --user-goal "切换到长篇写作" --reason manual_new_goal --json > "$TMP_DIR/switch.json"

    [ -f "$old_dir/task.json" ]
    [ -f "$old_dir/rpd.md" ]
    grep -q '"status": "paused"' "$old_dir/task.json"
    ! grep -q '"status": "superseded"' "$old_dir/task.json"
    grep -q '"event":"focus_paused"' "$old_dir/journal.jsonl"
    grep -q "审阅旧任务 1-10 章" "$old_dir/rpd.md"

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
  for (const id of ['startup_scan', 'startup_menu', 'freshness_window', 'info_source_pool']) {
    const memory = stages[id].memory_contract || {};
    if (memory.read_mode !== 'none' || Number(memory.token_budget || 0) !== 0) {
      throw new Error(`${id} must not assemble story memory: ${JSON.stringify(memory)}`);
    }
  }
  if (!stages.short_setting.allowed_next.includes('platform_genre_lock')) {
    throw new Error(`short_setting must go to platform_genre_lock: ${JSON.stringify(stages.short_setting.allowed_next)}`);
  }
  if (!stages.platform_genre_lock.required_inputs.includes('short_setting') || stages.platform_genre_lock.requires_user_confirm) {
    throw new Error(`platform_genre_lock contract invalid: ${JSON.stringify(stages.platform_genre_lock)}`);
  }
  if (!stages.platform_genre_lock.allowed_next.includes('rhythm_pattern_selection')) {
    throw new Error(`platform_genre_lock must go to rhythm_pattern_selection: ${JSON.stringify(stages.platform_genre_lock.allowed_next)}`);
  }
  if (!stages.rhythm_pattern_selection.required_inputs.includes('platform_genre_lock')) {
    throw new Error(`rhythm_pattern_selection must require platform_genre_lock: ${JSON.stringify(stages.rhythm_pattern_selection.required_inputs)}`);
  }
  if (stages.rhythm_pattern_selection.requires_user_confirm) {
    throw new Error(`rhythm_pattern_selection must stay inside the author-visible outline phase: ${JSON.stringify(stages.rhythm_pattern_selection)}`);
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

@test "new private short startup shows freshness menu before bounded discovery" {
    mkdir -p "$TMP_DIR/book"
    run node "$REPO/scripts/short-startup-entry.js" --project-root "$TMP_DIR/book" --legacy-v2 --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"short_startup_ready"'* ]]
    [[ "$output" == *'抓取最新热点资讯做选题（推荐）'* ]]

    run node "$REPO/scripts/workflow-entry-guard.js" --project-root "$TMP_DIR/book" --write --compact --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"short_startup_choice_required"'* ]]
    [[ "$output" == *'抓取最新热点资讯做选题（推荐）'* ]]
    [[ "$output" != *'查看未完成任务'* ]]
    [[ "$output" == *'verbatim_no_pipe_no_redirect_no_truncation'* ]]

    workflow_id="$(node -p "JSON.parse(require('fs').readFileSync('$TMP_DIR/book/追踪/workflow/current-task.json','utf8')).workflow_id")"
    run node "$SCRIPT" activate --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --compact --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'抓取最新热点资讯做选题（推荐）'* ]]
    [[ "$output" != *'继续继续当前任务'* ]]
    [[ "$output" != *'pa-resume-startup_scan'* ]]

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 1 --bind-current --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"workflow_choice_required"'* ]]
    [[ "$output" == *'最近 24 小时（推荐）'* ]]
    [[ "$output" == *'最近 7 天'* ]]

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 3 --bind-current --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"stage_id":"info_source_pool"'* ]]
    [[ "$output" == *'hot-source-capture.js'* ]]
    [[ "$output" == *'short-info-source-finalize.js'* ]]
    [[ "$output" == *'"read_mode":"none"'* ]]
    [[ "$output" == *'"token_budget":0'* ]]

    run node "$REPO/scripts/workflow-entry-guard.js" --project-root "$TMP_DIR/book" --user-intent "/novel-assistant" --write --compact --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'当前任务：新开短篇'* ]]
    [[ "$output" == *'当前阶段：抓取最近 7 天热点资讯'* ]]
    [[ "$output" == *'1. 继续抓取最近 7 天热点资讯（推荐）'* ]]

    run node - "$TMP_DIR/book/追踪/workflow/current-task.json" <<'NODE'
const fs=require('fs');
const path=require('path');
const pointerFile=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(pointerFile,'utf8'));
const root=path.resolve(path.dirname(pointerFile),'../..');
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
if(task.current_stage!=='info_source_pool') throw new Error(JSON.stringify(task.current_stage));
if(Number(((task.freshness_window||{}).days)||0)!==7) throw new Error(JSON.stringify(task.freshness_window));
if(((task.stage_execution||{}).memory_context||{}).status!=='not_applicable') throw new Error(JSON.stringify(task.stage_execution.memory_context));
if(!String((task.stage_execution||{}).info_source_capture||'').endsWith('/source-capture.json')) throw new Error(JSON.stringify(task.stage_execution));
if(!String((task.stage_execution||{}).info_source_context||'').endsWith('/enrichment-context.json')) throw new Error(JSON.stringify(task.stage_execution));
const hint=String((task.stage_execution||{}).resume_hint||'');
if(!hint.includes('再立即运行 execution_command')||!hint.includes('只能读取返回的 context_path')) throw new Error(hint);
if(hint.includes('只读取其中 source_items')) throw new Error(hint);
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }

    workflow_id="$(node -p "JSON.parse(require('fs').readFileSync('$TMP_DIR/book/追踪/workflow/current-task.json','utf8')).workflow_id")"
    run node "$REPO/scripts/short-info-source-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"short_info_source_capture_required"'* ]]
    [[ "$output" == *'hot-source-capture.js'* ]]

    node - "$TMP_DIR/book" <<'NODE'
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
const captureFile=path.join(root,task.stage_execution.info_source_capture);
fs.mkdirSync(path.dirname(captureFile),{recursive:true});
fs.writeFileSync(captureFile,JSON.stringify({
  status:'hot_source_capture_ready',
  capture_id:'capture-fake',
  discovery_evidence:{performed:true,methods:['web_search'],queried_at:'2026-07-26',queries:[],source_attempts:['baidu_realtime','tencent_news','sina_news_ent','netease_news','douyin_hot','toutiao_hot','weibo_hot'].map(source_id=>({source_id,status:'success'}))},
  source_items:[]
}), 'utf8');
const file=path.join(root,task.stage_execution.info_source_candidate);
fs.mkdirSync(path.dirname(file),{recursive:true});
fs.writeFileSync(file,JSON.stringify({
  capture_id:'capture-fake',
  discovery_evidence:{performed:true,methods:['web_search'],queried_at:'2026-07-26',queries:['微博热搜 彩礼'],source_attempts:['baidu_realtime','tencent_news','sina_news_ent','netease_news','douyin_hot','toutiao_hot','weibo_hot'].map(source_id=>({source_id,status:'success'}))},
  info_source_cards:[]
}), 'utf8');
NODE
    run node "$REPO/scripts/short-info-source-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"short_info_source_capture_revision_required"'* ]]
    [[ "$output" == *'capture_items_missing'* ]]
}

@test "material learning stage always carries a bounded deterministic execution contract" {
    mkdir -p "$TMP_DIR/book"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --json >/dev/null
    run node - "$SCRIPT" "$TMP_DIR/book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const helper=require(process.env.WORKFLOW_TASK_FIXTURE);
fs.mkdirSync(path.join(root,'追踪/private-short-extension/cards'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/private-short-extension/cards/info-source-cards.jsonl'),JSON.stringify({info_id:'info-1',title:'热点事件',factual_summary:'企业公开承诺与实际生产不一致',human_conflict:'员工生计与消费者知情权冲突',verdict:'write',pool_status:'selected',route_fit:['番茄短篇'],scorecard:{material_score:8.6},learning_notes:'适合作为商业伦理冲突的现实燃料',source_refs:[{url:'https://example.com'}]})+'\n');
const task=helper.readFocusedTask(root);
task.current_stage='material_learning';task.current_step='material_learning';task.status='running';
task.stage_execution={status:'running',stage_id:'material_learning',step_id:'material_learning',owner_module:'private-short-extension',stage_attempt_id:'attempt-material',expected_result_packet:`${task.task_dir}/result-packets/material_learning.result.json`};
task.pending_action=null;
fs.writeFileSync(helper.focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
const out=cp.spawnSync(process.execPath,[script,'reconcile-runtime','--project-root',root,'--workflow-id',task.workflow_id,'--session-id','test:material-learning','--json'],{encoding:'utf8'});
if(out.status!==0) throw new Error(out.stdout||out.stderr);
const refreshed=helper.readFocusedTask(root);const execution=refreshed.stage_execution||{};
if(!String(execution.context_read_command||'').includes('short-material-learning-finalize.js')) throw new Error(JSON.stringify(execution));
if(!String(execution.execution_command||'').includes('short-material-learning-finalize.js')) throw new Error(JSON.stringify(execution));
if(JSON.stringify(execution.write_set)!==JSON.stringify([`${task.task_dir}/artifacts/material-learning/candidate-cards.json`])) throw new Error(JSON.stringify(execution));
if((execution.memory_context||{}).status!=='not_applicable') throw new Error(JSON.stringify(execution.memory_context));
const prepare=cp.spawnSync(process.execPath,[path.join(path.dirname(script),'short-material-learning-finalize.js'),'--project-root',root,'--workflow-id',task.workflow_id,'--prepare','--json'],{encoding:'utf8'});
if(prepare.status!==0) throw new Error(prepare.stdout||prepare.stderr);
const prepared=JSON.parse(prepare.stdout);
if(prepared.status!=='short_material_learning_context_ready'||prepared.selected_info_cards?.[0]?.info_id!=='info-1') throw new Error(prepare.stdout);
if(prepared.generation_plan?.topic_card_count!==3||prepared.generation_plan?.material_card_count!==1||prepared.generation_plan?.primary_candidate_limit!==1) throw new Error(prepare.stdout);
if(prepared.selected_info_cards?.[0]?.material_score!==8.6) throw new Error(prepare.stdout);
const shape=((prepared.contract||{}).candidate_shape)||{};
const materialFields=((shape.material_cards||{}).required_fields)||[];
const hotspotFields=((shape.hotspot_cards||{}).required_fields)||[];
const topicFields=((shape.topic_cards||{}).required_fields)||[];
for(const field of ['card_type','canonical_id','source_info_ids','actionable_choice']) if(!materialFields.includes(field)) throw new Error(`missing material contract field ${field}`);
for(const field of ['hotspot_id','source_material_ids','protagonist_action','payoff_shape']) if(!hotspotFields.includes(field)) throw new Error(`missing hotspot contract field ${field}`);
for(const field of ['topic_id','primary_hotspot_id','irreversible_choice','escalation_beats','final_payoff']) if(!topicFields.includes(field)) throw new Error(`missing topic contract field ${field}`);
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "project seed uses one numeric card namespace and promotes the selected card directly" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension/cards"
    printf '%s\n' \
      '{"card_type":"topic_card","topic_id":"top-1","quality_status":"story_value_passed","title_candidates":["卡一"]}' \
      '{"card_type":"topic_card","topic_id":"top-2","quality_status":"story_value_passed","title_candidates":["卡二"]}' \
      '{"card_type":"topic_card","topic_id":"top-3","quality_status":"story_value_passed","title_candidates":["卡三"]}' \
      > "$TMP_DIR/book/追踪/private-short-extension/cards/topic-cards.jsonl"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --json >/dev/null
    run node - "$SCRIPT" "$TMP_DIR/book" <<'NODE'
const cp=require('child_process'),fs=require('fs');
const script=process.argv[2],root=process.argv[3],helper=require(process.env.WORKFLOW_TASK_FIXTURE);
let task=helper.readFocusedTask(root);
task.current_stage='project_seed';task.current_step='project_seed';task.status='running';task.stage_execution=null;
task.pending_action={id:'pa-project_seed',question:'请选择下一步',options:[
 {number:1,action_id:'continue_next_stage',label:'继续选择脑洞并建立独立短篇项目（推荐）',target_stage:'project_seed',risk_level:'high',requires_user_confirm:true},
 {number:2,action_id:'inspect_current_state',label:'查看当前进度与依据'},
 {number:3,action_id:'pause',label:'停止并保存断点'},
 {number:4,action_id:'free_text',label:'输入其他要求'}
],free_text_enabled:true,status:'pending'};
fs.writeFileSync(helper.focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
let result=cp.spawnSync(process.execPath,[script,'next-candidates','--project-root',root,'--json'],{encoding:'utf8'});
let out=JSON.parse(result.stdout);if(!out.visible_response.text.includes('3. 卡三')||out.visible_response.text.includes('B1')||out.visible_response.text.includes('A3')) throw new Error(result.stdout);
if(!out.visible_response.text.includes('看 3 详情')||!out.visible_response.text.includes('删除 3')) throw new Error(result.stdout);
result=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','3','--bind-current','--json'],{encoding:'utf8'});
if(result.status!==0) throw new Error(result.stdout||result.stderr);
out=JSON.parse(result.stdout);
if(out.status!=='short_project_seeded'||out.current_stage!=='short_setting') throw new Error(result.stdout);
task=helper.readFocusedTask(root);
if((task.short_card_selection||{}).topic_ids?.[0]!=='top-3') throw new Error(JSON.stringify(task.short_card_selection));
if(task.current_stage!=='short_setting'||!fs.existsSync(root+'/素材卡.md')) throw new Error(JSON.stringify(task));
const state=JSON.parse(fs.readFileSync(root+'/追踪/story-system/short/project-state.json','utf8'));
if(state.project_title!=='卡三'||state.selected_material?.card_id!=='top-3') throw new Error(JSON.stringify(state));
const policy=JSON.parse(fs.readFileSync(root+'/追踪/story-system/write-policy.json','utf8'));
if(policy.mode!=='strict'||policy.initialized_for!=='managed_short_project_seed') throw new Error(JSON.stringify(policy));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "project seed multi selection creates isolated child projects" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension/cards"
    printf '%s\n' \
      '{"card_type":"topic_card","topic_id":"top-1","quality_status":"story_value_passed","title_candidates":["卡一"]}' \
      '{"card_type":"topic_card","topic_id":"top-2","quality_status":"story_value_passed","title_candidates":["卡二"]}' \
      > "$TMP_DIR/book/追踪/private-short-extension/cards/topic-cards.jsonl"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --json >/dev/null
    run node - "$SCRIPT" "$TMP_DIR/book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3],helper=require(process.env.WORKFLOW_TASK_FIXTURE);
let task=helper.readFocusedTask(root);
task.current_stage='project_seed';task.current_step='project_seed';task.status='running';task.stage_execution=null;
task.pending_action={id:'pa-project_seed',question:'请选择脑洞',options:[
 {number:1,action_id:'continue_next_stage',label:'建立项目',target_stage:'project_seed'},
 {number:2,action_id:'inspect_current_state',label:'查看当前进度'},
 {number:3,action_id:'pause',label:'暂停'},
 {number:4,action_id:'free_text',label:'其他'}
],free_text_enabled:true,status:'pending'};
fs.writeFileSync(helper.focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
const result=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1,2','--bind-current','--json'],{encoding:'utf8'});
if(result.status!==0) throw new Error(result.stdout||result.stderr);
const out=JSON.parse(result.stdout);
if(out.status!=='short_projects_seeded'||out.created_projects?.length!==2) throw new Error(result.stdout);
for(const project of out.created_projects){
  if(!fs.existsSync(path.join(project.project_root,'素材卡.md'))) throw new Error(JSON.stringify(project));
  const state=JSON.parse(fs.readFileSync(path.join(project.project_root,'追踪/story-system/short/project-state.json'),'utf8'));
  if(state.selected_material?.card_id!==project.card_id||state.active_write_workflow_id!==project.workflow_id) throw new Error(JSON.stringify(state));
  const policy=JSON.parse(fs.readFileSync(path.join(project.project_root,'追踪/story-system/write-policy.json'),'utf8'));
  if(policy.mode!=='strict') throw new Error(JSON.stringify(policy));
}
if(out.created_projects[0].project_root===out.created_projects[1].project_root) throw new Error(result.stdout);
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "project seed text commands inspect reject and regenerate without a second menu namespace" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension/cards"
    printf '%s\n' \
      '{"card_type":"topic_card","topic_id":"top-1","quality_status":"story_value_passed","title_candidates":["卡一"],"story_promise":"承诺一"}' \
      '{"card_type":"topic_card","topic_id":"top-2","quality_status":"story_value_passed","title_candidates":["卡二"]}' \
      > "$TMP_DIR/book/追踪/private-short-extension/cards/topic-cards.jsonl"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --json >/dev/null
    run node - "$SCRIPT" "$TMP_DIR/book" <<'NODE'
const cp=require('child_process'),fs=require('fs');
const script=process.argv[2],root=process.argv[3],helper=require(process.env.WORKFLOW_TASK_FIXTURE);
let task=helper.readFocusedTask(root);
task.current_stage='project_seed';task.current_step='project_seed';task.status='running';task.stage_execution=null;
task.pending_action={id:'pa-project_seed',question:'请选择脑洞',options:[
 {number:1,action_id:'continue_next_stage',label:'建立项目',target_stage:'project_seed'},
 {number:2,action_id:'inspect_current_state',label:'查看当前进度'},
 {number:3,action_id:'pause',label:'暂停'},
 {number:4,action_id:'free_text',label:'其他'}
],free_text_enabled:true,status:'pending'};
fs.writeFileSync(helper.focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
let result=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','看 1 详情','--json'],{encoding:'utf8'});
let out=JSON.parse(result.stdout);if(out.status!=='project_seed_card_detail'||!out.visible_response.text.includes('承诺一')) throw new Error(result.stdout);
result=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','删除 1','--json'],{encoding:'utf8'});
out=JSON.parse(result.stdout);if(out.status!=='project_seed_selection_required'||out.visible_response.cards?.length!==1||out.visible_response.cards[0].topic_id!=='top-2'||!out.visible_response.text.includes('1. 卡二')) throw new Error(result.stdout);
result=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','换一批','--json'],{encoding:'utf8'});
out=JSON.parse(result.stdout);if(out.status!=='short_card_pool_regeneration_requested') throw new Error(result.stdout);
task=helper.readFocusedTask(root);if(task.current_stage!=='material_learning') throw new Error(JSON.stringify(task));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "legacy project seed cards must re-enter material learning before selection" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension/cards"
    printf '%s\n' '{"card_type":"topic_card","topic_id":"legacy-top","title_candidates":["旧卡"]}' > "$TMP_DIR/book/追踪/private-short-extension/cards/topic-cards.jsonl"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --json >/dev/null
    run node - "$SCRIPT" "$TMP_DIR/book" <<'NODE'
const cp=require('child_process'),fs=require('fs');
const script=process.argv[2],root=process.argv[3],helper=require(process.env.WORKFLOW_TASK_FIXTURE);
let task=helper.readFocusedTask(root);
task.current_stage='project_seed';task.current_step='project_seed';task.status='running';task.stage_execution=null;
task.pending_action={id:'pa-project_seed',question:'请选择下一步',status:'resolved',selected_number:3,selected_action_id:'pause',options:[
 {number:1,action_id:'continue_next_stage',label:'继续选择脑洞并建立独立短篇项目',target_stage:'project_seed'},
 {number:2,action_id:'inspect_current_state',label:'查看当前进度'},
 {number:3,action_id:'pause',label:'停止并保存断点'},
 {number:4,action_id:'free_text',label:'输入其他要求'}
]};
fs.writeFileSync(helper.focusedTaskFile(root),JSON.stringify(task,null,2)+'\n');
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--bind-current','--json'],{encoding:'utf8'});
if(out.status!==0) throw new Error(out.stdout||out.stderr);
task=helper.readFocusedTask(root);
if(task.current_stage!=='material_learning'||!String((task.stage_execution||{}).execution_command||'').includes('short-material-learning-finalize.js')) throw new Error(JSON.stringify(task));
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "private short startup restart preserves old workflow and creates a clean successor" {
    mkdir -p "$TMP_DIR/book"
    run node "$REPO/scripts/short-startup-entry.js" --project-root "$TMP_DIR/book" --legacy-v2 --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    old_id="$(node -p "JSON.parse(require('fs').readFileSync('$TMP_DIR/book/追踪/workflow/current-task.json','utf8')).workflow_id")"

    run node "$REPO/scripts/short-startup-entry.js" --project-root "$TMP_DIR/book" --legacy-v2 --restart --reason "重新规划热点资讯发现流程" --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"short_startup_ready"'* ]]
    new_id="$(node -p "JSON.parse(require('fs').readFileSync('$TMP_DIR/book/追踪/workflow/current-task.json','utf8')).workflow_id")"
    [ "$new_id" != "$old_id" ]

    run node - "$TMP_DIR/book" "$old_id" "$new_id" <<'NODE'
const fs=require('fs');
const path=require('path');
const [root,oldId,newId]=process.argv.slice(2);
const oldTask=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',oldId,'task.json'),'utf8'));
const newTask=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',newId,'task.json'),'utf8'));
if(String(oldTask.status)!=='paused') throw new Error(`old status ${oldTask.status}`);
if(String(((oldTask.lifecycle||{}).focus_switched_to)||'')!==newId) throw new Error(JSON.stringify(oldTask.lifecycle));
if(String(newTask.parent_workflow_id||'')!==oldId) throw new Error(`parent ${newTask.parent_workflow_id}`);
if(String(newTask.current_stage||'')!=='startup_menu') throw new Error(`stage ${newTask.current_stage}`);
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "private short free text can restart info discovery without reading skill internals" {
    mkdir -p "$TMP_DIR/book"
    run node "$REPO/scripts/short-startup-entry.js" --project-root "$TMP_DIR/book" --legacy-v2 --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "我需要重新抓取资讯，之前的认为作废" --bind-current --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"short_info_discovery_restarted"'* ]]
    [[ "$output" == *'"current_stage":"freshness_window"'* ]]
    [[ "$output" == *'最近 24 小时（推荐）'* ]]
    [[ "$output" == *'最近 3 天'* ]]
    [[ "$output" == *'最近 7 天'* ]]
    [[ "$output" == *'old_artifacts_preserved'* ]]

    run node "$REPO/scripts/workflow-entry-guard.js" --project-root "$TMP_DIR/book" --compact --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status":"task_inbox_ready"'* ]]
    [[ "$output" == *'查看未完成任务（1 个）（推荐）'* ]]
    [[ "$output" != *'最近 24 小时（推荐）'* ]]
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
    printf '%s\n' '{"project_id":"short-feedback-project","project_title":"档案复核","plan_revision":2}' > "$TMP_DIR/book/追踪/private-short-extension/project-state.json"
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
if(!/workflow-stage-context\.js read-current/.test(String(execution.context_read_command||''))) throw new Error(`section_plan_lock must read its task-scoped memory packet: ${JSON.stringify(execution)}`);
if(!/标题/.test(String(execution.resume_hint||''))) throw new Error(JSON.stringify(execution));
NODE

    workflow_id="$(jq -r '.workflow_id' "$(focused_task_file "$TMP_DIR/book")")"
    node "$REPO/scripts/short-section-title-lock.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --json > "$TMP_DIR/title-preview.json"
    digest="$(jq -r '.digest' "$TMP_DIR/title-preview.json")"
    node "$REPO/scripts/short-section-title-lock.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --digest "$digest" --confirm --json > "$TMP_DIR/title-confirm.json"
    [ "$(jq -r '.next_stage' "$TMP_DIR/title-confirm.json")" = "short_structure_impact_audit" ]
    task_file="$(focused_task_file "$TMP_DIR/book")"
    [[ "$(jq -r '.stage_execution.context_read_command // empty' "$task_file")" == *'workflow-stage-context.js read-current'* ]]
    [[ "$(jq -r '.stage_execution.execution_command' "$task_file")" == *'short-structure-impact-finalize.js'* ]]

    node "$REPO/scripts/short-structure-impact-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json > "$TMP_DIR/impact.json"
    [ "$(jq -r '.status' "$TMP_DIR/impact.json")" = "short_structure_impact_completed" ]
    [ "$(jq -r '.current_stage' "$(focused_task_file "$TMP_DIR/book")")" = "hook_retention_gate" ]

    resolve_action "$TMP_DIR/book" 1 > "$TMP_DIR/hook-start.json"
    task_file="$(focused_task_file "$TMP_DIR/book")"
    [ "$(jq -r '.current_stage' "$task_file")" = "hook_retention_gate" ]
    [[ "$(jq -r '.stage_execution.context_read_command // empty' "$task_file")" == *'workflow-stage-context.js read-current'* ]]
    [[ "$(jq -r '.stage_execution.execution_command' "$task_file")" == *'short-hook-value-finalize.js'* ]]
    node "$REPO/scripts/short-hook-value-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json > "$TMP_DIR/hook-review.json"
    [ "$(jq -r '.status' "$TMP_DIR/hook-review.json")" = "short_hook_value_review_required" ]
    [ -f "$TMP_DIR/book/$(jq -r '.evidence_pack' "$TMP_DIR/hook-review.json")" ]
    jq -e '.review_card_schema.checks | map(.id) | index("golden_opening_disruption") != null and index("golden_opening_immediate_stakes") != null and index("golden_opening_active_choice") != null and index("first_third_power_shift") != null and index("finale_title_answer") != null' "$TMP_DIR/hook-review.json" >/dev/null
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
const ids=['title_promise','opening_pressure','plot_spikes','golden_reading_map','section_breakpoints','dropoff_risk','protagonist_agency','causal_chain','golden_opening_disruption','golden_opening_immediate_stakes','golden_opening_active_choice','first_third_power_shift','supporting_character_agency','identity_continuity','finale_title_answer','ending_payoff_capacity'];
fs.writeFileSync(file,JSON.stringify({schemaVersion:'1.0.0',workflow_id:workflowId,evidence_digest:digest,decision:'pass',repair_layer:'none',summary:'看点价值门通过。',checks:ids.map(id=>({id,status:'pass',evidence:`${id} 已在规划证据中明确。`,repair_direction:''}))},null,2)+'\n');
NODE
    node "$REPO/scripts/short-hook-value-finalize.js" --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --apply --json > "$TMP_DIR/hook-pass.json"
    [ "$(jq -r '.status' "$TMP_DIR/hook-pass.json")" = "short_hook_value_completed" ]
    task_file="$(focused_task_file "$TMP_DIR/book")"
    [ "$(jq -r '.current_stage' "$task_file")" = "first_section_brief" ]
    [ "$(jq -r '.stage_execution.status' "$task_file")" = "contract_blocked" ]
    [ "$(jq '.pending_action.options | length' "$task_file")" -eq 4 ]
    [ "$(jq -r '.pending_action.options[0].label' "$task_file")" = "查看缺失条件并恢复执行条件（推荐）" ]
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

@test "short feedback impact stage exposes a writable completion contract" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    printf '%s\n' '{"project_id":"feedback-contract-test","project_title":"反馈合同测试","plan_revision":1}' > "$TMP_DIR/book/追踪/private-short-extension/project-state.json"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：先更新设定和小节大纲。" --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" > "$TMP_DIR/feedback-impact-started.json"
    ln -s "$REPO/scripts" "$TMP_DIR/book/scripts"
    node - "$TMP_DIR/feedback-impact-started.json" "$TMP_DIR/book" "$REPO" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),root=process.argv[3];
const execution=out.stage_execution||{};
const packet=String(execution.expected_result_packet||'');
if(execution.write_set.length!==1||execution.write_set[0]!==packet) throw new Error(JSON.stringify(execution));
if(!/workflow-state-machine\.js apply-result/.test(String(execution.execution_command||''))) throw new Error(JSON.stringify(execution));
if(!String(execution.execution_command||'').includes(`--result ${JSON.stringify(packet)}`)) throw new Error(JSON.stringify(execution));
if(execution.stage_completion_command!==execution.execution_command) throw new Error(JSON.stringify(execution));
if(execution.current_required_action!=='edit_write_set') throw new Error(JSON.stringify(execution));
if((execution.after_write_action||{}).command!==execution.execution_command) throw new Error(JSON.stringify(execution));
for(const field of ['outputs=[]','changed_files=[]','evidence=[]','checkpoint_state']) if(!String(execution.resume_hint||'').includes(field)) throw new Error(JSON.stringify(execution.resume_hint));
const taskFile=path.join(root,'追踪/workflow/tasks',out.workflow_id,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const result={schemaVersion:'1.0.0',workflow_id:task.workflow_id,workflow_type:task.workflow_type,owner_module:execution.owner_module,stage_id:'feedback_impact_sync',step_id:'feedback_impact_sync',step_status:'completed',outputs:[],changed_files:[],evidence:[],verification_result:'pass',checkpoint_state:{completed_stage:'feedback_impact_sync'},output_health_result:'pass',feedback_id:task.pending_feedback.feedback_id,impact_level:'planning',affected_sections:[1],affected_assets:['小节大纲.md'],downstream_impact:{invalidate_briefs:[1],recheck_prose:[1]},revision_groups:[{group_id:'revision-1',goal:'回写规划',section_indices:[1],completion_condition:'规划已同步'}],next_stage_id:'feedback_apply_patch',result_packet_path:packet};
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});
fs.writeFileSync(path.join(root,packet),JSON.stringify(result,null,2)+'\n');
const applied=cp.spawnSync(execution.stage_completion_command,{cwd:root,encoding:'utf8',shell:true});
if(applied.status!==0) throw new Error(applied.stderr||applied.stdout);
const response=JSON.parse(applied.stdout),saved=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(!['advanced','stage_started'].includes(response.status)||saved.current_stage!=='feedback_apply_patch') throw new Error(JSON.stringify({response,saved}));
if((saved.short_feedback_impact||{}).feedback_id!==task.pending_feedback.feedback_id) throw new Error(JSON.stringify(saved.short_feedback_impact));
if((saved.proposed_plan||{}).status!=='awaiting_user_confirmation') throw new Error(JSON.stringify(saved.proposed_plan));
const pending=saved.pending_action||{},proposal=saved.proposed_plan||{};
if(pending.feedback_id!==task.pending_feedback.feedback_id||pending.proposal_id!==proposal.proposal_id) throw new Error(JSON.stringify({pending,proposal}));
const actions=(pending.options||[]).map(item=>item.action_id);
if(actions.join(',')!=='continue_next_stage,request_feedback_proposal_revision_input,inspect_current_state,pause') throw new Error(JSON.stringify(pending.options));
if((pending.options||[])[0].label!=='确认并执行当前回写方案（推荐）'||(pending.options||[])[1].label!=='进入 Chat 修改或补充方案') throw new Error(JSON.stringify(pending.options));
if(saved.stage_execution!==null) throw new Error(JSON.stringify(saved.stage_execution));
if(!String(((response.visible_response||{}).text)||'').includes(proposal.summary)||String(((response.visible_response||{}).text)||'').includes('继续双门验收与采用')) throw new Error(JSON.stringify(response.visible_response));
const revise=cp.spawnSync(process.execPath,[path.join(process.argv[4],'scripts/workflow-state-machine.js'),'resolve-action','--project-root',root,'--input','2','--pending-action-id',pending.id,'--visible-choice-hash',pending.visible_choice_hash,'--state-version',String(saved.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
if(revise.status!==0) throw new Error(revise.stdout||revise.stderr);
const reviseOut=JSON.parse(revise.stdout),awaiting=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(reviseOut.status!=='feedback_proposal_revision_input_requested'||String(((reviseOut.visible_response||{}).text)||'').includes('不会执行当前方案')===false) throw new Error(revise.stdout);
if((awaiting.proposal_revision_input||{}).status!=='awaiting_chat'||awaiting.proposal_revision_input.proposal_id!==proposal.proposal_id) throw new Error(JSON.stringify(awaiting.proposal_revision_input));
if((awaiting.proposed_plan||{}).status!=='awaiting_user_confirmation'||awaiting.stage_execution!==null) throw new Error(JSON.stringify(awaiting));
const premature=cp.spawnSync(process.execPath,[path.join(process.argv[4],'scripts/workflow-state-machine.js'),'resolve-action','--project-root',root,'--input','1','--bind-current','--json'],{encoding:'utf8'});
if(premature.status!==0) throw new Error(premature.stdout||premature.stderr);
const prematureOut=JSON.parse(premature.stdout),stillAwaiting=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(prematureOut.status!=='feedback_proposal_revision_input_required'||stillAwaiting.stage_execution!==null||(stillAwaiting.proposed_plan||{}).status!=='awaiting_user_confirmation') throw new Error(premature.stdout);
const amendment='删除第二项，把冲突结果改成公开复核。';
const amended=cp.spawnSync(process.execPath,[path.join(process.argv[4],'scripts/workflow-state-machine.js'),'resolve-action','--project-root',root,'--input',amendment,'--json'],{encoding:'utf8'});
if(amended.status!==0) throw new Error(amended.stdout||amended.stderr);
const amendedOut=JSON.parse(amended.stdout),requeued=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const amendmentItem=((requeued.pending_feedback||{}).items||[]).find(item=>item.text===amendment)||{};
if(amendedOut.status!=='short_feedback_impact_started'||requeued.current_stage!=='feedback_impact_sync') throw new Error(amended.stdout);
if(amendmentItem.source_kind!=='user_proposal_revision'||(requeued.proposal_revision_input||{}).status!=='feedback_received') throw new Error(JSON.stringify({amendmentItem,proposal_revision_input:requeued.proposal_revision_input}));
if((requeued.proposed_plan||{}).status!=='superseded_pending_reanalysis'||(requeued.accepted_plan||{}).proposal_id===proposal.proposal_id) throw new Error(JSON.stringify(requeued));
const validation=cp.spawnSync(process.execPath,[path.join(process.argv[4],'scripts/workflow-state-validate.js'),'--project-root',root,'--json'],{encoding:'utf8'});
if(validation.status!==0||JSON.parse(validation.stdout).status==='blocked') throw new Error(validation.stdout||validation.stderr);
NODE
}

@test "stale running feedback impact contract returns one deterministic recovery command" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：更新结局。" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2],task=JSON.parse(fs.readFileSync(file,'utf8'));
task.stage_execution.write_set=[];task.stage_execution.execution_command='';task.stage_execution.stage_completion_command='';task.stage_execution.after_write_action=null;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" next-candidates --project-root "$TMP_DIR/book" --compact --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" > "$TMP_DIR/stale-feedback-contract.json"
    node - "$TMP_DIR/stale-feedback-contract.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),visible=out.visible_response||{};
if(out.status!=='stage_contract_recovery_ready'||visible.render_mode!=='silent_execute') throw new Error(JSON.stringify(out));
if(!String(out.execution_command||'').includes('resume-pending-short-feedback')) throw new Error(JSON.stringify(out));
if(String(out.execution_command||'')!==String(visible.execution_command||'')) throw new Error(JSON.stringify(out));
NODE
}

@test "feedback impact completion rejects a result from another feedback batch" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    printf '%s\n' '{"project_id":"feedback-identity-test","project_title":"反馈身份测试","plan_revision":1}' > "$TMP_DIR/book/追踪/private-short-extension/project-state.json"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：更新结局。" --json > "$TMP_DIR/feedback-start.json"
    ln -s "$REPO/scripts" "$TMP_DIR/book/scripts"
    node - "$TMP_DIR/feedback-start.json" "$TMP_DIR/book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),root=process.argv[3],execution=out.stage_execution||{};
const packet=execution.expected_result_packet,taskFile=path.join(root,'追踪/workflow/tasks',out.workflow_id,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const result={schemaVersion:'1.0.0',workflow_id:task.workflow_id,workflow_type:task.workflow_type,owner_module:execution.owner_module,stage_id:'feedback_impact_sync',step_id:'feedback_impact_sync',step_status:'completed',outputs:[],changed_files:[],evidence:[],verification_result:'pass',checkpoint_state:{completed_stage:'feedback_impact_sync'},output_health_result:'pass',feedback_id:'feedback-batch-from-another-turn',impact_level:'planning',affected_sections:[1],affected_assets:['小节大纲.md'],downstream_impact:{invalidate_briefs:[1]},revision_groups:[],next_stage_id:'feedback_apply_patch',result_packet_path:packet};
fs.mkdirSync(path.dirname(path.join(root,packet)),{recursive:true});fs.writeFileSync(path.join(root,packet),JSON.stringify(result,null,2)+'\n');
const applied=cp.spawnSync(execution.stage_completion_command,{cwd:root,encoding:'utf8',shell:true});
const response=JSON.parse(applied.stdout),saved=JSON.parse(fs.readFileSync(taskFile,'utf8'));
if(applied.status===0||response.status!=='blocked_short_feedback_identity_mismatch') throw new Error(JSON.stringify({status:applied.status,response}));
if(saved.current_stage!=='feedback_impact_sync'||saved.short_feedback_impact||saved.proposed_plan) throw new Error(JSON.stringify(saved));
NODE
}

@test "running feedback impact normalizes a stale host command to the authoritative completion command" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "整篇回炉：更新结局。" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2],task=JSON.parse(fs.readFileSync(file,'utf8'));
task.stage_execution.execution_command='node scripts/workflow-stage-controller.js advance --project-root . --workflow-id stale --result stale.json --json';
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    node "$SCRIPT" next-candidates --project-root "$TMP_DIR/book" --compact --json > "$TMP_DIR/normalized-feedback-command.json"
    node - "$TMP_DIR/normalized-feedback-command.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),execution=out.stage_execution||{};
if(out.status!=='stage_execution_resume_ready') throw new Error(JSON.stringify(out));
if(!/workflow-state-machine\.js apply-result/.test(String(execution.execution_command||''))) throw new Error(JSON.stringify(execution));
if(execution.execution_command!==execution.stage_completion_command||(execution.after_write_action||{}).command!==execution.stage_completion_command) throw new Error(JSON.stringify(execution));
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

@test "pending planning feedback recovery returns to the bound proposal menu before canonical writes" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
const feedbackId='feedback-current-plan';
task.current_stage='next_section_brief';task.current_step='next_section_brief';task.status='running';
task.pending_feedback={feedback_id:feedbackId,text:'第7节补足关键决策人的当面对质，再回写设定和小节大纲。',scope_snapshot:'第7节',status:'pending'};
task.short_feedback_impact={status:'ok',feedback_id:feedbackId,impact_level:'planning',affected_sections:[7],affected_assets:['设定.md','小节大纲.md'],downstream_impact:{invalidate_briefs:['写作Brief_第007节.md'],recheck_prose:['正文/第007节.md']}};
task.proposed_plan={schema_version:'1.0.0',proposal_id:'proposal.feedback-current-plan',status:'awaiting_user_confirmation',feedback_id:feedbackId,summary:'补足关键决策人的当面对质并重建第7节规划。',requirements:[{requirement_id:'req-current',text:'关键决策人必须当面承认知情与越权操作。',impact_level:'planning'}],impact_level:'planning',affected_sections:[7]};
task.accepted_plan={plan_id:'accepted-plan.feedback-current-plan',proposal_id:'proposal.feedback-current-plan.v1',feedback_id:feedbackId,status:'accepted_pending_projection',projection_status:'pending'};
task.feedback_revision_queue={status:'running',current_section_index:4,items:[{section_index:4,status:'current',brief_status:'pending',prose_status:'pending_recheck'}]};
task.pending_action=null;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    local workflow_id
    workflow_id="$(jq -r '.workflow_id' "$task_file")"

    run node "$SCRIPT" resume-pending-short-feedback --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/resumed-proposal.json"
    node - "$TMP_DIR/resumed-proposal.json" "$task_file" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='workflow_choice_required'||out.target_stage!=='feedback_apply_patch') throw new Error(JSON.stringify(out));
if(task.current_stage!=='feedback_apply_patch'||task.stage_execution!==null) throw new Error(JSON.stringify(task.stage_execution));
if(task.proposed_plan.status!=='awaiting_user_confirmation'||task.accepted_plan.proposal_id!=='proposal.feedback-current-plan.v1') throw new Error(JSON.stringify(task));
const options=(task.pending_action||{}).options||[];
if(options.length!==4||options[0].target_stage!=='feedback_apply_patch'||options[0].requires_user_confirm!==true) throw new Error(JSON.stringify(options));
const visibleOptions=(out.visible_response||{}).options||[];
if((visibleOptions[0]||{}).target_stage!=='feedback_apply_patch'||(visibleOptions[0]||{}).requires_user_confirm!==true) throw new Error(JSON.stringify(visibleOptions));
if((visibleOptions[0]||{}).label!=='确认并执行当前回写方案（推荐）'||(visibleOptions[1]||{}).label!=='进入 Chat 修改或补充方案'||(visibleOptions[2]||{}).label!=='查看当前方案、影响范围与依据') throw new Error(JSON.stringify(visibleOptions));
if((out.visible_response||{}).work_queue!==null||String((out.visible_response||{}).text||'').includes('本轮整篇回炉')) throw new Error(JSON.stringify(out.visible_response));
if(!String((out.visible_response||{}).text||'').includes('1.')||String((out.visible_response||{}).text||'').includes('回复“继续”')) throw new Error(JSON.stringify(out.visible_response));
NODE

    run node "$SCRIPT" next-candidates --project-root "$TMP_DIR/book" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/reentered-proposal.json"
    node - "$TMP_DIR/reentered-proposal.json" <<'NODE'
const fs=require('fs'),out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),text=String(((out.visible_response||{}).text)||'');
if(!text.includes('补足关键决策人的当面对质并重建第7节规划。')||!text.includes('确认并执行当前回写方案（推荐）')||!text.includes('进入 Chat 修改或补充方案')) throw new Error(text);
NODE

    node - "$SCRIPT" "$TMP_DIR/book" "$task_file" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');const [script,root,file]=process.argv.slice(2);const task=JSON.parse(fs.readFileSync(file,'utf8'));const pending=task.pending_action;
const run=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',pending.id,'--visible-choice-hash',pending.visible_choice_hash,'--state-version',String(task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);const out=JSON.parse(run.stdout),updated=JSON.parse(fs.readFileSync(file,'utf8'));
if(out.status!=='stage_started'||updated.stage_execution.status!=='running') throw new Error(run.stdout);
if(updated.accepted_plan.feedback_id!=='feedback-current-plan'||updated.proposed_plan.status!=='accepted') throw new Error(JSON.stringify(updated));
const confirmation=updated.stage_execution.confirmation_context||{};
if(confirmation.selection_id!==pending.id||!confirmation.visible_choice_hash||Date.parse(confirmation.expires_at)<=Date.now()) throw new Error(JSON.stringify(confirmation));
const validation=cp.spawnSync(process.execPath,[path.join(path.dirname(script),'workflow-state-validate.js'),'--project-root',root,'--json'],{encoding:'utf8'});
if(validation.status!==0||JSON.parse(validation.stdout).status==='blocked') throw new Error(validation.stdout||validation.stderr);
NODE
}

@test "feedback proposal choice rejects a proposal changed after the menu was rendered" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "第7节" --user-goal "新开短篇" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.pending_feedback={feedback_id:'feedback-current',text:'重做当前 Brief',status:'pending',impact_level_hint:'current_brief',section_index:7,items:[]};
task.short_feedback_impact={status:'ok',feedback_id:'feedback-current',impact_level:'current_brief',affected_sections:[7],affected_assets:['Brief/第007节.md']};
task.proposed_plan={proposal_id:'proposal-current',feedback_id:'feedback-current',status:'awaiting_user_confirmation',summary:'只重做第7节 Brief'};
task.accepted_plan={feedback_id:'feedback-old',proposal_id:'proposal-old',status:'accepted_pending_projection'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    local workflow_id
    workflow_id="$(jq -r '.workflow_id' "$task_file")"
    node "$SCRIPT" resume-pending-short-feedback --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --json >/dev/null
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.proposed_plan={proposal_id:'proposal-old',feedback_id:'feedback-old',status:'awaiting_user_confirmation',summary:'旧方案'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input 1 --bind-current --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_feedback_proposal_binding_mismatch'* ]]
    [ "$(jq -r '.stage_execution // ""' "$task_file")" = "" ]
    [ "$(jq -r '.accepted_plan.feedback_id' "$task_file")" = "feedback-old" ]
}

@test "pending expression-only short feedback resumes section repair without impact reanalysis" {
    mkdir -p "$TMP_DIR/book"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --scope "第1节" --user-goal "新开短篇" --json >/dev/null
    local task_file
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');const file=process.argv[2];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='next_section_brief';task.current_step='next_section_brief';
task.pending_feedback={
  feedback_id:'feedback-expression-current',
  text:'“这句话很不对，帮我改一下。”',
  impact_level_hint:'expression_only',
  section_index:1,
  scope_snapshot:'第1节',
  status:'pending',
  items:[{
    feedback_id:'feedback-expression-current-item',
    text:'“这句话很不对，帮我改一下。”',
    impact_level_hint:'expression_only',
    section_index:1,
    scope_snapshot:'第1节',
    status:'pending'
  }]
};
task.short_feedback_impact={status:'ok',feedback_id:'older-feedback',impact_level:'planning'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    local workflow_id
    workflow_id="$(jq -r '.workflow_id' "$task_file")"
    run node "$SCRIPT" resume-pending-short-feedback --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"target_stage": "section_repair_loop"'* ]]
    [ "$(jq -r '.short_feedback_impact.recovered_from_pending_hint' "$task_file")" = "true" ]
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
const feedbackId=task.pending_feedback.feedback_id,proposalId=`proposal.${feedbackId}`;
task.current_stage='feedback_apply_patch';task.current_step='feedback_apply_patch';
task.short_feedback_impact={status:'ok',feedback_id:feedbackId,impact_level:'planning'};
task.proposed_plan={proposal_id:proposalId,feedback_id:feedbackId,status:'accepted',summary:'更新设定和小节大纲'};
task.accepted_plan={plan_id:`accepted-plan.${feedbackId}`,feedback_id:feedbackId,proposal_id:proposalId,status:'accepted_pending_projection'};
task.stage_execution={status:'running',stage_id:'feedback_apply_patch',step_id:'feedback_apply_patch',execution_command:'node scripts/short-planning-stage-finalize.js --project-root . --apply --json'};
task.pending_action={id:'pa-feedback-apply',status:'resolved',feedback_id:feedbackId,proposal_id:proposalId,options:[{number:1,action_id:'continue_next_stage',target_stage:'feedback_apply_patch'}]};
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
    printf '%s\n' "$output" > "$TMP_DIR/silent-next-candidates.json"
    node - "$TMP_DIR/silent-next-candidates.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const execution=out.stage_execution||{},visible=out.visible_response||{};
if(execution.stage_completion_command!=='node scripts/test-stage.js --json') throw new Error(JSON.stringify(execution));
if(execution.current_required_action!=='edit_write_set') throw new Error(JSON.stringify(execution));
if((execution.after_write_action||{}).command!==execution.stage_completion_command) throw new Error(JSON.stringify(execution));
if(out.presentation_allowed!==false||visible.user_visible!==false) throw new Error(JSON.stringify(out));
if('text' in visible) throw new Error(JSON.stringify(visible));
NODE
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
    node "$SCRIPT" resolve-action --project-root "$TMP_DIR/book" --input "主管的动机与小节大纲冲突，先改设定和小节大纲再重写本节" --json > "$TMP_DIR/free-feedback.json"
    node - "$TMP_DIR/free-feedback.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='short_feedback_impact_started' || out.target_stage!=='feedback_impact_sync') throw new Error(JSON.stringify(out));
if(task.current_stage!=='feedback_impact_sync' || task.stage_execution.status!=='running') throw new Error(JSON.stringify(task));
if(!task.pending_feedback || !/主管的动机/.test(task.pending_feedback.text)) throw new Error(JSON.stringify(task.pending_feedback));
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
    grep -q "presentation_allowed=false" "$WORKFLOW"
    grep -q "terminal_reply_allowed_on" "$WORKFLOW"
    grep -q "质量失败先在当前写集内修订一次" "$WORKFLOW"
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
    mkdir -p "$TMP_DIR/book/追踪/story-system/short"
    canonical_hash="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    mkdir -p "$TMP_DIR/book/追踪/story-system/commits"
    accepted_at="2099-01-01T00:00:00Z"
    cat > "$TMP_DIR/book/追踪/story-system/commits/section-001.json" <<JSON
{"commit_id":"section-001","workflow_id":"wf-short-gate-pass","status":"accepted","accepted_at":"$accepted_at","volume":"短篇正文","chapter":1,"artifacts":[{"target":"正文.md","after_hash":"sha256:$canonical_hash"}]}
JSON
    cat > "$TMP_DIR/book/追踪/story-system/short/section-001-anchor.json" <<JSON
{"workflow_id":"wf-short-gate-pass","section_index":1,"status":"accepted","canonical_path":"正文.md","canonical_sha256":"$canonical_hash","section_commit_id":"section-001","quality_result":{"machine_gate":"pass","story_value_gate":"pass","repetition_gate":"pass","length_policy":{"blocking":false,"verdict":"baseline_not_established"}}}
JSON
    cat > "$TMP_DIR/book/追踪/story-system/short/project-state.json" <<'JSON'
{"current_section_index":2,"accepted_sections":[{"section_index":1,"anchor_path":"追踪/story-system/short/section-001-anchor.json"}]}
JSON
    anchor_packet="$(jq -r '.stage_execution.expected_result_packet' "$(focused_task_file "$TMP_DIR/book")")"
    mkdir -p "$(dirname "$TMP_DIR/book/$anchor_packet")"
    cat > "$TMP_DIR/book/$anchor_packet" <<JSON
{
  "workflow_id": "wf-short-gate-pass",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "section_accept_anchor",
  "step_id": "section_accept_anchor",
  "step_status": "completed",
  "verification_result": "pass",
  "outputs": ["正文.md", "追踪/story-system/short/section-001-anchor.json"],
  "evidence": ["追踪/story-system/commits/section-001.json"],
  "checkpoint_state": {"stage": "section_accept_anchor", "section_index": 1},
  "output_health_result": "pass",
  "planned_sections": 2,
  "result_packet_path": "$anchor_packet",
  "section_acceptance": {
    "workflow_id": "wf-short-gate-pass",
    "section_index": 1,
    "anchor_path": "追踪/story-system/short/section-001-anchor.json",
    "canonical_path": "正文.md",
    "canonical_sha256": "$canonical_hash",
    "section_commit_id": "section-001",
    "planned_sections": 2
  },
  "changed_files": ["正文.md", "追踪/story-system/short/section-001-anchor.json"]
}
JSON
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/book/$anchor_packet" --json > "$TMP_DIR/anchor-out.json" || { cat "$TMP_DIR/anchor-out.json" >&2; false; }
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
    node - "$TMP_DIR/book/追踪/story-system/short/project-state.json" <<'NODE'
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (state.current_section_index !== 2) throw new Error(JSON.stringify({ current_section_index: state.current_section_index }));
NODE

    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-gate-pass/task.json" <<'JSON'
{
  "workflow_id": "wf-short-gate-pass",
  "workflow_type": "private_short_startup",
  "workflow_contract_version": 2,
  "result_contract_version": 2,
  "task_dir": "追踪/workflow/tasks/wf-short-gate-pass",
  "status": "running",
  "scope": "第1节",
  "current_stage": "section_accept_anchor",
  "current_step": "section_accept_anchor",
  "task_family_id": "tf-short-gate-pass",
  "branch_id": "wf-short-gate-pass",
  "machine": {
    "completed_stages": ["quality_gate"],
    "remaining_stages": ["section_accept_anchor", "next_section_brief"]
  },
  "runtime_guard": {
    "heartbeat": {"updated_at": "2026-07-27T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "current_stage"}
  },
  "stage_execution": {
    "status": "running",
    "stage_id": "section_accept_anchor",
    "step_id": "section_accept_anchor",
    "stage_attempt_id": "sa-short-gate-pass-accept",
    "expected_result_packet": "追踪/workflow/tasks/wf-short-gate-pass/result-packets/section_accept_anchor.section-001.result.json"
  }
}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-short-gate-pass","task_dir":"追踪/workflow/tasks/wf-short-gate-pass","state_version":1}
JSON
    mkdir -p "$TMP_DIR/book/追踪/workflow/task-families"
    cat > "$TMP_DIR/book/追踪/workflow/task-families/tf-short-gate-pass.json" <<'JSON'
{"schemaVersion":"1.0.0","task_family_id":"tf-short-gate-pass","head_workflow_id":"wf-short-gate-pass","branches":[{"workflow_id":"wf-short-gate-pass","status":"active"}]}
JSON
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --workflow-id wf-short-gate-pass --result "$TMP_DIR/book/$anchor_packet" --compact --json > "$TMP_DIR/anchor-v2-out.json" || { cat "$TMP_DIR/anchor-v2-out.json" >&2; false; }
    node - "$TMP_DIR/anchor-v2-out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'stage_started' || out.current_stage !== 'next_section_brief') throw new Error(JSON.stringify(out));
if (out.task) throw new Error('compact apply-result must not print full task');
if (JSON.stringify(out).includes('stage_context_packet')) throw new Error('compact apply-result leaked stage context packet');
if (!out.stage_execution || !out.stage_execution.expected_result_packet) throw new Error(JSON.stringify(out));
NODE
    node - "$TMP_DIR/book/追踪/story-system/short/project-state.json" <<'NODE'
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (state.current_section_index !== 2) throw new Error(JSON.stringify({ current_section_index: state.current_section_index }));
if (state.last_accepted_section_index !== 1) throw new Error(JSON.stringify({ last_accepted_section_index: state.last_accepted_section_index }));
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
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-short-legacy/result-packets"
    printf '%s\n' '唯一候选正文' > "$TMP_DIR/book/正文.md"
    before="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    node - "$REPO/tests/fixtures/workflow-v3/legacy-v2/planning-confirmed.json" "$TMP_DIR/book" <<'NODE'
const fs=require('fs'),path=require('path');
const [fixtureFile,root]=process.argv.slice(2),workflowId='wf-short-legacy';
const task=JSON.parse(fs.readFileSync(fixtureFile,'utf8'));
task.workflow_id=workflowId;
task.task_dir=`追踪/workflow/tasks/${workflowId}`;
task.stage_execution.stage_attempt_id=`sa-${workflowId}-fixture`;
task.stage_execution.expected_result_packet=`${task.task_dir}/result-packets/next_section_brief.section-002.result.json`;
const taskFile=path.join(root,task.task_dir,'task.json');
fs.mkdirSync(path.dirname(taskFile),{recursive:true});
fs.writeFileSync(taskFile,`${JSON.stringify(task,null,2)}\n`);
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),`${JSON.stringify({schemaVersion:'1.0.0',workflow_id:workflowId,task_dir:task.task_dir,state_version:task.state_version},null,2)}\n`);
NODE

    node "$SCRIPT" migrate-short-lean-workflow --project-root "$TMP_DIR/book" --workflow-id wf-short-legacy --json > "$TMP_DIR/dry.json"
    grep -q '"status": "v3_migration_preview"' "$TMP_DIR/dry.json"
    grep -q '"target_stage": "section_brief"' "$TMP_DIR/dry.json"
    grep -q '"creative_assets_modified": false' "$TMP_DIR/dry.json"

    node "$SCRIPT" migrate-short-lean-workflow --project-root "$TMP_DIR/book" --workflow-id wf-short-legacy --confirm --json > "$TMP_DIR/migrated.json"
    after="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    [ "$before" = "$after" ]
    node - "$TMP_DIR/migrated.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(out.status!=='v3_migration_applied'||out.migrated!==true) throw new Error(JSON.stringify(out));
if(task.workflow_type!=='short_write'||task.engine_version!==3||task.current_stage!=='section_brief') throw new Error(JSON.stringify(task));
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
for (const id of ['master_outline_review', 'volume_outline_review', 'detail_outline_review', 'brief_review', 'prose_acceptance', 'milestone_review', 'volume_acceptance', 'book_acceptance']) {
  if (longStages[id].write_set.length !== 0) {
    throw new Error(`long review stage ${id} must be result-packet-only: ${JSON.stringify(longStages[id].write_set)}`);
  }
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
  "changed_files": []
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
if (stages.platform_genre_lock.requires_user_confirm) throw new Error('platform_genre_lock must not add a second author stop after setting confirmation');
if (!stages.platform_genre_lock.allowed_next.includes('rhythm_pattern_selection')) throw new Error('platform_genre_lock must enter rhythm selection');
if (!stages.rhythm_pattern_selection.required_inputs.includes('platform_genre_lock')) throw new Error('rhythm pattern must require platform_genre_lock');
if (stages.rhythm_pattern_selection.requires_user_confirm) throw new Error('rhythm pattern selection must stay inside the outline author phase');
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
for (const id of ['short_setting', 'platform_genre_lock']) {
  if (stages[id].interaction_contract.author_phase.label !== '设定与人物') throw new Error(`${id} author phase drifted`);
}
for (const id of ['rhythm_pattern_selection', 'section_outline', 'section_plan_lock', 'short_structure_impact_audit', 'hook_value_gate']) {
  if (stages[id].interaction_contract.author_phase.label !== '节奏与全篇小节大纲') throw new Error(`${id} author phase drifted`);
}
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
        number:1, action_id:'write_sections', label:'继续写第 6-7 节', target_stage:'draft_next_section', target_scope:'第6-7节', max_units:2,
        stop_after:'第7节', completion_boundary:'stop_after_target_scope', risk_level:'high'
      },
      {
        number:2, action_id:'write_one_section_then_stop', label:'只写第 6 节，写完停下让我看', target_stage:'draft_next_section', target_scope:'第6节',
        target_files:['正文.md'], max_units:1, stop_after:'第6节', completion_boundary:'stop_after_target_scope',
        forbidden_interpretations:['pause_before_writing','review_sections_4_5','write_sections_6_7'], risk_level:'high'
      },
      {
        number:3, action_id:'review_sections', label:'先看 4-5 节，有意见再继续', target_stage:'draft_next_section', target_scope:'第4-5节',
        max_units:0, stop_after:'review_only', risk_level:'low'
      }
    ], free_text_enabled:true
};
const stable=JSON.stringify({id:task.pending_action.id,question:task.pending_action.question,options:task.pending_action.options.map(x=>({number:x.number,action_id:x.action_id,label:x.label,target_stage:x.target_stage||'',target_scope:x.target_scope||''}))});
task.pending_action.visible_choice_hash=crypto.createHash('sha256').update(stable).digest('hex');
task.pending_action.pending_action_id=task.pending_action.id; task.pending_action.state_version=task.state_version; task.pending_action.book_root=root;
const text=JSON.stringify(task,null,2)+'\n'; fs.writeFileSync(current,text);
NODE

    run resolve_action "$TMP_DIR/book" 2
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$(focused_task_file "$TMP_DIR/book")" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'blocked_short_plan_incomplete') throw new Error(`unexpected status: ${out.status}`);
if (out.target_stage !== 'draft_next_section') throw new Error(`wrong target stage: ${out.target_stage}`);
if (task.last_selection.action_id !== 'write_one_section_then_stop') throw new Error('last_selection action not persisted');
if (task.last_selection.target_scope !== '第6节') throw new Error('last_selection scope not persisted');
if (task.last_selection.execution_contract.max_units !== 1) throw new Error('max_units boundary not persisted');
if (task.last_selection.execution_contract.stop_after !== '第6节') throw new Error('stop_after boundary not persisted');
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
    prepare_long_chapter_v2_targets "$TMP_DIR/book" 1
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
if (out.interaction_contract !== 'continue_confirmed_internal_stage') throw new Error(JSON.stringify(out));
if (((out.stage_execution||{}).stage_id) !== 'chapter_commit') throw new Error(JSON.stringify(out.stage_execution));
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
    prepare_long_chapter_v2_targets "$TMP_DIR/book" 1
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
  "accepted_detail_outline_targets": [
    {"outline_path":"大纲/第2卷/细纲_第001章.md","outline_sha256":"1111111111111111111111111111111111111111111111111111111111111111"},
    {"outline_path":"大纲/第2卷/细纲_第002章.md","outline_sha256":"2222222222222222222222222222222222222222222222222222222222222222"},
    {"outline_path":"大纲/第2卷/细纲_第003章.md","outline_sha256":"3333333333333333333333333333333333333333333333333333333333333333"}
  ],
  "active_chapter_target": {"outline_path":"大纲/第2卷/细纲_第001章.md","outline_sha256":"1111111111111111111111111111111111111111111111111111111111111111"},
  "consumed_detail_outline_targets": [],
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
    prepare_long_chapter_v2_targets "$TMP_DIR/book" 3
    write_v2_transactional_commit_result "$TMP_DIR/book" "$TMP_DIR/next-chapter-result.json" chapter_brief

    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/next-chapter-result.json" --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" > "$TMP_DIR/next-chapter-out.json"

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
if((task.active_chapter_target||{}).outline_path!=='大纲/第2卷/细纲_第002章.md') throw new Error(`next target did not advance: ${JSON.stringify(task.active_chapter_target)}`);
if(JSON.stringify((task.consumed_detail_outline_targets||[]).map((item)=>item.outline_path))!==JSON.stringify(['大纲/第2卷/细纲_第001章.md'])) throw new Error(`consumed targets wrong: ${JSON.stringify(task.consumed_detail_outline_targets)}`);
if(((task.stage_execution||{}).chapter_target||{}).outline_path!=='大纲/第2卷/细纲_第002章.md') throw new Error(`next brief did not bind target: ${JSON.stringify(task.stage_execution)}`);
NODE

    for stage in chapter_brief brief_review prose prose_acceptance; do
        node - "$TMP_DIR/book" "$stage" <<'NODE'
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[2]),stage=process.argv[3],expected='大纲/第2卷/细纲_第002章.md';
if(task.current_stage!==stage) throw new Error(`expected ${stage}, got ${task.current_stage}`);
if((task.active_chapter_target||{}).outline_path!==expected||(task.stage_execution.chapter_target||{}).outline_path!==expected) throw new Error(JSON.stringify({active:task.active_chapter_target,execution:task.stage_execution}));
NODE
        advance_long_write_stage "$TMP_DIR/book"
    done

    write_v2_transactional_commit_result "$TMP_DIR/book" "$TMP_DIR/book/second-chapter-commit.result.json" chapter_brief
    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/book/second-chapter-commit.result.json" --json > "$TMP_DIR/second-chapter-commit.out.json"
    node - "$TMP_DIR/second-chapter-commit.out.json" <<'NODE'
const fs=require('fs'),out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),consumed=(out.task.consumed_detail_outline_targets||[]).map((item)=>item.outline_path);
if(out.task.current_stage!=='chapter_brief'||(out.task.active_chapter_target||{}).outline_path!=='大纲/第2卷/细纲_第003章.md') throw new Error(JSON.stringify(out.task));
if(JSON.stringify(consumed)!==JSON.stringify(['大纲/第2卷/细纲_第001章.md','大纲/第2卷/细纲_第002章.md'])) throw new Error(JSON.stringify(consumed));
if((out.task.stage_execution.chapter_target||{}).outline_path!=='大纲/第2卷/细纲_第003章.md') throw new Error(JSON.stringify(out.task.stage_execution));
NODE
}

@test "long V2 apply-result rejects target drift in all five stages and consumes only the accepted commit target" {
    book="$TMP_DIR/long-v2-target-loop"
    prepare_detail_outline_review "$book"
    apply_detail_outline_quality_result "$book" pass >/dev/null

    for stage in chapter_brief brief_review prose prose_acceptance; do
        current_stage="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(t.current_stage)" "$book")"
        [ "$current_stage" = "$stage" ] || { echo "expected $stage, got $current_stage"; false; }
        stage_status="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(String((t.stage_execution||{}).status||''))" "$book")"
        if [ "$stage_status" != "running" ]; then
            resolve_action "$book" 1 >/dev/null
        fi

        if [ "$stage" = "brief_review" ]; then
            node - "$book" <<'NODE'
const fs=require('fs'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
task.stage_execution.write_set=['追踪/workflow/tasks/wrong-target.md'];
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
            run apply_long_write_v2_result "$book"
            [ "$status" -eq 2 ]
            [[ "$output" == *'blocked_long_chapter_write_set_mismatch'* ]]
            node - "$book" <<'NODE'
const fs=require('fs'),fixture=require(process.env.WORKFLOW_TASK_FIXTURE),root=process.argv[2],file=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
task.stage_execution.write_set=[];
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
        fi

        run apply_long_write_v2_result "$book" "" completed pass "" "" "" "" global_chapter_no
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_chapter_target_echo_mismatch'* ]]
        [ "$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(t.current_stage)" "$book")" = "$stage" ]

        if [ "$stage" = "chapter_brief" ]; then
            contract="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(t.active_chapter_target.contract_path)" "$book")"
            mkdir -p "$book/$(dirname "$contract")"
            printf '%s\n' '# 当前章 Brief' '' '- 目标字数：100' '- 合法区间：90—120' > "$book/$contract"
            apply_long_write_v2_result "$book" "" completed pass "" "" "" "$contract" >/dev/null
        elif [ "$stage" = "prose" ]; then
            candidate="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(t.active_chapter_target.candidate_draft_path)" "$book")"
            mkdir -p "$book/$(dirname "$candidate")"
            node - "$book/$candidate" <<'NODE'
const fs=require('fs');fs.writeFileSync(process.argv[2],'汉'.repeat(100));
NODE
            apply_long_write_v2_result "$book" "" completed pass "" "" "" "$candidate" >/dev/null
        else
            advance_long_write_stage "$book"
        fi
    done

    [ "$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(t.current_stage)" "$book")" = "chapter_commit" ]
    stage_status="$(node -e "const t=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]);process.stdout.write(String((t.stage_execution||{}).status||''))" "$book")"
    if [ "$stage_status" != "running" ]; then
        resolve_action "$book" 1 >/dev/null
    fi
    run apply_long_write_v2_result "$book" "" completed pass "" "" "" "" global_chapter_no
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_chapter_target_echo_mismatch'* ]]

    node - "$book" "$SCRIPT" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),cp=require('child_process');
const root=process.argv[2],script=process.argv[3],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),task=fixture.readFocusedTask(root),target=task.active_chapter_target;
if(!target||task.current_stage!=='chapter_commit') throw new Error(JSON.stringify(task));
const candidateFile=path.join(root,target.candidate_draft_path),canonicalFile=path.join(root,target.draft_path);
fs.mkdirSync(path.dirname(canonicalFile),{recursive:true});fs.copyFileSync(candidateFile,canonicalFile);
const afterHash=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(canonicalFile)).digest('hex')}`;
const transactionId='tx-v2-target-001',transactionRel=`追踪/story-system/transactions/${transactionId}/transaction.json`,transactionFile=path.join(root,transactionRel);
fs.mkdirSync(path.dirname(transactionFile),{recursive:true});
fs.writeFileSync(transactionFile,JSON.stringify({schemaVersion:'1.0.0',transaction_id:transactionId,status:'accepted',workflow_id:task.workflow_id,volume:target.volume,chapter:target.volume_chapter_no,artifacts:[{role:'chapter_prose',source_staged:target.candidate_draft_path,target:target.draft_path,content_hash:afterHash}]}));
const commitId='chapter-v2target-001-abcdef1234',commitRel=`追踪/story-system/commits/${commitId}.json`,commitFile=path.join(root,commitRel);
fs.mkdirSync(path.dirname(commitFile),{recursive:true});
fs.writeFileSync(commitFile,JSON.stringify({schemaVersion:'1.0.0',commit_id:commitId,transaction_id:transactionId,status:'accepted',workflow_id:task.workflow_id,volume:target.volume,chapter:target.volume_chapter_no,artifacts:[{role:'chapter_prose',target:target.draft_path,after_hash:afterHash}]}));
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find((node)=>node.id===task.current_stage);
const result={
  workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'chapter_commit',step_id:task.current_step,step_status:'completed',
  owner_module:lifecycleNode.owner_module,lifecycle_node:lifecycleNode.id,asset_target:lifecycleNode.asset_target,review_requirement:lifecycleNode.review_requirement,
  outputs:[],changed_files:[target.draft_path],evidence:[],verification_result:'pass',checkpoint_state:{stage:'chapter_commit'},output_health_result:'pass',
  memory_read_receipt:(((task.stage_execution||{}).memory_context||{}).memory_read_receipt)||null,
  asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},review_decision:'not_applicable',downstream_effects:[],
  lifecycle_transition_request:{action:'advance',target:'chapter_commit'},result_write_set:[target.draft_path],chapter_target:target,
  chapter_commit:{mode:'transactional',accepted_commit_id:commitId,commit_file:commitRel,projection_status:'projection_current',projection_debt:false,staged_artifacts:[target.candidate_draft_path]},
};
const packet=path.join(root,task.stage_execution.expected_result_packet);fs.mkdirSync(path.dirname(packet),{recursive:true});fs.writeFileSync(packet,JSON.stringify(result,null,2));
const applied=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',packet,'--json'],{encoding:'utf8'});
if(applied.status===0) throw new Error('forged accepted transaction without durable provenance was trusted');
if(!String(applied.stdout||applied.stderr).includes('blocked_canonical_transaction_attempt_mismatch')) throw new Error(applied.stdout||applied.stderr);

const manifestFile=path.join(root,'追踪/staging/v2-chapter-manifest.json');
fs.mkdirSync(path.dirname(manifestFile),{recursive:true});
fs.writeFileSync(manifestFile,JSON.stringify({
  workflow_id:task.workflow_id,volume:target.volume,chapter:target.volume_chapter_no,
  gates:{output_health:'pass',prose_quality:'pass',story_drift:'pass'},
  artifacts:[{role:'chapter_prose',staged:target.candidate_draft_path,target:target.draft_path}]
}));
const commitScript=path.join(path.dirname(script),'chapter-commit.js');
const prepared=cp.spawnSync(process.execPath,[commitScript,'prepare','--project-root',root,'--manifest',manifestFile,'--json'],{encoding:'utf8'});
if(prepared.status!==0) throw new Error(prepared.stdout||prepared.stderr);
const preparedOutput=JSON.parse(prepared.stdout);
const accepted=cp.spawnSync(process.execPath,[commitScript,'accept','--project-root',root,'--transaction',preparedOutput.transaction_id,'--json'],{encoding:'utf8'});
if(accepted.status!==0) throw new Error(accepted.stdout||accepted.stderr);
const acceptedOutput=JSON.parse(accepted.stdout);
fs.unlinkSync(manifestFile);
result.chapter_commit={
  mode:'transactional',accepted_commit_id:acceptedOutput.commit_id,
  commit_file:path.relative(root,acceptedOutput.commit_file).replace(/\\/g,'/'),
  projection_status:acceptedOutput.projection_status,projection_debt:false,
  staged_artifacts:[target.candidate_draft_path]
};
fs.writeFileSync(packet,JSON.stringify(result,null,2));
const verified=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',packet,'--json'],{encoding:'utf8'});
if(verified.status!==0) throw new Error(verified.stdout||verified.stderr);
const out=JSON.parse(verified.stdout),consumed=out.task.consumed_detail_outline_targets||[];
if(consumed.length!==1||consumed[0].target_id!==target.target_id) throw new Error(JSON.stringify(consumed));
if((out.task.active_chapter_target||{}).target_id===target.target_id) throw new Error('accepted target remained active');
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
  "stage_execution":{"status":"running","stage_id":"repair_execution_plan","step_id":"repair_execution_plan","write_set":["追踪/workflow/tasks/wf-reconcile-repair/artifacts/repair-plan.md"],"execution_command":"node scripts/test-repair-finalize.js --project-root . --json"},
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
if(task.stage_execution.stage_completion_command!==task.stage_execution.execution_command) throw new Error(JSON.stringify(task.stage_execution));
if(task.stage_execution.current_required_action!=='edit_write_set') throw new Error(JSON.stringify(task.stage_execution));
if((task.stage_execution.after_write_action||{}).command!==task.stage_execution.execution_command) throw new Error(JSON.stringify(task.stage_execution));
if(task.stage_execution.completion_required_before_reply!==true) throw new Error(JSON.stringify(task.stage_execution));
NODE
}

@test "runtime reconciliation previews and confirms legacy prose detail outline target revalidation" {
    book="$TMP_DIR/legacy-prose-target-revalidation"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "恢复旧版长篇逐章写作" --json >/dev/null

    node - "$REPO" "$book" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const [repo,root]=process.argv.slice(2),fixture=require(process.env.WORKFLOW_TASK_FIXTURE);
const taskFile=fixture.focusedTaskFile(root),task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const outlines=[1,2,3].map((chapter)=>`大纲/第2卷/细纲_第${String(chapter).padStart(3,'0')}章.md`);
fs.mkdirSync(path.join(root,'大纲/第2卷'),{recursive:true});
fs.mkdirSync(path.join(root,'正文/第2卷'),{recursive:true});
fs.mkdirSync(path.join(root,'追踪/schema'),{recursive:true});
for(const [index,outlinePath] of outlines.entries()) {
  fs.writeFileSync(path.join(root,outlinePath),`# 第${index+1}章细纲\n- 当前可信内容 ${index+1}\n`);
}
fs.writeFileSync(path.join(root,'大纲/第2卷/细纲_第999章.md'),'# 未声明细纲\n不得通过目录扫描进入恢复目标。\n');
fs.writeFileSync(path.join(root,'正文/第2卷/第001章.md'),'# 第一章\n已经合法采用的正文。\n');
fs.writeFileSync(path.join(root,'追踪/schema/chapters.jsonl'),outlines.map((outlinePath,index)=>JSON.stringify({
  chapterId:`第${String(index+1).padStart(3,'0')}章`,chapterNo:index+1,volume:'第2卷',volumeChapterNo:index+1,
  globalDraftOrder:index+34,outlinePath,contractPath:`追踪/章节契约/第2卷/第${String(index+1).padStart(3,'0')}章.md`,
  draftPath:`正文/第2卷/第${String(index+1).padStart(3,'0')}章.md`
})).join('\n')+'\n');
const identities=outlines.map((outline_path)=>({outline_path,outline_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(root,outline_path))).digest('hex')}));
const packetDir=path.join(root,task.task_dir,'result-packets');fs.mkdirSync(packetDir,{recursive:true});
const predecessorRel=`${task.task_dir}/result-packets/stage_detail_outline.accepted.json`;
const oldReviewRel=`${task.task_dir}/result-packets/detail_outline_review.result.json`;
const oldBriefRel=`${task.task_dir}/result-packets/chapter_brief.result.json`;
fs.writeFileSync(path.join(root,predecessorRel),JSON.stringify({
  workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'stage_detail_outline',step_status:'completed',
  verification_result:'pass',result_write_set:outlines,changed_files:outlines
},null,2));
fs.writeFileSync(path.join(root,oldReviewRel),JSON.stringify({
  workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'detail_outline_review',step_status:'completed',
  verification_result:'pass',review_decision:'accepted',outputs:{detail_outline_quality:{
    status:'pass',workflow_id:task.workflow_id,stage_id:'detail_outline_review',...identities[0]
  }}
},null,2));
fs.writeFileSync(path.join(root,oldBriefRel),JSON.stringify({
  workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'chapter_brief',step_status:'completed',
  verification_result:'pass',outputs:[{kind:'legacy_brief',path:'写作Brief_第034章.md'}]
},null,2));
const {buildLongChapterTargetV2}=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const consumed=buildLongChapterTargetV2({projectRoot:root,outlinePath:identities[0].outline_path,outlineSha256:identities[0].outline_sha256,workflowId:task.workflow_id});
if(consumed.status!=='ok') throw new Error(JSON.stringify(consumed));
const consumedTarget={...consumed.target,consumed_at:'2026-08-03T00:00:00.000Z',accepted_commit_id:'chapter-consumed-001'};
const consumedCommitRel=`${task.task_dir}/result-packets/chapter_commit.consumed-001.result.json`;
fs.writeFileSync(path.join(root,consumedCommitRel),JSON.stringify({
  workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'chapter_commit',step_status:'completed',verification_result:'pass',
  chapter_target:consumedTarget,chapter_commit:{mode:'transactional',accepted_commit_id:consumedTarget.accepted_commit_id}
},null,2));
const tampered={...consumedTarget,outline_path:identities[1].outline_path,outline_sha256:identities[1].outline_sha256};
const stageIds=task.lifecycle_graph.nodes.map((node)=>node.id),currentIndex=stageIds.indexOf('prose');
task.scope='全局第34章';task.current_stage='prose';task.current_step='prose';task.status='running';
task.machine={...task.machine,completed_stages:stageIds.slice(0,currentIndex),remaining_stages:stageIds.slice(currentIndex),last_transition:'legacy_prose_running'};
task.lifecycle_graph.current_node='prose';
task.lifecycle_graph.asset_target={...(task.lifecycle_graph.nodes.find((node)=>node.id==='prose')||{}).asset_target};
task.lifecycle_graph.completed_nodes=stageIds.slice(0,currentIndex);task.lifecycle_graph.invalidated_nodes=[];
task.lifecycle_graph.review_results={};
for(const node of task.lifecycle_graph.nodes) {
  const index=stageIds.indexOf(node.id);node.status=index<currentIndex?'accepted':index===currentIndex?'draft':'missing';
  if(index<currentIndex&&((node.review_requirement||{}).required)) {
    task.lifecycle_graph.review_results[node.id]={status:'accepted',verification_result:'pass',result_packet_path:node.id==='detail_outline_review'?oldReviewRel:`fixture://${node.id}`};
  }
}
task.stage_attempt_history=[
  {stage_attempt_id:'commit-consumed-old',work_unit_id:'wu-consumed-001',stage_id:'chapter_commit',status:'completed',accepted_result_packet:consumedCommitRel,expected_result_packet:consumedCommitRel,result_packet:consumedCommitRel},
  {stage_attempt_id:'outline-batch-old',work_unit_id:'wu-outline-batch-old',stage_id:'stage_detail_outline',status:'completed',accepted_result_packet:predecessorRel,expected_result_packet:predecessorRel},
  {stage_attempt_id:'review-v1-old',stage_id:'detail_outline_review',status:'completed',accepted_result_packet:oldReviewRel,expected_result_packet:oldReviewRel,result_packet:oldReviewRel},
  {stage_attempt_id:'brief-old',stage_id:'chapter_brief',status:'completed',accepted_result_packet:oldBriefRel,expected_result_packet:oldBriefRel,result_packet:oldBriefRel},
  {stage_attempt_id:'brief-review-old',stage_id:'brief_review',status:'completed',accepted_result_packet:`${task.task_dir}/result-packets/brief_review.old.json`}
];
task.detail_outline_review_targets=[identities[0]];
task.accepted_detail_outline_targets=[consumedTarget];
task.consumed_detail_outline_targets=[consumedTarget,tampered];
task.active_chapter_target=null;
task.stage_execution={
  status:'running',stage_attempt_id:'prose-old',work_unit_id:'wu-prose-old',stage_id:'prose',step_id:'prose',
  expected_result_packet:`${task.task_dir}/result-packets/prose.old.json`,result_contract:'long_write_result_v2'
};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE

    task_file="$(focused_task_file "$book")"
    for invalid_attempt in status stage_attempt_id work_unit_id expected_result_packet; do
        node - "$task_file" "$invalid_attempt" <<'NODE'
const fs=require('fs'),file=process.argv[2],field=process.argv[3],task=JSON.parse(fs.readFileSync(file,'utf8')),attempt=task.stage_attempt_history.find((item)=>item.stage_id==='stage_detail_outline');
if(field==='status') attempt.status='failed';
else if(field==='stage_attempt_id') attempt.stage_attempt_id='';
else if(field==='work_unit_id') attempt.work_unit_id='';
else attempt.expected_result_packet=`${attempt.accepted_result_packet}.stale`;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
        invalid_attempt_before="$(shasum -a 256 "$task_file" | awk '{print $1}')"
        run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$(node -e "process.stdout.write(require(process.argv[1]).workflow_id)" "$task_file")" --session-id test:target-revalidation --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_detail_outline_target_revalidation_source_invalid'* ]]
        [ "$(shasum -a 256 "$task_file" | awk '{print $1}')" = "$invalid_attempt_before" ]
        node - "$task_file" <<'NODE'
const fs=require('fs'),file=process.argv[2],task=JSON.parse(fs.readFileSync(file,'utf8')),attempt=task.stage_attempt_history.find((item)=>item.stage_id==='stage_detail_outline');
attempt.status='completed';attempt.stage_attempt_id='outline-batch-old';attempt.work_unit_id='wu-outline-batch-old';attempt.expected_result_packet=attempt.accepted_result_packet;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    done
    node - "$book" "$task_file" fail <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],task=JSON.parse(fs.readFileSync(process.argv[3],'utf8')),verification=process.argv[4];
const source=task.stage_attempt_history.find((attempt)=>attempt.stage_id==='stage_detail_outline'),file=path.join(root,source.accepted_result_packet),packet=JSON.parse(fs.readFileSync(file,'utf8'));
packet.verification_result=verification;fs.writeFileSync(file,JSON.stringify(packet,null,2));
NODE
    invalid_source_before="$(shasum -a 256 "$task_file" | awk '{print $1}')"
    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$(node -e "process.stdout.write(require(process.argv[1]).workflow_id)" "$task_file")" --session-id test:target-revalidation --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_detail_outline_target_revalidation_source_invalid'* ]]
    [ "$(shasum -a 256 "$task_file" | awk '{print $1}')" = "$invalid_source_before" ]
    node - "$book" "$task_file" pass <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],task=JSON.parse(fs.readFileSync(process.argv[3],'utf8')),verification=process.argv[4];
const source=task.stage_attempt_history.find((attempt)=>attempt.stage_id==='stage_detail_outline'),file=path.join(root,source.accepted_result_packet),packet=JSON.parse(fs.readFileSync(file,'utf8'));
packet.verification_result=verification;fs.writeFileSync(file,JSON.stringify(packet,null,2));
NODE
    for missing_authority in machine lifecycle; do
        node - "$task_file" "$missing_authority" <<'NODE'
const fs=require('fs'),file=process.argv[2],authority=process.argv[3],task=JSON.parse(fs.readFileSync(file,'utf8'));
if(authority==='machine') task.machine.completed_stages=task.machine.completed_stages.filter((stageId)=>stageId!=='story_bible');
else task.lifecycle_graph.completed_nodes=task.lifecycle_graph.completed_nodes.filter((stageId)=>stageId!=='story_bible');
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
        incomplete_before="$(shasum -a 256 "$task_file" | awk '{print $1}')"
        run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$(node -e "process.stdout.write(require(process.argv[1]).workflow_id)" "$task_file")" --session-id test:target-revalidation --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'blocked_longform_detail_outline_target_revalidation_predecessor_incomplete'* ]]
        [ "$(shasum -a 256 "$task_file" | awk '{print $1}')" = "$incomplete_before" ]
        node - "$task_file" "$missing_authority" <<'NODE'
const fs=require('fs'),file=process.argv[2],authority=process.argv[3],task=JSON.parse(fs.readFileSync(file,'utf8'));
const stageIds=task.lifecycle_graph.nodes.map((node)=>node.id),completed=stageIds.slice(0,stageIds.indexOf('prose'));
if(authority==='machine') task.machine.completed_stages=completed;
else task.lifecycle_graph.completed_nodes=completed;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    done
    node - "$book" > "$TMP_DIR/creative-before.json" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),root=process.argv[2];
const files=['大纲/第2卷/细纲_第001章.md','大纲/第2卷/细纲_第002章.md','大纲/第2卷/细纲_第003章.md','大纲/第2卷/细纲_第999章.md','正文/第2卷/第001章.md'];
process.stdout.write(JSON.stringify(Object.fromEntries(files.map((file)=>[file,crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex')]))));
NODE
    task_before="$(shasum -a 256 "$task_file" | awk '{print $1}')"

    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$(node -e "process.stdout.write(require(process.argv[1]).workflow_id)" "$task_file")" --session-id test:target-revalidation --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" > "$TMP_DIR/target-revalidation-preview.json"
    node - "$TMP_DIR/target-revalidation-preview.json" <<'NODE'
const fs=require('fs'),out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='longform_detail_outline_target_revalidation_confirmation_required') throw new Error(JSON.stringify(out));
if(!String(out.recovery_command||'').includes('reconcile-runtime')||!String(out.recovery_command||'').includes('--confirm')) throw new Error(JSON.stringify(out));
if((out.detail_outline_review_targets||[]).length!==3||out.creative_assets_modified!==false) throw new Error(JSON.stringify(out));
NODE
    [ "$(shasum -a 256 "$task_file" | awk '{print $1}')" = "$task_before" ]

    workflow_id="$(node -e "process.stdout.write(require(process.argv[1]).workflow_id)" "$task_file")"
    node - "$book" "$task_file" > "$TMP_DIR/superseded-packet-hashes.json" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),root=process.argv[2],task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const sources=['detail_outline_review','chapter_brief'].map((stageId)=>task.stage_attempt_history.find((attempt)=>attempt.stage_id===stageId).accepted_result_packet);
process.stdout.write(JSON.stringify(Object.fromEntries(sources.map((source)=>[source,`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,source))).digest('hex')}`]))));
NODE
    node - "$book" "$task_file" > "$TMP_DIR/protected-consumed-packet-hashes.json" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),root=process.argv[2],task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const source=task.stage_attempt_history.find((attempt)=>attempt.stage_attempt_id==='commit-consumed-old').accepted_result_packet;
process.stdout.write(JSON.stringify({[source]:`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,source))).digest('hex')}`}));
NODE
    node - "$REPO" "$book" "$task_file" <<'NODE'
const fs=require('fs'),path=require('path'),repo=process.argv[2],root=process.argv[3],task=JSON.parse(fs.readFileSync(process.argv[4],'utf8'));
const {claimFamilyWriter}=require(path.join(repo,'scripts/lib/task-family-store.js'));
const claim=claimFamilyWriter(root,task.task_family_id,{session_id:'test:live-other',host:'test'},{write:true,hostLiveness:()=> 'running'});
if(claim.status!=='claimed') throw new Error(JSON.stringify(claim));
NODE
    task_before_takeover="$(shasum -a 256 "$task_file" | awk '{print $1}')"
    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:target-revalidation --confirm --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'workflow_session_takeover_required'* ]]
    [ "$(shasum -a 256 "$task_file" | awk '{print $1}')" = "$task_before_takeover" ]
    node - "$book" "$TMP_DIR/superseded-packet-hashes.json" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),root=process.argv[2],hashes=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
for(const [source,expected] of Object.entries(hashes)) {
  if(!fs.existsSync(path.join(root,source))) throw new Error(`packet moved before takeover: ${source}`);
  const actual=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,source))).digest('hex')}`;
  if(actual!==expected) throw new Error(JSON.stringify({source,expected,actual}));
}
NODE

    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:target-revalidation --takeover --confirm --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" > "$TMP_DIR/target-revalidation-applied.json"

    run node "$SCRIPT" next-candidates --project-root "$book" --workflow-id "$workflow_id" --compact --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }

    node - "$TMP_DIR/target-revalidation-applied.json" "$task_file" "$book" "$TMP_DIR/superseded-packet-hashes.json" "$TMP_DIR/protected-consumed-packet-hashes.json" "$REPO" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),task=JSON.parse(fs.readFileSync(process.argv[3],'utf8')),root=process.argv[4],oldHashes=JSON.parse(fs.readFileSync(process.argv[5],'utf8')),protectedHashes=JSON.parse(fs.readFileSync(process.argv[6],'utf8'));
if(out.status!=='longform_detail_outline_target_revalidation_applied'||out.creative_assets_modified!==false) throw new Error(JSON.stringify(out));
if(task.current_stage!=='detail_outline_review'||task.current_step!=='detail_outline_review') throw new Error(JSON.stringify(task));
if((((task.runtime_guard||{}).session_lease||{}).holder_id)!=='test:target-revalidation') throw new Error(JSON.stringify(task.runtime_guard));
const targets=task.detail_outline_review_targets||[],execution=task.stage_execution||{};
if(targets.length!==3||execution.stage_id!=='detail_outline_review'||execution.status!=='running') throw new Error(JSON.stringify({targets,execution}));
if(/undefined/.test(String(execution.resume_hint||''))||/第\s*章/.test(String(execution.resume_hint||''))) throw new Error(JSON.stringify({resume_hint:execution.resume_hint}));
const {validateWorkflowConfirmation}=require(path.join(process.argv[7],'scripts/lib/workflow-confirmation-context.js'));
if(!validateWorkflowConfirmation(task,execution).valid) throw new Error(JSON.stringify({confirmation:execution.confirmation_context,last_selection:task.last_selection,pending_action:task.pending_action}));
if(targets.some((target)=>target.outline_path.includes('999'))) throw new Error(JSON.stringify(targets));
if(execution.result_contract!=='detail_outline_quality_v2'||JSON.stringify(execution.review_targets)!==JSON.stringify(targets)) throw new Error(JSON.stringify(execution));
for(const target of targets) {
  const actual=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,target.outline_path))).digest('hex');
  if(target.outline_sha256!==actual) throw new Error(JSON.stringify(target));
}
if((task.accepted_detail_outline_targets||[]).length!==0||task.active_chapter_target!==null) throw new Error(JSON.stringify(task.accepted_detail_outline_targets));
const consumed=task.consumed_detail_outline_targets||[];
if(consumed.length!==1||consumed[0].outline_path!=='大纲/第2卷/细纲_第001章.md') throw new Error(JSON.stringify(consumed));
const stages=task.lifecycle_graph.nodes.map((node)=>node.id),reviewIndex=stages.indexOf('detail_outline_review');
if(JSON.stringify(task.machine.completed_stages)!==JSON.stringify(stages.slice(0,reviewIndex))) throw new Error(JSON.stringify(task.machine));
if(task.machine.remaining_stages[0]!=='detail_outline_review'||task.lifecycle_graph.current_node!=='detail_outline_review') throw new Error(JSON.stringify(task.lifecycle_graph));
if(task.lifecycle_graph.invalidated_nodes.includes('detail_outline_review')) throw new Error(JSON.stringify(task.lifecycle_graph.invalidated_nodes));
for(const stageId of stages.slice(reviewIndex+1)) {
  if(!task.lifecycle_graph.invalidated_nodes.includes(stageId)) throw new Error(JSON.stringify(task.lifecycle_graph.invalidated_nodes));
}
for(const stageId of stages.slice(reviewIndex)) {
  if(task.lifecycle_graph.completed_nodes.includes(stageId)||task.lifecycle_graph.review_results[stageId]) throw new Error(JSON.stringify(task.lifecycle_graph));
}
const attempts=Object.fromEntries((task.stage_attempt_history||[]).map((item)=>[item.stage_attempt_id,item]));
if(attempts['outline-batch-old'].superseded_by_target_revalidation) throw new Error(JSON.stringify(attempts['outline-batch-old']));
if(attempts['commit-consumed-old'].superseded_by_target_revalidation) throw new Error(JSON.stringify(attempts['commit-consumed-old']));
for(const attemptId of ['review-v1-old','brief-old','brief-review-old','prose-old']) {
  if(!attempts[attemptId]||attempts[attemptId].superseded_by_target_revalidation!==true) throw new Error(JSON.stringify(attempts));
}
const manifestRel=((task.longform_target_revalidation||{}).archive_manifest_path)||'',manifestFile=path.join(root,manifestRel);
if(!manifestRel||!fs.existsSync(manifestFile)) throw new Error(JSON.stringify(task.longform_target_revalidation));
const manifest=JSON.parse(fs.readFileSync(manifestFile,'utf8'));
for(const [source,expectedHash] of Object.entries(oldHashes)) {
  if(fs.existsSync(path.join(root,source))) throw new Error(`superseded canonical result still exists: ${source}`);
  const entry=(manifest.entries||[]).find((item)=>item.source_path===source);
  if(!entry||entry.sha256!==expectedHash||!fs.existsSync(path.join(root,entry.archive_path))) throw new Error(JSON.stringify({source,entry,manifest}));
  const actual=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,entry.archive_path))).digest('hex')}`;
  if(actual!==expectedHash) throw new Error(JSON.stringify({source,expectedHash,actual}));
}
if(fs.existsSync(path.join(root,execution.expected_result_packet))) throw new Error(`new canonical result path is not empty: ${execution.expected_result_packet}`);
for(const [source,expectedHash] of Object.entries(protectedHashes)) {
  if(!fs.existsSync(path.join(root,source))) throw new Error(`protected consumed result was archived: ${source}`);
  const actual=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,source))).digest('hex')}`;
  if(actual!==expectedHash||(manifest.entries||[]).some((item)=>item.source_path===source)) throw new Error(JSON.stringify({source,expectedHash,actual,manifest}));
}
NODE

    node - "$task_file" "$book" <<'NODE'
const fs=require('fs'),path=require('path'),taskFile=process.argv[2],root=process.argv[3],task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const manifestRel=task.longform_target_revalidation.archive_manifest_path,manifestFile=path.join(root,manifestRel),manifest=JSON.parse(fs.readFileSync(manifestFile,'utf8'));
for(const entry of manifest.entries.filter((item)=>/\/(?:detail_outline_review|chapter_brief)\.result\.json$/.test(item.source_path))) {
  fs.mkdirSync(path.dirname(path.join(root,entry.source_path)),{recursive:true});
  fs.renameSync(path.join(root,entry.archive_path),path.join(root,entry.source_path));
}
fs.unlinkSync(manifestFile);
delete task.longform_target_revalidation.archive_manifest_path;
delete task.longform_target_revalidation.archived_result_packet_count;
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:target-revalidation --confirm --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    printf '%s\n' "$output" > "$TMP_DIR/target-revalidation-archive-resumed.json"
    node - "$TMP_DIR/target-revalidation-archive-resumed.json" "$task_file" "$book" "$TMP_DIR/superseded-packet-hashes.json" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),task=JSON.parse(fs.readFileSync(process.argv[3],'utf8')),root=process.argv[4],oldHashes=JSON.parse(fs.readFileSync(process.argv[5],'utf8'));
if(out.status!=='longform_detail_outline_target_revalidation_archive_reconciled'||task.current_stage!=='detail_outline_review') throw new Error(JSON.stringify(out));
const manifestRel=task.longform_target_revalidation.archive_manifest_path,manifest=JSON.parse(fs.readFileSync(path.join(root,manifestRel),'utf8'));
for(const [source,expectedHash] of Object.entries(oldHashes)) {
  if(fs.existsSync(path.join(root,source))) throw new Error(`superseded canonical result still exists after resumed archive: ${source}`);
  const entry=manifest.entries.find((item)=>item.source_path===source);
  if(!entry||entry.sha256!==expectedHash) throw new Error(JSON.stringify({source,entry,manifest}));
  const actual=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,entry.archive_path))).digest('hex')}`;
  if(actual!==expectedHash) throw new Error(JSON.stringify({source,expectedHash,actual}));
}
NODE

    node - "$task_file" <<'NODE'
const fs=require('fs'),file=process.argv[2],task=JSON.parse(fs.readFileSync(file,'utf8'));
task.pending_action=null;task.last_selection={};task.stage_execution.confirmation_token='legacy-invalid';
task.stage_execution.confirmation_context={status:'confirmed',confirmation_token:'legacy-invalid',expires_at:''};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:target-revalidation --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'longform_detail_outline_target_revalidation_confirmation_repair_required'* ]]
    run node "$SCRIPT" reconcile-runtime --project-root "$book" --workflow-id "$workflow_id" --session-id test:target-revalidation --confirm --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'longform_detail_outline_target_revalidation_confirmation_repaired'* ]]
    node - "$REPO" "$task_file" <<'NODE'
const path=require('path'),task=require(process.argv[3]);
const {validateWorkflowConfirmation}=require(path.join(process.argv[2],'scripts/lib/workflow-confirmation-context.js'));
if(!validateWorkflowConfirmation(task,task.stage_execution).valid) throw new Error(JSON.stringify(task.stage_execution));
NODE

    run node "$SCRIPT" inspect --project-root "$book" --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status": "ok"'* ]]

    node - "$book" "$TMP_DIR/creative-before.json" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path'),root=process.argv[2],before=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
for(const [file,expected] of Object.entries(before)) {
  const actual=crypto.createHash('sha256').update(fs.readFileSync(path.join(root,file))).digest('hex');
  if(actual!==expected) throw new Error(`${file} changed`);
}
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
    [[ "$output" == *'不是 Git 提交'* ]]
    [[ "$output" == *'不要运行 git status 或 git commit'* ]]
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

@test "long-write chapter commit rejects a volume mismatch against the active outline path" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/story-system/commits"
    write_long_commit_task "wf-long-volume-mismatch"
    bind_active_long_chapter_target "大纲/第2卷/细纲_第001章.md" "$(printf '1%.0s' {1..64})"
    write_accepted_commit
    write_transactional_commit_result "wf-long-volume-mismatch" "projection_current" false

    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_chapter_commit_target_mismatch'* ]]
    [[ "$output" == *'commit.volume'* ]]
}

@test "long-write chapter commit accepts equivalent legacy volume labels" {
    for volume_label in '第2卷' '第二卷' '卷二'; do
        rm -rf "$TMP_DIR/book"
        mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/story-system/commits"
        write_long_commit_task "wf-long-volume-normalized"
        bind_active_long_chapter_target "大纲/第2卷/细纲_第001章.md" "$(printf '1%.0s' {1..64})"
        write_accepted_commit
        node - "$TMP_DIR/book/追踪/story-system/commits/chapter-v12345678-001-abcdef1234.json" "$volume_label" <<'NODE'
const fs=require('fs'),file=process.argv[2],volume=process.argv[3],commit=JSON.parse(fs.readFileSync(file,'utf8'));commit.volume=volume;fs.writeFileSync(file,JSON.stringify(commit));
NODE
        write_transactional_commit_result "wf-long-volume-normalized" "projection_current" false

        run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json
        [ "$status" -eq 0 ] || { echo "$volume_label: $output"; false; }
    done
}

@test "long-write chapter commit rejects a chapter mismatch using the volume-local number" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/story-system/commits"
    write_long_commit_task "wf-long-chapter-mismatch"
    bind_active_long_chapter_target "大纲/第2卷/细纲_第002章.md" "$(printf '2%.0s' {1..64})"
    write_accepted_commit
    node - "$TMP_DIR/book/追踪/story-system/commits/chapter-v12345678-001-abcdef1234.json" <<'NODE'
const fs=require('fs'),file=process.argv[2],commit=JSON.parse(fs.readFileSync(file,'utf8'));commit.volume='第2卷';fs.writeFileSync(file,JSON.stringify(commit));
NODE
    write_transactional_commit_result "wf-long-chapter-mismatch" "projection_current" false

    run node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/result.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_chapter_commit_target_mismatch'* ]]
    [[ "$output" == *'commit.chapter'* ]]
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
    node "$SCRIPT" create --workflow-type long_write --project-root "$TMP_DIR/book" --user-goal "新开长篇" --json > "$TMP_DIR/create.json"
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

@test "compact resolve action starts brief review without leaking durable execution payloads" {
    run node - "$SCRIPT" "$REPO" "$TMP_DIR/compact-resolve-brief-review" <<'NODE'
const assert=require('assert'),cp=require('child_process'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const [script,repo,root]=process.argv.slice(2);
const invoke=(args)=>cp.spawnSync(process.execPath,[script,...args],{encoding:'utf8'});
const created=invoke(['create','--workflow-type','long_write','--project-root',root,'--user-goal','继续当前长篇','--json']);
if(created.status!==0) throw new Error(created.stdout||created.stderr);
const fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
const stageIds=task.lifecycle_graph.nodes.map((node)=>node.id),reviewIndex=stageIds.indexOf('brief_review');
const outlinePath='大纲/第1卷/细纲_第001章.md',outlineFile=path.join(root,outlinePath);
fs.mkdirSync(path.dirname(outlineFile),{recursive:true});
fs.writeFileSync(outlineFile,'# 第一章细纲\n\n主角必须在公开质疑中作出不可撤回的选择。\n');
fs.mkdirSync(path.join(root,'追踪/schema'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/schema/chapters.jsonl'),`${JSON.stringify({
  chapterId:'第001章',chapterNo:1,volume:'第1卷',volumeChapterNo:1,globalDraftOrder:1,
  outlinePath,contractPath:'追踪/章节契约/第1卷/第001章.md',draftPath:'正文/第1卷/第001章.md',
})}\n`);
const {buildLongChapterTargetV2}=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const built=buildLongChapterTargetV2({
  projectRoot:root,
  outlinePath,
  outlineSha256:crypto.createHash('sha256').update(fs.readFileSync(outlineFile)).digest('hex'),
  workflowId:task.workflow_id,
});
if(built.status!=='ok') throw new Error(JSON.stringify(built));
const target=built.target;
fs.mkdirSync(path.dirname(path.join(root,target.contract_path)),{recursive:true});
fs.writeFileSync(path.join(root,target.contract_path),'# 第一章 Brief\n\n- 目标字数：3000\n- 合法区间：2700—3600\n');
const noiseDir=path.join(root,'素材','只用于验证快照边界');
fs.mkdirSync(noiseDir,{recursive:true});
for(let index=0;index<700;index+=1) fs.writeFileSync(path.join(noiseDir,`上下文-${String(index).padStart(4,'0')}.md`),`证据 ${index}\n`);
task.current_stage='brief_review';task.current_step='brief_review';task.status='running';
task.machine={...task.machine,completed_stages:stageIds.slice(0,reviewIndex),remaining_stages:stageIds.slice(reviewIndex),last_transition:'stage_completed',next_stop_reason:'awaiting_user_confirm'};
task.lifecycle_graph.current_node='brief_review';task.lifecycle_graph.completed_nodes=stageIds.slice(0,reviewIndex);task.lifecycle_graph.invalidated_nodes=[];
for(const node of task.lifecycle_graph.nodes) node.status=stageIds.indexOf(node.id)<reviewIndex?'accepted':'missing';
task.lifecycle_graph.review_results=Object.fromEntries(task.lifecycle_graph.nodes
  .filter((node)=>stageIds.indexOf(node.id)<reviewIndex&&node.review_requirement&&node.review_requirement.required)
  .map((node)=>[node.id,{status:'accepted',verification_result:'pass',result_packet_path:`${task.task_dir}/result-packets/${node.id}.result.json`}]))
task.lifecycle_graph.asset_target=task.lifecycle_graph.nodes[reviewIndex].asset_target;
task.active_chapter_target=target;task.accepted_detail_outline_targets=[target];task.consumed_detail_outline_targets=[];
task.stage_execution=null;
task.pending_action={
  ...(task.pending_action||{}),id:'pa-brief-review',pending_action_id:'pa-brief-review',status:'pending',
  question:'请选择下一步',
  options:[
    {...((task.pending_action||{}).options||[])[0],number:1,action_id:'continue_next_stage',label:'继续 Brief 审阅（推荐）',target_stage:'brief_review',recommended:true},
    ...((task.pending_action||{}).options||[]).slice(1),
  ],
};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');

const fullRoot=`${root}-full`;
fs.cpSync(root,fullRoot,{recursive:true});
const fullStarted=invoke(['resolve-action','--project-root',fullRoot,'--input','1','--bind-current','--json']);
if(fullStarted.status!==0) throw new Error(fullStarted.stdout||fullStarted.stderr);
const fullOut=JSON.parse(fullStarted.stdout),fullExecution=fullOut.stage_execution||{};
assert.equal(fullOut.status,'stage_started');
assert.ok(fullExecution.write_snapshot&&Object.keys(fullExecution.write_snapshot.files||{}).length>=700,'non-compact resolve-action lost its durable snapshot');
assert.ok(fullExecution.result_packet_template&&fullExecution.stage_context_packet,'non-compact resolve-action contract changed');

const candidates=invoke(['next-candidates','--project-root',root,'--compact','--json']);
if(candidates.status!==0) throw new Error(candidates.stdout||candidates.stderr);
const candidateOut=JSON.parse(candidates.stdout),continueOption=(candidateOut.next_candidates||[]).find((option)=>Number(option.number)===1)||{};
assert.ok(String(continueOption.execution_command||'').includes('resolve-action'),'compact menu lost the exact resolve-action command');
assert.ok(String(continueOption.execution_command||'').includes('--compact'),`compact menu resolve-action command must preserve compact mode: ${JSON.stringify(candidateOut)}`);

const started=invoke(['resolve-action','--project-root',root,'--input','1','--bind-current','--compact','--json']);
if(started.status!==0) throw new Error(started.stdout||started.stderr);
const raw=started.stdout,out=JSON.parse(raw),execution=out.stage_execution||{};
assert.equal(out.status,'stage_started');
const compactBytes=Buffer.byteLength(raw,'utf8');
assert.ok(compactBytes<20*1024,`compact resolve-action output too large: ${compactBytes} bytes`);
for(const field of ['stage_attempt_id','work_unit_id','stage_id','status','owner_module','context_read_command','execution_command','expected_result_packet']) {
  assert.ok(Object.hasOwn(execution,field)&&String(execution[field]||'')!=='',`missing ${field}: ${raw}`);
}
assert.equal(execution.stage_id,'brief_review');
assert.equal(execution.chapter_target.target_id,target.target_id);
assert.ok(out.visible_response&&typeof out.visible_response.text==='string','missing visible_response');
for(const forbidden of ['write_snapshot','stage_context_packet','result_packet_template','canonical_write_baseline','write_audit_snapshot']) {
  assert.equal(raw.includes(forbidden),false,`compact resolve-action leaked ${forbidden}`);
}
const durable=fixture.readFocusedTask(root),saved=durable.stage_execution||{};
assert.ok(saved.write_snapshot&&Object.keys(saved.write_snapshot.files||{}).length>=700,'durable write snapshot was not preserved');
assert.ok(saved.result_packet_template&&saved.stage_context_packet,'durable host contract was changed by compact projection');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "compact inspect projects bounded recovery state without changing full inspect" {
    run node - "$SCRIPT" "$TMP_DIR/compact-inspect-book" <<'NODE'
const cp=require('child_process'),fs=require('fs'),path=require('path');
const script=process.argv[2],root=process.argv[3];
const invoke=(args)=>cp.spawnSync(process.execPath,[script,...args],{encoding:'utf8'});
const created=invoke(['create','--workflow-type','long_write','--project-root',root,'--user-goal','继续长篇','--json']);
if(created.status!==0) throw new Error(created.stdout||created.stderr);
const task=JSON.parse(created.stdout).task;
const started=invoke(['resolve-action','--project-root',root,'--input','1','--bind-current','--compact','--json']);
if(started.status!==0) throw new Error(started.stdout||started.stderr);
const taskFile=path.join(root,task.task_dir,'task.json');
const durable=JSON.parse(fs.readFileSync(taskFile,'utf8'));
durable.stage_execution.write_snapshot={
  version:'stage_write_snapshot_v1',
  files:Object.fromEntries(Array.from({length:900},(_,index)=>[`追踪/证据/快照-${String(index).padStart(4,'0')}.json`,`sha256:${'a'.repeat(64)}`])),
};
durable.stage_execution.stage_context_packet={packet_md:'内部上下文'.repeat(12000),estimated_tokens:48000};
durable.stage_execution.context_packet_blocking={
  status:'blocked_context_packet',blocking:true,reason:'缺少当前阶段必要上下文',
  findings:Array.from({length:80},(_,index)=>({code:`missing_${index}`,message:'缺少字段'.repeat(80)})),
};
durable.stage_attempt_history=Array.from({length:300},(_,index)=>({
  stage_attempt_id:`sa-history-${index}`,stage_id:'positioning',status:'completed',
  evidence:'历史证据'.repeat(120),
}));
durable.longform_target_revalidation={
  status:'recovery_required',resume_stage:'positioning',reason:'runtime_upgrade',
  recovery_command:`node scripts/workflow-state-machine.js reconcile-runtime --project-root . --workflow-id ${durable.workflow_id} --confirm --json`,
  internal_manifest:Array.from({length:600},(_,index)=>({path:`archive/${index}.json`,digest:'b'.repeat(64)})),
};
fs.writeFileSync(taskFile,JSON.stringify(durable,null,2)+'\n');

const full=invoke(['inspect','--project-root',root,'--json']);
if(full.status!==0) throw new Error(full.stdout||full.stderr);
const fullOut=JSON.parse(full.stdout);
if(!fullOut.task||fullOut.task.stage_attempt_history.length!==300) throw new Error(full.stdout);
if(Object.keys(fullOut.task.stage_execution.write_snapshot.files).length!==900) throw new Error(full.stdout);
if(!String(fullOut.task.stage_execution.stage_context_packet.packet_md||'').includes('内部上下文')) throw new Error(full.stdout);

const compact=invoke(['inspect','--project-root',root,'--compact','--json']);
if(compact.status!==0) throw new Error(compact.stdout||compact.stderr);
const raw=compact.stdout;
const out=JSON.parse(raw),projected=out.task||{},execution=projected.stage_execution||{};
if(Buffer.byteLength(raw,'utf8')>=25*1024) throw new Error(`compact inspect too large: ${Buffer.byteLength(raw,'utf8')} bytes`);
for(const field of ['workflow_id','workflow_type','status','current_stage','state_version','task_dir']) {
  if(projected[field]===undefined||projected[field]===null||projected[field]==='') throw new Error(`missing ${field}: ${raw}`);
}
if(!projected.pending_action||projected.pending_action.options.length>4) throw new Error(raw);
if(!projected.machine||projected.machine.next_stop_reason==='') throw new Error(raw);
if(!projected.lifecycle||projected.lifecycle.status==='') throw new Error(raw);
if(execution.status!=='running'||execution.stage_id!=='positioning'||!execution.expected_result_packet) throw new Error(raw);
if(!execution.context_packet_blocking||execution.context_packet_blocking.status!=='blocked_context_packet') throw new Error(raw);
if(!projected.runtime_guard||!projected.runtime_guard.checkpoint_policy||!projected.runtime_guard.heartbeat) throw new Error(raw);
if(!projected.recovery_state||projected.recovery_state.longform_target_revalidation.status!=='recovery_required') throw new Error(raw);
for(const forbidden of ['stage_attempt_history','write_snapshot','stage_context_packet','internal_manifest']) {
  if(raw.includes(forbidden)) throw new Error(`compact inspect leaked ${forbidden}: ${raw}`);
}
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
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

@test "internal short planning stages receive an applying completion command" {
    mkdir -p "$TMP_DIR/book"
    printf '# 素材卡\n' > "$TMP_DIR/book/素材卡.md"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "新开短篇" --no-private-registry --json >/dev/null
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='platform_genre_lock';
task.current_step='platform_genre_lock';
task.status='running';
task.pending_action=null;
task.stage_execution={
  status:'running',
  stage_attempt_id:'sa-platform',
  stage_id:'platform_genre_lock',
  step_id:'platform_genre_lock',
  owner_module:'story-short-write',
  expected_result_packet:`${task.task_dir}/result-packets/platform_genre_lock.result.json`,
};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    workflow_id="$(jq -r '.workflow_id' "$task_file")"
    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --session-id test:planning --json
    [ "$status" -eq 0 ]
    node - "$task_file" <<'NODE'
const task=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));
const execution=task.stage_execution || {};
if(!String(execution.execution_command||'').includes('short-planning-stage-finalize.js')) throw new Error(JSON.stringify(execution));
if(!String(execution.execution_command||'').includes('--apply')) throw new Error(JSON.stringify(execution));
NODE
}

@test "fresh short setting candidate still stops before applying" {
    mkdir -p "$TMP_DIR/book"
    printf '# 素材卡\n' > "$TMP_DIR/book/素材卡.md"
    node "$SCRIPT" create --workflow-type short_write --project-root "$TMP_DIR/book" --user-goal "新开短篇" --no-private-registry --json >/dev/null
    task_file="$(focused_task_file "$TMP_DIR/book")"
    node - "$task_file" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='short_setting';
task.current_step='short_setting';
task.status='running';
task.pending_action=null;
task.stage_execution={
  status:'running',
  stage_attempt_id:'sa-setting-candidate',
  stage_id:'short_setting',
  step_id:'short_setting',
  action_id:'continue_next_stage',
  owner_module:'story-short-write',
  expected_result_packet:`${task.task_dir}/result-packets/short_setting.result.json`,
};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    workflow_id="$(jq -r '.workflow_id' "$task_file")"

    run node "$SCRIPT" reconcile-runtime --project-root "$TMP_DIR/book" --workflow-id "$workflow_id" --session-id test:setting --json
    [ "$status" -eq 0 ]
    node - "$task_file" <<'NODE'
const task=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));
const execution=task.stage_execution || {};
if(!String(execution.execution_command||'').includes('short-planning-stage-finalize.js')) throw new Error(JSON.stringify(execution));
if(String(execution.execution_command||'').includes('--apply')) throw new Error(JSON.stringify(execution));
NODE
}

@test "short revision queue advances to next pending section after accepting current section" {
    # Regression for Task P0.4: accepting section 1 of a feedback_revision_queue
    # [1,2,3] must deterministically push the workflow to section 2 instead of
    # jumping to whole-story assembly or re-entering section 1.
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-advance/result-packets"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-short-queue-advance","task_dir":"追踪/workflow/tasks/wf-short-queue-advance","state_version":1}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-advance/task.json" <<'JSON'
{
  "workflow_id": "wf-short-queue-advance",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "workflow_contract_version": 2,
  "result_contract_version": 2,
  "task_dir": "追踪/workflow/tasks/wf-short-queue-advance",
  "status": "running",
  "scope": "第1节",
  "current_stage": "section_accept_anchor",
  "current_step": "section_accept_anchor",
  "task_family_id": "tf-short-queue-advance",
  "branch_id": "wf-short-queue-advance",
  "machine": {
    "completed_stages": ["quality_gate", "story_value_gate"],
    "remaining_stages": ["section_accept_anchor", "next_section_brief", "draft_next_section", "full_story_assembly", "full_story_review", "short_deslop", "final_check"]
  },
  "runtime_guard": {
    "heartbeat": {"updated_at": "2026-07-27T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "current_stage"}
  },
  "stage_execution": {
    "status": "running",
    "stage_id": "section_accept_anchor",
    "step_id": "section_accept_anchor",
    "stage_attempt_id": "sa-queue-advance",
    "expected_result_packet": "追踪/workflow/tasks/wf-short-queue-advance/result-packets/section_accept_anchor.section-001.result.json"
  },
  "feedback_revision_queue": {
    "status": "running",
    "current_section_index": 1,
    "items": [
      {"section_index": 1, "status": "pending", "brief_status": "invalidated", "prose_status": "pending_recheck"},
      {"section_index": 2, "status": "pending", "brief_status": "invalidated", "prose_status": "pending_recheck"},
      {"section_index": 3, "status": "pending", "brief_status": "invalidated", "prose_status": "pending_recheck"}
    ]
  }
}
JSON
    mkdir -p "$TMP_DIR/book/追踪/workflow/task-families"
    cat > "$TMP_DIR/book/追踪/workflow/task-families/tf-short-queue-advance.json" <<'JSON'
{"schemaVersion":"1.0.0","task_family_id":"tf-short-queue-advance","head_workflow_id":"wf-short-queue-advance","branches":[{"workflow_id":"wf-short-queue-advance","status":"active"}]}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"

    printf '%s\n' '第一节正式正文' > "$TMP_DIR/book/正文.md"
    mkdir -p "$TMP_DIR/book/追踪/story-system/short" "$TMP_DIR/book/追踪/story-system/commits"
    canonical_hash="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    accepted_at="2099-01-01T00:00:00Z"
    cat > "$TMP_DIR/book/追踪/story-system/commits/section-001.json" <<JSON
{"commit_id":"section-001","workflow_id":"wf-short-queue-advance","status":"accepted","accepted_at":"$accepted_at","volume":"短篇正文","chapter":1,"artifacts":[{"target":"正文.md","after_hash":"sha256:$canonical_hash"}]}
JSON
    cat > "$TMP_DIR/book/追踪/story-system/short/section-001-anchor.json" <<JSON
{"workflow_id":"wf-short-queue-advance","section_index":1,"status":"accepted","canonical_path":"正文.md","canonical_sha256":"$canonical_hash","section_commit_id":"section-001","quality_result":{"machine_gate":"pass","story_value_gate":"pass","repetition_gate":"pass","length_policy":{"blocking":false,"verdict":"baseline_not_established"}}}
JSON
    cat > "$TMP_DIR/book/追踪/story-system/short/project-state.json" <<'JSON'
{"current_section_index":1,"accepted_sections":[{"section_index":1,"anchor_path":"追踪/story-system/short/section-001-anchor.json"}]}
JSON

    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-advance/result-packets/section_accept_anchor.section-001.result.json" <<JSON
{
  "workflow_id": "wf-short-queue-advance",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "section_accept_anchor",
  "step_id": "section_accept_anchor",
  "step_status": "completed",
  "verification_result": "pass",
  "outputs": ["正文.md", "追踪/story-system/short/section-001-anchor.json"],
  "evidence": ["追踪/story-system/commits/section-001.json"],
  "checkpoint_state": {"stage": "section_accept_anchor", "section_index": 1},
  "output_health_result": "pass",
  "planned_sections": 3,
  "section_acceptance": {
    "workflow_id": "wf-short-queue-advance",
    "section_index": 1,
    "anchor_path": "追踪/story-system/short/section-001-anchor.json",
    "canonical_path": "正文.md",
    "canonical_sha256": "$canonical_hash",
    "section_commit_id": "section-001",
    "planned_sections": 3
  },
  "changed_files": ["正文.md", "追踪/story-system/short/section-001-anchor.json"]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-advance/result-packets/section_accept_anchor.section-001.result.json" --json > "$TMP_DIR/advance-out.json" || { cat "$TMP_DIR/advance-out.json" >&2; false; }
    run node - "$TMP_DIR/advance-out.json" "$(focused_task_file "$TMP_DIR/book")" "$TMP_DIR/book/追踪/story-system/short/project-state.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const state = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
// Accepting section 1 of queue [1,2,3] must route to next_section_brief (not full_story_assembly)
if (out.current_stage !== 'next_section_brief') throw new Error(`expected next_section_brief, got ${out.current_stage}: ${JSON.stringify(out)}`);
// The transition reason must identify this as a queue advance (not a linear accept)
if (String(((task.machine || {}).last_transition) || '') !== 'short_feedback_revision_next_section') {
  throw new Error(`expected last_transition='short_feedback_revision_next_section', got ${(task.machine || {}).last_transition}`);
}
// task.scope must reflect the next pending section
if (task.scope !== '第2节') throw new Error(`expected task.scope='第2节', got ${task.scope}`);
if (!(task.unit_lifecycle && task.unit_lifecycle.current_scope === '第2节')) throw new Error(`unit_lifecycle scope mismatch: ${JSON.stringify(task.unit_lifecycle)}`);
// queue must have advanced its cursor to section 2
const queue = task.feedback_revision_queue || {};
if (queue.current_section_index !== 2) throw new Error(`expected queue.current_section_index=2, got ${queue.current_section_index}`);
if (queue.status !== 'running') throw new Error(`expected queue.status='running', got ${queue.status}`);
const item1 = (queue.items || []).find((item) => item.section_index === 1) || {};
if (item1.status !== 'accepted') throw new Error(`section 1 must be marked accepted: ${JSON.stringify(item1)}`);
if (!(queue.items || []).some((item) => item.section_index === 2 && item.status === 'pending')) throw new Error(`section 2 must remain pending: ${JSON.stringify(queue.items)}`);
if (!(queue.items || []).some((item) => item.section_index === 3 && item.status === 'pending')) throw new Error(`section 3 must remain pending: ${JSON.stringify(queue.items)}`);
// project-state.json must reflect the next section cursor (not jump to last section)
if (state.current_section_index !== 2) throw new Error(`expected state.current_section_index=2, got ${state.current_section_index}`);
if (state.current_stage !== 'next_section_brief') throw new Error(`expected state.current_stage='next_section_brief', got ${state.current_stage}`);
// next_section_brief is a non-confirm internal stage, so apply-result deterministically
// auto-starts it and points the stage_execution at the section-002 packet. There is no
// pending menu by design; the deterministic forward motion is captured by the work unit
// scope and expected result packet targeting the NEXT section (2), not the same section (1).
const se = task.stage_execution || {};
if (se.status !== 'running') throw new Error(`expected stage_execution.status='running', got ${se.status}`);
if (se.action_id !== 'auto_continue_internal') throw new Error(`expected auto_continue_internal, got ${se.action_id}`);
if (se.work_unit_scope !== '第2节') throw new Error(`expected work_unit_scope='第2节', got ${se.work_unit_scope}`);
if (!String(se.expected_result_packet || '').endsWith('next_section_brief.section-002.result.json')) {
  throw new Error(`expected_result_packet must target section 2, got ${se.expected_result_packet}`);
}
if (task.pending_action !== null && task.pending_action !== undefined) {
  throw new Error(`auto-continued next_section_brief must clear pending_action, got ${JSON.stringify(task.pending_action && task.pending_action.id)}`);
}
console.log('ok');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"ok"* ]]
}

@test "short revision queue routes to whole-story assembly after accepting the last pending section" {
    # Regression for Task P0.4: accepting the last pending section of a
    # feedback_revision_queue must route to full_story_assembly (not re-enter
    # the same section or sit on next_section_brief).
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-final/result-packets"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-short-queue-final","task_dir":"追踪/workflow/tasks/wf-short-queue-final","state_version":1}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-final/task.json" <<'JSON'
{
  "workflow_id": "wf-short-queue-final",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "workflow_contract_version": 2,
  "result_contract_version": 2,
  "task_dir": "追踪/workflow/tasks/wf-short-queue-final",
  "status": "running",
  "scope": "第3节",
  "current_stage": "section_accept_anchor",
  "current_step": "section_accept_anchor",
  "task_family_id": "tf-short-queue-final",
  "branch_id": "wf-short-queue-final",
  "machine": {
    "completed_stages": ["quality_gate", "story_value_gate"],
    "remaining_stages": ["section_accept_anchor", "next_section_brief", "draft_next_section", "full_story_assembly", "full_story_review", "short_deslop", "final_check"]
  },
  "runtime_guard": {
    "heartbeat": {"updated_at": "2026-07-27T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "current_stage"}
  },
  "stage_execution": {
    "status": "running",
    "stage_id": "section_accept_anchor",
    "step_id": "section_accept_anchor",
    "stage_attempt_id": "sa-queue-final",
    "expected_result_packet": "追踪/workflow/tasks/wf-short-queue-final/result-packets/section_accept_anchor.section-003.result.json"
  },
  "feedback_revision_queue": {
    "status": "running",
    "current_section_index": 3,
    "items": [
      {"section_index": 1, "status": "accepted", "brief_status": "rebuilt_and_used", "prose_status": "rechecked_and_accepted"},
      {"section_index": 2, "status": "accepted", "brief_status": "rebuilt_and_used", "prose_status": "rechecked_and_accepted"},
      {"section_index": 3, "status": "pending", "brief_status": "invalidated", "prose_status": "pending_recheck"}
    ]
  }
}
JSON
    mkdir -p "$TMP_DIR/book/追踪/workflow/task-families"
    cat > "$TMP_DIR/book/追踪/workflow/task-families/tf-short-queue-final.json" <<'JSON'
{"schemaVersion":"1.0.0","task_family_id":"tf-short-queue-final","head_workflow_id":"wf-short-queue-final","branches":[{"workflow_id":"wf-short-queue-final","status":"active"}]}
JSON
    migrate_legacy_fixture "$TMP_DIR/book"

    printf '%s\n' '第三节正式正文' > "$TMP_DIR/book/正文.md"
    mkdir -p "$TMP_DIR/book/追踪/story-system/short" "$TMP_DIR/book/追踪/story-system/commits"
    canonical_hash="$(shasum -a 256 "$TMP_DIR/book/正文.md" | awk '{print $1}')"
    accepted_at="2099-01-01T00:00:00Z"
    cat > "$TMP_DIR/book/追踪/story-system/commits/section-003.json" <<JSON
{"commit_id":"section-003","workflow_id":"wf-short-queue-final","status":"accepted","accepted_at":"$accepted_at","volume":"短篇正文","chapter":3,"artifacts":[{"target":"正文.md","after_hash":"sha256:$canonical_hash"}]}
JSON
    cat > "$TMP_DIR/book/追踪/story-system/short/section-003-anchor.json" <<JSON
{"workflow_id":"wf-short-queue-final","section_index":3,"status":"accepted","canonical_path":"正文.md","canonical_sha256":"$canonical_hash","section_commit_id":"section-003","quality_result":{"machine_gate":"pass","story_value_gate":"pass","repetition_gate":"pass","length_policy":{"blocking":false,"verdict":"baseline_not_established"}}}
JSON
    cat > "$TMP_DIR/book/追踪/story-system/short/project-state.json" <<'JSON'
{"current_section_index":3,"accepted_sections":[{"section_index":1},{"section_index":2},{"section_index":3,"anchor_path":"追踪/story-system/short/section-003-anchor.json"}]}
JSON

    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-final/result-packets/section_accept_anchor.section-003.result.json" <<JSON
{
  "workflow_id": "wf-short-queue-final",
  "workflow_type": "private_short_startup",
  "owner_module": "private-short-extension",
  "stage_id": "section_accept_anchor",
  "step_id": "section_accept_anchor",
  "step_status": "completed",
  "verification_result": "pass",
  "outputs": ["正文.md", "追踪/story-system/short/section-003-anchor.json"],
  "evidence": ["追踪/story-system/commits/section-003.json"],
  "checkpoint_state": {"stage": "section_accept_anchor", "section_index": 3},
  "output_health_result": "pass",
  "planned_sections": 3,
  "section_acceptance": {
    "workflow_id": "wf-short-queue-final",
    "section_index": 3,
    "anchor_path": "追踪/story-system/short/section-003-anchor.json",
    "canonical_path": "正文.md",
    "canonical_sha256": "$canonical_hash",
    "section_commit_id": "section-003",
    "planned_sections": 3
  },
  "changed_files": ["正文.md", "追踪/story-system/short/section-003-anchor.json"]
}
JSON

    node "$SCRIPT" apply-result --project-root "$TMP_DIR/book" --result "$TMP_DIR/book/追踪/workflow/tasks/wf-short-queue-final/result-packets/section_accept_anchor.section-003.result.json" --json > "$TMP_DIR/final-out.json" || { cat "$TMP_DIR/final-out.json" >&2; false; }
    run node - "$TMP_DIR/final-out.json" "$(focused_task_file "$TMP_DIR/book")" "$TMP_DIR/book/追踪/story-system/short/project-state.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const state = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
// Accepting the LAST pending section must route to full_story_assembly (not next_section_brief)
if (out.current_stage !== 'full_story_assembly') throw new Error(`expected full_story_assembly, got ${out.current_stage}: ${JSON.stringify(out)}`);
// The transition reason must identify queue completion (not a linear accept)
if (String(((task.machine || {}).last_transition) || '') !== 'short_feedback_revision_completed') {
  throw new Error(`expected last_transition='short_feedback_revision_completed', got ${(task.machine || {}).last_transition}`);
}
// task.scope must collapse to whole story for assembly
if (task.scope !== '全篇') throw new Error(`expected task.scope='全篇', got ${task.scope}`);
// queue must be marked completed with null cursor
const queue = task.feedback_revision_queue || {};
if (queue.status !== 'completed') throw new Error(`expected queue.status='completed', got ${queue.status}`);
if (queue.current_section_index !== null) throw new Error(`expected queue.current_section_index=null, got ${queue.current_section_index}`);
const item3 = (queue.items || []).find((item) => item.section_index === 3) || {};
if (item3.status !== 'accepted') throw new Error(`section 3 must be marked accepted: ${JSON.stringify(item3)}`);
// project-state must reflect assembly stage
if (state.current_stage !== 'full_story_assembly') throw new Error(`expected state.current_stage='full_story_assembly', got ${state.current_stage}`);
// full_story_assembly is a non-confirm internal stage, so apply-result deterministically
// auto-starts it and points stage_execution at the assembly finalizer. The signal that the
// workflow collapsed to whole-story (rather than re-entering section 3) is the assembly
// finalizer execution_command and the section-003 packet being superseded.
const se = task.stage_execution || {};
if (se.status !== 'running') throw new Error(`expected stage_execution.status='running', got ${se.status}`);
if (se.action_id !== 'auto_continue_internal') throw new Error(`expected auto_continue_internal, got ${se.action_id}`);
if (!String(se.execution_command || '').includes('short-story-assembly-finalize.js')) {
  throw new Error(`execution_command must run the assembly finalizer, got ${se.execution_command}`);
}
if (String(se.expected_result_packet || '').indexOf('full_story_assembly') === -1) {
  throw new Error(`expected_result_packet must target full_story_assembly, got ${se.expected_result_packet}`);
}
if (task.pending_action !== null && task.pending_action !== undefined) {
  throw new Error(`auto-continued full_story_assembly must clear pending_action, got ${JSON.stringify(task.pending_action && task.pending_action.id)}`);
}
console.log('ok');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"ok"* ]]
}
