#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    RUNNER="$REPO/scripts/workflow-runner.js"
    STATE="$REPO/scripts/workflow-state-machine.js"
    FAKE="$REPO/tests/fixtures/fake-workflow-host.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    FAKE_LOG="$TMP_DIR/fake-host-invocations.log"
    export NOVEL_ASSISTANT_FAKE_HOST_LOG="$FAKE_LOG"
    mkdir -p "$PROJECT"
}

@test "runner compact presentation preserves the atomic stage completion contract" {
    grep -q "stage_completion_command: String(execution.stage_completion_command" "$RUNNER"
    grep -q "current_required_action: String(execution.current_required_action" "$RUNNER"
    grep -q "after_write_action: execution.after_write_action" "$RUNNER"
    grep -q "completion_required_before_reply: execution.completion_required_before_reply === true" "$RUNNER"
    grep -q "response.render_mode !== 'silent_resume'" "$RUNNER"
}

@test "runner production default leaves enough turns for prose plus its result packet" {
    grep -q 'maxTurns: 50' "$RUNNER"
    run node "$RUNNER" --help
    [[ "$output" == *'default: 50'* ]]
}

teardown() {
    rm -rf "$TMP_DIR"
}

create_started_task() {
    workflow_type="${1:-long_write}"
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
    test ! -e "$FAKE_LOG"
}

@test "runner dry-run writes no packet and launches no host" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --dry-run --json > "$TMP_DIR/out.json"

    grep -q '"status": "dry_run"' "$TMP_DIR/out.json"
    grep -q '"adapter": "fake"' "$TMP_DIR/out.json"
    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.host_execution_mode !== 'managed_runner') throw new Error(JSON.stringify(out));
if (out.execution_boundary?.visible_execution_mode !== '托管运行') throw new Error(JSON.stringify(out.execution_boundary));
const caps = out.execution_boundary?.capabilities || {};
if (caps.stream_abort || caps.process_liveness || caps.exact_usage) throw new Error(JSON.stringify(caps));
for (const key of ['streaming_control', 'unattended']) {
  if (Object.prototype.hasOwnProperty.call(caps, key)) throw new Error(JSON.stringify(caps));
}
NODE
    test ! -e "$FAKE_LOG"
    test -z "$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-packets*' -type f -print)"
}

@test "runner packet records the durable task snapshot rather than the UI focus pointer" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const path = require('path');
const { buildRunPreview, normalizeManagedResultPacket } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
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

@test "long planning runner separates host staging writes from transactional canonical targets" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const path = require('path');
const fs = require('fs');
const { buildRunPreview, normalizeManagedResultPacket } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const root = process.argv[3], fake = process.argv[4];
const staged = ['追踪/workflow/staging/a/001-细纲_第001章.md', '追踪/workflow/staging/a/002-细纲_第002章.md'];
const canonical = ['大纲/第1卷/细纲_第001章.md', '大纲/第1卷/细纲_第002章.md'];
const task = {
  workflow_id: 'wf-long-planning', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-long-planning',
  lifecycle_graph: { nodes: [{ id: 'stage_detail_outline', owner_module: 'story-long-write', lifecycle_node: 'stage_detail_outline', asset_target: { kind: 'story_stage', id: 'current-story-stage' }, review_requirement: { required: false, failure_return: '' } }] },
};
const execution = {
  stage_id: 'stage_detail_outline', step_id: 'stage_detail_outline', stage_attempt_id: 'sa-planning',
  expected_result_packet: '追踪/workflow/tasks/wf-long-planning/result-packets/stage_detail_outline.result.json',
  write_set: staged, canonical_write_set: canonical,
  planning_targets: staged.map((candidate, index) => ({ staged: candidate, canonical: canonical[index] })),
  success_transition: { action: 'advance', target: 'detail_outline_review' },
  execution_command: 'node scripts/long-planning-stage-finalize.js --project-root . --json',
};
const memory = { mode: 'none', status: 'not_required', packet_md: '', packet_json: '', accepts_memory_updates: false };
const run = buildRunPreview(root, task, execution, { adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success' }, 0, memory);
assert.deepEqual(run.runnerPacket.stage_contract.write_set, staged);
assert.deepEqual(run.runnerPacket.stage_contract.canonical_write_set, canonical);
assert.deepEqual(run.runnerPacket.stage_instruction.write_set, staged);
assert.deepEqual(run.runnerPacket.result_packet_template.canonical_write_set, canonical);
assert.equal(run.runnerPacket.result_packet_template.host_execution_mode, 'managed_runner');
assert.deepEqual(run.runnerPacket.stage_contract.success_transition, { action: 'advance', target: 'detail_outline_review' });
assert(run.runnerPacket.requirements.some((item) => item.includes('long-planning-stage-finalize.js')));
assert(!run.runnerPacket.requirements.includes('只向 expected_result_packet 写入符合 result contract 的 JSON'));
NODE
}

@test "detail outline review runner packet carries the v2 target manifest and result contract" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { buildRunPreview, normalizeManagedResultPacket } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const root = process.argv[3];
const fake = process.argv[4];
const reviewTargets = [1, 2, 3].map((chapter) => ({
  outline_path: `大纲/第1卷/细纲_第${String(chapter).padStart(3, '0')}章.md`,
  outline_sha256: String(chapter).repeat(64),
}));
const task = {
  workflow_id: 'wf-detail-review', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-detail-review',
  scope: '第1卷当前剧情阶段', user_goal: '审阅当前阶段细纲',
  lifecycle_graph: { nodes: [{
    id: 'detail_outline_review', owner_module: 'story-review', lifecycle_node: 'detail_outline_review',
    asset_target: { kind: 'story_stage', id: 'current-story-stage' },
    review_requirement: { required: true, failure_return: 'stage_detail_outline' },
  }] },
};
const execution = {
  stage_id: 'detail_outline_review', step_id: 'detail_outline_review',
  expected_result_packet: '追踪/workflow/tasks/wf-detail-review/result-packets/detail_outline_review.result.json',
  write_set: ['追踪/**'], result_contract: 'detail_outline_quality_v2', review_targets: reviewTargets,
};
const memory = { mode: 'none', status: 'not_required', packet_md: '', packet_json: '', accepts_memory_updates: false };
const run = buildRunPreview(root, task, execution, {
  adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success',
}, 0, memory);
assert.equal(run.runnerPacket.stage_contract.result_contract, 'detail_outline_quality_v2');
assert.deepEqual(run.runnerPacket.stage_contract.review_targets, reviewTargets);
assert.equal(run.runnerPacket.result_packet_template.outputs.detail_outline_quality.version, 'detail_outline_quality_v2');
assert.equal(run.runnerPacket.result_packet_template.outputs.detail_outline_quality.status, 'REPLACE_WITH_AGGREGATE_STATUS');
assert.deepEqual(run.runnerPacket.result_packet_template.outputs.detail_outline_quality.identities.map((item)=>({workflow_id:item.workflow_id,stage_id:item.stage_id,outline_path:item.outline_path,outline_sha256:item.outline_sha256})),reviewTargets.map((item)=>({workflow_id:task.workflow_id,stage_id:'detail_outline_review',...item})));
assert.deepEqual(run.runnerPacket.result_packet_template.evidence,reviewTargets.map((item)=>({type:'detail_outline',path:item.outline_path,outline_sha256:item.outline_sha256})));
assert(run.runnerPacket.requirements.some((item) => item.includes('review_targets')));
const resultFile=path.join(root,execution.expected_result_packet),packet=JSON.parse(JSON.stringify(run.runnerPacket.result_packet_template));
packet.outputs.detail_outline_quality.status='PASS';
packet.outputs.detail_outline_quality.identities.forEach((item)=>{item.status='PASS';item.execution.semantic_review.status='accepted';item.execution.semantic_review.reviewer='fixture';item.execution.semantic_review.findings_sha256='4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945';});
packet.outputs.detail_outline_quality.identities[0].outline_sha256='0'.repeat(64);
delete packet.host_execution_mode;
fs.mkdirSync(path.dirname(resultFile),{recursive:true});fs.writeFileSync(resultFile,JSON.stringify(packet));
const normalized=normalizeManagedResultPacket(root,task,execution,resultFile);
assert.equal(normalized.status,'normalized');
const reread=JSON.parse(fs.readFileSync(resultFile,'utf8'));
assert.equal(reread.outputs.detail_outline_quality.status,'pass');
assert.equal(reread.host_execution_mode,'managed_runner');
assert.equal(reread.outputs.detail_outline_quality.identities[0].outline_sha256,reviewTargets[0].outline_sha256);
assert(reread.outputs.detail_outline_quality.identities.every((item)=>item.status==='pass'&&item.workflow_id===task.workflow_id&&item.stage_id==='detail_outline_review'));
NODE
}

