#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  CHECK="$REPO/scripts/detail-outline-quality-check.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK/大纲"
}

teardown() {
  rm -rf "$TMP_DIR"
}

make_valid_transition_outline() {
  local target="$1"
  cat > "$target" <<'MD'
# 过渡章
- 核心事件：林昭拿到调度记录并决定继续追查。
- 目标情绪：疑虑转为主动。
#### 情节安排
1. 林昭打开手机保存调度记录，因此确认旧账号仍在使用。
2. 她拨打旧同事电话，却只拿到一个需要继续调查的新地址。
#### 呈现与连续性
- 可见证据：调度记录和通话录音。
- 前置承接：承接上一章的异常调度。
- 本章变化：林昭从怀疑转为掌握追查入口。
- 后续债务：新地址的主人尚未现身。
MD
}

make_semantic_review() {
  local outline="$1"
  local workflow_id="$2"
  SEMANTIC_REVIEW="追踪/workflow/tasks/$workflow_id/work/detail-outline-semantic-review.json"
  mkdir -p "$BOOK/$(dirname "$SEMANTIC_REVIEW")"
  local hash
  hash="$(shasum -a 256 "$BOOK/$outline" | awk '{print $1}')"
  printf '{"outline_path":"%s","outline_sha256":"%s","reviewer":"main-session","findings":[]}' "$outline" "$hash" > "$BOOK/$SEMANTIC_REVIEW"
}

@test "baseline gate passes an actionable progressing outline" {
  cat > "$BOOK/大纲/细纲_第001章.md" <<'MD'
# 第001章 旧账号水印
- 核心事件：平台逼林昭接下错误任务，林昭公开拒绝并保存调度截图。
- 目标情绪：压迫转为主动反击。
- 开篇钩子：后台突然出现一笔不属于她的罚单。
- 爽点：她当众投屏原始记录，让主管无法删证。
#### 情节安排
1. 主管以停单威胁逼她签字；林昭先截屏，再要求对方重复规则。
2. 主管试图拔线，她把手机投到大厅屏幕，围观骑手开始录音。
3. 罚单来源暴露为旧账号，林昭拿到继续追查的入口。
#### 质量触发
- 激活标签：人物线、悬念推进、爽点兑现
- 激活原因：主角第一次主动反击，并建立旧账号悬念。
#### 呈现与连续性
- 可见证据：调度截图、投屏记录、围观者录音。
- 前置承接：承接入职时发现的异常账号。
- 本章变化：林昭从被动申诉转为掌握证据并主动追查。
- 后续债务：旧账号的持有人尚未揭晓。
MD
  make_semantic_review 大纲/细纲_第001章.md wf-long-1
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第001章.md --workflow-id wf-long-1 --semantic-review "$SEMANTIC_REVIEW" --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(x.status!=="pass" || x.activated_dimensions.length!==3 || x.workflow_id!=="wf-long-1" || x.stage_id!=="detail_outline_review" || x.outline_path!=="大纲/细纲_第001章.md" || !/^[0-9a-f]{64}$/.test(x.outline_sha256) || x.contract_projection.length || x.memory_projection.length) process.exit(1)' "$output"
}

@test "baseline gate revises a summary-only outline" {
  printf '# 第001章\n- 核心事件：主角遇到麻烦并解决。\n- 目标情绪：爽。\n#### 情节安排\n1. 主角完成任务并解决问题。\n2. 故事继续推进并发生变化。\n' > "$BOOK/大纲/细纲_第001章.md"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第001章.md --workflow-id wf-long-1 --json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(x.status!=="revise" || !x.findings.some(v=>v.dimension==="B1_causality_action" && v.severity==="blocking")) process.exit(1)' "$output"
}

@test "missing beats blocks projections as outline_underfilled" {
  printf '# 第001章\n- 核心事件：主角回家。\n- 目标情绪：平静。\n' > "$BOOK/大纲/细纲_第001章.md"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第001章.md --workflow-id wf-long-1 --json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(x.status!=="outline_underfilled" || x.contract_projection.length || x.memory_projection.length) process.exit(1)' "$output"
}

