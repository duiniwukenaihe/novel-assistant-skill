#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    FINALIZE="$REPO/scripts/short-section-repair-finalize.js"
    MACHINE_GATE="$REPO/scripts/short-section-machine-gate.js"
    QUALITY_GATE="$REPO/scripts/short-section-quality-gate.js"
    ACCEPT_FINALIZE="$REPO/scripts/short-section-accept-finalize.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/private-short-extension" "$BOOK/追踪/workflow"
    cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"project_id":"short-repair-test","plan_revision":1,"working_title":"测试短篇","narrative":{"planned_sections":8},"current_section_index":6,"accepted_sections":[{"section_index":5,"anchor_path":"追踪/private-short-extension/section-005-anchor.json"}]}
JSON
    printf '{"status":"accepted","section_index":5}\n' > "$BOOK/追踪/private-short-extension/section-005-anchor.json"
    printf '# 素材卡\n测试素材。\n' > "$BOOK/素材卡.md"
    printf '# 第6节\n\n这不是误会，是一场蓄谋已久的欺骗。\n' > "$BOOK/草稿_第006节_候选.md"
    printf '# 设定\n\n林昭是第一人称主角。\n主节奏：调查反击。\n共8节。\n' > "$BOOK/设定.md"
    cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲
## 第6节：摊牌
- 结构功能：中段判断翻转。
- 承接上节：上一节留下的伪造签名疑点迫使主角当面对质。
- 场景动作：主角把合同摊到桌上，当面圈出伪造签名。
- 子事件：
  1. 对手抢走合同并要求她停手。
  2. 主角用原始邮件证明签名被伪造。
- 情绪目标：怀疑到决绝。
- 压力变化：私下怀疑升级为失去家庭和工作保护的正面对抗。
- 因果链：发现签名异常 -> 当面对质 -> 对手抢夺 -> 主角留下备份。
- 角色选择：主角拒绝删除备份，选择承担家庭冲突。
- 可见阻力：对手当面抢夺合同并威胁停掉她的工作。
- 本节兑现：伪造签名从怀疑变成可验证事实。
- 关系变化：主角与对手从暗中怀疑转为当面对抗。
- 代价升级：主角失去工作保护，必须独立保存证据。
- 节尾钩子：备份邮件显示另一名家人早已知情。
EOF
    cat > "$BOOK/写作Brief_第006节.md" <<'EOF'
# 第6节写作提要

## 视角与人物
第一人称，林昭是主角。
## 大纲覆盖映射
- S00：中段判断翻转。
- B01：对手抢走合同并要求她停手。
- B02：主角用原始邮件证明签名被伪造。
- C01：主角拒绝删除备份，选择承担家庭冲突。
- H01：备份邮件显示另一名家人早已知情。
- Q01：上一节留下的伪造签名疑点迫使主角当面对质。
- V01：私下怀疑升级为失去家庭和工作保护的正面对抗。
- A01：主角把合同摊到桌上，当面圈出伪造签名。
- O01：对手当面抢夺合同并威胁停掉她的工作。
- P01：伪造签名从怀疑变成可验证事实。
- R01：主角与对手从暗中怀疑转为当面对抗。
- K01：主角失去工作保护，必须独立保存证据。
## 因果动作链
[Q01] -> [V01] -> [A01] -> [B01] -> [O01] -> [B02] -> [P01] -> [C01] -> [R01] -> [K01] -> [H01]
## 节尾钩子
另一名家人早已知情。
## 禁止漂移
不改人物，不引入外部救场。
## 验收标准
保留事实、对抗和代价。
EOF
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$BOOK" --scope "第6节" --user-goal "修订第6节" --json >/dev/null
    node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const file=path.join(root,pointer.task_dir,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
const gateRel=`${pointer.task_dir}/result-packets/section_machine_gate.result.json`;
fs.mkdirSync(path.dirname(path.join(root,gateRel)),{recursive:true});
fs.writeFileSync(path.join(root,gateRel),JSON.stringify({machine_gate_result:'blocking',blocking_findings:[{code:'quote-style',message:'统一改为中文弯引号。'}],evidence:[{check:'quote-style',status:'blocking',blocking:true,finding_count:2}]},null,2)+'\n');
task.current_stage='draft_next_section';task.current_step='draft_next_section';task.scope='第6节';
task.machine=task.machine||{};task.machine.last_result_packet=gateRel;
task.pending_feedback={feedback_id:'feedback-repair-test',text:'第6节AI味有点重',section_index:6,scope_snapshot:'第6节',received_at:new Date().toISOString()};
task.short_feedback_impact={status:'ok',feedback_id:'feedback-repair-test',impact_level:'expression_only',invalidates_draft:true,requires_reacceptance:true,applied_at:new Date().toISOString()};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    WORKFLOW_ID="$(node -e 'const fs=require("fs"),path=require("path");const p=JSON.parse(fs.readFileSync(path.join(process.argv[1],"追踪/workflow/current-task.json"),"utf8"));console.log(p.workflow_id)' "$BOOK")"
}

