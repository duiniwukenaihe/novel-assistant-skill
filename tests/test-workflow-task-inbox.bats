#!/usr/bin/env bats
# tests/test-workflow-task-inbox.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/workflow-task-inbox.js"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    ENTRY="$REPO/skills/novel-assistant/SKILL.md"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    BUNDLE="$REPO/skills/novel-assistant"
    TASK_INBOX_PROTOCOL="$REPO/src/internal-skills/story-workflow/references/task-inbox-protocol.md"
    ENTRY_RUNTIME="$BUNDLE/references/entry-runtime-contract.md"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_focused_task() {
    workflow_id="$1"
    task_dir="追踪/workflow/tasks/$workflow_id"
    mkdir -p "$TMP_DIR/book/$task_dir"
    cat > "$TMP_DIR/book/$task_dir/task.json"
    node - "$TMP_DIR/book/$task_dir/task.json" "$TMP_DIR/book/追踪/workflow/current-task.json" "$workflow_id" "$task_dir" <<'NODE'
const fs = require('fs');
const [taskFile, pointerFile, workflowId, taskDir] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.schemaVersion ||= '1.0.0';
task.state_version ||= 1;
task.workflow_id = workflowId;
task.task_dir = taskDir;
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
fs.writeFileSync(pointerFile, `${JSON.stringify({
  schemaVersion: '1.0.0',
  workflow_id: workflowId,
  task_dir: taskDir,
  focused_at: '2026-07-12T00:00:00.000Z',
  state_version: task.state_version,
}, null, 2)}\n`);
NODE
}

@test "workflow task inbox reports missing durable authority for an existing focus pointer" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-missing","task_dir":"追踪/workflow/tasks/wf-missing","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_task_authority_missing') throw new Error(JSON.stringify(out));
NODE
}

@test "workflow task inbox reports no resumable tasks without reading chapters" {
    mkdir -p "$TMP_DIR/book"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"status": "empty"' "$TMP_DIR/out.json"
    grep -q '"startup_health_check": true' "$TMP_DIR/out.json"
    grep -q '"candidateCount": 0' "$TMP_DIR/out.json"
    grep -q '"readPolicy": "metadata_only"' "$TMP_DIR/out.json"
}

@test "workflow task inbox accepts legacy show_inbox action as a no-op" {
    mkdir -p "$TMP_DIR/book"

    run node "$SCRIPT" --project-root "$TMP_DIR/book" --json --action show_inbox

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status": "empty"'
    echo "$output" | grep -q '"readPolicy": "metadata_only"'
}

@test "workflow task inbox exposes compact deterministic actions for the startup menu" {
    mkdir -p "$TMP_DIR/book"

    run node "$SCRIPT" --project-root "$TMP_DIR/book" --json --action show_unfinished_tasks
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "show_unfinished_tasks"'* ]]
    [[ "$output" == *'"task_cards": []'* ]]
    [[ "$output" != *'"migration_inventory"'* ]]
    [[ "$output" != *'"workflow_groups"'* ]]

    run node "$SCRIPT" --project-root "$TMP_DIR/book" --json --action show_smart_recommendations
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "show_smart_recommendations"'* ]]

    run node "$SCRIPT" --project-root "$TMP_DIR/book" --json --action show_new_goal_options
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "show_new_goal_options"'* ]]
    [[ "$output" == *'"new_goal_options"'* ]]
}

@test "workflow task inbox ignores an empty legacy review ledger" {
    mkdir -p "$TMP_DIR/book/追踪"
    cat > "$TMP_DIR/book/追踪/review-state.json" <<'JSON'
{"version":1,"updated_at":"2026-07-10T11:50:23.363Z","reviews":[]}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"candidateCount": 0' "$TMP_DIR/out.json"
    ! grep -q '"id": "review-state"' "$TMP_DIR/out.json"
}

@test "workflow task inbox does not promote private domain cards into a second global task" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension/cards"
    cat > "$TMP_DIR/book/追踪/private-short-extension/cards/info-source-cards.jsonl" <<'JSONL'
{"info_id":"info_a","title":"保留素材","pool_status":"retained"}
{"info_id":"info_b","title":"本轮新增","pool_status":"new"}
{"info_id":"info_c","title":"已丢弃素材","pool_status":"discarded"}
JSONL

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"candidateCount": 0' "$TMP_DIR/out.json"
    ! grep -q '"id": "short-info-pool"' "$TMP_DIR/out.json"
    ! grep -q '"action": "resume_short_info_pool"' "$TMP_DIR/out.json"
}

@test "new short goal creates the complete short_write lifecycle" {
    mkdir -p "$TMP_DIR/book"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"label": "新开短篇"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "short_write"' "$TMP_DIR/out.json"
    grep -q '"action": "create_workflow:short_write"' "$TMP_DIR/out.json"
    ! grep -q '"action": "create_workflow:short_startup"' "$TMP_DIR/out.json"
}

@test "short task inbox uses the bound project identity instead of a generic new-short label" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/book/追踪/private-short-extension"
    write_focused_task "wf-fruit-short" <<'JSON'
{
  "schemaVersion":"1.0.0",
  "state_version":1,
  "workflow_id":"wf-fruit-short",
  "workflow_type":"private_short_startup",
  "status":"running",
  "task_dir":"追踪/workflow/tasks/wf-fruit-short",
  "user_goal":"新开短篇",
  "current_stage":"platform_genre_lock",
  "lifecycle":{"status":"active","user_goal":"新开短篇"},
  "machine":{"next_stop_reason":"requires_user_confirm"},
  "runtime_guard":{
    "heartbeat":{"updated_at":"2026-07-18T00:00:00.000Z"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"platform_genre_lock"}
  }
}
JSON
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{
  "schema_version":"1.0.0",
  "project_id":"short-fruit-001",
  "workflow_id":"wf-fruit-short",
  "status":"design_draft_pending_confirmation",
  "current_stage":"platform_genre_lock",
  "selected_material":{"card_id":"hot_nfc_001","label":"NFC果汁事件"},
  "working_title":"我在集团溯源直播里发现车间没有水果",
  "platform":"番茄短篇"
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.candidateCount!==1 || out.task_cards.length!==1) throw new Error(JSON.stringify(out));
const card=out.task_cards[0];
if(card.title!=='我在集团溯源直播里发现车间没有水果') throw new Error(JSON.stringify(card));
if(card.project_id!=='short-fruit-001') throw new Error(JSON.stringify(card));
if(card.selected_material_label!=='NFC果汁事件') throw new Error(JSON.stringify(card));
if(card.visible_stage!=='锁定平台与题材方法') throw new Error(JSON.stringify(card));
if(out.workflow_groups.length!==1 || out.workflow_groups[0].workflow_type!=='short_write') throw new Error(JSON.stringify(out.workflow_groups));
if(out.workflow_groups[0].label!=='短篇创作') throw new Error(JSON.stringify(out.workflow_groups[0]));
if(out.longform_lifecycle_status!==null) throw new Error('short project must not expose longform lifecycle status');
if(out.smart_new_task_recommendations.some(item=>item.action==='longform_lifecycle_next')) throw new Error(JSON.stringify(out.smart_new_task_recommendations));
if(out.smart_new_task_recommendations.some(item=>/没有检测到活跃写作任务/.test(item.reason||''))) throw new Error(JSON.stringify(out.smart_new_task_recommendations));
if(JSON.stringify(out).includes('外卖站')) throw new Error('stale short setting leaked into visible task card');
NODE
}

@test "workflow task inbox ignores superseded durable tasks" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/old-review"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/old-review/task.json" <<'JSON'
{
  "workflow_id":"old-review",
  "workflow_type":"review_repair",
  "status":"paused",
  "current_stage":"evidence_scan",
  "lifecycle":{"status":"superseded","superseded_by":"new-review"}
}

JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"candidateCount": 0' "$TMP_DIR/out.json"
    ! grep -q '"id": "old-review"' "$TMP_DIR/out.json"
}

@test "workflow task inbox translates repair execution planning for authors" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-repair-plan"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-repair-plan/task.json" <<'JSON'
{
  "workflow_id":"wf-repair-plan","workflow_type":"review_repair","status":"running",
  "task_dir":"追踪/workflow/tasks/wf-repair-plan","user_goal":"审阅 1-200 章","scope":"1-200",
  "current_stage":"repair_execution_plan","current_step":"repair_execution_plan",
  "lifecycle":{"status":"active"}
}

JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"visible_stage": "生成受控修复方案"' "$TMP_DIR/out.json"
    ! grep -q 'repair execution plan' "$TMP_DIR/out.json"
}

