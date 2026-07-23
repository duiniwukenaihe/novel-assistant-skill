#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/workflow-entry-guard.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/workflow" "$BOOK/追踪/输出门禁"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_focus_pointer() {
    node - "$BOOK" "$1" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
const pointer={schemaVersion:'1.0.0',workflow_id:id,task_dir:task.task_dir||`追踪/workflow/tasks/${id}`,focused_at:'2026-07-12T00:00:00.000Z',state_version:task.state_version||0};
fs.mkdirSync(path.join(root,'追踪/workflow'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify(pointer,null,2)+'\n');
NODE
}

@test "workflow entry guard runs supervisor and task inbox before new project onboarding" {
    [ -x "$SCRIPT" ]
    output="$(node "$SCRIPT" --project-root "$BOOK" --json)"
    echo "$output" | grep -q '"schemaVersion":"1.0.0"'
    echo "$output" | grep -q '"status":"new_project_ready"'
    echo "$output" | grep -q '"supervisor"'
    echo "$output" | grep -q '"task_inbox"'
    echo "$output" | grep -q '"output_gate"'
    echo "$output" | grep -q '"recommended_next":"show_new_project_onboarding"'
    echo "$output" | grep -q '1. 新开长篇'
    echo "$output" | grep -q '2. 新开短篇'
    echo "$output" | grep -q 'create_workflow:short_write'
    ! echo "$output" | grep -q 'create_workflow:short_startup'
    ! echo "$output" | grep -q '查看未完成任务（0 个）'
}

@test "workflow entry guard compact output omits the full inbox and supervisor payload" {
    output="$(node "$SCRIPT" --project-root "$BOOK" --compact --json)"
    echo "$output" | grep -q '"status":"new_project_ready"'
    echo "$output" | grep -q '"visible_response"'
    ! echo "$output" | grep -q '"migration_inventory"'
    ! echo "$output" | grep -q '"task_families"'
    [ "${#output}" -lt 6000 ]
}

@test "workflow entry guard writes task index and guard report when requested" {
    node "$SCRIPT" --project-root "$BOOK" --write --json >/dev/null
    [ -f "$BOOK/追踪/workflow/task-index.json" ]
    [ -f "$BOOK/追踪/workflow/entry-guard.json" ]
    grep -q '"metadata_only"' "$BOOK/追踪/workflow/task-index.json"
    grep -q '"schemaVersion"' "$BOOK/追踪/workflow/entry-guard.json"
    grep -q '"1.0.0"' "$BOOK/追踪/workflow/entry-guard.json"
}

@test "workflow entry guard reconciles the active task before showing its inbox" {
    mkdir -p "$BOOK/追踪/workflow/tasks/reconcile-entry"
    cat > "$BOOK/追踪/workflow/tasks/reconcile-entry/task.json" <<'JSON'
{
  "workflow_id":"reconcile-entry","workflow_type":"review_repair","task_dir":"追踪/workflow/tasks/reconcile-entry","status":"running","scope":"1-50章",
  "current_stage":"repair_execution_plan","current_step":"repair_execution_plan","lifecycle":{"status":"active"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","user_scope_choice"],"remaining_stages":["repair_execution_plan","staged_repair_candidate","repair_machine_gate","execute_repair","recheck","closure"]},
  "unit_lifecycle":{"status":"completed","current_stage":"closure","current_role":"handoff_and_next"},
  "runtime_guard":{"heartbeat":{"updated_at":"2026-07-11T10:00:00.000Z","latest_trusted_artifact":"追踪/workflow/current-task.json"},"stall_policy":{"heartbeat_timeout_minutes":999999},"checkpoint_policy":{"resume_from":"repair_execution_plan"}},
  "pending_action":{"id":"pa-rebuild","status":"pending","options":[{"number":1,"label":"重新生成受控修复方案","action_id":"continue_next_stage"}]}
}
JSON
    write_focus_pointer reconcile-entry

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --session-id claude-test --json)"

    echo "$output" | grep -q '"runtime_reconciliation"'
    echo "$output" | grep -q '"status":"runtime_reconciled"'
    node - "$BOOK/追踪/workflow/tasks/reconcile-entry/task.json" "$BOOK/追踪/workflow/current-task.json" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const pointer=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(task.unit_lifecycle.status!=='running'||task.runtime_guard.session_lease.holder_id!=='claude-test') throw new Error(JSON.stringify(task));
if(Object.keys(pointer).sort().join(',')!=='focused_at,schemaVersion,state_version,task_dir,workflow_id') throw new Error(JSON.stringify(pointer));
NODE
}

