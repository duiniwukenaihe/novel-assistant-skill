#!/usr/bin/env bats
# tests/test-stability-repair-dispatch.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    HANDOFF_SCRIPT="$REPO/scripts/chapter-handoff-pack.sh"
    DISPATCH_SCRIPT="$REPO/scripts/stability-repair-dispatch.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "stability repair dispatch reports no action for pass batch" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$DISPATCH_SCRIPT" "$tmp/book" "001" "002")"

    echo "$output" | grep -q "## Stability Repair Dispatch"
    echo "$output" | grep -q "审计状态：PASS"
    echo "$output" | grep -q "No repair actions required"
    echo "$output" | grep -q "追踪/稳定性审计/日更_第001章_to_第002章.md"

    rm -rf "$tmp"
}

@test "stability repair dispatch maps continuity failure to ordered repair action" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$DISPATCH_SCRIPT" "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "审计状态：FAIL"
    echo "$output" | grep -q "Continuity_Missing"
    echo "$output" | grep -q "第 001 章 -> 第 002 章"
    echo "$output" | grep -q "先修第 002 章 Chapter Contract"
    echo "$output" | grep -q "再修第 002 章正文"
    echo "$output" | grep -q "重跑 Cross Chapter Continuity Audit"

    rm -rf "$tmp"
}

@test "stability repair dispatch maps code-less chapter failure to generic stability action" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/江临追查旧账号/江临检查缓存/g' "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$DISPATCH_SCRIPT" "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Stability_Check_Failed"
    echo "$output" | grep -q "第 002 章"
    echo "$output" | grep -q "先对照审计报告 Diagnostics"
    echo "$output" | grep -q "重跑 Longform Daily Stability Audit"

    rm -rf "$tmp"
}

@test "stability repair dispatch routes character invariant failures to character designer" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    printf '\n江临已经提前知道委托人的真实目的。\n' >> "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$DISPATCH_SCRIPT" --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"code":"Knowledge_Leak"'
    echo "$output" | grep -q '"owner":"character-designer"'
    echo "$output" | grep -q "角色裁决"
    echo "$output" | grep -q "补获知过程"

    rm -rf "$tmp"
}

@test "stability repair dispatch writes repair report artifact" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$DISPATCH_SCRIPT" --write "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    report="$tmp/book/追踪/稳定性审计/修复清单_第001章_to_第002章.md"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "WROTE: 追踪/稳定性审计/修复清单_第001章_to_第002章.md"
    [ -f "$report" ]
    grep -q "Continuity_Missing" "$report"
    grep -q "修复队列" "$report"

    rm -rf "$tmp"
}

@test "stability repair dispatch emits machine readable json for pass batch" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$DISPATCH_SCRIPT" --json "$tmp/book" "001" "002")"

    echo "$output" | grep -q '"status":"PASS"'
    echo "$output" | grep -q '"failures":0'
    echo "$output" | grep -q '"actions":\[\]'
    echo "$output" | grep -q '"audit_report_path":"追踪/稳定性审计/日更_第001章_to_第002章.md"'
    ! echo "$output" | grep -q "## Stability Repair Dispatch"

    rm -rf "$tmp"
}

@test "stability repair dispatch emits machine readable json for fail batch" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$DISPATCH_SCRIPT" --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"FAIL"'
    echo "$output" | grep -q '"actions":\['
    echo "$output" | grep -q '"code":"Continuity_Missing"'
    echo "$output" | grep -q '"priority":"P1"'
    echo "$output" | grep -q '"target_chapter":"002"'
    echo "$output" | grep -q '"steps":\['
    ! echo "$output" | grep -q "修复队列"

    rm -rf "$tmp"
}

@test "stability repair dispatch json reports written repair artifact path" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$DISPATCH_SCRIPT" --write --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    report="$tmp/book/追踪/稳定性审计/修复清单_第001章_to_第002章.md"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"repair_report_path":"追踪/稳定性审计/修复清单_第001章_to_第002章.md"'
    [ -f "$report" ]
    ! echo "$output" | grep -q "WROTE:"

    rm -rf "$tmp"
}

@test "stability repair dispatcher reference is wired into workflow and setup bundle" {
    reference="$LONG_WRITE/references/stability-repair-dispatcher.md"
    setup_copy="$SETUP/references/agent-references/stability-repair-dispatcher.md"

    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "scripts/stability-repair-dispatch.sh" "$reference"
    grep -q -- "--json" "$reference"
    grep -q "actions" "$reference"
    grep -q "owner" "$reference"
    grep -q "character-designer" "$reference"
    grep -q "repair_report_path" "$reference"
    grep -q "Continuity_Missing" "$reference"
    grep -q "Stability Repair Dispatch" "$LONG_WRITE/references/workflow-daily.md"
    grep -q "stability-repair-dispatcher.md" "$LONG_WRITE/SKILL.md"
    cmp -s "$reference" "$setup_copy"
}
