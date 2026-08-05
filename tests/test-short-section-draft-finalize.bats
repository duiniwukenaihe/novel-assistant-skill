#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    FINALIZE="$REPO/scripts/short-section-draft-finalize.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/private-short-extension"
    printf '{"working_title":"测试短篇","current_section_index":7,"accepted_sections":[]}\n' > "$BOOK/追踪/private-short-extension/project-state.json"
    printf '# 第7节写作提要\n\n视角：我。\n人物：阿岚。\n因果：公开证据。\n钩子：负责人出现。\n禁止：不换视角。\n验收：完成冲突升级。\n' > "$BOOK/写作Brief_第007节.md"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$BOOK" --scope "第7节" --user-goal "写第7节" --no-private-registry --json >/dev/null
    WORKFLOW_ID="$(node -e 'const fs=require("fs"),path=require("path");const p=JSON.parse(fs.readFileSync(path.join(process.argv[1],"追踪/workflow/current-task.json"),"utf8"));console.log(p.workflow_id)' "$BOOK")"
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);const file=path.join(root,'追踪/workflow/tasks',id,'task.json');const t=JSON.parse(fs.readFileSync(file,'utf8'));
const token='test-confirmation-token',selectionId='pa-draft-7',hash='visible-choice-7',expires=new Date(Date.now()+3600000).toISOString();
t.current_stage='draft_section';t.current_step='draft_section';t.scope='第7节';t.status='running';
t.machine={...(t.machine||{}),completed_stages:['section_brief'],remaining_stages:['section_machine_gate','section_repair_loop','story_value_gate','feedback_impact_sync','feedback_apply_patch','section_accept_anchor','next_section_brief','full_story_assembly','deslop','final_check']};
t.pending_action={id:selectionId,status:'resolved',visible_choice_hash:hash};
t.last_selection={selection_id:selectionId,selected_number:1,action_id:'continue_next_stage',visible_choice_hash:hash,confirmation_token:token,requires_user_confirm:true};
t.stage_execution={status:'running',stage_id:'draft_section',step_id:'draft_section',action_id:'continue_next_stage',selected_number:1,owner_module:'story-short-write',expected_result_packet:`追踪/workflow/tasks/${id}/result-packets/draft_section.result.json`,write_set:['草稿_第007节_候选.md'],draft_target:'草稿_第007节_候选.md',draft_input_digest:'',requires_user_confirm:true,confirmation_token:token,confirmation_context:{status:'confirmed',workflow_id:id,workflow_type:t.workflow_type,stage_id:'draft_section',step_id:'draft_section',selection_id:selectionId,selected_number:1,selected_action_id:'continue_next_stage',visible_choice_hash:hash,confirmation_token:token,expires_at:expires}};
t.runtime_guard=t.runtime_guard||{};t.runtime_guard.checkpoint_policy={...(t.runtime_guard.checkpoint_policy||{}),resume_from:'draft_section',expected_result_packet:t.stage_execution.expected_result_packet};
fs.writeFileSync(file,JSON.stringify(t,null,2)+'\n');
NODE
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "draft finalize records one candidate and starts the machine gate" {
    cat > "$BOOK/草稿_第007节_候选.md" <<'MD'
# 第7节

我把复核记录投到会议室的白墙上。屏幕里的编号连续跳过一页，归档目录却声称材料完整。负责人推门进来，把三年前那份授权书放在桌上。他没有替我解释，只问审查组敢不敢把原始签收单也投上去。
MD

    run node "$FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
    if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"applied"'* ]]
    [[ "$output" == *'"next_stage":"section_machine_gate"'* ]]
    [[ "$output" == *'short-section-machine-gate.js'* ]]
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);const t=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
if(t.current_stage!=='section_machine_gate'||(t.stage_execution||{}).status!=='running') throw new Error(JSON.stringify(t));
NODE
}