@test "sequencing-only beats remain blocked by B1 causality" {
  printf '# 第001章\n- 核心事件：主角处理问题。\n- 目标情绪：平静。\n#### 情节安排\n1. 然后完成处理。\n2. 最终解决问题。\n#### 呈现与连续性\n- 前置承接：上一章问题。\n- 后续债务：下一章结果。\n- 本章变化：问题得到处理。\n' > "$BOOK/大纲/细纲_第001章.md"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第001章.md --workflow-id wf-long-1 --json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(x.status!=="revise" || !x.findings.some(v=>v.dimension==="B1_causality_action" && v.severity==="blocking")) process.exit(1)' "$output"
}

@test "causal connectors without concrete action remain blocked by B1" {
  printf '# 第001章\n- 核心事件：主角处理问题。\n- 目标情绪：平静。\n#### 情节安排\n1. 主角为了完成任务而解决问题。\n2. 因此故事推进并发生变化。\n#### 呈现与连续性\n- 前置承接：上一章问题。\n- 后续债务：下一章结果。\n- 本章变化：故事发生变化。\n' > "$BOOK/大纲/细纲_第001章.md"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第001章.md --workflow-id wf-long-1 --json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(x.status!=="revise" || !x.findings.some(v=>v.dimension==="B1_causality_action" && v.severity==="blocking")) process.exit(1)' "$output"
}

@test "inactive conditional dimensions never block a low-pressure chapter" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第002章.md"
  make_semantic_review 大纲/细纲_第002章.md wf-long-2
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第002章.md --workflow-id wf-long-2 --semantic-review "$SEMANTIC_REVIEW" --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(x.activated_dimensions.length!==0 || x.findings.some(v=>/^C[1-7]_/.test(v.dimension))) process.exit(1)' "$output"
}

@test "semantic findings for inactive conditional dimensions are ignored" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第002章.md"
  make_semantic_review 大纲/细纲_第002章.md wf-long-inactive-semantic
  node - "$BOOK/$SEMANTIC_REVIEW" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const review = JSON.parse(fs.readFileSync(file, 'utf8'));
review.findings = [{ dimension: 'C1_reader_immersion', severity: 'blocking', message: '未激活维度误报' }];
fs.writeFileSync(file, JSON.stringify(review));
NODE
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第002章.md --workflow-id wf-long-inactive-semantic --semantic-review "$SEMANTIC_REVIEW" --json
  [ "$status" -eq 0 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(!/^pass/.test(q.status) || q.findings.some(v=>v.dimension==="C1_reader_immersion") || q.execution.semantic_review.ignored_inactive_findings!==1) process.exit(1)' "$output"
}

@test "ability transition activates and requires a complete chain" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第003章.md"
  cat >> "$BOOK/大纲/细纲_第003章.md" <<'MD'
#### 质量触发
- 激活标签：能力切换
- 激活原因：主角第一次使用新能力。
#### 按需质量卡
- 能力切换链：触发条件只有，没有过程、限制和代价。
MD
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第003章.md --workflow-id wf-long-3 --json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(!x.findings.some(v=>v.dimension==="C4_ability_transition" && v.severity==="blocking")) process.exit(1)' "$output"
}

@test "same outline hash reuses an accepted result packet" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第004章.md"
  RESULT='追踪/workflow/tasks/wf-long-4/result-packets/detail_outline_review.result.json'
  make_semantic_review 大纲/细纲_第004章.md wf-long-4
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第004章.md --workflow-id wf-long-4 --semantic-review "$SEMANTIC_REVIEW" --write-result "$RESULT" --json
  [ "$status" -eq 0 ]
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第004章.md --workflow-id wf-long-4 --semantic-review "$SEMANTIC_REVIEW" --write-result "$RESULT" --reuse-result --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(x.execution.mode!=="reused" || !x.execution.reused_result) process.exit(1)' "$output"
}

