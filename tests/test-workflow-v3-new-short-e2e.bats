#!/usr/bin/env bats

# Task: project-neutral end-to-end RED for the new V3 short lifecycle.
#
# This file is the FIRST acceptance-level RED for the new V3 short lifecycle.
# It drives the workflow-v3.js CLI only — no direct require of planning.js,
# section-loop.js, or closure.js to advance a stage. Every professional stage
# is advanced by the production run-stage command:
#
#     material_positioning, setting, section_outline, section_brief,
#     section_draft, machine_gate, story_gate, section_accept, assembly,
#     editorial_review, deslop, final_check
#
# creative_entry and planning_confirmation advance via the existing apply-result
# command (their semantics are engine-owned and host-facing, not a staged
# artifact). The needs_author_choice pause + four-field resolve + Chat-style
# revision confirmation all flow through the existing show / resolve commands.
#
# This test was introduced RED before the production entry existed. Its first
# failure was the missing run-stage command rather than Bash syntax or a
# fixture-contract error; the implementation now keeps that path GREEN.
#
# Two read-only boundaries are covered in separate tests:
#   1. context-file carrying any of {task, current_stage, workflow_id,
#      projectRoot, expectedVersion} is rejected (durable task.json must stay
#      byte-for-byte unchanged).
#   2. run-stage must refuse creative_entry / planning_confirmation /
#      section_repair (those stages have specific engine or apply-result paths
#      and must never be invokable through the staged-artifact entry point).
#
# Domain: archive number reconciliation. Synthetic characters 阿岚 (校对员) /
# 老沈 (主管). No real project titles, character names, or domain vocabulary.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    CLI="$REPO/scripts/workflow-v3.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/story-system"
    printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$PROJECT/追踪/story-system/write-policy.json"
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Helper: invoke create-short via `run`, then persist the emitted JSON payload.
create_short() {
    local goal="$1"
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "$goal" \
        --json
    printf '%s\n' "$output" > "$TMP_DIR/create.json"
}

# Helper: invoke apply-result via `run` and persist its JSON payload.
apply_result() {
    local expected="$1"
    run node "$CLI" apply-result \
        --project-root "$PROJECT" \
        --workflow-id "$WFID" \
        --expected-version "$expected" \
        --result-file "$TMP_DIR/result.json" \
        --json
    printf '%s\n' "$output" > "$TMP_DIR/apply.json"
}

# Helper: invoke run-stage via `run` and persist its output.
run_stage() {
    local stage="$1"
    local context="$2"
    local expected
    expected=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$PROJECT/$TASK_DIR/task.json','utf8')).state_version)")
    run node "$CLI" run-stage \
        --project-root "$PROJECT" \
        --workflow-id "$WFID" \
        --expected-version "$expected" \
        --stage "$stage" \
        --context-file "$context" \
        --json
    printf '%s\n' "$output" > "$TMP_DIR/runstage.json"
}

run_current_stage() {
    local expected
    expected=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$PROJECT/$TASK_DIR/task.json','utf8')).state_version)")
    run node "$CLI" run-current-stage \
        --project-root "$PROJECT" \
        --workflow-id "$WFID" \
        --expected-version "$expected" \
        --json
    printf '%s\n' "$output" > "$TMP_DIR/run-current-stage.json"
}

# Helper: invoke show and persist its JSON payload.
show_state() {
    run node "$CLI" show --project-root "$PROJECT" --workflow-id "$WFID" --json
    printf '%s\n' "$output" > "$TMP_DIR/show.json"
}

# Helper: invoke resolve with a prebuilt input-file.
resolve_choice() {
    local expected="$1"
    local input="$2"
    run node "$CLI" resolve \
        --project-root "$PROJECT" \
        --workflow-id "$WFID" \
        --expected-version "$expected" \
        --input-file "$input" \
        --json
    printf '%s\n' "$output" > "$TMP_DIR/resolve.json"
}

# Helper: substring assertion via grep + `[ ]`. `[[ ]]` does NOT abort a bats
# test under this shell, so substring checks are routed through `[ ]`.
assert_contains() {
    local needle="$1"
    printf '%s' "$output" | grep -F -- "$needle" >/dev/null
}
refute_contains() {
    local needle="$1"
    if printf '%s' "$output" | grep -F -- "$needle" >/dev/null; then
        echo "expected output NOT to contain: $needle" >&3
        echo "actual: $output" >&3
        return 1
    fi
}

# --- project-neutral fixtures ----------------------------------------------
# Archive number reconciliation domain. All names, beats, and consequences are
# synthetic. The setting exercises the REAL short character contract
# (protagonist goal / flaw / mistaken belief / capability boundary + 主管
# independent stake + 阿岚<->主管 关系债).

NEUTRAL_MATERIAL='# 素材与定位

核心素材：档案校对员发现两个批次使用了同一编号。
短篇定位：以公开复核推动责任落地，共两节完成。
'

NEUTRAL_SETTING='# 设定

作品名：测试短篇
叙事方式：第一人称。
目标长度：共2节。
主节奏：发现异常 -> 修复。

## 主要人物

### 阿岚，25岁，女主
第一人称"我"。目标是查清档案中重复出现的编号错误；软肋是害怕同事被牵连；误信只要自己加班就能补齐。她不懂系统底层逻辑。最终选择是亲自提交补丁并接受复核。

### 老沈，40岁，主管
他要保住季度交付和团队稳定，认为压下问题能争取修复时间；拥有审批权限，但不能无成本甩锅给执行人。