@test "draft finalize refreshes stale short memory once and continues" {
    mkdir -p "$BOOK/追踪/memory"
    mkdir -p "$BOOK/追踪/story-system/short"
    printf '{"project_id":"short-test","working_title":"测试短篇","current_section_index":7,"accepted_sections":[{"section_index":1},{"section_index":2},{"section_index":3},{"section_index":4},{"section_index":5},{"section_index":6}],"narrative":{"planned_sections":9}}\n' > "$BOOK/追踪/story-system/short/project-state.json"
    printf '%s\n' '# 设定' '主角必须主动公开证据。' > "$BOOK/设定.md"
    cat > "$BOOK/小节大纲.md" <<'MD'
# 小节大纲

## 第7节：公开证据
- 承接上节：第6节留下关键文件来源未公开。
- 结构功能：反击升级。
- 开篇钩子：复核席追问文件是真是假。
- 故事承诺：主角必须用可核验的证据反击。
- 场景动作：主角把关键文件展示给公开复核席。
- 压力变化：被催促停止投影转为全场必须看文件编号。
- 角色选择：她不再等待主管解释。
- 可见阻力：有人催她停止复核。
- 因果链：拿到文件 -> 公开编号 -> 逼迫对方回应。
- 本节兑现：证据被公开看见。
- 关系变化：主角与主管从被保护转为公开对峙。
- 代价升级：她会失去部门内部权限。
- 核心承诺兑现：文件编号把谎言从口头争执变成公开证据。
- 决定性行动：她把文件编号投到公开屏幕。
- 现实后果：主管必须解释文件来源。
- 关系收束：兄妹关系暂时转为对立。
- 节尾钩子：对方必须回应文件来源。
## 第8节：继续追问
## 第9节：最终收束
MD
    printf '%s\n' '# 素材卡' '公开证据反击。' > "$BOOK/素材卡.md"
    printf '%s\n' '{"fact_id":"fact.prev","subject":"测试短篇","predicate":"第6节状态","object":"主角已经决定公开证据。","scope":{"book":"current","section":6},"status":"active"}' > "$BOOK/追踪/memory/facts.jsonl"
    node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');
const {buildStageContextPacket}=require(process.argv[2]);
const [root,id]=process.argv.slice(3);
const file=path.join(root,'追踪/workflow/tasks',id,'task.json');
const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.workflow_profile='private';
task.runtime_guard={...(task.runtime_guard||{}),token_estimate:{input_chars_estimate:12000,output_chars_budget:2000,risk_level:'low'}};
const packet=buildStageContextPacket({projectRoot:root,task,stage:'draft_section',options:{tokenBudget:4000}});
if(packet.status!=='assembled') throw new Error(JSON.stringify(packet));
if(!packet.memory_read_receipt) throw new Error(JSON.stringify(packet));
task.stage_execution.stage_context_packet={packet_json:packet.packet_json,packet_md:packet.packet_md,section_index:7};
task.stage_execution.memory_context={context_source:'stage_context',memory_read_receipt:packet.memory_read_receipt,memory_contract:packet.memory_contract};
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE
    printf '%s\n' '{"fact_id":"fact.changed","subject":"测试短篇","predicate":"第6节状态","object":"审计员已经把关键文件交给主角。","scope":{"book":"current","section":6},"status":"active"}' >> "$BOOK/追踪/memory/facts.jsonl"
    cat > "$BOOK/草稿_第007节_候选.md" <<'MD'
# 第7节

我把关键文件压在掌心，第一次没有等主管替我解释。会议室门外有人催我停止复核，我却把文件编号投到公开屏幕，让所有人先看清楚这份证据到底从哪儿来。

主管隔着桌子叫我的名字，我没有回头。那一刻我知道，继续说下去不是为了赢一场嘴仗，而是让每个参加复核的人都能顺着编号查到文件来源。
MD

    run node "$FINALIZE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --apply --json
    if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"applied"'* ]]
    [[ "$output" == *'"next_stage":"section_machine_gate"'* ]]
    node - "$BOOK" "$WORKFLOW_ID" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const t=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
if(t.current_stage!=='section_machine_gate') throw new Error(JSON.stringify(t));
if(Number((((t.stage_execution||{}).memory_context||{}).estimated_tokens)||0)<0) throw new Error(JSON.stringify(t.stage_execution));
NODE
}

@test "draft stages declare one target and one deterministic finalizer" {
    grep -q "execution.draft_target = draftTarget" "$STATE_MACHINE"
    grep -q "short-section-draft-finalize.js" "$STATE_MACHINE"
    grep -q "execution.write_set = \[draftTarget\]" "$STATE_MACHINE"
}
