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

# Audit point #2（Task 4）：扫描器只完成部分输入时，--json 结果必须显式标 status=partial
# 并列出未读文件，不得靠空 findings 冒充完成。仅看 findings 数组的聚合器无法仅凭 findings
# 区分「全部扫完且无问题」与「部分文件崩掉、只扫到可读文件」，扫描器必须在 JSON 里自报 partial。
@test "check-degeneration --json marks partial scan when an input file is unreadable" {
    READABLE="$TMP_DIR/ok.md"
    MISSING="$TMP_DIR/missing.md"
    printf '正常正文一段，没有退化。\n' > "$READABLE"

    # 退出码 2 = 扫描错误（区别于 0=clean / 1=quality finding）。用 run 捕获退出码不外抛。
    run node "$SCRIPT" --json "$READABLE" "$MISSING"
    [ "$status" -eq 2 ]
    printf '%s' "$output" > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
// 必须有显式 status，且部分扫描时为 partial（不是 pass/ok）
if (report.status !== 'partial') {
  throw new Error(`expected status=partial on unreadable input, got status=${JSON.stringify(report.status)}, keys=${Object.keys(report)}`);
}
// 必须列出未读文件，聚合器才能把崩溃文件和「扫完没发现」区分开
const failed = Array.isArray(report.files_unreadable) ? report.files_unreadable : [];
if (!failed.some((entry) => /missing\.md/.test(String(entry.file || entry)))) {
  throw new Error(`missing file not reported in files_unreadable: ${JSON.stringify(report)}`);
}
NODE
}
