#!/usr/bin/env bats
# tests/test-upstream-20260628-backport.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "long-write documents benchmark rhythm migration and chapter positioning" {
    OUTLINE="$REPO/src/internal-skills/story-long-write/references/outline-structure-theory.md"
    SKILL="$REPO/src/internal-skills/story-long-write/SKILL.md"
    AGENT_REF="$REPO/src/internal-skills/story-setup/references/agent-references/outline-structure-theory.md"

    grep -q "对标节奏迁移" "$OUTLINE"
    grep -q "对标结构坐标" "$OUTLINE"
    grep -q "章节定位与张弛" "$OUTLINE"
    grep -q "低压生活章" "$OUTLINE"
    grep -q "禁情绪母题扎堆" "$OUTLINE"
    grep -q "按章节定位分层打磨" "$SKILL"
    grep -q "章节定位与张弛" "$AGENT_REF"
}

@test "long-write recalls one genre prose card and checks longform scene rhythm" {
    DAILY="$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"
    CARD="$REPO/src/internal-skills/story-long-write/references/genre-prose-cards.md"
    WRITER="$REPO/src/internal-skills/story-setup/references/templates/agents/narrative-writer.md"

    grep -q "单张题材正文卡" "$DAILY"
    grep -q "长篇节奏门" "$DAILY"
    grep -q "场景推进" "$DAILY"
    grep -q "按需题材正文卡" "$CARD"
    grep -q "不得把全文卡库注入" "$CARD"
    grep -q "题材正文卡" "$WRITER"
}
