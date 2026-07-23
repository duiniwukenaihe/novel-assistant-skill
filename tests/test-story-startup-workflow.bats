#!/usr/bin/env bats
# tests/test-story-startup-workflow.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    LONG_WRITE="$REPO/src/internal-skills/story-long-write/SKILL.md"
    STARTUP="$REPO/src/internal-skills/story-long-write/references/workflow-startup.md"
    BUNDLE_STARTUP="$REPO/skills/novel-assistant/references/internal-skills/story-long-write/references/workflow-startup.md"
}

@test "long-write references startup workflow for opening a new book" {
    grep -q "workflow-startup.md" "$LONG_WRITE"
    grep -q "新书启动" "$LONG_WRITE"
    grep -q "禁止裸写正文" "$LONG_WRITE"
}

@test "startup workflow gates opening before prose" {
    test -f "$STARTUP"
    grep -q "Project Readiness Gate" "$STARTUP"
    grep -q "Market Positioning Gate" "$STARTUP"
    grep -q "Character Relationship Gate" "$STARTUP"
    grep -q "Plot Engine Gate" "$STARTUP"
    grep -q "Macro Outline Gate" "$STARTUP"
    grep -q "Detailed Outline Gate" "$STARTUP"
    grep -q "Production Entry Gate" "$STARTUP"
    grep -q "前 10 章细纲" "$STARTUP"
    grep -q "Chapter Contract" "$STARTUP"
}

@test "startup workflow defines concrete artifacts" {
    grep -q "设定/题材定位.md" "$STARTUP"
    grep -q "设定/关系.md" "$STARTUP"
    grep -q "设定/角色不变量.md" "$STARTUP"
    grep -q "大纲/卷纲_第1卷.md" "$STARTUP"
    grep -q "大纲/细纲_第001章.md" "$STARTUP"
    grep -q "追踪/当前章节契约.md" "$STARTUP"
}

@test "oh-story bundle includes startup workflow" {
    test -f "$BUNDLE_STARTUP"
    cmp -s "$STARTUP" "$BUNDLE_STARTUP"
}
