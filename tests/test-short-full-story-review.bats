#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/full-story-review-book"
  mkdir -p "$BOOK"
  node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const section=(n,title,lead,size)=>`## 第${n}节 ${title}\n\n${lead}${'情节推进人物选择现实代价'.repeat(size)}\n`;
const text=[
  section(1,'开场','阿岚在复核里看见编号空缺。',90),
  section(2,'追查','阿岚拿到档案单。',45),
  section(3,'对抗','主管叫停复核。',42),
  section(4,'揭露','审计员把原始凭证交给阿岚。',25),
  section(5,'结尾','凭证重新归档。',18),
].join('\n');
fs.writeFileSync(path.join(root,'正文.md'),text);
fs.writeFileSync(path.join(root,'设定.md'),'# 角色\n主角：阿岚\n身份：复核员\n缺陷：习惯等主管拍板\n渴望：被当成能承担责任的人\n人物：主管\n人物：审计员\n');
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
if(!pack.identity_hints.some(line=>line.includes('复核员'))) throw new Error(JSON.stringify(pack.identity_hints));
if(!String(pack.note||'').includes('不等于故事结论')) throw new Error(JSON.stringify(pack));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "full story evidence pack records static detector evidence without promoting it to a story verdict" {
  run node - "$REPO/scripts/lib/short-story-editorial-review.js" "$BATS_TEST_TMPDIR/static-evidence" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
fs.mkdirSync(root,{recursive:true});
fs.writeFileSync(path.join(root,'正文.md'),[
  '## 第001节 起因',
  '',
  '林舟找到了第一份记录。',
  '',
  '## 第002节 异常',
  '',
  '作为AI，我无法继续写作。',
].join('\n'));
const pack=api.buildShortStoryEvidencePack(root,{workflowId:'wf-static'});
if(pack.status!=='ok') throw new Error(JSON.stringify(pack));
if(!Array.isArray(pack.static_findings)||!pack.static_findings.some(row=>row.detector==='degeneration'&&row.section_index===2&&row.line>0)) throw new Error(JSON.stringify(pack.static_findings));
if(!Array.isArray(pack.detector_status)||!pack.detector_status.every(row=>['complete','unavailable'].includes(row.status))) throw new Error(JSON.stringify(pack.detector_status));
if(pack.structural_signals.some(row=>String(row.code||'').includes('degeneration'))) throw new Error('static evidence was promoted to a structural verdict');
if(!String(pack.note||'').includes('静态检测')) throw new Error(JSON.stringify(pack.note));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "editorial review card requires every section, character agency, identity payoff and exact prose evidence" {
  run node - "$REPO/scripts/lib/short-story-editorial-review.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const pack=api.attachEvidenceRuntime(api.buildShortStoryEvidencePack(root,{workflowId:'wf-review'}),path.join(root,'正文.md'));
const reader={reader_profile:{target_platform:'番茄短篇',platform_mode:'free_feed_mobile',genre_lens:['现实世情'],style_lens:['restrained_realism','suspense_gap'],reading_scene:'mobile_continuous',profile_basis:'设定.md'},section_reader_response:pack.section_metrics.map(row=>({section_index:row.section_index,engagement:row.section_index>3?'wavering':'engaged',felt_emotion:'想继续确认真相',reader_question:'下一步会付出什么代价',evidence_quote:row.opening_excerpt.slice(0,18)})),drop_off_points:[],character_impressions:[{character:'阿岚',first_impression:'依赖上级',later_impression:'开始主动查证',trust_change:'up',evidence_quotes:['阿岚拿到档案单。']}],identity_continuity:[{identity_or_trait:'复核员',visibility:'fading',reader_effect:'开篇身份后续参与不足',evidence_quotes:['阿岚在复核里看见编号空缺。','主管叫停复核。']}],supporting_character_reality:[{character:'主管',felt_status:'thin',apparent_want:'保住部门',decisive_choice:'叫停复核',relationship_effect:'下属不再信任他',evidence_quotes:['主管叫停复核。']}],reveal_aftershock:[{reveal_section_index:4,revelation:'原始凭证被交出',immediate_reader_shift:'期待公开对抗',consequence_seen:'partial',later_evidence_quotes:['审计员把原始凭证交给阿岚。','凭证重新归档。']}],promise_response:{title_expectation:'看见档案空缺背后的真相',payoff_status:'partial',evidence_quotes:['凭证重新归档。'],reader_aftertaste:'后果仍显仓促'},final_reader_state:{would_continue_or_recommend:'maybe',strongest_pull:'档案空缺真相',biggest_resistance:'后段收束过快'}};
const card={
  schemaVersion:'1.0.0',workflow_id:'wf-review',story_sha256:pack.story_sha256,decision:'revise',summary:'后段收束过快。',
  reader_response:reader,
  opening_assessment:{verdict:'concern',evidence_quote:'阿岚在复核里看见编号空缺。',reason:'开篇背景说明比例偏高。'},
  section_function_matrix:pack.section_metrics.map(row=>({section_index:row.section_index,structural_role:`第${row.section_index}节职责`,function_verdict:row.section_index>3?'concern':'pass',evidence_quote:row.opening_excerpt.slice(0,18),note:'逐节验收'})),
  character_arc_matrix:[
    {character:'阿岚',desire:'承担责任',independent_stake:'获得独立判断权',active_action:'公开证据',cost:'与上级决裂',relationship_effect:'与主管的保护关系破裂',change:'从等待到行动',verdict:'pass',evidence_quotes:['阿岚拿到档案单。']},
    {character:'主管',desire:'保住部门',independent_stake:'保住经营控制权',active_action:'叫停复核',cost:'失去下属信任',relationship_effect:'上下级关系转为对抗',change:'责任暴露',verdict:'concern',evidence_quotes:['主管叫停复核。']},
  ],
  identity_payoff_matrix:[{identity_or_trait:'复核员',identity_type:'职业与技能',setup_quote:'阿岚在复核里看见编号空缺。',payoff_quote:'主管叫停复核。',ongoing_participation:'后段未持续转化为行动能力',verdict:'concern'}],
  reveal_aftershock_matrix:[{reveal_section_index:4,revelation:'审计员交出原始凭证',immediate_consequence:'真相获得公开证据',downstream_change:'终局恢复归档但中间后果偏短',verdict:'concern',evidence_quotes:['审计员把原始凭证交给阿岚。','凭证重新归档。']}],
  climax_ending_assessment:{verdict:'fail',climax_quote:'审计员把原始凭证交给阿岚。',ending_quote:'凭证重新归档。',reason:'高潮和后果篇幅不足。'},
  findings:[{code:'TailCollapse',severity:'S2',scope:'第4-5节及小节大纲',evidence_quote:'凭证重新归档。',repair_direction:'先补高潮行动链和结尾后果，再重建对应 Brief。'}],
};
const valid=api.validateEditorialReviewCard(card,pack);if(valid.status!=='valid') throw new Error(JSON.stringify(valid));
delete card.character_arc_matrix[1].active_action;
const invalid=api.validateEditorialReviewCard(card,pack);if(invalid.status!=='invalid'||!invalid.findings.some(row=>row.field==='character_arc_matrix.active_action')) throw new Error(JSON.stringify(invalid));
card.character_arc_matrix[1].active_action='关闭直播';delete card.reveal_aftershock_matrix;
const missingAftershock=api.validateEditorialReviewCard(card,pack);if(missingAftershock.status!=='invalid'||!missingAftershock.findings.some(row=>row.field==='reveal_aftershock_matrix')) throw new Error(JSON.stringify(missingAftershock));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "reader profile cannot infer a platform from the directory or prose" {
  run node - "$REPO/scripts/lib/short-story-editorial-review.js" "$BATS_TEST_TMPDIR" <<'NODE'
const fs=require('fs'),path=require('path');
const review=require(process.argv[2]);
const root=process.argv[3];
fs.writeFileSync(path.join(root,'正文.md'),'## 第001节\n阿岚推开复核室门。\n');
const pack=review.attachEvidenceRuntime(review.buildShortStoryEvidencePack(root,{workflowId:'wf-reader'}),path.join(root,'正文.md'));
const card={schemaVersion:'1.0.0',workflow_id:'wf-reader',story_sha256:pack.story_sha256,decision:'revise',reader_response:{reader_profile:{target_platform:'短篇（未确认具体平台）',platform_mode:'free_feed_mobile',genre_lens:['现实'],style_lens:['fast_punchy'],reading_scene:'mobile_continuous',profile_basis:'项目目录推断'},section_reader_response:[{section_index:1,engagement:'engaged',felt_emotion:'好奇',reader_question:'发生了什么',evidence_quote:'阿岚推开复核室门。'}],drop_off_points:[],character_impressions:[{character:'阿岚',first_impression:'主动',later_impression:'主动',trust_change:'flat',evidence_quotes:['阿岚推开复核室门。']}],identity_continuity:[],identity_continuity_not_applicable_reason:'样本过短',supporting_character_reality:[],supporting_character_not_applicable_reason:'只有主角',reveal_aftershock:[],reveal_aftershock_not_applicable_reason:'尚无揭示',promise_response:{title_expectation:'进入复核室',payoff_status:'partial',evidence_quotes:['阿岚推开复核室门。'],reader_aftertaste:'待展开'},final_reader_state:{would_continue_or_recommend:'maybe',strongest_pull:'复核室',biggest_resistance:'信息少'}},opening_assessment:{verdict:'pass',evidence_quote:'阿岚推开复核室门。',reason:'直接进入场景'},section_function_matrix:[{section_index:1,structural_role:'开场',function_verdict:'pass',evidence_quote:'阿岚推开复核室门。'}],character_arc_matrix:[{character:'阿岚',desire:'查明情况',independent_stake:'确认眼前事实',active_action:'推门',cost:'未知',relationship_effect:'尚未展开',change:'开始行动',verdict:'concern',evidence_quotes:['阿岚推开复核室门。']}],identity_payoff_matrix:[],identity_not_applicable_reason:'样本过短',reveal_aftershock_matrix:[],reveal_aftershock_not_applicable_reason:'尚无揭示',climax_ending_assessment:{verdict:'concern',climax_quote:'阿岚推开复核室门。',ending_quote:'阿岚推开复核室门。',reason:'尚未展开'},findings:[{code:'SampleShort',severity:'S3',scope:'第1节',evidence_quote:'阿岚推开复核室门。',repair_direction:'继续观察'}]};
const out=review.validateEditorialReviewCard(card,pack);
if(out.status!=='invalid') throw new Error(JSON.stringify(out));
if(!out.findings.some(item=>item.field==='reader_response.reader_profile.platform_mode')) throw new Error(JSON.stringify(out));
if(!out.findings.some(item=>item.field==='reader_response.reader_profile.profile_basis')) throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "malformed reader evidence arrays return validation findings instead of crashing the workflow" {
  run node - "$REPO/scripts/lib/short-story-editorial-review.js" "$BOOK" <<'NODE'
const review=require(process.argv[2]);const root=process.argv[3];
const pack=review.buildShortStoryEvidencePack(root,{workflowId:'wf-malformed-reader'});
const reader={
  reader_profile:{target_platform:'未确认',platform_mode:'general_fiction',genre_lens:[],style_lens:[],reading_scene:'mobile_continuous',profile_basis:'用户未指定'},
  section_reader_response:[],drop_off_points:[],character_impressions:[],
  identity_continuity:{unexpected:'object'},supporting_character_reality:[],reveal_aftershock:[],
  promise_response:{title_expectation:'待核对',payoff_status:'partial',reader_aftertaste:'待核对',evidence_quotes:{unexpected:'object'}},
  final_reader_state:{would_continue_or_recommend:'maybe',strongest_pull:'待核对',biggest_resistance:'证据不足'},
};
const out=review.validateReaderResponseCard(reader,pack);
if(out.status!=='invalid'||!Array.isArray(out.findings)||!out.findings.length) throw new Error(JSON.stringify(out));
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

@test "editorial finalizer asks for a reader reaction artifact before the editor decision" {
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-review"
  cat > "$BOOK/追踪/workflow/tasks/wf-review/task.json" <<'JSON'
{"workflow_id":"wf-review","workflow_type":"short_write","task_dir":"追踪/workflow/tasks/wf-review","current_stage":"full_story_review","stage_execution":{"status":"running","stage_id":"full_story_review","owner_module":"story-review"}}
JSON
  run node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id wf-review --apply --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  node - "$output" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const out=JSON.parse(process.argv[2]);const root=process.argv[3];
if(out.status!=='short_story_reader_response_required') throw new Error(JSON.stringify(out));
if(!fs.existsSync(path.join(root,out.evidence_pack))) throw new Error('evidence pack missing');
if(fs.existsSync(path.join(root,out.review_card))) throw new Error('review card must be written by reviewers, not fabricated by the finalizer');
if(!out.reader_response_schema.section_reader_response||out.reader_response_schema.character_arc_matrix) throw new Error(JSON.stringify(out.reader_response_schema));
NODE
}

@test "reader and editor artifacts are isolated and invalid retries stop after one repair" {
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-split-review"
  cat > "$BOOK/追踪/workflow/tasks/wf-split-review/task.json" <<'JSON'
{"workflow_id":"wf-split-review","workflow_type":"short_write","task_dir":"追踪/workflow/tasks/wf-split-review","current_stage":"full_story_review","stage_execution":{"status":"running","stage_id":"full_story_review","owner_module":"story-review","stage_attempt_id":"sa-split"}}
JSON
  node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id wf-split-review --json > "$BATS_TEST_TMPDIR/reader-required.json"
  reader_path="$(node -p 'require(process.argv[1]).reader_response_card' "$BATS_TEST_TMPDIR/reader-required.json")"
  mkdir -p "$BOOK/$(dirname "$reader_path")"
  printf '%s\n' '{"reader_profile":{}}' > "$BOOK/$reader_path"

  node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id wf-split-review --json > "$BATS_TEST_TMPDIR/reader-invalid-1.json"
  node "$REPO/scripts/short-story-review-finalize.js" --project-root "$BOOK" --workflow-id wf-split-review --json > "$BATS_TEST_TMPDIR/reader-invalid-2.json"

  node - "$BATS_TEST_TMPDIR/reader-invalid-1.json" "$BATS_TEST_TMPDIR/reader-invalid-2.json" <<'NODE'
const first=require(process.argv[2]),second=require(process.argv[3]);
if(first.status!=='short_story_reader_response_invalid'||first.retry_budget_remaining!==0) throw new Error(JSON.stringify(first));
if(second.status!=='short_story_review_manual_resolution_required'||!second.retry_budget_exhausted) throw new Error(JSON.stringify(second));
NODE
}

@test "a revise verdict becomes task-scoped editorial feedback and returns to the existing impact workflow" {
  node - "$REPO" "$BOOK" "$BATS_TEST_TMPDIR/create.json" <<'NODE'
const fs=require('fs'),path=require('path');const [repo,root,out]=process.argv.slice(2);
const store=require(path.join(repo,'scripts/lib/workflow-v3/task-store.js'));
const task=store.createTaskRecord(root,{workflow_id:'wf-v3-editorial-revise',workflow_type:'short_write',current_stage:'editorial_review',user_goal:'验证审阅回炉'});
fs.writeFileSync(out,JSON.stringify({task},null,2));
NODE
  WORKFLOW_ID="$(node -e "console.log(require(process.argv[1]).task.workflow_id)" "$BATS_TEST_TMPDIR/create.json")"
  node - "$REPO" "$BOOK" "$WORKFLOW_ID" "$BATS_TEST_TMPDIR/required.json" <<'NODE'
const fs=require('fs'),path=require('path');const [repo,root,id,out]=process.argv.slice(2);
const engine=require(path.join(repo,'scripts/lib/workflow-v3/engine.js'));
const closure=require(path.join(repo,'scripts/lib/short-production/closure.js'));
fs.writeFileSync(out,JSON.stringify(closure.finalizeEditorialReview({projectRoot:root,task:engine.readTask(root,id)}),null,2));
NODE
  node - "$BOOK" "$BATS_TEST_TMPDIR/required.json" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2],required=require(process.argv[3]);const pack=JSON.parse(fs.readFileSync(path.join(root,required.evidence_pack)));const quote=i=>pack.section_metrics[i].opening_excerpt.slice(0,18);
const reader={reader_profile:{target_platform:'番茄短篇',platform_mode:'free_feed_mobile',genre_lens:['现实世情'],style_lens:['restrained_realism','suspense_gap'],reading_scene:'mobile_continuous',profile_basis:'设定.md'},section_reader_response:pack.section_metrics.map((row,i)=>({section_index:row.section_index,engagement:i>2?'wavering':'engaged',felt_emotion:'担心真相代价',reader_question:'下一步会发生什么',evidence_quote:quote(i)})),drop_off_points:[],character_impressions:[{character:'阿岚',first_impression:'被保护',later_impression:'开始行动',trust_change:'up',evidence_quotes:['阿岚拿到档案单。']}],identity_continuity:[{identity_or_trait:'复核员',visibility:'fading',reader_effect:'身份后续参与不足',evidence_quotes:['阿岚在复核里看见编号空缺。','主管叫停复核。']}],supporting_character_reality:[{character:'主管',felt_status:'thin',apparent_want:'保住部门',decisive_choice:'叫停复核',relationship_effect:'失去下属信任',evidence_quotes:['主管叫停复核。']}],reveal_aftershock:[{reveal_section_index:4,revelation:'原始凭证出现',immediate_reader_shift:'期待公开对抗',consequence_seen:'partial',later_evidence_quotes:['审计员把原始凭证交给阿岚。','凭证重新归档。']}],promise_response:{title_expectation:'档案空缺真相',payoff_status:'partial',evidence_quotes:['凭证重新归档。'],reader_aftertaste:'后果太快'},final_reader_state:{would_continue_or_recommend:'maybe',strongest_pull:'真相',biggest_resistance:'结尾压缩'}};
const card={schemaVersion:'1.0.0',workflow_id:pack.workflow_id,story_sha256:pack.story_sha256,decision:'revise',summary:'后段人物与高潮需要回炉。',reader_response:reader,opening_assessment:{verdict:'concern',evidence_quote:'阿岚在复核里看见编号空缺。',reason:'背景比例偏高。'},section_function_matrix:pack.section_metrics.map((row,i)=>({section_index:row.section_index,structural_role:`第${row.section_index}节职责`,function_verdict:i>2?'concern':'pass',evidence_quote:quote(i),note:'逐节验收'})),character_arc_matrix:[{character:'阿岚',desire:'承担责任',independent_stake:'获得独立判断权',active_action:'公开证据',cost:'上下级冲突',relationship_effect:'保护关系破裂',change:'开始独立决策',verdict:'pass',evidence_quotes:['阿岚拿到档案单。']},{character:'主管',desire:'保住部门',independent_stake:'保住经营控制权',active_action:'叫停复核',cost:'失去信任',relationship_effect:'上下级转为对抗',change:'责任暴露',verdict:'concern',evidence_quotes:['主管叫停复核。']}],identity_payoff_matrix:[{identity_or_trait:'复核员',identity_type:'职业与技能',setup_quote:'阿岚在复核里看见编号空缺。',payoff_quote:'主管叫停复核。',ongoing_participation:'后续参与不足',verdict:'concern'}],reveal_aftershock_matrix:[{reveal_section_index:4,revelation:'审计员交出原始凭证',immediate_consequence:'获得公开证据',downstream_change:'后果收束偏短',verdict:'concern',evidence_quotes:['审计员把原始凭证交给阿岚。','凭证重新归档。']}],climax_ending_assessment:{verdict:'fail',climax_quote:'审计员把原始凭证交给阿岚。',ending_quote:'凭证重新归档。',reason:'高潮和后果被压缩。'},findings:[{code:'TailCollapse',severity:'S2',scope:'第4-5节及小节大纲',evidence_quote:'凭证重新归档。',repair_direction:'先补高潮行动链和结尾责任后果，再重建受影响 Brief。'}]};
fs.writeFileSync(path.join(root,required.reader_response_card),JSON.stringify(reader,null,2));
fs.writeFileSync(path.join(root,required.review_card),JSON.stringify(card,null,2));
NODE
  run node - "$REPO" "$BOOK" "$WORKFLOW_ID" <<'NODE'
const path=require('path');const [repo,root,id]=process.argv.slice(2);
const engine=require(path.join(repo,'scripts/lib/workflow-v3/engine.js'));
const closure=require(path.join(repo,'scripts/lib/short-production/closure.js'));
const task=engine.readTask(root,id);const result=closure.finalizeEditorialReview({projectRoot:root,task});
if(result.kind!=='completed') throw new Error(JSON.stringify(result));
const outcome=engine.applyStageResult(root,id,task.state_version,result);
console.log(JSON.stringify(outcome));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const task=require(`${process.argv[2]}/追踪/workflow/tasks/${process.argv[3]}/task.json`);
if(task.current_stage!=='editorial_review') throw new Error(JSON.stringify(task.current_stage));
const item=(((task.pending_feedback||{}).proposed_plan||{}).review_findings||[])[0];
if(!item||item.code!=='TailCollapse'||!item.visible_title) throw new Error(JSON.stringify(task.pending_feedback));
if((task.pending_action||{}).feedback_id!==(task.pending_feedback||{}).id) throw new Error(JSON.stringify(task.pending_action));
if((task.short_full_story_review||{}).decision!=='revise') throw new Error(JSON.stringify(task.short_full_story_review));
NODE
}

@test "a pass verdict advances to expression cleanup without writing story facts" {
  node - "$REPO" "$BOOK" "$BATS_TEST_TMPDIR/pass-create.json" <<'NODE'
const fs=require('fs'),path=require('path');const [repo,root,out]=process.argv.slice(2);
const store=require(path.join(repo,'scripts/lib/workflow-v3/task-store.js'));
const task=store.createTaskRecord(root,{workflow_id:'wf-v3-editorial-pass',workflow_type:'short_write',current_stage:'editorial_review',user_goal:'验证审阅通过'});
fs.writeFileSync(out,JSON.stringify({task},null,2));
NODE
  WORKFLOW_ID="$(node -e "console.log(require(process.argv[1]).task.workflow_id)" "$BATS_TEST_TMPDIR/pass-create.json")"
  node - "$REPO" "$BOOK" "$WORKFLOW_ID" "$BATS_TEST_TMPDIR/pass-required.json" <<'NODE'
const fs=require('fs'),path=require('path');const [repo,root,id,out]=process.argv.slice(2);
const engine=require(path.join(repo,'scripts/lib/workflow-v3/engine.js'));
const closure=require(path.join(repo,'scripts/lib/short-production/closure.js'));
fs.writeFileSync(out,JSON.stringify(closure.finalizeEditorialReview({projectRoot:root,task:engine.readTask(root,id)}),null,2));
NODE
  node - "$BOOK" "$BATS_TEST_TMPDIR/pass-required.json" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2],required=require(process.argv[3]);const pack=JSON.parse(fs.readFileSync(path.join(root,required.evidence_pack)));const quote=i=>pack.section_metrics[i].opening_excerpt.slice(0,18);
const reader={reader_profile:{target_platform:'番茄短篇',platform_mode:'free_feed_mobile',genre_lens:['现实世情'],style_lens:['restrained_realism','suspense_gap'],reading_scene:'mobile_continuous',profile_basis:'设定.md'},section_reader_response:pack.section_metrics.map((row,i)=>({section_index:row.section_index,engagement:'engaged',felt_emotion:'持续关注真相',reader_question:'后果如何落地',evidence_quote:quote(i)})),drop_off_points:[],character_impressions:[{character:'阿岚',first_impression:'被保护',later_impression:'主动承担',trust_change:'up',evidence_quotes:['阿岚拿到档案单。']}],identity_continuity:[{identity_or_trait:'复核员',visibility:'present',reader_effect:'复核经验参与公开行动',evidence_quotes:['阿岚在复核里看见编号空缺。','主管叫停复核。']}],supporting_character_reality:[{character:'主管',felt_status:'alive',apparent_want:'保住部门',decisive_choice:'叫停复核',relationship_effect:'承担失去下属信任的后果',evidence_quotes:['主管叫停复核。']}],reveal_aftershock:[{reveal_section_index:4,revelation:'原始凭证出现',immediate_reader_shift:'确认真相可被证明',consequence_seen:'yes',later_evidence_quotes:['审计员把原始凭证交给阿岚。','凭证重新归档。']}],promise_response:{title_expectation:'档案空缺真相',payoff_status:'fulfilled',evidence_quotes:['凭证重新归档。'],reader_aftertaste:'真实归档回归'},final_reader_state:{would_continue_or_recommend:'yes',strongest_pull:'人物选择',biggest_resistance:'无明显阻力'}};
const card={schemaVersion:'1.0.0',workflow_id:pack.workflow_id,story_sha256:pack.story_sha256,decision:'pass',summary:'全篇可进入表达清理。',reader_response:reader,opening_assessment:{verdict:'pass',evidence_quote:'阿岚在复核里看见编号空缺。',reason:'开篇直接进入核心冲突。'},section_function_matrix:pack.section_metrics.map((row,i)=>({section_index:row.section_index,structural_role:`第${row.section_index}节职责`,function_verdict:'pass',evidence_quote:quote(i),note:'功能完成'})),character_arc_matrix:[{character:'阿岚',desire:'承担责任',independent_stake:'获得独立判断权',active_action:'公开证据',cost:'上下级冲突',relationship_effect:'重写上下级边界',change:'开始独立决策',verdict:'pass',evidence_quotes:['阿岚拿到档案单。']},{character:'主管',desire:'保住部门',independent_stake:'保住经营控制权',active_action:'叫停复核',cost:'失去信任',relationship_effect:'上下级关系改变',change:'承担后果',verdict:'pass',evidence_quotes:['主管叫停复核。']}],identity_payoff_matrix:[{identity_or_trait:'复核员',identity_type:'职业与技能',setup_quote:'阿岚在复核里看见编号空缺。',payoff_quote:'主管叫停复核。',ongoing_participation:'复核经验持续参与行动',verdict:'pass'}],reveal_aftershock_matrix:[{reveal_section_index:4,revelation:'审计员交出原始凭证',immediate_consequence:'真相获得公开证据',downstream_change:'推动责任结算和真实归档恢复',verdict:'pass',evidence_quotes:['审计员把原始凭证交给阿岚。','凭证重新归档。']}],climax_ending_assessment:{verdict:'pass',climax_quote:'审计员把原始凭证交给阿岚。',ending_quote:'凭证重新归档。',reason:'高潮证据推动终局兑现。'},findings:[]};
fs.writeFileSync(path.join(root,required.reader_response_card),JSON.stringify(reader,null,2));
fs.writeFileSync(path.join(root,required.review_card),JSON.stringify(card,null,2));
NODE
  run node - "$REPO" "$BOOK" "$WORKFLOW_ID" <<'NODE'
const path=require('path');const [repo,root,id]=process.argv.slice(2);
const engine=require(path.join(repo,'scripts/lib/workflow-v3/engine.js'));
const closure=require(path.join(repo,'scripts/lib/short-production/closure.js'));
const task=engine.readTask(root,id);const result=closure.finalizeEditorialReview({projectRoot:root,task});
if(result.kind!=='completed') throw new Error(JSON.stringify(result));
const outcome=engine.applyStageResult(root,id,task.state_version,result);
console.log(JSON.stringify(outcome));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const task=require(`${process.argv[2]}/追踪/workflow/tasks/${process.argv[3]}/task.json`);
if(task.current_stage!=='deslop'||task.pending_feedback) throw new Error(JSON.stringify({stage:task.current_stage,feedback:task.pending_feedback}));
if((task.short_full_story_review||{}).decision!=='pass') throw new Error(JSON.stringify(task.short_full_story_review));
if((task.short_full_story_review||{}).visible_label!=='故事层可进入表达清理') throw new Error(JSON.stringify(task.short_full_story_review));
NODE
}
