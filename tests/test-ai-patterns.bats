#!/usr/bin/env bats
# tests/test-ai-patterns.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/src/internal-skills/story-deslop/scripts/check-ai-patterns.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "check-ai-patterns detects not-then-is flips without conjunction false positives" {
    FILE="$TMP_DIR/fixture.md"
    OUT="$TMP_DIR/out.json"
    cat > "$FILE" <<'EOF'
---
title: 不是A，而是B
---
是不是这里不该报。
他不是冷漠，而是绝望。
她不是害怕，是累了。
他不是笨是太急。
他不是冷漠；是绝望。
它不是普通的粥！
是药。
她不是不想走，也不是不敢走。
他不是讨厌你，只是累了。
他不是走了，可是没人知道。
他不是不愿意，于是答应了。
她不是生气，倒是有点担心。
```
他不是冷漠，而是绝望。
```
~~~md
他不是普通表达，而是代码示例。
~~~
EOF

    if node "$SCRIPT" --json "$FILE" > "$OUT" 2>"$TMP_DIR/err.txt"; then
        echo "expected check-ai-patterns to report AI sentence patterns"
        cat "$OUT"
        return 1
    fi

    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const findings = report.findings.filter(finding => finding.type === 'not-is-comparison');
const excerpts = findings.map(finding => finding.excerpt);
const expected = [
  '不是冷漠，而是绝望',
  '不是害怕，是累了',
  '不是笨是太急',
  '不是冷漠；是绝望',
  '不是普通的粥！ 是药',
];
const forbidden = [
  '只是累了',
  '可是没人知道',
  '于是答应了',
  '倒是有点担心',
];
if (findings.length !== expected.length) {
  throw new Error(`expected ${expected.length} not-is findings, got ${findings.length}: ${JSON.stringify(excerpts)}`);
}
for (const excerpt of expected) {
  if (!excerpts.includes(excerpt)) throw new Error(`missing expected excerpt: ${excerpt}; got ${JSON.stringify(excerpts)}`);
}
for (const marker of forbidden) {
  if (excerpts.some(excerpt => excerpt.includes(marker))) throw new Error(`false positive ${marker}: ${JSON.stringify(excerpts)}`);
}
NODE
}

@test "check-ai-patterns shared script copies stay byte-identical" {
    cmp -s "$REPO/src/internal-skills/story-deslop/scripts/check-ai-patterns.js" "$REPO/src/internal-skills/story-review/scripts/check-ai-patterns.js"
    cmp -s "$REPO/src/internal-skills/story-deslop/scripts/check-ai-patterns.js" "$REPO/src/internal-skills/story-long-write/scripts/check-ai-patterns.js"
    cmp -s "$REPO/src/internal-skills/story-deslop/scripts/check-ai-patterns.js" "$REPO/src/internal-skills/story-short-write/scripts/check-ai-patterns.js"
    cmp -s "$REPO/src/internal-skills/story-deslop/scripts/check-ai-patterns.js" "$REPO/scripts/check-ai-patterns.js"
}

@test "one functional not-is comparison is advisory instead of a blocking repair loop" {
    FILE="$TMP_DIR/one-comparison.md"
    OUT="$TMP_DIR/one-comparison.json"
    printf '%s\n' '沉默的代价不是我们两个人的事，是三千名员工的工资。' > "$FILE"

    run node "$SCRIPT" --check --json --fail-on=blocking "$FILE"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$OUT"
    node - "$OUT" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const finding=out.findings.find((item)=>item.type==='not-is-comparison');
if(!finding||finding.severity!=='advisory') throw new Error(JSON.stringify(out));
NODE
}

@test "mainland Chinese prose blocks ASCII straight quotes" {
    FILE="$TMP_DIR/ascii-quotes.md"
    printf '%s\n' '她把合同推过来。"你自己看。"桌边的人都没说话。' > "$FILE"

    run node "$SCRIPT" --check --json --fail-on=blocking "$FILE"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"type": "ascii-quote-style"'* ]]
}

@test "check-ai-patterns treats one functional dash as advisory and rhythm issues as advisory" {
    FILE="$TMP_DIR/prose.md"
    OUT="$TMP_DIR/out.json"
    python3 - "$FILE" <<'PY'
from pathlib import Path
target = Path(__import__("sys").argv[1])
target.write_text("""# 标题里——不检测
他抬头——没有说话。
他走了。
她停了。
风冷了。
灯灭了。
门开了。
雨落了。
“好。”
“走。”
""" + "这一段很长，" * 45 + "终于停下。\n", encoding="utf-8")
PY

    node "$SCRIPT" --json "$FILE" > "$OUT" 2>"$TMP_DIR/err.txt"

    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const byType = new Map();
for (const finding of report.findings) byType.set(finding.type, (byType.get(finding.type) || 0) + 1);
for (const type of ['em-dash', 'period-stutter', 'long-paragraph']) {
  if (!byType.has(type)) throw new Error(`missing ${type}: ${JSON.stringify(report.findings)}`);
}
if (report.findings.some(f => f.excerpt.includes('标题里'))) {
  throw new Error(`markdown heading should be ignored: ${JSON.stringify(report.findings)}`);
}
if (!report.findings.some(f => f.type === 'em-dash' && f.severity === 'advisory')) {
  throw new Error('single em-dash must be advisory');
}
if (!report.findings.some(f => f.type === 'period-stutter' && f.severity === 'advisory')) {
  throw new Error('period-stutter must be advisory');
}
NODE

    node "$SCRIPT" --check --fail-on=blocking "$FILE" >/dev/null

    if node "$SCRIPT" --json --fail-on=all "$FILE" > "$OUT" 2>"$TMP_DIR/err.txt"; then
        echo "expected --fail-on=all to fail on advisory prose rhythm findings"
        cat "$OUT"
        return 1
    fi
}

