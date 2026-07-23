#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    FINALIZE="$REPO/scripts/short-section-draft-finalize.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/private-short-extension"
    printf '{"working_title":"测试短篇","current_section_index":7,"accepted_sections":[]}\n' > "$BOOK/追踪/private-short-extension/project-state.json"
    printf '# 第7节写作提要\n\n视角：我。\n人物：林昭。\n因果：公开证据。\n钩子：母亲出现。\n禁止：不换视角。\n验收：完成冲突升级。\n' > "$BOOK/写作Brief_第007节.md"
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

我把直播回放投到会议室的白墙上。屏幕里，传送带一直在转，镜头扫过的仓库却连一只果筐都没有。母亲推门进来，把三年前那份弃权书放在桌上。她没有替我解释，只问董事会敢不敢把原料采购单也投上去。
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

@test "draft stages declare one target and one deterministic finalizer" {
    grep -q "execution.draft_target = draftTarget" "$STATE_MACHINE"
    grep -q "short-section-draft-finalize.js" "$STATE_MACHINE"
    grep -q "execution.write_set = \[draftTarget\]" "$STATE_MACHINE"
}
