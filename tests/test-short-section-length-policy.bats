#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO/scripts/short-section-length-policy.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/追踪/private-short-extension"
}

teardown() {
  rm -rf "$TMP_DIR"
}

write_state() {
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{
  "accepted_sections": [
    {"section_index": 1, "length_chars": 2490, "section_role": "opening"}
  ]
}
JSON
}

@test "first accepted section establishes a provisional local baseline" {
  write_state
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --planned-target 2500 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.baseline_chars!==2490 || x.baseline_status!=="provisional" || x.verdict!=="within_target_band") process.exit(1)' "$output"
}

@test "observed median remains advisory and cannot lower or enforce the writing target" {
  write_state
  node - "$BOOK/追踪/private-short-extension/project-state.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const state = JSON.parse(fs.readFileSync(file, 'utf8'));
state.accepted_sections.push({ section_index: 2, length_chars: 1724 });
fs.writeFileSync(file, JSON.stringify(state));
NODE
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --actual 1724 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="observed_length_variance_advisory" || x.blocking || x.status!=="advisory" || x.target_enforcement!=="advisory" || x.baseline_chars!==2490 || x.sample_size!==1) process.exit(1)' "$output"
}

@test "an explicit section target enforces minus ten percent and plus twenty percent" {
  write_state
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --actual 2699 --planned-target 3000 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="under_target_repair_required" || !x.blocking || x.author_decision_required || x.target_source!=="explicit_section_target" || x.target_chars!==3000 || x.hard_floor!==2700 || x.hard_ceiling!==3600 || !x.note.includes("目标3000字，实际2699字，少301字（10.0%）")) process.exit(1)' "$output"
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --actual 2700 --planned-target 3000 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="within_target_band" || x.blocking || x.lower_bound!==2700 || x.upper_bound!==3600) process.exit(1)' "$output"
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --actual 3600 --planned-target 3000 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="within_target_band" || x.blocking) process.exit(1)' "$output"
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --actual 3601 --planned-target 3000 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="over_target_repair_required" || !x.blocking || x.author_decision_required || !x.note.includes("目标3000字，实际3601字，多601字（20.0%）")) process.exit(1)' "$output"
}

@test "Brief budget wording is parsed as a hard section target" {
  cat > "$BOOK/写作Brief_第001节.md" <<'MD'
# 写作Brief 第 1 节
- 字数预算：2800 字（允许 -10% 到 +20%）
## 字数核对
本节预算 2800 字，写作后需自检字数 2520-3360 字。
MD
  run node - "$REPO/scripts/lib/short-section-length-target.js" "$REPO/scripts/lib/short-section-length-policy.js" "$BOOK" <<'NODE'
const assert = require('assert');
const { resolveSectionLengthTarget } = require(process.argv[2]);
const { deriveSectionLengthPolicy } = require(process.argv[3]);
const root = process.argv[4];
const target = resolveSectionLengthTarget(root, {}, 1);
assert.equal(target.chars, 2800);
assert.equal(target.source, 'explicit_section_target');
assert.equal(target.enforcement, 'hard');
const result = deriveSectionLengthPolicy({
  sectionIndex: 1,
  actual: 865,
  plannedTarget: target.chars,
  plannedTargetSource: target.source,
  targetEnforcement: target.enforcement,
});
assert.equal(result.verdict, 'under_target_repair_required');
assert.equal(result.hard_floor, 2520);
assert.equal(result.blocking, true);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "explicit transition reason is preserved but is not required to continue" {
  write_state
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --planned-target 1800 --section-role transition --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.blocking || x.verdict!=="under_target_review_completeness" || x.author_decision_required) process.exit(1)' "$output"
  run node "$SCRIPT" --project-root "$BOOK" --section-index 2 --planned-target 1800 --section-role transition --exception-reason "本节只承担撤离后的即时转场与新钩子" --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.verdict!=="explicit_story_exception" || x.blocking) process.exit(1)' "$output"
}