@test "workflow task inbox translates stale stored next-action labels" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-stale-label"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-stale-label/task.json" <<'JSON'
{
  "workflow_id":"wf-stale-label","workflow_type":"review_repair","status":"paused",
  "task_dir":"追踪/workflow/tasks/wf-stale-label","current_stage":"evidence_scan",
  "lifecycle":{"status":"paused"},"state_version":1,
  "pending_action":{"id":"pa-old","visible_choice_hash":"hash","options":[{"number":1,"label":"继续 evidence_scan","action_id":"continue_next_stage","target_stage":"evidence_scan"}]}
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"label": "继续扫描证据"' "$TMP_DIR/out.json"
    ! grep -q '继续 evidence_scan' "$TMP_DIR/out.json"
}

@test "workflow task inbox shows repair actions instead of resume when focused task violates state invariants" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-bad-state"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-bad-state","task_dir":"追踪/workflow/tasks/wf-bad-state","focused_at":"2026-07-18T00:00:00.000Z","state_version":7}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-bad-state/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0",
  "state_version":7,
  "workflow_id":"wf-bad-state",
  "workflow_type":"short_write",
  "status":"running",
  "task_dir":"追踪/workflow/tasks/wf-bad-state",
  "user_goal":"继续写第 6 节",
  "scope":"第6节",
  "current_stage":"section_machine_gate",
  "current_step":"section_machine_gate",
  "machine":{"completed_stages":["section_machine_gate"],"remaining_stages":["section_repair_loop"]},
  "stage_execution":{"status":"running","stage_id":"draft_next_section","expected_result_packet":"追踪/workflow/tasks/wf-bad-state/result-packets/draft_next_section.result.json"},
  "runtime_guard":{
    "heartbeat":{"updated_at":"2026-07-18T00:00:00.000Z","latest_trusted_artifact":"追踪/workflow/tasks/wf-bad-state/result-packets/draft_next_section.result.json"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"current_stage"}
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/bad-state.json"

    node - "$TMP_DIR/bad-state.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_state_invariant') throw new Error(JSON.stringify(out));
if(out.candidateCount!==1 || out.task_cards.length!==1) throw new Error(JSON.stringify(out));
const card=out.task_cards[0];
if(card.status!=='blocked_state_invariant') throw new Error(JSON.stringify(card));
if(card.title!=='当前任务状态不一致，需先修复') throw new Error(JSON.stringify(card));
if(card.next_actions[0].action_id!=='repair_task_state') throw new Error(JSON.stringify(card));
if(JSON.stringify(out).includes('从断点继续')) throw new Error(JSON.stringify(out));
NODE
}

@test "workflow task inbox blocks stale short section result packet instead of showing resume" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-stale-packet/result-packets" "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-stale-packet","task_dir":"追踪/workflow/tasks/wf-stale-packet","focused_at":"2026-07-18T00:00:00.000Z","state_version":9}
JSON
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{
  "schema_version":"1.0.0",
  "project_id":"short-nfc-fruit",
  "workflow_id":"wf-stale-packet",
  "working_title":"我替家里直播鲜榨工厂，镜头里却一颗水果都没有",
  "selected_material":{"card_id":"hot_nfc","label":"大型果汁集团溯源直播事件"},
  "status":"section_006_quality_gate"
}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-stale-packet/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0",
  "state_version":9,
  "result_contract_version":2,
  "workflow_id":"wf-stale-packet",
  "workflow_type":"short_write",
  "status":"running",
  "task_dir":"追踪/workflow/tasks/wf-stale-packet",
  "user_goal":"继续短篇",
  "scope":"第6节",
  "current_stage":"quality_gate",
  "current_step":"quality_gate",
  "machine":{"completed_stages":["section_machine_gate"],"remaining_stages":["quality_gate","section_accept_anchor"]},
  "unit_lifecycle":{"unit_type":"section","status":"active","current_scope":"第6节","current_stage":"quality_gate"},
  "stage_execution":{"status":"running","stage_id":"quality_gate","step_id":"quality_gate","expected_result_packet":"追踪/workflow/tasks/wf-stale-packet/result-packets/quality_gate.result.json"},
  "runtime_guard":{
    "heartbeat":{"updated_at":"2026-07-18T00:00:00.000Z","latest_trusted_artifact":"追踪/workflow/tasks/wf-stale-packet/result-packets/section_machine_gate.result.json"},
    "stall_policy":{"heartbeat_timeout_minutes":999999},
    "checkpoint_policy":{"resume_from":"quality_gate","expected_result_packet":"追踪/workflow/tasks/wf-stale-packet/result-packets/quality_gate.result.json"}
  }
}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-stale-packet/result-packets/quality_gate.result.json" <<'JSON'
{
  "workflow_id":"wf-stale-packet",
  "workflow_type":"short_write",
  "stage_id":"quality_gate",
  "step_id":"quality_gate",
  "step_status":"completed",
  "outputs":[],
  "changed_files":[],
  "evidence":[],
  "verification_result":"pass",
  "checkpoint_state":{},
  "output_health_result":"pass",
  "current_section_index":5
}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-stale-packet/result-packets/section_machine_gate.result.json" <<'JSON'
{"workflow_id":"wf-stale-packet","workflow_type":"short_write","stage_id":"section_machine_gate","step_status":"completed","current_section_index":6}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/stale-packet.json"

    node - "$TMP_DIR/stale-packet.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_stale_result_packet_scope') throw new Error(JSON.stringify(out));
if(out.candidateCount!==1 || out.task_cards.length!==1) throw new Error(JSON.stringify(out));
const card=out.task_cards[0];
if(card.status!=='blocked_stale_result_packet_scope') throw new Error(JSON.stringify(card));
if(card.next_actions[0].action_id!=='regenerate_current_result_packet') throw new Error(JSON.stringify(card));
if(JSON.stringify(out).includes('继续检查故事质量')) throw new Error(JSON.stringify(out));
if(!JSON.stringify(out).includes('上一小节同名 result packet')) throw new Error(JSON.stringify(out));
if(!JSON.stringify(out).includes('当前作品：我替家里直播鲜榨工厂，镜头里却一颗水果都没有')) throw new Error(JSON.stringify(out));
if(!JSON.stringify(out).includes('已选素材：大型果汁集团溯源直播事件')) throw new Error(JSON.stringify(out));
if(card.working_title!=='我替家里直播鲜榨工厂，镜头里却一颗水果都没有') throw new Error(JSON.stringify(card));
NODE
}

@test "workflow task inbox shows one upstream oh-story migration card without writing state" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-legacy-review"
    cat > "$TMP_DIR/book/.story-deployed" <<'JSON'
{"source_repository":"worldwonderer/oh-story-claudecode"}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-legacy-review/task.json" <<'JSON'
{
  "workflow_id": "wf-legacy-review",
  "workflow_type": "review_repair",
  "status": "running",
  "task_dir": "追踪/workflow/tasks/wf-legacy-review",
  "user_goal": "审阅 1-200 章",
  "scope": "1-200",
  "current_stage": "evidence_scan",
  "risk_level": "medium",
  "review_batches": {"batch_size": 50, "agent_count": 4, "agents": ["plot", "character", "canon", "prose"]}
}
JSON
    mkdir -p "$TMP_DIR/book/正文"
    printf '# 来源结构\n' > "$TMP_DIR/book/正文/README.md"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"workflow_id":"wf-legacy-review","task_dir":"追踪/workflow/tasks/wf-legacy-review"}
JSON

    before="$(shasum -a 256 "$TMP_DIR/book/追踪/workflow/current-task.json" "$TMP_DIR/book/追踪/workflow/tasks/wf-legacy-review/task.json")"
    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"candidateCount": 1' "$TMP_DIR/out.json"
    grep -q '"migration_task_count": 1' "$TMP_DIR/out.json"
    grep -q '"id": "wf-legacy-review"' "$TMP_DIR/out.json"
    grep -q '"migration_source": "worldwonderer/oh-story-claudecode"' "$TMP_DIR/out.json"
    grep -q '"requires_user_confirm": true' "$TMP_DIR/out.json"
    [ "$before" = "$(shasum -a 256 "$TMP_DIR/book/追踪/workflow/current-task.json" "$TMP_DIR/book/追踪/workflow/tasks/wf-legacy-review/task.json")" ]
}

