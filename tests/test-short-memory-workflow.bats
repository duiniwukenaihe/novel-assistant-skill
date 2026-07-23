#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/short-memory-book"
  mkdir -p "$BOOK/追踪/memory" "$BOOK/追踪/schema" "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow/tasks/wf-short"
  printf '%s\n' '{"project_id":"short-a","project_title":"果汁事件","plan_revision":1,"current_section_index":1,"accepted_sections":[{"section_index":1}],"narrative":{"planned_sections":3}}' > "$BOOK/追踪/private-short-extension/project-state.json"
  cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：开场
## 第2节：账本
- 结构功能：公开第一份证据。
- 承接上节：哥哥拿出工资账本。
- 场景动作：林照把账本摊到母亲面前。
- 子事件：
  1. 林照核对签名。
  2. 母亲认出签名。
- 情绪目标：压迫转主动。
- 压力变化：口头争执升级为可核验的账目冲突。
- 因果链：质疑 -> 出示账本 -> 母亲认出签名。
- 角色选择：林照拒绝让家人代她解释。
- 可见阻力：哥哥试图抢回账本。
- 本节兑现：工资账本证明宣传说法不实。
- 关系变化：林照与母亲从争执转为共同核验。
- 代价升级：林照可能失去家族职位。
- 核心承诺兑现：林照第一次用家族账本推翻公开宣传。
- 决定性行动：林照保存账本副本。
- 即时代价：哥哥当场切断她的工作权限。
- 节尾钩子：母亲认出签名。
## 第3节：反转
EOF
  printf '%s\n' '# 设定' '第一人称。林照负责查证。' > "$BOOK/设定.md"
  printf '%s\n' '# 素材卡' '虚构果汁企业的宣传争议。' > "$BOOK/素材卡.md"
  printf '%s\n' '# 第2节写作提要' '## 本节任务' '林照出示工资账本。' '## 视角与称谓' '第一人称。' '## 禁止漂移' '不得新增哥哥救过公司的设定。' '## 验收标准' '账本改变母亲态度。' > "$BOOK/写作Brief_第002节.md"
  printf '%s\n' '{"workflow_id":"wf-short","section_index":1,"status":"accepted","canonical_path":"正文/第001节.md","section_summary":"林照公开质疑宣传。","character_state":{"林照":"决定查账"},"open_hook":"哥哥拿出工资账本。"}' > "$BOOK/追踪/private-short-extension/section-001-anchor.json"
  printf '%s\n' '{"fact_id":"fact.section-1.summary","subject":"果汁事件","predicate":"本节发生","object":"林照公开质疑宣传。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' > "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"fact_id":"fact.character-linzhao","subject":"林照","predicate":"第1节状态","object":"决定查账，不再接受家人代她表态。","scope":{"book":"current","section":1},"status":"active","evidence":[{"path":"正文/第001节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"fact_id":"fact.future","subject":"林照","predicate":"第3节状态","object":"尚未发生的结局。","scope":{"book":"current","section":3},"status":"active","evidence":[{"path":"正文/第003节.md"}]}' >> "$BOOK/追踪/memory/facts.jsonl"
  printf '%s\n' '{"rule_id":"style-natural-dialogue","status":"active","content":"对白先回应眼前的人和动作，不用总结式台词。","scope":"short_write"}' > "$BOOK/追踪/schema/user-style-rules.jsonl"
  printf '%s\n' '{"entryId":"pref-menu","status":"accepted","category":"interaction","scope":"workflow","content":"首屏使用数字菜单。"}' > "$BOOK/追踪/workflow/preference-memory.jsonl"
  printf '%s\n' '{"entryId":"pref-voice","status":"accepted","category":"voice","scope":"short_write","content":"对话保持克制，不用长篇宣言。"}' >> "$BOOK/追踪/workflow/preference-memory.jsonl"
  printf '%s\n' '{"rule_id":"pollution-loop","status":"active","content":"禁止同一领域词连续循环填充。","scope":"short_write"}' > "$BOOK/追踪/schema/output-pollution-rules.jsonl"
}

