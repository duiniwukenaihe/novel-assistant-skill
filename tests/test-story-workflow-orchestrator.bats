#!/usr/bin/env bats
# tests/test-story-workflow-orchestrator.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    TOP="$REPO/skills/novel-assistant/SKILL.md"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    BUNDLE_NOVEL="$REPO/skills/novel-assistant"
}

extract_section() {
    local file="$1"
    local start="$2"
    local end_prefix="$3"
    python3 - "$file" "$start" "$end_prefix" <<'PY'
from pathlib import Path
import sys

file_path, start, end_prefix = sys.argv[1:4]
lines = Path(file_path).read_text(encoding="utf-8").splitlines()
capturing = False
captured = []

for line in lines:
    if not capturing and line == start:
        capturing = True
    if not capturing:
        continue
    if captured and line.startswith(end_prefix):
        break
    captured.append(line)

print("\n".join(captured))
PY
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]]
}

workflow_has() {
    local needle="$1"
    local protocol_dir
    protocol_dir="$(dirname "$WORKFLOW")/references"

    grep -q -- "$needle" "$WORKFLOW" ||
        grep -q -- "$needle" "$protocol_dir/task-inbox-protocol.md" ||
        grep -q -- "$needle" "$protocol_dir/runner-execution-protocol.md" ||
        grep -q -- "$needle" "$protocol_dir/canonical-write-protocol.md" ||
        grep -q -- "$needle" "$protocol_dir/completion-evidence-protocol.md"
}

@test "story-workflow skill defines orchestration without taking over domain execution" {
    test -f "$WORKFLOW"
    workflow_has "story-workflow"
    workflow_has "工作流大脑"
    workflow_has "只负责编排"
    workflow_has "不得直接写正文"
    workflow_has "不得替代 story-long-write"
    workflow_has "不得替代 story-review"
    workflow_has "不得替代 story-long-analyze"
}

@test "workflow loads heavy protocols through references" {
    [ "$(wc -l < "$WORKFLOW")" -lt 800 ]

    for protocol in \
        task-inbox-protocol.md \
        runner-execution-protocol.md \
        canonical-write-protocol.md \
        completion-evidence-protocol.md
    do
        workflow_has "$protocol"
        test -f "$(dirname "$WORKFLOW")/references/$protocol"
    done
}

@test "progressive protocol links resolve and stage ownership is unambiguous" {
    protocol_dir="$(dirname "$WORKFLOW")/references"

    run node - "$WORKFLOW" \
        "$protocol_dir/task-inbox-protocol.md" \
        "$protocol_dir/runner-execution-protocol.md" \
        "$protocol_dir/canonical-write-protocol.md" \
        "$protocol_dir/completion-evidence-protocol.md" <<'NODE'
const fs = require('fs');
const path = require('path');
for (const file of process.argv.slice(2)) {
  const source = fs.readFileSync(file, 'utf8');
  for (const match of source.matchAll(/\[[^\]]+\]\(([^)]+)\)/g)) {
    const target = match[1].split('#')[0];
    if (!target || /^(?:https?:|#|\/)/.test(target)) continue;
    const resolved = path.resolve(path.dirname(file), target);
    if (!fs.existsSync(resolved)) throw new Error(`${file}: unresolved link ${target}`);
  }
}
NODE
    [ "$status" -eq 0 ]

    grep -q "状态机命令由 \[task-inbox-protocol.md\]" "$WORKFLOW"
    grep -q "packet 字段由 \[completion-evidence-protocol.md\]" "$WORKFLOW"
    grep -q "进入执行前读取.*runner-execution-protocol.md" "$WORKFLOW"
    grep -q "正式资产.*必须先读取.*canonical-write-protocol.md" "$WORKFLOW"
    grep -q "应用 result packet.*必须读取.*completion-evidence-protocol.md" "$WORKFLOW"
}

@test "task inbox has one recoverable numeric interaction schema" {
    inbox="$(dirname "$WORKFLOW")/references/task-inbox-protocol.md"

    ! grep -q "render_mode: host_select | text_numbers" "$inbox"
    ! grep -q '"render_mode": "host_select_preferred"' "$inbox"
    ! grep -q "不占编号" "$inbox"
    grep -q '"interaction_renderer": "host_select_preferred"' "$inbox"
    grep -q '"render_mode": "text_numbers"' "$inbox"
    grep -q "4. 输入其他要求" "$inbox"
}