@test "check-ai-patterns warns on fragmented short paragraph rhythm across UI and dialogue" {
    FILE="$TMP_DIR/fragmented-short-lines.md"
    OUT="$TMP_DIR/out.json"
    cat > "$FILE" <<'EOF'
小阿远像没看见屋里的沉默，又发来一张页面。
【家庭关系理解】
【请上传家庭群截图，用于识别亲属称呼、沟通习惯、矛盾点和未尽心愿】
我妈迟疑了一下。
“家庭群也要啊？”
小阿远语音立刻跟上。
“阿姨，不强制。只是如果您希望林叔叔更懂家里的事，就需要让他知道家里现在的关系。比如照照为什么一开始接受不了，我们也好避免叔叔说错话。”
他说的是避免说错话。
页面上写的却是：子女冲突事件。
我伸手点了点那几个字。
“小阿远，这个为什么是必填？”
他停了两秒，才回。
EOF

    node "$SCRIPT" --json --fail-on=blocking "$FILE" > "$OUT" 2>"$TMP_DIR/err.txt"

    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const finding = report.findings.find(f => f.type === 'short-paragraph-fragmentation');
if (!finding) throw new Error(`missing short-paragraph-fragmentation: ${JSON.stringify(report.findings)}`);
if (finding.severity !== 'advisory') throw new Error(`short paragraph fragmentation should be advisory, got ${finding.severity}`);
if (!finding.message.includes('连续短段')) throw new Error(`message should mention 连续短段: ${finding.message}`);
NODE
}

@test "check-ai-patterns blocks repeated dash overuse and per-character dash corruption" {
    FILE="$TMP_DIR/dash-overuse.md"
    OUT="$TMP_DIR/out.json"
    cat > "$FILE" <<'EOF'
他抬头——没有说话。
门外——有人站着。
风声——贴着窗缝。
她的手——停在半空。
灯光——晃了一下。
本——系——统——开——始——提——示。
EOF

    if node "$SCRIPT" --json --fail-on=blocking "$FILE" > "$OUT" 2>"$TMP_DIR/err.txt"; then
        echo "expected check-ai-patterns to block dash overuse"
        cat "$OUT"
        return 1
    fi

    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!report.findings.some(f => f.type === 'dash-density' && f.severity === 'blocking')) {
  throw new Error(`missing blocking dash-density: ${JSON.stringify(report.findings)}`);
}
if (!report.findings.some(f => f.type === 'per-character-dash' && f.severity === 'blocking')) {
  throw new Error(`missing blocking per-character-dash: ${JSON.stringify(report.findings)}`);
}
NODE
}

@test "check-ai-patterns warns on dense corner quotes in mainland shortform prose" {
    FILE="$TMP_DIR/corner-quotes.md"
    OUT="$TMP_DIR/out.json"
    cat > "$FILE" <<'EOF'
「你凭什么替我决定？」
「我是你妈。」
「那你把我标价的时候，有没有问过我？」
「二十八万，少一分都不行。」
「我偏不。」
「你敢？」
EOF

    node "$SCRIPT" --json "$FILE" > "$OUT" 2>"$TMP_DIR/err.txt"

    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const finding = report.findings.find(f => f.type === 'corner-quote-density');
if (!finding) throw new Error(`missing corner-quote-density: ${JSON.stringify(report.findings)}`);
if (finding.severity !== 'advisory') throw new Error(`corner quote density should be advisory, got ${finding.severity}`);
NODE
}

@test "check-ai-patterns supports advisory-only pass with fail-on blocking" {
    FILE="$TMP_DIR/advisory.md"
    OUT="$TMP_DIR/out.json"
    cat > "$FILE" <<'EOF'
他走了。
她停了。
风冷了。
灯灭了。
门开了。
雨落了。
EOF

    node "$SCRIPT" --json --fail-on=blocking "$FILE" > "$OUT"
    node - "$OUT" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!report.findings.some(f => f.type === 'period-stutter' && f.severity === 'advisory')) {
  throw new Error(`expected advisory period-stutter: ${JSON.stringify(report.findings)}`);
}
NODE
}

@test "normalize-punctuation can convert corner quotes to mainland curly quotes" {
    NORMALIZE="$REPO/src/internal-skills/story-short-write/scripts/normalize-punctuation.js"
    FILE="$TMP_DIR/quotes.md"
    cat > "$FILE" <<'EOF'
「你凭什么替我决定？」
我妈说：「我是你妈。」
EOF

    node "$NORMALIZE" --quote-mode=mainland "$FILE" >/dev/null

    grep -q '“你凭什么替我决定？”' "$FILE"
    grep -q '我妈说：“我是你妈。”' "$FILE"
    ! grep -q '「' "$FILE"
    ! grep -q '」' "$FILE"
}
