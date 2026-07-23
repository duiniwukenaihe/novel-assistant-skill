#!/usr/bin/env bats
# tests/test-write-failure-triage.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/write-failure-triage.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "write failure triage classifies invalid tool parameters as schema issue not permission" {
    mkdir -p "$TMP_DIR/book/追踪/审查报告"
    cat > "$TMP_DIR/log.txt" <<'EOF'
⎿  Error writing file
⎿  Invalid tool parameters
Thinking for 3s
看起来我的 Write 调用还是参数不完整。让我用正确格式重新调用。
EOF

    node "$SCRIPT" --target "$TMP_DIR/book/追踪/审查报告/综合报告.md" --log-file "$TMP_DIR/log.txt" --json > "$TMP_DIR/out.json"

    grep -q '"status": "blocked_write_tool_call_invalid"' "$TMP_DIR/out.json"
    grep -q '"category": "tool_call_schema_check"' "$TMP_DIR/out.json"
    grep -q '"permissionWritable": true' "$TMP_DIR/out.json"
    grep -q 'file_path' "$TMP_DIR/out.json"
    grep -q 'content' "$TMP_DIR/out.json"
}

@test "write failure triage classifies hook usage errors as hook block" {
    mkdir -p "$TMP_DIR/book/正文/第1卷"
    target="$TMP_DIR/book/正文/第1卷/第023章.md"
    printf '正文\n' > "$target"
    cat > "$TMP_DIR/log.txt" <<'EOF'
PostToolUse:Edit hook returned blocking error
[bash "$CLAUDE_PROJECT_DIR"/.claude/hooks/ai-trace-detector.sh]: usage:
/book/.claude/hooks/ai-trace-detector.sh <file>
EOF

    node "$SCRIPT" --target "$target" --log-file "$TMP_DIR/log.txt" --json > "$TMP_DIR/out.json"

    grep -q '"status": "blocked_write_hook"' "$TMP_DIR/out.json"
    grep -q '"category": "hook_block"' "$TMP_DIR/out.json"
    grep -q 'ai-trace-detector.sh' "$TMP_DIR/out.json"
    grep -q '"targetExists": true' "$TMP_DIR/out.json"
}

@test "write failure triage detects parent path that is a file" {
    mkdir -p "$TMP_DIR/book/追踪"
    printf 'not a dir\n' > "$TMP_DIR/book/追踪/审查报告"
    cat > "$TMP_DIR/log.txt" <<'EOF'
⎿  Error writing file
EOF

    ! node "$SCRIPT" --target "$TMP_DIR/book/追踪/审查报告/综合报告.md" --log-file "$TMP_DIR/log.txt" --json > "$TMP_DIR/out.json"

    grep -q '"status": "blocked_write_permission"' "$TMP_DIR/out.json"
    grep -q '"category": "filesystem_preflight"' "$TMP_DIR/out.json"
    grep -q '"parentType": "file"' "$TMP_DIR/out.json"
}

@test "write failure triage writes recovery record under project root" {
    mkdir -p "$TMP_DIR/book/追踪/审查报告"
    cat > "$TMP_DIR/log.txt" <<'EOF'
⎿  Error editing file
old_string not found
EOF

    node "$SCRIPT" --target "$TMP_DIR/book/追踪/审查报告/综合报告.md" --log-file "$TMP_DIR/log.txt" --project-root "$TMP_DIR/book" --write --json > "$TMP_DIR/out.json"

    grep -q '"written"' "$TMP_DIR/out.json"
    find "$TMP_DIR/book/追踪/写入失败分诊" -name '*.json' | grep -q .
    find "$TMP_DIR/book/追踪/写入失败分诊" -name '*.md' | grep -q .
    grep -q '"status": "blocked_write_missing_output"' "$TMP_DIR/out.json"
}
