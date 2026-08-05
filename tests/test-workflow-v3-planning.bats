#!/usr/bin/env bats

# Task 5: Engine-neutral short planning service. The shared
# finalizePlanningStage returns a Task 1 StageResult only — no visible_response,
# no banned V2 imports — and the V3 Engine is the single writer that persists a
# retry_state for retryable_internal results. Tests drive the REAL V3 engine,
# the REAL plan/character validators, and the REAL chapter-commit transaction
# path; nothing is stubbed. All fixtures are project-neutral synthetic names so
# no real project title, character, plot, ID, or domain term leaks in.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/story-system"
    printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$PROJECT/追踪/story-system/write-policy.json"
}

teardown() {
    rm -rf "$TMP_DIR"
}

# A project-neutral setting that passes the REAL short character contract.
# Synthetic characters and a synthetic domain (archive number reconciliation) so
# no real project word appears.
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

# A project-neutral two-section outline that passes the REAL narrative quality
# validator for planned_sections=2 (section 1 opening, section 2 ending).
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

# A setting missing a protagonist: the REAL character contract returns a blocked
# status. The same file is submitted twice so the failure family is identical.
SETTING_NO_PROTAGONIST='# 设定

作品名：测试短篇
叙事方式：第一人称。
目标长度：共2节。
主节奏：发现异常 -> 修复。
'

@test "V3 finalizePlanningStage accepts a valid neutral setting and section_outline through a real transaction" {
    node - "$REPO" "$PROJECT" "$NEUTRAL_SETTING" "$NEUTRAL_OUTLINE" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, settingText, outlineText] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const planning = require(path.join(repo, 'scripts/lib/short-production/planning.js'));

// An ordinary V3 task created through engine.createTask MUST carry everything
// the real chapter-commit transaction path needs (task_family_id, branch_id,
// branch_status, and an Engine-owned stage_attempt_id). The test does NOT
// call ensureTaskFamily, mutate family/branch fields, OR inject a
// stage_execution: the create flow registers the family and the Engine owns
// the attempt provenance. A plain createTask must commit directly — Step 6.
let task = engine.createTask(root, {
  workflow_id: 'wf-plan-accept',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
// The durable task carries durable commit provenance stamped at creation.
assert.ok(String(task.task_family_id || '').trim(), 'createTask must stamp task_family_id');
assert.equal(task.branch_id, task.workflow_id, 'createTask must stamp branch_id = workflow_id');
assert.ok(String(task.branch_status || '').trim(), 'createTask must stamp branch_status');
// The Engine owns a non-empty stage_attempt_id without any caller injection.
assert.ok(String((task.stage_execution || {}).stage_attempt_id || '').trim(),
  'createTask must stamp an Engine-owned stage_attempt_id');

// Drive onto the setting node through real engine transitions.
for (const stage of ['creative_entry', 'material_positioning']) {
  task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: 'advance', stage_id: stage,
  }).task;
}
assert.equal(task.current_stage, 'setting');

// Stage the neutral setting artifact exactly as the production host would.
const stagedSettingRel = `${task.task_dir}/artifacts/planning/setting/sa-setting/设定.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedSettingRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedSettingRel), settingText);

// Commit the setting through the REAL chapter-commit transaction (apply=true).
// A passing setting must return a completed StageResult carrying the durable
// commit receipt, and write 设定.md to the project root.
const settingResult = planning.finalizePlanningStage({
  projectRoot: root,
  task,
  stageId: 'setting',
  stagedRel: stagedSettingRel,
  apply: true,
});
assert.equal(settingResult.kind, 'completed');
assert.equal(settingResult.stage_id, 'setting');
assert.ok(String(settingResult.commit_id || ''), 'completed setting must carry a commit_id receipt');
assert.ok(!Object.prototype.hasOwnProperty.call(settingResult, 'visible_response'),
  'StageResult must not carry visible_response');
assert.ok(fs.existsSync(path.join(root, '设定.md')), 'commit must write canonical 设定.md');

// Advance to section_outline and stage the neutral two-section outline.
task = engine.applyStageResult(root, task.workflow_id, task.state_version, settingResult).task;
assert.equal(task.current_stage, 'section_outline');
const stagedOutlineRel = `${task.task_dir}/artifacts/planning/section_outline/sa-outline/小节大纲.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedOutlineRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedOutlineRel), outlineText);

