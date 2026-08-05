#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/short-memory-book"
  mkdir -p "$BOOK/追踪/memory" "$BOOK/追踪/schema" "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow/tasks/wf-short"
  printf '%s\n' '{"project_id":"short-a","project_title":"档案复核","plan_revision":1,"current_section_index":1,"accepted_sections":[{"section_index":1}],"narrative":{"planned_sections":3}}' > "$BOOK/追踪/private-short-extension/project-state.json"
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：开场
## 第2节：凭证
- 结构功能：公开第一份证据。
- 承接上节：主管拿出成本账册。
- 场景动作：阿岚把账册摊到负责人面前。
- 子事件：
  1. 阿岚核对签名。
  2. 负责人认出签名。
- 情绪目标：压迫转主动。
- 压力变化：口头争执升级为可核验的账目冲突。
- 因果链：质疑 -> 出示账册 -> 负责人认出签名。
- 角色选择：阿岚拒绝让主管代她解释。
- 可见阻力：主管试图抢回账册。
- 本节兑现：成本账册证明宣传说法不实。
- 关系变化：阿岚与负责人从争执转为共同核验。
- 代价升级：阿岚可能失去部门职位。
- 核心承诺兑现：阿岚第一次用部门账册推翻公开宣传。
- 决定性行动：阿岚保存账册副本。
- 即时代价：主管当场切断她的工作权限。
- 节尾钩子：负责人认出签名。
## 第3节：反转
EOF
  printf '%s\n' '# 设定' '第一人称。阿岚负责查证。' > "$BOOK/设定.md"
  printf '%s\n' '# 素材卡' '虚构机构凭证的宣传争议。' > "$BOOK/素材卡.md"
  printf '%s\n' '# 第2节写作提要' '## 本节任务' '阿岚出示成本账册。' '## 视角与称谓' '第一人称。' '## 禁止漂移' '不得新增主管救过部门的设定。' '## 验收标准' '账册改变负责人态度。' > "$BOOK/写作Brief_第002节.md"
  printf '%s\n' '{"workflow_id":"wf-short","section_index":1,"status":"accepted","canonical_path":"正文/第001节.md","section_summary":"阿岚公开质疑宣传。","character_state":{"阿岚":"决定复核"},"open_hook":"主管拿出成本账册。"}' > "$BOOK/追踪/private-short-extension/section-001-anchor.json"
  printf '%s\n' '{"fact_id":"fact.section-1.summary","subject":"档案复核","predicate":"本节发生","object":"阿岚公开质疑宣传。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' > "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"fact_id":"fact.character-alan","subject":"阿岚","predicate":"第1节状态","object":"决定复核，不再接受主管代她表态。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"fact_id":"fact.future","subject":"阿岚","predicate":"第3节状态","object":"尚未发生的结局。","scope":{"book":"current","section":3},"status":"active","evidence":[{"path":"正文/第003节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"rule_id":"style-natural-dialogue","status":"active","content":"对白先回应眼前的人和动作，不用总结式台词。","scope":"short_write"}' > "$BOOK/追踪/schema/user-style-rules.jsonl"
  printf '%s\n' '{"entryId":"pref-menu","status":"accepted","category":"interaction","scope":"workflow","content":"首屏使用数字菜单。"}' > "$BOOK/追踪/workflow/preference-memory.jsonl"
  printf '%s\n' '{"entryId":"pref-voice","status":"accepted","category":"voice","scope":"short_write","content":"对话保持克制，不用长篇宣言。"}' >> "$BOOK/追踪/workflow/preference-memory.jsonl"
  printf '%s\n' '{"rule_id":"pollution-loop","status":"active","content":"禁止同一领域词连续循环填充。","scope":"short_write"}' > "$BOOK/追踪/schema/output-pollution-rules.jsonl"
  printf '%s\n' '{"source_kind":"canonical_setting","presentCharacters":[],"characters":{"阿岚":{"role":"protagonist","aliases":["我"]},"主管":{"role":"supporting","aliases":["主管"],"goal":"保住部门"}}}' > "$BOOK/追踪/memory/active-cast.json"
}

@test "short memory snapshot selects accepted continuity facts and emits a read receipt" {
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节'};
const out=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'draft_next_section'});
if(out.status!=='assembled'||!out.receipt.memory_revision) throw new Error(JSON.stringify(out));
const ids=out.receipt.selected_entry_ids;
if(!ids.includes('fact.character-alan')||ids.includes('fact.future')) throw new Error(JSON.stringify(out));
const text=JSON.stringify(out.payload);
if(!text.includes('决定复核')||!text.includes('对白先回应眼前的人')||!text.includes('对话保持克制')||!text.includes('禁止同一领域词')) throw new Error(text);
if(text.includes('首屏使用数字菜单')) throw new Error('workflow preference leaked into prose memory');
if(text.includes('尚未发生的结局')) throw new Error(text);
if(!text.includes('主管')||!text.includes('保住部门')) throw new Error(`character alias was not recalled: ${text}`);
const obligations=out.payload.continuity_obligations||[];
if(!obligations.some(item=>item.source_id==='fact.character-alan'&&item.requirement==='preserve_or_explain_change')) throw new Error(JSON.stringify(out.payload));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "accepted short planning projects a reader promise and recalls only current section obligations" {
  cat > "$BOOK/素材卡.md" <<'EOF'
# 素材卡
- 标题承诺：复核现场里没有凭证，主角必须让真实归档重新回到镜头里。
- 目标情绪：从被主管保护到主动承担公开真相的代价。
EOF
  cat > "$BOOK/设定.md" <<'EOF'
# 设定
- 主角渴望：被团队当成能够承担责任的人。
- 主角恐惧：成为替部门谎言背书的自己人。
- 关系债：主管曾替全组扛住工资危机，主角不能把他写成纯粹恶人。
- 终局兑现：恢复真实凭证归档、核验、检测和公开追溯。
EOF
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：公开质疑
- 本节升级：主角发现复核镜头刻意避开归档流程。
## 第2节：成本账册
- 本节升级：主管用员工工资逼主角沉默，主角选择继续核验。
- 本节兑现：部门保护第一次变成可见压力。
## 第3节：旧视频
- 本节升级：主角发现所谓当天视频三年前就上传了。
## 第9节：复核里终于有了凭证
- 终局兑现：真实凭证重新归档，核验与检测全程公开。
EOF
  run node - "$REPO/scripts/lib/short-reader-promise.js" "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const promiseApi=require(process.argv[2]);const memoryApi=require(process.argv[3]);const root=process.argv[4];
const task={workflow_id:'wf-short',workflow_type:'private_short_startup',current_stage:'section_plan_lock',scope:'第2节'};
const projected=promiseApi.projectShortReaderPromise(root,task,{stage_id:'section_plan_lock',step_status:'completed',result_packet_path:'result.json'});
if(projected.status!=='reader_promise_projected') throw new Error(JSON.stringify(projected));
const out=memoryApi.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
const text=JSON.stringify(out.payload.reader_promise||{});
if(!text.includes('复核现场里没有凭证')||!text.includes('能够承担责任')||!text.includes('工资逼主角沉默')||!text.includes('恢复真实凭证归档')) throw new Error(text);
if(text.includes('三年前就上传')) throw new Error(`future section leaked: ${text}`);
if(!(out.payload.continuity_obligations||[]).some(row=>row.kind==='reader_promise')) throw new Error(JSON.stringify(out.payload));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "incomplete short planning is recorded as partial and is not injected as active memory" {
  cat > "$BOOK/素材卡.md" <<'EOF'
# 素材卡
- 核心冲突：家族要求主角继续替失实宣传背书。
EOF
  cat > "$BOOK/设定.md" <<'EOF'
# 设定
- 主角渴望：查明真相。
EOF
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：进入现场
- 本节升级：主角发现现场没有凭证归档。
EOF
  run node - "$REPO/scripts/lib/short-reader-promise.js" "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const promiseApi=require(process.argv[2]);const memoryApi=require(process.argv[3]);const root=process.argv[4];
const task={workflow_id:'wf-short',workflow_type:'short_write',current_stage:'section_plan_lock',scope:'第1节'};
const projected=promiseApi.projectShortReaderPromise(root,task,{stage_id:'section_plan_lock',step_status:'completed'});
if(projected.status!=='reader_promise_projection_incomplete') throw new Error(JSON.stringify(projected));
const stored=JSON.parse(fs.readFileSync(path.join(root,'追踪/memory/reader-promise.json'),'utf8'));
if(stored.status!=='partial'||!stored.missing_fields.includes('final_payoff')) throw new Error(JSON.stringify(stored));
const out=memoryApi.buildShortMemorySnapshot(root,{task,sectionIndex:1,stageId:'section_brief'});
if(out.payload.reader_promise) throw new Error(JSON.stringify(out.payload.reader_promise));
const warning=(out.payload.memory_warnings||[]).find(item=>item.code==='reader_promise_partial');
if(!warning||!warning.missing_fields.includes('final_payoff')) throw new Error(JSON.stringify(out.payload.memory_warnings));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "due promises and previous hooks become current section continuity obligations" {
  printf '%s\n' '{"promise_id":"promise-signature","summary":"负责人必须说明为何认得签名。","status":"active","opened_section":1,"target_section":2}' > "$BOOK/追踪/schema/promises.jsonl"
  printf '%s\n' '{"fact_id":"fact.hook-signature","subject":"档案复核","predicate":"留下待续钩子","object":"负责人认出了签名。","scope":{"book":"current","section":1},"status":"active"}' >> "$BOOK/追踪/memory/facts.jsonl"
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节'};
const out=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
const rows=out.payload.continuity_obligations||[];
if(!rows.some(item=>item.source_id==='fact.hook-signature'&&item.requirement==='progress_or_hold_explicitly')) throw new Error(JSON.stringify(rows));
if(!rows.some(item=>item.source_id==='promise-signature'&&item.requirement==='must_progress_now')) throw new Error(JSON.stringify(rows));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "brief generation does not invalidate its own memory receipt" {
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',scope:'第2节'};
const first=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
fs.writeFileSync(path.join(root,'写作Brief_第002节.md'),'# 写作 Brief：第002节\n\n## 本节任务\n这是本轮刚生成的新提要。\n');
const second=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
if(first.receipt.memory_revision!==second.receipt.memory_revision) throw new Error(JSON.stringify({first:first.receipt,second:second.receipt}));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "short project runtime fields do not make memory receipts stale" {
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const stateFile=path.join(root,'追踪/private-short-extension/project-state.json');
const task={workflow_id:'wf-short',workflow_type:'short_write',scope:'第2节'};
const first=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
const state=JSON.parse(fs.readFileSync(stateFile,'utf8'));
fs.writeFileSync(stateFile,`${JSON.stringify({...state,status:'section_002_brief_ready',current_stage:'section_draft_ready',current_section_index:2,updated_at:'2026-07-28T00:00:00.000Z'},null,2)}\n`);
const second=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
if(first.receipt.source_digests['追踪/story-system/short/project-state.json']!==second.receipt.source_digests['追踪/story-system/short/project-state.json']) throw new Error(JSON.stringify({first:first.receipt.source_digests,second:second.receipt.source_digests}));
if(first.receipt.memory_revision!==second.receipt.memory_revision) throw new Error(JSON.stringify({first:first.receipt,second:second.receipt}));
fs.writeFileSync(stateFile,`${JSON.stringify({...state,plan_revision:2,plan_digest:'changed-plan'},null,2)}\n`);
const third=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
if(second.receipt.source_digests['追踪/story-system/short/project-state.json']===third.receipt.source_digests['追踪/story-system/short/project-state.json']) throw new Error(JSON.stringify({second:second.receipt.source_digests,third:third.receipt.source_digests}));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "short memory collapses duplicate section summaries hooks and reveals before budgeting" {
  printf '%s\n' '{"fact_id":"fact.summary-duplicate","subject":"全篇","predicate":"本节发生","object":"这是一段重复且更长的第1节摘要，只用于验证旧投影不会重复注入上下文。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"fact_id":"fact.hook-duplicate","subject":"全篇","predicate":"留下待续钩子","object":"负责人沉默。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"fact_id":"fact.reveal-a","subject":"全篇","predicate":"本节揭示","object":"复核素材与实时画面不一致。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"fact_id":"fact.reveal-b","subject":"当前作品","predicate":"第1节揭示","object":"复核素材与实时画面不一致，且旧素材时间需要继续核验。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',scope:'第2节'};
const out=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
const facts=out.payload.accepted_facts||[];
const summaries=facts.filter(row=>/本节发生/.test(row.predicate)||row.subject==='summary');
const hooks=facts.filter(row=>/钩子|待续|承诺/.test(row.predicate));
const reveals=facts.filter(row=>/揭示/.test(row.predicate));
if(summaries.length!==1||hooks.length!==1||reveals.length!==1) throw new Error(JSON.stringify(facts));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "next section stage packet carries the compiled memory snapshot and receipt" {
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const {buildStageContextPacket}=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节',current_stage:'draft_next_section',task_dir:'追踪/workflow/tasks/wf-short',stage_execution:{stage_attempt_id:'sa-2'}};
const out=buildStageContextPacket({projectRoot:root,task,stage:'draft_next_section'});
if(out.status!=='assembled'||!out.memory_read_receipt||!out.memory_read_receipt.memory_revision) throw new Error(JSON.stringify(out));
if(out.memory_read_receipt.stage_attempt_id!=='sa-2'||out.memory_read_receipt.work_unit_id) throw new Error(JSON.stringify(out.memory_read_receipt));
const markdown=fs.readFileSync(path.join(root,out.packet_md),'utf8');
if(!markdown.includes('当前作品记忆快照')||!markdown.includes('决定复核')) throw new Error(markdown);
const meta=JSON.parse(fs.readFileSync(path.join(root,out.packet_json),'utf8'));
if(meta.memory_read_receipt.memory_revision!==out.memory_read_receipt.memory_revision) throw new Error(JSON.stringify(meta));
if(meta.memory_read_receipt.stage_attempt_id!=='sa-2') throw new Error(JSON.stringify(meta.memory_read_receipt));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "accepted planning feedback is recalled by the affected section and becomes stale after plan drift" {
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" "$REPO/scripts/lib/short-planning-memory.js" "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const feedbackApi=require(process.argv[2]);
const planningApi=require(process.argv[3]);
const memoryApi=require(process.argv[4]);
const root=process.argv[5];
const task={workflow_id:'wf-short',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short',current_stage:'feedback_apply_patch',scope:'第2节',stage_execution:{stage_attempt_id:'sa-feedback-2'}};
feedbackApi.enqueueShortFeedback(root,task,'第2节必须让主管守住底线，不能无条件替阿岚洗白。',{sectionIndex:2,scopeSnapshot:'第2节',receivedAt:'2026-07-22T02:00:00.000Z'});
const result={workflow_id:'wf-short',workflow_type:'short_write',stage_id:'feedback_apply_patch',step_status:'completed',impact_level:'planning',changed_assets:['小节大纲.md'],changed_files:['小节大纲.md'],affected_sections:[2],result_packet_path:'追踪/workflow/tasks/wf-short/result-packets/feedback_apply_patch.result.json'};
const projected=planningApi.projectAcceptedShortPlanningFeedback(root,task,result);
if(projected.status!=='planning_constraints_projected'||projected.projected!==1) throw new Error(JSON.stringify(projected));
const first=memoryApi.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
if(first.status!=='assembled'||!JSON.stringify(first.payload.canon_constraints).includes('主管守住底线')) throw new Error(JSON.stringify(first));
if(!first.payload.continuity_obligations.some(row=>row.kind==='accepted_planning_constraint')) throw new Error(JSON.stringify(first.payload));
fs.appendFileSync(path.join(root,'小节大纲.md'),'\n- 用户后来重新规划了本节。\n');
const stale=memoryApi.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
if(JSON.stringify(stale.payload.canon_constraints).includes('主管守住底线')) throw new Error(JSON.stringify(stale.payload));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "whole-story planning memory still respects its explicit affected sections" {
  printf '%s\n' '{"schema_version":"1.0.0","constraint_id":"constraint.ending-only","type":"planning_constraint","content":"召回、员工安置、治理整改与最终复产只在第8至9节兑现。","status":"active","scope":{"book":"current","whole_story":true},"affected_sections":[8,9],"source_refs":[{"path":"小节大纲.md","hash":"PLACEHOLDER"}]}' > "$BOOK/追踪/memory/planning-constraints.jsonl"
  node -e "const fs=require('fs'),c=require('crypto');const f=process.argv[1],o=process.argv[2],h='sha256:'+c.createHash('sha256').update(fs.readFileSync(f)).digest('hex');fs.writeFileSync(o,fs.readFileSync(o,'utf8').replace('PLACEHOLDER',h));" "$BOOK/小节大纲.md" "$BOOK/追踪/memory/planning-constraints.jsonl"
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',scope:'第4节'};
const middle=api.buildShortMemorySnapshot(root,{task,sectionIndex:4,stageId:'next_section_brief'});
if(JSON.stringify(middle.payload.canon_constraints).includes('最终复产')) throw new Error(JSON.stringify(middle.payload.canon_constraints));
const ending=api.buildShortMemorySnapshot(root,{task:{...task,scope:'第8节'},sectionIndex:8,stageId:'next_section_brief'});
if(!JSON.stringify(ending.payload.canon_constraints).includes('最终复产')) throw new Error(JSON.stringify(ending.payload.canon_constraints));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "legacy broad planning rows are narrowed by the requirement text during recall" {
  printf '%s\n' '{"schema_version":"1.0.0","constraint_id":"constraint.legacy-broad","type":"planning_constraint","content":"影响范围：第9节正文。只在第9节完成董事会与复产收束。","status":"active","scope":{"book":"current","whole_story":true},"affected_sections":[1,4,7,8,9],"source_refs":[{"path":"小节大纲.md","hash":"PLACEHOLDER"}]}' > "$BOOK/追踪/memory/planning-constraints.jsonl"
  node -e "const fs=require('fs'),c=require('crypto');const f=process.argv[1],o=process.argv[2],h='sha256:'+c.createHash('sha256').update(fs.readFileSync(f)).digest('hex');fs.writeFileSync(o,fs.readFileSync(o,'utf8').replace('PLACEHOLDER',h));" "$BOOK/小节大纲.md" "$BOOK/追踪/memory/planning-constraints.jsonl"
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const middle=api.buildShortMemorySnapshot(root,{task:{workflow_id:'wf-short',workflow_type:'short_write',scope:'第4节'},sectionIndex:4,stageId:'next_section_brief'});
if(JSON.stringify(middle.payload.canon_constraints).includes('复产收束')) throw new Error(JSON.stringify(middle.payload.canon_constraints));
const ending=api.buildShortMemorySnapshot(root,{task:{workflow_id:'wf-short',workflow_type:'short_write',scope:'第9节'},sectionIndex:9,stageId:'next_section_brief'});
if(!JSON.stringify(ending.payload.canon_constraints).includes('复产收束')) throw new Error(JSON.stringify(ending.payload.canon_constraints));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "active accepted plan remains available to its revision child after canonical files change" {
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const task={
  workflow_id:'wf-short',
  workflow_type:'private_short_startup',
  scope:'第2节',
  accepted_plan:{
    plan_id:'accepted-plan.archive',
    status:'projected_to_canonical_memory',
    projection_status:'completed',
    affected_sections:[1,2,8,9],
    requirements:[{requirement_id:'req-ending',text:'结局必须兑现已确认的真实归档承诺。'}],
    projected_assets:['设定.md','小节大纲.md'],
  },
  feedback_revision_queue:{
    status:'running',
    current_section_index:2,
    affected_sections:[1,2,8,9],
    items:[{section_index:2,status:'pending'}],
  },
};
const out=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
const serialized=JSON.stringify(out.payload);
if(!out.contract.query.needs.includes('planning_constraints')) throw new Error(JSON.stringify(out.contract.query));
if(!serialized.includes('结局必须兑现已确认的真实归档承诺')) throw new Error(serialized);
if(!(out.payload.continuity_obligations||[]).some(row=>row.kind==='accepted_planning_constraint')) throw new Error(serialized);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "task-scoped accepted plan filters each review requirement by its own impact range" {
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]),root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'private_short_startup',scope:'第4节',accepted_plan:{plan_id:'plan-review',status:'projected_to_canonical_memory',projection_status:'completed',affected_sections:[1,4,7,8,9],requirements:[
  {requirement_id:'req-one',text:'影响范围：第1节正文。压缩开场。'},
  {requirement_id:'req-middle',text:'影响范围：第4-7节正文。保持标题承诺。'},
  {requirement_id:'req-nine',text:'影响范围：第9节正文。完成终局。'},
]},feedback_revision_queue:{status:'running',affected_sections:[1,4,7,8,9]}};
const out=api.buildShortMemorySnapshot(root,{task,sectionIndex:4,stageId:'next_section_brief'});
const text=JSON.stringify(out.payload.canon_constraints);
if(!text.includes('保持标题承诺')||text.includes('压缩开场')||text.includes('完成终局')) throw new Error(text);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an accepted plan cannot escape its explicit section scope through a broader revision queue" {
  mkdir -p "$BOOK/正文"
  printf '%s\n' '第1节结尾：主管拿出成本账册。' > "$BOOK/正文/第001节.md"
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const memoryApi=require(process.argv[2]),packetApi=require(process.argv[3]),root=process.argv[4];
const task={
  workflow_id:'wf-short-scope',workflow_type:'short_write',scope:'第2节',current_stage:'section_brief',
  task_dir:'追踪/workflow/tasks/wf-short-scope',
  stage_execution:{stage_attempt_id:'sa-scope-2',section_index:2},
  accepted_plan:{
    plan_id:'accepted-plan.section-one',status:'completed',projection_status:'completed',affected_sections:[1],
    requirements:[{requirement_id:'req-one',text:'第1节补齐公开动作，并承接第2节现有开场。'}],
  },
  feedback_revision_queue:{
    status:'running',feedback_id:'feedback-whole-revision',current_section_index:2,affected_sections:[1,2],
    items:[{section_index:1,status:'accepted'},{section_index:2,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}],
  },
};
const snapshot=memoryApi.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'section_brief'});
if(JSON.stringify(snapshot.payload.canon_constraints).includes('第1节补齐公开动作')) {
  throw new Error('section-1 accepted plan leaked into section-2 memory snapshot');
}
const packet=packetApi.buildStageContextPacket({projectRoot:root,task,stage:'section_brief'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
const markdown=fs.readFileSync(path.join(root,packet.packet_md),'utf8');
if(markdown.includes('第1节补齐公开动作')) throw new Error('section-1 accepted plan leaked into section-2 stage packet');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "revision section context packet carries the confirmed plan obligations" {
  mkdir -p "$BOOK/正文"
  printf '%s\n' '第1节结尾：主管拿出成本账册。' > "$BOOK/正文/第001节.md"
  printf '%s\n' '{"project_id":"short-a","project_title":"档案复核","current_section_index":10,"accepted_sections":[{"section_index":1},{"section_index":2},{"section_index":3},{"section_index":4},{"section_index":5},{"section_index":6},{"section_index":7},{"section_index":8},{"section_index":9}]}' > "$BOOK/追踪/private-short-extension/project-state.json"
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={
  workflow_id:'wf-short',
  workflow_type:'private_short_startup',
  scope:'第2节',
  current_stage:'next_section_brief',
  task_dir:'追踪/workflow/tasks/wf-short',
  stage_execution:{stage_attempt_id:'sa-brief-2'},
  accepted_plan:{
    plan_id:'accepted-plan.archive',
    status:'projected_to_canonical_memory',
    summary:'按确认方案重构全篇。',
    requirements:[{requirement_id:'req-ending',text:'结局必须兑现真实归档承诺。'}],
  },
  feedback_revision_queue:{
    status:'running',
    feedback_id:'feedback-archive',
    current_section_index:2,
    affected_sections:[1,2],
    items:[{section_index:1,status:'accepted'},{section_index:2,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}],
    groups:[{group_id:'opening',section_indices:[1,2],goal:'重建开篇压力链',completion_rule:'逐节重新采用'}],
  },
};
const out=api.buildStageContextPacket({projectRoot:root,task,stage:'next_section_brief'});
if(out.status!=='assembled') throw new Error(JSON.stringify(out));
if(out.section_index!==2) throw new Error(JSON.stringify(out));
const markdown=fs.readFileSync(path.join(root,out.packet_md),'utf8');
if(!markdown.includes('accepted_revision_obligations')||!markdown.includes('结局必须兑现真实归档承诺')||!markdown.includes('重建开篇压力链')||!markdown.includes('当前作品记忆快照.canon_constraints')) throw new Error(markdown);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "next-section Brief context excludes prior section quality and historical length diagnostics" {
  mkdir -p "$BOOK/正文"
  printf '%s\n' '第1节结尾：主管拿出成本账册。' > "$BOOK/正文/第001节.md"
  cat > "$BOOK/追踪/private-short-extension/section-001-anchor.json" <<'JSON'
{"workflow_id":"wf-short","section_index":1,"status":"accepted","canonical_path":"正文/第001节.md","section_summary":"阿岚公开质疑宣传。","open_hook":"主管拿出成本账册。","quality_result":{"machine_gate":"pass","story_value_gate":"pass","length_policy":{"baseline_chars":1600,"lower_bound":1400,"upper_bound":1800,"status":"advisory","note":"历史篇幅提醒，不是下一节目标。"}}}
JSON
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const task = {
  workflow_id: 'wf-short',
  workflow_type: 'short_write',
  scope: '第2节',
  current_stage: 'section_brief',
  task_dir: '追踪/workflow/tasks/wf-short',
  stage_execution: { stage_attempt_id: 'sa-brief-2', section_index: 2 },
};
const out = api.buildStageContextPacket({ projectRoot: root, task, stage: 'section_brief' });
if (out.status !== 'assembled') throw new Error(JSON.stringify(out));
const markdown = fs.readFileSync(path.join(root, out.packet_md), 'utf8');
if (!markdown.includes('主管拿出成本账册')) throw new Error('continuity anchor was lost');
if (/quality_result|length_policy|baseline_chars|历史篇幅提醒/.test(markdown)) {
  throw new Error(`prior-section quality diagnostics leaked into Brief context:\n${markdown}`);
}
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "revision context packet recovers confirmed obligations from canonical planning memory" {
  mkdir -p "$BOOK/正文"
  printf '%s\n' '第1节结尾：主管拿出成本账册。' > "$BOOK/正文/第001节.md"
  printf '%s\n' '{"project_id":"short-a","project_title":"档案复核","current_section_index":10,"accepted_sections":[{"section_index":1},{"section_index":2},{"section_index":3},{"section_index":4},{"section_index":5},{"section_index":6},{"section_index":7},{"section_index":8},{"section_index":9}]}' > "$BOOK/追踪/private-short-extension/project-state.json"
  printf '%s\n' '{"schema_version":"1.0.0","constraint_id":"constraint.archive-ending","type":"planning_constraint","content":"第9节必须让真实凭证重新归档，旧档主动纠错，长程核验链路体现真朋友与塑料关系。","status":"active","source_kind":"user_confirmed_plan","scope":{"book":"current","whole_story":true},"affected_sections":[2,9],"provenance":{"workflow_id":"wf-short","feedback_id":"feedback-archive","plan_id":"accepted-plan.archive"}}' > "$BOOK/追踪/memory/planning-constraints.jsonl"
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={
  workflow_id:'wf-short',
  workflow_type:'private_short_startup',
  scope:'第2节',
  current_stage:'next_section_brief',
  task_dir:'追踪/workflow/tasks/wf-short',
  stage_execution:{stage_attempt_id:'sa-brief-2'},
  feedback_revision_queue:{
    status:'running',
    feedback_id:'feedback-archive',
    current_section_index:2,
    affected_sections:[2,9],
    items:[{section_index:2,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}],
  },
};
const out=api.buildStageContextPacket({projectRoot:root,task,stage:'next_section_brief'});
if(out.status!=='assembled') throw new Error(JSON.stringify(out));
const markdown=fs.readFileSync(path.join(root,out.packet_md),'utf8');
if(!markdown.includes('accepted_revision_obligations')) throw new Error(markdown);
if(!markdown.includes('真实凭证重新归档')||!markdown.includes('长程核验链路体现真朋友与塑料关系')) throw new Error(markdown);
if(!markdown.includes('canonical_planning_constraints')) throw new Error(markdown);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "section repair context also carries confirmed revision obligations" {
  mkdir -p "$BOOK/正文"
  printf '%s\n' '主管说只是设备升级，我差点信了。' > "$BOOK/草稿_第002节_候选.md"
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={
  workflow_id:'wf-short',
  workflow_type:'private_short_startup',
  scope:'第2节',
  current_stage:'section_repair_loop',
  task_dir:'追踪/workflow/tasks/wf-short',
  stage_execution:{stage_attempt_id:'sa-repair-2'},
  accepted_plan:{
    plan_id:'accepted-plan.archive',
    status:'projected_to_canonical_memory',
    summary:'按确认方案重构全篇。',
    requirements:[{requirement_id:'req-2',text:'第2节必须把主管的“设备升级”说法推向可核验证据，不得提前替主管洗白。'}],
    affected_sections:[2],
  },
  feedback_revision_queue:{
    status:'running',
    feedback_id:'feedback-archive',
    current_section_index:2,
    affected_sections:[2],
    items:[{section_index:2,status:'pending',brief_status:'passed',prose_status:'pending_recheck'}],
  },
};
const out=api.buildStageContextPacket({projectRoot:root,task,stage:'section_repair_loop'});
if(out.status!=='assembled') throw new Error(JSON.stringify(out));
const markdown=fs.readFileSync(path.join(root,out.packet_md),'utf8');
if(!markdown.includes('accepted_revision_obligations')) throw new Error(markdown);
if(!markdown.includes('不得提前替主管洗白')) throw new Error(markdown);
if(!markdown.includes('草稿_第002节_候选.md')) throw new Error(markdown);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "whole story feedback impact packet excludes prose and uses the full plan overview" {
  printf '%s\n' '# 第2节候选正文' '这段正文不应进入规划影响分析。' > "$BOOK/草稿_第002节_候选.md"
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',scope:'全篇',current_stage:'feedback_impact_sync',task_dir:'追踪/workflow/tasks/wf-short',stage_execution:{stage_attempt_id:'sa-whole-feedback'},pending_feedback:{feedback_id:'feedback-whole',scope_snapshot:'全篇',text:'整篇结局和人物功能需要重构。',items:[{feedback_id:'feedback-item',text:'整篇结局和人物功能需要重构。'}]}};
const out=api.buildStageContextPacket({projectRoot:root,task,stage:'feedback_impact_sync'});
if(out.status!=='assembled'||!out.packet_md.includes('/whole-story/')) throw new Error(JSON.stringify(out));
const markdown=fs.readFileSync(path.join(root,out.packet_md),'utf8');
if(!markdown.includes('第1节：开场')||!markdown.includes('第3节：反转')) throw new Error(markdown);
if(markdown.includes('这段正文不应进入规划影响分析')||markdown.includes('写作Brief_第002节')) throw new Error(markdown);
if(out.estimated_tokens>2500) throw new Error(`impact packet unexpectedly large: ${out.estimated_tokens}`);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "feedback impact chain: V3 engine projects accepted plan to canonical memory and the next section brief still recalls it across workflows" {
  # Task P0.8 e2e: drive the full feedback impact chain through the V3 Engine
  # instead of reopening the read-only V2 mutation path, then assert the three
  # P0.x fixes are wired together:
  #   1. P0.1 projection — accepted_plan.requirements land in
  #      追踪/memory/planning-constraints.jsonl via projectAcceptedShortPlanningFeedback.
  #   2. P0.1 cross-task recall + P0.7 dedup — a DIFFERENT workflow_id building the
  #      next_section_brief packet still sees the projected constraint content (the
  #      workflow_id filter was removed from isPlanningConstraintActive) and it is not
  #      silently dropped when it overlaps an inline accepted_plan.
  #   3. P0.4 queue setup — feedback_revision_queue is initialized with its cursor on
  #      the first affected section, the deterministic forward motion that P0.4 guards.
  local book="$BATS_TEST_TMPDIR/chain-book"
  mkdir -p "$book/追踪/memory" \
           "$book/追踪/private-short-extension"
  # Reuse the rich outline/setting/material so the downstream next_section_brief
  # packet can assemble its required section-002 outline contract.
  cp "$BOOK/小节大纲.md" "$book/小节大纲.md"
  cp "$BOOK/设定.md" "$book/设定.md"
  cp "$BOOK/素材卡.md" "$book/素材卡.md"
  mkdir -p "$book/正文"
  printf '%s\n' '第1节正文：阿岚公开质疑凭证宣传，主管拿出成本账册。' > "$book/正文/第001节.md"
  printf '%s\n' '{"project_id":"short-a","project_title":"档案复核","plan_revision":1,"current_section_index":2,"accepted_sections":[{"section_index":1},{"section_index":2}],"narrative":{"planned_sections":3}}' > "$book/追踪/private-short-extension/project-state.json"
  printf '%s\n' '{"workflow_id":"wf-chain-feedback","section_index":1,"status":"accepted","canonical_path":"正文/第001节.md","section_summary":"阿岚公开质疑宣传。","open_hook":"主管拿出成本账册。"}' > "$book/追踪/private-short-extension/section-001-anchor.json"
  node - "$REPO" "$book" <<'NODE'
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
let task = engine.createTask(root, {
  workflow_id: 'wf-chain-feedback',
  workflow_type: 'short_write',
  user_goal: '按确认方案回炉第2至3节',
});
const acceptedPlan = {
  schema_version: '1.0.0',
  plan_id: 'accepted-plan.chain',
  proposal_id: 'proposal-v3.chain',
  feedback_id: 'fb-chain-001',
  status: 'accepted_pending_projection',
  projection_status: 'pending',
  summary: '按确认方案重构第2、3节。',
  requirements: [
    { requirement_id: 'req-confess', text: '结局必须由负责人主动坦白隐瞒，不得让主管替阿岚背锅。', impact_level: 'planning' },
  ],
  impact_level: 'planning',
  affected_sections: [2, 3],
  projection_plan: {
    planning_assets: ['设定.md', '小节大纲.md'],
    invalidate_briefs: ['写作Brief_第002节.md', '写作Brief_第003节.md'],
    recheck_prose: ['正文/第002节.md', '正文/第003节.md'],
  },
};
task.current_stage = 'section_brief';
task.current_section_index = 2;
task.scope = '第2节';
task.stage_execution = { status: 'running', stage_id: 'section_brief', stage_attempt_id: 'sa-chain-feedback', section_index: 2 };
task.pending_feedback = { id: 'fb-chain-001', status: 'accepted', accepted_plan: acceptedPlan };
task.accepted_plan = acceptedPlan;
fs.writeFileSync(path.join(root, task.task_dir, 'task.json'), `${JSON.stringify(task, null, 2)}\n`);
NODE
  # Drive the authoritative V3 Engine path: projection + queue init + transition.
  # The public apply-result CLI intentionally refuses professional-stage packets;
  # its production entry is run-stage, covered by the V3 host-routing tests.
  run node - "$REPO" "$book" <<'NODE'
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const task = engine.readTask(root, 'wf-chain-feedback');
const applied = engine.applyStageResult(root, 'wf-chain-feedback', task.state_version, {
  kind: 'completed',
  code: 'short_brief_accepted',
  stage_id: 'section_brief',
  section_index: 2,
});
process.stdout.write(`${JSON.stringify({ ok: true, ...applied })}\n`);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/chain-apply.json"

  run node - "$book" "$BATS_TEST_TMPDIR/chain-apply.json" "$REPO/scripts/lib/workflow-stage-context-packet.js" <<'NODE'
const fs = require('fs');
const path = require('path');
const book = process.argv[2];
const applyOut = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const packetApi = require(process.argv[4]);

// (1) P0.1 projection: accepted_plan.requirements projected to canonical memory.
const constraintsFile = path.join(book, '追踪', 'memory', 'planning-constraints.jsonl');
const constraints = fs.existsSync(constraintsFile)
  ? fs.readFileSync(constraintsFile, 'utf8').trim().split(/\n/).filter(Boolean).map(JSON.parse)
  : [];
const projected = constraints.find(row => String(row.content || '').includes('负责人主动坦白'));
if (!projected) throw new Error(`planning-constraints.jsonl missing projected requirement: ${JSON.stringify(constraints)}`);
if (String(projected.constraint_id || '') !== 'constraint.req-confess') throw new Error(`unexpected constraint_id: ${projected.constraint_id}`);
if (String(projected.source_kind || '') !== 'user_confirmed_plan') throw new Error(`unexpected source_kind: ${projected.source_kind}`);
if (String(projected.status || '') !== 'active') throw new Error(`projected constraint not active: ${projected.status}`);

// (3) P0.4 queue setup: revision queue initialized, cursor on the first affected section.
const task = JSON.parse(fs.readFileSync(path.join(book, '追踪/workflow/tasks/wf-chain-feedback/task.json'), 'utf8'));
const queue = task.feedback_revision_queue || {};
if (queue.status !== 'running') throw new Error(`expected queue.status='running', got ${queue.status}`);
if (queue.current_section_index !== 2) throw new Error(`expected queue.current_section_index=2, got ${queue.current_section_index}`);
if (!(Array.isArray(queue.items) && queue.items.some(i => i.section_index === 2 && i.status === 'pending'))) throw new Error(`section 2 not pending in queue: ${JSON.stringify(queue.items)}`);
if (!(Array.isArray(queue.items) && queue.items.some(i => i.section_index === 3 && i.status === 'pending'))) throw new Error(`section 3 not pending in queue: ${JSON.stringify(queue.items)}`);
// accepted_plan must be stamped as projected to canonical memory.
if (String((task.accepted_plan || {}).status || '') !== 'projected_to_canonical_memory') throw new Error(`accepted_plan not stamped projected: ${(task.accepted_plan || {}).status}`);
// feedback_apply_patch must have advanced the workflow forward (no re-entry).
if (String(((applyOut.task || {}).current_stage) || '') !== 'section_draft') throw new Error(`workflow did not advance to section_draft: ${JSON.stringify(applyOut)}`);

// (2) P0.1 cross-task recall + P0.7 dedup: a DIFFERENT workflow_id building the
// next_section_brief packet for section 2 still sees the projected constraint.
// The constraint provenance is wf-chain-feedback; this revision child is
// wf-chain-feedback-rev2 — different workflow_id — exercising the removed filter.
// The child carries an accepted_plan with NO overlapping requirement text, so the
// only way "负责人主动坦白" can reach the packet is the projected row read back from
// 追踪/memory/planning-constraints.jsonl across the workflow boundary (the P0.1
// disk-recall path). This isolates the cross-workflow fix from the task-scoped
// accepted_plan copy.
const revChild = {
  workflow_id: 'wf-chain-feedback-rev2',
  workflow_type: 'private_short_startup',
  scope: '第2节',
  current_stage: 'next_section_brief',
  task_dir: '追踪/workflow/tasks/wf-chain-feedback-rev2',
  stage_execution: { stage_attempt_id: 'sa-brief-rev2' },
  accepted_plan: {
    plan_id: 'accepted-plan.chain',
    status: 'projected_to_canonical_memory',
    projection_status: 'completed',
    feedback_id: 'fb-chain-001',
    summary: '按确认方案逐节复检，约束已投影到作品记忆。',
    requirements: [],
    affected_sections: [2, 3],
    projected_assets: ['设定.md', '小节大纲.md'],
  },
  feedback_revision_queue: {
    status: 'running',
    feedback_id: 'fb-chain-001',
    current_section_index: 2,
    affected_sections: [2, 3],
    items: [{ section_index: 2, status: 'pending', brief_status: 'invalidated', prose_status: 'pending_recheck' }],
  },
};
const packet = packetApi.buildStageContextPacket({ projectRoot: book, task: revChild, stage: 'next_section_brief' });
if (packet.status !== 'assembled') throw new Error(`next_section_brief packet not assembled: ${JSON.stringify(packet).slice(0, 800)}`);
const md = fs.readFileSync(path.join(book, packet.packet_md), 'utf8');
// The confirmed obligation must reach the brief context...
if (!md.includes('负责人主动坦白')) throw new Error(`projected constraint missing from next_section_brief packet (cross-task recall failed)`);
// ...carried as the accepted revision obligations block (P0.4/P0.7 inline asset)...
if (!md.includes('accepted_revision_obligations')) throw new Error(`accepted_revision_obligations asset missing from packet`);
// ...and the memory-snapshot constraint source must be referenced (P0.1 canon_constraints path).
if (!/canon_constraints|当前作品记忆快照/.test(md)) throw new Error(`memory snapshot constraint source not referenced in packet`);
console.log('ok');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ok"* ]]
}

@test "cross-asset dedup collapses accepted plan facts already in canonical memory and emits a budget receipt" {
  mkdir -p "$BOOK/正文"
  printf '%s\n' '第1节结尾：主管拿出成本账册。' > "$BOOK/正文/第001节.md"
  printf '%s\n' '{"project_id":"short-a","project_title":"档案复核","current_section_index":2,"accepted_sections":[{"section_index":1}]}' > "$BOOK/追踪/private-short-extension/project-state.json"
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={
  workflow_id:'wf-short',
  workflow_type:'short_write',
  scope:'第2节',
  current_stage:'feedback_apply_patch',
  task_dir:'追踪/workflow/tasks/wf-short',
  stage_execution:{stage_attempt_id:'sa-feedback-dedup-2'},
  accepted_plan:{
    plan_id:'accepted-plan.archive',
    status:'projected_to_canonical_memory',
    projection_status:'completed',
    affected_sections:[1,2],
    requirements:[
      {requirement_id:'req-ending',text:'结局必须兑现已确认的真实归档承诺。'},
      {requirement_id:'req-signature',text:'第2节必须让负责人认出账册签名。'},
    ],
    projected_assets:['设定.md','小节大纲.md'],
  },
  feedback_revision_queue:{
    status:'running',
    feedback_id:'feedback-archive',
    current_section_index:2,
    affected_sections:[1,2],
    items:[{section_index:2,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}],
  },
};
const out=api.buildStageContextPacket({projectRoot:root,task,stage:'feedback_apply_patch'});
if(out.status!=='assembled') throw new Error(JSON.stringify(out));
const markdown=fs.readFileSync(path.join(root,out.packet_md),'utf8');
// The same requirement text is carried by BOTH the inline accepted_plan asset and
// the memory snapshot canon_constraints. After cross-asset dedup the prose packet
// must surface it only once.
const reqEnding='结局必须兑现已确认的真实归档承诺';
const reqSignature='第2节必须让负责人认出账册签名';
if((markdown.split(reqEnding).length-1)!==1) throw new Error(`req-ending should appear once, got ${markdown.split(reqEnding).length-1}`);
if((markdown.split(reqSignature).length-1)!==1) throw new Error(`req-signature should appear once, got ${markdown.split(reqSignature).length-1}`);
// Budget receipt fields.
if(typeof out.deduplicated_items!=='number'||out.deduplicated_items<1) throw new Error(`deduplicated_items missing or zero: ${JSON.stringify(out.deduplicated_items)}`);
if(!Array.isArray(out.included_assets)||!out.included_assets.length) throw new Error(`included_assets missing: ${JSON.stringify(out.included_assets)}`);
if(!out.included_assets.includes('accepted_plan')||!out.included_assets.includes('memory_snapshot')) throw new Error(`expected accepted_plan + memory_snapshot included, got ${JSON.stringify(out.included_assets)}`);
// Same receipt fields in the persisted packet JSON.
const meta=JSON.parse(fs.readFileSync(path.join(root,out.packet_json),'utf8'));
if(meta.deduplicated_items!==out.deduplicated_items) throw new Error(`packet_json deduplicated_items mismatch: ${meta.deduplicated_items}`);
if(JSON.stringify(meta.included_assets)!==JSON.stringify(out.included_assets)) throw new Error(`packet_json included_assets mismatch: ${JSON.stringify(meta.included_assets)}`);
// The accepted_plan asset stays authoritative; the duplicate is suppressed in the
// memory snapshot section with an annotation pointing back to the plan.
if(!markdown.includes('accepted_plan')) throw new Error('accepted_plan asset should still be present');
if(!/见 accepted_plan|covered by accepted_plan|由 accepted_plan 覆盖/.test(markdown)) throw new Error('memory snapshot section should annotate the dedup against accepted_plan');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "brief freshness becomes stale when accepted story memory changes" {
  run node - "$REPO/scripts/lib/short-brief-freshness.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const options={projectRoot:root,briefPath:'写作Brief_第002节.md',sectionIndex:2,acceptedAnchorPath:'追踪/private-short-extension/section-001-anchor.json'};
const written=api.writeBriefFreshnessSnapshot(options);
if(written.status!=='snapshot_written'||!written.snapshot.memory_revision) throw new Error(JSON.stringify(written));
fs.appendFileSync(path.join(root,'追踪/memory/facts.jsonl'),'\n'+JSON.stringify({fact_id:'fact.hook-new',subject:'档案复核',predicate:'留下待续钩子',object:'负责人认出签名。',scope:{book:'current',section:1},status:'active',evidence:[{path:'正文/第001节.md'}]})+'\n');
const stale=api.checkBriefFreshness(options);
if(stale.status!=='stale'||!stale.stale_dependencies.includes('当前作品记忆')) throw new Error(JSON.stringify(stale));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "future or unselected facts do not invalidate the current section brief" {
  run node - "$REPO/scripts/lib/short-brief-freshness.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const options={projectRoot:root,briefPath:'写作Brief_第002节.md',sectionIndex:2,acceptedAnchorPath:'追踪/private-short-extension/section-001-anchor.json'};
if(api.writeBriefFreshnessSnapshot(options).status!=='snapshot_written') throw new Error('snapshot failed');
fs.appendFileSync(path.join(root,'追踪/memory/facts.jsonl'),'\n'+JSON.stringify({fact_id:'fact.future-2',subject:'陌生人',predicate:'第3节状态',object:'尚未发生且与第2节无关。',scope:{book:'current',section:3},status:'active'})+'\n');
const current=api.checkBriefFreshness(options);
if(current.status!=='current') throw new Error(JSON.stringify(current));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "runtime metadata changes do not affect memory_revision" {
  # Regression guard (P0.5 Step 1): runtime-only fields on project-state.json
  # (current_section_index / updated_at / stage_execution / heartbeat) must NOT
  # bleed into the content-derived memory_revision. Only the content sources
  # listed in CONTENT_SOURCES feed buildMemoryRevision.
  local TMP="$BATS_TEST_TMPDIR/runtime-metadata"
  mkdir -p "$TMP/追踪/story-system/short" "$TMP/追踪/memory"
  cat > "$TMP/追踪/story-system/short/project-state.json" <<'JSON'
{"project_id":"proj-x","plan_revision":2,"planned_sections":3,"current_section_index":1,"updated_at":"2026-07-28T10:00:00Z","stage_execution":{"status":"running"}}
JSON
  printf '%s\n' '{"fact_id":"fact-1","subject":"主角","predicate":"是","object":"程序员","scope":{"book":"current","section":1},"status":"active"}' > "$TMP/追踪/memory/facts.jsonl"
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$TMP" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const rev1=api.buildShortMemorySnapshot(root,{sectionIndex:1,stageId:'next_section_brief'}).receipt.memory_revision;
const fs=require('fs');fs.writeFileSync(root+'/追踪/story-system/short/project-state.json',JSON.stringify({project_id:"proj-x",plan_revision:2,planned_sections:3,current_section_index:5,updated_at:"2026-07-28T23:59:59Z",stage_execution:{status:"completed",heartbeat:"abc"}}));
const rev2=api.buildShortMemorySnapshot(root,{sectionIndex:1,stageId:'next_section_brief'}).receipt.memory_revision;
if(!rev1||rev1!==rev2) throw new Error(`memory_revision drifted under runtime metadata: ${rev1} -> ${rev2}`);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "planning constraint change produces structured dimension diff" {
  # P0.5 Step 3: when a current-section active planning asset changes, the
  # freshness receipt must classify the change into semantic dimensions
  # (changed_dimensions) in addition to the legacy stale_dependencies list.
  local TMP="$BATS_TEST_TMPDIR/dimension-diff"
  mkdir -p "$TMP/追踪/story-system/short" "$TMP/追踪/memory"
  cat > "$TMP/追踪/story-system/short/project-state.json" <<'JSON'
{"project_id":"proj-d","plan_revision":1,"planned_sections":3,"current_section_index":2}
JSON
  printf '%s\n' '# 设定' '第一人称。主角是程序员。' > "$TMP/设定.md"
  printf '%s\n' '# 素材卡' '基础冲突。' > "$TMP/素材卡.md"
  printf '%s\n' '# 小节大纲' '## 第1节：起' '## 第2节：承' '## 第3节：合' > "$TMP/小节大纲.md"
  printf '%s\n' '# 写作Brief：第002节' '本节任务：承接。' > "$TMP/写作Brief_第002节.md"
  printf '%s\n' '{"subject":"主角","predicate":"是","object":"程序员","scope":{"book":"current","section":1},"status":"active"}' > "$TMP/追踪/memory/facts.jsonl"
  run node - "$REPO/scripts/lib/short-brief-freshness.js" "$TMP" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const options={projectRoot:root,briefPath:'写作Brief_第002节.md',sectionIndex:2};
const written=api.writeBriefFreshnessSnapshot(options);
if(written.status!=='snapshot_written') throw new Error(JSON.stringify(written));
// Change a planning asset (设定.md) -> planning dimension should be reported.
fs.writeFileSync(path.join(root,'设定.md'),'# 设定\n第一人称。主角改成了设计师。\n');
const stale=api.checkBriefFreshness(options);
if(stale.status!=='stale') throw new Error(`expected stale, got ${stale.status}`);
// Backward-compat: legacy stale_dependencies still carries the human-readable label.
if(!Array.isArray(stale.stale_dependencies)||!stale.stale_dependencies.includes('设定.md')) throw new Error(JSON.stringify(stale));
// New: structured changed_dimensions must classify the change.
if(!Array.isArray(stale.changed_dimensions)||!stale.changed_dimensions.includes('planning')) throw new Error(JSON.stringify(stale));
// New: affects_current_section flag + recovery hint.
if(stale.affects_current_section!==true) throw new Error(JSON.stringify(stale));
if(stale.recovery!=='rebuild_current_brief_once') throw new Error(JSON.stringify(stale));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "brief dimension diff is absent when nothing changes" {
  # P0.5: when the brief is current, changed_dimensions is empty,
  # affects_current_section is false, and recovery is null.
  local TMP="$BATS_TEST_TMPDIR/dimension-current"
  mkdir -p "$TMP/追踪/story-system/short" "$TMP/追踪/memory"
  cat > "$TMP/追踪/story-system/short/project-state.json" <<'JSON'
{"project_id":"proj-c","plan_revision":1,"planned_sections":3,"current_section_index":2}
JSON
  printf '%s\n' '# 设定' '稳定设定。' > "$TMP/设定.md"
  printf '%s\n' '# 素材卡' '稳定素材。' > "$TMP/素材卡.md"
  printf '%s\n' '# 小节大纲' '## 第1节：起' '## 第2节：承' > "$TMP/小节大纲.md"
  printf '%s\n' '# 写作Brief：第002节' '本节任务：承接。' > "$TMP/写作Brief_第002节.md"
  printf '%s\n' '{"subject":"主角","predicate":"是","object":"程序员","scope":{"book":"current","section":1},"status":"active"}' > "$TMP/追踪/memory/facts.jsonl"
  run node - "$REPO/scripts/lib/short-brief-freshness.js" "$TMP" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const options={projectRoot:root,briefPath:'写作Brief_第002节.md',sectionIndex:2};
if(api.writeBriefFreshnessSnapshot(options).status!=='snapshot_written') throw new Error('snapshot failed');
const current=api.checkBriefFreshness(options);
if(current.status!=='current') throw new Error(JSON.stringify(current));
if(!Array.isArray(current.changed_dimensions)||current.changed_dimensions.length!==0) throw new Error(JSON.stringify(current));
if(current.affects_current_section!==false) throw new Error(JSON.stringify(current));
if(current.recovery!==null) throw new Error(JSON.stringify(current));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "memory change unrelated to current section does not affect current section" {
  # P0.5 Step 5: a memory change that does NOT touch the current section's
  # selected facts (e.g. a future-section fact) leaves affects_current_section
  # false even though the brief is still reported current. This documents the
  # section-aware filtering already provided by memory_revision.
  local TMP="$BATS_TEST_TMPDIR/section-unrelated"
  mkdir -p "$TMP/追踪/story-system/short" "$TMP/追踪/memory"
  cat > "$TMP/追踪/story-system/short/project-state.json" <<'JSON'
{"project_id":"proj-u","plan_revision":1,"planned_sections":9,"current_section_index":2}
JSON
  printf '%s\n' '# 设定' '稳定设定。' > "$TMP/设定.md"
  printf '%s\n' '# 素材卡' '稳定素材。' > "$TMP/素材卡.md"
  printf '%s\n' '# 小节大纲' '## 第1节：起' '## 第2节：承' '## 第9节：终局' > "$TMP/小节大纲.md"
  printf '%s\n' '# 写作Brief：第002节' '本节任务：承接。' > "$TMP/写作Brief_第002节.md"
  printf '%s\n' '{"fact_id":"fact-base","subject":"主角","predicate":"是","object":"程序员","scope":{"book":"current","section":1},"status":"active"}' > "$TMP/追踪/memory/facts.jsonl"
  run node - "$REPO/scripts/lib/short-brief-freshness.js" "$TMP" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const options={projectRoot:root,briefPath:'写作Brief_第002节.md',sectionIndex:2};
if(api.writeBriefFreshnessSnapshot(options).status!=='snapshot_written') throw new Error('snapshot failed');
// Append a fact scoped to section 8 (not 1/2). selectFacts filters to facts
// with section < currentSection (i.e. section 1 only), so the memory_revision
// for section 2 must not change, and the brief stays current.
fs.appendFileSync(path.join(root,'追踪/memory/facts.jsonl'),'\n'+JSON.stringify({fact_id:'fact-future-8',subject:'配角',predicate:'第8节状态',object:'尚未发生且与第2节无关。',scope:{book:'current',section:8},status:'active'})+'\n');
const result=api.checkBriefFreshness(options);
if(result.status!=='current') throw new Error(`expected current, got ${result.status}: ${JSON.stringify(result)}`);
if(result.affects_current_section!==false) throw new Error(JSON.stringify(result));
if((result.changed_dimensions||[]).length!==0) throw new Error(JSON.stringify(result));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a stage memory receipt detects relevant accepted facts added after packet creation" {
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const packetApi=require(process.argv[2]);const memoryApi=require(process.argv[3]);const root=process.argv[4];
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节',current_stage:'draft_next_section',task_dir:'追踪/workflow/tasks/wf-short',stage_execution:{stage_attempt_id:'sa-stale'}};
const packet=packetApi.buildStageContextPacket({projectRoot:root,task,stage:'draft_next_section'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
const execution={stage_id:'draft_next_section',stage_context_packet:{packet_json:packet.packet_json}};
if(memoryApi.validateShortStageMemoryReceipt(root,task,execution).status!=='current') throw new Error('receipt should begin current');
fs.appendFileSync(path.join(root,'追踪/memory/facts.jsonl'),'\n'+JSON.stringify({fact_id:'fact.new-choice',subject:'阿岚',predicate:'第1节状态',object:'决定先保护账册原件。',scope:{book:'current',section:1},status:'active'})+'\n');
const stale=memoryApi.validateShortStageMemoryReceipt(root,task,execution);
if(stale.status!=='stale') throw new Error(JSON.stringify(stale));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "short memory recovery refreshes a stale stage once inside the same command boundary" {
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$REPO/scripts/lib/short-memory-stage-recovery.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const packetApi=require(process.argv[2]);
const recovery=require(process.argv[3]);
const root=process.argv[4];
fs.writeFileSync(path.join(root,'草稿_第002节_候选.md'),'## 第2节 账册\n\n阿岚把账册摊到负责人面前。负责人认出了签名，主管伸手来抢，她先拍下了副本。\n');
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节',current_stage:'quality_gate',current_step:'quality_gate',task_dir:'追踪/workflow/tasks/wf-short',state_version:1,stage_execution:{status:'running',stage_id:'quality_gate',stage_attempt_id:'sa-refresh',context_refresh_count:0}};
const packet=packetApi.buildStageContextPacket({projectRoot:root,task,stage:'quality_gate'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
task.stage_execution.stage_context_packet={packet_json:packet.packet_json,packet_md:packet.packet_md,section_index:2};
task.stage_execution.memory_context={context_source:'stage_context',memory_read_receipt:packet.memory_read_receipt,memory_contract:packet.memory_contract};
fs.writeFileSync(path.join(root,task.task_dir,'task.json'),JSON.stringify(task,null,2));
fs.appendFileSync(path.join(root,'追踪/memory/facts.jsonl'),'\n'+JSON.stringify({fact_id:'fact.refresh',subject:'阿岚',predicate:'第1节状态',object:'负责人已经承认签名。',scope:{book:'current',section:1},status:'active',evidence:[{path:'正文/第001节.md'}]})+'\n');
const out=recovery.ensureCurrentShortMemoryStage({projectRoot:root,workflowId:'wf-short',task,execution:task.stage_execution,sectionIndex:2,stageId:'quality_gate'});
if(out.status!=='refreshed_and_current'||out.blocking||!out.refreshed) throw new Error(JSON.stringify(out));
if(Number(out.execution.context_refresh_count)!==1) throw new Error(JSON.stringify(out.execution));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "active book planning constraint survives task and feedback changes" {
  # constraint provenance 是 wf-old/feedback-old，当前 task 是 wf-new/feedback-new
  # 同一 project、status=active、影响当前小节 -> 必须进入上下文包。
  # 复制 fixture 到临时目录，避免 buildStageContextPacket 写出的上下文包污染仓库 fixture。
  local fixture="$BATS_TEST_TMPDIR/cross-task-active"
  cp -R "$REPO/tests/fixtures/cross-task-active" "$fixture"
  run node "$REPO/tests/fixtures/assert-stage-context.js" \
    --fixture "$fixture" \
    --stage next_section_brief \
    --section 2 \
    --expect "恢复真实复核线"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "superseded planning constraint is excluded" {
  local fixture="$BATS_TEST_TMPDIR/superseded-plan"
  cp -R "$REPO/tests/fixtures/superseded-plan" "$fixture"
  run node "$REPO/tests/fixtures/assert-stage-context.js" \
    --fixture "$fixture" \
    --stage next_section_brief \
    --section 2 \
    --reject "旧结局"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
