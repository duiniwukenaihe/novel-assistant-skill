#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP_DIR="$(mktemp -d)"
  PROJECT="$TMP_DIR/book"
  mkdir -p "$PROJECT"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "V3 accepting a structural feedback plan enters the dedicated planning-patch stage before any Brief" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));

let task = store.createTaskRecord(root, {
  workflow_id: 'wf-feedback-planning-stage',
  workflow_type: 'short_write',
  current_stage: 'section_brief',
  current_section_index: 1,
  scope: '第1节',
  user_goal: '中性短篇规划反馈',
});
task = engine.submitAuthorFeedback(root, task.workflow_id, task.state_version, {
  text: '需要同时调整人物约束和第1节结构。',
}).task;
const feedbackId = String(task.pending_feedback.id || '');
const proposed = engine.proposeAuthorFeedbackPlan(root, task.workflow_id, task.state_version, {
  feedback_id: feedbackId,
  summary: '先同步设定与小节大纲，再重建第1节 Brief。',
  impact_level: 'structure',
  affected_sections: [1],
  evidence: ['当前人物约束与第1节事件链需要一起调整。'],
  proposed_changes: ['补足人物行动边界', '调整第1节因果链'],
  section_titles: [{ section_index: 1, title: '发现异常编号' }],
});
assert.match(proposed.visible_response.text, /第1节：发现异常编号/u,
  'a title-changing plan must expose the exact proposed title before acceptance');
engine.resolveAuthorInput(root, task.workflow_id, proposed.task.state_version, {
  ...proposed.visible_response.binding,
  choice: '1',
});
const accepted = engine.readTask(root, task.workflow_id);
assert.equal(accepted.current_stage, 'feedback_apply_patch', JSON.stringify(accepted));
assert.equal(accepted.stage_execution.stage_id, 'feedback_apply_patch');
assert.deepEqual(accepted.accepted_plan.projection_plan.planning_assets, ['设定.md', '小节大纲.md']);
assert.deepEqual(accepted.accepted_plan.section_titles, [{ section_index: 1, title: '发现异常编号' }]);
assert.equal(accepted.accepted_plan.projection_status, 'pending');
const contract = runner.describeCurrentStage({ projectRoot: root, workflowId: accepted.workflow_id });
assert.equal(contract.stage_id, 'feedback_apply_patch');
assert.equal(contract.write_set.includes('写作Brief_第001节.md'), false);
assert.deepEqual(contract.write_set.map(item => item.split('/').pop()).sort(), ['小节大纲.md', '设定.md']);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 feedback planning patch rejects a partial staged asset set without changing canonical assets" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { finalizeFeedbackPlanningPatch } = require(path.join(repo, 'scripts/lib/short-production/feedback-planning.js'));