@test "workflow entry guard turns a task-family writer conflict into one explicit takeover menu" {
    mkdir -p "$BOOK/追踪/workflow/tasks/session-entry"
    cat > "$BOOK/追踪/workflow/tasks/session-entry/task.json" <<'JSON'
{
  "workflow_id":"session-entry","workflow_type":"review_repair","task_dir":"追踪/workflow/tasks/session-entry","status":"running","scope":"1-50章","user_goal":"审阅 1-50 章",
  "current_stage":"repair_execution_plan","current_step":"repair_execution_plan","lifecycle":{"status":"active"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","user_scope_choice"],"remaining_stages":["repair_execution_plan","staged_repair_candidate","repair_machine_gate","execute_repair","recheck","closure"]},
  "unit_lifecycle":{"status":"running","current_stage":"repair_execution_plan","current_role":"brief_or_contract"},
  "runtime_guard":{"heartbeat":{"updated_at":"2026-07-11T10:00:00.000Z","latest_trusted_artifact":"追踪/workflow/current-task.json"},"stall_policy":{"heartbeat_timeout_minutes":999999},"checkpoint_policy":{"resume_from":"repair_execution_plan"}},
  "pending_action":{"id":"pa-session","status":"pending","options":[{"number":1,"label":"继续当前阶段","action_id":"continue_next_stage"}]}
}
JSON
    write_focus_pointer session-entry

    node - "$REPO/scripts/lib/task-family-store.js" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const [storeFile,root]=process.argv.slice(2);
const store=require(storeFile);
const taskFile=path.join(root,'追踪/workflow/tasks/session-entry/task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
const family=store.ensureTaskFamily(root,task,{write:true}).family;
task.task_family_id=family.task_family_id;
fs.writeFileSync(taskFile,`${JSON.stringify(task,null,2)}\n`);
store.claimFamilyWriter(root,family.task_family_id,{session_id:'claude:writer',host:'claude'},{write:true,hostLiveness:()=> 'running'});
NODE
    write_focus_pointer session-entry

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --session-id codex:observer --compact --json)"

    echo "$output" | grep -q '"status":"blocked_workflow_session_lease"'
    echo "$output" | grep -q '"status":"workflow_session_takeover_required"'
    echo "$output" | grep -q '1. 接管当前任务'
    echo "$output" | grep -q '2. 只读查看当前任务'
    echo "$output" | grep -q '3. 暂不接管'
    echo "$output" | grep -q '4. 输入其他要求'
    ! echo "$output" | grep -q '继续当前阶段（推荐）'
}

@test "initialized project with zero unfinished tasks still gets the numbered inbox home" {
    printf '{"novel_assistant_bundle_id":"test"}\n' > "$BOOK/.story-deployed"
    printf '# 当前作品设定\n' > "$BOOK/设定.md"

    output="$(node "$SCRIPT" --project-root "$BOOK" --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '1. 查看未完成任务（0 个）'
    echo "$output" | grep -q '2. 查看智能推荐新任务'
    echo "$output" | grep -q '3. 开启当前作品新目标'
    echo "$output" | grep -q '4. 输入其他要求'
    echo "$output" | grep -q 'show_unfinished_tasks'
    echo "$output" | grep -q 'show_smart_recommendations'
    echo "$output" | grep -q 'show_new_goal_options'
    echo "$output" | grep -q 'execute_command_or_route_intent'
    ! echo "$output" | grep -q 'A. 继续写作'
}

@test "entry guard prompts supported legacy tasks to migrate into task families before inbox rendering" {
    mkdir -p "$BOOK/追踪/workflow/tasks/wf-legacy-family"
    printf '{"novel_assistant_bundle_id":"test"}\n' > "$BOOK/.story-deployed"
    cat > "$BOOK/追踪/workflow/tasks/wf-legacy-family/task.json" <<'JSON'
{"workflow_id":"wf-legacy-family","workflow_type":"review_repair","status":"running","scope":"1-200章","user_goal":"审阅 1-200 章","task_dir":"追踪/workflow/tasks/wf-legacy-family","lifecycle":{"status":"active"},"runtime_guard":{"heartbeat":{"updated_at":"2026-07-11T10:00:00.000Z"},"stall_policy":{"heartbeat_timeout_minutes":999999},"checkpoint_policy":{}}}
JSON
    write_focus_pointer wf-legacy-family

    output="$(node "$SCRIPT" --project-root "$BOOK" --json)"
    echo "$output" | grep -q '"status":"task_family_migration_pending"'
    echo "$output" | grep -q '1. 同步旧项目任务账本'
    echo "$output" | grep -q '"pending_task_count":1'
}

@test "workflow entry guard rejects a project root beneath a symlinked ancestor before writing" {
    mkdir -p "$TMP_DIR/outside-host/book/追踪/workflow"
    ln -s "$TMP_DIR/outside-host" "$TMP_DIR/host-escape"

    run node "$SCRIPT" --project-root "$TMP_DIR/host-escape/book" --write --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"status":"blocked_project_root"'* ]]
    [[ "$output" == *'"root_kind":"symlink_escape"'* ]]
    test ! -e "$TMP_DIR/outside-host/book/追踪/workflow/entry-guard.json"
}

@test "workflow entry guard stops at task inbox when resumable tasks exist" {
    mkdir -p "$BOOK/正文/第1卷" "$BOOK/大纲/第1卷"
    printf '# 第001章\n' > "$BOOK/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$BOOK/大纲/第1卷/细纲_第001章.md"

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '"recommended_next":"show_task_inbox_only"'
    echo "$output" | grep -q '"business_routing_allowed":false'
    echo "$output" | grep -q '"candidateCount":1'
    echo "$output" | grep -q '恢复旧项目工作流断点'
    echo "$output" | grep -q '"visible_response"'
    echo "$output" | grep -q '"render_mode":"text_numbers"'
    echo "$output" | grep -q '1. 查看未完成任务（1 个）'
    echo "$output" | grep -q '2. 查看智能推荐新任务'
    echo "$output" | grep -q '3. 开启当前作品新目标'
    echo "$output" | grep -q '4. 输入其他要求'
    echo "$output" | grep -q '回复数字选择。'
    ! echo "$output" | grep -q '\\n   '
    ! echo "$output" | grep -q '也可以直接输入新的'
    ! echo "$output" | grep -q '例如'
    ! echo "$output" | grep -q '\\n- 继续写'
    grep -q '"status": "task_inbox_ready"' "$BOOK/追踪/workflow/entry-guard.json"
}

@test "workflow entry guard renders multiple recoverable workflows as numbered groups" {
    mkdir -p "$BOOK/追踪/workflow" "$BOOK/追踪/private-short-extension" "$BOOK/追踪" "$BOOK/拆文库/盘龙"
    mkdir -p "$BOOK/追踪/workflow/tasks/long-1"
    cat > "$BOOK/追踪/workflow/tasks/long-1/task.json" <<'JSON'
{
  "workflow_id":"long-1",
  "workflow_type":"long_daily_write",
  "task_dir":"追踪/workflow/tasks/long-1",
  "status":"paused",
  "current_step":"第12卷第004章",
  "resume_hint":"/novel-assistant 继续写",
  "runtime_guard": {
    "heartbeat": {"latest_trusted_artifact": "追踪/workflow/current-task.md", "updated_at": "2026-07-07T09:00:00+08:00"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "workflow"}
  }
}
JSON
    write_focus_pointer long-1
    printf '# current task\n' > "$BOOK/追踪/workflow/current-task.md"
    cat > "$BOOK/追踪/private-short-extension/current-task.json" <<'JSON'
{"task_id":"short-1","title":"继续短篇素材卡","status":"in_progress","resume_hint":"/novel-assistant 继续短篇"}
JSON
    cat > "$BOOK/追踪/review-state.json" <<'JSON'
{"status":"paused","scope":"1-200","resume_hint":"/novel-assistant 继续审阅 1-200"}
JSON
    cat > "$BOOK/拆文库/盘龙/_progress.md" <<'EOF'
status: running
resume: /novel-assistant 继续拆《盘龙》
EOF

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '"business_routing_allowed":false'
    echo "$output" | grep -q '1. 查看未完成任务（'
    echo "$output" | grep -q '2. 查看智能推荐新任务'
    echo "$output" | grep -q '3. 开启当前作品新目标'
    echo "$output" | grep -q '4. 输入其他要求'
    echo "$output" | grep -q '回复数字选择。'
    ! echo "$output" | grep -q '\\n   '
    ! echo "$output" | grep -q '\\n- 继续写'
    ! echo "$output" | grep -q '\\n- 审查'
    ! echo "$output" | grep -q '例如'
}

@test "workflow entry guard blocks polluted visible drafts before they reach user" {
    draft="$BOOK/追踪/输出门禁/visible-draft.md"
    cat > "$draft" <<'EOF'
修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值修真进度阈值
EOF
    set +e
    output="$(node "$SCRIPT" --project-root "$BOOK" --visible-draft "$draft" --json 2>&1)"
    status="$?"
    set -e
    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"blocked_output_pollution"'
    echo "$output" | grep -q '"recommended_next":"blocked_recovery_template"'
}

@test "workflow entry guard explains missing task artifact as recoverable checkpoint issue" {
    mkdir -p "$BOOK/追踪/workflow"
    mkdir -p "$BOOK/追踪/workflow/tasks/review-missing-packet"
    cat > "$BOOK/追踪/workflow/tasks/review-missing-packet/task.json" <<'JSON'
{
  "workflow_id":"review-missing-packet",
  "workflow_type":"review_repair",
  "task_dir":"追踪/workflow/tasks/review-missing-packet",
  "status":"running",
  "user_goal":"审阅 1-200 章",
  "scope":"1-200",
  "current_stage":"evidence_scan",
  "current_step":"evidence_scan",
  "runtime_guard":{
    "heartbeat":{"latest_trusted_artifact":"追踪/workflow/tasks/review-missing-packet/result-packets/evidence_scan.result.json","updated_at":"2026-07-07T12:00:00+08:00"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"evidence_scan","checkpoint_path":"追踪/workflow/current-task.json"}
  }
}
JSON
    write_focus_pointer review-missing-packet

    run node "$SCRIPT" --project-root "$BOOK" --json
    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"blocked_trusted_artifact_missing"'
    echo "$output" | grep -q '当前任务断点不完整'
    echo "$output" | grep -q '恢复任务断点'
    ! echo "$output" | grep -q 'runtime_guard'
    ! echo "$output" | grep -q 'result packet'
}

@test "workflow entry guard returns a normal visible repair menu for state invariant blocks" {
    mkdir -p "$BOOK/追踪/workflow/tasks/state-bad"
    cat > "$BOOK/追踪/workflow/tasks/state-bad/task.json" <<'JSON'
{
  "workflow_id":"state-bad",
  "workflow_type":"short_write",
  "task_dir":"追踪/workflow/tasks/state-bad",
  "status":"running",
  "current_stage":"section_machine_gate",
  "current_step":"section_machine_gate",
  "machine":{"completed_stages":["section_machine_gate"],"remaining_stages":["section_repair_loop"]},
  "stage_execution":{"status":"running","stage_id":"draft_next_section","expected_result_packet":"追踪/workflow/tasks/state-bad/result-packets/draft_next_section.result.json"},
  "runtime_guard":{
    "heartbeat":{"updated_at":"2026-07-18T00:00:00.000Z","latest_trusted_artifact":"追踪/workflow/tasks/state-bad/result-packets/draft_next_section.result.json"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"current_stage"}
  }
}
JSON
    write_focus_pointer state-bad

    run node "$SCRIPT" --project-root "$BOOK" --write --json

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status":"blocked"'
    echo "$output" | grep -q '"reason_code":"state_invariant"'
    echo "$output" | grep -q '当前任务状态不一致，需先修复'
    echo "$output" | grep -q '1. 查看任务状态修复方案'
    echo "$output" | grep -q '2. 查看可恢复任务入口'
    grep -q '"status": "blocked"' "$BOOK/追踪/workflow/entry-guard.json"
}

@test "workflow entry guard auto repairs missing runtime guard before showing inbox" {
    mkdir -p "$BOOK/追踪/workflow/tasks/bad-1"
    cat > "$BOOK/追踪/workflow/tasks/bad-1/task.json" <<'JSON'
{"workflow_id":"bad-1","workflow_type":"long_write","task_dir":"追踪/workflow/tasks/bad-1","status":"running","current_stage":"prose"}
JSON
    write_focus_pointer bad-1
    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '"repaired":true'
    grep -q '"runtime_guard"' "$BOOK/追踪/workflow/tasks/bad-1/task.json"
    echo "$output" | grep -q '1. 查看未完成任务（1 个）'
    echo "$output" | grep -q '2. 查看智能推荐新任务'
    echo "$output" | grep -q '3. 开启当前作品新目标'
    echo "$output" | grep -q '4. 输入其他要求'
    ! echo "$output" | grep -q '\\n   '
    ! echo "$output" | grep -q '\\n- '
    ! echo "$output" | grep -q '例如'
}

@test "workflow entry guard repairs the durable focused task while retaining a pointer-only focus" {
    mkdir -p "$BOOK/追踪/workflow/tasks/bad-2"
    cat > "$BOOK/追踪/workflow/tasks/bad-2/task.json" <<'JSON'
{"workflow_id":"bad-2","workflow_type":"long_write","task_dir":"追踪/workflow/tasks/bad-2","status":"running","current_stage":"prose"}
JSON
    write_focus_pointer bad-2

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"

    echo "$output" | grep -q '"repaired":true'
    grep -q '"runtime_guard"' "$BOOK/追踪/workflow/tasks/bad-2/task.json"
    node - "$BOOK/追踪/workflow/current-task.json" "$BOOK/追踪/workflow/tasks/bad-2/task.json" <<'NODE'
const fs=require('fs');const pointer=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const task=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
if(Object.keys(pointer).sort().join(',')!=='focused_at,schemaVersion,state_version,task_dir,workflow_id') throw new Error(JSON.stringify(pointer));
if(pointer.workflow_id!==task.workflow_id||task.status!=='running') throw new Error(JSON.stringify({pointer,task}));
NODE
}

@test "workflow entry guard treats the durable task as the focused lifecycle authority" {
    mkdir -p "$BOOK/追踪/workflow/tasks/diverged-1"
    cat > "$BOOK/追踪/workflow/tasks/diverged-1/task.json" <<'JSON'
{"workflow_id":"diverged-1","workflow_type":"long_write","task_dir":"追踪/workflow/tasks/diverged-1","status":"running","current_stage":"prose","marker":"durable"}
JSON
    write_focus_pointer diverged-1

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"
    echo "$output" | grep -q '"repaired":true'
    grep -q '"runtime_guard"' "$BOOK/追踪/workflow/tasks/diverged-1/task.json"
    node - "$BOOK/追踪/workflow/current-task.json" <<'NODE'
const fs=require('fs');const pointer=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(Object.keys(pointer).sort().join(',')!=='focused_at,schemaVersion,state_version,task_dir,workflow_id') throw new Error(JSON.stringify(pointer));
NODE
}

@test "workflow entry guard visible response uses task cards before business guesses" {
    mkdir -p "$BOOK/追踪/workflow/tasks/short-brief-1"
    cat > "$BOOK/追踪/workflow/tasks/short-brief-1/task.json" <<'JSON'
{
  "workflow_id":"short-brief-1",
  "workflow_type":"short_write",
  "task_dir":"追踪/workflow/tasks/short-brief-1",
  "status":"running",
  "user_goal":"短篇《480万红本》第 4 节 Brief",
  "scope":"第4节",
  "current_stage":"section_brief",
  "current_step":"section_brief",
  "machine":{"next_stop_reason":"等待确认第 4 节 Brief 后再写正文"},
  "runtime_guard":{
    "heartbeat":{"latest_trusted_artifact":"写作Brief_第004节.md","updated_at":"2026-07-07T12:00:00+08:00"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"current_stage"}
  },
  "pending_action":{
    "options":[
      {"number":1,"label":"确认 Brief 并写第 4 节","action_id":"continue_next_stage","target_stage":"draft_section"},
      {"number":2,"label":"修改 Brief","action_id":"revise_brief"}
    ],
    "free_text_enabled":true
  }
}
JSON
    write_focus_pointer short-brief-1
    printf '# 第4节 Brief\n' > "$BOOK/写作Brief_第004节.md"

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '"task_cards"'
    echo "$output" | grep -q '"task_visible_menu"'
    echo "$output" | grep -q '1. 查看未完成任务（1 个）'
    echo "$output" | grep -q '2. 查看智能推荐新任务'
    echo "$output" | grep -q '输入其他要求'
    echo "$output" | grep -q '回复数字选择。'
    ! echo "$output" | grep -q '\\n   '
    echo "$output" | grep -q '"title":"短篇《480万红本》第 4 节 Brief"'
    echo "$output" | grep -q '"last_trusted_artifact":"写作Brief_第004节.md"'
    ! echo "$output" | grep -q '继续写第十二卷'
}

@test "workflow entry guard single review group has only numbered actionable choices" {
    mkdir -p "$BOOK/追踪/workflow/tasks/review-1-200"
    cat > "$BOOK/追踪/workflow/tasks/review-1-200/task.json" <<'JSON'
{
  "workflow_id":"review-1-200",
  "workflow_type":"review_repair",
  "task_dir":"追踪/workflow/tasks/review-1-200",
  "status":"running",
  "user_goal":"审阅 1-200 章节情节/钩子/剧情是否偏离大纲、细纲是否完整、行文是否顺畅",
  "scope":"1-200",
  "current_stage":"range_lock",
  "current_step":"ready_for_classify_findings",
  "machine":{"next_stop_reason":"停靠在确认审阅范围阶段"},
  "runtime_guard":{
    "heartbeat":{"latest_trusted_artifact":"追踪/workflow/current-task.json","updated_at":"2026-07-08T10:00:00+08:00"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"current_stage"}
  },
  "pending_action":{
    "options":[
      {"number":1,"label":"继续 classify_findings，full 模式审阅 1-50","action_id":"continue_full"},
      {"number":2,"label":"改为 lean 模式审阅 1-50","action_id":"continue_lean"},
      {"number":3,"label":"只审第 50 章","action_id":"single_chapter"}
    ],
    "free_text_enabled":true
  }
}
JSON
    write_focus_pointer review-1-200

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '1. 查看未完成任务（1 个）'
    echo "$output" | grep -q '2. 查看智能推荐新任务'
    echo "$output" | grep -q '3. 开启当前作品新目标'
    echo "$output" | grep -q '4. 输入其他要求'
    echo "$output" | grep -q '回复数字选择。'
    ! echo "$output" | grep -q '\\n   '
    echo "$output" | grep -q '"title":"审阅 1-200 章节情节/钩子/剧情是否偏离大纲、细纲是否完整、行文是否顺畅"'
    echo "$output" | grep -q '"last_trusted_artifact":"追踪/workflow/current-task.json"'
    ! echo "$output" | grep -q '工作流大类'
    ! echo "$output" | grep -q '回复 1 即查看'
    ! echo "$output" | grep -q '也可以直接输入新的'
    ! echo "$output" | grep -q '例如'
    ! echo "$output" | grep -q '\\n- 继续写'
    ! echo "$output" | grep -q '为 480万红本'
}

@test "workflow entry guard holds business routing for a pending legacy migration card" {
    mkdir -p "$BOOK/正文" "$BOOK/追踪/workflow/tasks/wf-legacy-review"
    printf '{"source_repository":"worldwonderer/oh-story-claudecode"}\n' > "$BOOK/.story-deployed"
    printf '# 第001章\n\n正文。\n' > "$BOOK/正文/chapter001.md"
    cat > "$BOOK/追踪/workflow/tasks/wf-legacy-review/task.json" <<'JSON'
{
  "workflow_id": "wf-legacy-review",
  "workflow_type": "review_repair",
  "status": "running",
  "task_dir": "追踪/workflow/tasks/wf-legacy-review",
  "scope": "1-200",
  "current_stage": "evidence_scan",
  "runtime_guard": {
    "heartbeat": {"updated_at": "2099-01-01T00:00:00.000Z", "latest_trusted_artifact": "追踪/workflow/current-task.json", "workflow_id": "wf-legacy-review"},
    "stall_policy": {"heartbeat_timeout_minutes": 60, "on_stall": "pause_at_checkpoint"},
    "checkpoint_policy": {"resume_from": "evidence_scan", "checkpoint_path": "追踪/workflow/current-task.json"}
  },
  "review_batches": {"batch_size": 50, "agent_count": 4, "agents": ["plot", "character", "canon", "prose"]}
}

JSON
    write_focus_pointer wf-legacy-review

    output="$(node "$SCRIPT" --project-root "$BOOK" --user-intent "/novel-assistant 继续审阅 1-200 章" --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '"business_routing_allowed":false'
    echo "$output" | grep -q '"task_family_migration_pending_count":1'
}

@test "workflow entry guard shows legacy migration before a stale heartbeat repair" {
    mkdir -p "$BOOK/正文" "$BOOK/追踪/workflow/tasks/wf-legacy-stale"
    printf '{"source_repository":"worldwonderer/oh-story-claudecode"}\n' > "$BOOK/.story-deployed"
    printf '# 第001章\n\n正文。\n' > "$BOOK/正文/chapter001.md"
    cat > "$BOOK/追踪/workflow/tasks/wf-legacy-stale/task.json" <<'JSON'
{
  "workflow_id": "wf-legacy-stale",
  "workflow_type": "review_repair",
  "status": "running",
  "task_dir": "追踪/workflow/tasks/wf-legacy-stale",
  "scope": "1-200",
  "current_stage": "evidence_scan",
  "runtime_guard": {
    "heartbeat": {"updated_at": "2020-01-01T00:00:00.000Z", "latest_trusted_artifact": "追踪/workflow/current-task.json", "workflow_id": "wf-legacy-stale"},
    "stall_policy": {"heartbeat_timeout_minutes": 1, "on_stall": "pause_at_checkpoint"},
    "checkpoint_policy": {"resume_from": "evidence_scan", "checkpoint_path": "追踪/workflow/current-task.json"}
  },
  "review_batches": {"batch_size": 50, "agent_count": 4, "agents": ["plot", "character", "canon", "prose"]}
}

JSON
    write_focus_pointer wf-legacy-stale

    output="$(node "$SCRIPT" --project-root "$BOOK" --json)"

    echo "$output" | grep -q '"status":"task_inbox_ready"'
    echo "$output" | grep -q '"business_routing_allowed":false'
    echo "$output" | grep -q '"task_family_migration_pending_count":1'
}

@test "workflow entry guard shows upstream migration before repairing a missing runtime guard" {
    mkdir -p "$BOOK/追踪/workflow/tasks/wf-upstream-review"
    cat > "$BOOK/.story-deployed" <<'JSON'
{"source_repository":"worldwonderer/oh-story-claudecode"}
JSON
    cat > "$BOOK/追踪/workflow/tasks/wf-upstream-review/task.json" <<'JSON'
{
  "workflow_id":"wf-upstream-review","workflow_type":"review_repair","status":"running",
  "task_dir":"追踪/workflow/tasks/wf-upstream-review","scope":"1-8","current_stage":"evidence_scan",
  "review_batches":{"batch_size":50,"agent_count":4,"agents":["plot","character","canon","prose"]}
}
JSON
    write_focus_pointer wf-upstream-review
    before_pointer="$(shasum -a 256 "$BOOK/追踪/workflow/current-task.json")"
    before_durable="$(shasum -a 256 "$BOOK/追踪/workflow/tasks/wf-upstream-review/task.json")"

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --json)"

    echo "$output" | grep -q '"status":"task_family_migration_pending"'
    echo "$output" | grep -q '"recommended_next":"preview_or_confirm_task_family_migration"'
    echo "$output" | grep -q '"task_family_migration_pending_count":1'
    echo "$output" | grep -q '"repaired":false'
    [ "$before_pointer" = "$(shasum -a 256 "$BOOK/追踪/workflow/current-task.json")" ]
    [ "$before_durable" = "$(shasum -a 256 "$BOOK/追踪/workflow/tasks/wf-upstream-review/task.json")" ]
}

