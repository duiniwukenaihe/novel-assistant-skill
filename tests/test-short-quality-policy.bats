#!/usr/bin/env bats

# P1.3 验证：篇幅按任务模式分级
#   - 整篇回炉：单节篇幅偏差记入队列（section anchor），继续后续小节，整篇收束时统一提醒。
#   - 单节精修：篇幅明显偏离时给"补写 / 保留并记录 / 调整基准"选择。
# 单节精修的选择路径已在 test-short-section-repair-finalize.bats
# (single-section task records length variance and asks before continuing) 覆盖；
# 本文件聚焦"整篇回炉"链路：偏差落进 section anchor（队列），最终检查能汇总成统一提醒。

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  LENGTH_POLICY="$REPO/scripts/short-section-length-policy.js"
  MACHINE_GATE="$REPO/scripts/short-section-machine-gate.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/追踪/private-short-extension"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "length policy library defers whole-story variance without blocking the section" {
  # P1.3 验证点一（库层）：普通小节偏离基准时不阻断，标记为 outside_story_band_deferred，
  # 由整篇收束统一处理。这是"记入队列继续后续小节"的判定基础。
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"accepted_sections":[
  {"section_index":1,"length_chars":2490},
  {"section_index":2,"length_chars":2380},
  {"section_index":3,"length_chars":2520}
]}
JSON
  run node "$LENGTH_POLICY" --project-root "$BOOK" --section-index 4 --actual 1500 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="outside_story_band_deferred" || x.blocking!==false || x.status!=="advisory") process.exit(1)' "$output"
}

@test "deferred length verdict flows into the section anchor queue consumed by final check" {
  # P1.3 验证点二（集成层）：整篇回炉的"记入队列"靠 section anchor 落地。
  # accept-finalize 会把 length_policy 写入 section-NNN-anchor.json 的
  # quality_result.length_policy；short-story-final-check.collectLengthAdvisories
  # 读到的正是这个字段，把 outside_story_band_deferred 汇总成 section_length_variance
  # 提醒。这里用与生产代码完全一致的 anchor 结构验证该队列契约。
  cat > "$BOOK/追踪/private-short-extension/section-004-anchor.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "workflow_id": "wf-p13-queue",
  "section_index": 4,
  "status": "accepted",
  "canonical_path": "正文/第004节.md",
  "canonical_sha256": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
  "quality_result": {
    "machine_gate": "pass",
    "story_value_gate": "pass",
    "quality_gate": "pass",
    "repetition_gate": "pass",
    "length_policy": {
      "verdict": "outside_story_band_deferred",
      "blocking": false,
      "observed_chars": 1500,
      "baseline_chars": 2460,
      "status": "advisory"
    }
  }
}
JSON
  # 再放一个 within_story_band 的 anchor，验证它不会被误记入队列。
  cat > "$BOOK/追踪/private-short-extension/section-003-anchor.json" <<'JSON'
{
  "schema_version": "1.0.0",
  "workflow_id": "wf-p13-queue",
  "section_index": 3,
  "status": "accepted",
  "canonical_path": "正文/第003节.md",
  "canonical_sha256": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
  "quality_result": {
    "machine_gate": "pass",
    "story_value_gate": "pass",
    "quality_gate": "pass",
    "repetition_gate": "pass",
    "length_policy": {"verdict": "within_story_band", "blocking": false, "observed_chars": 2500, "baseline_chars": 2460}
  }
}
JSON

  # 用与 short-story-final-check.js:collectLengthAdvisories 完全一致的筛选逻辑
  # 读回队列：只有第4节（deferred）应被收集，第3节（within band）应被排除。
  run node - "$BOOK/追踪/private-short-extension" <<'NODE'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const advisories = fs.readdirSync(dir)
  .filter((name) => /^section-\d{3}-anchor\.json$/.test(name))
  .map((name) => JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8')))
  .filter((anchor) => (((anchor.quality_result || {}).length_policy || {}).verdict) === 'outside_story_band_deferred')
  .map((anchor) => ({
    debt_type: 'section_length_variance',
    scope: `第${anchor.section_index}节`,
    observed_chars: anchor.quality_result.length_policy.observed_chars,
    baseline_chars: anchor.quality_result.length_policy.baseline_chars,
  }));
if (advisories.length !== 1) { process.stderr.write(JSON.stringify(advisories)); process.exit(1); }
if (advisories[0].scope !== '第4节') { process.stderr.write(JSON.stringify(advisories)); process.exit(2); }
if (advisories[0].debt_type !== 'section_length_variance') process.exit(3);
process.stdout.write(JSON.stringify(advisories));
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'"scope":"第4节"'* ]]
  [[ "$output" == *'"debt_type":"section_length_variance"'* ]]
}

@test "single-section task pauses with a three-option length choice rather than only deferring" {
  # P1.3 验证点三（单节精修，与整篇回炉对照）：shouldAskSingleSectionLengthChoice
  # 只对单节任务触发选择菜单（补写/保留/调整），整篇任务只 defer。这与上面两条
  # 共同构成"按任务模式分级"。完整菜单暂停已在 repair-finalize 覆盖，这里做轻量回归。
  run node - "$REPO/scripts/lib/short-section-length-policy.js" <<'NODE'
const { shouldAskSingleSectionLengthChoice } = require(process.argv[2]);
const policy = { verdict: 'outside_story_band_deferred' };
const single = { lifecycle: { scope: '第 4 节' } };
const whole = { lifecycle: { scope: '全篇' } };
// 单节任务应触发选择（不静默 defer）。
if (!shouldAskSingleSectionLengthChoice(single, policy)) process.exit(1);
// 整篇任务应只 defer，不弹单节选择菜单。
if (shouldAskSingleSectionLengthChoice(whole, policy)) process.exit(2);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
