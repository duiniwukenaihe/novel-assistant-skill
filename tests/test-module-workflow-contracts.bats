#!/usr/bin/env bats
# tests/test-module-workflow-contracts.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    WORKFLOW_CONTRACT="$REPO/src/internal-skills/story-workflow/references/workflow-contract.md"
    COMPLETION_PROTOCOL="$REPO/src/internal-skills/story-workflow/references/completion-evidence-protocol.md"
    LONG_ANALYZE="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write/SKILL.md"
    SHORT_WRITE="$REPO/src/internal-skills/story-short-write/SKILL.md"
    REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
    DESLOP="$REPO/src/internal-skills/story-deslop/SKILL.md"
    SHORT_ANALYZE="$REPO/src/internal-skills/story-short-analyze/SKILL.md"
    PRIVATE_SHORT="$REPO/src/private-internal-skills/private-short-extension/SKILL.md"
    README="$REPO/README.md"
    BUNDLE_NOVEL="$REPO/skills/novel-assistant"
}

@test "cover generation and overwrite require durable workflow confirmation context" {
    for file in \
        "$REPO/src/internal-skills/story-cover/SKILL.md" \
        "$REPO/skills/novel-assistant/references/internal-skills/story-cover/SKILL.md"; do
        grep -q 'confirmation_context' "$file"
        grep -q 'confirmation_token' "$file"
        grep -q 'blocked_confirmation_required' "$file"
        grep -q '裸调用' "$file"
        grep -q '生成新封面' "$file"
        grep -q '覆盖现有封面' "$file"
    done
}

@test "story-workflow defines L2 to L3 workflow packet fields" {
    grep -q "L2 到 L3 输入契约" "$COMPLETION_PROTOCOL"
    grep -q "workflow packet" "$WORKFLOW_CONTRACT"
    for field in workflow_id workflow_type book_root user_goal scope completion_policy current_stage current_step owner_module read_set write_set result_write_set risk_level requires_user_confirm completion_condition verification next_candidates memory_paths lifecycle_node asset_target upstream_dependencies review_requirement memory_scope; do
        grep -q "$field" "$COMPLETION_PROTOCOL"
    done
}

@test "story-workflow packet carries long task runtime guard fields" {
    grep -q "runtime_guard" "$WORKFLOW_CONTRACT"
    for field in token_estimate adaptive_budget_policy heartbeat checkpoint_policy output_health_gate max_retry_budget stall_policy; do
        grep -q "$field" "$WORKFLOW_CONTRACT"
    done
    grep -q "长任务和全局任务必须填写 runtime_guard" "$COMPLETION_PROTOCOL"
}

@test "story-workflow defines L3 to L2 result packet fields" {
    grep -q "L3 到 L2 结果契约" "$COMPLETION_PROTOCOL"
    grep -q "result packet" "$WORKFLOW_CONTRACT"
    for field in workflow_id stage_id step_id owner_module step_status outputs changed_files evidence verification_result blocking_reason next_recommendation handoff_summary memory_updates asset_revision review_decision downstream_effects lifecycle_transition_request; do
        grep -q "$field" "$COMPLETION_PROTOCOL"
    done
    grep -q "模块不能自行宣布整个 workflow 完成" "$COMPLETION_PROTOCOL"
}

@test "longform professional modules use bounded packets through story-workflow only" {
    MEMORY="$REPO/src/internal-skills/story-memory/SKILL.md"

    for file in "$LONG_WRITE" "$REVIEW" "$MEMORY"; do
        grep -q "仅由 .*story-workflow" "$file"
        grep -q "read_set" "$file"
        grep -q "result_write_set" "$file"
        grep -q "asset_revision" "$file"
        grep -q "review_decision" "$file"
        grep -q "downstream_effects" "$file"
        grep -q "lifecycle_transition_request" "$file"
        grep -q "不得让用户直接调用内部.*story-" "$file"
    done
}

@test "story-workflow result packet reports checkpoint and output health" {
    for field in checkpoint_state heartbeat_update budget_usage output_health_result handoff_packet_path resume_hint; do
        grep -q "$field" "$COMPLETION_PROTOCOL"
    done
    grep -q "专业模块必须回传 checkpoint_state" "$COMPLETION_PROTOCOL"
}