## 角色锁定卡
| 角色名 | 性别/称谓/视角身份 | 年龄/职业 | 与主角关系 | 本篇目标 | 行动边界 |
|---|---|---|---|---|---|
| 阿岚 | 女，第一人称"我" | 25岁，校对员 | 部门成员 | 查清编号错误 | 不擅自删除历史记录 |
| 老沈 | 男，称"主管" | 40岁，主管 | 主管/压力角色 | 保住交付 | 不调用外部关系 |

## 人物关系与责任债
- 阿岚欠主管一次通融；主管欠阿岚一次公开的真相。
'

# A neutral two-section outline. Section 1 = opening (黄金开篇); section 2 =
# ending (结尾收束). Each section's children satisfy the outline contract.
NEUTRAL_OUTLINE='# 小节大纲

核心路线：发现编号错误，再用公开补丁恢复档案可信度。

## 第1节：发现重复编号
- 结构功能：黄金开篇，兑现标题画面
- 情绪目标：疑惑到警觉
- 因果链：扫描报告跳错，阿岚拒绝关停并追查
- 场景动作：阿岚移动光标，当面拒绝主管撤回
- 主角选择：她选择保留扫描回放
- 子事件：
  1. 阿岚扫描时看见编号重复出现
  2. 主管逼她撤回，她拒绝并公开追问
- 节尾钩子：主管承认编号源自旧批次

## 第2节：恢复正确编号
- 结构功能：结尾收束责任与档案承诺
- 情绪目标：压力升高到责任落地
- 因果链：承接主管承认旧批次，阿岚推动补丁和复核
- 承接上节：主管承认编号源自旧批次
- 场景动作：阿岚在评审会提交补丁和复核方案
- 主角选择：她选择提交补丁并公开新编号
- 子事件：
  1. 阿岚提交补丁并暂停主管审批
  2. 她启动新编号入档复核，承担延期
- 现实后果：旧号回滚，主管停权，排期承压
- 关系收束：阿岚与主管保持裂痕，不用情面替责任结账
- 结尾回扣：编号终于可追溯，读者可以自行核验
- 节尾钩子：新编号接受长期公开复核
'

# Neutral section Briefs (each references every required outline obligation).
NEUTRAL_BRIEF_1='# 第1节写作提要

## 大纲覆盖映射
- S00：黄金开篇，兑现标题画面
- B01：阿岚扫描时看见编号重复出现
- B02：主管逼她撤回，她拒绝并公开追问
- A01：阿岚移动光标，当面拒绝主管撤回
- C01：她选择保留扫描回放
- H01：主管承认编号源自旧批次

## 因果动作链
[B01] -> [B02] -> [A01] -> [C01] -> [H01]

## 承接
- 开篇直接进入当前冲突。

## 目标与阻力
- 阿岚要查清编号错误，主管要求她撤回。

## 人物与视角锁
- 第一人称"我"，只使用当前已确认人物。

## 禁写项
- 不提前揭晓下一节证据。

## 节尾钩子
- 主管承认编号源自旧批次。

## 验收
- 人物选择、因果变化和节尾钩子成立。
'

NEUTRAL_BRIEF_2='# 第2节写作提要

## 大纲覆盖映射
- S00：结尾收束责任与档案承诺
- B01：阿岚提交补丁并暂停主管审批
- B02：她启动新编号入档复核，承担延期
- A01：阿岚在评审会提交补丁和复核方案
- C01：她选择提交补丁并公开新编号
- H01：新编号接受长期公开复核
- N01：旧号回滚，主管停权，排期承压
- L01：阿岚与主管保持裂痕，不用情面替责任结账
- T01：编号终于可追溯，读者可以自行核验
- Q01：主管承认编号源自旧批次

## 因果动作链
[Q01] -> [B01] -> [B02] -> [A01] -> [C01] -> [N01] -> [L01] -> [T01] -> [H01]

## 承接
- 主管承认编号源自旧批次。

## 目标与阻力
- 阿岚要恢复正确编号，主管仍想延期公布。

## 人物与视角锁
- 第一人称"我"，只使用当前已确认人物。

## 禁写项
- 不引入旧号之外的新剧情线。

## 节尾钩子
- 新编号接受长期公开复核。

## 验收
- 责任落地与可核验的结尾兑现。
'

# Neutral section prose (passes the real machine-gate stack: AI patterns,
# anti-AI, output pollution, degeneration, story-prose gate).
NEUTRAL_DRAFT_1='# 第1节

我把扫描回放投到评审室的白墙上。屏幕里，归档编号在两个不同批次里重复出现，扫描任务一直跑，档案却对不上。主管推门进来，让我立刻撤回这次扫描，理由是季度交付吃紧。我没有替自己解释，只问在座的人敢不敢把旧批次的原始记录也投上去。我沉默地接过撤回单，指尖压在签名栏上，那是我从未见过的字迹。窗外的雨砸在玻璃上，评审室的灯白得刺眼。我抬起头，看着主管，慢慢开口，请他把旧批次也摆到桌面上。他怔了很久，最后承认那批编号源自三年前停用的旧批次。
'

NEUTRAL_DRAFT_2='# 第2节

评审会上，我把补丁和新编号的复核方案一起推到桌面正中。主管仍想延期公布，理由是排期和考核都要承压。我没有退缩，只把旧号回滚和独立复核的步骤逐项念给在座的人听。窗外的光斜斜落在原始记录上，纸面的旧编号被划掉，新编号写在旁边。我承担了延期带来的成本，也接受主管停权后的代签流程。最后，新编号接受长期公开复核，任何人都能在档案里追溯这一次纠错。我没有再用情面替责任结账，主管也保持沉默地接受了这个结果。
'

