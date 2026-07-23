#!/usr/bin/env bats
# tests/test-daily-stability-audit.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    HANDOFF_SCRIPT="$REPO/scripts/chapter-handoff-pack.sh"
    AUDIT_SCRIPT="$REPO/scripts/longform-daily-stability-audit.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "daily stability audit verifies a completed two-chapter batch" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$AUDIT_SCRIPT" "$tmp/book" "001" "002")"

    echo "$output" | grep -q "## Longform Daily Stability Audit"
    echo "$output" | grep -q "章节范围：第 001 章 - 第 002 章"
    echo "$output" | grep -q "Audit: PASS"
    echo "$output" | grep -q "第 001 章 | 单章稳定性 | PASS"
    echo "$output" | grep -q "第 002 章 | 单章稳定性 | PASS"
    echo "$output" | grep -q "第 001 章 -> 第 002 章 | 跨章连续性 | PASS"

    rm -rf "$tmp"
}

@test "daily stability audit rejects a broken inherited clue" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    ! bash "$AUDIT_SCRIPT" "$tmp/book" "001" "002" >/dev/null 2>&1

    rm -rf "$tmp"
}

@test "daily stability audit reports continuity failure diagnostics" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$AUDIT_SCRIPT" "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "### Diagnostics"
    echo "$output" | grep -q "第 001 章 -> 第 002 章"
    echo "$output" | grep -q "Continuity_Missing"
    echo "$output" | grep -q "旧账号"

    rm -rf "$tmp"
}

@test "daily stability audit reports single chapter failure diagnostics" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/江临追查旧账号/江临检查缓存/g' "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$AUDIT_SCRIPT" "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "### Diagnostics"
    echo "$output" | grep -q "第 002 章 | 单章稳定性"
    echo "$output" | grep -q "contract beat not found"
    echo "$output" | grep -q "江临追查旧账号"

    rm -rf "$tmp"
}

@test "daily stability audit writes pass report artifact" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$AUDIT_SCRIPT" --write "$tmp/book" "001" "002")"
    report="$tmp/book/追踪/稳定性审计/日更_第001章_to_第002章.md"

    echo "$output" | grep -q "WROTE: 追踪/稳定性审计/日更_第001章_to_第002章.md"
    [ -f "$report" ]
    grep -q "Audit: PASS" "$report"
    grep -q "第 001 章 -> 第 002 章 | 跨章连续性 | PASS" "$report"

    rm -rf "$tmp"
}

@test "daily stability audit supports volume-local batch artifacts" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    mkdir -p "$tmp/book/正文/第1卷" "$tmp/book/追踪/章节契约/第1卷" "$tmp/book/追踪/漂移门控/第1卷"
    mv "$tmp/book/正文/第001章_拒绝错误任务.md" "$tmp/book/正文/第1卷/第001章_拒绝错误任务.md"
    mv "$tmp/book/正文/第002章_追查旧账号.md" "$tmp/book/正文/第1卷/第002章_追查旧账号.md"
    mv "$tmp/book/追踪/章节契约/第001章.md" "$tmp/book/追踪/章节契约/第1卷/第001章.md"
    mv "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/追踪/章节契约/第1卷/第002章.md"
    mv "$tmp/book/追踪/漂移门控/第001章.md" "$tmp/book/追踪/漂移门控/第1卷/第001章.md"
    mv "$tmp/book/追踪/漂移门控/第002章.md" "$tmp/book/追踪/漂移门控/第1卷/第002章.md"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$AUDIT_SCRIPT" --write --volume 第1卷 "$tmp/book" "001" "002")"
    report="$tmp/book/追踪/稳定性审计/第1卷/日更_第001章_to_第002章.md"

    echo "$output" | grep -q "WROTE: 追踪/稳定性审计/第1卷/日更_第001章_to_第002章.md"
    [ -f "$report" ]
    grep -q "Audit: PASS" "$report"

    rm -rf "$tmp"
}

@test "daily stability audit writes fail report artifact with diagnostics" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$AUDIT_SCRIPT" --write "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    report="$tmp/book/追踪/稳定性审计/日更_第001章_to_第002章.md"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "WROTE: 追踪/稳定性审计/日更_第001章_to_第002章.md"
    [ -f "$report" ]
    grep -q "Audit: FAIL" "$report"
    grep -q "Diagnostics" "$report"
    grep -q "Continuity_Missing" "$report"
    grep -q "旧账号" "$report"

    rm -rf "$tmp"
}

@test "daily stability audit emits machine readable json for pass batch" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$AUDIT_SCRIPT" --json "$tmp/book" "001" "002")"

    echo "$output" | grep -q '"status":"PASS"'
    echo "$output" | grep -q '"failures":0'
    echo "$output" | grep -q '"start_chapter":"001"'
    echo "$output" | grep -q '"end_chapter":"002"'
    echo "$output" | grep -q '"scope":"第 001 章"'
    echo "$output" | grep -q '"check":"单章稳定性"'
    echo "$output" | grep -q '"scope":"第 001 章 -> 第 002 章"'
    ! echo "$output" | grep -q "## Longform Daily Stability Audit"

    rm -rf "$tmp"
}

@test "daily stability audit emits machine readable json for fail batch" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$AUDIT_SCRIPT" --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"FAIL"'
    echo "$output" | grep -q '"failures":1'
    echo "$output" | grep -q '"result":"FAIL"'
    echo "$output" | grep -q '"error_codes":\["Continuity_Missing"\]'
    ! echo "$output" | grep -q "### Diagnostics"

    rm -rf "$tmp"
}

@test "daily stability audit emits character invariant error codes" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    printf '\n江临已经提前知道委托人的真实目的。\n' >> "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$AUDIT_SCRIPT" --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"FAIL"'
    echo "$output" | grep -q '"error_codes":\["Knowledge_Leak"\]'

    rm -rf "$tmp"
}

@test "daily stability audit json reports written artifact path" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$AUDIT_SCRIPT" --write --json "$tmp/book" "001" "002")"
    report="$tmp/book/追踪/稳定性审计/日更_第001章_to_第002章.md"

    echo "$output" | grep -q '"status":"PASS"'
    echo "$output" | grep -q '"report_path":"追踪/稳定性审计/日更_第001章_to_第002章.md"'
    [ -f "$report" ]
    grep -q "Audit: PASS" "$report"
    ! echo "$output" | grep -q "WROTE:"

    rm -rf "$tmp"
}

@test "daily stability audit reference is wired into longform workflow and setup bundle" {
    reference="$LONG_WRITE/references/longform-daily-stability-audit.md"
    setup_copy="$SETUP/references/agent-references/longform-daily-stability-audit.md"

    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "scripts/longform-daily-stability-audit.sh" "$reference"
    grep -q -- "--write" "$reference"
    grep -q -- "--json" "$reference"
    grep -q "追踪/稳定性审计" "$reference"
    grep -q "scripts/chapter-stability-check.sh" "$reference"
    grep -q "Knowledge_Leak" "$reference"
    grep -q "Motivation_Drift" "$reference"
    grep -q "不能提前知道" "$reference"
    ! grep -q "scripts/check-longform-stability-fixture.sh" "$reference"
    grep -q "Longform Daily Stability Audit" "$LONG_WRITE/references/workflow-daily.md"
    grep -q "longform-daily-stability-audit.md" "$LONG_WRITE/SKILL.md"
    cmp -s "$reference" "$setup_copy"
}
