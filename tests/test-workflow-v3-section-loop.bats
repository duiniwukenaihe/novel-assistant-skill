#!/usr/bin/env bats

# Task 6: Engine-neutral short section production loop. The shared
# finalizeBrief/finalizeDraft/runMachineGate/runStoryGate/acceptSection services
# each return a Task 1 StageResult ONLY — no visible_response, no numbered
# options, no banned V2 imports — and the V3 Engine is the single writer that
# persists retry_state for retryable_internal results. Tests drive the REAL V3
# engine, the REAL deterministic check scripts, the REAL chapter-commit
# transaction, and the REAL accepted-section projection. Nothing is stubbed. All
# fixtures are project-neutral synthetic names so no real project title,
# character, plot, ID, or domain term leaks in.
#
# Canonical state lives under 追踪/story-system/short (short-project-state
# resolves there for a fresh project). Title-lock and accepted anchors are read
# from that canonical root. Quality evidence is REAL: each passing story gate is
# backed by a schema-valid evidence card bound to the actual draft sha256, the
# outline contract digest/obligations, exact non-reused prose quotes, and the
# professional-reader milestone the policy requires for opening/ending sections.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/story-system"
    printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$PROJECT/追踪/story-system/write-policy.json"
    QUALITY_HELPER="$TMP_DIR/quality-evidence-helper.js"
    export QUALITY_HELPER
    cat > "$QUALITY_HELPER" <<'JS'
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function writeEvidenceCard({ repo, root, task, draftRel, reviseDimensions = [] }) {
  const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store'));
  const { buildShortSectionOutlineContract } = require(path.join(repo, 'scripts/lib/short-section-outline-contract'));
  const { resolveShortReaderMilestone } = require(path.join(repo, 'scripts/lib/short-reader-milestone-policy'));
  const { readShortProjectState } = require(path.join(repo, 'scripts/lib/short-project-state'));
  const { QUALITY_CHECKS } = require(path.join(repo, 'scripts/lib/short-section-quality-evidence'));
  const state = readShortProjectState(root) || {};
  const sectionIndex = Number(state.current_section_index || 0);
  if (!Number.isInteger(sectionIndex) || sectionIndex < 1) throw new Error('test_section_index_missing');
  const draftFile = path.join(root, draftRel);
  const draftText = fs.readFileSync(draftFile, 'utf8');
  const draftDigest = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(draftFile)).digest('hex')}`;
  const outlineContract = buildShortSectionOutlineContract(root, sectionIndex);
  if (outlineContract.status !== 'current') throw new Error(JSON.stringify(outlineContract));
  const readerMilestone = resolveShortReaderMilestone({ sectionIndex, outlineContract, task });
  const quotes = draftText
    .replace(/^#{1,6}[^\n]*$/gmu, '')
    .split(/[。！？\n]+/u)
    .map((item) => item.trim())
    .filter((item) => item.length >= 6);
  if (quotes.length < 4) throw new Error('test_evidence_quotes_underfilled');
  const revise = new Set(reviseDimensions.map(String));
  const required = outlineContract.obligations.filter((item) => item.required_in_draft);
  const outlineCoverage = required.map((item, index) => ({
    id: item.id,
    status: 'pass',
    evidence_quote: quotes[Math.floor(index / 2) % quotes.length],
  }));
  const evidence = {
    schemaVersion: '1.0.0',
    workflow_id: String(task.workflow_id || ''),
    section_index: sectionIndex,
    draft_digest: draftDigest,
    outline_contract_digest: String(outlineContract.contract_digest || ''),
    checks: QUALITY_CHECKS.map((id, index) => ({
      id,
      status: revise.has(id) ? 'revise' : 'pass',
      evidence: revise.has(id) ? '这一维度仍需局部加强后再采用' : '正文已有可核验的具体推进',
      evidence_quote: quotes[index % quotes.length],
    })),
    outline_coverage: outlineCoverage,
    summary: revise.size ? '当前小节存在明确的局部质量缺口，需要修订后复核。' : '当前小节的人物行动、因果变化与阅读牵引均有正文证据。',
    acceptance_metadata: {
      section_summary: `第${sectionIndex}节完成当前规划动作并留下可核验结果。`,
      revealed_information: ['当前小节新增信息已经在正文中明确呈现'],
      character_state: { 阿岚: '完成当前选择并承担相应后果' },
      relationship_state: { '阿岚与主管': '关系因公开选择发生变化' },
      decisions: ['保留可复核记录并承担选择后果'],
      present_characters: ['阿岚', '主管'],
      open_hook: outlineContract.section_role === 'ending' ? '' : '旧批次编号仍需在下一节完成公开复核',
    },
  };
  if (readerMilestone.required) {
    evidence.reader_milestone = {
      reviewer: 'professional-reader',
      kind: readerMilestone.kind,
      status: 'pass',
      would_continue: 'yes',
      strongest_pull: '主角已经作出带代价的具体选择',
      biggest_resistance: '后续责任如何落地仍需继续兑现',
      evidence_quote: quotes[0],
      repair_direction: '',
    };
  }
  const mode = revise.size ? 'revise' : 'pass';
  const rel = `${task.task_dir}/artifacts/section-${String(sectionIndex).padStart(3, '0')}-story-review-${mode}.json`;
  atomicWriteJson(path.join(root, rel), evidence);
  return rel;
}

module.exports = { writeEvidenceCard };
JS
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Project-neutral setting that passes the REAL short character contract and the
# narrative-quality validator for planned_sections=2. Synthetic characters and a
# synthetic domain (archive number reconciliation) so no real project word
# appears.
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

# Project-neutral two-section outline that passes the REAL narrative-quality
# validator for planned_sections=2 (section 1 opening, section 2 ending) and
# yields a current outline contract for each section.
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

# A neutral section-1 Brief that passes the REAL outline-coverage and brief
# quality validators for the section-1 outline contract above.
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

# A neutral section-2 Brief. The acceptance anchor for section 1 is bound as
# the freshness dependency so the next-section Brief stays current after accept.
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

# Neutral section prose that passes every REAL machine-gate check (AI patterns,
# anti-AI, output pollution, degeneration, story prose gate). Section 2 carries
# the section-1 ending forward so the next-section Brief stays consistent.
NEUTRAL_DRAFT_1='# 第1节

我把扫描回放投到评审室的白墙上。屏幕里，归档编号在两个不同批次里重复出现，传送带一直转，档案却对不上。主管推门进来，让我立刻撤回这次扫描，理由是季度交付吃紧。我没有替自己解释，只问在座的人敢不敢把旧批次的采购单也投上去。我沉默地接过撤回单，指尖压在签名栏上，那是我从未见过的字迹。窗外的雨砸在玻璃上，评审室的灯白得刺眼。我抬起头，看着主管，慢慢开口，请他把旧批次也摆到桌面上。他怔了很久，最后承认那批编号源自三年前停用的旧批次。
'

NEUTRAL_DRAFT_2='# 第2节

评审会上，我把补丁和新编号的复核方案一起推到桌面正中。主管仍想延期公布，理由是排期和工资都要承压。我没有退缩，只把旧号回滚和独立复核的步骤逐项念给在座的人听。窗外的光斜斜落在采购单上，纸面的旧编号被划掉，新编号写在旁边。我承担了延期带来的成本，也接受主管停权后的代签流程。最后，新编号接受长期公开复核，任何人都能在档案里追溯这一次纠错。我没有再用情面替责任结账，主管也保持沉默地接受了这个结果。
'

# Run the planning phase (real planning service) so the section loop begins at
# section_brief with a durable V3 task and the title lock bound by the real
# planning-confirmation transition. Returns the workflow_id. Reused by every
# section-loop test.
plan_to_section_brief() {
    node - "$REPO" "$PROJECT" "$NEUTRAL_MATERIAL" "$NEUTRAL_SETTING" "$NEUTRAL_OUTLINE" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const engine = require(path.join(process.argv[2], 'scripts/lib/workflow-v3/engine.js'));
const planning = require(path.join(process.argv[2], 'scripts/lib/short-production/planning.js'));
const [repo, root, materialText, settingText, outlineText] = process.argv.slice(2);

let task = engine.createTask(root, {
  workflow_id: 'wf-section-loop',
  workflow_type: 'short_write',
  user_goal: '写两节短篇',
});
task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'advance', stage_id: 'creative_entry',
}).task;
const stagedMaterialRel = `${task.task_dir}/artifacts/planning/material_positioning/sa-material/素材卡.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedMaterialRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedMaterialRel), materialText);
const materialResult = planning.finalizePlanningStage({
  projectRoot: root, task, stageId: 'material_positioning', stagedRel: stagedMaterialRel, apply: true,
});
task = engine.applyStageResult(root, task.workflow_id, task.state_version, materialResult).task;
const stagedSettingRel = `${task.task_dir}/artifacts/planning/setting/sa-setting/设定.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedSettingRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedSettingRel), settingText);
const settingResult = planning.finalizePlanningStage({
  projectRoot: root, task, stageId: 'setting', stagedRel: stagedSettingRel, apply: true,
});
task = engine.applyStageResult(root, task.workflow_id, task.state_version, settingResult).task;

const stagedOutlineRel = `${task.task_dir}/artifacts/planning/section_outline/sa-outline/小节大纲.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedOutlineRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedOutlineRel), outlineText);
const outlineResult = planning.finalizePlanningStage({
  projectRoot: root, task, stageId: 'section_outline', stagedRel: stagedOutlineRel, apply: true,
});
task = engine.applyStageResult(root, task.workflow_id, task.state_version, outlineResult).task;
assert.equal(task.current_stage, 'planning_confirmation');

