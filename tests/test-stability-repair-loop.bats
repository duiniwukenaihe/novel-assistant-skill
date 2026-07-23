#!/usr/bin/env bats
# tests/test-stability-repair-loop.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    HANDOFF_SCRIPT="$REPO/scripts/chapter-handoff-pack.sh"
    LOOP_SCRIPT="$REPO/scripts/stability-repair-loop.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "stability repair loop exits cleanly when audit is already pass" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$LOOP_SCRIPT" "$tmp/book" "001" "002")"

    echo "$output" | grep -q "## Stability Repair Loop"
    echo "$output" | grep -q "闭环状态：PASS"
    echo "$output" | grep -q "No pending repair actions"
    echo "$output" | grep -q "追踪/稳定性审计/日更_第001章_to_第002章.md"

    rm -rf "$tmp"
}

@test "stability repair loop surfaces first checkpoint for failed audit" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$LOOP_SCRIPT" "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "闭环状态：NEEDS_REPAIR"
    echo "$output" | grep -q "当前 checkpoint：R1"
    echo "$output" | grep -q "Continuity_Missing"
    echo "$output" | grep -q "target_chapter: 002"
    echo "$output" | grep -q "bash scripts/cross-chapter-continuity-audit.sh"
    echo "$output" | grep -q "bash scripts/stability-repair-loop.sh"

    rm -rf "$tmp"
}

@test "stability repair loop writes checkpoint artifact" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$LOOP_SCRIPT" --write "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    report="$tmp/book/追踪/稳定性审计/修复闭环_第001章_to_第002章.md"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "WROTE: 追踪/稳定性审计/修复闭环_第001章_to_第002章.md"
    [ -f "$report" ]
    grep -q "当前 checkpoint：R1" "$report"
    grep -q "Continuity_Missing" "$report"

    rm -rf "$tmp"
}

@test "stability repair loop emits machine readable json checkpoint" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$LOOP_SCRIPT" --write --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    report="$tmp/book/追踪/稳定性审计/修复闭环_第001章_to_第002章.md"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"NEEDS_REPAIR"'
    echo "$output" | grep -q '"current_action"'
    echo "$output" | grep -q '"id":"R1"'
    echo "$output" | grep -q '"code":"Continuity_Missing"'
    echo "$output" | grep -q '"owner":"narrative-writer"'
    echo "$output" | grep -q '"current_owner":"narrative-writer"'
    echo "$output" | grep -q '"loop_report_path":"追踪/稳定性审计/修复闭环_第001章_to_第002章.md"'
    [ -f "$report" ]
    ! echo "$output" | grep -q "WROTE:"

    rm -rf "$tmp"
}

@test "stability repair loop exposes character checkpoint owner" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    printf '\n江临已经提前知道委托人的真实目的。\n' >> "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$LOOP_SCRIPT" --write --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    report="$tmp/book/追踪/稳定性审计/修复闭环_第001章_to_第002章.md"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"code":"Knowledge_Leak"'
    echo "$output" | grep -q '"owner":"character-designer"'
    echo "$output" | grep -q '"current_owner":"character-designer"'
    [ -f "$report" ]
    grep -q "owner: character-designer" "$report"

    rm -rf "$tmp"
}

@test "stability repair loop json includes volume for volume-local runs" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    mkdir -p "$tmp/book/正文/第2卷" "$tmp/book/大纲/第2卷" "$tmp/book/追踪/章节契约/第2卷" "$tmp/book/追踪/漂移门控/第2卷"
    mv "$tmp/book/正文/第001章_拒绝错误任务.md" "$tmp/book/正文/第2卷/"
    mv "$tmp/book/正文/第002章_追查旧账号.md" "$tmp/book/正文/第2卷/"
    mv "$tmp/book/大纲/细纲_第001章.md" "$tmp/book/大纲/第2卷/第001章.md"
    mv "$tmp/book/大纲/细纲_第002章.md" "$tmp/book/大纲/第2卷/第002章.md"
    mv "$tmp/book/追踪/章节契约/第001章.md" "$tmp/book/追踪/章节契约/第2卷/"
    mv "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/追踪/章节契约/第2卷/"
    mv "$tmp/book/追踪/漂移门控/第001章.md" "$tmp/book/追踪/漂移门控/第2卷/"
    mv "$tmp/book/追踪/漂移门控/第002章.md" "$tmp/book/追踪/漂移门控/第2卷/"
    bash "$HANDOFF_SCRIPT" --write --volume 第2卷 "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第2卷/第002章.md" "$tmp/book/正文/第2卷/第002章_追查旧账号.md"

    set +e
    output="$(bash "$LOOP_SCRIPT" --write --json --volume 第2卷 "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"NEEDS_REPAIR"'
    echo "$output" | grep -q '"volume":"第2卷"'
    echo "$output" | grep -q '"loop_report_path":"追踪/稳定性审计/第2卷/修复闭环_第001章_to_第002章.md"'
    echo "$output" | grep -q -- "--volume 第2卷"

    rm -rf "$tmp"
}

@test "stability repair loop reference is wired into workflow and setup bundle" {
    reference="$LONG_WRITE/references/stability-repair-loop.md"
    setup_copy="$SETUP/references/agent-references/stability-repair-loop.md"

    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "scripts/stability-repair-loop.sh" "$reference"
    grep -q "current_action" "$reference"
    grep -q "current_owner" "$reference"
    grep -q "character-designer" "$reference"
    grep -q "Stability Repair Loop" "$LONG_WRITE/references/workflow-daily.md"
    grep -q "stability-repair-loop.md" "$LONG_WRITE/SKILL.md"
    cmp -s "$reference" "$setup_copy"
}
