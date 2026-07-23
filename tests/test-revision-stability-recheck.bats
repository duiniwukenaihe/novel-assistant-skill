#!/usr/bin/env bats
# tests/test-revision-stability-recheck.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    HANDOFF_SCRIPT="$REPO/scripts/chapter-handoff-pack.sh"
    RECHECK_SCRIPT="$REPO/scripts/revision-stability-recheck.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "revision stability recheck reports impact and pass loop after rewrite" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$RECHECK_SCRIPT" "$tmp/book" "$tmp/book/修订请求/删除异常水印.md" "001" "002")"

    echo "$output" | grep -q "## Revision Stability Recheck"
    echo "$output" | grep -q "Revision Impact Analysis"
    echo "$output" | grep -q "修改对象：正文/第001章_拒绝错误任务.md"
    echo "$output" | grep -q "## Stability Repair Loop"
    echo "$output" | grep -q "闭环状态：PASS"
    echo "$output" | grep -q "No pending agent prompt"

    rm -rf "$tmp"
}

@test "revision stability recheck emits agent prompt for failed rewrite checkpoint" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$RECHECK_SCRIPT" "$tmp/book" "$tmp/book/修订请求/删除异常水印.md" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "## Revision Stability Recheck"
    echo "$output" | grep -q "闭环状态：NEEDS_REPAIR"
    echo "$output" | grep -q 'Agent(subagent_type: "narrative-writer"'
    echo "$output" | grep -q "current_owner：narrative-writer"
    echo "$output" | grep -q "Continuity_Missing"

    rm -rf "$tmp"
}

@test "revision stability recheck writes post revision report artifact" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$RECHECK_SCRIPT" --write "$tmp/book" "$tmp/book/修订请求/删除异常水印.md" "001" "002")"
    report="$tmp/book/追踪/稳定性审计/回炉复检_第001章_to_第002章.md"

    echo "$output" | grep -q "WROTE: 追踪/稳定性审计/回炉复检_第001章_to_第002章.md"
    [ -f "$report" ]
    grep -q "## Revision Stability Recheck" "$report"
    grep -q "Revision Impact Analysis" "$report"
    grep -q "## Stability Repair Loop" "$report"

    rm -rf "$tmp"
}

@test "revision stability recheck emits json bundle for automation" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$RECHECK_SCRIPT" --json "$tmp/book" "$tmp/book/修订请求/删除异常水印.md" "001" "002")"

    echo "$output" | grep -q '"status":"PASS"'
    echo "$output" | grep -q '"impact_report"'
    echo "$output" | grep -q '"agent_call":""'
    echo "$output" | grep -q '"revision_report_path":null'
    ! echo "$output" | grep -q "## Revision Stability Recheck"

    rm -rf "$tmp"
}

@test "revision stability recheck supports volume-local artifacts and report" {
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

    output="$(bash "$RECHECK_SCRIPT" --write --json --volume 第2卷 "$tmp/book" "$tmp/book/修订请求/删除异常水印.md" "001" "002")"
    report="$tmp/book/追踪/稳定性审计/第2卷/回炉复检_第001章_to_第002章.md"

    echo "$output" | grep -q '"status":"PASS"'
    echo "$output" | grep -q '"volume":"第2卷"'
    echo "$output" | grep -q '"revision_report_path":"追踪/稳定性审计/第2卷/回炉复检_第001章_to_第002章.md"'
    [ -f "$report" ]
    grep -q "## Revision Stability Recheck" "$report"

    rm -rf "$tmp"
}

@test "revision stability recheck is documented in revision workflow and setup bundle" {
    reference="$LONG_WRITE/references/revision-impact-analysis.md"
    setup_copy="$SETUP/references/agent-references/revision-impact-analysis.md"

    [ -x "$RECHECK_SCRIPT" ]
    grep -q "scripts/revision-stability-recheck.sh" "$reference"
    grep -q -- "--volume 第X卷" "$reference"
    grep -q "scripts/revision-stability-recheck.sh" "$setup_copy"
    grep -q -- "--volume 第X卷" "$setup_copy"
    grep -q "Revision Stability Recheck" "$LONG_WRITE/references/workflow-revision.md"
    grep -q -- "--volume 第X卷" "$LONG_WRITE/references/workflow-revision.md"
    grep -q "stability-agent-dispatch-prompt.sh" "$LONG_WRITE/references/workflow-revision.md"
    cmp -s "$reference" "$setup_copy"
}
