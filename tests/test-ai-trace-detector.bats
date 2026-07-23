#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../src/internal-skills/story-deslop/scripts/ai-trace-detector.sh"
}

@test "ai-trace-detector.sh exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "ai-trace-detector.sh exits 1 on trace" {
    ! bash "$SCRIPT" "$BATS_TEST_DIRNAME/fixtures/ai-trace/with-trace.md"
}

@test "ai-trace-detector.sh exits 0 on clean file" {
    bash "$SCRIPT" "$BATS_TEST_DIRNAME/fixtures/ai-trace/clean.md"
}

@test "ai-trace-detector.sh exits 2 on missing file" {
    ! bash "$SCRIPT" /tmp/nonexistent-file-12345.md
}

@test "ai-trace-detector.sh detects NOVEL_TEXT_START marker" {
    echo "Some text" > /tmp/test-trace.md
    echo "NOVEL_TEXT_START" >> /tmp/test-trace.md
    ! bash "$SCRIPT" /tmp/test-trace.md
    rm -f /tmp/test-trace.md
}

@test "ai-trace-detector.sh detects square bracket TODO" {
    echo "Some text" > /tmp/test-trace.md
    echo "[TODO: 补完这段]" >> /tmp/test-trace.md
    ! bash "$SCRIPT" /tmp/test-trace.md
    rm -f /tmp/test-trace.md
}

@test "ai-trace-detector.sh extracts edited file from Claude hook JSON stdin" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/正文/第1卷"
    target="$tmp/正文/第1卷/第001章_干净.md"
    printf '陈洛趴在泥里。\\n' > "$target"

    printf '{"tool_input":{"file_path":"%s"}}' "$target" | CLAUDE_PROJECT_DIR="$tmp" bash "$SCRIPT"

    rm -rf "$tmp"
}

@test "ai-trace-detector.sh does not block hook when Claude provides no file path" {
    tmp="$(mktemp -d)"

    CLAUDE_PROJECT_DIR="$tmp" bash "$SCRIPT"

    rm -rf "$tmp"
}

@test "ai-trace-detector.sh reports trace from Claude hook JSON stdin" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/正文/第1卷"
    target="$tmp/正文/第1卷/第001章_泄漏.md"
    printf 'NOVEL_TEXT_START\\n正文\\n' > "$target"

    ! printf '{"tool_input":{"file_path":"%s"}}' "$target" | CLAUDE_PROJECT_DIR="$tmp" bash "$SCRIPT"

    rm -rf "$tmp"
}