# --- main e2e happy path ---------------------------------------------------

@test "V3 new short e2e lifecycle creates a task, advances every stage through run-stage, and closes the lifecycle" {
    # 1. create-short: the existing CLI command lands the V3 first durable task.
    create_short "档案复核短篇"
    [ "$status" -eq 0 ]
    WFID=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")
    TASK_DIR=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.task_dir)")
    [ -n "$WFID" ]
    [ -n "$TASK_DIR" ]

    # 2. creative_entry advances via apply-result (engine-owned semantic).
    printf '{"kind":"completed","code":"creative_entry_confirmed","stage_id":"creative_entry"}\n' > "$TMP_DIR/result.json"
    apply_result 1
    [ "$status" -eq 0 ]
    [ "$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/apply.json','utf8')).task.current_stage)")" = "material_positioning" ]

    # 3. Planning resumes through the same describe/run-current contract used
    #    by real hosts. The durable stage attempt owns the staged path.
    node "$CLI" describe-stage --project-root "$PROJECT" --workflow-id "$WFID" --json > "$TMP_DIR/describe.json"
    STAGED_REL=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).stage_execution.write_set[0])" "$TMP_DIR/describe.json")
    mkdir -p "$(dirname "$PROJECT/$STAGED_REL")"
    printf '%s' "$NEUTRAL_MATERIAL" > "$PROJECT/$STAGED_REL"
    run_current_stage
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # 4. setting: the next durable attempt exposes its own staged path.
    node "$CLI" describe-stage --project-root "$PROJECT" --workflow-id "$WFID" --json > "$TMP_DIR/describe.json"
    STAGED_REL=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).stage_execution.write_set[0])" "$TMP_DIR/describe.json")
    mkdir -p "$(dirname "$PROJECT/$STAGED_REL")"
    printf '%s' "$NEUTRAL_SETTING" > "$PROJECT/$STAGED_REL"
    run_current_stage
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # 5. section_outline: same recovery path, no hand-built context file.
    node "$CLI" describe-stage --project-root "$PROJECT" --workflow-id "$WFID" --json > "$TMP_DIR/describe.json"
    STAGED_REL=$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).stage_execution.write_set[0])" "$TMP_DIR/describe.json")
    mkdir -p "$(dirname "$PROJECT/$STAGED_REL")"
    printf '%s' "$NEUTRAL_OUTLINE" > "$PROJECT/$STAGED_REL"
    run_current_stage
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # 6. planning_confirmation is the author's approval of the accepted outline.
    # It must atomically bind the title list before the first Brief; tests may
    # not fabricate that production artifact after the transition.
    printf '{"kind":"completed","code":"planning_confirmed","stage_id":"planning_confirmation"}\n' > "$TMP_DIR/result.json"
    apply_result 5
    [ "$status" -eq 0 ]
    [ "$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/apply.json','utf8')).task.current_stage)")" = "section_brief" ]
    node - "$REPO" "$PROJECT" "$WFID" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, workflowId] = process.argv.slice(2);
const { resolveShortStateRelative } = require(path.join(repo, 'scripts/lib/short-project-state'));
const stateRel = resolveShortStateRelative(root, 'project-state.json');
const state = JSON.parse(fs.readFileSync(path.join(root, stateRel), 'utf8'));
const lockRel = resolveShortStateRelative(root, 'section-title-lock.json');
const lock = JSON.parse(fs.readFileSync(path.join(root, lockRel), 'utf8'));
assert.equal(lock.status, 'confirmed');
assert.equal(lock.workflow_id, workflowId);
assert.equal(lock.project_id, state.project_id);
assert.equal(lock.plan_revision, state.plan_revision);
assert.deepEqual(lock.sections.map(item => item.title), ['发现重复编号', '恢复正确编号']);
NODE

    # 7. The confirmed title lock and section-1 Brief live on disk before section_brief advances.
    printf '%s' "$NEUTRAL_BRIEF_1" > "$PROJECT/写作Brief_第001节.md"
    run_current_stage
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # 8. section_draft + machine_gate + story_gate + section_accept for section 1.
    printf '%s' "$NEUTRAL_DRAFT_1" > "$PROJECT/草稿_第001节_候选.md"
    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第001节_候选.md","section_index":1}
JSON
    run_stage section_draft "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第001节_候选.md","section_index":1}