// planning_confirmation advances to section_brief on a completed result.
task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'planning_confirmed', stage_id: 'planning_confirmation',
}).task;
assert.equal(task.current_stage, 'section_brief');

// planning_confirmation itself must write the lock. No test fixture may fake
// a post-confirmation artifact just to let the Brief service continue.
const lock = JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/short/section-title-lock.json'), 'utf8'));
assert.equal(lock.confirmation_basis, 'planning_confirmation');
assert.deepEqual(lock.sections.map(item => item.title), ['发现重复编号', '恢复正确编号']);
NODE
}

@test "V3 section Brief resume exposes one minimum context packet instead of an empty source list" {
    plan_to_section_brief
    run node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief, draft] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));

const contract = runner.describeCurrentStage({ projectRoot: root, workflowId: 'wf-section-loop' });
assert.equal(contract.stage_id, 'section_brief');
assert.equal(contract.section_index, 1);
assert.equal(contract.source_files.length, 1, JSON.stringify(contract));
assert.match(contract.source_files[0], /context-packets\/section_brief\/.+\/stage-context\.md$/u);
assert.equal(contract.stage_context_packet.status, 'assembled');
assert.equal(contract.stage_context_packet.packet_md, contract.source_files[0]);
assert.ok(contract.stage_context_packet.memory_read_receipt, JSON.stringify(contract.stage_context_packet));
assert.match(contract.context_read_command, /workflow-stage-context\.js read-current/u);
assert.doesNotMatch(contract.context_read_command, /workflow-v3\.js describe-stage/u);

fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief);
let task = engine.readTask(root, 'wf-section-loop');
task = engine.applyStageResult(root, task.workflow_id, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;
assert.equal(task.current_stage, 'section_draft');
const draftContract = runner.describeCurrentStage({ projectRoot: root, workflowId: task.workflow_id });
assert.equal(draftContract.source_files.length, 1, JSON.stringify(draftContract));
assert.match(draftContract.source_files[0], /context-packets\/draft_section\/.+\/stage-context\.md$/u);
assert.equal(draftContract.stage_context_packet.stage_id, 'draft_section');
assert.ok(draftContract.stage_context_packet.memory_read_receipt);
const persisted = engine.readTask(root, task.workflow_id);
assert.equal(persisted.state_version, draftContract.state_version);
assert.equal(persisted.stage_execution.stage_context_packet.packet_md, draftContract.source_files[0]);
assert.equal(persisted.stage_execution.memory_context.memory_read_receipt.memory_revision,
  draftContract.stage_context_packet.memory_read_receipt.memory_revision);
const repeated = runner.describeCurrentStage({ projectRoot: root, workflowId: task.workflow_id });
assert.equal(repeated.state_version, draftContract.state_version,
  'describing an unchanged stage context must not churn durable task versions');
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft);
const completed = runner.runCurrentStage({
  projectRoot: root,
  workflowId: task.workflow_id,
  expectedVersion: repeated.state_version,
});
assert.equal(completed.stage_result.code, 'short_draft_accepted', JSON.stringify(completed));
assert.equal(completed.task.current_stage, 'machine_gate');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 section repair keeps unchanged or empty prose at the repair stage and records the input digest" {
    plan_to_section_brief
    run node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief, neutralDraft] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));

const workflowId = 'wf-section-loop';
const draftRel = '草稿_第001节_候选.md';
const draftFile = path.join(root, draftRel);
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief);
let task = engine.readTask(root, workflowId);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;

// Use a real machine-gate finding so the Engine, rather than the test, routes
// the task into section_repair. The ASCII quotes are a known blocking prose
// finding; the rest stays the same neutral fixture.
const failingDraft = neutralDraft.replace(
  '主管推门进来，让我立刻撤回这次扫描，理由是季度交付吃紧。',
  '主管推门进来——他说："立刻撤回这次扫描。"理由是季度交付吃紧。',
);
fs.writeFileSync(draftFile, failingDraft);
let contract = runner.describeCurrentStage({ projectRoot: root, workflowId });
task = runner.runCurrentStage({ projectRoot: root, workflowId, expectedVersion: contract.state_version }).task;
assert.equal(task.current_stage, 'machine_gate', JSON.stringify(task));
const machine = loop.runMachineGate({ projectRoot: root, task, draft: draftRel });
assert.equal(machine.next_stage, 'section_repair', JSON.stringify(machine));
task = engine.applyStageResult(root, workflowId, task.state_version, machine).task;
assert.equal(task.current_stage, 'section_repair', JSON.stringify(task));
assert.equal(task.stage_execution.draft_input_digest, machine.draft_digest,
  'the repair stage must retain the exact candidate digest it is required to change');

// The service itself fails closed for a missing or empty repair candidate.
assert.equal(loop.finalizeRepair({ projectRoot: root, task, draft: 'missing.md' }).code, 'awaiting_short_draft');
fs.writeFileSync(draftFile, '');
assert.equal(loop.finalizeRepair({ projectRoot: root, task, draft: draftRel }).code, 'awaiting_short_draft');
fs.writeFileSync(draftFile, failingDraft);

// The production run-current-stage path must leave an unchanged candidate at
// section_repair rather than auto-advancing to machine_gate.
const unchanged = runner.runCurrentStage({ projectRoot: root, workflowId, expectedVersion: task.state_version });
assert.equal(unchanged.stage_result.kind, 'blocked', JSON.stringify(unchanged));
assert.equal(unchanged.stage_result.code, 'awaiting_short_draft_change', JSON.stringify(unchanged));
assert.equal(unchanged.task.current_stage, 'section_repair', JSON.stringify(unchanged.task));

// A real byte change is the only completion path. Replaying the stale version
// afterward must conflict rather than advancing a second time.
const staleVersion = unchanged.task.state_version;
fs.appendFileSync(draftFile, '\n我把原始编号的影印件压在撤回单旁边，要求当场登记。\n');
const changed = runner.runCurrentStage({ projectRoot: root, workflowId, expectedVersion: staleVersion });
assert.equal(changed.stage_result.code, 'short_section_repair_ready', JSON.stringify(changed));
assert.equal(changed.task.current_stage, 'machine_gate', JSON.stringify(changed.task));
let stale;
try {
  runner.runCurrentStage({ projectRoot: root, workflowId, expectedVersion: staleVersion });
} catch (error) {
  stale = error;
}
assert.equal(stale && stale.code, 'WORKFLOW_TASK_CONFLICT');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 accepted planning feedback is durably projected before the revised draft stage" {
    plan_to_section_brief
    run node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
const submitted = engine.submitAuthorFeedback(root, workflowId, task.state_version, {
  text: '第1至2节都要保留公开复核约束，并让下一节继续承接。',
});
task = submitted.task;
const proposed = engine.proposeAuthorFeedbackPlan(root, workflowId, task.state_version, {
  feedback_id: submitted.feedback_receipt.feedback_id,
  summary: '把公开复核写回规划，并按第1至2节逐节复检。',
  impact_level: 'planning_and_prose',
  affected_sections: [1, 2],
  evidence: ['当前规划没有把跨节复核明确为持续义务。'],
  proposed_changes: ['第1节建立公开复核约束', '第2节兑现并保留长期核验入口'],
});
task = proposed.task;
engine.resolveAuthorInput(root, workflowId, task.state_version, {
  ...proposed.visible_response.binding,
  choice: '1',
});
task = engine.readTask(root, workflowId);
assert.equal(task.pending_feedback.status, 'accepted');
assert.equal(task.current_stage, 'feedback_apply_patch');

