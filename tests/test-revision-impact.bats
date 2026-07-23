#!/usr/bin/env bats
# tests/test-revision-impact.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    SCRIPT="$REPO/scripts/revision-impact-scan.sh"
}

@test "revision impact scan reports affected longform stability files" {
    request="$FIXTURE/修订请求/删除异常水印.md"
    [ -x "$SCRIPT" ]
    [ -f "$request" ]

    output="$(bash "$SCRIPT" "$FIXTURE" "$request")"

    echo "$output" | grep -q "## Revision Impact Analysis"
    echo "$output" | grep -q "修改对象：正文/第001章_拒绝错误任务.md"
    echo "$output" | grep -q "关键词：异常水印 江临 旧账号"
    echo "$output" | grep -q "正文/第001章_拒绝错误任务.md"
    echo "$output" | grep -q "追踪/上下文.md"
    echo "$output" | grep -q "追踪/伏笔.md"
    echo "$output" | grep -q "追踪/时间线.md"
    echo "$output" | grep -q "设定/角色不变量/江临.md"
    echo "$output" | grep -q "State_Not_Updated"
    echo "$output" | grep -q "Foreshadow_Early_Payoff"
    echo "$output" | grep -q "Plot Drift Gate"
}

@test "revision impact scan rejects incomplete request" {
    tmp="$(mktemp -d)"
    bad="$tmp/bad-request.md"
    printf '# Revision Request\n修改对象：正文/第001章_拒绝错误任务.md\n' > "$bad"

    ! bash "$SCRIPT" "$FIXTURE" "$bad" >/dev/null 2>&1

    rm -rf "$tmp"
}

@test "revision impact reference documents automation entrypoint" {
    reference="$REPO/src/internal-skills/story-long-write/references/revision-impact-analysis.md"
    setup_copy="$REPO/src/internal-skills/story-setup/references/agent-references/revision-impact-analysis.md"

    grep -q "scripts/revision-impact-scan.sh" "$reference" &&
        grep -q "scripts/revision-impact-scan.sh" "$setup_copy" &&
        cmp -s "$reference" "$setup_copy"
}