teardown() {
    rm -rf "$TMP_DIR"
}

prepare_valid_quality_evidence() {
    node - "$BOOK" "$WORKFLOW_ID" "$REPO" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [root,id,repo]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');
const task=JSON.parse(fs.readFileSync(file,'utf8'));
const draft='草稿_第006节_候选.md';
const lines=[
  '我把合同摊到桌上，红笔圈住第一处伪造签名。',
  '他伸手抢合同，我抢先把备份塞进外套。',
  '原始邮件的发送时间比所谓签署日早了两天。',
  '我拒绝删除备份，也拒绝再替他解释。',
  '他当场停掉我的工作权限，让我立刻离开。',
  '我第一次直接问他：这签名到底是谁仿的？',
  '门外的母亲没有进来，我们之间最后那点默契断了。',
  '我的手心全是汗，却还是当着他的面把邮件转存。',
  '备份邮件的抄送栏里，还有母亲的名字。',
  '这一刻，伪造签名不再是我的猜测。',
  '我失去了工作保护，也终于停止为家人找借口。',
];
fs.writeFileSync(path.join(root,draft),'# 第6节\n\n'+lines.join('\n\n')+'\n');
const artifact=`${task.task_dir}/artifacts/section-006-machine-gate.json`;
const packet=`${task.task_dir}/result-packets/section_machine_gate.section-006.result.json`;
const evidence=`${task.task_dir}/artifacts/section-006-story-review.json`;
fs.mkdirSync(path.dirname(path.join(root,artifact)),{recursive:true});
fs.writeFileSync(path.join(root,artifact),'{}\n');
fs.writeFileSync(path.join(root,packet),JSON.stringify({workflow_id:id,machine_gate_result:'pass',verification_result:'pass',outputs:[draft,artifact],blocking_findings:[]},null,2)+'\n');
const digest='sha256:'+crypto.createHash('sha256').update(fs.readFileSync(path.join(root,draft))).digest('hex');
const contract=require(path.join(repo,'scripts/lib/short-section-outline-contract')).buildShortSectionOutlineContract(root,6);
if(contract.status!=='current') throw new Error(JSON.stringify(contract));
const ids=['role_lock','causal_chain','title_promise','protagonist_agency','human_emotion','hook_payoff','story_attraction','continuity','drift_control','outline_fidelity','section_function_completion'];
const checks=ids.map((check,index)=>({id:check,status:'pass',evidence:'该原句证明当前维度在场景中真实发生。',evidence_quote:lines[index]}));
const outline_coverage=contract.obligations.filter((item)=>item.required_in_draft).map((item,index)=>({id:item.id,status:'pass',evidence_quote:lines[index%lines.length]}));
fs.writeFileSync(path.join(root,evidence),JSON.stringify({
  schemaVersion:'1.0.0',workflow_id:id,section_index:6,draft_digest:digest,
  outline_contract_digest:contract.contract_digest,outline_coverage,checks,
  summary:'第六节以当面抢夺和主角拒绝删除备份完成判断翻转。',
  acceptance_metadata:{revealed_information:['伪造签名已由原始邮件闭合'],character_state:{'林昭':'与对手公开对抗并失去工作权限'},open_hook:'母亲也在原始邮件抄送栏中',carry_forward:['追查母亲知情时间']}
},null,2)+'\n');
task.current_stage='quality_gate';task.current_step='quality_gate';task.status='running';task.pending_feedback=null;
task.machine=task.machine||{};task.machine.completed_stages=['section_machine_gate'];task.machine.remaining_stages=['quality_gate','section_accept_anchor','next_section_brief'];
task.stage_execution={status:'running',stage_id:'quality_gate',step_id:'quality_gate',owner_module:task.workflow_owner||'story-short-write',quality_evidence_target:evidence,expected_result_packet:`${task.task_dir}/result-packets/quality_gate.section-006.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
}

@test "quality gate accepts equivalent review card fields instead of looping on missing schema" {
    prepare_valid_quality_evidence
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');
const [root,id]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'artifacts/section-006-story-review.json');
const card=JSON.parse(fs.readFileSync(file,'utf8'));
card.candidate_digest=String(card.draft_digest||'').replace(/^sha256:/,'');
card.draft_digest='stale-digest-from-previous-candidate';
card.workflow_id='model-copied-wrong-workflow-id';
card.section_index=88;
card.outline_contract_digest='model-copied-wrong-contract-digest';
card.quality_dimensions=card.checks.map((row)=>({
  dimension:row.id,status:row.status,reason:row.evidence,evidence_quote:row.evidence_quote
}));
delete card.checks;
card.draft_outline_obligations=card.outline_coverage.map((row)=>({
  obligation_id:row.id,status:row.status,evidence_quote:row.evidence_quote
}));
delete card.outline_coverage;
card.revealed_information=card.acceptance_metadata.revealed_information.join('；');
card.character_state='林昭与对手公开对抗并失去工作权限';
card.open_hook=card.acceptance_metadata.open_hook;
delete card.acceptance_metadata;
fs.writeFileSync(file,JSON.stringify(card,null,2)+'\n');
NODE

    run node "$QUALITY_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"packet_ready"'* ]]
    [[ "$output" != *'quality_evidence_required'* ]]
}

@test "quality gate returns an exact writable schema when evidence is genuinely incomplete" {
    prepare_valid_quality_evidence
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');
const [root,id]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'artifacts/section-006-story-review.json');
const card=JSON.parse(fs.readFileSync(file,'utf8'));
card.checks=[];
card.outline_coverage=[];
delete card.acceptance_metadata;
fs.writeFileSync(file,JSON.stringify(card,null,2)+'\n');
NODE

    run node "$QUALITY_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"quality_evidence_required"'* ]]
    [[ "$output" == *'"evidence_schema"'* ]]
    [[ "$output" == *'"checks"'* ]]
    [[ "$output" == *'"outline_coverage"'* ]]
    [[ "$output" == *'"acceptance_metadata"'* ]]
}

@test "quality gate repairs unescaped quotes in an evidence quote once" {
    prepare_valid_quality_evidence
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');
const [root,id]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'artifacts/section-006-story-review.json');
const card=JSON.parse(fs.readFileSync(file,'utf8'));
const quote=card.checks[0].evidence_quote;
const raw=fs.readFileSync(file,'utf8').replace(JSON.stringify(quote),`""${quote}""`);
fs.writeFileSync(file,raw);
NODE

    run node "$QUALITY_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"packet_ready"'* ]]
    jq -e . "$BOOK/追踪/workflow/tasks/$WORKFLOW_ID/artifacts/section-006-story-review.json" >/dev/null
}

@test "repair finalizer reports an unstarted stage as recoverable state instead of console error" {
    run node "$FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"repair_stage_not_started"'* ]]
    [[ "$output" == *'"stage_execution_stage_id"'* ]]
}

@test "feedback repair stage exposes one candidate write target and one finalize command" {
    run node "$STATE_MACHINE" resume-pending-short-feedback --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/resume.json"
    node - "$TMP_DIR/resume.json" <<'NODE'
const fs=require('fs');const r=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const e=r.stage_execution||{};
if(e.stage_id!=='section_repair_loop') throw new Error(JSON.stringify(e));
if(JSON.stringify(e.write_set)!==JSON.stringify(['草稿_第006节_候选.md'])) throw new Error(JSON.stringify(e));
if(e.repair_target!=='草稿_第006节_候选.md') throw new Error(JSON.stringify(e));
if(!String(e.execution_command||'').includes('short-section-repair-finalize.js')) throw new Error(JSON.stringify(e));
if(!String(e.resume_hint||'').includes('只修改 草稿_第006节_候选.md')) throw new Error(JSON.stringify(e));
const kinds=((e.stage_context_packet||{}).source_files||[]).map((item)=>item.kind);
if(JSON.stringify(kinds)!==JSON.stringify(['gate_findings','memory_snapshot','outline_contract','repair_constraints','current_draft'])) throw new Error(JSON.stringify(kinds));
NODE
}

@test "repair finalize advances directly to a running machine gate" {
    node "$STATE_MACHINE" resume-pending-short-feedback --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json >/dev/null
    printf '# 第6节\n\n我把合同摊到桌上，逐页标出了伪造的签名。\n' > "$BOOK/草稿_第006节_候选.md"

    run node "$FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"applied"'* ]]
    [[ "$output" == *'"next_stage":"section_machine_gate"'* ]]
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
if(task.current_stage!=='section_machine_gate') throw new Error(JSON.stringify(task));
if((task.stage_execution||{}).status!=='running') throw new Error(JSON.stringify(task.stage_execution));
if(!String((task.stage_execution||{}).execution_command||'').includes('short-section-machine-gate.js')) throw new Error(JSON.stringify(task.stage_execution));
if(task.pending_feedback!==null) throw new Error(JSON.stringify(task.pending_feedback));
NODE
}

@test "gate policy recheck advances without fabricating a prose edit" {
    node "$STATE_MACHINE" resume-pending-short-feedback --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json >/dev/null
    run node "$FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --recheck-policy --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"next_stage":"section_machine_gate"'* ]]
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const packet=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'result-packets/section_repair_loop.section-006.result.json'),'utf8'));
if(packet.changed_files.length!==0||packet.evidence[0].reason!=='gate_policy_recheck_without_prose_change') throw new Error(JSON.stringify(packet));
NODE
}

@test "quote-only repair normalizes punctuation deterministically and returns to machine gate" {
    printf '# 第6节\n\n"你看清楚。"我把合同摊到桌上。\n' > "$BOOK/草稿_第006节_候选.md"
    node "$STATE_MACHINE" resume-pending-short-feedback --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json >/dev/null

    run node "$FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --normalize-quotes --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deterministic_repair":"mainland_quote_normalization"'* ]]
    [[ "$output" == *'"next_stage":"section_machine_gate"'* ]]
    ! grep -q '"' "$BOOK/草稿_第006节_候选.md"
    grep -q '“你看清楚。”' "$BOOK/草稿_第006节_候选.md"
}

@test "policy recheck reopens the same unchanged draft from quality gate" {
    printf '# 第6节\n\n"你看清楚。"我把合同摊到桌上。\n' > "$BOOK/草稿_第006节_候选.md"
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
const draft='草稿_第006节_候选.md';const artifact=`${task.task_dir}/artifacts/section-006-machine-gate.json`;
const packet=`${task.task_dir}/result-packets/section_machine_gate.result.json`;
const digest=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(path.join(root,draft))).digest('hex')}`;
fs.mkdirSync(path.dirname(path.join(root,artifact)),{recursive:true});
fs.writeFileSync(path.join(root,artifact),JSON.stringify({draft,draft_digest:digest,blocking_count:0},null,2)+'\n');
fs.writeFileSync(path.join(root,packet),JSON.stringify({workflow_id:id,machine_gate_result:'pass',verification_result:'pass',outputs:[draft,artifact],blocking_findings:[]},null,2)+'\n');
task.current_stage='quality_gate';task.current_step='quality_gate';task.status='running';
task.pending_feedback=null;
task.machine=task.machine||{};task.machine.completed_stages=['section_machine_gate'];task.machine.remaining_stages=['quality_gate','section_accept_anchor','next_section_brief'];task.machine.last_result_packet=packet;
task.stage_execution={status:'running',stage_id:'quality_gate',step_id:'quality_gate',expected_result_packet:`${task.task_dir}/result-packets/quality_gate.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$MACHINE_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --recheck-policy --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"gate_status":"blocking"'* ]]
    [[ "$output" == *'"next_stage":"section_repair_loop"'* ]]
    [[ "$output" == *'--normalize-quotes'* ]]
}

@test "single-section task records length variance and asks before continuing" {
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const stateFile=path.join(root,'追踪/private-short-extension/project-state.json');
const state=JSON.parse(fs.readFileSync(stateFile,'utf8'));
state.current_section_index=6;
state.accepted_sections=[1,2,3,4,5].map((n)=>({section_index:n,length_chars:1700,section_role:'normal'}));
fs.writeFileSync(stateFile,JSON.stringify(state,null,2)+'\n');
const draft='草稿_第006节_候选.md';
fs.writeFileSync(path.join(root,draft),'# 第6节\n\n'+Array.from({length:65},(_,n)=>`我核对第${n+1}页账目，记下证据。`).join('\n')+'\n');
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
const artifact=`${task.task_dir}/artifacts/section-006-machine-gate.json`;
const machine=`${task.task_dir}/result-packets/section_machine_gate.result.json`;
const quality=`${task.task_dir}/result-packets/quality_gate.result.json`;
fs.mkdirSync(path.dirname(path.join(root,artifact)),{recursive:true});
fs.writeFileSync(path.join(root,artifact),JSON.stringify({draft,draft_digest:`sha256:${'0'.repeat(64)}`,blocking_count:0},null,2)+'\n');
fs.writeFileSync(path.join(root,machine),JSON.stringify({workflow_id:id,machine_gate_result:'pass',verification_result:'pass',outputs:[draft,artifact],blocking_findings:[]},null,2)+'\n');
fs.writeFileSync(path.join(root,quality),JSON.stringify({workflow_id:id,quality_gate_result:'pass',verification_result:'pass',outputs:[draft],blocking_findings:[]},null,2)+'\n');
task.current_stage='section_accept_anchor';task.current_step='section_accept_anchor';task.status='running';task.pending_action=null;
task.pending_feedback=null;task.short_feedback_impact=null;
task.machine=task.machine||{};task.machine.last_result_packet=quality;
task.stage_execution={status:'running',stage_id:'section_accept_anchor',step_id:'section_accept_anchor',expected_result_packet:`${task.task_dir}/result-packets/section_accept_anchor.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$MACHINE_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --recheck-policy --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"short_length_choice_required"'* ]]
    [[ "$output" == *'"gate_status":"pass"'* ]]
    [[ "$output" == *'"next_stage":"quality_gate"'* ]]
    [[ "$output" == *'"accept_length_variance"'* ]]
    [[ "$output" == *'"revise_length_variance"'* ]]
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const packet=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'result-packets/section_machine_gate.section-006.result.json'),'utf8'));
if(packet.blocking_findings.some((item)=>item.code==='short-section-length-policy')) throw new Error(JSON.stringify(packet.blocking_findings));
if(packet.length_policy.verdict!=='outside_story_band_deferred'||packet.length_policy.blocking) throw new Error(JSON.stringify(packet.length_policy));
const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
if(task.current_stage!=='quality_gate') throw new Error(JSON.stringify(task));
if((task.stage_execution||{}).status!=='paused'||(task.pending_action.options||[]).length!==3) throw new Error(JSON.stringify(task));
NODE

    task_file="$BOOK/追踪/workflow/tasks/$WORKFLOW_ID/task.json"
    pending_id="$(jq -r '.pending_action.id' "$task_file")"
    choice_hash="$(jq -r '.pending_action.visible_choice_hash' "$task_file")"
    state_version="$(jq -r '.state_version' "$task_file")"
    run node "$STATE_MACHINE" resolve-action --project-root "$BOOK" --input 1 \
      --pending-action-id "$pending_id" --visible-choice-hash "$choice_hash" \
      --state-version "$state_version" --book-root "$BOOK" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"stage_started"'* ]]
    [[ "$output" == *'"action_id":"accept_length_variance"'* ]]
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
if(task.current_stage!=='quality_gate'||(task.stage_execution||{}).status!=='running') throw new Error(JSON.stringify(task));
if((task.short_length_choice||{}).status!=='accepted_for_final_review') throw new Error(JSON.stringify(task.short_length_choice));
NODE
}

