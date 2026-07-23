#!/usr/bin/env bats
# tests/test-cross-chapter-continuity.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    HANDOFF_SCRIPT="$REPO/scripts/chapter-handoff-pack.sh"
    AUDIT_SCRIPT="$REPO/scripts/cross-chapter-continuity-audit.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "cross chapter continuity audit verifies handoff inheritance" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$AUDIT_SCRIPT" "$tmp/book" "001" "002")"

    echo "$output" | grep -q "## Cross Chapter Continuity Audit：第 001 章 -> 第 002 章"
    echo "$output" | grep -q "Audit: PASS"
    echo "$output" | grep -q "追踪/交接包/第001章_to_第002章.md"
    echo "$output" | grep -q "追踪/章节契约/第002章.md"
    echo "$output" | grep -q "正文/第002章_追查旧账号.md"
    echo "$output" | grep -q "异常水印"
    echo "$output" | grep -q "旧账号"
    echo "$output" | grep -q "江临"

    rm -rf "$tmp"
}

@test "cross chapter continuity audit rejects missing inherited clue" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    ! bash "$AUDIT_SCRIPT" "$tmp/book" "001" "002" >/dev/null 2>&1

    rm -rf "$tmp"
}

@test "cross chapter continuity audit supports volume-local handoff and contract" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    mkdir -p "$tmp/book/正文/第1卷" "$tmp/book/追踪/章节契约/第1卷" "$tmp/book/追踪/漂移门控/第1卷"
    mv "$tmp/book/正文/第001章_拒绝错误任务.md" "$tmp/book/正文/第1卷/第001章_拒绝错误任务.md"
    mv "$tmp/book/正文/第002章_追查旧账号.md" "$tmp/book/正文/第1卷/第002章_追查旧账号.md"
    mv "$tmp/book/追踪/章节契约/第001章.md" "$tmp/book/追踪/章节契约/第1卷/第001章.md"
    mv "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/追踪/章节契约/第1卷/第002章.md"
    mv "$tmp/book/追踪/漂移门控/第001章.md" "$tmp/book/追踪/漂移门控/第1卷/第001章.md"

    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    output="$(bash "$AUDIT_SCRIPT" "$tmp/book" "001" "002")"

    echo "$output" | grep -q "追踪/交接包/第1卷/第001章_to_第002章.md"
    echo "$output" | grep -q "追踪/章节契约/第1卷/第002章.md"
    echo "$output" | grep -q "正文/第1卷/第002章_追查旧账号.md"
    echo "$output" | grep -q "Audit: PASS"

    rm -rf "$tmp"
}

@test "cross chapter continuity reference is wired into longform workflow and setup bundle" {
    reference="$LONG_WRITE/references/cross-chapter-continuity-audit.md"
    setup_copy="$SETUP/references/agent-references/cross-chapter-continuity-audit.md"

    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "scripts/cross-chapter-continuity-audit.sh" "$reference"
    grep -q "Cross Chapter Continuity Audit" "$LONG_WRITE/references/workflow-daily.md"
    grep -q "cross-chapter-continuity-audit.md" "$LONG_WRITE/SKILL.md"
    cmp -s "$reference" "$setup_copy"
}