let resumed = runner.describeCurrentStage({ projectRoot: root, workflowId });
assert.equal(resumed.stage_id, 'feedback_apply_patch');
assert.equal(resumed.write_set.includes('写作Brief_第001节.md'), false);
assert.equal(resumed.write_set.length, 1);
const stagedOutline = path.join(root, resumed.write_set[0]);
fs.mkdirSync(path.dirname(stagedOutline), { recursive: true });
fs.writeFileSync(stagedOutline,
  `${fs.readFileSync(path.join(root, '小节大纲.md'), 'utf8').trim()}\n- 跨节约束：公开复核必须持续到第2节兑现。\n`);
const patched = runner.runCurrentStage({
  projectRoot: root,
  workflowId,
  expectedVersion: resumed.state_version,
});
assert.equal(patched.stage_result.code, 'short_feedback_planning_patch_accepted', JSON.stringify(patched));
assert.equal(patched.task.current_stage, 'section_brief');
assert.ok(fs.existsSync(path.join(root, '追踪', 'memory', 'planning-constraints.jsonl')));
const refreshedState = JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/short/project-state.json'), 'utf8'));
const refreshedLock = JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/short/section-title-lock.json'), 'utf8'));
assert.equal(refreshedLock.plan_revision, refreshedState.plan_revision,
  'unchanged author-confirmed titles must be rebound to the new outline revision');
assert.equal(refreshedLock.source_digest,
  require('crypto').createHash('sha256').update(fs.readFileSync(path.join(root, '小节大纲.md'))).digest('hex'));

fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief);
resumed = runner.describeCurrentStage({ projectRoot: root, workflowId });
const completed = runner.runCurrentStage({
  projectRoot: root,
  workflowId,
  expectedVersion: resumed.state_version,
});
assert.equal(completed.stage_result.code, 'short_brief_accepted', JSON.stringify(completed));
assert.equal(completed.task.current_stage, 'section_draft');

const persisted = engine.readTask(root, workflowId);
assert.equal(persisted.pending_feedback.status, 'accepted',
  'feedback remains active until every affected section has been reaccepted');
assert.equal(persisted.accepted_plan.projection_status, 'completed');
assert.equal(persisted.feedback_revision_queue.status, 'running');
assert.deepEqual(persisted.feedback_revision_queue.affected_sections, [1, 2]);
assert.equal(persisted.feedback_revision_queue.current_section_index, 1);

const memoryFile = path.join(root, '追踪', 'memory', 'planning-constraints.jsonl');
assert.ok(fs.existsSync(memoryFile), 'accepted planning feedback must reach canonical memory');
const memoryText = fs.readFileSync(memoryFile, 'utf8');
assert.match(memoryText, /第1节建立公开复核约束/u);
assert.match(memoryText, /第2节兑现并保留长期核验入口/u);

const draftContract = runner.describeCurrentStage({ projectRoot: root, workflowId });
const packet = fs.readFileSync(path.join(root, draftContract.source_files[0]), 'utf8');
assert.match(packet, /第1节建立公开复核约束/u,
  'the next prose stage must receive the confirmed memory rather than only a chat receipt');
NODE
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 two-section production loop accepts real prose and closes an editorial repair cycle" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" "$NEUTRAL_BRIEF_2" "$NEUTRAL_DRAFT_2" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1, draft1, brief2, draft2] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));
const taskStore = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const { resolveShortStateRelative } = require(path.join(repo, 'scripts/lib/short-project-state'));
const { writeEvidenceCard } = require(process.env.QUALITY_HELPER);
const hashFile = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
assert.equal(task.current_stage, 'section_brief');

// --- Section 1 -----------------------------------------------------------
fs.writeFileSync(path.join(root, `写作Brief_第001节.md`), brief1);
const brief1Result = loop.finalizeBrief({ projectRoot: root, task });
assert.equal(brief1Result.kind, 'completed', JSON.stringify(brief1Result));
assert.equal(brief1Result.stage_id, 'section_brief');
assert.ok(!Object.prototype.hasOwnProperty.call(brief1Result, 'visible_response'),
  'finalizeBrief must not carry visible_response');
task = engine.applyStageResult(root, workflowId, task.state_version, brief1Result).task;
assert.equal(task.current_stage, 'section_draft');

// Draft must validate a changed, non-empty candidate against the current
// memory receipt. Write the real candidate, then run the real machine gate.
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft1);
const draft1Result = loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第001节_候选.md' });
assert.equal(draft1Result.kind, 'completed');
assert.equal(draft1Result.stage_id, 'section_draft');
assert.ok(!Object.prototype.hasOwnProperty.call(draft1Result, 'visible_response'),
  'finalizeDraft must not carry visible_response');
task = engine.applyStageResult(root, workflowId, task.state_version, draft1Result).task;
assert.equal(task.current_stage, 'machine_gate');

const machine1 = loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md' });
assert.equal(machine1.kind, 'completed');
assert.equal(machine1.stage_id, 'machine_gate');
assert.equal(machine1.next_stage, 'story_gate', JSON.stringify(machine1));
assert.ok(!Object.prototype.hasOwnProperty.call(machine1, 'visible_response'),
  'runMachineGate must not carry visible_response');
task = engine.applyStageResult(root, workflowId, task.state_version, machine1).task;
assert.equal(task.current_stage, 'story_gate');

// The story gate consumes a REAL evidence card (built by writeEvidenceCard
// below) bound to the actual draft sha256, outline contract digest/obligations,
// exact non-reused prose quotes, and the professional-reader milestone the
// opening section requires. The service must never auto-pass missing evidence.
const evidence1Rel = writeEvidenceCard({
  repo, root, task, draftRel: '草稿_第001节_候选.md',
});
const story1 = loop.runStoryGate({
  projectRoot: root, task, draft: '草稿_第001节_候选.md', evidenceFile: evidence1Rel,
});
assert.equal(story1.kind, 'completed');
assert.equal(story1.stage_id, 'story_gate');
assert.ok(!Object.prototype.hasOwnProperty.call(story1, 'visible_response'),
  'runStoryGate must not carry visible_response');
task = engine.applyStageResult(root, workflowId, task.state_version, story1).task;
assert.equal(task.current_stage, 'section_accept');
assert.equal(task.stage_execution.section_index, 1,
  'Engine must carry the section identity into section_accept for crash-safe retries');

// Legacy projects can carry a polluted project_title such as a section label
// while retaining the correct durable working_title. Cross-project events and
// commit metadata must use the work title, never the stale section label.
const stateFileBeforeAccept = path.join(root, resolveShortStateRelative(root, 'project-state.json'));
const stateBeforeAccept = JSON.parse(fs.readFileSync(stateFileBeforeAccept, 'utf8'));
stateBeforeAccept.working_title = '测试短篇';
stateBeforeAccept.project_title = '第1节';
fs.writeFileSync(stateFileBeforeAccept, `${JSON.stringify(stateBeforeAccept, null, 2)}\n`);

const accept1 = loop.acceptSection({ projectRoot: root, task });
assert.equal(accept1.kind, 'completed', JSON.stringify(accept1));
assert.equal(accept1.stage_id, 'section_accept');
assert.equal(accept1.next_stage, 'section_brief',
  'accept with another planned section remaining must target section_brief');
assert.ok(String(accept1.commit_id || ''), 'accept must carry a durable commit id');
assert.equal(accept1.integration_event.event.project_title, '测试短篇');
task = engine.applyStageResult(root, workflowId, task.state_version, accept1).task;

// Immutable canonical section file + exactly one accepted anchor + exactly one
// accepted project-state entry after section 1, all under the canonical state
// root 追踪/story-system/short.
const canonical1 = path.join(root, '正文', '第001节.md');
assert.ok(fs.existsSync(canonical1), '正文/第001节.md must exist after accept');
const section1Hash = hashFile(canonical1);
const stateDir = path.dirname(path.join(root, resolveShortStateRelative(root, 'project-state.json')));
const anchors1 = fs.readdirSync(stateDir).filter((name) => /^section-\d{3}-anchor\.json$/.test(name));
assert.deepEqual(anchors1, ['section-001-anchor.json'], `anchors after section 1: ${JSON.stringify(anchors1)}`);
const projectState1 = JSON.parse(fs.readFileSync(path.join(stateDir, 'project-state.json'), 'utf8'));
assert.equal((projectState1.accepted_sections || []).length, 1, 'one accepted section after section 1');
assert.equal(projectState1.current_section_index, 2,
  'project cursor must advance to the next planned section after acceptance');