@test "result packet writes stay scoped to the workflow result directory" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第005章.md"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第005章.md --workflow-id wf-long-5 --write-result 追踪/workflow/result.json --json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]); const q=x.outputs.detail_outline_quality; if(x.schemaVersion!=="2.0.0" || x.step_status!=="blocked" || q.status!=="revise" || !q.findings.some(v=>v.code==="result_packet_scope")) process.exit(1)' "$output"
}

@test "reuse rejects a packet with a different outline hash" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第006章.md"
  RESULT='追踪/workflow/tasks/wf-long-6/result-packets/detail_outline_review.result.json'
  make_semantic_review 大纲/细纲_第006章.md wf-long-6
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第006章.md --workflow-id wf-long-6 --semantic-review "$SEMANTIC_REVIEW" --write-result "$RESULT" --json
  [ "$status" -eq 0 ]
  printf '\n- 后续债务：新地址已经被人清理。\n' >> "$BOOK/大纲/细纲_第006章.md"
  make_semantic_review 大纲/细纲_第006章.md wf-long-6
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第006章.md --workflow-id wf-long-6 --semantic-review "$SEMANTIC_REVIEW" --write-result "$RESULT" --reuse-result --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"existing result outline_sha256 mismatch"* ]]
}

@test "ability transition rejects a line that only lists ordered labels" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第007章.md"
  cat >> "$BOOK/大纲/细纲_第007章.md" <<'MD'
#### 质量触发
- 激活标签：能力切换
#### 按需质量卡
- 触发前状态 -> 触发条件 -> 过程限制 -> 结果 -> 代价/新限制
MD
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第007章.md --workflow-id wf-long-7 --json
  [ "$status" -eq 2 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(!q.findings.some(v=>v.dimension==="C4_ability_transition" && v.severity==="blocking")) process.exit(1)' "$output"
}

@test "ability transition accepts an ordered structured nonempty chain" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第008章.md"
  cat >> "$BOOK/大纲/细纲_第008章.md" <<'MD'
#### 质量触发
- 激活标签：能力切换
#### 按需质量卡
- 触发前状态：林昭只能依靠旧账号记录定位对手。
- 触发条件：她接通旧账号发来的加密来电。
- 过程限制：她每次只能保持三分钟同步，且需要持续录音。
- 结果：她锁定了主管删除记录的终端。
- 代价/新限制：同步耗尽手机电量，终端将在明早更换。
MD
  make_semantic_review 大纲/细纲_第008章.md wf-long-8
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第008章.md --workflow-id wf-long-8 --semantic-review "$SEMANTIC_REVIEW" --json
  [ "$status" -eq 0 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(q.findings.some(v=>v.dimension==="C4_ability_transition")) process.exit(1)' "$output"
}

