#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/full-story-review-book"
  mkdir -p "$BOOK"
  node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const section=(n,title,lead,size)=>`## 第${n}节 ${title}\n\n${lead}${'情节推进人物选择现实代价'.repeat(size)}\n`;
const text=[
  section(1,'开场','林照在直播里看见空车间。',90),
  section(2,'追查','林照拿到入厂单。',45),
  section(3,'对抗','哥哥关掉直播。',42),
  section(4,'揭露','唐禾把原始画面交给林照。',25),
  section(5,'结尾','鲜果重新进入车间。',18),
].join('\n');
fs.writeFileSync(path.join(root,'正文.md'),text);
fs.writeFileSync(path.join(root,'设定.md'),'# 角色\n主角：林照\n身份：游戏主播\n缺陷：习惯等哥哥拍板\n渴望：被当成能承担责任的人\n人物：哥哥\n人物：唐禾\n');
fs.writeFileSync(path.join(root,'小节大纲.md'),'## 第1节 开场\n## 第2节 追查\n## 第3节 对抗\n## 第4节 揭露\n## 第5节 结尾\n');
NODE
}

@test "full story evidence pack exposes opening and tail weight risks without pretending they are verdicts" {
  run node - "$REPO/scripts/lib/short-story-editorial-review.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const pack=api.buildShortStoryEvidencePack(root,{workflowId:'wf-review'});
if(pack.status!=='ok'||pack.section_count!==5) throw new Error(JSON.stringify(pack));
const codes=new Set(pack.structural_signals.map(row=>row.code));
if(!codes.has('opening_overweight')||!codes.has('tail_weight_collapse')||!codes.has('ending_underweight')) throw new Error(JSON.stringify(pack.structural_signals));
if(!pack.identity_hints.some(line=>line.includes('游戏主播'))) throw new Error(JSON.stringify(pack.identity_hints));
if(!String(pack.note||'').includes('不等于故事结论')) throw new Error(JSON.stringify(pack));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "editorial review card requires every section, character agency, identity payoff and exact prose evidence" {
  run node - "$REPO/scripts/lib/short-story-editorial-review.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const pack=api.attachEvidenceRuntime(api.buildShortStoryEvidencePack(root,{workflowId:'wf-review'}),path.join(root,'正文.md'));
const card={
  schemaVersion:'1.0.0',workflow_id:'wf-review',story_sha256:pack.story_sha256,decision:'revise',summary:'后段收束过快。',
  opening_assessment:{verdict:'concern',evidence_quote:'林照在直播里看见空车间。',reason:'开篇背景说明比例偏高。'},
  section_function_matrix:pack.section_metrics.map(row=>({section_index:row.section_index,structural_role:`第${row.section_index}节职责`,function_verdict:row.section_index>3?'concern':'pass',evidence_quote:row.opening_excerpt.slice(0,18),note:'逐节验收'})),
  character_arc_matrix:[
    {character:'林照',desire:'承担责任',active_action:'公开证据',cost:'与家人决裂',change:'从等待到行动',verdict:'pass',evidence_quotes:['林照拿到入厂单。']},
    {character:'哥哥',desire:'保住公司',active_action:'关闭直播',cost:'失去妹妹信任',change:'责任暴露',verdict:'concern',evidence_quotes:['哥哥关掉直播。']},
  ],
  identity_payoff_matrix:[{identity_or_trait:'游戏主播',setup_quote:'林照在直播里看见空车间。',payoff_quote:'哥哥关掉直播。',verdict:'concern'}],
  climax_ending_assessment:{verdict:'fail',climax_quote:'唐禾把原始画面交给林照。',ending_quote:'鲜果重新进入车间。',reason:'高潮和后果篇幅不足。'},
  findings:[{code:'TailCollapse',severity:'S2',scope:'第4-5节及小节大纲',evidence_quote:'鲜果重新进入车间。',repair_direction:'先补高潮行动链和结尾后果，再重建对应 Brief。'}],
};
const valid=api.validateEditorialReviewCard(card,pack);if(valid.status!=='valid') throw new Error(JSON.stringify(valid));
delete card.character_arc_matrix[1].active_action;
const invalid=api.validateEditorialReviewCard(card,pack);if(invalid.status!=='invalid'||!invalid.findings.some(row=>row.field==='character_arc_matrix.active_action')) throw new Error(JSON.stringify(invalid));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "public and private short workflows both route assembly through editorial review" {
  run node - "$REPO/scripts/lib/workflow-template-registry.js" "$REPO/src/private-internal-skills/private-short-extension/workflow-registry.json" <<'NODE'
const registry=require(process.argv[2]);const fs=require('fs');
const publicTemplate=registry.BASE_TEMPLATES.short_write;const publicStages=Object.fromEntries(publicTemplate.stages.map(row=>[row.stage_id,row]));
if(!publicStages.full_story_review||!publicStages.full_story_assembly.allowed_next.includes('full_story_review')||!publicStages.deslop.required_inputs.includes('full_story_review')) throw new Error(JSON.stringify(publicStages));
const privateRegistry=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));const privateTemplate=privateRegistry.workflow_templates.find(row=>row.workflow_type==='short_write');const privateStages=Object.fromEntries(privateTemplate.stages.map(row=>[row.stage_id,row]));
if(!privateStages.full_story_review||!privateStages.full_story_assembly.allowed_next.includes('full_story_review')||!privateStages.short_deslop.required_inputs.includes('full_story_review')) throw new Error(JSON.stringify(privateStages));
if(privateStages.full_story_review.owner_module!=='story-review') throw new Error('private editorial owner drifted');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "editorial finalizer creates a deterministic evidence pack before asking agents for one review card" {
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-review"
  cat > "$BOOK/追踪/workflow/tasks/wf-review/task.json" <<'JSON'
{"workflow_id":"wf-review","workflow_type":"short_write","task_dir":"追踪/workflow/tasks/wf-review","current_stage":"full_story_review","stage_execution":{"status":"running","stage_id":"full_story_review","owner_module":"story-review"}}
JSON
  run node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id wf-review --apply --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  node - "$output" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const out=JSON.parse(process.argv[2]);const root=process.argv[3];
if(out.status!=='short_story_editorial_review_required') throw new Error(JSON.stringify(out));
if(!fs.existsSync(path.join(root,out.evidence_pack))) throw new Error('evidence pack missing');
if(fs.existsSync(path.join(root,out.review_card))) throw new Error('review card must be written by reviewers, not fabricated by the finalizer');
if(!out.review_card_schema.character_arc_matrix||!out.review_card_schema.identity_payoff_matrix) throw new Error(JSON.stringify(out.review_card_schema));
NODE
}

@test "a revise verdict becomes task-scoped editorial feedback and returns to the existing impact workflow" {
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$BOOK" --user-goal test --no-private-registry --json > "$BATS_TEST_TMPDIR/create.json"
  WORKFLOW_ID="$(node -e "console.log(require(process.argv[1]).task.workflow_id)" "$BATS_TEST_TMPDIR/create.json")"
  node - "$BOOK" "$BATS_TEST_TMPDIR/create.json" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2],created=require(process.argv[3]);const file=path.join(root,created.task.task_dir,'task.json');const task=JSON.parse(fs.readFileSync(file));
task.current_stage='full_story_review';task.current_step='full_story_review';task.result_contract_version=1;
task.machine={...(task.machine||{}),current_stage:'full_story_review',current_step:'full_story_review',completed_stages:['full_story_assembly'],remaining_stages:['full_story_review','deslop','final_check']};
task.stage_execution={status:'running',stage_id:'full_story_review',step_id:'full_story_review',owner_module:'story-review',expected_result_packet:`${task.task_dir}/result-packets/full_story_review.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2));
NODE
  node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json > "$BATS_TEST_TMPDIR/required.json"
  node - "$BOOK" "$BATS_TEST_TMPDIR/required.json" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2],required=require(process.argv[3]);const pack=JSON.parse(fs.readFileSync(path.join(root,required.evidence_pack)));const quote=i=>pack.section_metrics[i].opening_excerpt.slice(0,18);
const card={schemaVersion:'1.0.0',workflow_id:pack.workflow_id,story_sha256:pack.story_sha256,decision:'revise',summary:'后段人物与高潮需要回炉。',opening_assessment:{verdict:'concern',evidence_quote:'林照在直播里看见空车间。',reason:'背景比例偏高。'},section_function_matrix:pack.section_metrics.map((row,i)=>({section_index:row.section_index,structural_role:`第${row.section_index}节职责`,function_verdict:i>2?'concern':'pass',evidence_quote:quote(i),note:'逐节验收'})),character_arc_matrix:[{character:'林照',desire:'承担责任',active_action:'公开证据',cost:'家庭冲突',change:'开始独立决策',verdict:'pass',evidence_quotes:['林照拿到入厂单。']},{character:'哥哥',desire:'保住公司',active_action:'关闭直播',cost:'失去信任',change:'责任暴露',verdict:'concern',evidence_quotes:['哥哥关掉直播。']}],identity_payoff_matrix:[{identity_or_trait:'游戏主播',setup_quote:'林照在直播里看见空车间。',payoff_quote:'哥哥关掉直播。',verdict:'concern'}],climax_ending_assessment:{verdict:'fail',climax_quote:'唐禾把原始画面交给林照。',ending_quote:'鲜果重新进入车间。',reason:'高潮和后果被压缩。'},findings:[{code:'TailCollapse',severity:'S2',scope:'第4-5节及小节大纲',evidence_quote:'鲜果重新进入车间。',repair_direction:'先补高潮行动链和结尾责任后果，再重建受影响 Brief。'}]};
fs.writeFileSync(path.join(root,required.review_card),JSON.stringify(card,null,2));
NODE
  run node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const task=require(`${process.argv[2]}/追踪/workflow/tasks/${process.argv[3]}/task.json`);
if(task.current_stage!=='feedback_impact_sync') throw new Error(JSON.stringify(task.current_stage));
const item=((task.pending_feedback||{}).items||[])[0];
if(!item||item.source_kind!=='editorial_review'||!item.text.includes('TailCollapse')) throw new Error(JSON.stringify(task.pending_feedback));
if((task.short_full_story_review||{}).decision!=='revise') throw new Error(JSON.stringify(task.short_full_story_review));
NODE
}

@test "a pass verdict advances to expression cleanup without writing story facts" {
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$BOOK" --user-goal test --no-private-registry --json > "$BATS_TEST_TMPDIR/pass-create.json"
  WORKFLOW_ID="$(node -e "console.log(require(process.argv[1]).task.workflow_id)" "$BATS_TEST_TMPDIR/pass-create.json")"
  node - "$BOOK" "$BATS_TEST_TMPDIR/pass-create.json" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2],created=require(process.argv[3]);const file=path.join(root,created.task.task_dir,'task.json');const task=JSON.parse(fs.readFileSync(file));
task.current_stage='full_story_review';task.current_step='full_story_review';task.result_contract_version=1;task.machine={...(task.machine||{}),current_stage:'full_story_review',current_step:'full_story_review',completed_stages:['full_story_assembly'],remaining_stages:['full_story_review','deslop','final_check']};task.stage_execution={status:'running',stage_id:'full_story_review',step_id:'full_story_review',owner_module:'story-review',expected_result_packet:`${task.task_dir}/result-packets/full_story_review.result.json`};fs.writeFileSync(file,JSON.stringify(task,null,2));
NODE
  node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json > "$BATS_TEST_TMPDIR/pass-required.json"
  node - "$BOOK" "$BATS_TEST_TMPDIR/pass-required.json" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2],required=require(process.argv[3]);const pack=JSON.parse(fs.readFileSync(path.join(root,required.evidence_pack)));const quote=i=>pack.section_metrics[i].opening_excerpt.slice(0,18);
const card={schemaVersion:'1.0.0',workflow_id:pack.workflow_id,story_sha256:pack.story_sha256,decision:'pass',summary:'全篇可进入表达清理。',opening_assessment:{verdict:'pass',evidence_quote:'林照在直播里看见空车间。',reason:'开篇直接进入核心冲突。'},section_function_matrix:pack.section_metrics.map((row,i)=>({section_index:row.section_index,structural_role:`第${row.section_index}节职责`,function_verdict:'pass',evidence_quote:quote(i),note:'功能完成'})),character_arc_matrix:[{character:'林照',desire:'承担责任',active_action:'公开证据',cost:'家庭冲突',change:'开始独立决策',verdict:'pass',evidence_quotes:['林照拿到入厂单。']},{character:'哥哥',desire:'保住公司',active_action:'关闭直播',cost:'失去信任',change:'承担后果',verdict:'pass',evidence_quotes:['哥哥关掉直播。']}],identity_payoff_matrix:[{identity_or_trait:'游戏主播',setup_quote:'林照在直播里看见空车间。',payoff_quote:'哥哥关掉直播。',verdict:'pass'}],climax_ending_assessment:{verdict:'pass',climax_quote:'唐禾把原始画面交给林照。',ending_quote:'鲜果重新进入车间。',reason:'高潮证据推动终局兑现。'},findings:[]};fs.writeFileSync(path.join(root,required.review_card),JSON.stringify(card,null,2));
NODE
  run node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const task=require(`${process.argv[2]}/追踪/workflow/tasks/${process.argv[3]}/task.json`);
if(task.current_stage!=='deslop'||task.pending_feedback) throw new Error(JSON.stringify({stage:task.current_stage,feedback:task.pending_feedback}));
if((task.short_full_story_review||{}).decision!=='pass') throw new Error(JSON.stringify(task.short_full_story_review));
if((task.short_full_story_review||{}).visible_label!=='故事层可进入表达清理') throw new Error(JSON.stringify(task.short_full_story_review));
NODE
}