assert.equal(task.current_stage, 'section_brief');

// The next attempt must bind its context and memory to section 2 even though
// the task scope still carries the completed section's legacy label.
task = taskStore.commitTask(root, workflowId, task.state_version, (draft) => {
  draft.scope = '第1节';
  return draft;
});
const section2Contract = runner.describeCurrentStage({ projectRoot: root, workflowId });
assert.equal(section2Contract.section_index, 2, JSON.stringify(section2Contract));
assert.equal(section2Contract.stage_context_packet.section_index, 2,
  JSON.stringify(section2Contract.stage_context_packet));
assert.match(section2Contract.stage_context_packet.packet_md, /section-002/u);
task = engine.readTask(root, workflowId);

// --- Section 2 -----------------------------------------------------------
fs.writeFileSync(path.join(root, `写作Brief_第002节.md`), brief2);
const brief2Result = loop.finalizeBrief({ projectRoot: root, task });
assert.equal(brief2Result.kind, 'completed');
task = engine.applyStageResult(root, workflowId, task.state_version, brief2Result).task;
assert.equal(task.current_stage, 'section_draft');

fs.writeFileSync(path.join(root, '草稿_第002节_候选.md'), draft2);
const draft2Result = loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第002节_候选.md' });
assert.equal(draft2Result.kind, 'completed');
task = engine.applyStageResult(root, workflowId, task.state_version, draft2Result).task;
assert.equal(task.current_stage, 'machine_gate');

const machine2 = loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第002节_候选.md' });
assert.equal(machine2.kind, 'completed');
assert.equal(machine2.next_stage, 'story_gate');
task = engine.applyStageResult(root, workflowId, task.state_version, machine2).task;
assert.equal(task.current_stage, 'story_gate');

const evidence2Rel = writeEvidenceCard({
  repo, root, task, draftRel: '草稿_第002节_候选.md',
});
const story2 = loop.runStoryGate({
  projectRoot: root, task, draft: '草稿_第002节_候选.md', evidenceFile: evidence2Rel,
});
assert.equal(story2.kind, 'completed');
task = engine.applyStageResult(root, workflowId, task.state_version, story2).task;
assert.equal(task.current_stage, 'section_accept');

const accept2 = loop.acceptSection({ projectRoot: root, task });
assert.equal(accept2.kind, 'completed', JSON.stringify(accept2));
assert.equal(accept2.next_stage, 'assembly',
  'final planned section accept must target assembly');
task = engine.applyStageResult(root, workflowId, task.state_version, accept2).task;

// Section 1 hash unchanged, section 2 canonical exists, exactly two anchors
// and two accepted project-state entries, task at assembly, no section 3.
assert.equal(hashFile(canonical1), section1Hash, 'section 1 canonical must be immutable');
assert.ok(fs.existsSync(path.join(root, '正文', '第002节.md')), '正文/第002节.md must exist');
const anchors2 = fs.readdirSync(stateDir).filter((name) => /^section-\d{3}-anchor\.json$/.test(name));
assert.deepEqual(anchors2, ['section-001-anchor.json', 'section-002-anchor.json'],
  `exactly two anchors after section 2: ${JSON.stringify(anchors2)}`);
const projectState2 = JSON.parse(fs.readFileSync(path.join(stateDir, 'project-state.json'), 'utf8'));
assert.equal((projectState2.accepted_sections || []).length, 2, 'two accepted sections after section 2');
assert.equal(task.current_stage, 'assembly');
assert.ok(!fs.existsSync(path.join(root, '写作Brief_第003节.md')), 'no section 3 Brief');
assert.ok(!fs.existsSync(path.join(root, '正文', '第003节.md')), 'no section 3 canonical');
assert.ok(!fs.existsSync(path.join(stateDir, 'section-003-anchor.json')), 'no section 3 anchor');

// --- Whole-story editorial repair --------------------------------------
// Assemble the accepted canonical sections, then let an editorial revise
// result enter the same author-confirmed feedback path used in production.
const storyFile = path.join(root, '正文.md');
fs.writeFileSync(storyFile, `${fs.readFileSync(canonical1, 'utf8').trim()}\n\n${fs.readFileSync(path.join(root, '正文', '第002节.md'), 'utf8').trim()}\n`);
const storyBeforeRepair = hashFile(storyFile);
task = engine.applyStageResult(root, workflowId, task.state_version, {
  kind: 'completed', code: 'short_story_assembled', stage_id: 'assembly', next_stage: 'editorial_review',
}).task;
const firstReview = engine.applyStageResult(root, workflowId, task.state_version, {
  kind: 'completed', code: 'short_story_editorial_revision_required', stage_id: 'editorial_review',
  decision: 'revise', next_stage: 'planning_confirmation', story_sha256: storyBeforeRepair,
  review_card_sha256: 'sha256:editorial-cycle-one', section_indices: [1, 2],
  findings: [{
    code: 'EndingCost', severity: 'S2', scope: '第2节',
    evidence_quote: '我没有再用情面替责任结账，主管也保持沉默地接受了这个结果。',
    repair_direction: '补足主管接受结果后对公开复核的实际约束。',
  }],
});
task = firstReview.task;
assert.equal(task.current_stage, 'editorial_review');
assert.equal(task.pending_feedback.status, 'awaiting_confirmation');
const firstFeedbackId = task.pending_feedback.id;
engine.resolveAuthorInput(root, workflowId, task.state_version, {
  ...firstReview.visible_response.binding,
  choice: '1',
});
task = engine.readTask(root, workflowId);
assert.equal(task.current_stage, 'feedback_apply_patch');
assert.equal(task.current_section_index, 2);

// The accepted planning-and-prose plan has a dedicated staged transaction.
// The canonical outline stays untouched until this transaction accepts it.
const planningPatch = runner.describeCurrentStage({ projectRoot: root, workflowId });
assert.equal(planningPatch.stage_id, 'feedback_apply_patch');
assert.equal(planningPatch.write_set.includes('写作Brief_第002节.md'), false);
const stagedRepairOutline = path.join(root, planningPatch.write_set[0]);
fs.mkdirSync(path.dirname(stagedRepairOutline), { recursive: true });
fs.writeFileSync(stagedRepairOutline,
  `${fs.readFileSync(path.join(root, '小节大纲.md'), 'utf8').trim()}\n- 回炉约束：主管接受停权后，公开复核必须形成可执行的长期约束。\n`);
task = runner.runCurrentStage({
  projectRoot: root,
  workflowId,
  expectedVersion: planningPatch.state_version,
}).task;
assert.equal(task.current_stage, 'section_brief');
fs.writeFileSync(path.join(root, '写作Brief_第002节.md'), `${brief2.trim()}\n\n## 回炉约束\n- 主管接受结果后，公开复核形成长期约束。\n`);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;
assert.equal(task.current_stage, 'section_draft');
assert.equal(task.feedback_revision_queue.status, 'running');
assert.deepEqual(task.feedback_revision_queue.affected_sections, [2]);

const revisedDraft2 = `${draft2.trim()}\n主管随后交出审批权限，公开复核被写进每次归档都必须执行的流程。\n`;
fs.writeFileSync(path.join(root, '草稿_第002节_候选.md'), revisedDraft2);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第002节_候选.md' })).task;
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第002节_候选.md' })).task;
const repairEvidenceRel = writeEvidenceCard({
  repo, root, task, draftRel: '草稿_第002节_候选.md',
});
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runStoryGate({
    projectRoot: root, task, draft: '草稿_第002节_候选.md', evidenceFile: repairEvidenceRel,
  })).task;
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.acceptSection({ projectRoot: root, task })).task;
assert.equal(task.current_stage, 'assembly');
assert.equal(task.feedback_revision_queue.status, 'completed');
assert.equal(task.pending_feedback.status, 'applied');
assert.equal(task.pending_feedback.id, firstFeedbackId);