const digest = (file) => `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
fs.writeFileSync(path.join(root, '设定.md'), '# 设定\n\n原始人物约束。\n');
fs.writeFileSync(path.join(root, '小节大纲.md'), '# 小节大纲\n\n## 第1节：原始事件\n');
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-feedback-partial-assets',
  workflow_type: 'short_write',
  current_stage: 'feedback_apply_patch',
  user_goal: '中性规划回写',
  accepted_plan: {
    plan_id: 'accepted-plan.partial',
    feedback_id: 'fb-partial',
    impact_level: 'structure',
    affected_sections: [1],
    projection_status: 'pending',
    projection_plan: {
      planning_assets: ['设定.md', '小节大纲.md'],
      source_before: [
        { path: '设定.md', sha256: digest(path.join(root, '设定.md')) },
        { path: '小节大纲.md', sha256: digest(path.join(root, '小节大纲.md')) },
      ],
    },
  },
});
const settingCandidate = `${task.task_dir}/artifacts/planning/feedback_apply_patch/setting.md`;
const candidateFile = path.join(root, settingCandidate);
fs.mkdirSync(path.dirname(candidateFile), { recursive: true });
fs.writeFileSync(candidateFile, '# 设定\n\n候选人物约束。\n');
const beforeSetting = fs.readFileSync(path.join(root, '设定.md'));
const beforeOutline = fs.readFileSync(path.join(root, '小节大纲.md'));
const beforeTask = fs.readFileSync(path.join(root, task.task_dir, 'task.json'));
const result = finalizeFeedbackPlanningPatch({
  projectRoot: root,
  task,
  stagedAssets: [{ canonical: '设定.md', staged: settingCandidate }],
});
assert.equal(result.kind, 'blocked', JSON.stringify(result));
assert.equal(result.code, 'planning_asset_set_incomplete', JSON.stringify(result));
assert.deepEqual(result.missing_assets, ['小节大纲.md']);
assert.deepEqual(fs.readFileSync(path.join(root, '设定.md')), beforeSetting);
assert.deepEqual(fs.readFileSync(path.join(root, '小节大纲.md')), beforeOutline);
assert.deepEqual(fs.readFileSync(path.join(root, task.task_dir, 'task.json')), beforeTask);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 feedback planning patch refuses a stale confirmed source before it evaluates or writes candidates" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { finalizeFeedbackPlanningPatch } = require(path.join(repo, 'scripts/lib/short-production/feedback-planning.js'));
const digest = (file) => `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
fs.writeFileSync(path.join(root, '设定.md'), '# 设定\n\n确认前版本。\n');
fs.writeFileSync(path.join(root, '小节大纲.md'), '# 小节大纲\n\n## 第1节：确认前版本\n');
const before = { setting: digest(path.join(root, '设定.md')), outline: digest(path.join(root, '小节大纲.md')) };
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-feedback-stale-source', workflow_type: 'short_write', current_stage: 'feedback_apply_patch',
  accepted_plan: {
    plan_id: 'accepted-plan.stale', feedback_id: 'fb-stale', impact_level: 'structure', affected_sections: [1], projection_status: 'pending',
    projection_plan: { planning_assets: ['设定.md', '小节大纲.md'], source_before: [
      { path: '设定.md', sha256: before.setting }, { path: '小节大纲.md', sha256: before.outline },
    ] },
  },
});
fs.writeFileSync(path.join(root, '设定.md'), '# 设定\n\n外部更新后的版本。\n');
const changedCanonical = fs.readFileSync(path.join(root, '设定.md'));
const base = `${task.task_dir}/artifacts/planning/feedback_apply_patch/stale`;
fs.mkdirSync(path.join(root, base), { recursive: true });
fs.writeFileSync(path.join(root, `${base}/设定.md`), '# 设定\n\n候选版本。\n');
fs.writeFileSync(path.join(root, `${base}/小节大纲.md`), '# 小节大纲\n\n## 第1节：候选版本\n');
const result = finalizeFeedbackPlanningPatch({
  projectRoot: root, task,
  stagedAssets: [{ canonical: '设定.md', staged: `${base}/设定.md` }, { canonical: '小节大纲.md', staged: `${base}/小节大纲.md` }],
});
assert.equal(result.kind, 'blocked', JSON.stringify(result));
assert.equal(result.code, 'planning_asset_source_stale', JSON.stringify(result));
assert.deepEqual(result.stale_assets, ['设定.md']);
assert.deepEqual(fs.readFileSync(path.join(root, '设定.md')), changedCanonical);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 feedback planning patch commits every structural asset in one accepted transaction before leaving the patch stage" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { finalizeFeedbackPlanningPatch } = require(path.join(repo, 'scripts/lib/short-production/feedback-planning.js'));
const digest = (file) => `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;

const setting = `# 设定

作品名：中性事务短篇
叙事方式：第一人称。
目标长度：共2节。
主节奏：发现异常 -> 公开复核。

## 主要人物

### 林舟，26岁，档案校对员
第一人称“我”。目标是查清重复档案编号；软肋是害怕同事被牵连；误信只要加班就能补齐错误。她不懂系统底层逻辑。最终选择是亲自提交补丁并接受公开复核。

### 周主管，42岁，部门主管
他要保住季度交付和团队稳定，认为压下问题能争取修复时间；拥有审批权限，但不能无成本甩锅给执行人。

## 角色锁定卡
| 角色名 | 性别/称谓/视角身份 | 年龄/职业 | 与主角关系 | 本篇目标 | 行动边界 |
|---|---|---|---|---|---|
| 林舟 | 女，第一人称“我” | 26岁，校对员 | 部门成员 | 查清编号错误 | 不擅自删除历史记录 |
| 周主管 | 男，称“主管” | 42岁，主管 | 主管/压力角色 | 保住交付 | 不调用外部关系 |