@test "information load blocks four ordinary named concepts without demonstration" {
  cat > "$BOOK/大纲/细纲_第009章.md" <<'MD'
# 第009章 名物来源
- 核心事件：林昭发现四件新名物来自同一份调度档案。
- 目标情绪：疑虑转为警觉。
#### 情节安排
1. 新概念：赤铜星核、霜月钥、夜航印、潮汐码；林昭说起它们，因此主管解释来源。
2. 林昭打开手机保存主管的解释录音，发现旧账号仍在使用。
#### 质量触发
- 激活标签：信息负载
#### 呈现与连续性
- 可见证据：解释录音和调度档案。
- 前置承接：承接上一章发现的异常账号。
- 本章变化：林昭从怀疑转为掌握四件名物的共同来源。
- 后续债务：旧账号的持有人尚未揭晓。
MD
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第009章.md --workflow-id wf-long-9 --json
  [ "$status" -eq 2 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(!q.findings.some(v=>v.dimension==="C3_information_load" && v.severity==="blocking")) process.exit(1)' "$output"
}

@test "information load permits four ordinary named concepts with demonstration" {
  cat > "$BOOK/大纲/细纲_第010章.md" <<'MD'
# 第010章 名物验真
- 核心事件：林昭逐一验证四件新名物并保存结果。
- 目标情绪：疑虑转为主动。
#### 情节安排
1. 新概念：赤铜星核、霜月钥、夜航印、潮汐码；林昭打开资料夹逐一投屏展示，因此主管承认它们来自旧账号。
2. 林昭保存主管录音并拨打旧同事电话，拿到继续追查的新地址。
#### 质量触发
- 激活标签：信息负载
#### 呈现与连续性
- 可见证据：投屏记录、主管录音和资料夹截图。
- 前置承接：承接上一章发现的异常账号。
- 本章变化：林昭从怀疑转为掌握四件名物的验证结果。
- 后续债务：新地址的主人尚未现身。
MD
  make_semantic_review 大纲/细纲_第010章.md wf-long-10
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第010章.md --workflow-id wf-long-10 --semantic-review "$SEMANTIC_REVIEW" --json
  [ "$status" -eq 0 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(q.findings.some(v=>v.dimension==="C3_information_load")) process.exit(1)' "$output"
}

@test "information load does not infer bare Chinese noun compounds as new concepts" {
  cat > "$BOOK/大纲/细纲_第012章.md" <<'MD'
# 第012章 名物闲谈
- 核心事件：林昭听主管提到几件旧物并保存录音。
- 目标情绪：疑虑转为警觉。
#### 情节安排
1. 林昭听主管提到赤铜星核、霜月钥、夜航印、潮汐码，因此主管解释这些都是旧称。
2. 林昭打开手机保存主管录音，发现旧账号仍在使用。
#### 质量触发
- 激活标签：信息负载
#### 呈现与连续性
- 可见证据：主管录音和调度档案。
- 前置承接：承接上一章发现的异常账号。
- 本章变化：林昭从怀疑转为掌握旧称来源。
- 后续债务：旧账号的持有人尚未揭晓。
MD
  make_semantic_review 大纲/细纲_第012章.md wf-long-12
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第012章.md --workflow-id wf-long-12 --semantic-review "$SEMANTIC_REVIEW" --json
  [ "$status" -eq 0 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(q.findings.some(v=>v.dimension==="C3_information_load")) process.exit(1)' "$output"
}

@test "chapter position is part of reuse identity and fresh writes replace it" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第011章.md"
  RESULT='追踪/workflow/tasks/wf-long-11/result-packets/detail_outline_review.result.json'
  make_semantic_review 大纲/细纲_第011章.md wf-long-11
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第011章.md --workflow-id wf-long-11 --chapter-position transition --semantic-review "$SEMANTIC_REVIEW" --write-result "$RESULT" --json
  [ "$status" -eq 0 ]
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第011章.md --workflow-id wf-long-11 --chapter-position end --semantic-review "$SEMANTIC_REVIEW" --write-result "$RESULT" --reuse-result --json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]); const q=x.outputs.detail_outline_quality; if(x.schemaVersion!=="2.0.0" || x.step_status!=="blocked" || q.status!=="revise" || !q.findings.some(v=>v.code==="reuse_chapter_position_mismatch")) process.exit(1)' "$output"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第011章.md --workflow-id wf-long-11 --chapter-position end --semantic-review "$SEMANTIC_REVIEW" --write-result "$RESULT" --json
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); const q=x.outputs.detail_outline_quality; if(q.chapter_position!=="end" || q.execution.mode!=="fresh") process.exit(1)' "$output"
}

@test "validation errors emit a blocked v2 envelope without json" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第013章.md"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第013章.md --workflow-id wf-long-13 --write-result 追踪/workflow/outside.json
  [ "$status" -eq 2 ]
  node -e 'const x=JSON.parse(process.argv[1]); const q=x.outputs.detail_outline_quality; if(x.schemaVersion!=="2.0.0" || x.step_status!=="blocked" || x.verification_result!=="blocked" || q.status!=="revise" || !q.findings.some(v=>v.code==="result_packet_scope")) process.exit(1)' "$output"
}

@test "help emits an advisory v2 envelope" {
  run node "$CHECK" --help
  [ "$status" -eq 0 ]
  node -e 'const x=JSON.parse(process.argv[1]); const q=x.outputs.detail_outline_quality; if(x.schemaVersion!=="2.0.0" || x.step_status!=="completed" || x.verification_result!=="pass" || q.status!=="pass_with_advisory" || q.contract_projection.length || q.memory_projection.length || !q.findings.some(v=>v.code==="help_requested" && /Usage:/.test(v.message))) process.exit(1)' "$output"
}