@test "workflow task inbox rejects unsafe task paths but preserves high-risk unsupported tasks" {
    mkdir -p "$TMP_DIR/book/追踪/workflow" "$TMP_DIR/unsafe"
    cat > "$TMP_DIR/unsafe/task.json" <<'JSON'
{
  "workflow_id": "wf-legacy-review",
  "workflow_type": "review_repair",
  "status": "running",
  "task_dir": "../unsafe",
  "scope": "201-400",
  "current_stage": "execute_repair",
  "risk_level": "high",
  "review_batches": {"batch_size": 50, "agent_count": 4, "agents": ["plot", "character", "canon", "prose"]}
}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-legacy-review","task_dir":"../unsafe","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/blocked.json"

    grep -q '"candidateCount": 0' "$TMP_DIR/blocked.json"
    ! grep -q '"classification"' "$TMP_DIR/blocked.json"

    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-legacy-review"
    node - "$TMP_DIR/book/追踪/workflow/current-task.json" "$TMP_DIR/unsafe/task.json" "$TMP_DIR/book/追踪/workflow/tasks/wf-legacy-review/task.json" <<'NODE'
const fs=require('fs');
const [file, unsafeTaskFile, safeTaskFile]=process.argv.slice(2);
const task=JSON.parse(fs.readFileSync(unsafeTaskFile,'utf8'));
task.task_dir='追踪/workflow/tasks/wf-legacy-review';
fs.writeFileSync(safeTaskFile,JSON.stringify(task,null,2)+'\n');
const pointer=JSON.parse(fs.readFileSync(file,'utf8'));
pointer.task_dir='追踪/workflow/tasks/wf-legacy-review';
fs.writeFileSync(file,JSON.stringify(pointer,null,2)+'\n');
NODE
    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/confirm.json"
    grep -q '"candidateCount": 1' "$TMP_DIR/confirm.json"
}

@test "workflow task inbox preserves active fixed-batch tasks when no supported migration card exists" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-current" "$TMP_DIR/book/追踪/workflow/tasks/wf-durable-legacy"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-current","task_dir":"追踪/workflow/tasks/wf-current","focused_at":"2026-07-12T00:00:00.000Z","state_version":1}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-current/task.json" <<'JSON'
{"schemaVersion":"1.0.0","state_version":1,"workflow_id":"wf-current","task_dir":"追踪/workflow/tasks/wf-current","workflow_type":"long_write","status":"running","current_stage":"outline","runtime_guard":{"heartbeat":{"updated_at":"2026-07-18T00:00:00.000Z"},"stall_policy":{"heartbeat_timeout_minutes":999999},"checkpoint_policy":{"resume_from":"outline"}}}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-durable-legacy/task.json" <<'JSON'
{
  "workflow_id":"wf-durable-legacy","workflow_type":"review_repair","status":"running",
  "task_dir":"追踪/workflow/tasks/wf-durable-legacy","scope":"1-8","current_stage":"evidence_scan",
  "review_batches":{"batch_size":50,"agent_count":4,"agents":["plot","character","canon","prose"]}
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/non-current-legacy.json"
    node - "$TMP_DIR/non-current-legacy.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if (!out.candidates.some(candidate=>candidate.id==='wf-durable-legacy')) throw new Error(JSON.stringify(out.candidates));
if (out.candidateCount!==2) throw new Error(JSON.stringify(out.candidates));
if (out.migration_inventory.items.length!==0) throw new Error(JSON.stringify(out.migration_inventory));
NODE
}

@test "workflow task inbox keeps current 1-200 review resumable after runtime refresh" {
    mkdir -p "$TMP_DIR/book"
    printf 'novel_assistant_bundle_id: current\nmigration_status: not_requested\n' > "$TMP_DIR/book/.story-deployed"
    write_focused_task wf-review-1-200 <<'JSON'
{
  "workflow_id":"wf-review-1-200","workflow_type":"review_repair","status":"running",
  "task_dir":"追踪/workflow/tasks/wf-review-1-200","scope":"1-200章 范围审阅","current_stage":"evidence_scan",
  "review_batches":{"batch_size":50,"completed_count":1,"total_count":4,"next_batch_id":"002","batches":[
    {"id":"001","range":"1-50","status":"done"},{"id":"002","range":"51-100","status":"pending"},
    {"id":"003","range":"101-150","status":"pending"},{"id":"004","range":"151-200","status":"pending"}
  ]}
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/current-review.json"

    node - "$TMP_DIR/current-review.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.candidates.find(item=>item.id==='wf-review-1-200');
if(!task) throw new Error(JSON.stringify(out));
if(task.scope_label!=='1-200章 范围审阅') throw new Error(JSON.stringify(task));
if(out.migration_task_count!==0) throw new Error(JSON.stringify(out.migration_inventory));
NODE
}

@test "workflow task inbox asks to reaccept from the first incompatible completed review batch" {
    task_dir="$TMP_DIR/book/追踪/workflow/tasks/wf-review-protocol"
    packet_dir="$task_dir/result-packets"
    mkdir -p "$packet_dir"
    cat > "$task_dir/task.json" <<'JSON'
{
  "workflow_id":"wf-review-protocol","workflow_type":"review_repair","status":"done",
  "task_dir":"追踪/workflow/tasks/wf-review-protocol","scope":"1-200","current_stage":"closure",
  "review_batches":{"completed_count":4,"total_count":4,"next_batch_id":"","aggregate_status":"completed","batches":[
    {"id":"001","range":"1-50","status":"completed","accepted_result_packet":"追踪/workflow/tasks/wf-review-protocol/result-packets/evidence_scan.batch-001.result.json"},
    {"id":"002","range":"51-100","status":"done","accepted_result_packet":"追踪/workflow/tasks/wf-review-protocol/result-packets/evidence_scan.batch-002.result.json"},
    {"id":"003","range":"101-150","status":"completed","accepted_result_packet":"追踪/workflow/tasks/wf-review-protocol/result-packets/evidence_scan.batch-003.result.json"},
    {"id":"004","range":"151-200","status":"done","accepted_result_packet":"追踪/workflow/tasks/wf-review-protocol/result-packets/evidence_scan.batch-004.result.json"}
  ]}
}
JSON
    for spec in "001 1 50" "002 51 100"; do
      set -- $spec
      cat > "$packet_dir/evidence_scan.batch-$1.result.json" <<JSON
{"protocolVersion":"2.0.0","sourceDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fullRangeCoverage":{"start":$2,"end":$3,"coveredChapters":50,"complete":true}}
JSON
    done
    printf '%s\n' '{"step_status":"completed"}' > "$packet_dir/evidence_scan.batch-003.result.json"
    printf '%s\n' '{"step_status":"completed"}' > "$packet_dir/evidence_scan.batch-004.result.json"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/protocol-inbox.json"

    node - "$TMP_DIR/protocol-inbox.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const task=out.candidates.find(item=>item.id==='wf-review-protocol');
if(!task) throw new Error(JSON.stringify(out));
if(task.label!=='旧批次证据不符合当前验收协议（从 101-150 开始）') throw new Error(JSON.stringify(task));
if(task.status!=='reacceptance_required') throw new Error(JSON.stringify(task));
if(task.next_actions.length!==4) throw new Error(JSON.stringify(task));
if(task.next_actions[0].action_id!=='reset_incompatible_review_batches') throw new Error(JSON.stringify(task));
if(task.next_actions[1].action_id!=='continue_review_with_legacy_evidence') throw new Error(JSON.stringify(task));
if(task.next_actions[2].action_id!=='inspect_legacy_review_evidence') throw new Error(JSON.stringify(task));
if(task.next_actions[3].action_id!=='pause') throw new Error(JSON.stringify(task));
if(!String(task.next_actions[1].execution_command||'').includes('continue-review-with-legacy-evidence')) throw new Error(JSON.stringify(task));
if(!String(task.execution_command||'').includes('reset-incompatible-review-batches')||!String(task.execution_command).includes('--confirm')) throw new Error(JSON.stringify(task));
NODE
}

@test "workflow task inbox gives previous novel-assistant projects a distinct upgrade card" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-previous-na"
    cat > "$TMP_DIR/book/.story-deployed" <<'JSON'
{"novel_assistant_bundle_id":"novel-assistant-2026.06"}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-previous-na/task.json" <<'JSON'
{
  "workflow_id":"wf-previous-na","workflow_type":"review_repair","status":"running",
  "task_dir":"追踪/workflow/tasks/wf-previous-na","scope":"1-8","current_stage":"evidence_scan",
  "review_batches":{"batch_size":50,"agent_count":4,"agents":["plot","character","canon","prose"]}
}
JSON
    mkdir -p "$TMP_DIR/book/正文"
    printf '# 来源结构\n' > "$TMP_DIR/book/正文/README.md"
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"workflow_id":"wf-previous-na","task_dir":"追踪/workflow/tasks/wf-previous-na"}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/previous-na.json"
    grep -q '"candidateCount": 1' "$TMP_DIR/previous-na.json"
    grep -q '"migration_source": "novel-assistant/previous-version"' "$TMP_DIR/previous-na.json"
    grep -q '升级旧版 novel-assistant 审阅任务' "$TMP_DIR/previous-na.json"
}