JSON
    run_stage machine_gate "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # The story gate consumes a real evidence card written on disk by the test
    # so the gate has something to validate (no auto-pass on missing evidence).
    node - "$REPO" "$PROJECT" "$TASK_DIR" "$WFID" 1 <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root, taskDir, workflowId, sectionIndex] = process.argv.slice(2);
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store'));
const { buildShortSectionOutlineContract } = require(path.join(repo, 'scripts/lib/short-section-outline-contract'));
const { resolveShortReaderMilestone } = require(path.join(repo, 'scripts/lib/short-reader-milestone-policy'));
const { QUALITY_CHECKS } = require(path.join(repo, 'scripts/lib/short-section-quality-evidence'));
const draftFile = path.join(root, '草稿_第001节_候选.md');
const draftText = fs.readFileSync(draftFile, 'utf8');
const draftDigest = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(draftFile)).digest('hex')}`;
const outlineContract = buildShortSectionOutlineContract(root, Number(sectionIndex));
if (outlineContract.status !== 'current') throw new Error(JSON.stringify(outlineContract));
const readerMilestone = resolveShortReaderMilestone({
  sectionIndex: Number(sectionIndex), outlineContract, task: { workflow_id: workflowId },
});
const quotes = draftText
  .replace(/^#{1,6}[^\n]*$/gmu, '')
  .split(/[。！？\n]+/u)
  .map((item) => item.trim())
  .filter((item) => item.length >= 6);
if (quotes.length < 4) throw new Error('test_evidence_quotes_underfilled');
const required = (outlineContract.obligations || []).filter((item) => item.required_in_draft);
const outlineCoverage = required.map((item, index) => ({
  id: item.id, status: 'pass',
  evidence_quote: quotes[Math.floor(index / 2) % quotes.length],
}));
const evidence = {
  schemaVersion: '1.0.0',
  workflow_id: workflowId,
  section_index: Number(sectionIndex),
  draft_digest: draftDigest,
  outline_contract_digest: String(outlineContract.contract_digest || ''),
  checks: QUALITY_CHECKS.map((id, index) => ({
    id, status: 'pass', evidence: '正文已有可核验的具体推进',
    evidence_quote: quotes[index % quotes.length],
  })),
  outline_coverage: outlineCoverage,
  summary: '当前小节的人物行动、因果变化与阅读牵引均有正文证据。',
  acceptance_metadata: {
    revealed_information: ['当前小节新增信息已经在正文中明确呈现'],
    character_state: { 阿岚: '完成当前选择并承担相应后果' },
    relationship_state: { '阿岚与老沈': '关系因公开选择发生变化' },
    decisions: ['保留可复核记录并承担选择后果'],
    present_characters: ['阿岚', '老沈'],
    open_hook: outlineContract.section_role === 'ending' ? '' : '旧批次编号仍需在下一节完成公开复核',
  },
};
if (readerMilestone.required) {
  evidence.reader_milestone = {
    reviewer: 'professional-reader', kind: readerMilestone.kind, status: 'pass',
    would_continue: 'yes',
    strongest_pull: '主角已经作出带代价的具体选择',
    biggest_resistance: '后续责任如何落地仍需继续兑现',
    evidence_quote: quotes[0], repair_direction: '',
  };
}
atomicWriteJson(path.join(root, taskDir, `artifacts/section-001-story-review-pass.json`), evidence);
NODE

    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第001节_候选.md","section_index":1,"evidence_rel":"$TASK_DIR/artifacts/section-001-story-review-pass.json"}
JSON
    run_stage story_gate "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第001节_候选.md","section_index":1,"evidence_rel":"$TASK_DIR/artifacts/section-001-story-review-pass.json"}
JSON
    run_stage section_accept "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # --- needs_author_choice pause + Chat revision confirmation -----------
    # The brief-finalize overload path asks the author to revise the brief
    # before drafting section 2. We simulate it by posting an overloaded
    # section-2 Brief through run-stage, then expect show to render an
    # interaction and resolve to consume the four-field binding.
    printf '%s\n%s\n' "$NEUTRAL_BRIEF_2" "## 证据机制
1. 现场记录。
2. 书面凭据。
3. 第三方核验。
4. 时间线复核。

## 本节承担项
1. 回答核心疑问。
2. 兑现前置承诺。
3. 处理直接后果。
4. 完成人物关系变化。
5. 建立下一阶段的新状态。
" > "$PROJECT/写作Brief_第002节.md"
    cat > "$TMP_DIR/ctx.json" <<JSON
{"brief_rel":"写作Brief_第002节.md","section_index":2}
JSON
    run_stage section_brief "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # The committed pending action must surface through show as a 4-field
    # binding + Arbiter-rendered text. Resolve consumes the binding.
    show_state
    [ "$status" -eq 0 ]
    node - "$TMP_DIR/show.json" "$TMP_DIR/input.json" <<'NODE'
const fs = require('fs');
const [showFile, inputFile] = process.argv.slice(2);
const show = JSON.parse(fs.readFileSync(showFile, 'utf8'));
if (!show.interaction || !show.interaction.binding) {
  console.error('expected a committed pending action binding from show');
  process.exit(1);
}
const b = show.interaction.binding;
fs.writeFileSync(inputFile, `${JSON.stringify({
  workflow_id: b.workflow_id,
  state_version: b.state_version,
  pending_action_id: b.pending_action_id,
  visible_choice_hash: b.visible_choice_hash,
  choice: '1',
})}\n`);
NODE
    [ "$status" -eq 0 ]

    BINDING_VER=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/show.json','utf8')).interaction.binding.state_version)")
    resolve_choice "$BINDING_VER" "$TMP_DIR/input.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # --- Section 2: rewrite the Brief cleanly and complete the loop -------
    printf '%s' "$NEUTRAL_BRIEF_2" > "$PROJECT/写作Brief_第002节.md"
    cat > "$TMP_DIR/ctx.json" <<JSON
{"brief_rel":"写作Brief_第002节.md","section_index":2}
JSON
    run_stage section_brief "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    printf '%s' "$NEUTRAL_DRAFT_2" > "$PROJECT/草稿_第002节_候选.md"
    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第002节_候选.md","section_index":2}
JSON
    run_stage section_draft "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第002节_候选.md","section_index":2}
JSON
    run_stage machine_gate "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    node - "$REPO" "$PROJECT" "$TASK_DIR" "$WFID" 2 <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root, taskDir, workflowId, sectionIndex] = process.argv.slice(2);
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store'));
const { buildShortSectionOutlineContract } = require(path.join(repo, 'scripts/lib/short-section-outline-contract'));
const { resolveShortReaderMilestone } = require(path.join(repo, 'scripts/lib/short-reader-milestone-policy'));
const { QUALITY_CHECKS } = require(path.join(repo, 'scripts/lib/short-section-quality-evidence'));
const draftFile = path.join(root, '草稿_第002节_候选.md');
const draftText = fs.readFileSync(draftFile, 'utf8');
const draftDigest = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(draftFile)).digest('hex')}`;
const outlineContract = buildShortSectionOutlineContract(root, Number(sectionIndex));
if (outlineContract.status !== 'current') throw new Error(JSON.stringify(outlineContract));
const readerMilestone = resolveShortReaderMilestone({
  sectionIndex: Number(sectionIndex), outlineContract, task: { workflow_id: workflowId },
});
const quotes = draftText
  .replace(/^#{1,6}[^\n]*$/gmu, '')
  .split(/[。！？\n]+/u)
  .map((item) => item.trim())
  .filter((item) => item.length >= 6);
if (quotes.length < 4) throw new Error('test_evidence_quotes_underfilled');
const required = (outlineContract.obligations || []).filter((item) => item.required_in_draft);
const outlineCoverage = required.map((item, index) => ({
  id: item.id, status: 'pass',
  evidence_quote: quotes[Math.floor(index / 2) % quotes.length],
}));
const evidence = {
  schemaVersion: '1.0.0',
  workflow_id: workflowId,
  section_index: Number(sectionIndex),
  draft_digest: draftDigest,
  outline_contract_digest: String(outlineContract.contract_digest || ''),
  checks: QUALITY_CHECKS.map((id, index) => ({
    id, status: 'pass', evidence: '正文已有可核验的具体推进',
    evidence_quote: quotes[index % quotes.length],
  })),
  outline_coverage: outlineCoverage,
  summary: '当前小节的人物行动、因果变化与阅读牵引均有正文证据。',
  acceptance_metadata: {
    revealed_information: ['当前小节新增信息已经在正文中明确呈现'],
    character_state: { 阿岚: '完成当前选择并承担相应后果' },
    relationship_state: { '阿岚与老沈': '关系因公开选择发生变化' },
    decisions: ['保留可复核记录并承担选择后果'],
    present_characters: ['阿岚', '老沈'],
    open_hook: outlineContract.section_role === 'ending' ? '' : '新编号仍需长期公开复核',
  },
};
if (readerMilestone.required) {
  evidence.reader_milestone = {
    reviewer: 'professional-reader', kind: readerMilestone.kind, status: 'pass',
    would_continue: 'yes',
    strongest_pull: '结尾收束责任与档案承诺',
    biggest_resistance: '篇幅较短',
    evidence_quote: quotes[0], repair_direction: '',
  };
}
atomicWriteJson(path.join(root, taskDir, `artifacts/section-002-story-review-pass.json`), evidence);
NODE

    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第002节_候选.md","section_index":2,"evidence_rel":"$TASK_DIR/artifacts/section-002-story-review-pass.json"}
JSON
    run_stage story_gate "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    cat > "$TMP_DIR/ctx.json" <<JSON
{"draft_rel":"草稿_第002节_候选.md","section_index":2,"evidence_rel":"$TASK_DIR/artifacts/section-002-story-review-pass.json"}
JSON
    run_stage section_accept "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # --- Closure stages ----------------------------------------------------
    # assembly owns 正文.md; the test must not pre-create or overwrite
    # accepted canonical prose. Editorial review then proves both required
    # external cards through three real calls on the same durable stage.
    cat > "$TMP_DIR/ctx.json" <<JSON
{}
JSON
    run_stage assembly "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
    [ -f "$PROJECT/正文.md" ]

    READER_REL="$TASK_DIR/artifacts/e2e-reader-response.json"
    REVIEW_REL="$TASK_DIR/artifacts/e2e-editorial-review.json"
    cat > "$TMP_DIR/ctx.json" <<JSON
{"reader_response_path":"$READER_REL","review_card_path":"$REVIEW_REL"}
JSON
    run_stage editorial_review "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
    assert_contains 'short_story_reader_response_required'

    node - "$PROJECT" "$READER_REL" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, readerRel] = process.argv.slice(2);