// Second call: COMMIT (apply=true). The real chapter-commit transaction must
// accept the outline, write 小节大纲.md to the project root, and stamp a
// durable commit record — proving the receipt is not faked. The outline
// validator reads the just-committed 设定.md from the project root.
const committed = planning.finalizePlanningStage({
  projectRoot: root,
  task,
  stageId: 'section_outline',
  stagedRel: stagedOutlineRel,
  apply: true,
});
assert.equal(committed.kind, 'completed');
assert.equal(committed.stage_id, 'section_outline');

// The committed result is applied to the real engine: the node advances.
task = engine.applyStageResult(root, task.workflow_id, task.state_version, committed).task;
assert.equal(task.current_stage, 'planning_confirmation');

// The canonical outline artifact exists on disk with the staged content, and a
// durable accepted commit exists in 追踪/story-system/commits referencing it.
assert.ok(fs.existsSync(path.join(root, '小节大纲.md')), 'canonical outline must be written');
assert.ok(fs.readFileSync(path.join(root, '小节大纲.md'), 'utf8').includes('发现重复编号'));
const commitDir = path.join(root, '追踪', 'story-system', 'commits');
const commits = fs.readdirSync(commitDir).map((name) => JSON.parse(fs.readFileSync(path.join(commitDir, name), 'utf8')));
assert.ok(commits.some((commit) => commit.status === 'accepted'
  && (commit.artifacts || []).some((a) => a.target === '小节大纲.md')),
  'an accepted commit for 小节大纲.md must be durable');
NODE
}

@test "V3 first missing-protagonist failure is retryable_internal and Engine persists retry_state in task.json" {
    node - "$REPO" "$PROJECT" "$SETTING_NO_PROTAGONIST" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, settingText] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const planning = require(path.join(repo, 'scripts/lib/short-production/planning.js'));

let task = engine.createTask(root, {
  workflow_id: 'wf-plan-retry',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
for (const stage of ['creative_entry', 'material_positioning']) {
  task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: 'advance', stage_id: stage,
  }).task;
}
const stagedRel = `${task.task_dir}/artifacts/planning/setting/sa-bad/设定.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedRel), settingText);

// First identical failure: the planning service MUST return retryable_internal.
const first = planning.finalizePlanningStage({
  projectRoot: root, task, stageId: 'setting', stagedRel: stagedRel, apply: true,
});
assert.equal(first.kind, 'retryable_internal');
assert.equal(first.stage_id, 'setting');
assert.ok(String(first.failure_family || '').trim(), 'retryable_internal must carry a failure_family');

// The engine is the single writer: applying that result persists a compact
// retry_state (stage_id, failure_family, count=1) in the SAME state-version
// commit, and the node stays on setting.
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, first);
assert.equal(outcome.task.current_stage, 'setting');
assert.ok(outcome.task.retry_state, 'engine must persist retry_state');
assert.equal(outcome.task.retry_state.stage_id, 'setting');
assert.equal(outcome.task.retry_state.failure_family, first.failure_family);
assert.equal(Number(outcome.task.retry_state.count), 1);

// The durable task.json carries the same retry_state.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-plan-retry', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.deepEqual(persisted.retry_state, outcome.task.retry_state);
NODE
}

@test "V3 second identical failure becomes needs_author_choice driven by durable retry_state" {
    node - "$REPO" "$PROJECT" "$SETTING_NO_PROTAGONIST" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, settingText] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const planning = require(path.join(repo, 'scripts/lib/short-production/planning.js'));

let task = engine.createTask(root, {
  workflow_id: 'wf-plan-choice',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
for (const stage of ['creative_entry', 'material_positioning']) {
  task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: 'advance', stage_id: stage,
  }).task;
}
const stagedRel = `${task.task_dir}/artifacts/planning/setting/sa-bad/设定.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedRel), settingText);

// First identical failure -> retryable_internal, persisted by the engine.
const first = planning.finalizePlanningStage({
  projectRoot: root, task, stageId: 'setting', stagedRel: stagedRel, apply: true,
});
assert.equal(first.kind, 'retryable_internal');
task = engine.applyStageResult(root, task.workflow_id, task.state_version, first).task;

// Reread the freshly committed task and submit the SAME failing artifact a
// second time. The planning service must read the durable retry_state and turn
// the second identical failure into a needs_author_choice StageResult with 2-4
// unnumbered options — no retry count is injected by the caller.
const reread = engine.readTask(root, task.workflow_id);
assert.ok(reread.retry_state, 'reread task must carry durable retry_state');
const second = planning.finalizePlanningStage({
  projectRoot: root, task: reread, stageId: 'setting', stagedRel: stagedRel, apply: true,
});
assert.equal(second.kind, 'needs_author_choice');
assert.equal(second.stage_id, 'setting');
assert.ok(Array.isArray(second.options) && second.options.length >= 2 && second.options.length <= 4,
  'needs_author_choice must carry 2-4 options');
