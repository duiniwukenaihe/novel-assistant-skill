#!/usr/bin/env bats
# tests/test-prose-output-gates.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SHORT_WRITE="$REPO/src/internal-skills/story-short-write"
    DESLOP="$REPO/src/internal-skills/story-deslop"
    SETUP="$REPO/src/internal-skills/story-setup"
    PROSE_HOOK="$SETUP/references/templates/hooks/prose-quality-gate.sh"
}

@test "all body prose entrypoints allow controlled dash use and block corruption" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$LONG_WRITE/references/workflow-daily.md" \
        "$LONG_WRITE/references/workflow-revision.md" \
        "$SHORT_WRITE/SKILL.md" \
        "$SHORT_WRITE/references/writing-workflow.md" \
        "$SHORT_WRITE/references/format-and-structure.md" \
        "$DESLOP/SKILL.md" \
        "$DESLOP/references/anti-ai-writing.md" \
        "$SETUP/references/templates/agents/narrative-writer.md"
    do
        grep -q "破折号密度" "$file"
        grep -Eq "合理少量|少量.*功能|有功能" "$file"
        grep -q "逐字破折号化" "$file"
        grep -q "必须回炉重写" "$file"
    done
}

@test "all body prose workflows require deterministic punctuation cleanup" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$LONG_WRITE/references/workflow-daily.md" \
        "$LONG_WRITE/references/workflow-revision.md" \
        "$SHORT_WRITE/SKILL.md" \
        "$SHORT_WRITE/references/writing-workflow.md" \
        "$DESLOP/SKILL.md" \
        "$SETUP/references/templates/agents/narrative-writer.md"
    do
        grep -q "normalize-punctuation.js" "$file"
    done
}

@test "all body prose workflows require deterministic AI pattern rescan" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$LONG_WRITE/references/workflow-daily.md" \
        "$LONG_WRITE/references/workflow-revision.md" \
        "$SHORT_WRITE/SKILL.md" \
        "$SHORT_WRITE/references/writing-workflow.md" \
        "$DESLOP/SKILL.md" \
        "$SETUP/references/templates/agents/narrative-writer.md"
    do
        grep -q "check-ai-patterns.js" "$file"
        grep -Eq "先否定再肯定|否定铺垫" "$file"
        grep -Eq "复扫到 0|复扫.*0|0 处残留" "$file"
    done
}

@test "all body prose entrypoints treat dash overuse as AI flavor" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$LONG_WRITE/references/workflow-daily.md" \
        "$LONG_WRITE/references/workflow-revision.md" \
        "$SHORT_WRITE/SKILL.md" \
        "$SHORT_WRITE/references/writing-workflow.md" \
        "$DESLOP/SKILL.md" \
        "$DESLOP/references/anti-ai-writing.md" \
        "$SETUP/references/templates/agents/narrative-writer.md"
    do
        grep -Eq "AI味|AI 味" "$file"
        grep -Eq "——|—|--" "$file"
    done
}

@test "deslop and narrative writer preserve narrative facts while cleaning prose" {
    for file in \
        "$DESLOP/SKILL.md" \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md"
    do
        grep -q "只能改文字表达" "$file"
        grep -q "不能改变事实、钩子、人物状态" "$file"
        grep -q "不能改变.*因果链" "$file"
        grep -q "升级为回炉" "$file"
    done
}

@test "short writing has compact narrative continuity gates" {
    grep -q "短篇内部连续性硬门" "$SHORT_WRITE/SKILL.md"
    grep -q "短篇内部因果" "$SHORT_WRITE/SKILL.md"
    grep -q "反转铺垫" "$SHORT_WRITE/SKILL.md"
    grep -q "人物/关系变化" "$SHORT_WRITE/SKILL.md"
    grep -q "不能只看情绪强度或文风" "$SHORT_WRITE/SKILL.md"
}

@test "body prose generation controls AI flavor during drafting instead of only after cleanup" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$SHORT_WRITE/SKILL.md" \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md"
    do
        grep -q "写中防 AI 味执行包" "$file"
        grep -q "POV 锚定" "$file"
        grep -q "动作/物件承载情绪" "$file"
        grep -q "对话承接" "$file"
        grep -q "句式去模板化" "$file"
        grep -q "逐段扫" "$file"
        grep -q "不要等成稿后再去 AI 味" "$file"
    done
}

@test "story-setup deploys a PostToolUse prose quality gate hook" {
    [ -x "$PROSE_HOOK" ]
    grep -q "prose-quality-gate.sh" "$SETUP/references/templates/settings-hooks.json"
    grep -q '"matcher": "Write|Edit|MultiEdit"' "$SETUP/references/templates/settings-hooks.json"
    grep -q "story-prose-gate.js" "$PROSE_HOOK"
    grep -q "逐字破折号化" "$PROSE_HOOK"
    grep -q "正文工程词泄露" "$PROSE_HOOK"
    grep -q "只对正文成稿文件" "$SETUP/SKILL.md"
    grep -q "审查报告、workflow 断点、下一步候选不走正文门禁" "$SETUP/SKILL.md"
}