@test "workflow progressive protocols retain their required anchors" {
    protocol_dir="$(dirname "$WORKFLOW")/references"

    grep -q "任务中心工作流" "$protocol_dir/task-inbox-protocol.md"
    grep -q "workflow-task-inbox.js" "$protocol_dir/task-inbox-protocol.md"
    grep -q "workflow-runner.js" "$protocol_dir/runner-execution-protocol.md"
    grep -q "tool_call_degradation_guard" "$protocol_dir/runner-execution-protocol.md"
    grep -q "正式资产事务接受" "$protocol_dir/canonical-write-protocol.md"
    grep -q "chapter-commit.js prepare" "$protocol_dir/canonical-write-protocol.md"
    grep -q "短篇单节写作" "$protocol_dir/canonical-write-protocol.md"
    grep -q "可信产物、预期产物与恢复" "$protocol_dir/completion-evidence-protocol.md"
    grep -q "完成策略" "$protocol_dir/completion-evidence-protocol.md"
}

@test "story-workflow defines completion policies and step navigation" {
    workflow_has "completion_policy"
    workflow_has "full_auto"
    workflow_has "stage_then_confirm"
    workflow_has "step_then_confirm"
    workflow_has "plan_only"
    workflow_has "A1"
    workflow_has "下一步候选"
    workflow_has "完成后停在阶段导航"
    ! workflow_has "仅执行本项"
}

@test "story-workflow persists memory with task history and preferences" {
    workflow_has "工作流记忆"
    workflow_has "追踪/workflow/current-task.json"
    workflow_has "追踪/workflow/history.jsonl"
    workflow_has "追踪/workflow/preference-memory.jsonl"
    workflow_has "任务记忆"
    workflow_has "偏好记忆"
    workflow_has "source"
    workflow_has "confidence"
    workflow_has "scope"
    workflow_has "当前请求优先"
}

@test "story-workflow uses file-backed planning instead of external task tools" {
    workflow_has "文件化任务计划协议"
    workflow_has "不得调用 TaskCreate"
    workflow_has "不得调用交互式选择工具"
    workflow_has "Invalid tool parameters"
    workflow_has "current-task.json"
    workflow_has "current-task.md"
    workflow_has "任务较大"
}

@test "story-workflow exposes numeric candidates for cli and frontend selection" {
    workflow_has "数字候选协议"
    workflow_has "1. 继续当前阶段"
    workflow_has "number"
    workflow_has "label"
    workflow_has "action"
    workflow_has "1/2/3/4"
    workflow_has "前端.*上下方向键"
    workflow_has "CLI 用户直接输入"
    workflow_has "不得依赖外部交互式选择工具"
    workflow_has "查看更多选项"
    workflow_has "Chat about this"
    ! workflow_has "\\[1/A\\]"
}

@test "story-workflow prefers host select interaction with text fallback" {
    top="$REPO/skills/novel-assistant/SKILL.md"

    grep -q "底层始终保存稳定数字，宿主支持时优先渲染 host_select" "$top"
    grep -q "宿主选择器适配协议" "$top"
    grep -q "不得直接调用原始 AskUserQuestion" "$top"
    grep -q "host_select_failed" "$top"

    workflow_has "host_select 优先、text_numbers 兜底"
    workflow_has "interaction_renderer"
    workflow_has "interaction_renderer.*host_select_preferred"
    workflow_has "render_mode.*text_numbers"
    workflow_has "fallback.*text_numbers"
    workflow_has "host_select_failed"
    workflow_has "interaction_degraded_to_text_numbers"
    workflow_has "上下方向键"
}

@test "story-workflow defines transactional write gate and blocks false completion" {
    workflow_has "写入事务门禁"
    workflow_has "write_failure_triage"
    workflow_has "write-failure-triage.js"
    workflow_has "tool_call_schema_check"
    workflow_has "Error writing file"
    workflow_has "Error editing file"
    workflow_has "PostToolUse hook"
    workflow_has "参数不完整"
    workflow_has "file_path.*content"
    workflow_has "不得说.*继续执行.*落盘"
    workflow_has "不得再次调用同一 Write/Edit"
    workflow_has "file .* directory .* symlink"
    workflow_has "恢复报告路径"
    workflow_has "agent Done"
    workflow_has "文件存在"
    workflow_has "blocked_write_permission"
    workflow_has "blocked_write_hook"
    workflow_has "blocked_write_tool_call_invalid"
    workflow_has "blocked_write_missing_output"
    workflow_has "不得把未落盘内容当作完成"
}