@test "pending short feedback is an actionable menu with one exact recovery command" {
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$BOOK" --scope "第7节" --user-goal "继续短篇" --json >/dev/null
    node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const taskFile=path.join(root,pointer.task_dir,'task.json');
const task=JSON.parse(fs.readFileSync(taskFile,'utf8'));
task.current_stage='draft_next_section';task.current_step='draft_next_section';task.scope='第7节';
task.pending_feedback={feedback_id:'feedback-entry-test',text:'第6节AI味有点重',section_index:6,scope_snapshot:'第6节',received_at:new Date().toISOString()};
task.short_feedback_impact={status:'ok',feedback_id:'feedback-entry-test',impact_level:'expression_only',invalidates_draft:true,requires_reacceptance:true,applied_at:new Date().toISOString()};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" --project-root "$BOOK" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/pending-feedback-menu.json"
    node - "$TMP_DIR/pending-feedback-menu.json" <<'NODE'
const fs=require('fs');const report=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const visible=report.visible_response||{};const options=visible.options||[];
if(report.status!=='blocked') throw new Error(JSON.stringify(report));
if(visible.status!=='blocked_pending_feedback_unreconciled') throw new Error(JSON.stringify(visible));
if(visible.selection_contract!=='execute_command_or_route_intent') throw new Error(JSON.stringify(visible));
if((options[0]||{}).interaction_mode!=='execute_command') throw new Error(JSON.stringify(options));
if(!String((options[0]||{}).execution_command||'').includes('resume-pending-short-feedback')) throw new Error(JSON.stringify(options));
if(!String((options[0]||{}).execution_command||'').includes('--workflow-id')) throw new Error(JSON.stringify(options));
if((String(visible.text||'').match(/^1\./gm)||[]).length!==1) throw new Error(visible.text);
if(String(visible.text||'').includes('1. 当前反馈尚未同步影响链')) throw new Error(visible.text);
NODE
}

