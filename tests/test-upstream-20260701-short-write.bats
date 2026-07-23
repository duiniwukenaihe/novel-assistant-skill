#!/usr/bin/env bats
# tests/test-upstream-20260701-short-write.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SHORT_WRITE="$REPO/src/internal-skills/story-short-write"
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    README="$REPO/README.md"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "short write uses short-story-specific references as primary workflow" {
    grep -q "references/short-format.md" "$SHORT_WRITE/SKILL.md"
    grep -q "references/short-craft.md" "$SHORT_WRITE/SKILL.md"
    grep -q "references/short-deslop.md" "$SHORT_WRITE/SKILL.md"
    grep -q "genre-styles/{题材}.md" "$SHORT_WRITE/SKILL.md"
    grep -q "短篇主线不得默认加载" "$SHORT_WRITE/SKILL.md"

    [ -f "$SHORT_WRITE/references/short-format.md" ]
    [ -f "$SHORT_WRITE/references/short-craft.md" ]
    [ -f "$SHORT_WRITE/references/short-deslop.md" ]
    [ -f "$SHORT_WRITE/references/genre-styles/追妻火葬场.md" ]
    [ -f "$SHORT_WRITE/references/genre-styles/复仇打脸.md" ]
    [ -f "$SHORT_WRITE/references/genre-styles/总裁豪门.md" ]
    [ -f "$SHORT_WRITE/references/genre-styles/宅斗宫斗.md" ]
}

@test "short write workflow avoids long-form anti-ai defaults" {
    grep -q "short-format.md" "$SHORT_WRITE/references/writing-workflow.md"
    grep -q "short-deslop.md" "$SHORT_WRITE/references/writing-workflow.md"
    grep -q "short-craft.md" "$SHORT_WRITE/references/writing-workflow.md"
    grep -q "short-deslop.md" "$SHORT_WRITE/references/output-contract.md"
    grep -q "short-craft.md" "$SHORT_WRITE/references/cross-book-recall.md"
}

@test "narrative writer keeps short-story emotion exception" {
    for writer in \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md"
    do
        grep -q "短篇题材包例外" "$writer"
        grep -q "short-craft.md" "$writer"
        grep -q "short-deslop.md" "$writer"
        grep -q "心如死灰" "$writer"
        grep -q "情绪词默认外化" "$writer"
    done
}

@test "upstream short write absorption is wired into global router and workflow" {
    grep -q "短篇写作路由补充" "$ROUTER"
    grep -q "short_format_path" "$ROUTER"
    grep -q "short_deslop_path" "$ROUTER"
    grep -q "短篇写作" "$WORKFLOW"
    grep -q "short_story_style_pack" "$WORKFLOW"
    grep -q "short_deslop_path" "$WORKFLOW"
    grep -q "上游吸收后的全局联动验收" "$README"
    grep -q "router / workflow / L3 contract / bundle" "$README"
}