const body = (index) => fs.readFileSync(path.join(root, '正文', `第${String(index).padStart(3, '0')}节.md`), 'utf8')
  .replace(/^##[^\n]*\n+/u, '').trim();
const first = body(1);
const second = body(2);
const reader = {
  reader_profile: { target_platform: '未确认', platform_mode: 'general_fiction', genre_lens: ['责任选择'], style_lens: ['restrained_realism'], reading_scene: 'mobile_continuous', profile_basis: '用户未指定，使用通用画像' },
  section_reader_response: [
    { section_index: 1, engagement: 'engaged', felt_emotion: '关注核验结果', reader_question: '她会不会公开', evidence_quote: first },
    { section_index: 2, engagement: 'engaged', felt_emotion: '责任得到落实', reader_question: '复核能否持续', evidence_quote: second },
  ],
  drop_off_points: [],
  character_impressions: [{ character: '阿岚', first_impression: '谨慎', later_impression: '愿意承担', trust_change: 'up', evidence_quotes: [first, second] }],
  identity_continuity: [], identity_continuity_not_applicable_reason: '设定没有额外职业或能力承诺。',
  supporting_character_reality: [{ character: '老沈', felt_status: 'alive', apparent_want: '保住交付', decisive_choice: '接受停权', relationship_effect: '失去控制权', evidence_quotes: [first, second] }],
  reveal_aftershock: [], reveal_aftershock_not_applicable_reason: '两节故事没有独立的中段揭示。',
  promise_response: { title_expectation: '看到差异如何被复核', payoff_status: 'fulfilled', evidence_quotes: [second], reader_aftertaste: '责任清楚' },
  final_reader_state: { would_continue_or_recommend: 'yes', strongest_pull: '具体选择', biggest_resistance: '篇幅较短' },
};
fs.mkdirSync(path.dirname(path.join(root, readerRel)), { recursive: true });
fs.writeFileSync(path.join(root, readerRel), `${JSON.stringify(reader, null, 2)}\n`);
NODE

    run_stage editorial_review "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
    assert_contains 'short_story_editorial_review_required'

    node - "$PROJECT" "$WFID" "$REVIEW_REL" <<'NODE'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [root, workflowId, reviewRel] = process.argv.slice(2);
const body = (index) => fs.readFileSync(path.join(root, '正文', `第${String(index).padStart(3, '0')}节.md`), 'utf8')
  .replace(/^##[^\n]*\n+/u, '').trim();
const first = body(1);
const second = body(2);
const storyHash = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, '正文.md'))).digest('hex');
const card = {
  schemaVersion: '1.0.0', workflow_id: workflowId, story_sha256: storyHash, decision: 'pass',
  summary: '故事可进入表达精修。',
  opening_assessment: { verdict: 'pass', evidence_quote: first, reason: '直接进入核验冲突。' },
  section_function_matrix: [
    { section_index: 1, structural_role: '建立差异与选择', function_verdict: 'pass', evidence_quote: first, note: '功能完成' },
    { section_index: 2, structural_role: '落实责任与复核', function_verdict: 'pass', evidence_quote: second, note: '功能可核验' },
  ],
  character_arc_matrix: [
    { character: '阿岚', desire: '公开复核', independent_stake: '承担延期', active_action: '提交更正方案', cost: '排期延后', relationship_effect: '与主管形成责任边界', change: '从核对转向公开承担', verdict: 'pass', evidence_quotes: [first, second] },
    { character: '老沈', desire: '保住交付', independent_stake: '保住审批权', active_action: '要求撤回', cost: '接受停权', relationship_effect: '失去原有控制', change: '从压制到接受复核', verdict: 'pass', evidence_quotes: [first, second] },
  ],
  identity_payoff_matrix: [], identity_not_applicable_reason: '本故事没有独立职业能力承诺。',
  reveal_aftershock_matrix: [], reveal_aftershock_not_applicable_reason: '两节故事没有独立中段揭示。',
  climax_ending_assessment: { verdict: 'pass', climax_quote: second, ending_quote: second, reason: '更正与责任在结尾落地。' },
  findings: [],
};
fs.writeFileSync(path.join(root, reviewRel), `${JSON.stringify(card, null, 2)}\n`);
NODE

    run_stage editorial_review "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
    assert_contains 'short_story_editorial_passed'

    cp "$PROJECT/正文.md" "$PROJECT/$TASK_DIR/artifacts/deslop-candidate.md"

    cat > "$TMP_DIR/ctx.json" <<JSON
{"staged_path":"$TASK_DIR/artifacts/deslop-candidate.md"}
JSON
    run_stage deslop "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    cat > "$TMP_DIR/ctx.json" <<JSON
{}
JSON
    run_stage final_check "$TMP_DIR/ctx.json"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }

    # --- Final invariants --------------------------------------------------
    # task.status and lifecycle.status BOTH completed, current_stage stays on
    # final_check, exactly two accepted anchors, NO section 3, 正文.md sha256
    # equals the final-check receipt's canonical_sha256.
    TASK_FILE="$PROJECT/追踪/workflow/tasks/$WFID/task.json"
    [ -f "$TASK_FILE" ]
    node - "$TASK_FILE" "$PROJECT" "$TASK_DIR" "$WFID" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [taskFile, root, taskDir, workflowId] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