@test "explicit whole story short revision bypasses inbox and returns one direct command" {
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    mkdir -p "$BOOK"
    printf '# 素材卡\n' > "$BOOK/素材卡.md"
    printf '# 设定\n' > "$BOOK/设定.md"
    printf '# 小节大纲\n' > "$BOOK/小节大纲.md"
    printf '# 正文\n' > "$BOOK/正文.md"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$BOOK" --scope "全篇" --user-goal "新开短篇" --json >/dev/null

    run node "$SCRIPT" --project-root "$BOOK" --user-intent "可以，根据总结的这些开始整篇修改" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/direct-revision.json"
    node - "$TMP_DIR/direct-revision.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='pass'||!out.runner_contract.business_routing_allowed) throw new Error(JSON.stringify(out));
const direct=out.direct_intent||{};
if(direct.intent_type!=='short_revision_feedback'||direct.interaction_mode!=='execute_command'||direct.requires_user_confirm!==false) throw new Error(JSON.stringify(direct));
if(!String(direct.execution_command||'').includes('workflow-state-machine.js resolve-action')) throw new Error(JSON.stringify(direct));
if(!String(direct.execution_command||'').includes('整篇修改')) throw new Error(JSON.stringify(direct));
const visible=out.visible_response||{};
if(visible.render_mode!=='silent_execute'||visible.selection_contract!=='execute_direct_intent_command') throw new Error(JSON.stringify(visible));
if(String(visible.text||'')!=='') throw new Error(JSON.stringify(visible));
NODE
}