@test "three accepted sections switch the baseline to a rolling median" {
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"accepted_sections":[
  {"section_index":1,"length_chars":2490},
  {"section_index":2,"length_chars":2380},
  {"section_index":3,"length_chars":2520},
  {"section_index":4,"length_chars":3100,"section_role":"climax"}
]}
JSON
  run node "$SCRIPT" --project-root "$BOOK" --section-index 5 --planned-target 2450 --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); if(x.baseline_status!=="stabilized" || x.baseline_chars!==2490 || x.sample_size!==3) process.exit(1)' "$output"
}

@test "accepted outline section targets remain hard when a compatible current outline omits the number" {
  mkdir -p "$BOOK/追踪/story-system/short" "$BOOK/追踪/story-system/commits" "$BOOK/追踪/story-system/transactions/tx-outline/staged"
  cat > "$BOOK/追踪/story-system/short/section-title-lock.json" <<'JSON'
{"status":"confirmed","planned_sections":9,"sections":[{"section_index":1},{"section_index":2},{"section_index":3},{"section_index":4},{"section_index":5},{"section_index":6},{"section_index":7},{"section_index":8},{"section_index":9}]}
JSON
  cat > "$BOOK/小节大纲.md" <<'MD'
# 小节大纲
- 总小节数：9 节；目标总字数：15,000—17,000 字。
## 第1节：开始
## 第2节：推进
## 第3节：推进
## 第4节：已调整的支线
## 第5节：推进
## 第6节：推进
## 第7节：推进
## 第8节：公开高潮
## 第9节：结尾
MD
  cat > "$BOOK/追踪/story-system/transactions/tx-outline/staged/001-小节大纲.md" <<'MD'
# 小节大纲
- 总小节数：9 节；目标总字数：15,000—17,000 字。
## 第1节：开始
## 第2节：推进
## 第3节：推进
## 第4节：推进
## 第5节：推进
## 第6节：推进
## 第7节：推进
## 第8节：公开高潮
- 目标字数：1,900-2,200字。
## 第9节：结尾
MD
  cat > "$BOOK/追踪/story-system/transactions/tx-outline/transaction.json" <<'JSON'
{"transaction_id":"tx-outline","status":"accepted","artifacts":[{"role":"section_outline","staged":"追踪/story-system/transactions/tx-outline/staged/001-小节大纲.md","target":"小节大纲.md"}]}
JSON
  cat > "$BOOK/追踪/story-system/commits/outline.json" <<'JSON'
{"commit_id":"outline","transaction_id":"tx-outline","status":"accepted","accepted_at":"2026-01-01T00:00:00.000Z","artifacts":[{"role":"section_outline","target":"小节大纲.md"}]}
JSON
  run node - "$REPO/scripts/lib/short-section-length-target.js" "$REPO/scripts/lib/short-section-length-policy.js" "$BOOK" <<'NODE'
const assert = require('assert');
const { resolveSectionLengthTarget } = require(process.argv[2]);
const { deriveSectionLengthPolicy } = require(process.argv[3]);
const root = process.argv[4];
assert.deepEqual(resolveSectionLengthTarget(root, {}, 2), { chars: 1778, source: 'project_average_target', enforcement: 'advisory' });
const restored = resolveSectionLengthTarget(root, {}, 8);
assert.equal(restored.chars, 2050);
assert.equal(restored.source, 'accepted_outline_section_target');
assert.equal(restored.enforcement, 'hard');
assert.deepEqual(restored.range, { min: 1900, max: 2200 });
assert.match(restored.evidence_path, /tx-outline\/staged\/001-小节大纲\.md$/u);
for (const actual of [1900, 2200]) {
  const result = deriveSectionLengthPolicy({ actual, plannedTarget: restored.chars, plannedTargetRange: restored.range, plannedTargetSource: restored.source, targetEnforcement: restored.enforcement, sectionIndex: 8 });
  assert.equal(result.blocking, false, JSON.stringify(result));
}
for (const actual of [1899, 2201]) {
  const result = deriveSectionLengthPolicy({ actual, plannedTarget: restored.chars, plannedTargetRange: restored.range, plannedTargetSource: restored.source, targetEnforcement: restored.enforcement, sectionIndex: 8 });
  assert.equal(result.blocking, true, JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "current explicit section ranges preserve their exact lower and upper bounds" {
  mkdir -p "$BOOK/追踪/story-system/short"
  cat > "$BOOK/追踪/story-system/short/section-title-lock.json" <<'JSON'
{"status":"confirmed","planned_sections":2,"sections":[{"section_index":1},{"section_index":2}]}
JSON
  cat > "$BOOK/小节大纲.md" <<'MD'
# 小节大纲
## 第1节：起点
## 第2节：推进
- 目标字数：1,500-1,700字。
MD
  run node - "$REPO/scripts/lib/short-section-length-target.js" "$REPO/scripts/lib/short-section-length-policy.js" "$BOOK" <<'NODE'
const assert = require('assert');
const { resolveSectionLengthTarget } = require(process.argv[2]);
const { deriveSectionLengthPolicy } = require(process.argv[3]);
const root = process.argv[4];
const target = resolveSectionLengthTarget(root, {}, 2);
assert.equal(target.chars, 1600);
assert.deepEqual(target.range, { min: 1500, max: 1700 });
assert.equal(target.enforcement, 'hard');
for (const actual of [1500, 1700]) {
  const result = deriveSectionLengthPolicy({ actual, plannedTarget: target.chars, plannedTargetRange: target.range, plannedTargetSource: target.source, targetEnforcement: target.enforcement, sectionIndex: 2 });
  assert.equal(result.blocking, false, JSON.stringify(result));
}
for (const actual of [1499, 1701]) {
  const result = deriveSectionLengthPolicy({ actual, plannedTarget: target.chars, plannedTargetRange: target.range, plannedTargetSource: target.source, targetEnforcement: target.enforcement, sectionIndex: 2 });
  assert.equal(result.blocking, true, JSON.stringify(result));
}
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "length enforcement never asks the author to approve an out-of-band draft" {
  run node - "$REPO/scripts/lib/short-section-length-policy.js" <<'NODE'
const { shouldAskSingleSectionLengthChoice } = require(process.argv[2]);
const under = { verdict: 'under_target_repair_required', blocking: true, author_decision_required: false };
const over = { verdict: 'over_target_repair_required', blocking: true, author_decision_required: false };
const single = { lifecycle: { scope: '第 2 节' } };
const whole = { lifecycle: { scope: '全篇' } };
const queue = { lifecycle: { scope: '第2节' }, feedback_revision_queue: { status: 'running', affected_sections: [2, 3] } };
if (shouldAskSingleSectionLengthChoice(single, under)) process.exit(1);
if (shouldAskSingleSectionLengthChoice(whole, under)) process.exit(2);
if (shouldAskSingleSectionLengthChoice(queue, over)) process.exit(3);
NODE
  [ "$status" -eq 0 ]
}

@test "compact workflow choices do not invent a four-option menu" {
  run node - "$REPO/scripts/lib/workflow-action-renderer.js" <<'NODE'
const { decoratePendingAction } = require(process.argv[2]);
const pending = decoratePendingAction({compact_options:true,free_text_enabled:true,options:[
  {action_id:'accept_length_variance',label:'保留并继续（推荐）'},
  {action_id:'revise_length_variance',label:'补写或压缩'},
  {action_id:'free_text',label:'输入其他要求或开启新任务'},
]});
if (pending.options.length !== 3) process.exit(1);
if (pending.interaction_profile !== 'numeric_compact_choice') process.exit(2);
if (!pending.options[0].recommended) process.exit(3);
NODE
  [ "$status" -eq 0 ]
}

@test "public and private short workflows require the local length baseline before the next brief" {
  grep -q 'short-section-length-policy.js' "$REPO/src/internal-skills/story-short-write/SKILL.md"
  if [ -f "$REPO/src/private-internal-skills/private-short-extension/SKILL.md" ]; then
    grep -q 'short-section-length-policy.js' "$REPO/src/private-internal-skills/private-short-extension/SKILL.md"
    grep -q '作品内篇幅基准' "$REPO/src/private-internal-skills/private-short-extension/workflow-registry.json"
  fi
  grep -q 'short-section-length-policy.js' "$REPO/config/novel-assistant-bundle-files.json"
}

@test "short writing guidance documents the tiered target policy instead of one fixed section size" {
  grep -q '最低.*-10%' "$REPO/src/internal-skills/story-short-write/SKILL.md"
  grep -q '最高.*+20%' "$REPO/src/internal-skills/story-short-write/SKILL.md"
  grep -q '低于.*高于.*自动回炉' "$REPO/src/internal-skills/story-short-write/SKILL.md"
  ! grep -q '每小节 800-1500 字' "$REPO/src/internal-skills/story-short-write/references/format-and-structure.md"
  grep -q '总目标字数.*计划节数' "$REPO/src/internal-skills/story-short-write/references/format-and-structure.md"
}

@test "accepted section proof requires fresh double gates and current canonical hash" {
  printf '%s\n' '第一节正文' > "$BOOK/正文.md"
  mkdir -p "$BOOK/追踪/private-short-extension"
  hash="$(shasum -a 256 "$BOOK/正文.md" | awk '{print $1}')"
  cat > "$BOOK/追踪/private-short-extension/section-001-anchor.json" <<JSON
{"workflow_id":"wf-short-proof","section_index":1,"status":"accepted","canonical_path":"正文.md","canonical_sha256":"$hash","quality_result":{"machine_gate":"pass","story_value_gate":"pass","repetition_gate":"pass","length_policy":{"blocking":false,"verdict":"baseline_not_established"}}}
JSON
  run node - "$REPO/scripts/lib/short-section-acceptance-proof.js" "$BOOK" "$hash" <<'NODE'
const assert = require('assert');
const { validateShortSectionAcceptanceProof } = require(process.argv[2]);
const root = process.argv[3];
const hash = process.argv[4];
const proof = { workflow_id: 'wf-short-proof', section_index: 1, anchor_path: '追踪/private-short-extension/section-001-anchor.json', canonical_path: '正文.md', canonical_sha256: hash };
assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-short-proof', proof }).status, 'accepted');
const accepted = JSON.parse(require('fs').readFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, 'utf8'));
accepted.quality_result.length_policy = {blocking:true,verdict:'under_target_repair_required',author_decision_required:false};
require('fs').writeFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, JSON.stringify(accepted));
assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-short-proof', proof }).code, 'short_section_length_repair_required');
accepted.quality_result.length_policy = {blocking:false,verdict:'outside_story_band_deferred'};
require('fs').writeFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, JSON.stringify(accepted));
assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-short-proof', proof }).status, 'accepted');
accepted.quality_result.length_policy = {blocking:false,verdict:'observed_length_variance_advisory'};
require('fs').writeFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, JSON.stringify(accepted));
assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-short-proof', proof }).status, 'accepted');
const anchor = require('fs').readFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, 'utf8');
require('fs').writeFileSync(`${root}/追踪/private-short-extension/section-001-anchor.json`, anchor.replace('"story_value_gate":"pass"', '"story_value_gate":"pending"'));
assert.equal(validateShortSectionAcceptanceProof({ projectRoot: root, workflowId: 'wf-short-proof', proof }).code, 'short_section_story_value_gate_missing');
NODE
  [ "$status" -eq 0 ]
}