@test "short memory snapshot selects accepted continuity facts and emits a read receipt" {
  run node - "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节'};
const out=api.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'draft_next_section'});
if(out.status!=='assembled'||!out.receipt.memory_revision) throw new Error(JSON.stringify(out));
const ids=out.receipt.selected_entry_ids;
if(!ids.includes('fact.character-linzhao')||ids.includes('fact.future')) throw new Error(JSON.stringify(out));
const text=JSON.stringify(out.payload);
if(!text.includes('决定查账')||!text.includes('对白先回应眼前的人')||!text.includes('对话保持克制')||!text.includes('禁止同一领域词')) throw new Error(text);
if(text.includes('首屏使用数字菜单')) throw new Error('workflow preference leaked into prose memory');
if(text.includes('尚未发生的结局')) throw new Error(text);
const obligations=out.payload.continuity_obligations||[];
if(!obligations.some(item=>item.source_id==='fact.character-linzhao'&&item.requirement==='preserve_or_explain_change')) throw new Error(JSON.stringify(out.payload));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "due promises and previous hooks become current section continuity obligations" {
  printf '%s\n' '{"promise_id":"promise-signature","summary":"母亲必须说明为何认得签名。","status":"active","opened_section":1,"target_section":2}' > "$BOOK/追踪/schema/promises.jsonl"
  printf '%s\n' '{"fact_id":"fact.hook-signature","subject":"果汁事件","predicate":"留下待续钩子","object":"母亲认出了签名。","scope":{"book":"current","section":1},"status":"active"}' >> "$BOOK/追踪/memory/facts.jsonl"
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

@test "next section stage packet carries the compiled memory snapshot and receipt" {
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const {buildStageContextPacket}=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节',current_stage:'draft_next_section',task_dir:'追踪/workflow/tasks/wf-short',stage_execution:{stage_attempt_id:'sa-2'}};
const out=buildStageContextPacket({projectRoot:root,task,stage:'draft_next_section'});
if(out.status!=='assembled'||!out.memory_read_receipt||!out.memory_read_receipt.memory_revision) throw new Error(JSON.stringify(out));
const markdown=fs.readFileSync(path.join(root,out.packet_md),'utf8');
if(!markdown.includes('当前作品记忆快照')||!markdown.includes('决定查账')) throw new Error(markdown);
const meta=JSON.parse(fs.readFileSync(path.join(root,out.packet_json),'utf8'));
if(meta.memory_read_receipt.memory_revision!==out.memory_read_receipt.memory_revision) throw new Error(JSON.stringify(meta));
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
feedbackApi.enqueueShortFeedback(root,task,'第2节必须让老大守住底线，不能无条件替林照洗白。',{sectionIndex:2,scopeSnapshot:'第2节',receivedAt:'2026-07-22T02:00:00.000Z'});
const result={workflow_id:'wf-short',workflow_type:'short_write',stage_id:'feedback_apply_patch',step_status:'completed',impact_level:'planning',changed_assets:['小节大纲.md'],changed_files:['小节大纲.md'],affected_sections:[2],result_packet_path:'追踪/workflow/tasks/wf-short/result-packets/feedback_apply_patch.result.json'};
const projected=planningApi.projectAcceptedShortPlanningFeedback(root,task,result);
if(projected.status!=='planning_constraints_projected'||projected.projected!==1) throw new Error(JSON.stringify(projected));
const first=memoryApi.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
if(first.status!=='assembled'||!JSON.stringify(first.payload.canon_constraints).includes('老大守住底线')) throw new Error(JSON.stringify(first));
if(!first.payload.continuity_obligations.some(row=>row.kind==='accepted_planning_constraint')) throw new Error(JSON.stringify(first.payload));
fs.appendFileSync(path.join(root,'小节大纲.md'),'\n- 用户后来重新规划了本节。\n');
const stale=memoryApi.buildShortMemorySnapshot(root,{task,sectionIndex:2,stageId:'next_section_brief'});
if(JSON.stringify(stale.payload.canon_constraints).includes('老大守住底线')) throw new Error(JSON.stringify(stale.payload));
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

@test "brief freshness becomes stale when accepted story memory changes" {
  run node - "$REPO/scripts/lib/short-brief-freshness.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const options={projectRoot:root,briefPath:'写作Brief_第002节.md',sectionIndex:2,acceptedAnchorPath:'追踪/private-short-extension/section-001-anchor.json'};
const written=api.writeBriefFreshnessSnapshot(options);
if(written.status!=='snapshot_written'||!written.snapshot.memory_revision) throw new Error(JSON.stringify(written));
fs.appendFileSync(path.join(root,'追踪/memory/facts.jsonl'),'\n'+JSON.stringify({fact_id:'fact.hook-new',subject:'果汁事件',predicate:'留下待续钩子',object:'母亲认出签名。',scope:{book:'current',section:1},status:'active',evidence:[{path:'正文/第001节.md'}]})+'\n');
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

@test "a stage memory receipt detects relevant accepted facts added after packet creation" {
  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$REPO/scripts/lib/short-memory-snapshot.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const packetApi=require(process.argv[2]);const memoryApi=require(process.argv[3]);const root=process.argv[4];
const task={workflow_id:'wf-short',workflow_type:'short_write',workflow_profile:'private',scope:'第2节',current_stage:'draft_next_section',task_dir:'追踪/workflow/tasks/wf-short',stage_execution:{stage_attempt_id:'sa-stale'}};
const packet=packetApi.buildStageContextPacket({projectRoot:root,task,stage:'draft_next_section'});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
const execution={stage_id:'draft_next_section',stage_context_packet:{packet_json:packet.packet_json}};
if(memoryApi.validateShortStageMemoryReceipt(root,task,execution).status!=='current') throw new Error('receipt should begin current');
fs.appendFileSync(path.join(root,'追踪/memory/facts.jsonl'),'\n'+JSON.stringify({fact_id:'fact.new-choice',subject:'林照',predicate:'第1节状态',object:'决定先保护账本原件。',scope:{book:'current',section:1},status:'active'})+'\n');
const stale=memoryApi.validateShortStageMemoryReceipt(root,task,execution);
if(stale.status!=='stale') throw new Error(JSON.stringify(stale));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
