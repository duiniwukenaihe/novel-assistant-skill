#!/usr/bin/env bats
# tests/test-user-style-learning.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
    BUNDLE="$REPO/skills/novel-assistant"
}

@test "story router recognizes user style learning intents" {
    grep -q "个人风格学习" "$ROUTER"
    grep -q "记住我的风格" "$ROUTER"
    grep -q "按我修改后的风格学习" "$ROUTER"
    grep -q "style-learner" "$ROUTER"
    grep -q "user-style-learning.md" "$ROUTER"
}

@test "long write owns user style learning protocol" {
    protocol="$LONG_WRITE/references/user-style-learning.md"
    [ -f "$protocol" ]
    grep -q "设定/作者风格/我的写作偏好.md" "$protocol"
    grep -q "追踪/schema/user-style-rules.jsonl" "$protocol"
    grep -q "硬约束" "$protocol"
    grep -q "软偏好" "$protocol"
    grep -q "单书设定" "$protocol"
    grep -q "style-learner" "$protocol"
    grep -q "不直接改正文" "$protocol"
}

@test "daily writing loads user style profile before narrative writer" {
    workflow="$LONG_WRITE/references/workflow-daily.md"
    skill="$LONG_WRITE/SKILL.md"
    grep -q "用户风格画像加载" "$workflow"
    grep -q "设定/作者风格/我的写作偏好.md" "$workflow"
    grep -q "user-style-rules.jsonl" "$workflow"
    grep -q "user_style_constraints" "$workflow"
    grep -q "用户风格画像加载" "$skill"
    grep -q "user-style-learning.md" "$skill"
}

@test "daily writing treats project style guide as authoritative before benchmark style" {
    workflow="$LONG_WRITE/references/workflow-daily.md"
    bundle_workflow="$BUNDLE/references/internal-skills/story-long-write/references/workflow-daily.md"
    grep -q "设定/文风.md" "$workflow"
    grep -q "本书自定义文风优先于对标文风" "$workflow"
    grep -q "project_style_constraints" "$workflow"
    grep -Eq "对标书缺少.*文风.md.*设定/文风.md" "$workflow"
    grep -q "设定/文风.md" "$bundle_workflow"
    grep -q "本书自定义文风优先于对标文风" "$bundle_workflow"
    grep -q "project_style_constraints" "$bundle_workflow"
}

@test "story setup deploys style learner agent and references" {
    agent="$SETUP/references/templates/agents/style-learner.md"
    [ -f "$agent" ]
    grep -q "^name: style-learner" "$agent"
    grep -q "设定/作者风格/我的写作偏好.md" "$agent"
    grep -q "追踪/schema/user-style-rules.jsonl" "$agent"
    grep -q "不直接改正文" "$agent"
    grep -q "style-learner.md" "$SETUP/SKILL.md"
    grep -q "user-style-learning.md" "$SETUP/SKILL.md"
    [ -f "$SETUP/references/agent-references/user-style-learning.md" ]
}

@test "narrative writer consumes user style constraints without overriding hard gates" {
    writer="$SETUP/references/templates/agents/narrative-writer.md"
    grep -q "用户风格画像" "$writer"
    grep -q "user_style_constraints" "$writer"
    grep -q "用户硬约束" "$writer"
    grep -q "正文门禁" "$writer"
    grep -q "不得突破" "$writer"
}

@test "single directory bundle carries user style learning assets" {
    test -f "$BUNDLE/references/internal-skills/story-long-write/references/user-style-learning.md"
    test -f "$BUNDLE/references/internal-skills/story-setup/references/templates/agents/style-learner.md"
    test -f "$BUNDLE/references/internal-skills/story-setup/references/agent-references/user-style-learning.md"
    grep -q "个人风格学习" "$BUNDLE/references/internal-skills/story/SKILL.md"
}
