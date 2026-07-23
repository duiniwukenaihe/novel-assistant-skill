#!/usr/bin/env bats
# tests/test-degeneration-detector.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/check-degeneration.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "check-degeneration detects repetition, truncation, placeholder, and prose meta leak" {
    FILE="$TMP_DIR/bad.md"
    OUT="$TMP_DIR/out.json"
    cat > "$FILE" <<'EOF'
第1章 开端
他终于明白这场雨不是雨，是天塌下来的声音。
他终于明白这场雨不是雨，是天塌下来的声音。
他终于明白这场雨不是雨，是天塌下来的声音。
细纲要求这里回收上一章伏笔。
（此处省略战斗）
门外传来脚步
EOF

    if node "$SCRIPT" --json "$FILE" > "$OUT" 2>"$TMP_DIR/err.txt"; then
        echo "expected degeneration detector to fail"
        cat "$OUT"
        return 1
    fi

    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const types = new Set(report.findings.map(f => f.type));
for (const type of ['verbatim-repeat', 'placeholder-leak', 'meta-leak', 'truncated']) {
  if (!types.has(type)) throw new Error(`missing ${type}: ${JSON.stringify(report.findings)}`);
}
if (!report.findings.some(f => f.type === 'meta-leak' && f.severity === 'blocking')) {
  throw new Error('tier1 engineering word leak must be blocking');
}
NODE
}

@test "check-degeneration keeps title chapter line and dialogue repetition from becoming false positives" {
    FILE="$TMP_DIR/ok.md"
    OUT="$TMP_DIR/out.json"
    cat > "$FILE" <<'EOF'
第12章 风雪夜
"对不起，我无法答应你。"
"对不起，我无法答应你。"
"对不起，我无法答应你。"
她把书页翻到下一章，指尖停在那行小字上。
门外雪声落了一夜。
EOF

    node "$SCRIPT" --json --fail-on=blocking "$FILE" > "$OUT"
    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (report.findings.some(f => f.severity === 'blocking')) {
  throw new Error(`unexpected blocking finding: ${JSON.stringify(report.findings)}`);
}
NODE
}

@test "check-degeneration is bundled and executable" {
    test -x "$SCRIPT"
    test -x "$REPO/skills/novel-assistant/scripts/check-degeneration.js"
    test -x "$REPO/skills/novel-assistant/scripts/check-degeneration.js"
}