@test "story-workflow caps global agent output with compressed handoff packets" {
    workflow_has "全局 agent 压缩协议"
    workflow_has "agent_output_budget"
    workflow_has "动态 agent_output_budget"
    workflow_has "adaptive_budget_policy"
    workflow_has "visible_reply_budget"
    workflow_has "batch_handoff_budget"
    workflow_has "range_summary_budget"
    workflow_has "不得写死固定字数"
    workflow_has "1-200 章不能压成一个短摘要"
    workflow_has "范围级摘要不是事实源"
    workflow_has "detail_matrix_paths"
    workflow_has "批次交接包"
    workflow_has "范围级摘要"
    workflow_has "token_estimate"
    workflow_has "model_degradation_guard"
    workflow_has "handoff_packet_path"
    workflow_has "禁止把长设定正文直接返回主线程"
    workflow_has "主线程只读取压缩交接包"
    workflow_has "完整产物必须落盘"
    workflow_has "source-grounding"
    workflow_has "token_guard"
}

@test "story-workflow pending action is scoped and expires" {
    workflow_has "workflow_id"
    workflow_has "book_root"
    workflow_has "created_at"
    workflow_has "expires_at"
    workflow_has "visible_choice_hash"
    workflow_has "expected_reply_set"
    workflow_has "短回复只能绑定到最新可见候选"
    workflow_has "pending_action_expired"
    workflow_has "pending_action_project_mismatch"
    workflow_has "pending_action_choice_hash_mismatch"
}

@test "story-workflow replies after numbered choice execution instead of relying on recap" {
    workflow_has "编号选择执行后必须有可见停靠"
    workflow_has "不得只读文件后依赖 recap"
    workflow_has "本轮已执行"
    workflow_has "当前停靠位置"
    workflow_has "下一步可选"
    workflow_has "没有继续吗"
    workflow_has "阶段启动锁"
    workflow_has "stage_execution.status"
    workflow_has "stage_running_waiting_result_packet"
    workflow_has "不得再说.*待确认是否先执行"
}

@test "story-workflow uses deterministic domain profile for genre wording" {
    workflow_has "story-domain-profile.js"
    workflow_has "domainProfile"
    workflow_has "primaryDomain=xiuzhen_xianxia"
    workflow_has "growthAxisLabel"
    workflow_has "不得默认写.*修真进度一致性"
}

@test "story-workflow blocks contaminated tool commands and repeated failed tool calls" {
    workflow_has "tool_call_degradation_guard"
    workflow_has "blocked_tool_command_contaminated"
    workflow_has "blocked_repeated_tool_failure"
    workflow_has "tool-call-degradation-check.js"
    workflow_has "不得把 diff hunk"
    workflow_has "不得把工具输出拼进 Bash 命令"
    workflow_has "同一 Bash/Agent/Write/Edit 失败两次"
    workflow_has "Invalid tool parameters"
    workflow_has "不得继续换 prompt 撞 Agent"
    workflow_has "工具调用自愈协议"
    workflow_has "blocked-payload.txt"
    workflow_has "last-trusted-state"
    workflow_has "执行成功后更新 workflow 断点"
    workflow_has "needs_tool_task_decomposition"
    workflow_has "tool-task-decompose-plan.js"
    workflow_has "禁止以自由拼接形态直接执行多行 Bash"
    workflow_has "python3 -c"
    workflow_has "heredoc"
    workflow_has "分拆优先"
    workflow_has "不是拒绝任务"
    workflow_has "decompose_and_execute_scripted_steps"
    workflow_has "拆成可验证步骤"
    workflow_has "任务继续执行"
    workflow_has "safeCommands"
    workflow_has "chapter-text-stats.js"
    workflow_has "stage2-summary-quality-check.js"
    workflow_has "story-progress-status.js"
}