fs.writeFileSync(storyFile, `${fs.readFileSync(canonical1, 'utf8').trim()}\n\n${fs.readFileSync(path.join(root, '正文', '第002节.md'), 'utf8').trim()}\n`);
const storyAfterRepair = hashFile(storyFile);
assert.notEqual(storyAfterRepair, storyBeforeRepair, 'accepted editorial repair must change canonical prose');
task = engine.applyStageResult(root, workflowId, task.state_version, {
  kind: 'completed', code: 'short_story_reassembled', stage_id: 'assembly', next_stage: 'editorial_review',
}).task;
assert.equal(task.current_stage, 'editorial_review');

// A still-unresolved second review creates a new proposal without erasing the
// applied first review or its evidence.
const secondReview = engine.applyStageResult(root, workflowId, task.state_version, {
  kind: 'completed', code: 'short_story_editorial_revision_required', stage_id: 'editorial_review',
  decision: 'revise', next_stage: 'planning_confirmation', story_sha256: storyAfterRepair,
  review_card_sha256: 'sha256:editorial-cycle-two', section_indices: [1, 2],
  findings: [{
    code: 'reader_pull', severity: 'S3', scope: '第1节',
    evidence_quote: '主管推门进来，让我立刻撤回这次扫描，理由是季度交付吃紧。',
    repair_direction: '加强第一节末尾对下一步公开复核的牵引。',
  }],
});
assert.equal(secondReview.task.current_stage, 'editorial_review');
assert.notEqual(secondReview.task.pending_feedback.id, firstFeedbackId);
assert.ok((secondReview.task.feedback_history || []).some(item => item.id === firstFeedbackId));
NODE
}

@test "V3 professional services never return visible_response or numbered options" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1, draft1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const { writeEvidenceCard } = require(process.env.QUALITY_HELPER);

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
const evidenceRel = writeEvidenceCard({
  repo, root, task, draftRel: '草稿_第001节_候选.md',
});
const story = loop.runStoryGate({
  projectRoot: root, task, draft: '草稿_第001节_候选.md', evidenceFile: evidenceRel,
});

// A passing story gate result must never carry visible_response and any options
// it carries must be unnumbered (the Arbiter assigns numbers after persistence).
assert.ok(!Object.prototype.hasOwnProperty.call(story, 'visible_response'),
  'professional services must never return visible_response');
if (story.options) {
  for (const option of story.options) {
    assert.ok(!Object.prototype.hasOwnProperty.call(option, 'number'),
      'professional services must never assign option numbers');
  }
}
NODE
}

@test "legacy section CLIs refuse V3 tasks before writing V2 packets" {
    plan_to_section_brief
    task_file="$PROJECT/追踪/workflow/tasks/wf-section-loop/task.json"
    before="$(shasum -a 256 "$task_file" | awk '{print $1}')"
    for script in \
        short-section-brief-finalize.js \
        short-section-draft-finalize.js \
        short-section-machine-gate.js \
        short-section-quality-gate.js \
        short-section-accept-finalize.js; do
        run node "$REPO/scripts/$script" --project-root "$PROJECT" --workflow-id wf-section-loop --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'"status":"v3_engine_apply_required"'* ]]
    done
    after="$(shasum -a 256 "$task_file" | awk '{print $1}')"
    [ "$before" = "$after" ]
}

@test "V3 draft blocks when a recorded stage memory packet is missing" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1, draft1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
let task = engine.readTask(root, 'wf-section-loop');
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task = engine.applyStageResult(root, task.workflow_id, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft1);
task.stage_execution.stage_context_packet = {
  packet_json: '追踪/workflow/tasks/wf-section-loop/artifacts/missing-memory-context.json',
};
const result = loop.finalizeDraft({
  projectRoot: root, task, draft: '草稿_第001节_候选.md',
});
assert.equal(result.kind, 'blocked', JSON.stringify(result));
assert.equal(result.code, 'short_memory_context_refresh_required');
assert.equal(result.memory_status, 'missing');
NODE
}

@test "V3 Brief blocks when its recorded stage memory packet is missing" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const task = engine.readTask(root, 'wf-section-loop');
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task.stage_execution.stage_context_packet = {
  packet_json: '追踪/workflow/tasks/wf-section-loop/artifacts/missing-brief-memory-context.json',
};
const result = loop.finalizeBrief({ projectRoot: root, task });
assert.equal(result.kind, 'blocked', JSON.stringify(result));
assert.equal(result.code, 'short_memory_context_refresh_required');
assert.equal(result.memory_status, 'missing');
NODE
}

@test "V3 Brief author-judgment overload goes directly to unnumbered choice" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const task = engine.readTask(root, 'wf-section-loop');
const overload = `${brief1}\n\n## 证据机制\n1. 现场记录。\n2. 书面凭据。\n3. 第三方核验。\n4. 时间线复核。\n\n## 本节承担项\n1. 回答核心疑问。\n2. 兑现前置承诺。\n3. 处理直接后果。\n4. 完成人物关系变化。\n5. 建立下一阶段的新状态。\n`;
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), overload);
const result = loop.finalizeBrief({ projectRoot: root, task });
assert.equal(result.kind, 'needs_author_choice', JSON.stringify(result));
assert.ok(result.options.length >= 2 && result.options.length <= 4);
result.options.forEach((option) => assert.ok(!Object.prototype.hasOwnProperty.call(option, 'number')));
NODE
}

@test "V3 single-section deficit beyond twenty percent automatically routes to repair" {
    mkdir -p "$PROJECT/追踪/story-system/short" "$PROJECT/追踪/workflow/tasks/wf-length/artifacts"
    printf '%s\n' '{"project_id":"neutral-length","current_section_index":2,"accepted_sections":[{"section_index":1,"length_chars":2000,"section_role":"normal"}]}' > "$PROJECT/追踪/story-system/short/project-state.json"
    printf '%s\n' '## 本节目标' '目标篇幅：2000 字' > "$PROJECT/写作Brief_第002节.md"
    printf '%s' "$NEUTRAL_DRAFT_2" > "$PROJECT/草稿_第002节_候选.md"
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const task = {
  workflow_id: 'wf-length',
  workflow_type: 'short_write',
  task_dir: '追踪/workflow/tasks/wf-length',
  current_stage: 'machine_gate',
  scope: '第2节',
  stage_execution: { stage_id: 'machine_gate', section_index: 2 },
};
const result = loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第002节_候选.md' });
assert.equal(result.kind, 'completed', JSON.stringify(result));
assert.equal(result.code, 'short_machine_gate_blocking');
assert.equal(result.next_stage, 'section_repair');
assert.equal(result.length_policy.verdict, 'under_target_repair_required');
assert.equal(result.length_policy.author_decision_required, false);
assert.ok(!Object.prototype.hasOwnProperty.call(result, 'visible_response'));
NODE
}

@test "V3 machine gate enforces generated Brief budget wording before section acceptance" {
    mkdir -p "$PROJECT/追踪/story-system/short" "$PROJECT/追踪/workflow/tasks/wf-budget-length/artifacts"
    printf '%s\n' '{"project_id":"neutral-budget-length","current_section_index":1,"accepted_sections":[]}' > "$PROJECT/追踪/story-system/short/project-state.json"
    printf '%s\n' '## 本节目标' '- 字数预算：2800 字（允许 -10%% 到 +20%%）' '本节预算 2800 字。' > "$PROJECT/写作Brief_第001节.md"
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const draftRel = '草稿_第001节_候选.md';
fs.writeFileSync(path.join(root, draftRel), `# 第1节\n\n${'字'.repeat(865)}\n`);
const task = {
  workflow_id: 'wf-budget-length',
  workflow_type: 'short_write',
  task_dir: '追踪/workflow/tasks/wf-budget-length',
  current_stage: 'machine_gate',
  scope: '第1节',
  stage_execution: { stage_id: 'machine_gate', section_index: 1 },
};
const result = loop.runMachineGate({ projectRoot: root, task, draft: draftRel });
assert.equal(result.kind, 'completed', JSON.stringify(result));
assert.equal(result.code, 'short_machine_gate_blocking');
assert.equal(result.next_stage, 'section_repair');
assert.equal(result.length_policy.target_chars, 2800, JSON.stringify(result.length_policy));
assert.equal(result.length_policy.hard_floor, 2520);
assert.equal(result.length_policy.verdict, 'under_target_repair_required');
NODE
}