@test "semantic review merges blocking findings without deleting deterministic findings" {
  run node - "$REPO/scripts/lib/detail-outline-quality.js" <<'NODE'
const assert = require('assert');
const { mergeSemanticReview } = require(process.argv[2]);
const hash = 'a'.repeat(64);
const baseResult = {
  status: 'pass_with_advisory',
  outline_path: '大纲/第1卷/细纲_第001章.md',
  outline_sha256: hash,
  activated_dimensions: ['C7_payoff_debt'],
  findings: [{ dimension: 'B2_visible_evidence', severity: 'advisory', message: '需要更明确的场面证据' }],
  execution: { mode: 'fresh', reused_result: false },
};
const merged = mergeSemanticReview(baseResult, {
  outline_path: baseResult.outline_path,
  outline_sha256: baseResult.outline_sha256,
  reviewer: 'story-architect',
  findings: [{ dimension: 'C7_payoff_debt', severity: 'blocking', message: '反击没有产生可见后果', evidence: '爽点字段仅写“完成打脸”' }],
});
assert.equal(merged.status, 'revise');
assert.equal(merged.execution.semantic_reviewer, 'story-architect');
assert.equal(merged.findings.length, 2);
assert.equal(merged.findings[0].dimension, 'B2_visible_evidence');
assert.throws(() => mergeSemanticReview(baseResult, { outline_path: baseResult.outline_path, outline_sha256: '0'.repeat(64), reviewer: 'story-architect', findings: [] }), /semantic_review_identity_mismatch/);
assert.throws(() => mergeSemanticReview(baseResult, { outline_path: baseResult.outline_path, outline_sha256: hash, reviewer: 'story-architect', findings: [{ dimension: 'C8_unknown', severity: 'blocking', message: 'x' }] }), /semantic_review_dimension_invalid/);
assert.throws(() => mergeSemanticReview(baseResult, { outline_path: baseResult.outline_path, outline_sha256: hash, reviewer: 'story-architect', findings: [{ dimension: 'C7_payoff_debt', severity: 'warning', message: 'x' }] }), /semantic_review_severity_invalid/);
NODE
  [ "$status" -eq 0 ]
}

@test "CLI merges a workflow work semantic artifact into the only official packet" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第014章.md"
  printf '\n#### 质量触发\n- 激活标签：爽点兑现\n' >> "$BOOK/大纲/细纲_第014章.md"
  WORK='追踪/workflow/tasks/wf-long-14/work/detail-outline-semantic-review.json'
  RESULT='追踪/workflow/tasks/wf-long-14/result-packets/detail_outline_review.result.json'
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-long-14/work"
  hash="$(shasum -a 256 "$BOOK/大纲/细纲_第014章.md" | awk '{print $1}')"
  cat > "$BOOK/$WORK" <<JSON
{"outline_path":"大纲/细纲_第014章.md","outline_sha256":"$hash","reviewer":"story-architect","findings":[{"dimension":"C7_payoff_debt","severity":"blocking","message":"反击没有产生可见后果","evidence":"爽点字段仅写完成打脸"}]}
JSON

  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第014章.md --workflow-id wf-long-14 --semantic-review "$WORK" --write-result "$RESULT" --json
  [ "$status" -eq 2 ]
  node - "$output" "$BOOK/$RESULT" "$BOOK/$WORK" <<'NODE'
const fs = require('fs');
const stdout = JSON.parse(process.argv[2]);
const packet = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const semantic = JSON.parse(fs.readFileSync(process.argv[4], 'utf8'));
const quality = packet.outputs.detail_outline_quality;
if (JSON.stringify(stdout) !== JSON.stringify(packet)) throw new Error('stdout and official packet diverged');
if (packet.result_contract_version !== 2 || quality.status !== 'revise') throw new Error(JSON.stringify(packet));
if (quality.execution.semantic_reviewer !== 'story-architect') throw new Error(JSON.stringify(quality.execution));
if (!quality.findings.some(item => item.dimension === 'C7_payoff_debt' && item.severity === 'blocking')) throw new Error(JSON.stringify(quality.findings));
if (semantic.findings.length !== 1 || Object.prototype.hasOwnProperty.call(semantic, 'outputs')) throw new Error('temporary semantic artifact was rewritten');
NODE
}

