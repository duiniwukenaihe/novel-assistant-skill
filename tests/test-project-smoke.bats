#!/usr/bin/env bats
# tests/test-project-smoke.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SMOKE_SCRIPT="$REPO/scripts/novel-assistant-project-smoke.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

make_book() {
    local book="$TMP_DIR/book"
    mkdir -p "$book/设定/世界观" "$book/正文/第1卷" "$book/追踪"
    printf '{"bookTitle":"蛋炒饭","chapterLayout":"volume"}\n' > "$book/.book-state.json"
    printf '魔教后厨，心法、厨艺、红袖坊经营线。\n' > "$book/设定/世界观/背景.md"
    printf '## 第1章 开锅\n\n沈七把锅烧热。\n绿珠站在门边。\n' > "$book/正文/第1卷/第001章_开锅.md"
    printf '%s\n' "$book"
}

@test "project smoke script reports domain progress and prose gate sample without writes" {
    book="$(make_book)"

    output="$(node "$SMOKE_SCRIPT" "$book" --json --sample 1)"
    echo "$output" | grep -q '"status": "pass"'
    echo "$output" | grep -q '"primaryDomain": "martial_food_business"'
    echo "$output" | grep -q '"progressStatus": "ok"'
    echo "$output" | grep -q '"proseGate"'
    echo "$output" | grep -q '"sampled": 1'
    [ ! -d "$book/追踪/checks" ]
}

@test "project smoke script marks prose issues as needs_attention without mutating project" {
    book="$(make_book)"
    printf '## 第1章 坏稿\n\n沈七说：“该到下一章了，本章任务完成。”\n' > "$book/正文/第1卷/第001章_开锅.md"

    output="$(node "$SMOKE_SCRIPT" "$book" --json --sample 1)"
    echo "$output" | grep -q '"status": "needs_attention"'
    echo "$output" | grep -q '"proseIssues": 2'
    echo "$output" | grep -q '"prose-meta-leak"'
    [ ! -d "$book/追踪/checks" ]
}

@test "project smoke script can discover books under scan root" {
    book="$(make_book)"

    output="$(node "$SMOKE_SCRIPT" --scan-root "$TMP_DIR" --json --sample 1)"
    echo "$output" | grep -q "$(basename "$book")"
    echo "$output" | grep -q '"projectCount": 1'
}
