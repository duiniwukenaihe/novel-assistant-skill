#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/workflow-stage-context.js"
    BOOK="$(mktemp -d)/档案复核"
    WORKFLOW_ID="wf-20260716014257097-private_short_startup-8318de87"
    TASK_DIR="$BOOK/追踪/workflow/tasks/$WORKFLOW_ID"
    PACKET_REL="追踪/workflow/tasks/$WORKFLOW_ID/context-packets/feedback_apply_patch/whole-story/sa-$WORKFLOW_ID-feedback_apply_patch-b5491f6d/stage-context.md"
    mkdir -p "$TASK_DIR" "$(dirname "$BOOK/$PACKET_REL")" "$BOOK/追踪/workflow"
    printf '# 精确阶段包\n只读这份内容。\n' > "$BOOK/$PACKET_REL"
    cat > "$TASK_DIR/task.json" <<JSON
{
  "workflow_id":"$WORKFLOW_ID",
  "workflow_type":"private_short_startup",
  "task_dir":"追踪/workflow/tasks/$WORKFLOW_ID",
  "current_stage":"feedback_apply_patch",
  "stage_execution":{
    "status":"running",
    "stage_id":"feedback_apply_patch",
    "stage_context_packet":{"packet_md":"$PACKET_REL"}
  }
}
JSON
    cat > "$BOOK/追踪/workflow/current-task.json" <<JSON
{"schemaVersion":"1.0.0","workflow_id":"$WORKFLOW_ID","task_dir":"追踪/workflow/tasks/$WORKFLOW_ID"}
JSON
}

teardown() {
    rm -rf "$(dirname "$BOOK")"
}

@test "read-current resolves the authoritative stage packet without a host copying its path" {
    run node "$SCRIPT" read-current --project-root "$BOOK" --workflow-id "$WORKFLOW_ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *'# 精确阶段包'* ]]
    [[ "$output" == *'只读这份内容。'* ]]
}

@test "read-current returns structured blocking when the workflow id is unknown" {
    run node "$SCRIPT" read-current --project-root "$BOOK" --workflow-id "wf-unknown" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_task_not_found'* ]]
}

@test "refresh-current is a supported deterministic command" {
    run node "$SCRIPT" refresh-current --project-root "$BOOK" --workflow-id "wf-unknown" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_task_authority_missing'* ]]
}

@test "build-and-read assembles the current V3 Brief packet and returns its content in one command" {
    mkdir -p "$BOOK/追踪/story-system/short" "$BOOK/追踪/memory"
    cat > "$BOOK/追踪/story-system/short/project-state.json" <<'JSON'
{"project_id":"neutral-short","project_title":"中性短篇","plan_revision":1,"planned_sections":1,"current_section_index":1,"accepted_sections":[]}
JSON
    cat > "$BOOK/小节大纲.md" <<'EOF'
# 小节大纲

## 第1节：公开复核
- 结构功能：开篇建立可核验冲突
- 情绪目标：疑惑转为警觉
- 因果链：发现重复编号 -> 拒绝撤回 -> 保留复核记录
- 场景动作：主角在评审会上展示重复编号
- 角色选择：主角拒绝删除记录
- 可见阻力：主管要求立即撤回记录
- 本节兑现：重复编号第一次被公开展示
- 关系变化：主角与主管从配合转为公开分歧
- 代价升级：主角可能失去复核权限
- 核心承诺兑现：异常编号进入公开核验
- 决定性行动：主角保存扫描回放
- 即时代价：主管当场暂停她的操作权限
- 子事件：
  1. 主角发现两个批次编号重复
  2. 主管要求撤回，主角拒绝
- 节尾钩子：旧批次记录仍未公开
EOF
    printf '%s\n' '# 设定' '第一人称，主角负责档案复核。' > "$BOOK/设定.md"
    printf '%s\n' '# 素材卡' '以公开记录推动责任落地。' > "$BOOK/素材卡.md"
    node - "$TASK_DIR/task.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8'));
task.current_stage = 'section_brief';
task.current_section_index = 1;
task.stage_execution = {
  status: 'running',
  stage_id: 'section_brief',
  stage_attempt_id: 'sa-neutral-brief',
  section_index: 1,
};
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE

    run node "$SCRIPT" build-and-read --project-root "$BOOK" \
        --workflow-id "$WORKFLOW_ID" --stage section_brief --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'"status": "stage_context_ready"'* ]]
    [[ "$output" == *'"packet_md"'* ]]
    [[ "$output" == *'memory_read_receipt'* ]]
    [[ "$output" == *'当前作品记忆快照'* ]]
    [[ "$output" == *'第1节故事合同'* ]]
}

@test "stage context packet markdown includes recall explanation block" {
  local tmp
  tmp="$BATS_TEST_TMPDIR/recall-block"
  mkdir -p "$tmp/追踪/memory" "$tmp/追踪/private-short-extension" "$tmp/正文" "$tmp/追踪/workflow/tasks/w1"
  printf '%s\n' '{"project_id":"recall-test","project_title":"召回说明书","plan_revision":1,"current_section_index":1,"accepted_sections":[],"narrative":{"planned_sections":3}}' > "$tmp/追踪/private-short-extension/project-state.json"
  cat > "$tmp/小节大纲.md" <<'EOF'
# 小节大纲

## 第1节：公开复核
- 结构功能：开篇建立可核验冲突
- 情绪目标：疑惑转为警觉
- 因果链：发现重复编号 -> 拒绝撤回 -> 保留复核记录
- 场景动作：主角在评审会上展示重复编号
- 角色选择：主角拒绝删除记录
- 可见阻力：主管要求立即撤回记录
- 本节兑现：重复编号第一次被公开展示
- 关系变化：主角与主管从配合转为公开分歧
- 代价升级：主角可能失去复核权限
- 核心承诺兑现：异常编号进入公开核验
- 决定性行动：主角保存扫描回放
- 即时代价：主管当场暂停她的操作权限
- 子事件：
  1. 主角发现两个批次编号重复
  2. 主管要求撤回，主角拒绝
- 节尾钩子：旧批次记录仍未公开
## 第2节：升级
## 第3节：反转
EOF
  printf '%s\n' '# 设定' '第一人称，主角负责档案复核。' > "$tmp/设定.md"
  printf '%s\n' '# 素材卡' '以公开记录推动责任落地。' > "$tmp/素材卡.md"

  run node - "$REPO/scripts/lib/workflow-stage-context-packet.js" "$tmp" <<'NODE'
const fs = require('fs');
const path = require('path');
const mod = process.argv[2];
const projectRoot = process.argv[3];
const { buildStageContextPacket } = require(mod);
const packet = buildStageContextPacket({
  projectRoot,
  task: { workflow_id: 'w1', workflow_type: 'short_write', current_stage: 'section_brief', task_dir: '追踪/workflow/tasks/w1', current_section_index: 1, stage_execution: { stage_id: 'section_brief', stage_attempt_id: 'sa-recall' } },
  stage: 'section_brief',
});
if (packet.status !== 'assembled') throw new Error(`expected assembled, got: ${JSON.stringify(packet)}`);
const markdown = fs.readFileSync(path.join(projectRoot, packet.packet_md), 'utf8');
process.stdout.write(markdown);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"本次召回说明"* ]]
}