@test "CLI rejects semantic artifacts outside the owning workflow work directory" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第015章.md"
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-long-15"
  printf '{"outline_path":"大纲/细纲_第015章.md","outline_sha256":"%064d","reviewer":"story-architect","findings":[]}' 0 > "$BOOK/追踪/workflow/tasks/wf-long-15/semantic.json"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第015章.md --workflow-id wf-long-15 --semantic-review 追踪/workflow/tasks/wf-long-15/semantic.json --json
  [ "$status" -eq 2 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(!q.findings.some(item=>item.code==="semantic_review_scope")) process.exit(1)' "$output"
}

@test "CLI leaves a deterministic pass awaiting semantic review" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第016章.md"
  RESULT='追踪/workflow/tasks/wf-long-16/result-packets/detail_outline_review.result.json'
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第016章.md --workflow-id wf-long-16 --write-result "$RESULT" --json
  [ "$status" -eq 2 ]
  node -e 'const q=JSON.parse(process.argv[1]).outputs.detail_outline_quality; if(q.status!=="awaiting_semantic_review" || q.execution.semantic_review.status!=="required") process.exit(1)' "$output"
}

@test "reuse remerges the current semantic review instead of retaining an old pass" {
  make_valid_transition_outline "$BOOK/大纲/细纲_第017章.md"
  printf '\n#### 质量触发\n- 激活标签：悬念推进\n' >> "$BOOK/大纲/细纲_第017章.md"
  WORK='追踪/workflow/tasks/wf-long-17/work/detail-outline-semantic-review.json'
  RESULT='追踪/workflow/tasks/wf-long-17/result-packets/detail_outline_review.result.json'
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-long-17/work"
  hash="$(shasum -a 256 "$BOOK/大纲/细纲_第017章.md" | awk '{print $1}')"
  printf '{"outline_path":"大纲/细纲_第017章.md","outline_sha256":"%s","reviewer":"main-session","findings":[]}' "$hash" > "$BOOK/$WORK"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第017章.md --workflow-id wf-long-17 --semantic-review "$WORK" --write-result "$RESULT" --json
  [ "$status" -eq 0 ]
  printf '{"outline_path":"大纲/细纲_第017章.md","outline_sha256":"%s","reviewer":"main-session","findings":[{"dimension":"C5_suspense_progression","severity":"blocking","message":"新问题没有升级","evidence":"后续债务没有改变"}]}' "$hash" > "$BOOK/$WORK"
  run node "$CHECK" --project-root "$BOOK" --outline 大纲/细纲_第017章.md --workflow-id wf-long-17 --semantic-review "$WORK" --write-result "$RESULT" --reuse-result --json
  [ "$status" -eq 2 ]
  node - "$BOOK/$RESULT" <<'NODE'
const packet = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const quality = packet.outputs.detail_outline_quality;
if (quality.status !== 'revise' || !quality.findings.some(item => item.dimension === 'C5_suspense_progression' && item.severity === 'blocking')) process.exit(1);
NODE
}

@test "semantic findings ignore inactive conditional dimensions" {
  run node - "$REPO/scripts/lib/detail-outline-quality.js" <<'NODE'
const assert = require('assert');
const { mergeSemanticReview } = require(process.argv[2]);
const base = { outline_path: '大纲/第1卷/细纲_第001章.md', outline_sha256: 'a'.repeat(64), activated_dimensions: ['C5_suspense_progression'], findings: [], execution: {} };
const result = mergeSemanticReview(base, {
  outline_path: base.outline_path,
  outline_sha256: base.outline_sha256,
  reviewer: 'main-session',
  findings: [{ dimension: 'C7_payoff_debt', severity: 'blocking', message: 'x' }],
});
assert.equal(result.status, 'pass');
assert.equal(result.findings.length, 0);
assert.equal(result.execution.semantic_review.ignored_inactive_findings, 1);
NODE
  [ "$status" -eq 0 ]
}

