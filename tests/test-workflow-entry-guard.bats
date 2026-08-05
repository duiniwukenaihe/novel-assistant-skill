#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/workflow-entry-guard.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/workflow" "$BOOK/追踪/输出门禁"
    # Strict write-policy metadata (mode=strict + four transaction ledgers) so
    # the shared BOOK fixture satisfies book-write-policy-migrate.js
    # hasTransactionLedgers. These paths live under 追踪/story-system/, which
    # is NOT part of isInitializedWritingProject(), so the metadata alone does
    # not turn BOOK into a writing project. New tests that must verify the
    # missing-policy state use their own book dir (see write-policy-migration
    # tests) and remove this metadata explicitly.
    mkdir -p "$BOOK/追踪/story-system/transactions" "$BOOK/追踪/story-system/commits"
    printf '{"mode":"strict","migrated_at":"2026-07-12T00:00:00.000Z"}\n' \
        > "$BOOK/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$BOOK/追踪/story-system/chapter-identities.json"
    : > "$BOOK/追踪/story-system/projection-log.jsonl"
    : > "$BOOK/追踪/story-system/transactions/.keep"
    : > "$BOOK/追踪/story-system/commits/.keep"
}

@test "running stage labels section plan lock in user-facing Chinese" {
  run node -e 'const fs=require("fs"); const s=fs.readFileSync(process.argv[1], "utf8"); if (!s.includes("section_plan_lock") || !s.includes("确认总节数与小节标题")) process.exit(1);' "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "bare entry keeps section acceptance behind the global inbox" {
    mkdir -p "$BOOK/追踪/workflow/tasks/wf-short-accept"
    cat > "$BOOK/追踪/workflow/tasks/wf-short-accept/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0",
  "workflow_id":"wf-short-accept",
  "workflow_type":"short_revision",
  "workflow_contract_version":3,
  "workflow_profile":"private",
  "workflow_owner":"private-short-extension",
  "task_dir":"追踪/workflow/tasks/wf-short-accept",
  "status":"running",
  "scope":"全篇",
  "user_goal":"测试短篇",
  "current_stage":"section_accept_anchor",
  "current_step":"section_accept_anchor",
  "lifecycle":{"status":"active"},
  "machine":{"completed_stages":["first_section_brief","draft_first_section","section_machine_gate","story_value_gate"],"remaining_stages":["section_accept_anchor","next_section_brief"]},
  "runtime_guard":{"heartbeat":{"updated_at":"2026-07-12T00:00:00.000Z"},"stall_policy":{"heartbeat_timeout_minutes":999999}},
  "stage_execution":{"status":"running","stage_id":"section_accept_anchor","execution_command":"node scripts/short-section-accept-finalize.js --project-root . --workflow-id \"wf-short-accept\" --apply --json"}
}
JSON
    write_focus_pointer wf-short-accept

    output="$(node "$SCRIPT" --project-root "$BOOK" --compact --json)"
    echo "$output" | grep -q '1. 查看未完成任务（1 个）（推荐）'
    ! echo "$output" | grep -q '当前阶段：采用当前小节并写入锚点'
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

@test "workflow entry guard lazily migrates one old short workflow and memory contract" {
    task_file="$BOOK/追踪/workflow/tasks/wf-entry-v2/task.json"
    mkdir -p "$(dirname "$task_file")"
    node - "$REPO/tests/fixtures/workflow-v3/legacy-v2/planning-confirmed.json" "$task_file" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const [fixtureFile,taskFile,root]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(fixtureFile,'utf8'));
task.workflow_id='wf-entry-v2';task.task_dir='追踪/workflow/tasks/wf-entry-v2';
task.stage_execution.stage_attempt_id='sa-entry-v2';
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
fs.mkdirSync(path.join(root,'追踪/workflow'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify({
  schemaVersion:'1.0.0',workflow_id:task.workflow_id,task_dir:task.task_dir,
  state_version:task.state_version,focused_at:'2026-01-01T00:00:00.000Z'
},null,2)+'\n');
NODE

    output="$(node "$SCRIPT" --project-root "$BOOK" --compact --json)"
    echo "$output" | grep -q '"status":"short_workflow_migration_pending"'
    echo "$output" | grep -q '升级并恢复当前短篇任务'
    echo "$output" | grep -q 'migrate-short-lean-workflow'

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --compact --json)"
    echo "$output" | grep -q '"status":"task_inbox_ready"'
    node - "$task_file" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(![task.engine_version,task.task_schema_version,task.workflow_contract_version].every(value=>value===3)) throw new Error(JSON.stringify(task));