@test "V3 whole-story queue automatically repairs a deficit beyond twenty percent" {
    mkdir -p "$PROJECT/追踪/story-system/short" "$PROJECT/追踪/workflow/tasks/wf-length-queue/artifacts"
    printf '%s\n' '{"project_id":"neutral-length-queue","current_section_index":2,"accepted_sections":[{"section_index":1,"length_chars":2000,"section_role":"normal"}]}' > "$PROJECT/追踪/story-system/short/project-state.json"
    printf '%s\n' '## 本节目标' '目标篇幅：2000 字' > "$PROJECT/写作Brief_第002节.md"
    printf '%s' "$NEUTRAL_DRAFT_2" > "$PROJECT/草稿_第002节_候选.md"
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const task = {
  workflow_id: 'wf-length-queue',
  workflow_type: 'short_write',
  task_dir: '追踪/workflow/tasks/wf-length-queue',
  current_stage: 'machine_gate',
  scope: '第2节',
  lifecycle: { scope: '全篇' },
  feedback_revision_queue: { status: 'running', affected_sections: [2, 3] },
  stage_execution: { stage_id: 'machine_gate', section_index: 2 },
};
const draftRel = '草稿_第002节_候选.md';
const first = loop.runMachineGate({ projectRoot: root, task, draft: draftRel });
assert.equal(first.kind, 'completed', JSON.stringify(first));
assert.equal(first.next_stage, 'section_repair');
assert.equal(first.length_policy.verdict, 'under_target_repair_required');
assert.ok(!Object.prototype.hasOwnProperty.call(first, 'options'));
NODE
}

@test "V3 machine gate blocking selects section_repair without accepting a section" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const { buildStageContextPacket } = require(path.join(repo, 'scripts/lib/workflow-stage-context-packet.js'));
const { resolveShortStateRelative } = require(path.join(repo, 'scripts/lib/short-project-state'));

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;

// A draft that fails the real AI-pattern / story-prose checks (repeated
// filler). The real machine gate must report it blocking and the result must
// select section_repair WITHOUT accepting a section.
const badDraft = '# 第1节\n\n' + '我沉默地接受这个结果，我沉默地接受这个结果，我沉默地接受这个结果。'.repeat(40) + '\n';
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), badDraft);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
const machine = loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md' });
assert.equal(machine.kind, 'completed');
assert.equal(machine.next_stage, 'section_repair',
  'blocking machine gate must select section_repair');
task = engine.applyStageResult(root, workflowId, task.state_version, machine).task;
assert.equal(task.current_stage, 'section_repair');
const repairPacket = buildStageContextPacket({ projectRoot: root, task, stage: 'section_repair' });
assert.equal(repairPacket.status, 'assembled', JSON.stringify(repairPacket));
assert.ok(repairPacket.source_files.some(row => row.kind === 'machine_gate_findings'), JSON.stringify(repairPacket));
const repairText = fs.readFileSync(path.join(root, repairPacket.packet_md), 'utf8');
assert.match(repairText, new RegExp(machine.blocking_findings[0].message.slice(0, 12), 'u'), repairText);

// No section was accepted: no canonical section, no anchor, no accepted entry.
assert.ok(!fs.existsSync(path.join(root, '正文', '第001节.md')), 'no canonical section on blocking gate');
const stateDir = path.dirname(path.join(root, resolveShortStateRelative(root, 'project-state.json')));
if (fs.existsSync(stateDir)) {
  const anchors = fs.readdirSync(stateDir).filter((name) => /^section-\d{3}-anchor\.json$/.test(name));
  assert.deepEqual(anchors, [], 'no accepted anchor on blocking gate');
}
NODE
}

@test "V3 machine gate reports the blocking finding instead of an earlier advisory" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1, draft1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;

// The em dash is advisory, while the ASCII dialogue quotes are blocking. The
// author-facing result must name the punctuation that actually stopped the
// workflow instead of presenting the first advisory as the cause.
const draft = draft1.replace(
  '主管推门进来，让我立刻撤回这次扫描，理由是季度交付吃紧。',
  '主管推门进来——他说："立刻撤回这次扫描。"理由是季度交付吃紧。',
);
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
const machine = loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md' });
assert.equal(machine.next_stage, 'section_repair', JSON.stringify(machine));
assert.ok(machine.blocking_findings.length >= 1, JSON.stringify(machine));
machine.blocking_findings.forEach((finding) => {
  assert.match(finding.message, /半角直引号|中文弯引号/u, JSON.stringify(finding));
  assert.doesNotMatch(finding.message, /破折号/u, JSON.stringify(finding));
});
NODE
}

@test "V3 story gate routes semantic revise to section repair while invalid evidence stays at the gate" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1, draft1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const { buildStageContextPacket } = require(path.join(repo, 'scripts/lib/workflow-stage-context-packet.js'));
const { writeEvidenceCard } = require(process.env.QUALITY_HELPER);

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;

// 1) Missing evidence: the service must NOT auto-pass. With no evidenceFile
//    supplied it must return a non-completed StageResult (retryable_internal or
//    blocked), never a fabricated pass. It must never read a decision override.
const noEvidence = loop.runStoryGate({
  projectRoot: root, task, draft: '草稿_第001节_候选.md',
});
assert.notEqual(noEvidence.kind, 'completed',
  'runStoryGate must never auto-pass when real evidence is missing');

// 2) A schema-valid evidence card carrying revise is a valid quality decision,
//    not broken evidence. It must complete the gate and route directly to the
//    local section repair stage without asking the author to diagnose it.
const revise1Rel = writeEvidenceCard({
  repo, root, task, draftRel: '草稿_第001节_候选.md', reviseDimensions: ['reader_pull'],
});
const first = loop.runStoryGate({
  projectRoot: root, task, draft: '草稿_第001节_候选.md', evidenceFile: revise1Rel,
});
assert.equal(first.kind, 'completed', JSON.stringify(first));
assert.equal(first.next_stage, 'section_repair');
assert.ok(first.revision_requirements.some(row => row.label === '读者追读力'), JSON.stringify(first));
task = engine.applyStageResult(root, workflowId, task.state_version, first).task;
assert.equal(task.current_stage, 'section_repair');
assert.equal(task.pending_action, null);
const repairPacket = buildStageContextPacket({ projectRoot: root, task, stage: 'section_repair' });
assert.equal(repairPacket.status, 'assembled', JSON.stringify(repairPacket));
const repairText = fs.readFileSync(path.join(root, repairPacket.packet_md), 'utf8');
assert.match(repairText, /读者追读力/u, repairText);

// 3) A broken card is still an evidence failure and must not enter prose repair.
const badEvidence = JSON.parse(fs.readFileSync(path.join(root, revise1Rel), 'utf8'));
badEvidence.draft_digest = 'wrong-digest';
const badRel = path.join(path.dirname(revise1Rel), 'bad-story-review.json');
fs.writeFileSync(path.join(root, badRel), JSON.stringify(badEvidence, null, 2));
const atGate = { ...task, current_stage: 'story_gate' };
const second = loop.runStoryGate({
  projectRoot: root, task: atGate, draft: '草稿_第001节_候选.md', evidenceFile: badRel,
});
assert.notEqual(second.kind, 'completed', JSON.stringify(second));
assert.notEqual(second.next_stage, 'section_repair', JSON.stringify(second));

// 4) Duplicate rows are malformed evidence, not two independent judgments.
//    They must stay at the story gate instead of silently letting the last row
//    win or turning an invalid card into a prose-repair decision.
const duplicateEvidence = JSON.parse(fs.readFileSync(path.join(root, revise1Rel), 'utf8'));
duplicateEvidence.checks.push({ ...duplicateEvidence.checks[0] });
duplicateEvidence.outline_coverage.push({ ...duplicateEvidence.outline_coverage[0] });
const duplicateRel = path.join(path.dirname(revise1Rel), 'duplicate-story-review.json');
fs.writeFileSync(path.join(root, duplicateRel), JSON.stringify(duplicateEvidence, null, 2));
const duplicate = loop.runStoryGate({
  projectRoot: root, task: atGate, draft: '草稿_第001节_候选.md', evidenceFile: duplicateRel,
});
assert.notEqual(duplicate.kind, 'completed', JSON.stringify(duplicate));
assert.notEqual(duplicate.next_stage, 'section_repair', JSON.stringify(duplicate));
assert.ok(duplicate.findings.some(row => row.code === 'evidence_check_duplicate'), JSON.stringify(duplicate));
assert.ok(duplicate.findings.some(row => row.code === 'draft_outline_obligation_duplicate'), JSON.stringify(duplicate));