@test "accepted quality result projects the quality gate and declared deltas" {
  run node - "$REPO/scripts/lib/detail-outline-quality-projection.js" <<'NODE'
const assert = require('assert');
const { projectAcceptedQuality } = require(process.argv[2]);
const result = {
  status: 'pass',
  workflow_id: 'wf-long-projection',
  outline_path: '大纲/第1卷/细纲_第001章.md',
  outline_sha256: 'a'.repeat(64),
  activated_dimensions: ['C5_suspense_progression'],
  contract_projection: ['B1 必须写成场景。', '可见证据：调度记录和通话录音。'],
  memory_projection: [{
    kind: 'promise',
    dimension: 'C5_suspense_progression',
    workflow_id: 'wf-long-projection',
    outline_sha256: 'a'.repeat(64),
    source_path: '大纲/第1卷/细纲_第001章.md',
    source_kind: 'canonical',
    valid_from: 'chapter-001',
    evidence: '新地址的主人尚未现身。',
  }],
  execution: { completed_at: '2026-07-17T00:00:00.000Z' },
};
const projected = projectAcceptedQuality(result);
assert.equal(projected.beatSheetQualityGate.status, 'pass');
assert.equal(projected.beatSheetQualityGate.outlineSha256, result.outline_sha256);
assert(projected.contractProjection.some(x => /可见证据/.test(x)));
assert(projected.memoryProjection.some(x => x.kind === 'promise' && x.dimension === 'C5_suspense_progression'));
assert.deepEqual(projectAcceptedQuality({ status: 'outline_underfilled' }), {
  beatSheetQualityGate: null,
  contractProjection: [],
  memoryProjection: [],
});
NODE
  [ "$status" -eq 0 ]
}

@test "managed longform outline requires a complete plot unit and reader contract" {
  run node - "$REPO/scripts/lib/detail-outline-quality.js" <<'NODE'
const assert = require('assert');
const { evaluateDetailOutline } = require(process.argv[2]);
const base = `# 第001章
- 核心事件：林昭保存调度记录并继续追查。
- 目标情绪：疑虑转为主动。
## 情节安排
1. 林昭打开手机保存调度记录，因此确认旧账号仍在使用。
2. 她拨打旧同事电话，拿到需要继续调查的新地址。
## 呈现与连续性
- 可见证据：调度记录和通话录音。
- 前置承接：承接上一章的异常调度。
- 本章变化：林昭从怀疑转为掌握追查入口。
- 后续债务：新地址的主人尚未现身。
## 剧情单元合同
- 剧情单元ID：PU-V01-001
- 单元位置：1/4
- 本章读者问题：旧账号为什么仍在使用？
- 本章可见回报：林昭拿到新地址。
- 关键转折：旧同事承认账号被人接管。
- 本章净变化：林昭从被动怀疑转为主动追查。
- 继承钩子责任：继续追查异常水印 P-旧账号水印。
- 终局储备动作：不动用终极身份底牌。
`;
const passed = evaluateDetailOutline({ text: base, outlinePath: '大纲/第1卷/细纲_第001章.md' });
assert.equal(passed.status, 'pass');
assert.equal(passed.narrative_contract.status, 'complete');
assert.equal(passed.narrative_contract.plot_unit.id, 'PU-V01-001');
assert(passed.contract_projection.some(item => /本章读者问题/.test(item)));

const incomplete = evaluateDetailOutline({ text: base.replace('- 本章净变化：林昭从被动怀疑转为主动追查。\n', '') });
assert.equal(incomplete.status, 'revise');
assert(incomplete.findings.some(item => item.dimension === 'B5_narrative_contract' && item.field === 'netChange'));

const legacy = evaluateDetailOutline({ text: base.replace(/## 剧情单元合同[\s\S]*$/, '') });
assert.equal(legacy.status, 'pass');
assert.equal(legacy.narrative_contract.status, 'legacy_compatible');
NODE
  [ "$status" -eq 0 ]
}