assert.equal(task.status, 'completed', `task.status must be completed, got ${task.status}`);
assert.equal(task.lifecycle && task.lifecycle.status, 'completed',
  `lifecycle.status must be completed, got ${task.lifecycle && task.lifecycle.status}`);
assert.equal(task.current_stage, 'final_check', 'current_stage must stay on final_check');

const stateDir = path.join(root, '追踪/story-system/short');
const anchors = fs.existsSync(stateDir)
  ? fs.readdirSync(stateDir).filter((name) => /^section-\d{3}-anchor\.json$/.test(name))
  : [];
assert.deepEqual(anchors, ['section-001-anchor.json', 'section-002-anchor.json'],
  `exactly two accepted anchors: ${JSON.stringify(anchors)}`);

assert.ok(!fs.existsSync(path.join(root, '正文', '第003节.md')),
  'no section 3 canonical file may exist');
assert.ok(!fs.existsSync(path.join(stateDir, 'section-003-anchor.json')),
  'no section 3 anchor may exist');

// 正文.md summary equals final-check receipt canonical_sha256.
const storyFile = path.join(root, '正文.md');
const storyHash = crypto.createHash('sha256').update(fs.readFileSync(storyFile)).digest('hex');
const latest = JSON.parse(fs.readFileSync(path.join(root, taskDir,
  'artifacts/closure/final-check/latest.json'), 'utf8'));