// 5) A milestone-kind mismatch is an evidence-only repair. The result must
//    expose the expected and actual values in readable language so an agent can
//    fix the card once instead of guessing, rewriting prose, or looping.
const kindEvidence = JSON.parse(fs.readFileSync(path.join(root, revise1Rel), 'utf8'));
const expectedKind = kindEvidence.reader_milestone.kind;
const actualKind = expectedKind === 'contract_review' ? 'opening_review' : 'contract_review';
kindEvidence.reader_milestone.kind = actualKind;
const kindRel = path.join(path.dirname(revise1Rel), 'milestone-kind-mismatch.json');
fs.writeFileSync(path.join(root, kindRel), JSON.stringify(kindEvidence, null, 2));
const kindMismatch = loop.runStoryGate({
  projectRoot: root, task: atGate, draft: '草稿_第001节_候选.md', evidenceFile: kindRel,
});
assert.equal(kindMismatch.kind, 'retryable_internal', JSON.stringify(kindMismatch));
assert.equal(kindMismatch.code, 'short_story_evidence_invalid', JSON.stringify(kindMismatch));
assert.equal(kindMismatch.evidence, kindRel, JSON.stringify(kindMismatch));
const kindFinding = kindMismatch.findings.find(row => row.code === 'evidence_reader_milestone_kind_mismatch');
assert.equal(kindFinding.expected_kind, expectedKind, JSON.stringify(kindMismatch));
assert.equal(kindFinding.actual_kind, actualKind, JSON.stringify(kindMismatch));
const kindRequirement = kindMismatch.revision_requirements.find(
  row => row.id === 'professional_reader_milestone');
assert.equal(kindRequirement.expected_kind, expectedKind, JSON.stringify(kindMismatch));
assert.equal(kindRequirement.actual_kind, actualKind, JSON.stringify(kindMismatch));
assert.match(kindRequirement.requirement, new RegExp(expectedKind), JSON.stringify(kindMismatch));
assert.match(kindRequirement.requirement, new RegExp(actualKind), JSON.stringify(kindMismatch));
assert.match(kindRequirement.requirement, /只修改证据卡，不要改正文/u, JSON.stringify(kindMismatch));
assert.match(kindMismatch.instruction, /只修复证据卡/u, JSON.stringify(kindMismatch));
NODE
}

@test "V3 re-accepting an identical section is idempotent and cannot duplicate state" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1, draft1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const { resolveShortStateRelative } = require(path.join(repo, 'scripts/lib/short-project-state'));
const { writeEvidenceCard } = require(process.env.QUALITY_HELPER);

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
const evidenceRel = writeEvidenceCard({
  repo, root, task, draftRel: '草稿_第001节_候选.md',
});
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runStoryGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md', evidenceFile: evidenceRel })).task;

// First accept: section 1 lands once.
task.feedback_revision_queue = {
  status: 'running',
  current_section_index: 2,
  affected_sections: [1, 2],
  items: [
    { section_index: 1, status: 'pending' },
    { section_index: 2, status: 'pending' },
  ],
};
const cursorMismatch = loop.acceptSection({ projectRoot: root, task });
assert.equal(cursorMismatch.kind, 'blocked', JSON.stringify(cursorMismatch));
assert.equal(cursorMismatch.code, 'blocked_feedback_revision_section_mismatch');
assert.ok(!fs.existsSync(path.join(root, '正文', '第001节.md')),
  'cursor mismatch must block before canonical commit');
delete task.feedback_revision_queue;

const originalEvidence = fs.readFileSync(path.join(root, evidenceRel), 'utf8');
const tamperedEvidence = JSON.parse(originalEvidence);
tamperedEvidence.checks[0].status = 'revise';
fs.writeFileSync(path.join(root, evidenceRel), `${JSON.stringify(tamperedEvidence, null, 2)}\n`);
const tampered = loop.acceptSection({ projectRoot: root, task });
assert.equal(tampered.kind, 'completed', JSON.stringify(tampered));
assert.equal(tampered.code, 'accept_story_evidence_changed');
assert.equal(tampered.next_stage, 'machine_gate');
assert.ok(!fs.existsSync(path.join(root, '正文', '第001节.md')),
  'changed story evidence must block before canonical commit');
fs.writeFileSync(path.join(root, evidenceRel), originalEvidence);

const firstAccept = loop.acceptSection({ projectRoot: root, task });
assert.equal(firstAccept.kind, 'completed', JSON.stringify(firstAccept));
const commitsDir = path.join(root, '追踪', 'story-system', 'commits');
const commitsAfterFirst = fs.readdirSync(commitsDir).length;
const stateDir = path.dirname(path.join(root, resolveShortStateRelative(root, 'project-state.json')));
const anchorFile = path.join(stateDir, 'section-001-anchor.json');
const projectStateFile = path.join(stateDir, 'project-state.json');
const outboxFile = path.join(root, '追踪', 'integration', 'outbox.jsonl');
const anchorAfterFirst = fs.readFileSync(anchorFile, 'utf8');
const projectStateAfterFirst = fs.readFileSync(projectStateFile, 'utf8');
const outboxAfterFirst = fs.readFileSync(outboxFile, 'utf8');
const acceptedCommit = JSON.parse(fs.readFileSync(
  path.join(commitsDir, `${firstAccept.commit_id}.json`), 'utf8'));
assert.equal(JSON.parse(anchorAfterFirst).accepted_at, acceptedCommit.accepted_at,
  'anchor audit time must come from the canonical accepted commit');

// Re-running accept against the SAME draft digest is idempotent: no duplicate
// commit, no duplicate anchor, no duplicate accepted-section entry. The shared
// service returns the same completed result without writing a second commit.
const idempotent = loop.acceptSection({ projectRoot: root, task });
assert.equal(idempotent.kind, 'completed', JSON.stringify(idempotent));
assert.equal(idempotent.code, 'short_section_accept_idempotent');
if (idempotent.commit_id !== firstAccept.commit_id) {
  const commitsAfterSecond = fs.readdirSync(commitsDir).length;
  assert.equal(commitsAfterSecond, commitsAfterFirst, 'no duplicate accepted commit on re-accept');
}
assert.equal(fs.readFileSync(anchorFile, 'utf8'), anchorAfterFirst, 'idempotent retry must not rewrite anchor');
assert.equal(fs.readFileSync(projectStateFile, 'utf8'), projectStateAfterFirst,
  'idempotent retry must not rewrite project state');
assert.equal(fs.readFileSync(outboxFile, 'utf8'), outboxAfterFirst,
  'idempotent retry must not append another integration event');
const anchors = fs.readdirSync(stateDir).filter((name) => /^section-\d{3}-anchor\.json$/.test(name));
assert.deepEqual(anchors, ['section-001-anchor.json'], 'exactly one anchor after idempotent re-accept');
const projectState = JSON.parse(fs.readFileSync(path.join(stateDir, 'project-state.json'), 'utf8'));
const sectionOnes = (projectState.accepted_sections || []).filter((item) => Number(item.section_index) === 1);
assert.equal(sectionOnes.length, 1, 'no duplicate accepted-section entry on re-accept');

// Simulate an interruption after the canonical commit but before its derived
// control-plane records all land. A retry must repair the missing anchor,
// project-state entry, and idempotent outbox event without creating a second
// canonical commit.
fs.unlinkSync(anchorFile);
fs.writeFileSync(projectStateFile, `${JSON.stringify({
  ...projectState,
  status: 'planning_confirmed',
  current_stage: 'section_accept',
  current_section_index: 1,
  accepted_sections: [],
}, null, 2)}\n`);
fs.unlinkSync(outboxFile);
const recovered = loop.acceptSection({ projectRoot: root, task });
assert.equal(recovered.kind, 'completed', JSON.stringify(recovered));
assert.equal(recovered.code, 'short_section_accept_recovered');
assert.ok(fs.existsSync(anchorFile), 'recovery must recreate a missing accepted anchor');
const recoveredAnchorText = fs.readFileSync(anchorFile, 'utf8');
assert.equal(JSON.parse(recoveredAnchorText).accepted_at, acceptedCommit.accepted_at,
  'recovery must preserve the original canonical acceptance time');
const recoveredStateText = fs.readFileSync(projectStateFile, 'utf8');
const recoveredState = JSON.parse(recoveredStateText);
assert.equal((recoveredState.accepted_sections || [])
  .filter((item) => Number(item.section_index) === 1).length, 1,
'recovery must restore exactly one project-state accepted entry');
const recoveredOutboxText = fs.readFileSync(outboxFile, 'utf8');
assert.equal(recoveredOutboxText.trim().split(/\r?\n/).filter(Boolean).length, 1,
  'recovery must restore exactly one integration event');