@test "all interactive hosts resume a running short stage with a portable project command" {
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    printf '# 素材卡\n' > "$BOOK/素材卡.md"
    printf '# 设定\n' > "$BOOK/设定.md"
    printf '# 小节大纲\n' > "$BOOK/小节大纲.md"
    printf '# 正文\n' > "$BOOK/正文.md"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$BOOK" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$STATE_MACHINE" resolve-action --project-root "$BOOK" --input "整篇回炉：更新结局和人物关系。" --json >/dev/null
    local task_file
    task_file="$(node - "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
process.stdout.write(path.join(root,pointer.task_dir,'task.json'));
NODE
)"
    node - "$task_file" "$BOOK" <<'NODE'
const fs=require('fs');const file=process.argv[2],root=process.argv[3];const task=JSON.parse(fs.readFileSync(file,'utf8'));
task.stage_execution.execution_command=`node scripts/short-planning-stage-finalize.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(task.workflow_id)} --apply --json`;
fs.writeFileSync(file,JSON.stringify(task,null,2)+'\n');
NODE

    run node "$SCRIPT" --project-root "$BOOK" --user-intent "继续执行已确认的整篇回炉反馈" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/running-stage-resume.json"
    node - "$TMP_DIR/running-stage-resume.json" "$BOOK" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),root=process.argv[3];
