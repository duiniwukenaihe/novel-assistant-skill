#!/usr/bin/env bats
# tests/test-upstream-20260624-backport.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    COVER="$REPO/src/internal-skills/story-cover/SKILL.md"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SHORT_WRITE="$REPO/src/internal-skills/story-short-write"
    REVIEW="$REPO/src/internal-skills/story-review"
    DESLOP="$REPO/src/internal-skills/story-deslop"
    SHORT_ANALYZE="$REPO/src/internal-skills/story-short-analyze"
    SETUP="$REPO/src/internal-skills/story-setup"
    BUNDLE="$REPO/skills/novel-assistant"
}

@test "cover skill absorbs author collection and platform upload crop fallback" {
    grep -q "作者名（笔名）缺失" "$COVER"
    grep -q "UPLOAD_SIZE" "$COVER"
    grep -q "600x800" "$COVER"
    grep -q "_上传.png" "$COVER"
}

@test "narrative writer checks style fingerprint and comma stutter drift" {
    for writer in \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md"
    do
        grep -q "文风指纹" "$writer"
        grep -q "目标句长带" "$writer"
        grep -q "逗号结巴体" "$writer"
        grep -q "写完后文风自检" "$writer"
    done
    grep -q "文风指纹" "$SETUP/references/templates/上下文.md.tmpl"
    grep -q "目标句长带" "$SETUP/references/templates/上下文.md.tmpl"
}

@test "dialogue mastery blocks mechanical science-mouth and wrong-occasion lines" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$LONG_WRITE/references/workflow-daily.md" \
        "$LONG_WRITE/references/dialogue-mastery.md" \
        "$SHORT_WRITE/references/dialogue-mastery.md" \
        "$REVIEW/SKILL.md" \
        "$REVIEW/references/dialogue-mastery.md" \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md" \
        "$SETUP/references/agent-references/dialogue-mastery.md"
    do
        grep -q "机械对话" "$file"
        grep -q "科普嘴" "$file"
        grep -q "不分场合" "$file"
    done
}

@test "writing and review skills validate exact word-count expressions" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$SHORT_WRITE/SKILL.md" \
        "$REVIEW/SKILL.md" \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md"
    do
        grep -q "具体字数表达校验" "$file"
        grep -q "这五个字" "$file"
        grep -q "这一句落下" "$file"
    done
}

@test "anti-ai references keep first-use anchors for new terms after Gate G cleanup" {
    for file in \
        "$LONG_WRITE/references/anti-ai-writing.md" \
        "$SHORT_WRITE/references/anti-ai-writing.md" \
        "$REVIEW/references/anti-ai-writing.md" \
        "$DESLOP/references/anti-ai-writing.md" \
        "$SHORT_ANALYZE/references/anti-ai-writing.md" \
        "$SETUP/references/agent-references/anti-ai-writing.md"
    do
        grep -q "新名词" "$file"
        grep -q "首次出现" "$file"
        grep -q "读者读懵" "$file"
    done
}

@test "single directory bundle carries selected upstream backports" {
    grep -q "UPLOAD_SIZE" "$BUNDLE/references/internal-skills/story-cover/SKILL.md"
    grep -q "文风指纹" "$BUNDLE/references/internal-skills/story-setup/references/templates/agents/narrative-writer.md"
    grep -q "机械对话" "$BUNDLE/references/internal-skills/story-long-write/references/dialogue-mastery.md"
    grep -q "具体字数表达校验" "$BUNDLE/references/internal-skills/story-long-write/SKILL.md"
    grep -q "读者读懵" "$BUNDLE/references/internal-skills/story-long-write/references/anti-ai-writing.md"
}
