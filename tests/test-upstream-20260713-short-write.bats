#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SHORT_WRITE="$REPO/src/internal-skills/story-short-write"
    SHORT_ANALYZE="$REPO/src/internal-skills/story-short-analyze/SKILL.md"
}

@test "six clean-room genre cards follow one causal contract" {
    for name in 世情打脸 民俗怪谈 悬疑 甜宠 双男主 沙雕脑洞; do
        file="$SHORT_WRITE/references/genre-styles/$name.md"
        [ -f "$file" ]
        [ "$(wc -c < "$file" | tr -d ' ')" -lt 6144 ]
        for heading in 读者承诺 人物压力 因果引擎 节奏与钩子 反转与兑现 结尾契约 误用风险; do
            grep -q "^## $heading$" "$file"
        done
        ! grep -q '《' "$file"
    done
}

@test "short writing loads exactly one of ten primary genre cards" {
    grep -q '核心 10 题材' "$SHORT_WRITE/SKILL.md"
    grep -q '一次只加载 1 张题材卡' "$SHORT_WRITE/SKILL.md"
    grep -q 'submission-profile.md' "$SHORT_WRITE/SKILL.md"
    grep -q 'platform_genre_lock' "$SHORT_WRITE/references/writing-workflow.md"
}

@test "short analysis maps detected genres to stable card names" {
    for name in 世情打脸 民俗怪谈 悬疑 甜宠 双男主 沙雕脑洞; do
        grep -q "$name" "$SHORT_ANALYZE"
    done
    grep -q 'genre_card_id' "$SHORT_ANALYZE"
}

@test "selector exposes routes for all six new cards" {
    for name in 世情打脸 民俗怪谈 悬疑 甜宠 双男主 沙雕脑洞; do
        node "$REPO/scripts/short-writing-profile.js" --platform 番茄短篇 --genre "$name" --json |
            grep -q "references/genre-styles/$name.md"
    done
}