@test "story-workflow enforces unattended authorization budget" {
    workflow_has "无人值守授权预算协议"
    workflow_has "authorization_prompt_budget"
    workflow_has "启动自检.*0 次 Bash 授权"
    workflow_has "长任务确认后不得按批次反复授权"
    workflow_has "同一 workflow 授权弹窗超过预算"
    workflow_has "permission_budget_exceeded"
    workflow_has "改为脚本化一行命令或 runner 后台任务"
    workflow_has "不得继续让用户逐条点允许"
    workflow_has "novel-assistant-sync-runtime.js"
    workflow_has "不得拆成多条"
    workflow_has "允许请求授权的边界"
    workflow_has "sudo/chmod/chown"
    workflow_has "git push"
    workflow_has "安装依赖"
    workflow_has "访问登录态或付费源"
}

@test "story-workflow enforces authorization friendly search commands" {
    workflow_has "授权友好搜索协议"
    workflow_has "safe-text-search.js"
    workflow_has "不得生成.*cd .*grep.*2>/dev/null.*head"
    workflow_has "绝对路径"
    workflow_has "无 cd、无重定向、无管道"
    workflow_has "不是跳过搜索"
}

@test "story-workflow enforces authorization friendly chapter counting" {
    workflow_has "授权友好章节统计协议"
    workflow_has "chapter-volume-count.js"
    workflow_has "不得生成.*cd .*for .*ls .*grep .*wc"
    workflow_has "按卷统计章节"
    workflow_has "排除 _原稿_"
}

@test "story-workflow keeps user requested range first in visible choices" {
    workflow_has "范围优先候选协议"
    workflow_has "用户范围放在主标题最前面"
    workflow_has "审阅 1-200 章：完整多视角审查"
    workflow_has "按 7-07 批计划跑 1-200 full 模式审查"
    workflow_has "target_scope"
    workflow_has '日期 `7-07`'
    workflow_has "full 模式.*完整多视角审查"
}

@test "story-workflow uses deterministic template for blocked recovery replies" {
    workflow_has "blocked-recovery-template.js"
    workflow_has "禁止自由生成 blocked 状态长回复"
    workflow_has "模板输出后仍要按可见回复污染门禁复扫"
    workflow_has "不得在 blocked 回复里复述污染片段"
    workflow_has "超过 8 行的自由文本"
}

@test "story-workflow front-loads pollution checks to save tokens" {
    workflow_has "早停省 token 原则"
    workflow_has "生成前探针"
    workflow_has "生成中早停"
    workflow_has "小样本验证"
    workflow_has "同一污染类型最多重试一次"
    workflow_has "不得启动剩余 agent"
    workflow_has "工具调用/上下文污染型退化属于 skill 自身边界问题"
}

@test "story router uses story-workflow before specialized modules for multi step tasks" {
    grep -q "story-workflow" "$ROUTER"
    grep -q "工作流编排门禁" "$ROUTER"
    grep -q "拆文.*story-workflow" "$ROUTER"
    grep -q "审阅.*story-workflow" "$ROUTER"
    grep -q "写作.*story-workflow" "$ROUTER"
    grep -q "回炉.*story-workflow" "$ROUTER"
    grep -q "去 AI 味.*story-workflow" "$ROUTER"
    grep -q "再读取目标专业模块" "$ROUTER"
}

@test "top level novel assistant documents workflow memory and resumable plans" {
    grep -q "引用索引" "$TOP"
    grep -q "story-workflow/SKILL.md" "$TOP"
    grep -q "task-inbox-protocol.md" "$TOP"
    workflow_has "追踪/workflow/current-task.json"
    workflow_has "不依赖聊天记忆"
    workflow_has "下一步候选"
}

@test "README documents story-workflow as the workflow brain" {
    grep -q "工作流大脑" "$REPO/README.md"
    grep -q "story-workflow" "$REPO/README.md"
    grep -q "full_auto" "$REPO/README.md"
    grep -q "stage_then_confirm" "$REPO/README.md"
    grep -q "step_then_confirm" "$REPO/README.md"
    grep -q "追踪/workflow/current-task.json" "$REPO/README.md"
    grep -q "preference-memory.jsonl" "$REPO/README.md"
}