@test "high risk professional modules declare L3 workflow contracts" {
    for file in "$LONG_ANALYZE" "$LONG_WRITE" "$SHORT_WRITE" "$REVIEW" "$DESLOP"; do
        grep -q "## L3 Workflow Contract" "$file"
        grep -q "Inputs From story-workflow" "$file"
        grep -q "Outputs To story-workflow" "$file"
        grep -q "Completion Conditions" "$file"
        grep -q "Blocking States" "$file"
    done
}

@test "long analyze contract reports batch grounding and generated assets" {
    grep -q "source-grounding" "$LONG_ANALYZE"
    grep -q "batch progress" "$LONG_ANALYZE"
    grep -q "failed chapters" "$LONG_ANALYZE"
    grep -q "generated asset paths" "$LONG_ANALYZE"
    grep -q "completed_with_errors" "$LONG_ANALYZE"
}

@test "long write contract reports changed files and preserves titles" {
    grep -q "changed_files" "$LONG_WRITE"
    grep -q "chapter title preservation" "$LONG_WRITE"
    grep -q "已确认章节标题" "$LONG_WRITE"
    grep -q "useful existing content" "$LONG_WRITE"
    grep -q "verification_result" "$LONG_WRITE"
}

@test "long write docks bare calls at detailed outline and blocks underfilled briefs" {
    grep -q "裸调用停靠" "$LONG_WRITE"
    grep -q "outline_underfilled" "$LONG_WRITE"
    grep -q "不自动补写新剧情" "$LONG_WRITE"
    grep -q "单轮正文上限" "$LONG_WRITE"
    grep -q "最多 3 章" "$LONG_WRITE"
    grep -q "逐章 Brief" "$LONG_WRITE"
    grep -q "每节 Brief" "$LONG_WRITE"
}

@test "review contract returns findings gaps and repair request to workflow" {
    grep -q "reviewed range" "$REVIEW"
    grep -q "unreviewed gaps" "$REVIEW"
    grep -q "findings by severity" "$REVIEW"
    grep -q "repair queue recommendation" "$REVIEW"
    grep -q 'request repair through `story-workflow`' "$REVIEW"
}

@test "deslop contract is prose only and escalates fact changes" {
    grep -q "prose-only" "$DESLOP"
    grep -q "fact preservation" "$DESLOP"
    grep -q "AI-pattern scan" "$DESLOP"
    grep -q "story-long-write" "$DESLOP"
    grep -q "叙事事实" "$DESLOP"
}

@test "short write contract carries short-specific workflow context" {
    grep -q "workflow_type=short_write" "$SHORT_WRITE"
    grep -q "short_revision" "$SHORT_WRITE"
    grep -q "short_deslop" "$SHORT_WRITE"
    grep -q "genre_style_pack" "$SHORT_WRITE"
    grep -q "short_format_path" "$SHORT_WRITE"
    grep -q "short_craft_path" "$SHORT_WRITE"
    grep -q "short_deslop_path" "$SHORT_WRITE"
    grep -q "benchmark_paths" "$SHORT_WRITE"
    grep -q "deconstruction_meta" "$SHORT_WRITE"
    grep -q "正文.md" "$SHORT_WRITE"
    grep -q "小节大纲.md" "$SHORT_WRITE"
    grep -q "output_health_result" "$SHORT_WRITE"
    grep -q "platform_genre_lock" "$SHORT_WRITE"
    grep -q "submission-profile.md" "$SHORT_WRITE"
}

@test "creative modules return accepted learning through workflow packets" {
    for file in "$LONG_ANALYZE" "$LONG_WRITE" "$SHORT_WRITE" "$SHORT_ANALYZE" "$REVIEW" "$DESLOP"; do
        grep -q "memory_updates" "$file"
        grep -q "story-workflow" "$file"
        grep -q "确认" "$file"
    done
}

