#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/book"
  TASK_DIR="追踪/workflow/tasks/wf-short"
  mkdir -p "$BOOK/$TASK_DIR"
}

@test "short feedback working memory accumulates chat corrections without overwrite" {
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" "$BOOK" <<'NODE'
const fs=require('fs');
const path=require('path');
const api=require(process.argv[2]);
const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short',current_stage:'final_check',scope:'全篇'};
api.enqueueShortFeedback(root,task,'结局必须恢复真实鲜榨，不能把浓缩当成新价值。',{receivedAt:'2026-07-22T01:00:00.000Z'});
api.enqueueShortFeedback(root,task,'宿舍线要区分真朋友、塑料朋友和普通消费者。',{receivedAt:'2026-07-22T01:01:00.000Z'});
if(task.pending_feedback.item_count!==2) throw new Error(JSON.stringify(task.pending_feedback));
if(!/恢复真实鲜榨/.test(task.pending_feedback.text)||!/塑料朋友/.test(task.pending_feedback.text)) throw new Error(task.pending_feedback.text);
if(task.pending_feedback.impact_level_hint!=='planning') throw new Error(task.pending_feedback.impact_level_hint);
if(task.pending_feedback.scope_snapshot!=='全篇') throw new Error(task.pending_feedback.scope_snapshot);
const rows=fs.readFileSync(path.join(root,task.pending_feedback.feedback_inbox_path),'utf8').trim().split('\n').map(JSON.parse);
if(rows.length!==2||rows.some(row=>row.event_type!=='feedback_received')) throw new Error(JSON.stringify(rows));
NODE
  [ "$status" -eq 0 ]
}

@test "duplicate feedback is idempotent and accepted resolution is auditable" {
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" "$BOOK" <<'NODE'
const fs=require('fs');
const path=require('path');
const api=require(process.argv[2]);
const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short',current_stage:'feedback_apply_patch',scope:'第9节'};
api.enqueueShortFeedback(root,task,'第9节删除内部价，改成公开购买页。',{receivedAt:'2026-07-22T01:00:00.000Z',sectionIndex:9});
api.enqueueShortFeedback(root,task,'第9节删除内部价，改成公开购买页。',{receivedAt:'2026-07-22T01:01:00.000Z',sectionIndex:9});
if(task.pending_feedback.item_count!==1) throw new Error(JSON.stringify(task.pending_feedback));
api.resolveShortFeedback(root,task,{stage_id:'feedback_apply_patch',result_packet_path:'追踪/workflow/tasks/wf-short/result.json'});
const rows=fs.readFileSync(path.join(root,task.pending_feedback.feedback_inbox_path),'utf8').trim().split('\n').map(JSON.parse);
if(rows.length!==2||rows[1].event_type!=='feedback_resolved') throw new Error(JSON.stringify(rows));
NODE
  [ "$status" -eq 0 ]
}

@test "feedback impact routing keeps plans separate from accepted story facts" {
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" <<'NODE'
const api=require(process.argv[2]);
const planning=api.inferFeedbackImpact('结局要恢复鲜榨，并补足母亲退出治理和宿舍人物关系。');
const local=api.inferFeedbackImpact('第7节把这句对白改得自然一点。');
if(planning.impact_level!=='planning'||!planning.affected_assets.includes('小节大纲.md')) throw new Error(JSON.stringify(planning));
if(local.impact_level!=='current_brief') throw new Error(JSON.stringify(local));
NODE
  [ "$status" -eq 0 ]
  [ ! -e "$BOOK/追踪/memory/facts.jsonl" ]
}