const finalReceipt = JSON.parse(fs.readFileSync(path.join(root, latest.receipt_path), 'utf8'));
assert.equal(storyHash, finalReceipt.canonical_sha256,
  `正文.md sha256 must equal final-check receipt canonical_sha256: ${storyHash} vs ${finalReceipt.canonical_sha256}`);
NODE
}

# --- boundary 1: context-file authority fields -----------------------------

@test "V3 run-stage rejects a context-file carrying any authority-owned field and the durable task.json is byte-for-byte unchanged" {
    create_short "档案复核短篇"
    [ "$status" -eq 0 ]
    WFID=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")
    TASK_DIR=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.task_dir)")

    # creative_entry advances via apply-result so the durable task sits on
    # material_positioning when run-stage is invoked.
    printf '{"kind":"completed","code":"creative_entry_confirmed","stage_id":"creative_entry"}\n' > "$TMP_DIR/result.json"
    apply_result 1
    [ "$status" -eq 0 ]

    TASK_FILE="$PROJECT/追踪/workflow/tasks/$WFID/task.json"
    BEFORE=$(cat "$TASK_FILE")

    # Authority-owned fields deliberately mixed into the context-file. The CLI
    # must reject with a context-file authority error — not with "unknown
    # command: run-stage" and not with a generic usage error. The five
    # authority fields (task, current_stage, workflow_id, projectRoot,
    # expectedVersion) are each named individually.
    cat > "$TMP_DIR/ctx.json" <<JSON
{"task":{"workflow_id":"$WFID","current_stage":"setting"},"workflow_id":"$WFID","current_stage":"setting","projectRoot":"$PROJECT","expectedVersion":1,"staged_rel":"$TASK_DIR/artifacts/planning/material_positioning/sa-material/素材卡.md"}
JSON
    run_stage material_positioning "$TMP_DIR/ctx.json"
    [ "$status" -ne 0 ]
    # The error must specifically call out the context-file authority violation,
    # not the missing CLI entry point. The CLI prints a JSON {ok:false, error}
    # payload; we require the error string to mention an authority field name.
    REJECT=$(node -e "const o=JSON.parse(require('fs').readFileSync('$TMP_DIR/runstage.json','utf8'));process.stdout.write(String(o.error||''))")
    case "$REJECT" in
        *workflow_id*|*current_stage*|*projectRoot*|*expectedVersion*|*task*|*authority*|*context-file*|*context_file*)
            ;;
        *) echo "expected context-file authority rejection, got: $REJECT" >&3; false ;;
    esac
    refute_contains "unknown command: run-stage"

    AFTER=$(cat "$TASK_FILE")
    [ "$BEFORE" = "$AFTER" ]
}

@test "V3 run-stage rejects a stale expected-version before a professional service writes artifacts" {
    create_short "档案复核短篇"
    [ "$status" -eq 0 ]
    WFID=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")
    TASK_DIR=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.task_dir)")

    printf '{"kind":"completed","code":"creative_entry_confirmed","stage_id":"creative_entry"}\n' > "$TMP_DIR/result.json"
    apply_result 1
    [ "$status" -eq 0 ]

    STAGED_REL="$TASK_DIR/artifacts/planning/material_positioning/stale/素材卡.md"
    mkdir -p "$(dirname "$PROJECT/$STAGED_REL")"
    printf '%s' "$NEUTRAL_MATERIAL" > "$PROJECT/$STAGED_REL"
    printf '{"staged_rel":"%s"}\n' "$STAGED_REL" > "$TMP_DIR/ctx.json"
    TASK_FILE="$PROJECT/$TASK_DIR/task.json"
    BEFORE=$(cat "$TASK_FILE")

    run node "$CLI" run-stage \
        --project-root "$PROJECT" \
        --workflow-id "$WFID" \
        --expected-version 1 \
        --stage material_positioning \
        --context-file "$TMP_DIR/ctx.json" \
        --json
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/runstage.json"
    [ "$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/runstage.json','utf8')).code || '')")" = "WORKFLOW_TASK_CONFLICT" ]
    [ "$BEFORE" = "$(cat "$TASK_FILE")" ]
    [ ! -e "$PROJECT/素材卡.md" ]
}

@test "V3 run-stage rejects acceptance-evidence overrides from its public context" {
    create_short "档案复核短篇"
    [ "$status" -eq 0 ]
    WFID=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")
    TASK_DIR=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.task_dir)")
    printf '{"kind":"completed","code":"creative_entry_confirmed","stage_id":"creative_entry"}\n' > "$TMP_DIR/result.json"
    apply_result 1
    [ "$status" -eq 0 ]
    TASK_FILE="$PROJECT/$TASK_DIR/task.json"
    BEFORE=$(cat "$TASK_FILE")

    for field in metadata memoryBasis memory_basis; do
        printf '{"%s":{"forged":true}}\n' "$field" > "$TMP_DIR/ctx.json"
        run_stage material_positioning "$TMP_DIR/ctx.json"
        [ "$status" -ne 0 ]
        assert_contains "$field"
        [ "$BEFORE" = "$(cat "$TASK_FILE")" ]
    done
}

