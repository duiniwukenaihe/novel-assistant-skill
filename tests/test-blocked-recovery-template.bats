#!/usr/bin/env bats
# tests/test-blocked-recovery-template.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/blocked-recovery-template.js"
    POLLUTION="$REPO/scripts/output-pollution-check.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "blocked recovery template emits clean model degradation reply" {
    node "$SCRIPT" --status blocked_model_degradation > "$TMP_DIR/reply.md"

    grep -q "已暂停：检测到输出健康异常" "$TMP_DIR/reply.md"
    grep -q "为什么暂停" "$TMP_DIR/reply.md"
    grep -q "推荐选 1" "$TMP_DIR/reply.md"
    grep -q "回复 1/2/3/4" "$TMP_DIR/reply.md"
    grep -q "不要只回复“继续”" "$TMP_DIR/reply.md"
    grep -q "缩小范围继续" "$TMP_DIR/reply.md"
    ! grep -q "修真修真" "$TMP_DIR/reply.md"
    ! grep -q "修真SSOT" "$TMP_DIR/reply.md"
    node "$POLLUTION" "$TMP_DIR/reply.md"
}

@test "blocked recovery template emits clean tool contamination reply" {
    node "$SCRIPT" --status blocked_tool_command_contaminated > "$TMP_DIR/reply.md"

    grep -q "已暂停：检测到工具调用污染" "$TMP_DIR/reply.md"
    grep -q "自动重建一次干净调用" "$TMP_DIR/reply.md"
    ! grep -q "+deployed_at" "$TMP_DIR/reply.md"
    ! grep -q "Thought for" "$TMP_DIR/reply.md"
    node "$POLLUTION" "$TMP_DIR/reply.md"
}

@test "story-workflow requires deterministic blocked recovery template" {
    grep -q "blocked-recovery-template.js" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "禁止自由生成 blocked 状态长回复" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "blocked_model_degradation" "$REPO/src/internal-skills/story-workflow/SKILL.md"
}
