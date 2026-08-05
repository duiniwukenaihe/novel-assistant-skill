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
    printf '{"bookTitle":"测试长篇","chapterLayout":"volume"}\n' > "$book/.book-state.json"
    printf '江湖门派，武学、厨艺与餐馆经营线。\n' > "$book/设定/世界观/背景.md"
    printf '## 第1章 开端\n\n主角开始行动。\n同伴站在门边。\n' > "$book/正文/第1卷/第001章_开端.md"
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
    printf '## 第1章 坏稿\n\n主角说：“该到下一章了，本章任务完成。”\n' > "$book/正文/第1卷/第001章_开端.md"

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

@test "project smoke samples canonical short sections instead of only the assembled story" {
    book="$TMP_DIR/short-book"
    mkdir -p "$book/正文" "$book/追踪/private-short-extension"
    printf '# 短篇正文\n' > "$book/正文.md"
    printf '## 第1节 起因\n\n她推开门。\n' > "$book/正文/第001节.md"
    printf '## 第2节 转折\n\n灯忽然灭了。\n' > "$book/正文/第002节.md"
    printf '{"narrative":{"planned_sections":3},"accepted_sections":[{"section_index":1},{"section_index":2}]}\n' > "$book/追踪/private-short-extension/project-state.json"

    output="$(node "$SMOKE_SCRIPT" "$book" --json --sample 1)"
    echo "$output" | grep -q '"status": "pass"'
    echo "$output" | grep -q '"progressStatus": "ok"'
    echo "$output" | grep -q '"contentUnit": "section"'
    echo "$output" | grep -q '"completedSections": 2'
    echo "$output" | grep -q '"currentDraftPath": "正文/第002节.md"'
    echo "$output" | grep -q '"sampled": 1'
    echo "$output" | grep -q '"file": "正文/第001节.md"'
}