## 人物关系与责任债
- 林舟欠主管一次通融；主管欠林舟一次公开的真相。
`;
const outline = `# 小节大纲

核心路线：发现编号错误，再用公开补丁恢复档案可信度。

## 第1节：发现重复编号
- 结构功能：黄金开篇，兑现标题画面
- 情绪目标：疑惑到警觉
- 因果链：扫描报告跳错，林舟拒绝关停并追查
- 场景动作：林舟移动光标，当面拒绝主管撤回
- 主角选择：她选择保留扫描回放
- 子事件：
  1. 林舟扫描时看见编号重复出现
  2. 主管逼她撤回，她拒绝并公开追问
- 节尾钩子：主管承认编号源自旧批次

## 第2节：恢复正确编号
- 结构功能：结尾收束责任与档案承诺
- 情绪目标：压力升高到责任落地
- 因果链：承接主管承认旧批次，林舟推动补丁和复核
- 承接上节：主管承认编号源自旧批次
- 场景动作：林舟在评审会提交补丁和复核方案
- 主角选择：她选择提交补丁并公开新编号
- 子事件：
  1. 林舟提交补丁并暂停主管审批
  2. 她启动新编号入档复核，承担延期
- 现实后果：旧号回滚，主管停权，排期承压
- 关系收束：林舟与主管保持裂痕，不用情面替责任结账
- 结尾回扣：编号终于可追溯，读者可以自行核验
- 节尾钩子：新编号接受长期公开复核
`;
fs.mkdirSync(path.join(root, '追踪/story-system'), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/story-system/write-policy.json'), '{"schemaVersion":"1.0.0","mode":"strict"}\n');
fs.writeFileSync(path.join(root, '设定.md'), `${setting}\n旧版本标记。\n`);
fs.writeFileSync(path.join(root, '小节大纲.md'), `${outline}\n旧版本标记。\n`);
const beforeSetting = digest(path.join(root, '设定.md'));
const beforeOutline = digest(path.join(root, '小节大纲.md'));
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-feedback-atomic-assets',
  workflow_type: 'short_write',
  current_stage: 'feedback_apply_patch',
  current_section_index: 1,
  scope: '第1节',
  user_goal: '中性规划回写',
  pending_feedback: { id: 'fb-atomic', status: 'accepted', accepted_plan: { feedback_id: 'fb-atomic' } },
  accepted_plan: {
    plan_id: 'accepted-plan.atomic', feedback_id: 'fb-atomic', impact_level: 'structure',
    affected_sections: [1], projection_status: 'pending',
    requirements: [{ requirement_id: 'atomic-1', text: '人物约束与事件链一起回写。', impact_level: 'structure' }],
    projection_plan: {
      planning_assets: ['设定.md', '小节大纲.md'],
      source_before: [{ path: '设定.md', sha256: beforeSetting }, { path: '小节大纲.md', sha256: beforeOutline }],
      invalidate_briefs: ['写作Brief_第001节.md'], recheck_prose: ['正文/第001节.md'],
    },
  },
});
const base = `${task.task_dir}/artifacts/planning/feedback_apply_patch/${task.stage_execution.stage_attempt_id}`;
const settingStaged = `${base}/设定.md`;
const outlineStaged = `${base}/小节大纲.md`;
fs.mkdirSync(path.dirname(path.join(root, settingStaged)), { recursive: true });
fs.writeFileSync(path.join(root, settingStaged), setting);
fs.writeFileSync(path.join(root, outlineStaged), outline);
const result = finalizeFeedbackPlanningPatch({
  projectRoot: root, task,
  stagedAssets: [{ canonical: '设定.md', staged: settingStaged }, { canonical: '小节大纲.md', staged: outlineStaged }],
});
assert.equal(result.kind, 'completed', JSON.stringify(result));
assert.equal(result.code, 'short_feedback_planning_patch_accepted');
assert.equal(result.planning_transaction.artifacts.length, 2);
assert.deepEqual(result.planning_transaction.artifacts.map(item => item.canonical), ['小节大纲.md', '设定.md']);
assert.equal(fs.readFileSync(path.join(root, '设定.md'), 'utf8'), setting);
assert.equal(fs.readFileSync(path.join(root, '小节大纲.md'), 'utf8'), outline);
assert.notEqual(digest(path.join(root, '设定.md')), beforeSetting);
assert.notEqual(digest(path.join(root, '小节大纲.md')), beforeOutline);

// A regenerated outline is not allowed to rename user-confirmed section
// titles invisibly. The candidate is rejected before its transaction begins,
// leaving the canonical outline byte-for-byte intact.
const state = JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/short/project-state.json'), 'utf8'));
const lockFile = path.join(root, '追踪/story-system/short/section-title-lock.json');
fs.writeFileSync(lockFile, `${JSON.stringify({
  schema_version: '1.0.0', status: 'confirmed', workflow_id: task.workflow_id,
  project_id: state.project_id, plan_revision: state.plan_revision, planned_sections: 2,
  source_outline: '小节大纲.md', source_digest: digest(path.join(root, '小节大纲.md')).replace(/^sha256:/, ''),
  sections: [
    { section_index: 1, title: '发现重复编号', confirmed: true },
    { section_index: 2, title: '恢复正确编号', confirmed: true },
  ],
}, null, 2)}\n`);
const beforeTitleChange = fs.readFileSync(path.join(root, '小节大纲.md'));
const titleTask = store.createTaskRecord(root, {
  workflow_id: 'wf-feedback-title-change', workflow_type: 'short_write',
  current_stage: 'feedback_apply_patch', current_section_index: 1, user_goal: '中性标题变更',
  accepted_plan: {
    plan_id: 'accepted-plan.title-change', feedback_id: 'fb-title-change', impact_level: 'planning',
    affected_sections: [1], projection_status: 'pending',
    projection_plan: { planning_assets: ['小节大纲.md'], source_before: [{ path: '小节大纲.md', sha256: digest(path.join(root, '小节大纲.md')) }] },
  },
});
const titleCandidate = `${titleTask.task_dir}/artifacts/planning/feedback_apply_patch/title-change/小节大纲.md`;
fs.mkdirSync(path.dirname(path.join(root, titleCandidate)), { recursive: true });
fs.writeFileSync(path.join(root, titleCandidate), outline.replace('发现重复编号', '发现编号冲突'));
const titleResult = finalizeFeedbackPlanningPatch({
  projectRoot: root, task: titleTask,
  stagedAssets: [{ canonical: '小节大纲.md', staged: titleCandidate }],
});
assert.equal(titleResult.kind, 'blocked', JSON.stringify(titleResult));
assert.equal(titleResult.code, 'feedback_title_confirmation_required', JSON.stringify(titleResult));
assert.deepEqual(fs.readFileSync(path.join(root, '小节大纲.md')), beforeTitleChange);

const titleAcceptedTask = store.commitTask(root, task.workflow_id, task.state_version, (draft) => {
  draft.current_stage = 'feedback_apply_patch';
  draft.current_section_index = 1;
  draft.scope = '第1节';
  draft.stage_execution = {
    status: 'running', stage_id: 'feedback_apply_patch',
    stage_attempt_id: store.createStageAttemptId(draft.workflow_id, 'feedback_apply_patch'), section_index: 1,
  };
  draft.accepted_plan = {
    ...titleTask.accepted_plan,
    plan_id: 'accepted-plan.title-change-confirmed',
    section_titles: [
      { section_index: 1, title: '发现编号冲突' },
      { section_index: 2, title: '恢复正确编号' },
    ],
  };
  return draft;
});
const acceptedTitleCandidate = `${titleAcceptedTask.task_dir}/artifacts/planning/feedback_apply_patch/title-change-confirmed/小节大纲.md`;
fs.mkdirSync(path.dirname(path.join(root, acceptedTitleCandidate)), { recursive: true });
fs.writeFileSync(path.join(root, acceptedTitleCandidate), outline.replace('发现重复编号', '发现编号冲突'));
const acceptedTitleResult = finalizeFeedbackPlanningPatch({
  projectRoot: root, task: titleAcceptedTask,
  stagedAssets: [{ canonical: '小节大纲.md', staged: acceptedTitleCandidate }],
});
assert.equal(acceptedTitleResult.kind, 'completed', JSON.stringify(acceptedTitleResult));
const titleChangedLock = JSON.parse(fs.readFileSync(lockFile, 'utf8'));
assert.equal(titleChangedLock.sections[0].title, '发现编号冲突');
assert.equal(titleChangedLock.confirmation_basis, 'feedback_plan_title_confirmation');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