@test "workflow integrates story memory context before broad artifact reads" {
    PACKET_PROTOCOL="$REPO/src/internal-skills/story-workflow/references/completion-evidence-protocol.md"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write/SKILL.md"
    REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
    DESLOP="$REPO/src/internal-skills/story-deslop/SKILL.md"
    workflow_packet_section="$(extract_section "$PACKET_PROTOCOL" "## L2 到 L3 输入契约" "## ")"
    context_assembly_section="$(extract_section "$PACKET_PROTOCOL" "### 创作记忆库上下文装配" "## ")"
    long_write_memory_section="$(extract_section "$LONG_WRITE" "### 创作记忆库输入" "### ")"
    review_memory_section="$(extract_section "$REVIEW" "### 创作记忆库输入" "### ")"
    deslop_memory_section="$(extract_section "$DESLOP" "### 创作记忆库输入" "### ")"

    assert_contains "$workflow_packet_section" "必填字段："
    assert_contains "$workflow_packet_section" "runtime_guard"
    assert_contains "$workflow_packet_section" "context_assembly"
    assert_contains "$workflow_packet_section" "context_assembly.required=false"
    assert_contains "$workflow_packet_section" "required"
    assert_contains "$workflow_packet_section" "script"
    assert_contains "$workflow_packet_section" "status"
    assert_contains "$workflow_packet_section" "packet_json"
    assert_contains "$workflow_packet_section" "packet_md"
    assert_contains "$workflow_packet_section" "selected_entry_count"
    assert_contains "$workflow_packet_section" "omitted_entry_count"
    assert_contains "$workflow_packet_section" "conflicts"

    assert_contains "$context_assembly_section" "story-memory-context.md"
    assert_contains "$context_assembly_section" "context-assembler.js"
    assert_contains "$context_assembly_section" "workflow_packet.context_assembly.packet_md"
    assert_contains "$context_assembly_section" "blocked_memory_conflict"
    assert_contains "$context_assembly_section" "memory-recommender.js"

    assert_contains "$long_write_memory_section" '如果 workflow packet 含 `context_assembly.packet_md`'
    assert_contains "$long_write_memory_section" 'assembled-context.md'
    assert_contains "$long_write_memory_section" "不得绕过 assembled context"
    assert_contains "$long_write_memory_section" "knowledge boundaries"

    assert_contains "$review_memory_section" 'workflow_packet.context_assembly.packet_md'
    assert_contains "$review_memory_section" 'assembled-context.md'
    assert_contains "$review_memory_section" "memory changes"
    assert_contains "$review_memory_section" "stale ranges"

    assert_contains "$deslop_memory_section" "assembled-context.md"
    assert_contains "$deslop_memory_section" "只作为当前文本的记忆锚点"
    assert_contains "$deslop_memory_section" "不得广泛加载无关 lore"
}

@test "longform packet contracts close read and result write boundaries" {
    PACKET_PROTOCOL="$REPO/src/internal-skills/story-workflow/references/completion-evidence-protocol.md"
    workflow_packet_section="$(extract_section "$PACKET_PROTOCOL" "## L2 到 L3 输入契约" "## ")"
    result_packet_section="$(extract_section "$PACKET_PROTOCOL" "## L3 到 L2 结果契约" "## ")"

    for field in lifecycle_node asset_target upstream_dependencies review_requirement memory_scope read_set write_set result_write_set; do
        assert_contains "$workflow_packet_section" "$field"
    done
    for field in asset_revision review_decision downstream_effects lifecycle_transition_request result_write_set; do
        assert_contains "$result_packet_section" "$field"
    done

    assert_contains "$workflow_packet_section" "封闭只读集合"
    assert_contains "$result_packet_section" '只能是 `write_set` 的子集'
    assert_contains "$result_packet_section" "不得自行推进生命周期"
}

@test "source workflow declares the progressive protocol surface without rebuilding bundle" {
    grep -q '"story-workflow"' "$REPO/config/novel-assistant-bundle-files.json"
    for protocol in \
        task-inbox-protocol.md \
        runner-execution-protocol.md \
        canonical-write-protocol.md \
        completion-evidence-protocol.md
    do
        workflow_has "$protocol"
        test -f "$(dirname "$WORKFLOW")/references/$protocol"
    done
}
