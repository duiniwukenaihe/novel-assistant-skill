#!/usr/bin/env bats
# tests/test-chapter-index.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    INDEX_SCRIPT="$REPO/scripts/chapter-index-build.sh"
    STABILITY_SCRIPT="$REPO/scripts/chapter-stability-check.sh"
    DAILY_AUDIT="$REPO/scripts/longform-daily-stability-audit.sh"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    SETUP="$REPO/src/internal-skills/story-setup"
}

@test "chapter index builder lists chapter body files in stable order" {
    output="$(bash "$INDEX_SCRIPT" "$FIXTURE")"

    echo "$output" | grep -q $'chapter\ttitle\tpath\tchars'
    echo "$output" | grep -q $'001\t第001章 拒绝错误任务\t正文/第001章_拒绝错误任务.md'
    echo "$output" | grep -q $'002\t第002章 追查旧账号\t正文/第002章_追查旧账号.md'
}

@test "chapter index builder writes tracking artifact" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"

    output="$(bash "$INDEX_SCRIPT" --write "$tmp/book")"
    index_file="$tmp/book/追踪/章节索引.tsv"

    echo "$output" | grep -q "WROTE: 追踪/章节索引.tsv"
    [ -f "$index_file" ]
    grep -q $'001\t第001章 拒绝错误任务\t正文/第001章_拒绝错误任务.md' "$index_file"
    grep -q $'002\t第002章 追查旧账号\t正文/第002章_追查旧账号.md' "$index_file"

    rm -rf "$tmp"
}

@test "chapter stability check uses chapter index for nested body paths" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    mkdir -p "$tmp/book/正文/卷一"
    mv "$tmp/book/正文/第002章_追查旧账号.md" "$tmp/book/正文/卷一/第002章_追查旧账号.md"
    bash "$INDEX_SCRIPT" --write "$tmp/book" >/dev/null

    output="$(bash "$STABILITY_SCRIPT" "$tmp/book" "002")"

    echo "$output" | grep -q "Chapter Stability Check PASS: chapter 002"

    rm -rf "$tmp"
}

@test "daily stability audit refreshes chapter index once for batch checks" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    bash "$REPO/scripts/chapter-handoff-pack.sh" --write "$tmp/book" "001" >/dev/null

    bash "$DAILY_AUDIT" --write "$tmp/book" "001" "002" >/dev/null

    [ -f "$tmp/book/追踪/章节索引.tsv" ]
    grep -q $'001\t第001章 拒绝错误任务\t正文/第001章_拒绝错误任务.md' "$tmp/book/追踪/章节索引.tsv"

    rm -rf "$tmp"
}

@test "chapter index reference is wired into longform workflow and setup bundle" {
    reference="$LONG_WRITE/references/chapter-index.md"
    setup_copy="$SETUP/references/agent-references/chapter-index.md"

    [ -x "$INDEX_SCRIPT" ]
    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "scripts/chapter-index-build.sh" "$reference"
    grep -q "追踪/章节索引.tsv" "$reference"
    grep -q "chapter-index.md" "$LONG_WRITE/SKILL.md"
    grep -q "chapter-index.md" "$LONG_WRITE/references/workflow-daily.md"
    grep -q "追踪/章节索引.tsv" "$SETUP/references/templates/agents/story-explorer.md"
    cmp -s "$reference" "$setup_copy"
}