const direct=out.direct_intent||{},visible=out.visible_response||{},execution=visible.stage_execution||{};
if(direct.status!=='stage_execution_resume_ready'||direct.interaction_mode!=='resume_stage') throw new Error(JSON.stringify(direct));
if(visible.render_mode!=='silent_resume'||visible.selection_contract!=='resume_running_stage') throw new Error(JSON.stringify(visible));
if(execution.execution_workdir!=='.'||!String(execution.execution_command||'').includes('--project-root .')) throw new Error(JSON.stringify(execution));
if(JSON.stringify({direct,visible}).includes(root)) throw new Error('absolute project root leaked into host continuation');
NODE
}

@test "bare skill invocation shows running stage controls instead of silently resuming" {
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    printf '# 素材卡\n' > "$BOOK/素材卡.md"
    printf '# 设定\n' > "$BOOK/设定.md"
    printf '# 小节大纲\n' > "$BOOK/小节大纲.md"
    printf '# 正文\n' > "$BOOK/正文.md"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$BOOK" --scope "全篇" --user-goal "新开短篇" --json >/dev/null
    node "$STATE_MACHINE" resolve-action --project-root "$BOOK" --input "整篇回炉：更新结局和人物关系。" --json >/dev/null

    run node "$SCRIPT" --project-root "$BOOK" --user-intent "/novel-assistant" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/bare-running-stage.json"
    node - "$TMP_DIR/bare-running-stage.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),visible=out.visible_response||{};
if(out.recommended_next!=='show_running_stage_controls') throw new Error(JSON.stringify(out));
if(visible.status!=='running_stage_waiting_choice'||visible.selection_contract!=='execute_command_or_route_intent') throw new Error(JSON.stringify(visible));
for(const expected of ['1. 继续当前阶段（推荐）','2. 查看当前进度与依据','3. 暂停并保存断点','4. 输入其他要求']) {
  if(!String(visible.text||'').includes(expected)) throw new Error(JSON.stringify(visible));
}
if(out.direct_intent) throw new Error('bare skill invocation must not infer a business intent');
if((visible.options||[]).slice(0,3).some(option=>option.interaction_mode!=='execute_command'||!String(option.execution_command||'').includes('--project-root .'))) throw new Error(JSON.stringify(visible.options));
NODE
}