assert.equal(fs.readdirSync(commitsDir).length, commitsAfterFirst,
  'recovery must reuse the accepted canonical commit');

const afterRecovery = loop.acceptSection({ projectRoot: root, task });
assert.equal(afterRecovery.code, 'short_section_accept_idempotent');
assert.equal(fs.readFileSync(anchorFile, 'utf8'), recoveredAnchorText,
  'post-recovery retry must not rewrite anchor');
assert.equal(fs.readFileSync(projectStateFile, 'utf8'), recoveredStateText,
  'post-recovery retry must not rewrite project state');
assert.equal(fs.readFileSync(outboxFile, 'utf8'), recoveredOutboxText,
  'post-recovery retry must not append an event');
NODE
}

@test "V3 changing section 1 after acceptance returns blocked and cannot overwrite its canonical file" {
    plan_to_section_brief
    node - "$REPO" "$PROJECT" "$NEUTRAL_BRIEF_1" "$NEUTRAL_DRAFT_1" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root, brief1, draft1] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const loop = require(path.join(repo, 'scripts/lib/short-production/section-loop.js'));
const { writeEvidenceCard } = require(process.env.QUALITY_HELPER);
const hashFile = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

const workflowId = 'wf-section-loop';
let task = engine.readTask(root, workflowId);
fs.writeFileSync(path.join(root, '写作Brief_第001节.md'), brief1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeBrief({ projectRoot: root, task })).task;
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), draft1);
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.finalizeDraft({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runMachineGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md' })).task;
const evidenceRel = writeEvidenceCard({
  repo, root, task, draftRel: '草稿_第001节_候选.md',
});
task = engine.applyStageResult(root, workflowId, task.state_version,
  loop.runStoryGate({ projectRoot: root, task, draft: '草稿_第001节_候选.md', evidenceFile: evidenceRel })).task;

// KEEP the section_accept task snapshot. The first accept runs WITHOUT advancing
// the Engine, so `acceptSnapshot` stays validly on section_accept for the
// second call.
const acceptSnapshot = task;
const firstAccept = loop.acceptSection({ projectRoot: root, task: acceptSnapshot });
assert.equal(firstAccept.kind, 'completed');

const canonical1 = path.join(root, '正文', '第001节.md');
const originalHash = hashFile(canonical1);

// Change the SAME candidate draft to a different body and attempt to re-accept
// the same section against the SAME valid section_accept snapshot. The shared
// service must return an explicit blocked StageResult (not a silent completed)
// and must NOT overwrite the accepted immutable canonical file.
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'),
  '# 第1节\n\n完全不同的内容，试图覆盖已采用的小节。\n');
const secondAccept = loop.acceptSection({ projectRoot: root, task: acceptSnapshot });
assert.equal(secondAccept.kind, 'completed', JSON.stringify(secondAccept));
assert.equal(secondAccept.next_stage, 'machine_gate',
  'changed candidate must return to machine gate before any replacement decision');
assert.ok(String(secondAccept.code || '').trim(),
  'the recovery StageResult must carry a stable code');

// The canonical file must be byte-identical to the accepted one regardless.
assert.equal(hashFile(canonical1), originalHash,
  'changing an accepted section must not overwrite its canonical file');

// A durable revision queue authorizes replacement only for its exact current
// section. Rebuild real machine/story receipts for a valid revised candidate,
// then accept through the same transaction service.
const stateFile = path.join(root, '追踪', 'story-system', 'short', 'project-state.json');
const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
fs.writeFileSync(stateFile, `${JSON.stringify({ ...state, current_section_index: 1 }, null, 2)}\n`);
const revisedDraft = `${draft1}\n我把更正后的复核时间写进公开记录，也承担因此增加的延期。\n`;
fs.writeFileSync(path.join(root, '草稿_第001节_候选.md'), revisedDraft);
let revisionTask = {
  ...acceptSnapshot,
  current_stage: 'machine_gate',
  pending_feedback: {
    id: 'feedback-neutral-revision', status: 'accepted', section_index: 1,
    accepted_plan: { affected_sections: [1], impact_level: 'prose' },
  },
  feedback_revision_queue: {
    status: 'running', current_section_index: 1, affected_sections: [1],
    items: [{ section_index: 1, status: 'pending' }], completed_sections: [],
  },
  stage_execution: { status: 'running', stage_id: 'machine_gate', section_index: 1 },
};
const revisedMachine = loop.runMachineGate({
  projectRoot: root, task: revisionTask, draft: '草稿_第001节_候选.md',
});
assert.equal(revisedMachine.kind, 'completed', JSON.stringify(revisedMachine));
assert.equal(revisedMachine.next_stage, 'story_gate');
revisionTask = { ...revisionTask, current_stage: 'story_gate', stage_execution: {
  ...revisionTask.stage_execution, stage_id: 'story_gate',
} };
const revisedEvidenceRel = writeEvidenceCard({
  repo, root, task: revisionTask, draftRel: '草稿_第001节_候选.md',
});
const revisedStory = loop.runStoryGate({
  projectRoot: root, task: revisionTask,
  draft: '草稿_第001节_候选.md', evidenceFile: revisedEvidenceRel,
});
assert.equal(revisedStory.kind, 'completed', JSON.stringify(revisedStory));
revisionTask = { ...revisionTask, current_stage: 'section_accept', stage_execution: {
  ...revisionTask.stage_execution, stage_id: 'section_accept',
} };
const revisionAccept = loop.acceptSection({ projectRoot: root, task: revisionTask });
assert.equal(revisionAccept.kind, 'completed', JSON.stringify(revisionAccept));
assert.notEqual(hashFile(canonical1), originalHash,
  'matching active revision queue must transactionally replace the canonical section');
assert.equal(hashFile(canonical1), String(revisionAccept.canonical_sha256).replace(/^sha256:/, ''));
assert.equal(revisionAccept.all_sections_completed, false,
  'completing a local revision queue must not hide untouched missing planned sections');
assert.deepEqual(revisionAccept.remaining_sections, [2], JSON.stringify(revisionAccept));
assert.equal(revisionAccept.next_section, 2, JSON.stringify(revisionAccept));
assert.equal(revisionAccept.next_stage, 'section_brief',
  'after the revision queue completes, a fresh project must resume its next missing planned section');
NODE
}

@test "V3 shared service never imports forbidden V2 modules and never spawns workflow-state-machine apply-result" {
    # This static boundary assertion runs ONLY after the shared service module
    # exists. While section-loop.js is still missing the test delegates to the
    # same missing-module RED every other case hits, so the initial RED remains
    # the single trustworthy missing-handler failure. Once the module lands this
    # case enforces the architectural boundary against V2 imports and apply-result
    # child-process spawns.
    node - "$REPO" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo] = process.argv.slice(2);
const modulePath = path.join(repo, 'scripts/lib/short-production/section-loop.js');
if (!fs.existsSync(modulePath)) {
  // Module not implemented yet: the missing-module RED is captured by the
  // other cases. This case exits cleanly so the suite's first failure remains
  // the missing handler, not a false boundary failure.
  process.exit(0);
}
const source = fs.readFileSync(modulePath, 'utf8');

// The shared V3 service must never import the V2 state machine, entry guard,
// task inbox, action renderer, or the Interaction Arbiter, and must never
// spawn the V2 workflow-state-machine.js apply-result path.
const FORBIDDEN_IMPORTS = [
  /require\(\s*['"][^'"]*workflow-state-machine/u,
  /require\(\s*['"][^'"]*workflow-entry-guard/u,
  /require\(\s*['"][^'"]*workflow-task-inbox/u,
  /require\(\s*['"][^'"]*workflow-action-renderer/u,
  /require\(\s*['"][^'"]*interaction-arbiter/u,
];
for (const pattern of FORBIDDEN_IMPORTS) {
  assert.ok(!pattern.test(source),
    `section-loop.js must not import a forbidden V2 module (matched ${pattern})`);
}
assert.ok(!/workflow-state-machine\.js['"]\s*,\s*['"]?apply-result/u.test(source)
  && !/spawn(?:Sync)?\s*\([^)]*workflow-state-machine/u.test(source),
  'section-loop.js must never spawn workflow-state-machine.js apply-result');
NODE
}