@test "master and volume outline review runners require an exact readable revision plan" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path');
const {buildRunPreview}=require(path.join(process.argv[2],'scripts/lib/workflow-runner-execution.js'));
const root=process.argv[3],fake=process.argv[4];
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
for(const [review,producer,target] of [
  ['master_outline_review','master_outline','大纲/总纲.md'],
  ['volume_outline_review','volume_outline','大纲/第2卷/卷纲.md'],
]) {
  const task={workflow_id:`wf-${review}`,workflow_type:'long_write',task_dir:`追踪/workflow/tasks/wf-${review}`,lifecycle_graph:{nodes:[{
    id:review,owner_module:'story-review',lifecycle_node:review,asset_target:{kind:producer,id:`current-${producer}`},review_requirement:{required:true,failure_return:producer},
  }]}};
  const targetFile=path.join(root,target);fs.mkdirSync(path.dirname(targetFile),{recursive:true});fs.writeFileSync(targetFile,'# 中性规划资产\n');
  if(producer==='volume_outline') {
    const predecessorRel=`${task.task_dir}/result-history/${producer}.result.json`,predecessorFile=path.join(root,predecessorRel);
    const predecessorAttempt='sa-volume-outline-current',predecessorWorkUnit='wu-volume-outline-current';
    fs.mkdirSync(path.dirname(predecessorFile),{recursive:true});
    fs.writeFileSync(predecessorFile,JSON.stringify({workflow_id:task.workflow_id,stage_id:producer,stage_attempt_id:predecessorAttempt,work_unit_id:predecessorWorkUnit,step_status:'completed',verification_result:'pass',result_write_set:[target],changed_files:[target]}));
    task.stage_attempt_history=[{stage_id:producer,status:'completed',stage_attempt_id:predecessorAttempt,work_unit_id:predecessorWorkUnit,accepted_result_packet:predecessorRel}];
  }
  const execution={stage_id:review,step_id:review,stage_attempt_id:`sa-${review}`,work_unit_id:`wu-${review}`,work_unit_scope:'第2卷',expected_result_packet:`${task.task_dir}/result-packets/${review}.result.json`,write_set:[]};
  const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
  assert.deepEqual(run.runnerPacket.result_packet_template.planning_revision_plan,{
    version:'planning_revision_plan_v1',summary:'REPLACE_WITH_READABLE_REVISION_SUMMARY',requirements:['REPLACE_WITH_EXACT_REVISION_REQUIREMENT'],targets:[target],
  });
  assert.deepEqual(run.runnerPacket.stage_contract.planning_revision_targets,[target]);
  const requirements=run.runnerPacket.requirements.join('\n');
  assert(requirements.includes('planning_revision_plan'),requirements);
  assert(requirements.includes('可读摘要'),requirements);
  assert(requirements.includes('工作流冻结目标'),requirements);
  assert(requirements.includes('失败回退只允许'),requirements);
  assert.equal(run.runnerPacket.result_packet_template.lifecycle_transition_request.target,review);
}
NODE
}

@test "managed runner restores immutable memory receipt instead of trusting model copied hashes" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {normalizeManagedResultPacket}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const expectedReceipt={schema_version:'1.0.0',provider:'story-memory',workflow_id:'wf-memory',stage_id:'brief_review',contract_digest:'sha256:current-contract',memory_revision:'sha256:current-memory',packet_digest:'sha256:current-packet',selected_entry_ids:['fact-1']};
const expectedTarget={schema_version:'long_chapter_target_v2',target_id:'sha256:'+'1'.repeat(64),outline_path:'大纲/第1卷/细纲_第001章.md',outline_sha256:'2'.repeat(64),volume:'第1卷',global_chapter_no:1,volume_chapter_no:1,contract_path:'追踪/章节契约/第1卷/第1章.md',draft_path:'正文/第1卷/第001章.md',candidate_draft_path:'追踪/workflow/tasks/wf-memory/artifacts/'+'1'.repeat(16)+'/正文.md'};
const task={workflow_id:'wf-memory',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-memory'};
const runnerRel='追踪/workflow/tasks/wf-memory/runner-packets/brief_review.attempt-1.run.json';
const execution={stage_id:'brief_review',step_id:'brief_review',expected_result_packet:'追踪/workflow/tasks/wf-memory/result-packets/brief_review.result.json',chapter_target:expectedTarget,chapter_targets:[expectedTarget],memory_context:{memory_read_receipt:{...expectedReceipt,contract_digest:'sha256:stage-start-contract'}}};
const runnerFile=path.join(root,runnerRel);fs.mkdirSync(path.dirname(runnerFile),{recursive:true});
fs.writeFileSync(runnerFile,JSON.stringify({workflow_id:'wf-memory',stage_id:'brief_review',expected_result_packet:execution.expected_result_packet,memory_context:{memory_read_receipt:expectedReceipt},result_packet_template:{asset_revision:{status:'verified',asset_id:'current-chapter'},review_decision:'accepted',downstream_effects:[]}}));
const resultFile=path.join(root,execution.expected_result_packet);
fs.mkdirSync(path.dirname(resultFile),{recursive:true});
fs.writeFileSync(resultFile,JSON.stringify({workflow_id:'wf-memory',workflow_type:'long_write',stage_id:'brief_review',step_id:'brief_review',runner_packet_path:runnerRel,chapter_target:{...expectedTarget,outline_sha256:'2'.repeat(65)},chapter_targets:[],verification_result:'accepted',review_decision:'accepted',memory_updates:[{entryId:'fact.structured',type:'accepted_fact',proposedContent:{fact:'已确认事实',chapter:3,tags:['证据','承诺']}}],memory_read_receipt:{...expectedReceipt,contract_digest:'sha256:stale-contract',memory_revision:'sha256:stale-memory',packet_digest:'sha256:stale-packet'}}));
const normalized=normalizeManagedResultPacket(root,task,execution,resultFile);
assert.equal(normalized.status,'normalized');
const reread=JSON.parse(fs.readFileSync(resultFile,'utf8'));
assert.deepEqual(reread.memory_read_receipt,expectedReceipt);
assert.deepEqual(reread.chapter_target,expectedTarget);
assert.deepEqual(reread.chapter_targets,[expectedTarget]);
assert.equal(reread.host_execution_mode,'managed_runner');
assert.equal(reread.result_packet_path,execution.expected_result_packet);
assert(reread.contract_normalization.fields.includes('memory_read_receipt'));
assert(reread.contract_normalization.fields.includes('chapter_target'));
assert.equal(typeof reread.memory_updates[0].proposedContent,'string');
assert(reread.memory_updates[0].proposedContent.includes('已确认事实')&&!reread.memory_updates[0].proposedContent.includes('[object Object]'));
assert.equal(reread.memory_updates[0].type,'fact');
assert(reread.contract_normalization.fields.includes('memory_updates.proposedContent'));
assert(reread.contract_normalization.fields.includes('memory_updates.type'));
assert.deepEqual(reread.asset_revision,{status:'verified',asset_id:'current-chapter'});
assert.equal(reread.review_decision,'accepted');
assert.deepEqual(reread.downstream_effects,[]);
assert(reread.contract_normalization.fields.includes('asset_revision'));
NODE
}