@test "a concrete short section proposal is treated as direct feedback" {
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    mkdir -p "$BOOK"
    printf '# 设定\n' > "$BOOK/设定.md"
    printf '# 小节大纲\n' > "$BOOK/小节大纲.md"
    printf '# 正文\n' > "$BOOK/正文.md"
    node "$STATE_MACHINE" create --workflow-type short_write --project-root "$BOOK" --scope "全篇" --user-goal "新开短篇" --json >/dev/null

    run node "$SCRIPT" --project-root "$BOOK" --user-intent "第9节可以加一个宿舍群场面，结尾建议改成熟人先放购物车。" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/direct-proposal.json"
    node - "$TMP_DIR/direct-proposal.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if((out.direct_intent||{}).intent_type!=='short_revision_feedback') throw new Error(JSON.stringify(out));
NODE
}

@test "workflow entry guard is documented and bundled" {
    grep -q "workflow-entry-guard.js" "$REPO/scripts/README.md"
    grep -q '"workflow-entry-guard.js"' "$REPO/config/novel-assistant-bundle-files.json"
    grep -q "workflow-entry-guard.js" "$REPO/skills/novel-assistant/SKILL.md"
    grep -q 'candidateCount=0.*仍显示' "$REPO/skills/novel-assistant/references/internal-skills/story-workflow/references/task-inbox-protocol.md"
    grep -q '逐字展示.*visible_response.text' "$REPO/src/internal-skills/story-setup/SKILL.md"
}
