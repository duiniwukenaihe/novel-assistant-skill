#!/usr/bin/env bats
# tests/test-upstream-20260628-delete-first.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "deslop workflows require delete-first triage before polishing" {
    DESLOP="$REPO/src/internal-skills/story-deslop/SKILL.md"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write/SKILL.md"
    SHORT_WRITE="$REPO/src/internal-skills/story-short-write/SKILL.md"

    grep -q "删除优先判断" "$DESLOP"
    grep -q "每条 AI 味项先判能否删除" "$DESLOP"
    grep -q "删后不丢伏笔/钩子/角色/情节/必要信息/必要转折" "$DESLOP"
    grep -q "删不掉的标记项按此润色" "$DESLOP"

    grep -q "删除优先" "$LONG_WRITE"
    grep -q "每条 AI 味项先判能否删除" "$LONG_WRITE"
    grep -q "必要信息/必要转折" "$LONG_WRITE"
    grep -q "删除优先" "$SHORT_WRITE"
    grep -q "每条 AI 味项先判能否删除" "$SHORT_WRITE"
    grep -q "必要信息/必要转折" "$SHORT_WRITE"
}

@test "single-directory bundles carry delete-first deslop protocol" {
    for file in \
        "$REPO/skills/novel-assistant/references/internal-skills/story-deslop/SKILL.md" \
        "$REPO/skills/novel-assistant/references/internal-skills/story-long-write/SKILL.md" \
        "$REPO/skills/novel-assistant/references/internal-skills/story-short-write/SKILL.md" \
        "$REPO/skills/novel-assistant/references/internal-skills/story-deslop/SKILL.md" \
        "$REPO/skills/novel-assistant/references/internal-skills/story-long-write/SKILL.md" \
        "$REPO/skills/novel-assistant/references/internal-skills/story-short-write/SKILL.md"
    do
        grep -q "删除优先" "$file"
    done
}