@test "V3 run-stage and direct Engine mutations share one execution lock" {
    create_short "档案复核短篇"
    [ "$status" -eq 0 ]
    WFID=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")
    TASK_DIR=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.task_dir)")
    printf '{"kind":"completed","code":"creative_entry_confirmed","stage_id":"creative_entry"}\n' > "$TMP_DIR/result.json"
    apply_result 1
    [ "$status" -eq 0 ]

    STAGED_REL="$TASK_DIR/artifacts/planning/material_positioning/locked/素材卡.md"
    mkdir -p "$(dirname "$PROJECT/$STAGED_REL")"
    printf '%s' "$NEUTRAL_MATERIAL" > "$PROJECT/$STAGED_REL"
    printf '{"staged_rel":"%s"}\n' "$STAGED_REL" > "$TMP_DIR/ctx.json"
    printf '{"kind":"completed","code":"must_not_apply","stage_id":"material_positioning"}\n' > "$TMP_DIR/result.json"
    TASK_FILE="$PROJECT/$TASK_DIR/task.json"
    BEFORE=$(cat "$TASK_FILE")

    run node - "$REPO" "$PROJECT" "$CLI" "$WFID" "$TMP_DIR/ctx.json" "$TMP_DIR/result.json" <<'NODE'
const assert = require('assert');
const { spawnSync } = require('child_process');
const path = require('path');
const [repo, root, cli, workflowId, contextFile, resultFile] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine'));
const { withWorkflowExecutionLock } = require(path.join(repo, 'scripts/lib/workflow-v3/execution-lock'));
const fs = require('fs');
const emptyInput = path.join(path.dirname(contextFile), 'empty-input.json');
fs.writeFileSync(emptyInput, '{}\n');
const leakedCapability = withWorkflowExecutionLock(root, 'capability-capture-probe', (capability) => capability);
withWorkflowExecutionLock(root, 'test-holder', () => {
  for (const args of [
    ['run-stage', '--project-root', root, '--workflow-id', workflowId, '--expected-version', '2', '--stage', 'material_positioning', '--context-file', contextFile, '--json'],
    ['resolve', '--project-root', root, '--workflow-id', workflowId, '--expected-version', '2', '--input-file', emptyInput, '--json'],
  ]) {
    const child = spawnSync(process.execPath, [cli, ...args], { cwd: root, encoding: 'utf8' });
    assert.notEqual(child.status, 0, `mutation unexpectedly succeeded: ${child.stdout}`);
    const payload = JSON.parse(child.stdout);
    assert.equal(payload.code, 'WORKFLOW_EXECUTION_LOCKED', child.stdout);
  }
  const direct = spawnSync(process.execPath, [cli,
    'apply-result', '--project-root', root, '--workflow-id', workflowId,
    '--expected-version', '2', '--result-file', resultFile, '--json',
  ], { cwd: root, encoding: 'utf8' });
  assert.notEqual(direct.status, 0, 'professional apply-result must be rejected before mutation');
  assert.match(JSON.parse(direct.stdout).error, /professional_stage_requires_run_stage/);
  let forged;
  try {
    engine.applyStageResult(root, workflowId, 2, {
      kind: 'completed', code: 'must_not_apply', stage_id: 'material_positioning',
    }, { executionLockHeld: true });
  } catch (error) {
    forged = error;
  }
  assert.equal(forged && forged.code, 'WORKFLOW_EXECUTION_LOCKED');
  let leaked;
  try {
    engine.applyStageResult(root, workflowId, 2, {
      kind: 'completed', code: 'must_not_apply', stage_id: 'material_positioning',
    }, leakedCapability);
  } catch (error) {
    leaked = error;
  }
  assert.equal(leaked && leaked.code, 'WORKFLOW_EXECUTION_LOCKED');
});
NODE
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
    [ "$BEFORE" = "$(cat "$TASK_FILE")" ]
    [ ! -e "$PROJECT/素材卡.md" ]
}

# --- boundary 2: run-stage refuses creative_entry / planning_confirmation / section_repair

@test "V3 run-stage refuses creative_entry / planning_confirmation / section_repair and leaves the durable task.json byte-for-byte unchanged" {
    create_short "档案复核短篇"
    [ "$status" -eq 0 ]
    WFID=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")
    TASK_DIR=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.task_dir)")

    # The fresh task sits on creative_entry; the durable bytes are snapshotted
    # so every refused run-stage attempt below can be checked for byte-identity.
    # run-stage must refuse EACH of creative_entry / planning_confirmation /
    # section_repair regardless of the engine's actual current_stage — those
    # stages have specific engine or apply-result paths and must never be
    # invokable through the staged-artifact entry point.
    TASK_FILE="$PROJECT/追踪/workflow/tasks/$WFID/task.json"
    BEFORE=$(cat "$TASK_FILE")

    for stage in creative_entry planning_confirmation section_repair; do
        cat > "$TMP_DIR/ctx.json" <<JSON
{"staged_rel":"$TASK_DIR/artifacts/${stage}/${stage}.md"}
JSON
        run_stage "$stage" "$TMP_DIR/ctx.json"
        [ "$status" -ne 0 ]
        # The rejection must specifically name the refused stage (not just a
        # generic "unknown command: run-stage" complaint).
        REJECT=$(node -e "const o=JSON.parse(require('fs').readFileSync('$TMP_DIR/runstage.json','utf8'));process.stdout.write(String(o.error||''))")
        case "$REJECT" in
            *"$stage"*)
                ;;
            *) echo "expected $stage rejection, got: $REJECT" >&3; false ;;
        esac
        refute_contains "unknown command: run-stage"
        refute_contains "completed"
        # Each refused attempt must leave the durable task.json byte-identical.
        AFTER=$(cat "$TASK_FILE")
        [ "$BEFORE" = "$AFTER" ]
    done
}
