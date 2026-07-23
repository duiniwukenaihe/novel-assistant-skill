#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SOURCE="$REPO/src/internal-skills/story-memory"
    BUNDLE="$REPO/skills/novel-assistant/references/internal-skills/story-memory"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    TOP="$REPO/skills/novel-assistant/SKILL.md"
}

@test "story-memory is a dedicated internal module with bounded responsibility" {
    test -f "$SOURCE/SKILL.md"
    grep -q "^name: story-memory" "$SOURCE/SKILL.md"
    grep -q "context-assembler.js" "$SOURCE/SKILL.md"
    grep -q "memory-recommender.js" "$SOURCE/SKILL.md"
    grep -q "追踪/memory/lorebook.jsonl" "$SOURCE/SKILL.md"
    grep -q "追踪/workflow/preference-memory.jsonl" "$SOURCE/SKILL.md"
    grep -q "追踪/private-short-extension/learning-ledger.jsonl" "$SOURCE/SKILL.md"
    grep -q "不写正文" "$SOURCE/SKILL.md"
    grep -q "不替代 story-workflow" "$SOURCE/SKILL.md"
    grep -q "不替代领域子 skill" "$SOURCE/SKILL.md"
}

@test "story-memory contract defines read write compact inject lifecycle" {
    test -f "$SOURCE/references/memory-contract.md"
    grep -q "read" "$SOURCE/references/memory-contract.md"
    grep -q "write" "$SOURCE/references/memory-contract.md"
    grep -q "compact" "$SOURCE/references/memory-contract.md"
    grep -q "inject" "$SOURCE/references/memory-contract.md"
    grep -q "用户确认" "$SOURCE/references/memory-contract.md"
    grep -q "高风险" "$SOURCE/references/memory-contract.md"
    grep -q "低风险新增" "$SOURCE/references/memory-contract.md"
    grep -q "blocked_memory_conflict" "$SOURCE/references/memory-contract.md"
    grep -q "blocked_output_pollution" "$SOURCE/references/memory-contract.md"
    grep -q -- "--source" "$SOURCE/references/memory-contract.md"
    grep -q "书目级写入租约" "$SOURCE/references/memory-contract.md"
    grep -q "显式运行.*memory-migrate.js" "$SOURCE/references/memory-contract.md"
}

@test "story-memory exposes visible learning status query" {
    grep -q -- "--status" "$SOURCE/SKILL.md"
    grep -q "我学到了什么" "$SOURCE/SKILL.md"
    grep -q "recentLearned" "$SOURCE/SKILL.md"
    grep -q "pendingConfirmations" "$SOURCE/SKILL.md"
    grep -q "nextEffects" "$SOURCE/SKILL.md"
    grep -q -- "--status" "$SOURCE/references/memory-contract.md"
    grep -q "可见状态" "$SOURCE/references/memory-contract.md"
}

@test "story-workflow delegates creative memory assembly to story-memory" {
    grep -q "story-memory" "$WORKFLOW"
    grep -q "references/internal-skills/story-memory/SKILL.md" "$WORKFLOW"
    grep -q "context-assembler.js" "$WORKFLOW"
    grep -q "memory-recommender.js" "$WORKFLOW"
}

@test "novel-assistant bundle includes story-memory internal skill" {
    test -f "$BUNDLE/SKILL.md"
    test -f "$BUNDLE/references/memory-contract.md"
    grep -q "^name: story-memory" "$BUNDLE/SKILL.md"
    grep -q "story-memory" "$TOP"
    grep -q "内部记忆模块" "$TOP"
}
