#!/usr/bin/env bats
# tests/test-chapter-handoff.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    SCRIPT="$REPO/scripts/chapter-handoff-pack.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "chapter handoff pack summarizes next-chapter continuity constraints" {
    [ -x "$SCRIPT" ]

    output="$(bash "$SCRIPT" "$FIXTURE" "001")"

    echo "$output" | grep -q "## Chapter Handoff Pack：第 001 章 -> 第 002 章"
    echo "$output" | grep -q "源正文：正文/第001章_拒绝错误任务.md"
    echo "$output" | grep -q "Gate: PASS"
    echo "$output" | grep -q "下一章读者期待：江临会如何追查旧账号。"
    echo "$output" | grep -q "异常水印"
    echo "$output" | grep -q "旧账号"
    echo "$output" | grep -q "江临"
    echo "$output" | grep -q "大纲/细纲_第002章.md"
    echo "$output" | grep -q "追踪/章节契约/第002章.md"
}

@test "chapter handoff pack writes stable artifact when requested" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"

    output="$(bash "$SCRIPT" --write "$tmp/book" "001")"
    handoff="$tmp/book/追踪/交接包/第001章_to_第002章.md"

    echo "$output" | grep -q "WROTE: 追踪/交接包/第001章_to_第002章.md"
    [ -f "$handoff" ]
    grep -q "Chapter Handoff Pack" "$handoff"
    grep -q "异常水印" "$handoff"

    rm -rf "$tmp"
}

@test "chapter handoff pack supports volume-local artifacts" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    mkdir -p "$tmp/book/正文/第1卷" "$tmp/book/追踪/章节契约/第1卷" "$tmp/book/追踪/漂移门控/第1卷"
    mv "$tmp/book/正文/第001章_拒绝错误任务.md" "$tmp/book/正文/第1卷/第001章_拒绝错误任务.md"
    mv "$tmp/book/追踪/章节契约/第001章.md" "$tmp/book/追踪/章节契约/第1卷/第001章.md"
    mv "$tmp/book/追踪/漂移门控/第001章.md" "$tmp/book/追踪/漂移门控/第1卷/第001章.md"

    output="$(bash "$SCRIPT" --write "$tmp/book" "001")"
    handoff="$tmp/book/追踪/交接包/第1卷/第001章_to_第002章.md"

    echo "$output" | grep -q "WROTE: 追踪/交接包/第1卷/第001章_to_第002章.md"
    [ -f "$handoff" ]
    grep -q "源正文：正文/第1卷/第001章_拒绝错误任务.md" "$handoff"
    grep -q "章节契约：追踪/章节契约/第1卷/第001章.md" "$handoff"

    rm -rf "$tmp"
}

@test "chapter handoff pack rejects failed plot drift gate" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    perl -0pi -e 's/Gate: PASS/Gate: FAIL/g' "$tmp/book/追踪/漂移门控/第001章.md"

    ! bash "$SCRIPT" "$tmp/book" "001" >/dev/null 2>&1

    rm -rf "$tmp"
}

@test "chapter handoff reference is wired into longform workflow and setup bundle" {
    reference="$LONG_WRITE/references/chapter-handoff-pack.md"
    setup_copy="$SETUP/references/agent-references/chapter-handoff-pack.md"

    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "scripts/chapter-handoff-pack.sh" "$reference"
    grep -q "Chapter Handoff Pack" "$LONG_WRITE/references/workflow-daily.md"
    grep -q "chapter-handoff-pack.md" "$LONG_WRITE/SKILL.md"
    cmp -s "$reference" "$setup_copy"
}