@test "workflow task inbox ignores legacy short review and analyze state files" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    mkdir -p "$TMP_DIR/book/追踪"
    mkdir -p "$TMP_DIR/book/拆文库/盘龙"
    mkdir -p "$TMP_DIR/book/downloads/_reports"

    write_focused_task wf-long-001 <<'JSON'
{
  "workflow_id": "wf-long-001",
  "workflow_type": "long_daily_write",
  "status": "paused_after_batch",
  "current_stage": "正文生产",
  "current_step": "第12卷第003章",
  "resume_hint": "/novel-assistant 继续写当前章节",
  "next_candidates": [
    {"number": 1, "label": "继续当前章节", "action": "continue_current_chapter"}
  ],
  "runtime_guard": {
    "heartbeat": {"latest_trusted_artifact": "追踪/workflow/current-task.md", "updated_at": "2026-07-03T09:00:00+08:00"},
    "stall_policy": {"heartbeat_timeout_minutes": 20},
    "checkpoint_policy": {"resume_from": "chapter"}
  }
}
JSON

    cat > "$TMP_DIR/book/追踪/private-short-extension/current-task.json" <<'JSON'
{
  "task_id": "short-001",
  "title": "继续短篇素材卡",
  "status": "in_progress",
  "current_step": "素材卡复审",
  "resume_hint": "/novel-assistant 继续短篇"
}
JSON

    cat > "$TMP_DIR/book/追踪/review-state.json" <<'JSON'
{
  "status": "paused_after_scan",
  "scope": "201-400",
  "resume_hint": "/novel-assistant 继续审阅 201-400",
  "last_report": "追踪/审查报告/批次_201-300.md"
}
JSON

    cat > "$TMP_DIR/book/拆文库/盘龙/_progress.md" <<'EOF'
# 拆文进度

status: running
stage: Stage 2
next: 第121章
resume: /novel-assistant 继续拆《盘龙》
EOF

    cat > "$TMP_DIR/book/downloads/_reports/update-state.json" <<'JSON'
{
  "status": "needs_update",
  "title": "示例连载",
  "resume_hint": "/novel-assistant 续更示例连载"
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"status": "has_tasks"' "$TMP_DIR/out.json"
    grep -q '"candidateCount": 2' "$TMP_DIR/out.json"
    grep -q '"workflow_groups"' "$TMP_DIR/out.json"
    grep -q '"groupCount": 2' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "long_write"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "download_import"' "$TMP_DIR/out.json"
    grep -q '"default_visible_menu"' "$TMP_DIR/out.json"
    grep -q '"smart_new_task_recommendations"' "$TMP_DIR/out.json"
    grep -q '"smartRecommendationCount"' "$TMP_DIR/out.json"
    grep -q '1. 长篇写作（1 个未完成）' "$TMP_DIR/out.json"
    grep -q '2. 下载导入与续更（1 个未完成）' "$TMP_DIR/out.json"
    for type in long_daily_write download_update; do
        grep -q "\"workflow_type\": \"$type\"" "$TMP_DIR/out.json"
    done
    grep -q '"flat_visible_menu"' "$TMP_DIR/out.json"
    grep -q '1. 继续当前章节' "$TMP_DIR/out.json"
    grep -q '2. 续更示例连载' "$TMP_DIR/out.json"
    ! grep -q '继续短篇素材卡' "$TMP_DIR/out.json"
    ! grep -q '继续审阅 201-400' "$TMP_DIR/out.json"
    ! grep -q '继续拆《盘龙》' "$TMP_DIR/out.json"
}

@test "workflow task inbox derives smart new task recommendations from project metadata" {
    mkdir -p "$TMP_DIR/book/正文/第1卷" "$TMP_DIR/book/大纲/第1卷" "$TMP_DIR/book/追踪/审查报告" "$TMP_DIR/book/拆文库/样本书"
    printf '# 第001章\n' > "$TMP_DIR/book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$TMP_DIR/book/大纲/第1卷/细纲_第001章.md"
    printf '# 伏笔\n' > "$TMP_DIR/book/追踪/伏笔.md"
    printf '# 审查\n' > "$TMP_DIR/book/追踪/审查报告/报告.md"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"smart_new_task_recommendations"' "$TMP_DIR/out.json"
    grep -q '审阅并确认阶段细纲' "$TMP_DIR/out.json"
    ! grep -q '继续写作或生成下一章 Brief' "$TMP_DIR/out.json"
    grep -q '审阅当前正文范围' "$TMP_DIR/out.json"
    grep -q '检查伏笔与钩子回收' "$TMP_DIR/out.json"
    grep -q '复查历史审查报告未闭环项' "$TMP_DIR/out.json"
    grep -q '整理拆文库并生成可吸收技巧卡' "$TMP_DIR/out.json"
}

@test "completed short workflow recommends an executable short review instead of a terminal notice" {
    mkdir -p "$TMP_DIR/book/正文" "$TMP_DIR/book/大纲" \
        "$TMP_DIR/book/追踪/private-short-extension" \
        "$TMP_DIR/book/追踪/workflow/tasks/wf-short-completed"
    printf '# 第001节\n' > "$TMP_DIR/book/正文/第001节.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/大纲/小节大纲.md"
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{"workflow_type":"short_write","project_id":"short-001","selected_material":{"title":"测试短篇"},"status":"completed"}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-short-completed","task_dir":"追踪/workflow/tasks/wf-short-completed","state_version":9}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-completed/task.json" <<'JSON'
{
  "schemaVersion":"1.0.0","workflow_id":"wf-short-completed","workflow_type":"short_write",
  "workflow_profile":"private","workflow_owner":"private-short-extension","status":"completed",
  "current_stage":"final_check","current_step":"final_check","scope":"全篇","state_version":9,
  "book_root":".","task_dir":"追踪/workflow/tasks/wf-short-completed",
  "recommended_next":[{"number":1,"action_id":"start_new_workflow","label":"工作流完成；可发布。"}]
}

JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --action show_smart_recommendations --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.selection_contract !== 'execute_recommendation_command_or_route_intent') throw new Error(JSON.stringify(out));
if (out.smart_new_task_recommendations.some(item => /工作流完成|可发布/.test(item.label))) throw new Error(JSON.stringify(out.smart_new_task_recommendations));
const review = out.smart_new_task_recommendations.find(item => item.action === 'start_short_review');
if (!review || review.number !== 1 || review.interaction_mode !== 'execute_command') throw new Error(JSON.stringify(review));
if (!review.recommended || !/--workflow-type short_review/.test(review.execution_command || '')) throw new Error(JSON.stringify(review));
if (!/--project-root/.test(review.execution_command || '') || !/--scope/.test(review.execution_command || '')) throw new Error(JSON.stringify(review));
NODE

    node "$SCRIPT" --project-root "$TMP_DIR/book" --action show_smart_recommendations --selection 1 --json > "$TMP_DIR/selected.json"
    node - "$TMP_DIR/selected.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'selection_ready' || out.selected.action !== 'start_short_review') throw new Error(JSON.stringify(out));
if (out.selected.interaction_mode !== 'execute_command' || !out.selected.execution_command) throw new Error(JSON.stringify(out.selected));
NODE
}

@test "short assets override stale non-short project metadata in recommendations" {
    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"
    printf '# 设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{"workflow_type":"legacy_unknown","status":"completed"}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --action show_smart_recommendations --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const out = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if ((out.smart_new_task_recommendations || []).some((item) => /创作圣经|卷纲|长篇/.test(String(item.label || '')))) {
  throw new Error(JSON.stringify(out.smart_new_task_recommendations));
}
const review = (out.smart_new_task_recommendations || []).find((item) => item.action === 'start_short_review');
if (!review) throw new Error(JSON.stringify(out.smart_new_task_recommendations));
NODE
}

@test "active project new goal menu preserves numbered choices and route bindings" {
    mkdir -p "$TMP_DIR/book"
    printf '# 短篇设定\n' > "$TMP_DIR/book/设定.md"
    printf '# 小节大纲\n' > "$TMP_DIR/book/小节大纲.md"
    printf '# 正文\n' > "$TMP_DIR/book/正文.md"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --action show_new_goal_options --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.selection_contract !== 'route_new_goal_or_accept_free_text') throw new Error(JSON.stringify(out));
if ((out.visible_menu || []).length !== 4) throw new Error(JSON.stringify(out.visible_menu));
for (let index = 0; index < 4; index += 1) {
  if (!String(out.visible_menu[index] || '').startsWith(`${index + 1}. `)) throw new Error(JSON.stringify(out.visible_menu));
}
const first = out.new_goal_options[0] || {};
if (first.interaction_mode !== 'route_intent' || first.route_intent !== 'current_project_write') throw new Error(JSON.stringify(first));
if (first.preserve_existing_tasks !== true) throw new Error(JSON.stringify(first));
NODE
}

