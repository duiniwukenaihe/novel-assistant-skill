#!/usr/bin/env bats
# tests/test-stability-agent-dispatch-prompt.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    HANDOFF_SCRIPT="$REPO/scripts/chapter-handoff-pack.sh"
    PROMPT_SCRIPT="$REPO/scripts/stability-agent-dispatch-prompt.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "agent dispatch prompt reports no prompt when audit passes" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null

    output="$(bash "$PROMPT_SCRIPT" "$tmp/book" "001" "002")"

    echo "$output" | grep -q "## Stability Agent Dispatch Prompt"
    echo "$output" | grep -q "状态：PASS"
    echo "$output" | grep -q "No pending agent prompt"

    rm -rf "$tmp"
}

@test "agent dispatch prompt emits narrative writer call for continuity checkpoint" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    perl -0pi -e 's/旧账号/废弃入口/g' "$tmp/book/追踪/章节契约/第002章.md" "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$PROMPT_SCRIPT" "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'Agent(subagent_type: "narrative-writer"'
    echo "$output" | grep -q "current_owner：narrative-writer"
    echo "$output" | grep -q "Continuity_Missing"
    echo "$output" | grep -q "只改当前 checkpoint"
    echo "$output" | grep -q "禁止整章重写"
    echo "$output" | grep -q "verification_commands"

    rm -rf "$tmp"
}

@test "agent dispatch prompt emits character designer json for character checkpoint" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$HANDOFF_SCRIPT" --write "$tmp/book" "001" >/dev/null
    printf '\n江临已经提前知道委托人的真实目的。\n' >> "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$PROMPT_SCRIPT" --json "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"NEEDS_REPAIR"'
    echo "$output" | grep -q '"current_owner":"character-designer"'
    echo "$output" | grep -q '"subagent_type":"character-designer"'
    echo "$output" | grep -q '"agent_call"'
    echo "$output" | grep -q "Stability Repair Loop 角色裁决"
    echo "$output" | grep -q "补获知过程"
    ! echo "$output" | grep -q "## Stability Agent Dispatch Prompt"

    rm -rf "$tmp"
}

@test "agent dispatch prompt preserves volume in repair commands" {
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
    output="$(bash "$PROMPT_SCRIPT" --json --volume 第2卷 "$tmp/book" "001" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status":"NEEDS_REPAIR"'
    echo "$output" | grep -q '"volume":"第2卷"'
    echo "$output" | grep -q -- "--volume 第2卷"
    echo "$output" | grep -q "追踪/稳定性审计/第2卷/修复闭环_第001章_to_第002章.md"

    rm -rf "$tmp"
}

@test "agent dispatch prompt reference is wired into workflow and setup bundle" {
    reference="$LONG_WRITE/references/stability-agent-dispatch-prompts.md"
    setup_copy="$SETUP/references/agent-references/stability-agent-dispatch-prompts.md"

    [ -x "$PROMPT_SCRIPT" ]
    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "scripts/stability-agent-dispatch-prompt.sh" "$reference"
    grep -q -- "--json" "$reference"
    grep -q -- "--volume 第X卷" "$reference"
    grep -q "agent_call" "$reference"
    grep -q "current_owner" "$reference"
    grep -q "stability-agent-dispatch-prompts.md" "$LONG_WRITE/references/workflow-daily.md"
    grep -q "stability-agent-dispatch-prompts.md" "$LONG_WRITE/SKILL.md"
    cmp -s "$reference" "$setup_copy"
}