assert.ok(second.options.every((opt) => !Object.prototype.hasOwnProperty.call(opt, 'number')),
  'options must be unnumbered; the Arbiter assigns numbers');

// The needs_author_choice result is applied atomically: a durable pending
// action is persisted (status pending), and the Arbiter renders the committed
// interaction off the committed snapshot. The options carry Arbiter-assigned
// numbers 1..N, and the visible_response binding matches the committed task.
const outcome = engine.applyStageResult(root, reread.workflow_id, reread.state_version, second);
assert.ok(outcome.task.pending_action, 'a pending action must be persisted for the choice');
assert.equal(outcome.task.pending_action.status, 'pending');
assert.ok(outcome.visible_response, 'the Arbiter must render the committed interaction');
// The Arbiter assigns stable numbers 1..N to the committed options.
const committedOptions = outcome.task.pending_action.options;
assert.ok(Array.isArray(committedOptions) && committedOptions.length >= 2 && committedOptions.length <= 4,
  'committed pending_action must carry 2-4 options');
committedOptions.forEach((opt, index) => {
  assert.equal(Number(opt.number), index + 1, `option ${index} must carry Arbiter number ${index + 1}`);
});
// The rendered binding matches the committed task's identity and version.
const binding = outcome.visible_response.binding;
assert.equal(binding.workflow_id, outcome.task.workflow_id);
assert.equal(Number(binding.state_version), Number(outcome.task.state_version));
assert.equal(binding.pending_action_id, outcome.task.pending_action.id);
assert.equal(binding.visible_choice_hash, outcome.task.pending_action.visible_choice_hash);
// The durable task.json mirrors the committed pending action exactly.
const file = path.join(root, '追踪', 'workflow', 'tasks', 'wf-plan-choice', 'task.json');
const persisted = JSON.parse(fs.readFileSync(file, 'utf8'));
assert.deepEqual(persisted.pending_action, outcome.task.pending_action);

// Leaving the retry path clears retry_state: the needs_author_choice commit no
// longer carries the prior retry_state.
assert.ok(!outcome.task.retry_state, 'retry_state must be cleared once off the retryable path');
NODE
}

@test "V3 a different failure family resets retry_state count to 1" {
    node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const planning = require(path.join(repo, 'scripts/lib/short-production/planning.js'));

let task = engine.createTask(root, {
  workflow_id: 'wf-plan-reset',
  workflow_type: 'short_write',
  user_goal: '写短篇',
});
for (const stage of ['creative_entry', 'material_positioning']) {
  task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: 'advance', stage_id: stage,
  }).task;
}

// Produce a durable retry_state for a DIFFERENT family through the real engine:
// the test applies a retryable_internal result with an unrelated failure_family
// via engine.applyStageResult, which persists retry_state in task.json. The test
// does NOT inject retry_state or count, and does not mutate the store directly.
const priorFamily = 'unrelated_prior_family';
task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'retryable_internal', code: 'prior_check', stage_id: 'setting',
  failure_family: priorFamily,
}).task;
assert.equal(task.retry_state.failure_family, priorFamily);
assert.equal(Number(task.retry_state.count), 1);

// A NEW family failure must reset count to 1 and remain retryable_internal
// (not escalate to needs_author_choice), because the family differs. The setting
// body has no protagonist, so the planning service emits a character_contract
// family — distinct from the seeded prior family. The service reads the freshly
// reread task.
const reread = engine.readTask(root, task.workflow_id);
const stagedRel = `${task.task_dir}/artifacts/planning/setting/sa-diff/设定.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedRel), '# 设定\n\n无主角。\n');
const first = planning.finalizePlanningStage({
  projectRoot: root, task: reread, stageId: 'setting', stagedRel, apply: true,
});
assert.equal(first.kind, 'retryable_internal');
assert.notEqual(first.failure_family, priorFamily);

const outcome = engine.applyStageResult(root, reread.workflow_id, reread.state_version, first);
assert.equal(outcome.task.retry_state.failure_family, first.failure_family);
assert.equal(Number(outcome.task.retry_state.count), 1, 'a different family resets the count');
NODE
}