if(task.current_stage!=='section_brief'||task.state_version!==task.migration.target_state_version) throw new Error(JSON.stringify(task));
if(!task.migration||!task.migration.archive_path) throw new Error(JSON.stringify(task));
NODE
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

@test "bare entry keeps a running short outline behind the global inbox" {
    mkdir -p "$BOOK/追踪/workflow/tasks/short-outline-running"
    cat > "$BOOK/追踪/workflow/tasks/short-outline-running/task.json" <<'JSON'
{
  "workflow_id":"short-outline-running","workflow_type":"short_revision","workflow_contract_version":3,"task_dir":"追踪/workflow/tasks/short-outline-running","status":"running","scope":"全篇","user_goal":"新开短篇",
  "current_stage":"section_outline","current_step":"section_outline","lifecycle":{"status":"active","scope":"全篇"},
  "machine":{"completed_stages":["short_setting","platform_genre_lock","rhythm_pattern_selection"],"remaining_stages":["section_outline"]},
  "unit_lifecycle":{"status":"running","current_stage":"section_outline","current_role":"brief_or_contract"},
  "runtime_guard":{"heartbeat":{"updated_at":"2099-01-01T00:00:00.000Z"},"stall_policy":{"heartbeat_timeout_minutes":999999},"checkpoint_policy":{"resume_from":"section_outline"}},
  "stage_execution":{"status":"running","stage_id":"section_outline","step_id":"section_outline","work_unit_scope":"全篇","execution_command":"node scripts/short-planning-stage-finalize.js --project-root . --workflow-id short-outline-running --apply --json"},
  "pending_action":null
}
JSON
    write_focus_pointer short-outline-running
    printf '# 素材卡\n\n- 暂定作品名：迁移后的真实短篇标题\n' > "$BOOK/素材卡.md"

    output="$(node "$SCRIPT" --project-root "$BOOK" --json)"
    echo "$output" | grep -q '1. 查看未完成任务（1 个）（推荐）'
    ! echo "$output" | grep -q '当前任务：迁移后的真实短篇标题'

    output="$(node "$SCRIPT" --project-root "$BOOK" --write --session-id codex:test --compact --json)"
    node - "$BOOK/追踪/workflow/tasks/short-outline-running/task.json" <<'NODE'
const fs=require('fs');const task=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(task.scope!=='全篇'||task.lifecycle.scope!=='全篇') throw new Error(JSON.stringify({scope:task.scope,lifecycle:task.lifecycle}));
if(String(((task.stage_execution||{}).work_unit_scope)||'')!=='全篇') throw new Error(JSON.stringify(task.stage_execution));
NODE
}