@test "chapter text stats handles heading on first line" {
    tmp="$(mktemp -d)"
    target="$tmp/第003章.md"
    printf '## 第七百二十三章 念念誓言\n\n凡间。\n苏念念立誓。\n（本章完）\n后记不计入正文\n' > "$target"

    output="$(node "$REPO/scripts/chapter-text-stats.js" "$target" --json)"

    echo "$output" | grep -q '"cjk_chars": 7'
    echo "$output" | grep -q '"em_dash": 0'
    echo "$output" | grep -q '"ellipsis": 0'
    ! echo "$output" | grep -q '后记'

    rm -rf "$tmp"
}

@test "chapter text stats handles short story section headings on first line" {
    tmp="$(mktemp -d)"
    target="$tmp/正文.md"
    printf '###1. 开场\n\n她推门。\n灯灭了。\n###2. 反转\n\n他回头。\n刀落下。\n' > "$target"

    output="$(node "$REPO/scripts/chapter-text-stats.js" "$target" --json --sections)"

    echo "$output" | grep -q '"heading": "###1. 开场"'
    echo "$output" | grep -q '"heading": "###2. 反转"'
    echo "$output" | grep -q '"lines": 2'
    echo "$output" | grep -q '"cjk_chars": 16'

    rm -rf "$tmp"
}

@test "long write uses chapter text stats instead of brittle title split" {
    grep -q "chapter-text-stats.js" "$LONG_WRITE/SKILL.md"
    grep -q "不得临时写.*split" "$LONG_WRITE/SKILL.md"
    grep -q "标题可能在文件第一行" "$LONG_WRITE/SKILL.md"
}

@test "prose workflows do not prefer ad hoc Python or title split stats" {
    for file in \
        "$LONG_WRITE/SKILL.md" \
        "$LONG_WRITE/references/workflow-daily.md" \
        "$SHORT_WRITE/SKILL.md" \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md"
    do
        grep -q "chapter-text-stats.js" "$file"
        ! grep -q "优先使用跨平台 Python 字符统计" "$file"
        ! grep -q "优先使用 Python 字符统计" "$file"
    done
}

@test "prose quality gate blocks per-character dash corruption from hook JSON" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/正文/第1卷"
    cp "$REPO/scripts/story-prose-gate.js" "$tmp/scripts/story-prose-gate.js"
    target="$tmp/正文/第1卷/第001章_坏稿.md"
    printf '## 第1章 坏稿\n\n陈——洛——的——脑——子——御——兽——宗——\n' > "$target"

    out="$(printf '{"tool_input":{"file_path":"%s"}}' "$target" | CLAUDE_PROJECT_DIR="$tmp" bash "$PROSE_HOOK" 2>&1 || true)"
    echo "$out" | grep -q "逐字破折号化"

    rm -rf "$tmp"
}

@test "prose quality gate blocks writing workflow terms from hook JSON" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/正文/第1卷"
    cp "$REPO/scripts/story-prose-gate.js" "$tmp/scripts/story-prose-gate.js"
    target="$tmp/正文/第1卷/第001章_坏稿.md"
    printf '## 第1章 坏稿\n\n沈七说：“该到下一章了，本章任务已经完成。”\n' > "$target"

    out="$(printf '{"tool_input":{"file_path":"%s"}}' "$target" | CLAUDE_PROJECT_DIR="$tmp" bash "$PROSE_HOOK" 2>&1 || true)"
    echo "$out" | grep -q "prose-meta-leak"
    echo "$out" | grep -q "正文工程词泄露"

    rm -rf "$tmp"
}

@test "prose quality gate supports manual file path debugging" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/正文/第1卷"
    cp "$REPO/scripts/story-prose-gate.js" "$tmp/scripts/story-prose-gate.js"
    target="$tmp/正文/第1卷/第001章_坏稿.md"
    printf '## 第1章 坏稿\n\n陈——洛——的——脑——子——御——兽——宗——\n' > "$target"

    out="$(CLAUDE_PROJECT_DIR="$tmp" bash "$PROSE_HOOK" "$target" 2>&1 || true)"
    echo "$out" | grep -q "逐字破折号化"

    rm -rf "$tmp"
}

@test "prose quality gate allows non-prose files" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/设定"
    cp "$REPO/scripts/story-prose-gate.js" "$tmp/scripts/story-prose-gate.js"
    target="$tmp/设定/世界观.md"
    printf '设定——说明\n' > "$target"

    printf '{"tool_input":{"file_path":"%s"}}' "$target" | CLAUDE_PROJECT_DIR="$tmp" bash "$PROSE_HOOK"

    rm -rf "$tmp"
}

@test "prose quality gate does not block workflow or review notes" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/scripts" "$tmp/追踪/workflow" "$tmp/追踪/审查报告"
    cp "$REPO/scripts/story-prose-gate.js" "$tmp/scripts/story-prose-gate.js"

    workflow="$tmp/追踪/workflow/current-task.md"
    report="$tmp/追踪/审查报告/第001章.md"
    printf '下一步候选：回复继续可写下一章。\n本章任务描述需要回到细纲节点复核。\n' > "$workflow"
    printf '# 第001章 审查报告\n\n本章任务描述需要回到细纲节点复核。\n' > "$report"

    printf '{"tool_input":{"file_path":"%s"}}' "$workflow" | CLAUDE_PROJECT_DIR="$tmp" bash "$PROSE_HOOK"
    printf '{"tool_input":{"file_path":"%s"}}' "$report" | CLAUDE_PROJECT_DIR="$tmp" bash "$PROSE_HOOK"

    rm -rf "$tmp"
}