@test "workflow task inbox promotes the guarded longform lifecycle action without counting it as a task" {
    mkdir -p "$TMP_DIR/book/大纲"
    printf '# 总纲\n' > "$TMP_DIR/book/大纲/总纲.md"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const next = out.smart_new_task_recommendations.find(item => item.action === 'longform_lifecycle_next');
if (!next || next.lifecycle_action_id !== 'review_master_outline') throw new Error(JSON.stringify(out));
if (out.candidateCount !== 1) throw new Error(JSON.stringify(out.candidates));
if (out.candidates.some(item => item.action === 'longform_lifecycle_next')) throw new Error(JSON.stringify(out.candidates));
if (out.smart_new_task_recommendations.some(item => /下一章/.test(item.label))) throw new Error(JSON.stringify(out.smart_new_task_recommendations));
NODE
}

@test "workflow task inbox recognizes lifecycle-only project metadata" {
    mkdir -p "$TMP_DIR/book/追踪/workflow"
    cat > "$TMP_DIR/book/追踪/workflow/longform-lifecycle.json" <<'JSON'
{"assets":{"positioning":"accepted","story_bible":"accepted","master_outline":"accepted"}}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!out.longform_lifecycle_status) throw new Error(JSON.stringify(out));
if (out.candidateCount !== 0 || out.unfinished_family_count !== 0 || out.taskCardCount !== 0) throw new Error(JSON.stringify(out));
if (out.candidates.some(item => item.action === 'longform_lifecycle_next')) throw new Error(JSON.stringify(out.candidates));
const recommendations = out.smart_new_task_recommendations.filter(item => item.action === 'longform_lifecycle_next');
if (recommendations.length !== 1) throw new Error(JSON.stringify(out.smart_new_task_recommendations));
if (recommendations[0].lifecycle_action_id !== 'review_master_outline') throw new Error(JSON.stringify(recommendations));
NODE
}

@test "workflow task inbox exposes explicit new goal workflow options" {
    mkdir -p "$TMP_DIR/book"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"new_goal_options"' "$TMP_DIR/out.json"
    grep -q '"label": "新开长篇"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "long_startup"' "$TMP_DIR/out.json"
    grep -q '"label": "新开短篇"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "short_write"' "$TMP_DIR/out.json"
    grep -q '"label": "初始化新项目"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "project_setup"' "$TMP_DIR/out.json"
    grep -q '"label": "长篇扫榜"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "long_scan"' "$TMP_DIR/out.json"
    grep -q '"label": "短篇扫榜"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "short_scan"' "$TMP_DIR/out.json"
    grep -q '"label": "短篇拆文"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "short_analyze"' "$TMP_DIR/out.json"
    grep -q '"label": "制作书籍封面"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "cover"' "$TMP_DIR/out.json"
    grep -q '先完成题材定位、核心承诺、人物、剧情引擎、总纲、卷纲和前置细纲' "$TMP_DIR/out.json"
    grep -q '进入完整短篇生命周期：素材、设定、节奏、小节大纲、逐节 Brief、正文验收与完稿' "$TMP_DIR/out.json"
}