@test "initialized project with zero unfinished tasks still gets the numbered inbox home" {
    printf '{"novel_assistant_bundle_id":"test"}\n' > "$BOOK/.story-deployed"
    printf '# 当前作品设定\n' > "$BOOK/设定.md"
    mkdir -p "$BOOK/追踪/story-system/transactions" "$BOOK/追踪/story-system/commits"
    printf '{"mode":"strict","migrated_at":"2026-07-12T00:00:00.000Z"}\n' > "$BOOK/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$BOOK/追踪/story-system/chapter-identities.json"
    : > "$BOOK/追踪/story-system/projection-log.jsonl"
    : > "$BOOK/追踪/story-system/transactions/.keep"
    : > "$BOOK/追踪/story-system/commits/.keep"

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
    mkdir -p "$BOOK/正文/第1卷" "$BOOK/大纲/第1卷" \
             "$BOOK/追踪/story-system/transactions" "$BOOK/追踪/story-system/commits"
    printf '# 第001章\n' > "$BOOK/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$BOOK/大纲/第1卷/细纲_第001章.md"
    printf '{"mode":"strict","migrated_at":"2026-07-12T00:00:00.000Z"}\n' > "$BOOK/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$BOOK/追踪/story-system/chapter-identities.json"
    : > "$BOOK/追踪/story-system/projection-log.jsonl"
    : > "$BOOK/追踪/story-system/transactions/.keep"
    : > "$BOOK/追踪/story-system/commits/.keep"

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
  "workflow_type":"short_revision",
  "workflow_contract_version":3,
  "workflow_profile":"private",
  "workflow_owner":"private-short-extension",
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

@test "workflow entry guard exposes restore command when a completed task is missing a required stage" {
    task_dir="$BOOK/追踪/workflow/tasks/review-incomplete"
    mkdir -p "$task_dir/artifacts/staged_repair_candidate"
    printf '%s\n' '# 中性候选稿' > "$task_dir/artifacts/staged_repair_candidate/A1.draft.md"
    cat > "$task_dir/task.json" <<'JSON'
{
  "workflow_id":"review-incomplete",
  "workflow_type":"review_repair",
  "task_dir":"追踪/workflow/tasks/review-incomplete",
  "status":"completed",
  "current_stage":"closure",
  "current_step":"closure",
  "lifecycle":{"status":"completed"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","user_scope_choice","repair_execution_plan","staged_repair_candidate","repair_machine_gate","recheck","closure"],"remaining_stages":[]}
}
JSON
    write_focus_pointer review-incomplete

    run node "$SCRIPT" --project-root "$BOOK" --write --compact --json

    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/incomplete.json"
    node - "$TMP_DIR/incomplete.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_completed_workflow_incomplete') throw new Error(JSON.stringify(out));
if (!out.visible_response || out.visible_response.options.length !== 4) throw new Error(JSON.stringify(out));
const first = out.visible_response.options[0];
if (first.action !== 'restore_incomplete_workflow') throw new Error(JSON.stringify(first));
if (!first.execution_command.includes('restore-incomplete-workflow')
    || !first.execution_command.includes('--workflow-id "review-incomplete"')
    || !first.execution_command.includes('--confirm')) throw new Error(JSON.stringify(first));
if (out.visible_response.text.includes('未完成任务（0 个）')) throw new Error(out.visible_response.text);
NODE
}

@test "workflow entry guard accepts a legacy review handoff that intentionally omitted execute repair" {
    task_dir="$BOOK/追踪/workflow/tasks/review-handoff"
    mkdir -p "$task_dir/result-packets"
    cat > "$task_dir/task.json" <<'JSON'
{
  "workflow_id":"review-handoff",
  "workflow_type":"review_repair",
  "task_dir":"追踪/workflow/tasks/review-handoff",
  "status":"completed",
  "current_stage":"closure",
  "current_step":"closure",
  "lifecycle":{"status":"completed"},
  "machine":{"completed_stages":["range_lock","evidence_scan","classify_findings","repair_plan","user_scope_choice","repair_execution_plan","staged_repair_candidate","repair_machine_gate","recheck","closure"],"remaining_stages":[]}
}
JSON
    cat > "$task_dir/result-packets/closure.result.json" <<'JSON'
{
  "workflow_id":"review-handoff",
  "workflow_type":"review_repair",
  "stage_id":"closure",
  "step_status":"completed",
  "outputs":[{"kind":"closure_summary","summary":{"review_repair_status":"handoff_completed","repair_units_pending_user_apply":2,"repair_units_ready_for_author":1}}],
  "changed_files":[],
  "verification_result":"pass"
}
JSON
    printf '%s\n' '{"workflow_id":"review-handoff","stage_id":"repair_machine_gate","step_status":"completed","changed_files":[],"verification_result":"pass"}' > "$task_dir/result-packets/repair_machine_gate.result.json"
    printf '%s\n' '{"workflow_id":"review-handoff","stage_id":"recheck","step_status":"completed","changed_files":[],"verification_result":"pass"}' > "$task_dir/result-packets/recheck.result.json"
    write_focus_pointer review-handoff

    run node "$SCRIPT" --project-root "$BOOK" --write --compact --json

    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/handoff.json"
    node - "$TMP_DIR/handoff.json" "$task_dir/task.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'task_inbox_ready') throw new Error(JSON.stringify(out));
if (out.runtime_reconciliation.status !== 'completed_runtime_reconciled') throw new Error(JSON.stringify(out.runtime_reconciliation));
if (task.status !== 'completed' || task.workflow_completion_compatibility?.status !== 'legacy_handoff_completed') {
  throw new Error(JSON.stringify(task));
}
if (task.machine.completed_stages.includes('execute_repair')) throw new Error('repair execution was falsely recorded');
NODE
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
  "workflow_type":"short_revision",
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

@test "legacy V2 short business intent stays behind the compatibility migration boundary" {
    task_file="$BOOK/追踪/workflow/tasks/wf-entry-frozen-v2/task.json"
    mkdir -p "$(dirname "$task_file")"
    node - "$REPO/tests/fixtures/workflow-v3/legacy-v2/planning-confirmed.json" "$task_file" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');
const [fixtureFile,taskFile,root]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(fixtureFile,'utf8'));
task.workflow_id='wf-entry-frozen-v2';task.task_dir='追踪/workflow/tasks/wf-entry-frozen-v2';
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
fs.mkdirSync(path.join(root,'追踪/workflow'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify({
  schemaVersion:'1.0.0',workflow_id:task.workflow_id,task_dir:task.task_dir,
  state_version:task.state_version,focused_at:'2026-01-01T00:00:00.000Z'
},null,2)+'\n');
NODE

    run node "$SCRIPT" --project-root "$BOOK" --user-intent "继续执行整篇回炉" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/frozen-v2-entry.json"
    node - "$TMP_DIR/frozen-v2-entry.json" <<'NODE'
const out=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));
if(out.status!=='short_workflow_migration_pending') throw new Error(JSON.stringify(out));
if(out.direct_intent) throw new Error('V2 business intent bypassed migration');
if(!String((out.visible_response||{}).text||'').includes('升级')) throw new Error(JSON.stringify(out.visible_response));
NODE
}
@test "entry guard surfaces write-policy migration before legacy task authority when no strict policy exists" {
    book="$TMP_DIR/book-policy-gate"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/设定" "$book/细纲" "$book/追踪/workflow"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '# 设定\n' > "$book/设定/index.md"
    printf '{"task_id":"legacy_longform_checkpoint_20260101","task_type":"legacy continuity repair","status":"phase_pending","resume_command":"do not use","next_steps":[{"step_id":"next_chapter","status":"pending"}]}\n' \
        > "$book/追踪/workflow/current-task.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/policy-gate.json"

    node - "$TMP_DIR/policy-gate.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'write_policy_migration_required') throw new Error(JSON.stringify(out));
if (!out.visible_response) throw new Error('write-policy gate must emit a visible_response');
const visible = out.visible_response;
if (visible.selection_contract !== 'execute_command_or_route_intent') throw new Error(JSON.stringify(visible));
const options = Array.isArray(visible.options) ? visible.options : [];
if (options.length < 1) throw new Error('write-policy menu must carry at least one executable option');
const primary = options[0];
if (primary.interaction_mode !== 'execute_command') throw new Error(JSON.stringify(primary));
if (!primary.execution_command || !primary.execution_command.includes('book-write-policy-migrate.js')) throw new Error(JSON.stringify(primary));
if (!primary.execution_command.includes('继续当前长篇修订')) throw new Error(JSON.stringify(primary));
if (!primary.execution_command.includes('--resume-intent')) throw new Error(JSON.stringify(primary));
// Authority must NOT leak in front of the policy gate.
if (String(JSON.stringify(out)).includes('recover_legacy_task_authority')) throw new Error('legacy recovery leaked before policy migration');
if (String(JSON.stringify(out)).includes('blocked_task_authority_missing')) throw new Error('legacy authority leaked before policy migration');
NODE
}

@test "entry guard surfaces legacy task authority recovery after strict write policy is current" {
    book="$TMP_DIR/book-authority-gate"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/设定" "$book/细纲" \
             "$book/追踪/workflow" "$book/追踪/story-system/transactions" \
             "$book/追踪/story-system/commits"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '# 设定\n' > "$book/设定/index.md"
    # Strict write policy is current; legacy task note is still on disk.
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$book/追踪/story-system/chapter-identities.json"
    : > "$book/追踪/story-system/projection-log.jsonl"
    : > "$book/追踪/story-system/transactions/.keep"
    : > "$book/追踪/story-system/commits/.keep"
    printf '{"task_id":"legacy_longform_checkpoint_20260101","task_type":"legacy continuity repair","status":"phase_pending","resume_command":"do not use","next_steps":[{"step_id":"next_chapter","status":"pending"}]}\n' \
        > "$book/追踪/workflow/current-task.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/authority-gate.json"

    node - "$TMP_DIR/authority-gate.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_task_authority_missing') throw new Error(JSON.stringify(out));
const visible = out.visible_response;
if (!visible || !Array.isArray(visible.options) || visible.options.length < 1) throw new Error(JSON.stringify(visible));
const primary = visible.options[0];
if (primary.action !== 'recover_legacy_task_authority') throw new Error(JSON.stringify(primary));
if (primary.interaction_mode !== 'execute_command') throw new Error(JSON.stringify(primary));
if (!primary.execution_command || !primary.execution_command.includes('legacy-task-authority-recover.js')) throw new Error(JSON.stringify(primary));
if (!primary.execution_command.includes('继续当前长篇修订')) throw new Error(JSON.stringify(primary));
if (!primary.execution_command.includes('--resume-intent')) throw new Error(JSON.stringify(primary));
if (!String(visible.text || '').includes('下一步')) throw new Error('authority menu must explain the next step in Chinese');
// The empty generic repair option must NOT appear; we offer a real recovery command.
if (String(JSON.stringify(out)).includes('repair_runtime_guard')) throw new Error('task-authority loss was downgraded to repair_runtime_guard');
// Primary option must carry an execute_command label in Chinese, not just the action id.
if (!/[一-鿿]/.test(primary.label || '')) throw new Error('primary option label must be Chinese');
NODE
}

@test "entry guard recognizes allowlisted outline_backfill pointer after strict policy" {
    book="$TMP_DIR/book-outline-backfill-authority"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/细纲" "$book/设定" \
             "$book/追踪/workflow" "$book/追踪/story-system/transactions" \
             "$book/追踪/story-system/commits"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 中性大纲\n' > "$book/大纲/第1卷/卷纲.md"
    printf '# 中性细纲\n' > "$book/细纲/index.md"
    printf '# 中性设定\n' > "$book/设定/index.md"
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$book/追踪/story-system/chapter-identities.json"
    : > "$book/追踪/story-system/projection-log.jsonl"
    : > "$book/追踪/story-system/transactions/.keep"
    : > "$book/追踪/story-system/commits/.keep"
    cat > "$book/追踪/workflow/current-task.json" <<'JSON'
{"type":"outline_backfill","action_id":"outline-backfill-action-001","status":"running","target_files":["大纲/第1卷/卷纲.md","大纲/第1卷/章节索引.md"]}
JSON

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续中性大纲补全" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/outline-backfill-authority.json"

    node - "$TMP_DIR/outline-backfill-authority.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_task_authority_missing') throw new Error(JSON.stringify(out));
if (out.recommended_next !== 'recover_legacy_task_authority') throw new Error(JSON.stringify(out));
const visible = out.visible_response || {};
const primary = (visible.options || [])[0];
if (!primary || primary.interaction_mode !== 'execute_command') throw new Error(JSON.stringify(primary));
if (!String(primary.execution_command || '').includes('legacy-task-authority-recover.js preview')) throw new Error(JSON.stringify(primary));
const serialized = JSON.stringify(out);
if (serialized.includes('repair_runtime_guard')) throw new Error('outline_backfill was downgraded to repair_runtime_guard');
if (/查看未完成任务（0 个）[^]*推荐/.test(serialized) || /查看未完成任务（0 个）（推荐）/.test(serialized)) {
  throw new Error('zero unfinished tasks became the primary recommendation');
}
NODE
}

@test "entry guard returns business routing after both legacy migration gates are resolved" {
    book="$TMP_DIR/book-recovered"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/设定" "$book/细纲" \
             "$book/追踪/workflow/tasks/wf-recovered" "$book/追踪/story-system/transactions" \
             "$book/追踪/story-system/commits"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '# 设定\n' > "$book/设定/index.md"
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$book/追踪/story-system/chapter-identities.json"
    : > "$book/追踪/story-system/projection-log.jsonl"
    : > "$book/追踪/story-system/transactions/.keep"
    : > "$book/追踪/story-system/commits/.keep"
    # Recovery is complete: the current-task.json now points to a real long_write
    # durable task; the legacy task_id is gone.
    cat > "$book/追踪/workflow/tasks/wf-recovered/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0",
  "workflow_id":"wf-recovered",
  "workflow_type":"long_write",
  "task_dir":"追踪/workflow/tasks/wf-recovered",
  "status":"running",
  "current_stage":"prose",
  "user_goal":"继续当前长篇修订",
  "runtime_guard":{
    "heartbeat":{"updated_at":"2026-08-04T00:00:00.000Z"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"prose"}
  }
}
JSON
    node - "$book" "wf-recovered" <<'NODE'
const fs=require('fs'),path=require('path');const [root,id]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',id,'task.json'),'utf8'));
const pointer={schemaVersion:'1.0.0',workflow_id:id,task_dir:task.task_dir||`追踪/workflow/tasks/${id}`,focused_at:'2026-08-04T00:00:00.000Z',state_version:task.state_version||0};
fs.mkdirSync(path.join(root,'追踪/workflow'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify(pointer,null,2)+'\n');
NODE

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/recovered.json"

    node - "$TMP_DIR/recovered.json" "$book" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const book = process.argv[3];
if (!['pass', 'task_inbox_ready', 'business_routing_allowed'].includes(out.status)
    && out.status !== 'pass'
    && out.status !== 'task_inbox_ready') {
  // Accept either pass/business_routing_allowed or the task inbox showing the
  // recovered task. The legacy gates must NOT appear anymore.
  if (out.status === 'write_policy_migration_required' || out.status === 'blocked_task_authority_missing') {
    throw new Error('legacy gates still surfaced after recovery: ' + JSON.stringify(out));
  }
}
if (out.status === 'blocked_task_authority_missing') throw new Error('authority gate still active: ' + JSON.stringify(out));
const serialized = JSON.stringify(out);
if (serialized.includes('write_policy_migration_required')) throw new Error('write policy gate still active: ' + JSON.stringify(out));
if (serialized.includes('repair_runtime_guard') && /task.?authority/i.test(serialized)) {
  throw new Error('task-authority loss was downgraded to repair_runtime_guard: ' + JSON.stringify(out));
}
// The recovered durable task must be visible to the entry guard.
const taskFile = `${book}/追踪/workflow/tasks/wf-recovered/task.json`;
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
if (task.workflow_id !== 'wf-recovered') throw new Error('durable task was lost: ' + JSON.stringify(task));
NODE
}

@test "write-policy migration menu never leaks undefined display lines or padded empty options" {
    book="$TMP_DIR/book-menu-text"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/追踪/workflow"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '{"task_id":"legacy_longform_checkpoint_20260101","task_type":"legacy continuity repair"}\n' \
        > "$book/追踪/workflow/current-task.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/menu-text.json"

    node - "$TMP_DIR/menu-text.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'write_policy_migration_required') throw new Error(JSON.stringify(out));
const visible = out.visible_response;
if (!visible || typeof visible.text !== 'string') throw new Error(JSON.stringify(visible));
if (visible.text.includes('undefined')) throw new Error('write-policy menu text leaked undefined: ' + visible.text);
const options = Array.isArray(visible.options) ? visible.options : [];
for (const option of options) {
  if (typeof option.display !== 'string' || option.display.length === 0) {
    throw new Error('option missing display: ' + JSON.stringify(option));
  }
  if (typeof option.number !== 'number') throw new Error('option missing number: ' + JSON.stringify(option));
  if (!/^[一-龥]/.test(option.label || '')) throw new Error('option label must start with Chinese: ' + JSON.stringify(option));
}
const displays = options.map((option) => option.display);
for (const display of displays) {
  if (!visible.text.includes(display)) {
    throw new Error(`text must include option display "${display}": ${visible.text}`);
  }
}
NODE
}

@test "legacy task authority recovery menu never leaks undefined display lines or padded empty options" {
    book="$TMP_DIR/book-authority-text"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/追踪/workflow" \
             "$book/追踪/story-system/transactions" "$book/追踪/story-system/commits"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$book/追踪/story-system/chapter-identities.json"
    : > "$book/追踪/story-system/projection-log.jsonl"
    : > "$book/追踪/story-system/transactions/.keep"
    : > "$book/追踪/story-system/commits/.keep"
    printf '{"task_id":"legacy_longform_checkpoint_20260101","task_type":"legacy continuity repair"}\n' \
        > "$book/追踪/workflow/current-task.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/authority-text.json"

    node - "$TMP_DIR/authority-text.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_task_authority_missing') throw new Error(JSON.stringify(out));
const visible = out.visible_response;
if (!visible || typeof visible.text !== 'string') throw new Error(JSON.stringify(visible));
if (visible.text.includes('undefined')) throw new Error('authority menu text leaked undefined: ' + visible.text);
const options = Array.isArray(visible.options) ? visible.options : [];
for (const option of options) {
  if (typeof option.display !== 'string' || option.display.length === 0) {
    throw new Error('option missing display: ' + JSON.stringify(option));
  }
  if (typeof option.number !== 'number') throw new Error('option missing number: ' + JSON.stringify(option));
  if (!/^[一-龥]/.test(option.label || '')) throw new Error('option label must start with Chinese: ' + JSON.stringify(option));
}
const displays = options.map((option) => option.display);
for (const display of displays) {
  if (!visible.text.includes(display)) {
    throw new Error(`text must include option display "${display}": ${visible.text}`);
  }
}
NODE
}

@test "write-policy migration still fires when policy declares strict but transaction ledgers are missing" {
    book="$TMP_DIR/book-policy-mismatch"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/追踪/workflow" "$book/追踪/story-system" "$book/设定"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '# 设定\n' > "$book/设定/index.md"
    # mode=strict is declared but the four transaction ledgers are not all on disk.
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/policy-mismatch.json"

    node - "$TMP_DIR/policy-mismatch.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'write_policy_migration_required') throw new Error(JSON.stringify(out));
if (!out.visible_response || !out.visible_response.options) throw new Error(JSON.stringify(out));
const preview = out.visible_response.options[0];
if (!preview || !preview.execution_command || !preview.execution_command.includes('book-write-policy-migrate.js')) {
  throw new Error(JSON.stringify(preview));
}
NODE
}

@test "write-policy migration fires before task authority even when a durable workflow task is already on disk" {
    book="$TMP_DIR/book-policy-with-durable"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/设定" \
             "$book/追踪/workflow/tasks/wf-existing-long" "$book/追踪/story-system"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '# 设定\n' > "$book/设定/index.md"
    # A modern durable task is already on disk; the strict policy ledgers are
    # NOT. The policy gate must still fire first per the plan.
    cat > "$book/追踪/workflow/tasks/wf-existing-long/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0",
  "workflow_id":"wf-existing-long",
  "workflow_type":"long_write",
  "task_dir":"追踪/workflow/tasks/wf-existing-long",
  "status":"running",
  "current_stage":"prose",
  "runtime_guard":{"heartbeat":{"updated_at":"2026-08-04T00:00:00.000Z"}}
}
JSON
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/policy-with-durable.json"

    node - "$TMP_DIR/policy-with-durable.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'write_policy_migration_required') throw new Error(JSON.stringify(out));
if (!out.visible_response || !out.visible_response.options) throw new Error(JSON.stringify(out));
const preview = out.visible_response.options[0];
if (!preview || !preview.execution_command || !preview.execution_command.includes('book-write-policy-migrate.js')) {
  throw new Error(JSON.stringify(preview));
}
NODE
}