@test "planning memory projection rejects a completed patch without planning evidence" {
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" "$REPO/scripts/lib/short-planning-memory.js" "$BOOK" <<'NODE'
const feedbackApi=require(process.argv[2]);const planningApi=require(process.argv[3]);const root=process.argv[4];
const task={workflow_id:'wf-short',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short',current_stage:'feedback_apply_patch',scope:'全篇'};
feedbackApi.enqueueShortFeedback(root,task,'结局必须恢复真实鲜榨。',{scopeSnapshot:'全篇'});
const out=planningApi.projectAcceptedShortPlanningFeedback(root,task,{stage_id:'feedback_apply_patch',step_status:'completed',impact_level:'planning',changed_files:['正文.md']});
if(out.status!=='blocked_planning_memory_evidence_missing') throw new Error(JSON.stringify(out));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "confirmed assistant proposal becomes task decision memory before asset projection" {
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-short/artifacts"
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" "$REPO/scripts/lib/short-planning-memory.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const feedbackApi=require(process.argv[2]);const planningApi=require(process.argv[3]);const root=process.argv[4];
const task={workflow_id:'wf-short',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short',scope:'全篇'};
feedbackApi.enqueueShortFeedback(root,task,'终局恢复真实鲜榨；宿舍线贯穿第1、2、8、9节。',{scopeSnapshot:'全篇'});
task.short_feedback_impact={impact_level:'planning',affected_sections:[1,2,8,9],affected_assets:['设定.md','小节大纲.md'],downstream_impact:{replan:['设定.md：终局边界','小节大纲.md：宿舍线'],invalidate_briefs:['写作Brief_第001节.md','写作Brief_第002节.md','写作Brief_第008节.md','写作Brief_第009节.md'],recheck_prose:['正文/第001节.md','正文/第002节.md','正文/第008节.md','正文/第009节.md']}};
task.proposed_plan={proposal_id:'proposal.fruit-ending-v2',feedback_id:task.pending_feedback.feedback_id,status:'awaiting_user_confirmation',summary:'让鲜果回到工厂，宿舍三人分别承担真友情、塑料关系和普通消费者视角。',execution_summary:'先改设定和小节大纲，再使 1/2/8/9 节 Brief 与正文进入待复检。',requirements:[{requirement_id:'req-ending',text:'恢复真实鲜榨与公开可验证生产',impact_level:'planning'}]};
const out=planningApi.acceptShortPlanningDecision(root,task,{selected_number:1,action_id:'continue_next_stage',confirmation_input:'1',accepted_at:'2026-07-22T10:00:00.000Z'});
if(out.status!=='short_plan_accepted'||task.accepted_plan.status!=='accepted_pending_projection') throw new Error(JSON.stringify(out));
if(task.accepted_plan.affected_sections.join(',')!=='1,2,8,9') throw new Error(JSON.stringify(task.accepted_plan));
if(task.accepted_plan.proposal_id!=='proposal.fruit-ending-v2'||task.accepted_plan.summary!==task.proposed_plan.summary||task.proposed_plan.status!=='accepted') throw new Error(JSON.stringify(task));
if(task.accepted_plan.acceptance.confirmation_input!=='1'||task.accepted_plan.acceptance.confirmed_proposal_id!=='proposal.fruit-ending-v2'||task.accepted_plan.acceptance.confirmed_summary!==task.accepted_plan.summary) throw new Error(JSON.stringify(task.accepted_plan.acceptance));
if(task.accepted_plan.projection_plan.order.join(',')!=='planning_assets,briefs,prose_recheck,memory_projection') throw new Error(JSON.stringify(task.accepted_plan));
if(!fs.existsSync(path.join(root,task.accepted_plan_path))) throw new Error(task.accepted_plan_path);
const events=fs.readFileSync(path.join(root,task.task_dir,'decision-journal.jsonl'),'utf8').trim().split(/\n/).map(JSON.parse);
if(events.length!==1||events[0].event_type!=='short_plan_accepted') throw new Error(JSON.stringify(events));
if(fs.existsSync(path.join(root,'追踪/memory/planning-constraints.jsonl'))) throw new Error('decision memory must not pretend planning assets are already projected');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "planning projection stores the confirmed proposal instead of raw chat fragments" {
  printf '%s\n' '# 设定' '终局恢复真实鲜榨。' > "$BOOK/设定.md"
  printf '%s\n' '# 小节大纲' '第9节：公开可验证的新鲜榨线。' > "$BOOK/小节大纲.md"
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" "$REPO/scripts/lib/short-planning-memory.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const feedbackApi=require(process.argv[2]),planningApi=require(process.argv[3]),root=process.argv[4];
const task={workflow_id:'wf-short',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short',scope:'全篇'};
feedbackApi.enqueueShortFeedback(root,task,'酸就是酸。',{scopeSnapshot:'全篇'});
task.short_feedback_impact={impact_level:'planning',affected_sections:[9],affected_assets:['设定.md','小节大纲.md'],downstream_impact:{}};
task.proposed_plan={proposal_id:'proposal.fresh-juice-final',feedback_id:task.pending_feedback.feedback_id,summary:'结局让鲜果回到工厂并公开可验证生产。',requirements:[{requirement_id:'req-real-fresh-juice',text:'恢复真实鲜榨，旧货主动召回退款，新线公开生产证据。',impact_level:'planning'}]};
planningApi.acceptShortPlanningDecision(root,task,{selected_number:1,action_id:'continue_next_stage',confirmation_input:'采用上面的方案'});
const out=planningApi.projectAcceptedShortPlanningFeedback(root,task,{stage_id:'feedback_apply_patch',step_status:'completed',impact_level:'planning',affected_sections:[9],changed_files:['设定.md','小节大纲.md'],result_packet_path:'result.json'});
if(out.status!=='planning_constraints_projected'||out.constraint_ids[0]!=='constraint.req-real-fresh-juice') throw new Error(JSON.stringify(out));
const rows=fs.readFileSync(path.join(root,'追踪/memory/planning-constraints.jsonl'),'utf8').trim().split(/\n/).map(JSON.parse);
if(rows.length!==1||!/恢复真实鲜榨/.test(rows[0].content)||/酸就是酸/.test(rows[0].content)) throw new Error(JSON.stringify(rows));
if(rows[0].source_kind!=='user_confirmed_plan'||rows[0].provenance.proposal_id!=='proposal.fresh-juice-final') throw new Error(JSON.stringify(rows[0]));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a misclassified continuation is corrected in audit without becoming new canon" {
  run node - "$REPO/scripts/lib/short-feedback-working-memory.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const api=require(process.argv[2]);const root=process.argv[3];
const task={workflow_id:'wf-short',workflow_type:'short_write',task_dir:'追踪/workflow/tasks/wf-short'};
fs.mkdirSync(path.join(root,task.task_dir),{recursive:true});
fs.writeFileSync(path.join(root,task.task_dir,'feedback-inbox.jsonl'),JSON.stringify({event_type:'feedback_discarded',workflow_id:'wf-short',feedback_id:'feedback-summary-command'})+'\n');
const out=api.recordShortFeedbackReclassification(root,task,'feedback-summary-command',{classification:'accepted_plan_execution_command',preservedByPlanId:'accepted-plan.feedback-original'});
if(out.status!=='feedback_item_reclassified') throw new Error(JSON.stringify(out));
const duplicate=api.recordShortFeedbackReclassification(root,task,'feedback-summary-command',{classification:'accepted_plan_execution_command',preservedByPlanId:'accepted-plan.feedback-original'});
if(duplicate.status!=='feedback_item_reclassification_current') throw new Error(JSON.stringify(duplicate));
const row=fs.readFileSync(path.join(root,task.task_dir,'feedback-inbox.jsonl'),'utf8').trim().split(/\r?\n/).map(JSON.parse).at(-1);
if(row.event_type!=='feedback_reclassified'||row.preserved_by_plan_id!=='accepted-plan.feedback-original') throw new Error(JSON.stringify(row));
if(fs.existsSync(path.join(root,'追踪/memory/facts.jsonl'))) throw new Error('audit correction leaked into story facts');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "accepted cross-section feedback creates and advances a durable revision queue" {
  run node - "$REPO/scripts/lib/short-feedback-revision-queue.js" <<'NODE'
const api=require(process.argv[2]);
const task={workflow_id:'wf-short',workflow_type:'private_short_startup',scope:'全篇',pending_feedback:{feedback_id:'feedback-fruit'}};
const result={stage_id:'feedback_apply_patch',step_status:'completed',feedback_id:'feedback-fruit',affected_sections:[1,2,8,9],downstream_impact:{invalidate_briefs:['写作Brief_第001节.md','写作Brief_第002节.md','写作Brief_第008节.md','写作Brief_第009节.md'],recheck_prose:['正文/第001节.md','正文/第002节.md','正文/第008节.md','正文/第009节.md']}};
const policy={impact_level:'planning',affected_sections:[1,2,8,9]};
const created=api.initializeShortFeedbackRevisionQueue(task,result,policy);
if(created.status!=='feedback_revision_queue_created'||task.scope!=='第1节'||task.feedback_revision_queue.items.length!==4||task.feedback_revision_queue.items.some(item=>item.brief_status!=='invalidated'||item.prose_status!=='pending_recheck')) throw new Error(JSON.stringify(created));
let advanced=api.acceptShortFeedbackRevisionSection(task,1,{section_commit_id:'commit-1'});
if(advanced.status!=='feedback_revision_section_accepted'||advanced.next_section!==2||task.scope!=='第2节') throw new Error(JSON.stringify(advanced));
advanced=api.acceptShortFeedbackRevisionSection(task,2,{section_commit_id:'commit-2'});
if(advanced.next_section!==8||task.scope!=='第8节') throw new Error(JSON.stringify(advanced));
api.acceptShortFeedbackRevisionSection(task,8,{section_commit_id:'commit-8'});
advanced=api.acceptShortFeedbackRevisionSection(task,9,{section_commit_id:'commit-9'});
if(advanced.status!=='feedback_revision_queue_completed'||task.feedback_revision_queue.status!=='completed'||task.feedback_revision_queue.completed_sections.join(',')!=='1,2,8,9') throw new Error(JSON.stringify(advanced));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "structure impact expands an existing revision queue without losing progress" {
  run node - "$REPO/scripts/lib/short-feedback-revision-queue.js" <<'NODE'
const api=require(process.argv[2]);
const task={workflow_type:'private_short_startup',scope:'第2节',feedback_revision_queue:{schema_version:'1.0.0',queue_id:'revision.feedback',source_stage:'feedback_apply_patch',status:'running',affected_sections:[1,2,8,9],current_section_index:2,completed_sections:[1],items:[1,2,8,9].map(index=>({section_index:index,status:index===1?'accepted':'pending',brief_status:index===1?'rebuilt_and_used':'invalidated',prose_status:index===1?'rechecked_and_accepted':'pending_recheck',accepted_commit_id:index===1?'commit-1':'',completed_at:index===1?'2026-07-23T00:00:00.000Z':''})),created_at:'2026-07-23T00:00:00.000Z'}};
const result={stage_id:'short_structure_impact_audit',step_status:'completed',affected_sections:[1,2,3,5,8,9]};
const out=api.initializeShortFeedbackRevisionQueue(task,result,{});
if(out.status!=='feedback_revision_queue_expanded') throw new Error(JSON.stringify(out));
if(task.feedback_revision_queue.affected_sections.join(',')!=='1,2,3,5,8,9') throw new Error(JSON.stringify(task.feedback_revision_queue));
if(task.feedback_revision_queue.items.find(item=>item.section_index===1).status!=='accepted') throw new Error('accepted progress lost');
if(task.feedback_revision_queue.current_section_index!==2 || task.scope!=='第2节') throw new Error(JSON.stringify(task));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an upgraded task recovers title changes that an older impact audit missed" {
  mkdir -p "$BOOK/追踪/private-short-extension"
  cat > "$BOOK/追踪/private-short-extension/section-title-lock.json" <<'JSON'
{"status":"confirmed","sections":[{"section_index":1,"title":"第一节"},{"section_index":2,"title":"新标题"},{"section_index":3,"title":"第三节"}]}
JSON
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"accepted_sections":[{"section_index":1,"title":"第一节"},{"section_index":2,"title":"旧标题"},{"section_index":3,"title":"第三节"}]}
JSON
  run node - "$REPO/scripts/lib/short-feedback-revision-queue.js" "$BOOK" <<'NODE'
const api=require(process.argv[2]);
const root=process.argv[3];
const task={workflow_type:'private_short_startup',scope:'第1节',feedback_revision_queue:{queue_id:'revision.old',status:'running',affected_sections:[1],current_section_index:1,completed_sections:[],items:[{section_index:1,status:'pending',brief_status:'invalidated',prose_status:'pending_recheck'}]}};
const out=api.reconcileShortRevisionQueueWithTitleLock(root,task);
if(out.status!=='feedback_revision_queue_expanded') throw new Error(JSON.stringify(out));
if(task.feedback_revision_queue.affected_sections.join(',')!=='1,2') throw new Error(JSON.stringify(task.feedback_revision_queue));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