@test "runner packet asks memory-enabled creative stages for bounded story memory suggestions" {
  node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert=require('assert'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const task={workflow_id:'wf-memory-template',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-memory-template',lifecycle_graph:{nodes:[{id:'positioning',owner_module:'story-long-write',asset_target:{kind:'story_stage',id:'positioning'},review_requirement:{required:true,failure_return:'positioning'}}]}};
const execution={stage_id:'positioning',step_id:'positioning',expected_result_packet:'追踪/workflow/tasks/wf-memory-template/result-packets/positioning.result.json',write_set:[]};
const memory={mode:'required',status:'assembled',packet_md:'追踪/workflow/tasks/wf-memory-template/context.md',packet_json:'',accepts_memory_updates:true};
const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
assert.deepEqual(run.runnerPacket.result_packet_template.memory_updates,[]);
assert.equal(run.runnerPacket.result_packet_template.memory_update_omission_reason,'');
assert(run.runnerPacket.requirements.some((item)=>item.includes('memory_updates')&&item.includes('作品事实')&&item.includes('未结承诺')&&item.includes('规划漂移')&&item.includes('memory_update_omission_reason')&&item.includes('禁止对象或数组')));
NODE
}

@test "managed review packet is result-only and documents exact lifecycle transition actions" {
  node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert=require('assert'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const node={id:'milestone_review',owner_module:'story-review',lifecycle_node:'milestone_review',asset_target:{kind:'milestone',id:'current-milestone'},review_requirement:{required:true,failure_return:'chapter_commit'}};
const task={workflow_id:'wf-review-contract',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-review-contract',scope:'当前里程碑',lifecycle_graph:{nodes:[node]}};
const execution={stage_id:'milestone_review',step_id:'milestone_review',stage_attempt_id:'sa-review',work_unit_id:'wu-review',expected_result_packet:'追踪/workflow/tasks/wf-review-contract/result-packets/milestone_review.result.json',write_set:[]};
const memory={mode:'required',status:'assembled',packet_md:'追踪/workflow/tasks/wf-review-contract/context.md',packet_json:'',accepts_memory_updates:true};
const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
assert.deepEqual(run.runnerPacket.stage_instruction.write_set,[]);
assert(run.runnerPacket.requirements.some((item)=>item.includes('advance')&&item.includes('return')&&item.includes('stay')&&item.includes('pause')&&item.includes('hold')));
NODE
}

@test "managed result normalizes an unambiguous hold alias to the declared review return" {
  node - "$REPO" "$PROJECT" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {normalizeManagedResultPacket}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const resultRel='追踪/workflow/tasks/wf-hold/result-packets/milestone_review.result.json';
const task={workflow_id:'wf-hold',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-hold'};
const execution={stage_id:'milestone_review',stage_attempt_id:'sa-hold',work_unit_id:'wu-hold',expected_result_packet:resultRel,review_requirement:{required:true,failure_return:'chapter_commit'},write_set:[]};
const resultFile=path.join(root,resultRel);fs.mkdirSync(path.dirname(resultFile),{recursive:true});
fs.writeFileSync(resultFile,JSON.stringify({workflow_id:'wf-hold',stage_id:'milestone_review',step_status:'blocked',verification_result:'blocked',lifecycle_transition_request:{action:'hold',target:'chapter_commit'}}));
const normalized=normalizeManagedResultPacket(root,task,execution,resultFile);
assert.equal(normalized.status,'normalized');
const reread=JSON.parse(fs.readFileSync(resultFile,'utf8'));
assert.deepEqual(reread.lifecycle_transition_request,{action:'return',target:'chapter_commit'});
assert(reread.contract_normalization.fields.includes('lifecycle_transition_request.action'));
NODE
}

@test "managed detail review distinguishes completed semantic review from a revise verdict" {
  node - "$REPO" "$PROJECT" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {normalizeManagedResultPacket}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const outlineRel='大纲/第2卷/细纲_第004章.md',outlineFile=path.join(root,outlineRel);fs.mkdirSync(path.dirname(outlineFile),{recursive:true});fs.writeFileSync(outlineFile,'中性细纲');
const sha=crypto.createHash('sha256').update(fs.readFileSync(outlineFile)).digest('hex');
const resultRel='追踪/workflow/tasks/wf-detail/result-packets/detail_outline_review.result.json';
const task={workflow_id:'wf-detail',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-detail'};
const execution={stage_id:'detail_outline_review',stage_attempt_id:'sa-detail',work_unit_id:'wu-detail',expected_result_packet:resultRel,result_contract:'detail_outline_quality_v2',review_targets:[{outline_path:outlineRel,outline_sha256:sha}],write_set:[]};
const findings=[
  {dimension:'baseline',severity:'S2',message:'需要修订。'},
  {dimension:'baseline',severity:'S3',message:'可选优化。'},
];
const packet={workflow_id:task.workflow_id,stage_id:'detail_outline_review',step_status:'blocked',outputs:{detail_outline_quality:{version:'detail_outline_quality_v2',status:'revise',identities:[{outline_path:outlineRel,outline_sha256:sha,status:'revise',findings,execution:{semantic_review:{status:'revise',reviewer:'MiniMax3',findings}}}]}},evidence:[]};
const resultFile=path.join(root,resultRel);fs.mkdirSync(path.dirname(resultFile),{recursive:true});fs.writeFileSync(resultFile,JSON.stringify(packet));
assert.equal(normalizeManagedResultPacket(root,task,execution,resultFile).status,'normalized');
const reread=JSON.parse(fs.readFileSync(resultFile,'utf8')),semantic=reread.outputs.detail_outline_quality.identities[0].execution.semantic_review;
assert.equal(semantic.status,'accepted');
assert.equal(semantic.finding_count,2);
assert.match(semantic.findings_sha256,/^[0-9a-f]{64}$/);
assert(reread.contract_normalization.fields.includes('semantic_review.status'));
assert.deepEqual(reread.outputs.detail_outline_quality.identities[0].findings.map((item)=>item.severity),['blocking','advisory']);
assert.deepEqual(semantic.findings.map((item)=>item.severity),['blocking','advisory']);
assert(reread.contract_normalization.fields.includes('findings.severity'));
NODE
}

@test "milestone result cannot enter volume acceptance while later chapter outlines exist" {
  node - "$REPO" "$PROJECT" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {normalizeManagedResultPacket}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
for(const n of [3,4,5]){const file=path.join(root,'大纲/第2卷',`细纲_第${String(n).padStart(3,'0')}章.md`);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,`第${n}章中性细纲`);}
const current='大纲/第2卷/细纲_第003章.md';
const task={workflow_id:'wf-volume-boundary',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-volume-boundary',accepted_detail_outline_targets:[{outline_path:current,outline_sha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(root,current))).digest('hex'),volume:'第2卷',volume_chapter_no:3}]};
const resultRel=`${task.task_dir}/result-packets/milestone_review.result.json`;
const execution={stage_id:'milestone_review',stage_attempt_id:'sa-milestone',work_unit_id:'wu-milestone',expected_result_packet:resultRel,review_requirement:{required:true,failure_return:'chapter_commit'},write_set:[]};
const resultFile=path.join(root,resultRel);fs.mkdirSync(path.dirname(resultFile),{recursive:true});
fs.writeFileSync(resultFile,JSON.stringify({workflow_id:task.workflow_id,stage_id:'milestone_review',step_status:'completed',verification_result:'accepted',lifecycle_transition_request:{action:'advance',target:'volume_acceptance'}}));
const normalized=normalizeManagedResultPacket(root,task,execution,resultFile);
assert.equal(normalized.status,'normalized');
const reread=JSON.parse(fs.readFileSync(resultFile,'utf8'));
assert.deepEqual(reread.lifecycle_transition_request,{action:'advance',target:'detail_outline_review'});
assert.equal(reread.next_stage_id,'detail_outline_review');
assert.deepEqual(reread.detail_outline_review_targets.map(item=>item.outline_path),['大纲/第2卷/细纲_第004章.md','大纲/第2卷/细纲_第005章.md']);
assert(reread.contract_normalization.fields.includes('premature_volume_acceptance'));
NODE
}

@test "managed long prose normalizes a self-referential result write set to the exact authorized candidate" {
  node - "$REPO" "$PROJECT" <<'NODE'
const assert=require('assert'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {normalizeManagedResultPacket}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const resultRel='追踪/workflow/tasks/wf-prose/result-packets/prose.result.json';
const candidate='追踪/workflow/tasks/wf-prose/artifacts/1234567890abcdef/正文.md';
const task={workflow_id:'wf-prose',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-prose'};
const execution={stage_id:'prose',stage_attempt_id:'sa-current',work_unit_id:'wu-current',expected_result_packet:resultRel,write_set:[candidate]};
const resultFile=path.join(root,resultRel);fs.mkdirSync(path.dirname(resultFile),{recursive:true});
fs.writeFileSync(resultFile,JSON.stringify({workflow_id:'wf-prose',stage_id:'prose',step_status:'completed',changed_files:[candidate],result_write_set:[resultRel]}));
const normalized=normalizeManagedResultPacket(root,task,execution,resultFile);
assert.equal(normalized.status,'normalized');
const reread=JSON.parse(fs.readFileSync(resultFile,'utf8'));
assert.deepEqual(reread.result_write_set,[candidate]);
assert(reread.contract_normalization.fields.includes('result_write_set'));
NODE
}

@test "in-flight legacy detail review recovers targets from the accepted predecessor packet" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const outlinePath='大纲/第2卷/细纲_第001章.md',outlineFile=path.join(root,outlinePath);
fs.mkdirSync(path.dirname(outlineFile),{recursive:true});fs.writeFileSync(outlineFile,'中性阶段细纲');
const predecessorRel='追踪/workflow/tasks/wf-legacy-review/result-history/stage_detail_outline/workflow/a1.result.json';
const predecessorFile=path.join(root,predecessorRel);fs.mkdirSync(path.dirname(predecessorFile),{recursive:true});
fs.writeFileSync(predecessorFile,JSON.stringify({workflow_id:'wf-legacy-review',stage_id:'stage_detail_outline',step_status:'completed',verification_result:'pass',changed_files:[outlinePath],result_write_set:[outlinePath]}));
const predecessorAttempt={stage_id:'stage_detail_outline',status:'completed',stage_attempt_id:'sa-outline-001',work_unit_id:'wu-outline-001',accepted_result_packet:predecessorRel,expected_result_packet:predecessorRel};
const task={workflow_id:'wf-legacy-review',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-legacy-review',scope:'全局第27—29章',user_goal:'旧上下文下一目标：第34章',lifecycle_graph:{nodes:[{id:'detail_outline_review',owner_module:'story-review',lifecycle_node:'detail_outline_review'}]},stage_attempt_history:[predecessorAttempt]};
const execution={stage_id:'detail_outline_review',step_id:'detail_outline_review',expected_result_packet:'追踪/workflow/tasks/wf-legacy-review/result-packets/detail_outline_review.result.json'};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
assert.equal(run.runnerPacket.stage_contract.result_contract,'detail_outline_quality_v2');
assert.deepEqual(run.runnerPacket.stage_contract.review_targets,[{outline_path:outlinePath,outline_sha256:crypto.createHash('sha256').update(fs.readFileSync(outlineFile)).digest('hex')}]);
for(const broken of [
  {...predecessorAttempt,status:'failed'},
  {...predecessorAttempt,superseded_by_attempt_id:'sa-new'},
  {...predecessorAttempt,expected_result_packet:'追踪/workflow/tasks/wf-legacy-review/result-packets/other.json'},
  {...predecessorAttempt,stage_attempt_id:''},
]) {
  const brokenRun=buildRunPreview(root,{...task,stage_attempt_history:[broken]},execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
  assert.deepEqual(brokenRun.runnerPacket.stage_contract.review_targets,[],JSON.stringify(broken));
}
fs.writeFileSync(predecessorFile,JSON.stringify({workflow_id:'wf-legacy-review',stage_id:'stage_detail_outline',step_status:'completed',verification_result:'fail',changed_files:[outlinePath],result_write_set:[outlinePath]}));
const failedPacketRun=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
assert.deepEqual(failedPacketRun.runnerPacket.stage_contract.review_targets,[]);
NODE
}

@test "chapter brief runner targets accepted outline identities before a stale legacy next target" {
    mkdir -p "$PROJECT/追踪/schema"
    cat > "$PROJECT/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第026章","chapterNo":26,"volume":"第2卷","volumeChapterNo":1,"globalDraftOrder":26,"outlinePath":"大纲/第2卷/细纲_第001章.md","contractPath":"追踪/章节契约/第2卷/第001章.md","draftPath":"正文/第2卷/第001章.md"}
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","contractPath":"追踪/章节契约/第2卷/第002章.md","draftPath":"正文/第2卷/第002章.md"}
{"chapterId":"第028章","chapterNo":28,"volume":"第2卷","volumeChapterNo":3,"globalDraftOrder":28,"outlinePath":"大纲/第2卷/细纲_第003章.md","contractPath":"追踪/章节契约/第2卷/第003章.md","draftPath":"正文/第2卷/第003章.md"}
EOF
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),path=require('path'),fs=require('fs');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4];
const {buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const {inferLongChapter,inferVolume}=require(path.join(repo,'scripts/lib/long-stage-context-packet.js'));
const targetApi=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const accepted=[1,2,3].map((chapter)=>{
  const outlinePath=`大纲/第2卷/细纲_第${String(chapter).padStart(3,'0')}章.md`,content=`第${chapter}章细纲`,file=path.join(root,outlinePath);
  fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);
  const outlineSha256=crypto.createHash('sha256').update(content).digest('hex');
  return targetApi.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256,workflowId:'wf-brief-targets'}).target;
});
assert(accepted.every((t)=>t&&t.target_id),'all accepted targets built');
const task={
  workflow_id:'wf-brief-targets',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-brief-targets',
  scope:'继续当前已接受的全局第27—29章细纲',user_goal:'旧上下文下一目标：第34章',accepted_detail_outline_targets:accepted,active_chapter_target:accepted[0],
  stage_execution:{chapter_target:accepted[0]},
  lifecycle_graph:{nodes:[{id:'chapter_brief',owner_module:'story-long-write',lifecycle_node:'chapter_brief',asset_target:{kind:'chapter',id:'current-chapter'},review_requirement:{required:false,failure_return:''}}]},
};
const execution={stage_id:'chapter_brief',step_id:'chapter_brief',expected_result_packet:'追踪/workflow/tasks/wf-brief-targets/result-packets/chapter_brief.result.json',write_set:[accepted[0].contract_path],chapter_target:accepted[0],chapter_targets:accepted};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
assert.equal(run.runnerPacket.stage_contract.chapter_target_missing,false);
const echoed=run.runnerPacket.stage_contract.chapter_targets;
assert.equal(echoed.length,accepted.length);
for(let i=0;i<echoed.length;i+=1){
  assert.deepEqual(echoed[i],accepted[i],'chapter_targets['+i+'] exact deep-equal');
}
assert.deepEqual(run.runnerPacket.stage_contract.chapter_target,accepted[0]);
assert.equal(inferLongChapter(root,task,'chapter_brief'),1);
assert.equal(inferVolume(task),'第2卷');
const dump=JSON.stringify(run.runnerPacket);
assert(!dump.includes('细纲_第027章'),'no stale global 027 leaked');
assert(!dump.includes('细纲_第034章'),'no stale user_goal 34 leaked');
NODE
}

@test "all five long chapter runner stages bind the same active target" {
    mkdir -p "$PROJECT/追踪/schema"
    cat > "$PROJECT/追踪/schema/chapters.jsonl" <<'EOF'
{"chapterId":"第027章","chapterNo":27,"volume":"第2卷","volumeChapterNo":2,"globalDraftOrder":27,"outlinePath":"大纲/第2卷/细纲_第002章.md","contractPath":"追踪/章节契约/第2卷/第002章.md","draftPath":"正文/第2卷/第002章.md"}
EOF
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert=require('assert'),crypto=require('crypto'),fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3],fake=process.argv[4],{buildRunPreview}=require(path.join(repo,'scripts/lib/workflow-runner-execution.js'));
const targetApi=require(path.join(repo,'scripts/lib/long-chapter-target.js'));
const outlinePath='大纲/第2卷/细纲_第002章.md',content='第二章细纲',file=path.join(root,outlinePath);
fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);
const outlineSha256=crypto.createHash('sha256').update(content).digest('hex');
const target=targetApi.buildLongChapterTargetV2({projectRoot:root,outlinePath,outlineSha256,workflowId:'wf-active-target'}).target;
const stages=['chapter_brief','brief_review','prose','prose_acceptance','chapter_commit'];
const task={workflow_id:'wf-active-target',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-active-target',active_chapter_target:target,accepted_detail_outline_targets:[target],lifecycle_graph:{nodes:stages.map((id)=>({id,write_set:['追踪/workflow/tasks/**']}))}};
const memory={mode:'none',status:'not_required',packet_md:'',packet_json:'',accepts_memory_updates:false};
for(const stage of stages) {
  const expectedWriteSet=stage==='chapter_brief'?[target.contract_path]:stage==='prose'?[target.candidate_draft_path]:stage==='chapter_commit'?[target.draft_path]:[];
  const execution={stage_id:stage,step_id:stage,expected_result_packet:`追踪/workflow/tasks/wf-active-target/result-packets/${stage}.result.json`,chapter_target:target,chapter_targets:stage==='chapter_brief'?[target]:[],write_set:expectedWriteSet};
  const run=buildRunPreview(root,task,execution,{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
  assert.equal(run.runnerPacket.stage_contract.chapter_target_missing,false,stage);
  assert.deepEqual(run.runnerPacket.stage_contract.chapter_target,target,stage);
  assert.equal(run.runnerPacket.stage_contract.chapter_target.target_id,target.target_id,stage);
  assert.equal(run.runnerPacket.stage_contract.chapter_target.volume_chapter_no,2,stage);
  assert.equal(run.runnerPacket.stage_contract.chapter_target.global_chapter_no,27,stage);
  assert.deepEqual(run.runnerPacket.stage_contract.write_set,expectedWriteSet,`${stage}: execution write_set must narrow the template`);
  const tampered=buildRunPreview(root,task,{...execution,write_set:['追踪/workflow/tasks/wf-active-target/wrong-target.md']},{adapter:'fake',maxRetries:0,maxBudgetUsd:0,fakeExecutable:fake,fakeMode:'success'},0,memory);
  assert.equal(tampered.runnerPacket.stage_contract.chapter_target_missing,true,`${stage}: tampered exact write set must block before spawn`);
  assert(tampered.runnerPacket.stage_contract.chapter_target_blocking_reason.includes('write_set'),stage);
}
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

@test "recovered longform revalidates existing early assets without rewriting canon" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { buildRunPreview, normalizeManagedResultPacket } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const root = process.argv[3];
const fake = process.argv[4];
const memory = { mode: 'none', status: 'not_required', packet_md: '', packet_json: '', accepts_memory_updates: false };
const options = { adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success' };
const recovered = {
  workflow_id: 'wf-recovered', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-recovered',
  scope: '第27至29章', user_goal: '继续完善第二卷大纲并重写第27至29章',
  lifecycle: { switch_reason: 'legacy_task_authority_recovery' }, lifecycle_graph: { nodes: [] },
};
for (const stageId of ['positioning', 'story_bible', 'master_outline']) {
  const execution = {
    stage_id: stageId,
    expected_result_packet: `追踪/workflow/tasks/wf-recovered/result-packets/${stageId}.result.json`,
    write_set: ['设定/**', '大纲/**', '追踪/**'],
  };
  const run = buildRunPreview(root, recovered, execution, options, 0, memory);
  const contract = run.runnerPacket.stage_contract;
  assert.equal(contract.existing_asset_policy.mode, 'existing_asset_revalidation');
  assert.equal(contract.existing_asset_policy.result_artifacts, 'result_packet_only');
  assert.deepEqual(contract.write_set, []);
  assert.deepEqual(run.runnerPacket.stage_instruction.existing_asset_policy, contract.existing_asset_policy);
  const requirements = run.runnerPacket.requirements.join('\n');
  assert(requirements.includes('不得补写或编造未确认的全局设定'), requirements);
  assert(requirements.includes('与本次范围无关的缺失不阻断'), requirements);
  assert(requirements.includes('不得另写定位、故事圣经或总纲复核文档'), requirements);
}

const fresh = {
  ...recovered,
  workflow_id: 'wf-fresh', task_dir: '追踪/workflow/tasks/wf-fresh', lifecycle: { switch_reason: '' },
};
const freshRun = buildRunPreview(root, fresh, {
  stage_id: 'positioning',
  expected_result_packet: '追踪/workflow/tasks/wf-fresh/result-packets/positioning.result.json',
  write_set: ['设定/**', '追踪/**'],
}, options, 0, memory);
assert.deepEqual(freshRun.runnerPacket.stage_contract.write_set, ['设定/**', '追踪/**']);
assert.equal(freshRun.runnerPacket.stage_contract.existing_asset_policy, null);
NODE
}

@test "recovered longform accepts a read-only early revalidation runner contract" {
    node "$STATE" create --workflow-type long_write --project-root "$PROJECT" --user-goal "恢复旧长篇既有资产复核" --json >/dev/null
    resolve_first_action

    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const repo = process.argv[2], root = process.argv[3], fake = process.argv[4];
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
const { buildRunPreview } = require(path.join(repo, 'scripts/lib/workflow-runner-execution.js'));
const focused = authority.readFocusedTask(root);
const task = focused.authority.task;
const execution = task.stage_execution;
const lifecycleNode = task.lifecycle_graph.nodes.find((node) => node.id === execution.stage_id);
assert.equal(execution.stage_id, 'positioning');
task.lifecycle = { ...(task.lifecycle || {}), switch_reason: 'legacy_task_authority_recovery' };
execution.write_set = ['设定/**', '追踪/**'];
execution.canonical_write_set = ['大纲/**'];
const run = buildRunPreview(root, task, execution, {
  adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success',
}, 0, { mode: 'none', status: 'not_required', packet_md: '', packet_json: '', accepts_memory_updates: false });
assert.deepEqual(run.runnerPacket.stage_contract.write_set, []);
assert.deepEqual(run.runnerPacket.stage_contract.canonical_write_set, []);
const revisionTask = JSON.parse(JSON.stringify(task));
revisionTask.current_stage = 'master_outline';
revisionTask.machine = { ...(revisionTask.machine || {}), last_transition: 'review_failed_return_to_asset' };
revisionTask.lifecycle_graph = {
  ...(revisionTask.lifecycle_graph || {}),
  current_node: 'master_outline',
  last_transition_validation: { allowed: true, from: 'master_outline_review', to: 'master_outline', rule: 'required_review_failure_return' },
};
const revisionExecution = {
  ...execution,
  stage_id: 'master_outline', step_id: 'master_outline',
  write_set: ['大纲/**', '追踪/**'], canonical_write_set: ['大纲/**'],
  expected_result_packet: '追踪/workflow/tasks/wf-fresh/result-packets/master_outline.result.json',
};
const revisionRun = buildRunPreview(root, revisionTask, revisionExecution, {
  adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success',
}, 0, { mode: 'none', status: 'not_required', packet_md: '', packet_json: '', accepts_memory_updates: false });
assert.deepEqual(revisionRun.runnerPacket.stage_contract.write_set, ['大纲/**', '追踪/**']);
assert.deepEqual(revisionRun.runnerPacket.stage_contract.canonical_write_set, ['大纲/**']);
const runnerFile = path.join(root, run.runnerPacketRel);
fs.mkdirSync(path.dirname(runnerFile), { recursive: true });
fs.writeFileSync(runnerFile, JSON.stringify(run.runnerPacket, null, 2));
task.runtime_guard = task.runtime_guard || {};
task.runtime_guard.last_runner_attempt = {
  workflow_id: task.workflow_id, stage_id: execution.stage_id,
  stage_attempt_id: execution.stage_attempt_id, work_unit_id: execution.work_unit_id, run_id: run.runId,
  runner_packet_path: run.runnerPacketRel,
  expected_result_packet: execution.expected_result_packet,
};
fs.writeFileSync(path.join(root, task.task_dir, 'task.json'), JSON.stringify(task, null, 2));
const result = {
  workflow_id: task.workflow_id, workflow_type: task.workflow_type,
  stage_id: execution.stage_id, step_id: execution.step_id,
  owner_module: lifecycleNode.owner_module, lifecycle_node: lifecycleNode.id,
  asset_target: lifecycleNode.asset_target, review_requirement: lifecycleNode.review_requirement,
  step_status: 'completed', outputs: [], changed_files: [], evidence: [],
  verification_result: 'pass', checkpoint_state: { stage_id: execution.stage_id }, output_health_result: 'pass',
  asset_revision: { status: 'verified', asset_id: lifecycleNode.asset_target.id },
  review_decision: lifecycleNode.review_requirement.required ? 'accepted' : 'not_applicable',
  downstream_effects: [], lifecycle_transition_request: { action: 'advance', target: lifecycleNode.id },
  result_write_set: [], host_execution_mode: 'managed_runner', runner_packet_path: run.runnerPacketRel,
  result_packet_path: execution.expected_result_packet,
  memory_read_receipt: ((execution.memory_context || {}).memory_read_receipt) || null,
};
const resultFile = path.join(root, execution.expected_result_packet);
fs.mkdirSync(path.dirname(resultFile), { recursive: true });
fs.writeFileSync(resultFile, JSON.stringify(result, null, 2));
NODE

    result_file="$(node - "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
process.stdout.write(path.join(root, task.stage_execution.expected_result_packet));
NODE
)"
    run node "$STATE" apply-result --project-root "$PROJECT" --result "$result_file" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "stage_started"'* ]]
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
    test ! -e "$FAKE_LOG"
}

@test "runner once executes one started stage and applies its result packet" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json > "$TMP_DIR/out.json"

    grep -q '"status": "stage_applied"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" -eq 1 ]
    runner_packet="$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-packets*' -name '*.run.json' | head -1)"
    grep -q '"owner_module": "story-long-write"' "$runner_packet"
    grep -q '"task_state": "追踪/workflow/tasks/' "$runner_packet"
    grep -q '"stage_context_packet": null' "$runner_packet"
    test -n "$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-output*' -name '*.stdout.log' -type f -print -quit)"
    output_summary="$(find "$PROJECT/追踪/workflow/tasks" -path '*runner-output*' -name '*.summary.json' -type f -print -quit)"
    test -n "$output_summary"
    grep -q '"raw_chars"' "$output_summary"
    grep -q '"compression_ratio"' "$output_summary"
    grep -q '"workflow_id"' "$PROJECT/追踪/workflow/token-cost-ledger.jsonl"
    grep -q '"status": "summary"' "$PROJECT/追踪/workflow/token-cost-summary.json"
    node - "$PROJECT" <<'NODE'
const fs = require('fs');
const root = process.argv[2];
const event = JSON.parse(fs.readFileSync(`${root}/追踪/workflow/token-cost-ledger.jsonl`, 'utf8').trim());
const summary = JSON.parse(fs.readFileSync(`${root}/追踪/workflow/token-cost-summary.json`, 'utf8'));
    if (event.token_source !== 'estimated' || event.estimated_tokens <= 0) throw new Error(JSON.stringify(event));
    if (typeof event.raw_output_chars !== 'number' || typeof event.compacted_output_chars !== 'number') throw new Error(JSON.stringify(event));
    if (summary.estimated.events !== 1 || summary.unavailable.events !== 0) throw new Error(JSON.stringify(summary));
NODE
    node "$STATE" inspect --project-root "$PROJECT" --json > "$TMP_DIR/inspect.json"
    node - "$TMP_DIR/inspect.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.task.machine.completed_stages.length !== 1) throw new Error(JSON.stringify(out.task.machine));
if (out.task.stage_execution && out.task.stage_execution.status === 'running'
  && out.task.machine.completed_stages.includes(out.task.stage_execution.stage_id)) {
  throw new Error('completed stage is still running');
}
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

@test "runner release preserves the managed result binding for the current stage attempt" {
    create_started_task long_write

    node - "$REPO" "$PROJECT" <<'NODE'
const assert=require('assert');
const path=require('path');
const [repo,root]=process.argv.slice(2);
const authority=require(path.join(repo,'scripts/lib/workflow-task-authority.js'));
const telemetry=require(path.join(repo,'scripts/lib/workflow-runner-telemetry.js'));
const task=authority.readFocusedTask(root).authority.task;
const binding={
  runner_packet_path:`${task.task_dir}/runner-packets/${task.current_stage}.attempt-1.run.json`,
  expected_result_packet:task.stage_execution.expected_result_packet,
};
telemetry.refreshRunnerLease(root,task.workflow_id,task.task_dir,task.current_stage,'run-binding',binding);
telemetry.releaseRunnerLease(root,task.workflow_id,task.task_dir,task.current_stage,'run-binding',binding);
const released=authority.resolveTaskAuthority(root,task.workflow_id).task;
assert.equal(released.runtime_guard.runner_lease,undefined);
assert.equal(released.runtime_guard.last_runner_attempt.runner_packet_path,binding.runner_packet_path);
assert.equal(released.runtime_guard.last_runner_attempt.expected_result_packet,binding.expected_result_packet);
assert.equal(released.runtime_guard.last_runner_attempt.stage_attempt_id,task.stage_execution.stage_attempt_id);
assert.equal(released.runtime_guard.last_runner_attempt.work_unit_id,task.stage_execution.work_unit_id);
NODE
}

@test "background runner keeps heartbeat release and validates against its own authority after focus switches" {
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
  owner_module: taskA.workflow_registry.owner_module,
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
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_longform_result_contract'* ]]

    node - "$REPO" "$PROJECT" "$workflow_id" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root, workflowId] = process.argv.slice(2);
const authority = require(path.join(repo, 'scripts/lib/workflow-task-authority.js'));
assert.equal(authority.readFocusedTask(root).pointer.workflow_id, 'wf-focused-b');
const task = authority.resolveTaskAuthority(root, workflowId).task;
assert.equal(task.machine.completed_stages.length, 0);
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
  stage_attempt_id: task.stage_execution.stage_attempt_id,
  work_unit_id: task.stage_execution.work_unit_id,
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
    test ! -e "$FAKE_LOG"
}

@test "runner distinguishes a stale managed long-chapter result before immutable target normalization" {
    node - "$REPO" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const repo = process.argv[2];
const root = process.argv[3];
const { classifyExistingManagedResultUnit } = require(path.join(repo, 'scripts/lib/workflow-runner-execution.js'));
const task = { workflow_id: 'wf-loop', workflow_type: 'long_write', stage_attempt_history: [] };
const target = (id, chapter) => ({
  schema_version: 'long_chapter_target_v2',
  target_id: `sha256:${id.repeat(64)}`,
  outline_path: `大纲/第1卷/细纲_第${String(chapter).padStart(3, '0')}章.md`,
  outline_sha256: id.repeat(64),
  volume: '第1卷',
  global_chapter_no: chapter,
  volume_chapter_no: chapter,
  contract_path: `追踪/章节契约/第1卷/第${chapter}章.md`,
  draft_path: `正文/第1卷/第${String(chapter).padStart(3, '0')}章.md`,
  candidate_draft_path: `追踪/workflow/tasks/wf-loop/artifacts/${id.repeat(16)}/正文.md`,
});
const previous = target('1', 1);
const current = target('2', 2);
const execution = { stage_id: 'prose', stage_attempt_id: 'sa-current', work_unit_id: 'wu-current', expected_result_packet: '追踪/workflow/tasks/wf-loop/result-packets/prose.result.json', chapter_target: current };
const file = path.join(root, 'prose.result.json');
fs.writeFileSync(file, JSON.stringify({
  workflow_id: task.workflow_id,
  stage_id: execution.stage_id,
  host_execution_mode: 'managed_runner',
  chapter_target: previous,
  result_write_set: [previous.candidate_draft_path],
  changed_files: [previous.candidate_draft_path],
}));
const stale = classifyExistingManagedResultUnit(task, execution, file);
if (stale.status !== 'stale_long_chapter_unit' || stale.existing_target_id !== previous.target_id || stale.current_target_id !== current.target_id) {
  throw new Error(JSON.stringify(stale));
}
const preserved = JSON.parse(fs.readFileSync(file, 'utf8'));
if (preserved.chapter_target.target_id !== previous.target_id) throw new Error('classifier rewrote stale provenance');
task.stage_attempt_history = [{
  stage_id: 'prose', stage_attempt_id: 'sa-previous', status: 'completed',
  expected_result_packet: execution.expected_result_packet,
  accepted_result_packet: execution.expected_result_packet,
}];
fs.writeFileSync(file, JSON.stringify({
  workflow_id: task.workflow_id,
  stage_id: execution.stage_id,
  chapter_target: current,
}));
const oldAttempt = classifyExistingManagedResultUnit(task, execution, file);
if (oldAttempt.status !== 'stale_stage_attempt' || oldAttempt.existing_stage_attempt_id !== 'sa-previous') throw new Error(JSON.stringify(oldAttempt));
fs.writeFileSync(file, JSON.stringify({
  workflow_id: task.workflow_id,
  stage_id: execution.stage_id,
  stage_attempt_id: execution.stage_attempt_id,
  work_unit_id: execution.work_unit_id,
  host_execution_mode: 'managed_runner',
  chapter_target: current,
}));
const reusable = classifyExistingManagedResultUnit(task, execution, file);
if (reusable.status !== 'current_or_indeterminate') throw new Error(JSON.stringify(reusable));
fs.writeFileSync(file, JSON.stringify({
  workflow_id: task.workflow_id,
  stage_id: execution.stage_id,
  stage_attempt_id: execution.stage_attempt_id,
  host_execution_mode: 'managed_runner',
  chapter_target: current,
}));
const missingWorkUnit = classifyExistingManagedResultUnit(task, execution, file);
if (missingWorkUnit.status !== 'indeterminate_long_write_result') throw new Error(JSON.stringify(missingWorkUnit));
fs.writeFileSync(file, JSON.stringify({
  workflow_id: task.workflow_id,
  stage_id: execution.stage_id,
  stage_attempt_id: execution.stage_attempt_id,
  work_unit_id: 'wu-other',
  host_execution_mode: 'managed_runner',
  chapter_target: current,
}));
const mismatchedWorkUnit = classifyExistingManagedResultUnit(task, execution, file);
if (mismatchedWorkUnit.status !== 'stale_stage_attempt' || mismatchedWorkUnit.existing_work_unit_id !== 'wu-other') {
  throw new Error(JSON.stringify(mismatchedWorkUnit));
}
fs.writeFileSync(file, JSON.stringify({
  workflow_id: task.workflow_id,
  stage_id: execution.stage_id,
  host_execution_mode: 'managed_runner',
  result_write_set: [previous.candidate_draft_path],
}));
task.stage_attempt_history=[];
const malformed = classifyExistingManagedResultUnit(task, execution, file);
if (malformed.status !== 'indeterminate_long_write_result') throw new Error(JSON.stringify(malformed));

const planningExecution={stage_id:'master_outline_review',stage_attempt_id:'sa-planning-current',work_unit_id:'wu-planning-current',expected_result_packet:'追踪/workflow/tasks/wf-loop/result-packets/master_outline_review.result.json'};
fs.writeFileSync(file,JSON.stringify({
  workflow_id:task.workflow_id,stage_id:planningExecution.stage_id,stage_attempt_id:'sa-planning-old',work_unit_id:'wu-planning-old',step_status:'failed',verification_result:'failed',
}));
const stalePlanning=classifyExistingManagedResultUnit(task,planningExecution,file);
if(stalePlanning.status!=='stale_stage_attempt'||stalePlanning.existing_stage_attempt_id!=='sa-planning-old') throw new Error(JSON.stringify(stalePlanning));
task.stage_attempt_history=[{
  stage_id:planningExecution.stage_id,stage_attempt_id:'sa-planning-failed',work_unit_id:'wu-planning-failed',status:'failed',failed_result_packet:planningExecution.expected_result_packet,
}];
fs.writeFileSync(file,JSON.stringify({workflow_id:task.workflow_id,stage_id:planningExecution.stage_id,step_status:'failed',verification_result:'failed'}));
const historyPlanning=classifyExistingManagedResultUnit(task,planningExecution,file);
if(historyPlanning.status!=='stale_stage_attempt'||historyPlanning.existing_stage_attempt_id!=='sa-planning-failed') throw new Error(JSON.stringify(historyPlanning));
task.stage_attempt_history=[];
const indeterminatePlanning=classifyExistingManagedResultUnit(task,planningExecution,file);
if(indeterminatePlanning.status!=='indeterminate_long_write_result') throw new Error(JSON.stringify(indeterminatePlanning));
NODE
}

@test "runner archives a rejected managed result so the next run can retry the stage" {
    create_started_task
    node - "$PROJECT" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
const execution=task.stage_execution||{};
const packet=path.join(root,execution.expected_result_packet);fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify({workflow_id:task.workflow_id,workflow_type:task.workflow_type,stage_id:execution.stage_id,step_id:execution.step_id,stage_attempt_id:execution.stage_attempt_id,work_unit_id:execution.work_unit_id,step_status:'completed',host_execution_mode:'managed_runner',runner_packet_path:`${task.task_dir}/runner-packets/rejected.run.json`},null,2));
NODE
    run node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --max-retries 0 --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "blocked_managed_result_rejected"'* ]]
    test ! -e "$FAKE_LOG"
    node - "$PROJECT" "$output" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],out=JSON.parse(process.argv[3]);
if(!out.archived_result_packet||!fs.existsSync(path.join(root,out.archived_result_packet))) throw new Error(JSON.stringify(out));
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
if(fs.existsSync(path.join(root,task.stage_execution.expected_result_packet))) throw new Error('rejected canonical result still exists');
if(task.stage_execution.last_runner_stop_reason!==out.rejection_status) throw new Error(JSON.stringify(task.stage_execution));
if(!String(task.stage_execution.resume_hint||'').includes('上轮受控校验未通过')) throw new Error(task.stage_execution.resume_hint||'missing resume hint');
NODE
}

@test "runner stops at an unconfirmed stage instead of selecting for the user" {
    node "$STATE" create --workflow-type project_setup --project-root "$PROJECT" --user-goal "初始化" --json >/dev/null

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --json > "$TMP_DIR/out.json"

    grep -q '"status": "needs_confirmation"' "$TMP_DIR/out.json"
    grep -q '"target_stage": "project_type_lock"' "$TMP_DIR/out.json"
    test ! -e "$FAKE_LOG"
}

@test "runner stops cover before image generation until the user confirms it" {
    node "$STATE" create --workflow-type cover --project-root "$PROJECT" --user-goal "制作书籍封面" --json >/dev/null

    node "$RUNNER" run --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --max-stages 8 --json > "$TMP_DIR/out.json"

    grep -q '"status": "needs_selection"' "$TMP_DIR/out.json"
    grep -q '"target_stage": "cover_preflight"' "$TMP_DIR/out.json"
    test ! -e "$FAKE_LOG"
}

@test "runner retries model degradation once then preserves the checkpoint" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode repeat-term --max-retries 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "model_degradation_repeated_term"' "$TMP_DIR/out.json"
    grep -q '"attempts": 2' "$TMP_DIR/out.json"
    [ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" -eq 2 ]
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

@test "runner retries Claude max-turn exhaustion once instead of misreporting a healthy missing packet" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode max-turns-once --max-retries 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "stage_applied"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" -eq 2 ]
    grep -R -q '"stop_reason": "max_turns_exhausted"' "$PROJECT/追踪/workflow/tasks"/*/runner-recovery
}

@test "longform prose runner defers mechanical gates and prioritizes the stage receipt" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { buildRunPreview, normalizeManagedResultPacket } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const root = process.argv[3], fake = process.argv[4];
const target = {
  schema_version: 'long_chapter_target_v2', outline_path: '大纲/第1卷/细纲_第001章.md', outline_sha256: '1'.repeat(64),
  volume: '第1卷', global_chapter_no: 1, volume_chapter_no: 1, contract_path: '追踪/章节契约/第1卷/第1章.md',
  draft_path: '正文/第1卷/第001章_测试.md', candidate_draft_path: '追踪/workflow/tasks/wf-prose/artifacts/target/正文.md',
  target_id: `sha256:${'2'.repeat(64)}`,
};
const task = {
  workflow_id: 'wf-prose', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-prose', active_chapter_target: target,
  lifecycle_graph: { nodes: [{ id: 'prose', owner_module: 'story-long-write', lifecycle_node: 'prose', asset_target: { kind: 'chapter', id: 'current-chapter' }, review_requirement: { required: false, failure_return: '' } }] },
};
const execution = { stage_id: 'prose', step_id: 'prose', stage_attempt_id: 'sa-prose', expected_result_packet: `${task.task_dir}/result-packets/prose.result.json`, write_set: [target.candidate_draft_path], chapter_target: target };
const memory = { mode: 'none', status: 'not_required', packet_md: '', packet_json: '', accepts_memory_updates: false };
const run = buildRunPreview(root, task, execution, { adapter: 'fake', maxRetries: 1, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success' }, 0, memory);
const requirements = run.runnerPacket.requirements.join('\n');
assert(requirements.includes('正文机器检查统一由 prose_acceptance 阶段执行'));
assert(requirements.includes('写完候选后优先写 expected_result_packet'));
assert(!requirements.includes('实测字数及正文门禁'));
const retry = buildRunPreview(root, task, execution, { adapter: 'fake', maxRetries: 1, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success' }, 1, memory);
assert(retry.runnerPacket.recovery_instruction.includes('复用 write_set 中已有候选'));
assert(retry.runnerPacket.recovery_instruction.includes('优先补齐 expected_result_packet'));
const acceptanceExecution = {
  stage_id: 'prose_acceptance', step_id: 'prose_acceptance', stage_attempt_id: 'sa-acceptance',
  expected_result_packet: `${task.task_dir}/result-packets/prose_acceptance.result.json`, write_set: [], chapter_target: target,
  execution_command: 'node scripts/long-chapter-machine-gate.js --project-root . --workflow-id "wf-prose" --apply --json',
  quality_command: 'node scripts/long-chapter-quality-gate.js --project-root . --workflow-id "wf-prose" --apply --json',
};
const acceptance = buildRunPreview(root, task, acceptanceExecution, { adapter: 'fake', maxRetries: 1, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success' }, 0, memory);
assert.equal(acceptance.runnerPacket.stage_contract.execution_command, acceptanceExecution.execution_command);
assert.equal(acceptance.runnerPacket.stage_contract.quality_command, acceptanceExecution.quality_command);
const resultFile = path.join(root, execution.expected_result_packet);
fs.mkdirSync(path.dirname(resultFile), { recursive: true });
fs.writeFileSync(resultFile, JSON.stringify({
  ...run.runnerPacket.result_packet_template,
  changed_files: [{ path: target.candidate_draft_path, action: 'kept_existing_candidate' }],
  result_write_set: [target.candidate_draft_path],
}));
normalizeManagedResultPacket(root, task, execution, resultFile);
const normalized = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
assert.deepEqual(normalized.changed_files, [target.candidate_draft_path]);
NODE
}

@test "longform prose runner deterministically closes a missing receipt without bypassing apply-result" {
    node - "$REPO" "$PROJECT" "$FAKE" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { buildRunPreview, writeDeterministicLongProseReceipt } = require(path.join(process.argv[2], 'scripts/lib/workflow-runner-execution.js'));
const root = process.argv[3], fake = process.argv[4];
const candidate = '追踪/workflow/tasks/wf-prose/artifacts/target/正文.md';
const resultRel = '追踪/workflow/tasks/wf-prose/result-packets/prose.result.json';
const target = {
  schema_version: 'long_chapter_target_v2', outline_path: '大纲/第1卷/细纲_第001章.md', outline_sha256: '1'.repeat(64),
  volume: '第1卷', global_chapter_no: 1, volume_chapter_no: 1, contract_path: '追踪/章节契约/第1卷/第1章.md',
  draft_path: '正文/第1卷/第001章_测试.md', candidate_draft_path: candidate, target_id: `sha256:${'2'.repeat(64)}`,
};
const task = {
  workflow_id: 'wf-prose', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-prose', active_chapter_target: target,
  lifecycle_graph: { nodes: [{ id: 'prose', owner_module: 'story-long-write', lifecycle_node: 'prose', asset_target: { kind: 'chapter', id: 'current-chapter' }, review_requirement: { required: false, failure_return: '' } }] },
};
const original = '原候选';
const changed = '已经写完的当前章候选正文';
fs.mkdirSync(path.dirname(path.join(root, candidate)), { recursive: true });
fs.writeFileSync(path.join(root, candidate), changed);
const execution = {
  stage_id: 'prose', step_id: 'prose', stage_attempt_id: 'sa-prose', work_unit_id: 'wu-prose', expected_result_packet: resultRel,
  write_set: [candidate], chapter_target: target,
  write_snapshot: { files: { [candidate]: `sha256:${crypto.createHash('sha256').update(original).digest('hex')}` } },
};
const memory = { mode: 'none', status: 'not_required', packet_md: '', packet_json: '', accepts_memory_updates: false };
const run = buildRunPreview(root, task, execution, { adapter: 'fake', maxRetries: 0, maxBudgetUsd: 0, fakeExecutable: fake, fakeMode: 'success' }, 0, memory);
run.runnerPacket.stage_contract.chapter_target = target;
run.runnerPacket.stage_contract.write_set = [candidate];
assert.equal(writeDeterministicLongProseReceipt(root, task, execution, run, { health: { status: 'healthy', stop_reason: '' } }).status, 'written');
const packet = JSON.parse(fs.readFileSync(path.join(root, resultRel), 'utf8'));
assert.deepEqual(packet.changed_files, [candidate]);
assert.deepEqual(packet.result_write_set, [candidate]);
assert.equal(packet.receipt_origin, 'deterministic_long_prose_finalize');
fs.rmSync(path.join(root, resultRel));
assert.equal(writeDeterministicLongProseReceipt(root, task, execution, run, { health: { status: 'blocked', stop_reason: 'max_turns_exhausted' } }).status, 'written');
fs.rmSync(path.join(root, resultRel));
assert.equal(writeDeterministicLongProseReceipt(root, task, execution, run, { health: { status: 'blocked', stop_reason: 'tool_error_loop' } }).status, 'not_applicable');
assert(!fs.existsSync(path.join(root, resultRel)));
NODE
}

@test "runner stops repeated tool failures instead of starting an unbounded retry loop" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode tool-loop --max-retries 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "tool_failure_loop"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" -eq 2 ]
}

@test "runner treats a healthy host without a result packet as a blocked contract violation" {
    create_started_task

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode no-result --max-retries 1 --json > "$TMP_DIR/out.json"

    grep -q '"status": "missing_result_packet"' "$TMP_DIR/out.json"
    [ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" -eq 1 ]
    node - "$PROJECT" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2],pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
if(task.status!=='running'||task.stage_execution.status!=='running') throw new Error(JSON.stringify({status:task.status,execution:task.stage_execution.status}));
if(task.stage_execution.last_runner_stop_reason!=='missing_result_packet') throw new Error(JSON.stringify(task.stage_execution));
task.status='paused_after_step';task.stage_execution.status='paused';task.stage_execution.stop_reason='missing_result_packet';delete task.stage_execution.last_runner_stop_reason;
fs.writeFileSync(path.join(root,pointer.task_dir,'task.json'),JSON.stringify(task,null,2));
NODE
    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --max-retries 0 --json > "$TMP_DIR/resume.json"
    grep -q '"status": "stage_applied"' "$TMP_DIR/resume.json"
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

@test "runner run stops at a stage blocker before the configured stage limit" {
    create_started_task

    node "$RUNNER" run --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --max-stages 2 --json > "$TMP_DIR/out.json"

    grep -q '"status": "blocked_character_contract_revision_required"' "$TMP_DIR/out.json"
    grep -q '"stage_count": 1' "$TMP_DIR/out.json"
    [ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" -eq 2 ]
}

@test "runner starts a high-risk stage only after the state machine records user confirmation" {
    node "$STATE" create --workflow-type project_setup --project-root "$PROJECT" --user-goal "初始化" --json >/dev/null
    resolve_first_action

    node "$RUNNER" once --project-root "$PROJECT" --adapter fake --fake-executable "$FAKE" --fake-mode success --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_managed_result_rejected'||out.rejection_status!=='blocked_apply_result') throw new Error(JSON.stringify(out));
NODE
    [ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" -eq 1 ]
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
    grep -q '"owner_module": "story-long-write"' "$runner_packet"
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
    test ! -e "$FAKE_LOG"
}