@test "accept finalizer treats stale receipts as a handled revalidation instead of a console error" {
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const stateFile=path.join(root,'追踪/private-short-extension/project-state.json');const state=JSON.parse(fs.readFileSync(stateFile,'utf8'));
state.accepted_sections=[1,2,3,4,5].map((n)=>({section_index:n,length_chars:1700,section_role:'normal'}));
fs.writeFileSync(stateFile,JSON.stringify(state,null,2)+'\n');
const draft='草稿_第006节_候选.md';fs.writeFileSync(path.join(root,draft),'# 第6节\n\n'+Array.from({length:60},(_,n)=>`我翻到第${n+1}页，记下一笔账。`).join('\n')+'\n');
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
const artifact=`${task.task_dir}/artifacts/section-006-machine-gate.json`;const machine=`${task.task_dir}/result-packets/section_machine_gate.result.json`;const quality=`${task.task_dir}/result-packets/quality_gate.result.json`;
fs.mkdirSync(path.dirname(path.join(root,artifact)),{recursive:true});
fs.writeFileSync(path.join(root,artifact),JSON.stringify({draft,draft_digest:`sha256:${'0'.repeat(64)}`},null,2)+'\n');
fs.writeFileSync(path.join(root,machine),JSON.stringify({machine_gate_result:'pass',verification_result:'pass',outputs:[draft,artifact],blocking_findings:[]},null,2)+'\n');
fs.writeFileSync(path.join(root,quality),JSON.stringify({quality_gate_result:'pass',verification_result:'pass',outputs:[draft],blocking_findings:[]},null,2)+'\n');
task.current_stage='section_accept_anchor';task.current_step='section_accept_anchor';task.status='running';task.pending_action=null;task.pending_feedback=null;task.short_feedback_impact=null;
task.stage_execution={status:'running',stage_id:'section_accept_anchor',step_id:'section_accept_anchor',expected_result_packet:`${task.task_dir}/result-packets/section_accept_anchor.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$ACCEPT_FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"short_section_revision_required"'* ]]
    [[ "$output" == *'"next_stage":"section_repair_loop"'* ]]
    [[ "$output" != *'"status":"blocked_short_length_policy"'* ]]
}

@test "quality gate selects prose markdown instead of machine-gate JSON artifact" {
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');const [root,id]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
const draft='草稿_第006节_候选.md';const artifact=`${task.task_dir}/artifacts/section-006-machine-gate.json`;
const packet=`${task.task_dir}/result-packets/section_machine_gate.section-006.result.json`;
const evidence=`${task.task_dir}/artifacts/section-006-story-review.json`;
fs.mkdirSync(path.dirname(path.join(root,artifact)),{recursive:true});
fs.writeFileSync(path.join(root,artifact),'{}\n');
fs.writeFileSync(path.join(root,packet),JSON.stringify({workflow_id:id,machine_gate_result:'pass',verification_result:'pass',outputs:[draft,artifact],blocking_findings:[]},null,2)+'\n');
const digest='sha256:'+crypto.createHash('sha256').update(fs.readFileSync(path.join(root,draft))).digest('hex');
const checks=['role_lock','causal_chain','title_promise','protagonist_agency','human_emotion','hook_payoff','story_attraction','continuity','drift_control'].map((check)=>({id:check,status:'pass',evidence:'正文中已有对应动作证据。'}));
fs.writeFileSync(path.join(root,evidence),JSON.stringify({workflow_id:id,section_index:6,draft_digest:digest,checks},null,2)+'\n');
task.current_stage='quality_gate';task.current_step='quality_gate';task.status='running';task.pending_feedback=null;
task.stage_execution={status:'running',stage_id:'quality_gate',step_id:'quality_gate',quality_evidence_target:evidence,expected_result_packet:`${task.task_dir}/result-packets/quality_gate.section-006.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    prepare_valid_quality_evidence

    run node "$QUALITY_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const packet=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'result-packets/quality_gate.section-006.result.json'),'utf8'));
if(packet.outputs[0]!=='草稿_第006节_候选.md') throw new Error(JSON.stringify(packet.outputs));
NODE
}

@test "quality gate pass returns the exact four-choice workflow stop" {
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path'),crypto=require('crypto');const [root,id]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
const draft='草稿_第006节_候选.md';const artifact=`${task.task_dir}/artifacts/section-006-machine-gate.json`;
const packet=`${task.task_dir}/result-packets/section_machine_gate.section-006.result.json`;
const evidence=`${task.task_dir}/artifacts/section-006-story-review.json`;
fs.mkdirSync(path.dirname(path.join(root,artifact)),{recursive:true});
fs.writeFileSync(path.join(root,artifact),'{}\n');
fs.writeFileSync(path.join(root,packet),JSON.stringify({workflow_id:id,machine_gate_result:'pass',verification_result:'pass',outputs:[draft,artifact],blocking_findings:[]},null,2)+'\n');
const digest='sha256:'+crypto.createHash('sha256').update(fs.readFileSync(path.join(root,draft))).digest('hex');
const checks=['role_lock','causal_chain','title_promise','protagonist_agency','human_emotion','hook_payoff','story_attraction','continuity','drift_control'].map((check)=>({id:check,status:'pass',evidence:'正文中已有对应动作证据。'}));
fs.writeFileSync(path.join(root,evidence),JSON.stringify({workflow_id:id,section_index:6,draft_digest:digest,checks},null,2)+'\n');
task.current_stage='quality_gate';task.current_step='quality_gate';task.status='running';task.pending_feedback=null;
task.machine=task.machine||{};task.machine.completed_stages=['section_machine_gate'];task.machine.remaining_stages=['quality_gate','section_accept_anchor','next_section_brief'];
task.stage_execution={status:'running',stage_id:'quality_gate',step_id:'quality_gate',owner_module:task.workflow_owner||'story-short-write',quality_evidence_target:evidence,expected_result_packet:`${task.task_dir}/result-packets/quality_gate.section-006.result.json`};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    prepare_valid_quality_evidence

    run node "$QUALITY_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/quality-applied.json"
    node - "$TMP_DIR/quality-applied.json" <<'NODE'
const x=require(process.argv[2]);const options=x.next_candidates||[];
if(x.status!=='applied'||x.interaction_contract!=='render_visible_response_text_verbatim') throw new Error(JSON.stringify(x));
if(options.length!==4||options.map((item)=>item.number).join(',')!=='1,2,3,4') throw new Error(JSON.stringify(options));
if(options.filter((item)=>item.recommended).length!==1||!options[0].label.endsWith('（推荐）')) throw new Error(JSON.stringify(options));
const text=String((x.visible_response||{}).text||'');
if(!text.includes('1. ')||!text.includes('2. ')||!text.includes('3. ')||!text.includes('4. ')||!text.includes('回复 1/2/3/4')) throw new Error(text);
NODE
}

@test "repair finalize preserves edits and recovers a stale machine-gate execution" {
    node "$STATE_MACHINE" resume-pending-short-feedback --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json >/dev/null
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
const baseline=task.stage_execution.repair_input_digest;
const gateRel=`${task.task_dir}/result-packets/section_machine_gate.result.json`;
const artifactRel=`${task.task_dir}/artifacts/section-006-machine-gate.json`;
fs.mkdirSync(path.dirname(path.join(root,artifactRel)),{recursive:true});
fs.writeFileSync(path.join(root,gateRel),JSON.stringify({workflow_id:id,machine_gate_result:'blocking',verification_result:'blocking',outputs:['草稿_第006节_候选.md',artifactRel],blocking_findings:[{code:'quote-style',message:'统一引号'}]},null,2)+'\n');
fs.writeFileSync(path.join(root,artifactRel),JSON.stringify({draft:'草稿_第006节_候选.md',draft_digest:baseline,blocking_count:1},null,2)+'\n');
task.machine.last_result_packet=gateRel;
task.stage_execution={status:'paused',stage_id:'section_machine_gate',step_id:'section_machine_gate'};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    printf '# 第6节\n\n我把合同摊到桌上，逐页标出了伪造的签名。\n' > "$BOOK/草稿_第006节_候选.md"

    run node "$FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"applied"'* ]]
    [[ "$output" == *'"next_stage":"section_machine_gate"'* ]]
}

@test "existing section recheck prepares a candidate instead of reporting a missing draft" {
    rm "$BOOK/草稿_第006节_候选.md"
    mkdir -p "$BOOK/正文"
    printf '# 第6节\n\n现有正文保留，先进入受控复检。\n' > "$BOOK/正文/第006节.md"
    node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const file=path.join(root,pointer.task_dir,'task.json');const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.current_stage='section_machine_gate';task.current_step='section_machine_gate';task.status='running';task.scope='第6节';
task.feedback_revision_queue={status:'running',current_section_index:6,items:[{section_index:6,status:'pending',prose_status:'pending_recheck'}]};
task.stage_execution={status:'running',stage_id:'section_machine_gate',step_id:'section_machine_gate',owner_module:'story-short-write',expected_result_packet:`${pointer.task_dir}/result-packets/section_machine_gate.section-006.result.json`,write_set:[],memory_contract:{read_mode:'none',context_source:'none',receipt_required:false,update_mode:'none',projection_mode:'none'}};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$MACHINE_GATE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    [[ "$output" != *'"status":"short_draft_missing"'* ]]
    [ -f "$BOOK/草稿_第006节_候选.md" ]
    cmp "$BOOK/正文/第006节.md" "$BOOK/草稿_第006节_候选.md"
}