@test "workflow task inbox uses current-project goal options when existing work is unfinished" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-review-001"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-review-001/task.json" <<'JSON'
{
  "workflow_id": "wf-review-001",
  "workflow_type": "review_repair",
  "status": "running",
  "user_goal": "审阅 1-200 章",
  "scope": "1-200",
  "current_stage": "evidence_scan",
  "runtime_guard": {
    "heartbeat": {"latest_trusted_artifact": "追踪/workflow/tasks/wf-review-001/rpd.md"}
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"candidateCount": 1' "$TMP_DIR/out.json"
    grep -q '"new_goal_options"' "$TMP_DIR/out.json"
    grep -q '"label": "保留已有任务，开启当前作品写作或回炉目标"' "$TMP_DIR/out.json"
    grep -q '"label": "保留已有任务，开启当前作品审阅或修复目标"' "$TMP_DIR/out.json"
    grep -q '"label": "保留已有任务，开启当前作品素材学习或拆文目标"' "$TMP_DIR/out.json"
    grep -q '"label": "输入其他当前作品目标"' "$TMP_DIR/out.json"
    ! grep -q '"label": "新开长篇"' "$TMP_DIR/out.json"
    ! grep -q '"label": "新开短篇"' "$TMP_DIR/out.json"
}

@test "workflow task inbox recommends next writing step after completion" {
    write_focused_task wf-startup-001 <<'JSON'
{
  "workflow_id": "wf-startup-001",
  "workflow_type": "long_startup",
  "status": "completed_verified",
  "completed_step": "macro_outline",
  "current_stage": "Macro Outline Gate",
  "resume_hint": "/novel-assistant 继续开书"
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"status": "empty"' "$TMP_DIR/out.json"
    grep -q '"post_completion_recommendations"' "$TMP_DIR/out.json"
    grep -q '"recommendationCount": 3' "$TMP_DIR/out.json"
    grep -q '生成第一卷卷纲' "$TMP_DIR/out.json"
    grep -q '补齐前 10 章细纲' "$TMP_DIR/out.json"
    grep -q '进入第 1 章 Chapter Contract' "$TMP_DIR/out.json"
}

@test "workflow task inbox offers a read-only recovery hint from prose metadata" {
    mkdir -p "$TMP_DIR/book/正文/第1卷"
    mkdir -p "$TMP_DIR/book/大纲/第1卷"
    printf '# 第001章\n' > "$TMP_DIR/book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$TMP_DIR/book/大纲/第1卷/细纲_第001章.md"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --write --json > "$TMP_DIR/out.json"

    grep -q '"status": "has_tasks"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "legacy_long_recovery"' "$TMP_DIR/out.json"
    grep -q '"reconstructed": true' "$TMP_DIR/out.json"
    grep -q '恢复旧项目工作流断点' "$TMP_DIR/out.json"
    grep -q '"task_index_path": "追踪/workflow/task-index.json"' "$TMP_DIR/out.json"
}

@test "workflow task inbox renders internal stage ids as Chinese actions" {
    write_focused_task review-001 <<'JSON'
{
  "workflow_id": "review-001",
  "workflow_type": "review_repair",
  "status": "running",
  "current_stage": "range_lock",
  "current_step": "range_lock",
  "runtime_guard": {
    "heartbeat": {
      "updated_at": "2026-07-18T00:00:00.000Z"
    },
    "stall_policy": {
      "heartbeat_timeout_minutes": 999999
    },
    "checkpoint_policy": {
      "resume_from": "range_lock"
    }
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '继续确认审阅范围' "$TMP_DIR/out.json"
    ! grep -q '继续range_lock' "$TMP_DIR/out.json"
}

@test "workflow task inbox resumes a running stage after its pending action was resolved" {
    write_focused_task review-running-001 <<'JSON'
{
  "workflow_id": "review-running-001",
  "workflow_type": "review_repair",
  "status": "running",
  "state_version": 7,
  "book_root": "/tmp/book",
  "user_goal": "审阅 1-50 章",
  "current_stage": "evidence_scan",
  "current_step": "evidence_scan",
  "machine": {"next_stop_reason": "stage_running_waiting_result_packet"},
  "pending_action": {
    "id": "pending-review-running-001",
    "status": "resolved",
    "visible_choice_hash": "resolved-choice-hash",
    "options": [
      {"number": 1, "label": "开始 evidence_scan", "action_id": "continue_next_stage", "target_stage": "evidence_scan"}
    ]
  },
  "stage_execution": {
    "status": "running",
    "stage_id": "evidence_scan",
    "step_id": "evidence_scan",
    "expected_result_packet": "追踪/workflow/tasks/review-running-001/result-packets/evidence_scan.result.json"
  },
  "runtime_guard": {
    "heartbeat": {
      "updated_at": "2026-07-18T00:00:00.000Z"
    },
    "stall_policy": {
      "heartbeat_timeout_minutes": 999999
    },
    "checkpoint_policy": {
      "resume_from": "evidence_scan"
    }
  }
}

JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const candidate = out.candidates.find((item) => item.id === 'review-running-001');
const card = out.task_cards.find((item) => item.id === 'review-running-001');
if (!candidate || !card) throw new Error(JSON.stringify(out));
if (candidate.action_resolution !== null || card.action_resolution !== null) throw new Error(JSON.stringify({ candidate, card }));
if (candidate.next_actions.length !== 1 || card.next_actions.length !== 1) throw new Error(JSON.stringify({ candidate, card }));
const action = candidate.next_actions[0];
if (action.label !== '从断点继续扫描证据') throw new Error(JSON.stringify(action));
if (action.action_id === 'resolve-action' || action.action_resolution != null) throw new Error(JSON.stringify(action));
const visible = JSON.stringify({
  candidate_label: candidate.label,
  candidate_stop_reason: candidate.stop_reason,
  candidate_actions: candidate.next_actions,
  card_display: card.display,
  card_stop_reason: card.stop_reason,
  card_actions: card.next_actions,
  task_visible_menu: out.task_visible_menu,
});
for (const internalWord of ['evidence_scan', 'result packet', 'result_packet', 'running']) {
  if (visible.includes(internalWord)) throw new Error(`${internalWord}: ${visible}`);
}
NODE
}

@test "paused workflow discards stale menu and exposes one deterministic resume action" {
    write_focused_task short-paused-001 <<'JSON'
{
  "workflow_id": "short-paused-001",
  "workflow_type": "private_short_startup",
  "status": "paused",
  "state_version": 12,
  "book_root": ".",
  "user_goal": "整篇回炉",
  "current_stage": "feedback_impact_sync",
  "current_step": "feedback_impact_sync",
  "pending_action": {
    "options": [
      {"number":1,"label":"查看当前进度与依据（推荐）","action_id":"inspect_current_state"},
      {"number":2,"label":"查看当前进度与依据","action_id":"inspect_current_state"}
    ]
  },
  "stage_execution": {
    "status": "paused",
    "stage_id": "feedback_impact_sync",
    "step_id": "feedback_impact_sync",
    "stop_reason": "user_paused_from_running_stage_menu"
  },
  "runtime_guard": {
    "heartbeat": {"updated_at":"2026-07-24T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes":999999},
    "checkpoint_policy": {"resume_from":"feedback_impact_sync"},
    "token_estimate": {"input_files":1,"input_chars_estimate":1,"output_chars_budget":1,"agent_count":0,"batch_size":1,"risk_level":"low"},
    "adaptive_budget_policy": {},
    "output_health_gate": {},
    "max_retry_budget": 1,
    "token_cost_governance": {"cost_ledger_path":"追踪/workflow/token-cost-ledger.jsonl","model_routing_policy":"host_default","tool_output_filter":"compact","retry_budget_result":"not_used"}
  },
  "lifecycle": {"status":"paused"}
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const candidate=(out.candidates||[]).find(item=>item.id==='short-paused-001');
if(!candidate) throw new Error(JSON.stringify(out));
const actions=candidate.next_actions || [];
if(actions.length!==4) throw new Error(JSON.stringify(actions));
if(actions[0].label!=='继续分析反馈影响（推荐）') throw new Error(JSON.stringify(actions[0]));
if(actions[0].interaction_mode!=='execute_command') throw new Error(JSON.stringify(actions[0]));
if(actions[0].execution_command!=='node scripts/workflow-state-machine.js activate --project-root . --workflow-id short-paused-001 --compact --json') throw new Error(JSON.stringify(actions[0]));
if(actions.filter(item=>item.action_id==='inspect_current_state').length!==1) throw new Error(JSON.stringify(actions));
if(JSON.stringify(candidate).includes('feedback impact sync')) throw new Error(JSON.stringify(candidate));
NODE
}

@test "one focused unfinished task projects its current actions instead of stopping at a task summary" {
    write_focused_task short-running-001 <<'JSON'
{
  "workflow_id": "short-running-001",
  "workflow_type": "short_write",
  "status": "running",
  "state_version": 7,
  "book_root": ".",
  "user_goal": "继续短篇第 6 节",
  "current_stage": "section_repair_loop",
  "current_step": "section_repair_loop",
  "pending_action": null,
  "stage_execution": {
    "status": "running",
    "stage_id": "section_repair_loop",
    "step_id": "section_repair_loop",
    "execution_command": "node scripts/short-section-repair-finalize.js --project-root /tmp/book --workflow-id short-running-001 --apply --json",
    "resume_hint": "只读取当前阶段包，只修改第 6 节草稿，完成后再运行 execution_command。"
  },
  "runtime_guard": {
    "heartbeat": {"updated_at": "2026-07-18T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "section_repair_loop"}
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json --action show_unfinished_tasks > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='current_task_actions') throw new Error(JSON.stringify(out));
if(out.selection_contract!=='execute_command_or_route_intent') throw new Error(JSON.stringify(out));
if(out.current_task.id!=='short-running-001') throw new Error(JSON.stringify(out.current_task));
if(!String(out.visible_response||'').includes('当前任务：继续短篇第 6 节')) throw new Error(JSON.stringify(out));
if(String(out.visible_response||'').includes('ready_for_current_stage')) throw new Error(JSON.stringify(out));
if(!String(out.visible_response||'').includes('1. 从断点继续修订当前小节（推荐）')) throw new Error(JSON.stringify(out));
if(!String(out.visible_response||'').includes('4. 输入其他要求')) throw new Error(JSON.stringify(out));
if((out.next_actions||[]).length!==4) throw new Error(JSON.stringify(out.next_actions));
const resume=out.next_actions[0];
if(resume.interaction_mode!=='resume_stage') throw new Error(JSON.stringify(resume));
if(String(resume.execution_command||'').includes('resolve-action')) throw new Error(JSON.stringify(resume));
if(!String(resume.resume_hint||'').includes('只读取当前阶段包')) throw new Error(JSON.stringify(resume));
const inspect=out.next_actions[1];
if(inspect.interaction_mode!=='execute_command') throw new Error(JSON.stringify(inspect));
if(inspect.execution_command!=='node scripts/workflow-state-machine.js inspect --project-root . --json') throw new Error(JSON.stringify(inspect));
if(out.next_actions[2].interaction_mode!=='semantic_only'||out.next_actions[3].interaction_mode!=='semantic_only') throw new Error(JSON.stringify(out.next_actions));
NODE
}

@test "whole-story revision stays a task card before exposing its current section subtask" {
    write_focused_task short-revision-001 <<'JSON'
{
  "workflow_id": "short-revision-001",
  "workflow_type": "short_write",
  "status": "running",
  "state_version": 9,
  "book_root": ".",
  "user_goal": "整篇回炉",
  "current_stage": "draft_first_section",
  "current_step": "draft_first_section",
  "scope": "第1节",
  "feedback_revision_queue": {
    "status": "running",
    "current_section_index": 1,
    "items": [
      {"section_index":1,"status":"pending","brief_status":"invalidated","prose_status":"pending_recheck"},
      {"section_index":2,"status":"pending","brief_status":"invalidated","prose_status":"pending_recheck"}
    ]
  },
  "pending_action": {
    "id":"pa-draft",
    "visible_choice_hash":"hash",
    "options":[{"number":1,"label":"开始写第1节正文","action_id":"continue_next_stage","target_stage":"draft_first_section"}]
  },
  "runtime_guard": {
    "heartbeat": {"updated_at": "2026-07-18T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "draft_first_section"}
  }
}
JSON

    mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
    cat > "$TMP_DIR/book/追踪/private-short-extension/project-state.json" <<'JSON'
{"working_title":"测试短篇","planned_sections":3}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json --action show_unfinished_tasks > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='current_task_actions'||out.current_task.title!=='整篇回炉《测试短篇》') throw new Error(JSON.stringify(out));
if(out.current_task.visible_stage!=='整篇回炉（0/2）'||out.current_task.stop_reason!=='等待进入任务总览') throw new Error(JSON.stringify(out));
if(out.next_actions.length!==4||out.next_actions[0].action_id!=='open_task_overview') throw new Error(JSON.stringify(out.next_actions));
if(out.next_actions[0].interaction_mode!=='execute_command'||!out.next_actions[0].execution_command.includes(' activate ')) throw new Error(JSON.stringify(out.next_actions));
if(!String(out.visible_response||'').includes('1. 进入任务总览（推荐）')) throw new Error(JSON.stringify(out));
if(JSON.stringify(out.visible_menu).includes('开始写第1节')) throw new Error(JSON.stringify(out.visible_menu));
NODE
}

@test "unfinished task actions never emit resolve-action with empty selection bindings" {
    write_focused_task short-unbound-001 <<'JSON'
{
  "workflow_id": "short-unbound-001",
  "workflow_type": "short_write",
  "status": "running",
  "state_version": 8,
  "book_root": ".",
  "user_goal": "继续短篇",
  "current_stage": "section_outline",
  "current_step": "section_outline",
  "machine": {"next_stop_reason": "ready_for_current_stage"},
  "pending_action": {
    "options": [
      {"number": 1, "label": "继续小节大纲", "action_id": "continue_next_stage", "target_stage": "section_outline"}
    ]
  },
  "runtime_guard": {
    "heartbeat": {"updated_at": "2026-07-18T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "section_outline"}
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json --action show_unfinished_tasks > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(String(out.visible_response||'').includes('ready_for_current_stage')) throw new Error(JSON.stringify(out));
if(!String(out.visible_response||'').includes('当前停靠：等待继续当前阶段')) throw new Error(JSON.stringify(out));
const actions=Array.isArray(out.next_actions)
  ? out.next_actions
  : (out.task_cards || []).flatMap((card)=>card.next_actions||[]);
for(const action of actions){
  const command=String(action.execution_command||'');
  if(command.includes(process.argv[3])) throw new Error(`absolute project path leaked: ${command}`);
  if(command.includes('resolve-action') && (/--pending-action-id\s+""/.test(command)||/--visible-choice-hash\s+""/.test(command)||/--state-version\s+0\b/.test(command))) {
    throw new Error(JSON.stringify(action));
  }
}
NODE
}

@test "workflow task inbox emits task-centric cards with resumable next actions" {
    write_focused_task review-200 <<'JSON'
{
  "workflow_id": "review-200",
  "workflow_type": "review_repair",
  "status": "running",
  "user_goal": "审阅 1-200 章情节连贯、钩子回收、人物持续发展",
  "scope": "1-200",
  "current_stage": "range_lock",
  "current_step": "range_lock",
  "machine": {
    "next_stop_reason": "需要确认是否从 1-50 批次开始",
    "remaining_stages": ["range_lock", "evidence_scan", "classify_findings"]
  },
  "runtime_guard": {
    "heartbeat": {
      "latest_trusted_artifact": "追踪/审查报告/批次_001_1-50.md",
      "updated_at": "2026-07-07T10:00:00+08:00"
    }
  },
  "pending_action": {
    "options": [
      {"number": 1, "label": "继续审阅 1-50", "action_id": "continue_next_stage", "target_stage": "evidence_scan"},
      {"number": 2, "label": "调整审阅范围", "action_id": "change_scope"}
    ],
    "free_text_enabled": true
  }
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"task_cards"' "$TMP_DIR/out.json"
    grep -q '"taskCardCount": 1' "$TMP_DIR/out.json"
    grep -q '"title": "审阅 1-200 章情节连贯、钩子回收、人物持续发展"' "$TMP_DIR/out.json"
    grep -q '"visible_stage": "确认审阅范围"' "$TMP_DIR/out.json"
    grep -q '"scope_label": "1-200"' "$TMP_DIR/out.json"
    grep -q '"last_trusted_artifact": "追踪/审查报告/批次_001_1-50.md"' "$TMP_DIR/out.json"
    grep -q '"stop_reason": "需要确认是否从 1-50 批次开始"' "$TMP_DIR/out.json"
    grep -q '"next_actions"' "$TMP_DIR/out.json"
    grep -q '"label": "继续审阅 1-50"' "$TMP_DIR/out.json"
    grep -q '"free_text_enabled": true' "$TMP_DIR/out.json"
    grep -q '"task_visible_menu"' "$TMP_DIR/out.json"
    grep -q '1. 审阅 1-200 章情节连贯、钩子回收、人物持续发展｜阶段：确认审阅范围｜停靠：需要确认是否从 1-50 批次开始' "$TMP_DIR/out.json"
}

@test "workflow task inbox reads durable task directories and groups them before legacy current task" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-review-001" "$TMP_DIR/book/追踪/workflow/tasks/wf-short-001"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-review-001/task.json" <<'JSON'
{
  "workflow_id": "wf-review-001",
  "workflow_type": "review_repair",
  "status": "running",
  "user_goal": "审阅 1-200 章",
  "scope": "1-200",
  "current_stage": "evidence_scan",
  "current_step": "evidence_scan",
  "machine": {"next_stop_reason": "等待继续 51-100 批次"},
  "runtime_guard": {"heartbeat": {"latest_trusted_artifact": "追踪/workflow/tasks/wf-review-001/rpd.md"}},
  "pending_action": {
    "options": [{"number": 1, "label": "继续审阅 51-100", "action_id": "continue_next_stage"}],
    "free_text_enabled": true
  }
}
JSON
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short-001/task.json" <<'JSON'
{
  "workflow_id": "wf-short-001",
  "workflow_type": "short_write",
  "status": "paused",
  "user_goal": "短篇《480万红本》第 4 节 Brief",
  "scope": "第4节",
  "current_stage": "section_brief",
  "current_step": "section_brief",
  "machine": {"next_stop_reason": "等待确认 Brief"},
  "runtime_guard": {"heartbeat": {"latest_trusted_artifact": "追踪/workflow/tasks/wf-short-001/rpd.md"}}
}
JSON

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"

    grep -q '"candidateCount": 2' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "review_repair"' "$TMP_DIR/out.json"
    grep -q '"workflow_type": "short_write"' "$TMP_DIR/out.json"
    grep -q '"source": "追踪/workflow/tasks/wf-review-001/task.json"' "$TMP_DIR/out.json"
    grep -q '"source": "追踪/workflow/tasks/wf-short-001/task.json"' "$TMP_DIR/out.json"
    grep -q '"title": "审阅 1-200 章"' "$TMP_DIR/out.json"
    grep -q '"title": "短篇《480万红本》第 4 节 Brief"' "$TMP_DIR/out.json"
    grep -q '1. 短篇创作（1 个未完成）' "$TMP_DIR/out.json"
    grep -q '2. 审阅与修复（1 个未完成）' "$TMP_DIR/out.json"

    node "$SCRIPT" --project-root "$TMP_DIR/book" --action show_unfinished_tasks --json > "$TMP_DIR/tasks.json"
    node - "$TMP_DIR/tasks.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='show_unfinished_tasks') throw new Error(JSON.stringify(out));
if(out.selection_contract!=='execute_task_card_command_or_route_intent') throw new Error(JSON.stringify(out));
if((out.task_cards||[]).length!==2) throw new Error(JSON.stringify(out.task_cards));
if(out.current_task||out.next_actions) throw new Error('multiple tasks must stay at task selection');
NODE
}

@test "workflow docs route startup through global task inbox before business candidates" {
    grep -q "全局任务收件箱" "$WORKFLOW"
    grep -q "workflow-task-inbox.js" "$WORKFLOW"
    grep -q "task-index.json" "$WORKFLOW"
    grep -q "workflow_groups" "$WORKFLOW"
    grep -q "smart_new_task_recommendations" "$WORKFLOW"
    grep -q "post_completion_recommendations" "$WORKFLOW"
    grep -q "metadata_only" "$WORKFLOW"
    grep -q "短篇的启动恢复经验必须提升为全局能力" "$WORKFLOW"
    grep -q "task-inbox-protocol.md" "$WORKFLOW"
    grep -q "未完成数量只显示在第 1 项括号内" "$TASK_INBOX_PROTOCOL"
    grep -q "查看智能推荐新任务" "$TASK_INBOX_PROTOCOL"
    grep -q "明确新业务意图" "$TASK_INBOX_PROTOCOL"
    grep -q "不得用旧任务收件箱拦截" "$TASK_INBOX_PROTOCOL"

    grep -q "workflow-task-inbox.js" "$ROUTER"
    grep -q "全局任务收件箱" "$ROUTER"

    grep -q "workflow-task-inbox.js" "$ENTRY"
    grep -q "首屏是任务收件箱总览" "$ENTRY"
    grep -q "用户选择.*1/2/3" "$ENTRY"
    grep -q "show_unfinished_tasks" "$ENTRY"
    grep -q -- "--user-intent" "$ENTRY"
    grep -q "明确的新业务意图" "$ENTRY"
    grep -q "不能拦截新目标" "$ENTRY"
}

@test "workflow docs continue an authorized review after protocol reset instead of returning home" {
    grep -q 'review_batches_reset' "$WORKFLOW"
    grep -q '不得再次调用 workflow-entry-guard.js' "$WORKFLOW"
    grep -q 'finish_authorized_workflow' "$WORKFLOW"
    grep -q '依次完成所有剩余批次' "$WORKFLOW"
    grep -q 'review_batches_reset' "$REPO/src/internal-skills/story-workflow/references/task-inbox-protocol.md"
    grep -q '不得返回任务收件箱首页' "$REPO/src/internal-skills/story-workflow/references/task-inbox-protocol.md"
}

@test "collaboration environment update handoff uses task inbox before new business guesses" {
    grep -q "entry-runtime-contract.md" "$ENTRY"
    grep -q "更新完成后运行.*workflow-entry-guard.js" "$ENTRY_RUNTIME"
    grep -q "逐字使用.*visible_response.text" "$ENTRY_RUNTIME"
    grep -q "查看未完成任务（N 个）" "$TASK_INBOX_PROTOCOL"
    grep -q "candidateCount=0.*仍显示" "$TASK_INBOX_PROTOCOL"
    grep -q "不得凭聊天记忆" "$TASK_INBOX_PROTOCOL"
    grep -q "已初始化项目.*没有明确业务意图" "$TASK_INBOX_PROTOCOL"

    grep -q "entry-runtime-contract.md" "$ROUTER"
}

@test "workflow entry guard lets explicit new user intent bypass legacy task inbox" {
    mkdir -p "$TMP_DIR/book/正文/第1卷"
    mkdir -p "$TMP_DIR/book/大纲/第1卷"
    printf '# 第001章\n' > "$TMP_DIR/book/正文/第1卷/第001章.md"
    printf '# 细纲\n' > "$TMP_DIR/book/大纲/第1卷/细纲_第001章.md"

    node "$REPO/scripts/workflow-entry-guard.js" \
        --project-root "$TMP_DIR/book" \
        --user-intent "/novel-assistant 请做当前短篇的反馈影响链检查" \
        --json > "$TMP_DIR/entry-explicit.json"

    grep -q '"status":"pass"' "$TMP_DIR/entry-explicit.json"
    grep -q '"recommended_next":"business_routing_allowed"' "$TMP_DIR/entry-explicit.json"
    grep -q '"user_intent_present":true' "$TMP_DIR/entry-explicit.json"
    grep -q '"task_inbox_deferred_for_explicit_intent":true' "$TMP_DIR/entry-explicit.json"
    grep -q '"candidateCount":1' "$TMP_DIR/entry-explicit.json"

    node "$REPO/scripts/workflow-entry-guard.js" \
        --project-root "$TMP_DIR/book" \
        --user-intent "1" \
        --json > "$TMP_DIR/entry-short.json"

    grep -q '"status":"task_inbox_ready"' "$TMP_DIR/entry-short.json"
    grep -q '"recommended_next":"show_task_inbox_only"' "$TMP_DIR/entry-short.json"
}

@test "workflow entry guard shows new project onboarding for uninitialized directory" {
    mkdir -p "$TMP_DIR/empty-book/追踪/workflow"

    node "$REPO/scripts/workflow-entry-guard.js" \
        --project-root "$TMP_DIR/empty-book" \
        --json > "$TMP_DIR/entry-empty.json"

    grep -q '"status":"new_project_ready"' "$TMP_DIR/entry-empty.json"
    grep -q '"recommended_next":"show_new_project_onboarding"' "$TMP_DIR/entry-empty.json"
    grep -q '"project_initialized":false' "$TMP_DIR/entry-empty.json"
    grep -q '新开长篇' "$TMP_DIR/entry-empty.json"
    grep -q '新开短篇' "$TMP_DIR/entry-empty.json"
    grep -q '导入或拆文' "$TMP_DIR/entry-empty.json"
    ! grep -q '查看未完成任务（0 个）' "$TMP_DIR/entry-empty.json"

    grep -q "new_project_ready" "$TASK_INBOX_PROTOCOL"
    grep -q "show_new_project_onboarding" "$TASK_INBOX_PROTOCOL"
    grep -q "新项目只展示长篇、短篇、导入/拆文或其他目标" "$ENTRY"
    grep -q "未初始化目录不得展示任务收件箱" "$TASK_INBOX_PROTOCOL"
    grep -q "不得显示.*查看未完成任务（0 个）" "$TASK_INBOX_PROTOCOL"

    grep -q "new_project_ready" "$WORKFLOW"
    grep -q "show_new_project_onboarding" "$WORKFLOW"
    grep -q "未初始化目录不得展示任务收件箱" "$WORKFLOW"
    grep -q "不得显示.*查看未完成任务（0 个）" "$WORKFLOW"
}

@test "workflow entry guard does not turn its own empty runtime metadata into a writing project" {
    mkdir -p "$TMP_DIR/empty-book"

    node "$REPO/scripts/workflow-entry-guard.js" \
        --project-root "$TMP_DIR/empty-book" \
        --write --json > "$TMP_DIR/entry-first.json"

    test -f "$TMP_DIR/empty-book/追踪/workflow/entry-guard.json"

    node "$REPO/scripts/workflow-entry-guard.js" \
        --project-root "$TMP_DIR/empty-book" \
        --write --json > "$TMP_DIR/entry-second.json"

    grep -q '"status":"new_project_ready"' "$TMP_DIR/entry-second.json"
    grep -q '"project_initialized":false' "$TMP_DIR/entry-second.json"
    ! grep -q '查看未完成任务（0 个）' "$TMP_DIR/entry-second.json"
}

@test "workflow task inbox is bundled and covered by production smoke matrix" {
    grep -q '"workflow-task-inbox.js"' "$REPO/config/novel-assistant-bundle-files.json"
    grep -q '"longform-lifecycle-status.js"' "$REPO/config/novel-assistant-bundle-files.json"
    grep -q "workflow_task_inbox" "$REPO/scripts/production-smoke-matrix.js"
    test -x "$BUNDLE/scripts/workflow-task-inbox.js"
}

@test "workflow task inbox counts one task family with a paused branch once" {
    STORE="$REPO/scripts/lib/task-family-store.js"
    node - "$STORE" "$TMP_DIR/book" <<'NODE'
const fs=require('fs');const path=require('path');const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const tasks=[
  {workflow_id:'wf-review-a',workflow_type:'review_repair',status:'paused',scope:'1-200章',user_goal:'审阅 1-200 章情节与钩子',lifecycle:{status:'paused',focus_switched_to:'wf-review-b'},current_stage:'evidence_scan',pending_action:{options:[]}},
  {workflow_id:'wf-review-b',workflow_type:'review_repair',status:'running',scope:'1-200章',user_goal:'审阅 1-200 章情节与钩子',lifecycle:{status:'active',focus_switched_from:'wf-review-a'},current_stage:'repair_execution_plan',pending_action:{options:[{number:1,label:'重新生成受控修复方案',action_id:'continue_next_stage'}]}}
];
for(const task of tasks){task.task_dir=`追踪/workflow/tasks/${task.workflow_id}`;fs.mkdirSync(path.join(root,task.task_dir),{recursive:true});fs.writeFileSync(path.join(root,task.task_dir,'task.json'),JSON.stringify(task));store.ensureTaskFamily(root,task,{write:true});}
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify({schemaVersion:'1.0.0',workflow_id:tasks[1].workflow_id,task_dir:tasks[1].task_dir,focused_at:'2026-07-12T00:00:00.000Z',state_version:1}));
NODE

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/family-inbox.json"
    node - "$TMP_DIR/family-inbox.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.candidateCount!==1 || out.task_cards.length!==1) throw new Error(JSON.stringify(out));
const card=out.task_cards[0];
if(!String(card.id).startsWith('tf-') || card.paused_branch_count!==1 || card.next_actions[0].label!=='重新生成受控修复方案') throw new Error(JSON.stringify(card));
NODE
}

@test "task inbox displays authoritative paused task status over stale active family projection" {
    mkdir -p "$TMP_DIR/book/追踪/workflow/tasks/wf-short"
    cat > "$TMP_DIR/book/追踪/workflow/tasks/wf-short/task.json" <<'JSON'
{"workflow_id":"wf-short","workflow_type":"short_write","status":"paused","state_version":1,"scope":"全篇","user_goal":"整篇回炉","lifecycle":{"status":"paused"},"current_stage":"feedback_impact_sync","stage_execution":{"status":"paused","stage_id":"feedback_impact_sync"},"runtime_guard":{"heartbeat":{"updated_at":"2026-07-24T00:00:00.000Z"},"stall_policy":{"heartbeat_timeout_minutes":999999},"checkpoint_policy":{"resume_from":"feedback_impact_sync"},"token_estimate":{"input_files":1,"input_chars_estimate":1,"output_chars_budget":1,"agent_count":0,"batch_size":1,"risk_level":"low"},"adaptive_budget_policy":{},"output_health_gate":{},"max_retry_budget":1,"token_cost_governance":{"cost_ledger_path":"追踪/workflow/token-cost-ledger.jsonl","model_routing_policy":"host_default","tool_output_filter":"compact","retry_budget_result":"not_used"}}}
JSON
    node - "$REPO/scripts/lib/task-family-store.js" "$TMP_DIR/book" <<'NODE'
const [storeFile,root]=process.argv.slice(2);const store=require(storeFile);
const task=require(`${root}/追踪/workflow/tasks/wf-short/task.json`);
const projected=store.ensureTaskFamily(root,{...task,status:'running',lifecycle:{status:'active'}},{write:true});
task.task_family_id=projected.family.task_family_id;
require('fs').writeFileSync(`${root}/追踪/workflow/tasks/wf-short/task.json`,JSON.stringify(task));
require('fs').writeFileSync(`${root}/追踪/workflow/current-task.json`,JSON.stringify({workflow_id:'wf-short',task_dir:'追踪/workflow/tasks/wf-short',state_version:1}));
NODE

    node "$SCRIPT" --project-root "$TMP_DIR/book" --json > "$TMP_DIR/out.json"
    node - "$TMP_DIR/out.json" <<'NODE'
const out=JSON.parse(require('fs').readFileSync(process.argv[2],'utf8'));
const card=(out.task_cards||[])[0];
if(!card||card.status!=='paused') throw new Error(JSON.stringify(card));
NODE
}