@test "professional modules cannot bypass workflow to write memory" {
    for file in "$LONG_ANALYZE" "$LONG_WRITE" "$SHORT_WRITE" "$SHORT_ANALYZE" "$REVIEW" "$DESLOP"; do
        ! grep -q 'node scripts/memory-recommender.js' "$file"
        grep -q "memory_updates" "$file"
    done
    grep -q "runner.*统一调用.*memory-recommender.js" "$WORKFLOW"
}

@test "private short forge reports learning memory without leaking private routes into public contract" {
    test -f "$PRIVATE_SHORT"
    grep -q "memory_updates" "$PRIVATE_SHORT"
    grep -q "story-memory" "$PRIVATE_SHORT"
    grep -q "learning-ledger.jsonl" "$PRIVATE_SHORT"
    grep -q "platform_genre_lock" "$PRIVATE_SHORT"
    grep -q "result packet" "$PRIVATE_SHORT"
}

@test "story-workflow routes short writing with short-specific packet fields" {
    grep -q "Short-form writing" "$WORKFLOW_CONTRACT"
    grep -q "story-short-write" "$WORKFLOW_CONTRACT"
    grep -q "short_story_style_pack" "$COMPLETION_PROTOCOL"
    grep -q "genre_style_pack" "$COMPLETION_PROTOCOL"
    grep -q "short_format_path" "$COMPLETION_PROTOCOL"
    grep -q "short_craft_path" "$COMPLETION_PROTOCOL"
    grep -q "short_deslop_path" "$COMPLETION_PROTOCOL"
    grep -q "Chapter Contract.*short stories" "$WORKFLOW_CONTRACT"
    grep -q "短篇去 AI 味" "$COMPLETION_PROTOCOL"
}

@test "README keeps workflow memory documentation discoverable without duplicating runtime schemas" {
    grep -q "Workflow 完整协议" "$README"
    grep -q "Workflow / Memory 边界" "$README"
    grep -q "工作流" "$README"
    grep -q "记忆" "$README"
}

@test "progressive workflow references explain runtime guard fields for long unattended tasks" {
    grep -q "runtime_guard" "$WORKFLOW_CONTRACT"
    grep -q "token_estimate" "$COMPLETION_PROTOCOL"
    grep -q "adaptive_budget_policy" "$COMPLETION_PROTOCOL"
    grep -q "heartbeat" "$COMPLETION_PROTOCOL"
    grep -q "checkpoint_policy" "$COMPLETION_PROTOCOL"
    grep -q "output_health_gate" "$COMPLETION_PROTOCOL"
    grep -q "checkpoint_state" "$COMPLETION_PROTOCOL"
    grep -q "heartbeat_update" "$COMPLETION_PROTOCOL"
    grep -q "budget_usage" "$COMPLETION_PROTOCOL"
    grep -q "output_health_result" "$COMPLETION_PROTOCOL"
    grep -q "resume_hint" "$COMPLETION_PROTOCOL"
    grep -q "用户说.*继续.*checkpoint" "$COMPLETION_PROTOCOL"
}

@test "bundles include module workflow contracts" {
    for bundle in "$BUNDLE_NOVEL"; do
        grep -q "workflow-contract.md" "$bundle/references/internal-skills/story-workflow/SKILL.md"
        grep -q "L2 到 L3 输入契约" "$bundle/references/internal-skills/story-workflow/references/completion-evidence-protocol.md"
        grep -q "runtime_guard" "$bundle/references/internal-skills/story-workflow/references/workflow-contract.md"
        grep -q "checkpoint_state" "$bundle/references/internal-skills/story-workflow/references/completion-evidence-protocol.md"
        grep -q "## L3 Workflow Contract" "$bundle/references/internal-skills/story-long-analyze/SKILL.md"
        grep -q "## L3 Workflow Contract" "$bundle/references/internal-skills/story-long-write/SKILL.md"
        grep -q "## L3 Workflow Contract" "$bundle/references/internal-skills/story-short-write/SKILL.md"
        grep -q "short_deslop_path" "$bundle/references/internal-skills/story-short-write/SKILL.md"
        grep -q "## L3 Workflow Contract" "$bundle/references/internal-skills/story-review/SKILL.md"
        grep -q "## L3 Workflow Contract" "$bundle/references/internal-skills/story-deslop/SKILL.md"
    done
}