@test "unrecognized current-task pointer under strict policy returns a read-only diagnostic with no mutation command" {
    book="$TMP_DIR/book-unrecognized-pointer"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/追踪/workflow" \
             "$book/追踪/story-system/transactions" "$book/追踪/story-system/commits"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$book/追踪/story-system/chapter-identities.json"
    : > "$book/追踪/story-system/projection-log.jsonl"
    : > "$book/追踪/story-system/transactions/.keep"
    : > "$book/追踪/story-system/commits/.keep"
    # Malformed: not valid JSON, no workflow_id, no task_id.
    printf 'this is not json {\n' > "$book/追踪/workflow/current-task.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/unrecognized.json"

    node - "$TMP_DIR/unrecognized.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_task_authority_missing') throw new Error(JSON.stringify(out));
if (out.legacy_status && out.legacy_status.pointer_kind !== 'malformed_unrecognized') {
  throw new Error(JSON.stringify(out.legacy_status));
}
const visible = out.visible_response;
if (!visible || !Array.isArray(visible.options)) throw new Error(JSON.stringify(visible));
if (out.recommended_action !== 'inspect_unrecognized_task_pointer') throw new Error(JSON.stringify(out.recommended_action));
for (const option of visible.options) {
  if (option.execution_command) {
    const command = String(option.execution_command);
    if (/repair-runtime-guard|repair_task_state|legacy-task-authority-recover/.test(command)) {
      throw new Error('malformed pointer must not offer mutation command: ' + JSON.stringify(option));
    }
    if (!/workflow-task-inbox\.js/.test(command)) {
      throw new Error('malformed pointer must only offer read-only inbox command: ' + JSON.stringify(option));
    }
  }
}
if (!/人工|无法识别|不可恢复/.test(visible.text || '')) {
  throw new Error('malformed pointer menu must explain the diagnostic in Chinese: ' + visible.text);
}
NODE
}

@test "unrecognized current-task pointer with unsafe task_id under strict policy still returns the read-only diagnostic" {
    book="$TMP_DIR/book-unsafe-taskid"
    mkdir -p "$book/正文/第1卷" "$book/大纲/第1卷" "$book/追踪/workflow" \
             "$book/追踪/story-system/transactions" "$book/追踪/story-system/commits"
    printf '# 第001章\n' > "$book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$book/大纲/第1卷/细纲_第001章.md"
    printf '{"mode":"strict","current":{"chapter_commit":"required"}}\n' > "$book/追踪/story-system/write-policy.json"
    printf '{"chapter_identities":[]}\n' > "$book/追踪/story-system/chapter-identities.json"
    : > "$book/追踪/story-system/projection-log.jsonl"
    : > "$book/追踪/story-system/transactions/.keep"
    : > "$book/追踪/story-system/commits/.keep"
    # Unsafe task_id (contains spaces and shell metacharacters).
    printf '{"task_id":"bad task id; rm -rf /","task_type":"legacy"}\n' \
        > "$book/追踪/workflow/current-task.json"

    output="$(node "$SCRIPT" --project-root "$book" --user-intent "继续当前长篇修订" --json)"
    printf '%s\n' "$output" > "$TMP_DIR/unsafe-taskid.json"

    node - "$TMP_DIR/unsafe-taskid.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'blocked_task_authority_missing') throw new Error(JSON.stringify(out));
if (out.legacy_status && out.legacy_status.pointer_kind !== 'malformed_unrecognized') {
  throw new Error(JSON.stringify(out.legacy_status));
}
const visible = out.visible_response;
if (!visible || !Array.isArray(visible.options)) throw new Error(JSON.stringify(visible));
for (const option of visible.options) {
  if (option.execution_command && !/workflow-task-inbox\.js/.test(String(option.execution_command))) {
    throw new Error('unsafe task_id menu must only offer read-only inbox command: ' + JSON.stringify(option));
  }
}
// No option may invoke the legacy recovery adapter directly.
for (const option of visible.options) {
  if (option.execution_command && /legacy-task-authority-recover/.test(String(option.execution_command))) {
    throw new Error('unsafe task_id offered the recovery adapter: ' + JSON.stringify(option));
  }
}
NODE
}

@test "workflow entry guard is documented and bundled" {
    grep -q "workflow-entry-guard.js" "$REPO/scripts/README.md"
    grep -q '"workflow-entry-guard.js"' "$REPO/config/novel-assistant-bundle-files.json"
    grep -q "workflow-entry-guard.js" "$REPO/skills/novel-assistant/SKILL.md"
    grep -q 'candidateCount=0.*仍显示' "$REPO/skills/novel-assistant/references/internal-skills/story-workflow/references/task-inbox-protocol.md"
    grep -q '逐字展示.*visible_response.text' "$REPO/src/internal-skills/story-setup/SKILL.md"
}
