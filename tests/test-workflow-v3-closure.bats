#!/usr/bin/env bats

# Task 7: V3 whole-story closure. The shared service returns StageResult only;
# the Engine is the sole task.json writer and the Arbiter is the sole menu
# renderer. Fixtures are synthetic and project-neutral.

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  TMP_DIR="$(mktemp -d)"
  PROJECT="$TMP_DIR/book"
  mkdir -p "$PROJECT/追踪/story-system/short"
  printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$PROJECT/追踪/story-system/write-policy.json"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "V3 current-stage contracts cover every whole-story closure stage" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));

for (const stage of ['assembly', 'editorial_review', 'deslop', 'final_check']) {
  const workflowId = `wf-contract-${stage}`;
  const task = store.createTaskRecord(root, {
    workflow_id: workflowId, workflow_type: 'short_write', current_stage: stage,
    user_goal: '验证全篇收束恢复合约',
  });
  const contract = runner.describeCurrentStage({ projectRoot: root, workflowId });
  assert.equal(contract.stage_id, stage);
  assert.equal(contract.state_version, task.state_version);
  assert.match(contract.stage_completion_command, /run-current-stage/u);
  if (stage === 'assembly' || stage === 'final_check') {
    assert.deepEqual(contract.write_set, []);
  }
  if (stage === 'editorial_review') {
    assert.equal(contract.current_required_action, 'prepare_evidence_then_write');
    assert.equal(contract.write_set.length, 2);
    assert.ok(contract.write_set.some((item) => /reader-response\.json$/u.test(item)));
    assert.ok(contract.write_set.some((item) => /editorial-review\.json$/u.test(item)));
    assert.deepEqual(contract.source_files, ['正文.md']);
  }
  if (stage === 'deslop') {
    assert.equal(contract.write_set.length, 1);
    assert.match(contract.write_set[0], /正文-精修候选\.md$/u);
    assert.deepEqual(contract.source_files, ['正文.md']);
  }
}
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 assembly commits exactly the locked accepted sections and advances through Engine" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const closure = require(path.join(repo, 'scripts/lib/short-production/closure.js'));
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { commitAcceptedSection } = require(path.join(repo, 'scripts/lib/short-section-commit-store.js'));
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));
const stateRoot = path.join(root, '追踪/story-system/short');

let task = store.createTaskRecord(root, {
  workflow_id: 'wf-closure-normal', workflow_type: 'short_write',
  current_stage: 'assembly', user_goal: '完成两节中性短篇',
});
const accepted = [];
for (const section of [
  { index: 1, title: '发现记录差异', body: '我核对两份记录，发现同一编号对应不同日期。负责人要求我先别公开，我保留了核验清单。' },
  { index: 2, title: '完成公开复核', body: '我在复核会上提交更正记录，承担延期责任。负责人接受复核，编号恢复为可追溯状态。' },
]) {
  const commit = commitAcceptedSection(root, {
    task, sectionIndex: section.index, title: section.title, text: section.body,
    metadata: {}, projectTitle: '中性测试短篇',
  });
  const anchorRel = `追踪/story-system/short/section-${String(section.index).padStart(3, '0')}-anchor.json`;
  atomicWriteJson(path.join(root, anchorRel), {
    workflow_id: task.workflow_id, section_index: section.index, status: 'accepted',
    canonical_path: commit.canonical_path, canonical_sha256: commit.canonical_sha256,
    section_commit_id: commit.commit_id,
    quality_result: {
      machine_gate: 'pass', story_value_gate: 'pass', repetition_gate: 'pass',
      length_policy: { verdict: 'within_story_band', blocking: false },
    },
  });
  accepted.push({
    section_index: section.index, title: section.title, anchor_path: anchorRel,
    canonical_path: commit.canonical_path, sha256: commit.canonical_sha256,
    section_commit_id: commit.commit_id,
  });
}
atomicWriteJson(path.join(stateRoot, 'project-state.json'), {
  schema_version: '2.0.0', project_id: 'neutral-closure', project_title: '中性测试短篇',
  active_write_workflow_id: task.workflow_id, planned_sections: 2,
  narrative: { planned_sections: 2 }, accepted_sections: accepted,
});
atomicWriteJson(path.join(stateRoot, 'section-title-lock.json'), {
  planned_sections: 2,
  sections: [{ section_index: 1 }, { section_index: 2 }],
});
fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：发现记录差异\n## 第2节：完成公开复核\n');

const result = closure.assembleStory({ projectRoot: root, task });
assert.equal(result.kind, 'completed', JSON.stringify(result));
assert.equal(result.stage_id, 'assembly');
assert.equal(result.planned_sections, 2);
assert.equal(result.assembled_sections, 2);
assert.ok(!Object.prototype.hasOwnProperty.call(result, 'visible_response'));
const storyFile = path.join(root, '正文.md');
assert.ok(fs.existsSync(storyFile));
const actualHash = crypto.createHash('sha256').update(fs.readFileSync(storyFile)).digest('hex');
assert.equal(result.canonical_sha256, actualHash);
const storyBytes = fs.readFileSync(storyFile);
const repeated = closure.assembleStory({ projectRoot: root, task });
assert.equal(repeated.kind, 'completed');
assert.equal(repeated.assembly_commit_id, result.assembly_commit_id, 'identical retry must reuse the accepted transaction');
assert.deepEqual(fs.readFileSync(storyFile), storyBytes, 'identical retry must be byte-idempotent');

const beforeVersion = task.state_version;
task = engine.applyStageResult(root, task.workflow_id, task.state_version, result).task;
assert.equal(task.current_stage, 'editorial_review');
assert.equal(task.state_version, beforeVersion + 1, 'Engine must perform the only task commit');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 missing section creates one Arbiter menu and never modifies the assembled story" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const closure = require(path.join(repo, 'scripts/lib/short-production/closure.js'));
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { commitAcceptedSection } = require(path.join(repo, 'scripts/lib/short-section-commit-store.js'));
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));
const stateRoot = path.join(root, '追踪/story-system/short');
let task = store.createTaskRecord(root, {
  workflow_id: 'wf-closure-missing', workflow_type: 'short_write',
  current_stage: 'assembly', user_goal: '验证缺节恢复',
});
const commit = commitAcceptedSection(root, {
  task, sectionIndex: 1, title: '保留记录', text: '我保留第一份核验记录，等待下一步复核。',
  metadata: {}, projectTitle: '中性测试短篇',
});
const anchorRel = '追踪/story-system/short/section-001-anchor.json';
atomicWriteJson(path.join(root, anchorRel), {
  workflow_id: task.workflow_id, section_index: 1, status: 'accepted',
  canonical_path: commit.canonical_path, canonical_sha256: commit.canonical_sha256,
  section_commit_id: commit.commit_id,
  quality_result: {
    machine_gate: 'pass', story_value_gate: 'pass', repetition_gate: 'pass',
    length_policy: { verdict: 'within_story_band', blocking: false },
  },
});
atomicWriteJson(path.join(stateRoot, 'project-state.json'), {
  schema_version: '2.0.0', project_id: 'neutral-missing', project_title: '中性测试短篇',
  active_write_workflow_id: task.workflow_id, planned_sections: 2,
  narrative: { planned_sections: 2 },
  accepted_sections: [{ section_index: 1, anchor_path: anchorRel, canonical_path: commit.canonical_path, sha256: commit.canonical_sha256, section_commit_id: commit.commit_id }],
});
atomicWriteJson(path.join(stateRoot, 'section-title-lock.json'), {
  planned_sections: 2, sections: [{ section_index: 1 }, { section_index: 2 }],
});
fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：保留记录\n## 第2节：完成复核\n');
const storyFile = path.join(root, '正文.md');
const sentinel = '已有合稿不得被缺节恢复覆盖。\n';
fs.writeFileSync(storyFile, sentinel);
const beforeHash = crypto.createHash('sha256').update(fs.readFileSync(storyFile)).digest('hex');

const result = closure.assembleStory({ projectRoot: root, task });
assert.equal(result.kind, 'needs_author_choice', JSON.stringify(result));
assert.equal(result.stage_id, 'assembly');
assert.deepEqual(result.missing_sections, [2]);
assert.ok(!Object.prototype.hasOwnProperty.call(result, 'visible_response'));
assert.ok(result.options.length >= 2 && result.options.length <= 4);
assert.ok(result.options.every((option) => !Object.prototype.hasOwnProperty.call(option, 'number')));
assert.equal(fs.readFileSync(storyFile, 'utf8'), sentinel);
assert.equal(crypto.createHash('sha256').update(fs.readFileSync(storyFile)).digest('hex'), beforeHash);
assert.ok(!fs.existsSync(path.join(root, task.task_dir, 'artifacts/closure/assembly/正文.md')),
  'blocked assembly must not even write a staged whole-story body');

// A changed canonical body is an invalid accepted proof and must still leave
// the existing whole-story file untouched.
const canonicalOne = path.join(root, commit.canonical_path);
const canonicalBytes = fs.readFileSync(canonicalOne);
fs.appendFileSync(canonicalOne, '未验收改动\n');
const invalid = closure.assembleStory({ projectRoot: root, task });
assert.equal(invalid.kind, 'needs_author_choice');
assert.equal(invalid.invalid_sections[0].section_index, 1);
assert.equal(invalid.invalid_sections[0].reason, 'short_section_canonical_sha256_mismatch');
assert.equal(fs.readFileSync(storyFile, 'utf8'), sentinel);
fs.writeFileSync(canonicalOne, canonicalBytes);

// An accepted section outside the locked plan is surfaced in the same single
// recovery interaction; it never causes implicit plan expansion or assembly.
const outsideCommit = commitAcceptedSection(root, {
  task, sectionIndex: 3, title: '计划外记录', text: '这份记录不属于已锁定的两节范围。',
  metadata: {}, projectTitle: '中性测试短篇',
});
const outsideAnchorRel = '追踪/story-system/short/section-003-anchor.json';
atomicWriteJson(path.join(root, outsideAnchorRel), {
  workflow_id: task.workflow_id, section_index: 3, status: 'accepted',
  canonical_path: outsideCommit.canonical_path, canonical_sha256: outsideCommit.canonical_sha256,
  section_commit_id: outsideCommit.commit_id,
  quality_result: {
    machine_gate: 'pass', story_value_gate: 'pass', repetition_gate: 'pass',
    length_policy: { verdict: 'within_story_band', blocking: false },
  },
});
const stateFile = path.join(stateRoot, 'project-state.json');
const expandedState = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
expandedState.accepted_sections.push({ section_index: 3, anchor_path: outsideAnchorRel, canonical_path: outsideCommit.canonical_path, sha256: outsideCommit.canonical_sha256, section_commit_id: outsideCommit.commit_id });
atomicWriteJson(stateFile, expandedState);
const outside = closure.assembleStory({ projectRoot: root, task });
assert.equal(outside.kind, 'needs_author_choice');
assert.deepEqual(outside.missing_sections, [2]);
assert.deepEqual(outside.outside_plan_sections, [3]);
assert.equal(fs.readFileSync(storyFile, 'utf8'), sentinel);

const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, outside);
assert.equal(outcome.task.current_stage, 'assembly');
assert.equal(outcome.task.pending_action.status, 'pending');
assert.ok(outcome.visible_response && /^.+\n1\. /u.test(outcome.visible_response.text));
assert.equal((outcome.visible_response.text.match(/\n\d+\. /gu) || []).length, result.options.length);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 accepted-prose drift choice starts a durable revalidation queue instead of repeating assembly" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const closure = require(path.join(repo, 'scripts/lib/short-production/closure.js'));
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { commitAcceptedSection } = require(path.join(repo, 'scripts/lib/short-section-commit-store.js'));
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));
const stateRoot = path.join(root, '追踪/story-system/short');

let task = store.createTaskRecord(root, {
  workflow_id: 'wf-closure-drift', workflow_type: 'short_write',
  current_stage: 'assembly', user_goal: '验证旧项目正文漂移恢复',
});
const accepted = [];
for (const section of [
  { index: 1, title: '发现差异', body: '阿岚核对编号，保留了第一份原始记录。' },
  { index: 2, title: '公开复核', body: '阿岚提交更正，主管接受公开复核。' },
]) {
  const commit = commitAcceptedSection(root, {
    task, sectionIndex: section.index, title: section.title, text: section.body,
    metadata: {}, projectTitle: '中性测试短篇',
  });
  const anchorRel = `追踪/story-system/short/section-${String(section.index).padStart(3, '0')}-anchor.json`;
  atomicWriteJson(path.join(root, anchorRel), {
    workflow_id: task.workflow_id, section_index: section.index, status: 'accepted',
    canonical_path: commit.canonical_path, canonical_sha256: commit.canonical_sha256,
    section_commit_id: commit.commit_id,
    quality_result: {
      machine_gate: 'pass', story_value_gate: 'pass', repetition_gate: 'pass',
      length_policy: { verdict: 'within_story_band', blocking: false },
    },
  });
  accepted.push({
    section_index: section.index, title: section.title, anchor_path: anchorRel,
    canonical_path: commit.canonical_path, sha256: commit.canonical_sha256,
    section_commit_id: commit.commit_id,
  });
}
atomicWriteJson(path.join(stateRoot, 'project-state.json'), {
  schema_version: '2.0.0', project_id: 'neutral-drift', project_title: '中性测试短篇',
  planned_sections: 2, narrative: { planned_sections: 2 }, accepted_sections: accepted,
});
atomicWriteJson(path.join(stateRoot, 'section-title-lock.json'), {
  planned_sections: 2,
  sections: [
    { section_index: 1, title: '发现差异' },
    { section_index: 2, title: '公开复核' },
  ],
});
fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：发现差异\n## 第2节：公开复核\n');
const currentBodies = new Map([
  [1, '## 第001节 发现差异\n\n阿岚补入新的核验时间，并保留原始编号。\n'],
  [2, '## 第002节 公开复核\n\n阿岚公开更正，主管承担延期并开放查询。\n'],
]);
for (const [index, body] of currentBodies) {
  fs.writeFileSync(path.join(root, `正文/第${String(index).padStart(3, '0')}节.md`), body);
}

const blocked = closure.assembleStory({ projectRoot: root, task });
assert.equal(blocked.kind, 'needs_author_choice', JSON.stringify(blocked));
assert.deepEqual(blocked.invalid_sections.map((item) => item.section_index), [1, 2]);
assert.equal(blocked.options[0].action_id, 'revalidate_current_sections');
assert.match(blocked.options[0].label, /保留现稿/u);
let applied = engine.applyStageResult(root, task.workflow_id, task.state_version, blocked);
task = applied.task;
const binding = applied.visible_response.binding;
engine.resolveAuthorInput(root, task.workflow_id, task.state_version, { ...binding, choice: 1 });
task = engine.readTask(root, task.workflow_id);
assert.equal(task.pending_action.status, 'resolved');
assert.equal(task.pending_action.selection.action_id, 'revalidate_current_sections');

const recovery = closure.assembleStory({ projectRoot: root, task });
assert.equal(recovery.kind, 'completed', JSON.stringify(recovery));
assert.equal(recovery.code, 'short_story_assembly_revalidation_started');
assert.equal(recovery.next_stage, 'machine_gate');
assert.equal(recovery.section_index, 1);
for (const [index, body] of currentBodies) {
  assert.equal(fs.readFileSync(path.join(root, `草稿_第${String(index).padStart(3, '0')}节_候选.md`), 'utf8'), body);
}

task = engine.applyStageResult(root, task.workflow_id, task.state_version, recovery).task;
assert.equal(task.current_stage, 'machine_gate');
assert.equal(task.stage_execution.section_index, 1);
assert.equal(task.feedback_revision_queue.status, 'running');
assert.equal(task.feedback_revision_queue.source_stage, 'full_story_assembly');
assert.deepEqual(task.feedback_revision_queue.affected_sections, [1, 2]);
assert.equal(task.feedback_revision_queue.current_section_index, 1);
const contract = runner.describeCurrentStage({ projectRoot: root, workflowId: task.workflow_id });
assert.deepEqual(contract.source_files, ['草稿_第001节_候选.md']);
assert.match(contract.resume_hint, /重新验收/u);
task = store.commitTask(root, task.workflow_id, task.state_version, (draft) => ({
  ...draft,
  pending_feedback: {
    status: 'applied', section_index: 9,
    accepted_plan: { summary: '第9节的旧方案不得污染第1节复验。', affected_sections: [9] },
  },
}));
task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'short_machine_gate_passed', stage_id: 'machine_gate',
  section_index: 1, next_stage: 'story_gate',
}).task;
const storyContract = runner.describeCurrentStage({ projectRoot: root, workflowId: task.workflow_id });
assert.match(storyContract.resume_hint, /重新验收第1节/u);
assert.doesNotMatch(storyContract.resume_hint, /第9节的旧方案/u);
assert.equal(storyContract.accepted_feedback_plan, null,
  'an applied plan for another section must not be projected into the current contract');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 closure retries one mechanical failure then stops with one durable author choice" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const closure = require(path.join(repo, 'scripts/lib/short-production/closure.js'));
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));
fs.writeFileSync(path.join(root, '正文.md'), '## 第001节 核验\n\n阿岚保留了核验记录。\n');
fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：核验\n');
atomicWriteJson(path.join(root, '追踪/story-system/short/project-state.json'), {
  project_id: 'neutral-retry', planned_sections: 1, narrative: { planned_sections: 1 }, accepted_sections: [],
});
let task = store.createTaskRecord(root, {
  workflow_id: 'wf-closure-retry', workflow_type: 'short_write', current_stage: 'final_check', user_goal: '验证停止循环',
});
const first = closure.runFinalCheck({ projectRoot: root, task });
assert.equal(first.kind, 'retryable_internal', JSON.stringify(first));
assert.equal(first.failure_family, 'final_check_receipts');
task = engine.applyStageResult(root, task.workflow_id, task.state_version, first).task;
assert.equal(task.retry_state.count, 1);
const second = closure.runFinalCheck({ projectRoot: root, task });
assert.equal(second.kind, 'needs_author_choice', JSON.stringify(second));
assert.ok(second.options.every((option) => !Object.prototype.hasOwnProperty.call(option, 'number')));
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, second);
assert.equal(outcome.task.current_stage, 'final_check');
assert.equal(outcome.task.pending_action.status, 'pending');
assert.equal(outcome.visible_response.text.split('\n').filter((line) => /^\d+\. /u.test(line)).length, 3);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 editorial review sends pass to deslop and revise to a durable author-confirmed repair plan" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, base] = process.argv.slice(2);
const closure = require(path.join(repo, 'scripts/lib/short-production/closure.js'));
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));

function seed(root, id, decision, requireLengthDecision = false) {
  fs.mkdirSync(path.join(root, '追踪/story-system'), { recursive: true });
  fs.writeFileSync(path.join(root, '追踪/story-system/write-policy.json'), '{"schemaVersion":"1.0.0","mode":"strict"}\n');
  const first = '阿岚把编号记录投到屏幕上。主管让她撤回，阿岚拒绝签字。';
  const second = '阿岚提交更正方案并承担延期。主管接受停权，编号恢复公开复核。';
  fs.writeFileSync(path.join(root, '正文.md'), `## 第001节 发现差异\n\n${first}\n\n## 第002节 完成复核\n\n${second}\n`);
  fs.writeFileSync(path.join(root, '设定.md'), '## 阿岚\n她要完成公开复核。\n\n## 主管\n他要保住交付。\n');
  fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：发现差异\n## 第2节：完成复核\n');
  let task = store.createTaskRecord(root, {
    workflow_id: id, workflow_type: 'short_write', current_stage: 'editorial_review', user_goal: '验证全篇审阅',
  });
  task = store.commitTask(root, id, task.state_version, (draft) => ({
    ...draft,
    short_full_story_review: {
      decision: decision === 'pass' ? 'revise' : 'pass',
      visible_verdict: 'stale',
      visible_label: '旧裁决不得残留',
      story_sha256: 'stale-story-digest',
    },
    short_full_story_review_projection: { status: 'stale_projection' },
  }));
  const required = closure.finalizeEditorialReview({ projectRoot: root, task });
  assert.equal(required.kind, 'blocked');
  assert.equal(required.code, 'short_story_reader_response_required');
  const reader = {
    reader_profile: { target_platform: '未确认', platform_mode: 'general_fiction', genre_lens: ['责任选择'], style_lens: ['restrained_realism'], reading_scene: 'mobile_continuous', profile_basis: '用户未指定，使用通用画像' },
    section_reader_response: [
      { section_index: 1, engagement: 'engaged', felt_emotion: '关注核验结果', reader_question: '她会不会公开', evidence_quote: first },
      { section_index: 2, engagement: 'engaged', felt_emotion: '责任得到落实', reader_question: '复核能否持续', evidence_quote: second },
    ],
    drop_off_points: [],
    character_impressions: [{ character: '阿岚', first_impression: '谨慎', later_impression: '愿意承担', trust_change: 'up', evidence_quotes: [first, second] }],
    identity_continuity: [], identity_continuity_not_applicable_reason: '设定没有额外职业或能力承诺。',
    supporting_character_reality: [{ character: '主管', felt_status: 'alive', apparent_want: '保住交付', decisive_choice: '接受停权', relationship_effect: '失去控制权', evidence_quotes: [first, second] }],
    reveal_aftershock: [], reveal_aftershock_not_applicable_reason: '两节故事没有独立的中段揭示。',
    promise_response: { title_expectation: '看到差异如何被复核', payoff_status: 'fulfilled', evidence_quotes: [second], reader_aftertaste: '责任清楚' },
    final_reader_state: { would_continue_or_recommend: 'yes', strongest_pull: '具体选择', biggest_resistance: '篇幅较短' },
  };
  fs.mkdirSync(path.dirname(path.join(root, required.reader_response_card)), { recursive: true });
  fs.writeFileSync(path.join(root, required.reader_response_card), JSON.stringify(reader, null, 2));
  const editorRequired = closure.finalizeEditorialReview({ projectRoot: root, task });
  assert.equal(editorRequired.kind, 'blocked');
  assert.equal(editorRequired.code, 'short_story_editorial_review_required');
  const pack = JSON.parse(fs.readFileSync(path.join(root, editorRequired.evidence_pack), 'utf8'));
  const finding = { code: 'EndingCost', severity: 'S3', scope: '第2节', evidence_quote: second, repair_direction: '补足责任余波后重新确认。' };
  const card = {
    schemaVersion: '1.0.0', workflow_id: id, story_sha256: pack.story_sha256, decision,
    summary: decision === 'pass' ? '故事可进入表达精修。' : '结尾余波需要作者确认。',
    opening_assessment: { verdict: 'pass', evidence_quote: first, reason: '直接进入核验冲突。' },
    section_function_matrix: [
      { section_index: 1, structural_role: '建立差异与选择', function_verdict: 'pass', evidence_quote: first, note: '功能完成' },
      { section_index: 2, structural_role: '落实责任与复核', function_verdict: decision === 'pass' ? 'pass' : 'concern', evidence_quote: second, note: '功能可核验' },
    ],
    character_arc_matrix: [
      { character: '阿岚', desire: '公开复核', independent_stake: '承担延期', active_action: '提交更正方案', cost: '排期延后', relationship_effect: '与主管形成责任边界', change: '从核对转向公开承担', verdict: 'pass', evidence_quotes: [first, second] },
      { character: '主管', desire: '保住交付', independent_stake: '保住审批权', active_action: '要求撤回', cost: '接受停权', relationship_effect: '失去原有控制', change: '从压制到接受复核', verdict: 'pass', evidence_quotes: [first, second] },
    ],
    identity_payoff_matrix: [], identity_not_applicable_reason: '本故事没有独立职业能力承诺。',
    reveal_aftershock_matrix: [], reveal_aftershock_not_applicable_reason: '两节故事没有独立中段揭示。',
    climax_ending_assessment: { verdict: decision === 'pass' ? 'pass' : 'concern', climax_quote: second, ending_quote: second, reason: '更正与责任在结尾落地。' },
    findings: decision === 'pass' ? [] : [finding],
  };
  fs.writeFileSync(path.join(root, editorRequired.review_card), JSON.stringify(card, null, 2));
  if (requireLengthDecision) {
    fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：发现差异\n- 目标字数：1000字。\n## 第2节：完成复核\n- 目标字数：1000字。\n');
    const anchorDir = path.join(root, '追踪/story-system/short');
    fs.mkdirSync(anchorDir, { recursive: true });
    fs.mkdirSync(path.join(root, '正文'), { recursive: true });
    fs.writeFileSync(path.join(root, '正文/第001节.md'), `## 第001节 发现差异\n\n${first}\n`);
    fs.writeFileSync(path.join(anchorDir, 'section-001-anchor.json'), JSON.stringify({
      workflow_id: id,
      section_index: 1,
      quality_result: {
        length_policy: {
          verdict: 'outside_story_band_deferred',
          blocking: false,
          observed_chars: 500,
          baseline_chars: 1000,
        },
      },
    }, null, 2));
    fs.writeFileSync(path.join(anchorDir, 'project-state.json'), JSON.stringify({
      accepted_sections: [{
        section_index: 1,
        canonical_path: '正文/第001节.md',
        anchor_path: '追踪/story-system/short/section-001-anchor.json',
      }],
    }, null, 2));
    const automaticRepair = closure.finalizeEditorialReview({ projectRoot: root, task });
    assert.equal(automaticRepair.kind, 'completed', JSON.stringify(automaticRepair));
    assert.equal(automaticRepair.code, 'short_story_length_revision_required');
    assert.equal(automaticRepair.next_stage, 'machine_gate');
    assert.deepEqual(automaticRepair.length_findings.map((item) => item.section_index), [1]);
    assert.match(automaticRepair.length_findings[0].message, /第1节.*目标1000字.*缺口50\.0%/u);
    assert.ok(fs.existsSync(path.join(root, '草稿_第001节_候选.md')));
    const applied = engine.applyStageResult(root, id, task.state_version, automaticRepair);
    assert.equal(applied.task.current_stage, 'machine_gate');
    assert.equal(applied.task.feedback_revision_queue.source_stage, 'full_story_editorial_length');
    assert.equal(applied.task.feedback_revision_queue.current_section_index, 1);
    return applied.task;
  }
  const result = closure.finalizeEditorialReview({ projectRoot: root, task });
  assert.equal(result.kind, 'completed', JSON.stringify(result));
  assert.equal(result.decision, decision);
  assert.ok(!Object.prototype.hasOwnProperty.call(result, 'visible_response'));
  const outcome = engine.applyStageResult(root, id, task.state_version, result);
  assert.equal(outcome.task.current_stage, decision === 'pass' ? 'deslop' : 'editorial_review');
  assert.equal(outcome.task.short_full_story_review.decision, decision);
  assert.equal(outcome.task.short_full_story_review.story_sha256, pack.story_sha256);
  assert.equal(outcome.task.short_full_story_review.review_card_path, result.review_card_path);
  assert.equal(outcome.task.short_full_story_review.visible_label,
    decision === 'pass' ? '故事层可进入表达清理' : '故事层需先回炉');
  assert.equal(outcome.task.short_full_story_review_projection.status,
    decision === 'pass' ? 'review_passed' : 'review_revision_required');
  assert.equal(outcome.task.short_full_story_review_projection.source, 'workflow_v3_editorial_review');
  if (decision === 'revise') {
    assert.equal(outcome.task.short_full_story_review.findings.length, 1);
    assert.equal(outcome.task.short_full_story_review.findings[0].code, 'EndingCost');
    assert.equal(outcome.task.pending_feedback.status, 'awaiting_confirmation');
    assert.deepEqual(outcome.task.pending_feedback.proposed_plan.affected_sections, [2]);
    assert.equal(outcome.task.pending_action.feedback_id, outcome.task.pending_feedback.id);
    assert.match(outcome.visible_response.text, /1\. 采用这份修改方案/u);
    assert.doesNotMatch(outcome.visible_response.text, /EndingCost|S3/u);
    const persisted = engine.readTask(root, id);
    assert.deepEqual(persisted.pending_feedback.proposed_plan.review_findings,
      outcome.task.pending_feedback.proposed_plan.review_findings);
    engine.resolveAuthorInput(root, id, persisted.state_version, {
      ...outcome.visible_response.binding,
      choice: '1',
    });
    const accepted = engine.readTask(root, id);
    assert.equal(accepted.pending_feedback.status, 'accepted');
    assert.equal(accepted.current_stage, 'feedback_apply_patch');
    assert.equal(accepted.current_section_index, 2);
    return accepted;
  }
  return outcome.task;
}

seed(path.join(base, 'pass'), 'wf-editorial-pass', 'pass');
seed(path.join(base, 'revise'), 'wf-editorial-revise', 'revise');
seed(path.join(base, 'length-decision'), 'wf-editorial-length', 'pass', true);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 deslop receipts bind the reviewed source and final check closes the lifecycle" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const closure = require(path.join(repo, 'scripts/lib/short-production/closure.js'));
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { commitAcceptedSection } = require(path.join(repo, 'scripts/lib/short-section-commit-store.js'));
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));
const stateRoot = path.join(root, '追踪/story-system/short');
const first = '阿岚把核验记录放到桌面上。主管要求她先撤回，她拒绝签字并保留原始编号。'.repeat(12);
const second = '阿岚提交更正方案并承担延期。主管接受停权，编号恢复公开复核，后来的人都能查到。'.repeat(12);
const story = `## 第001节 发现差异\n\n${first}\n\n## 第002节 完成复核\n\n${second}\n`;
fs.writeFileSync(path.join(root, '正文.md'), story);
fs.writeFileSync(path.join(root, '设定.md'), '## 阿岚\n她要完成公开复核。\n\n## 主管\n他要保住交付。\n');
fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：发现差异\n## 第2节：完成复核\n');
let task = store.createTaskRecord(root, {
  workflow_id: 'wf-closure-final', workflow_type: 'short_write', current_stage: 'editorial_review', user_goal: '验证全篇闭环',
});
const accepted = [];
for (const section of [
  { index: 1, title: '发现差异', body: first },
  { index: 2, title: '完成复核', body: second },
]) {
  const commit = commitAcceptedSection(root, {
    task, sectionIndex: section.index, title: section.title, text: section.body,
    metadata: {}, projectTitle: '中性测试短篇',
  });
  const anchorRel = `追踪/story-system/short/section-${String(section.index).padStart(3, '0')}-anchor.json`;
  atomicWriteJson(path.join(root, anchorRel), {
    workflow_id: task.workflow_id, section_index: section.index, status: 'accepted',
    canonical_path: commit.canonical_path, canonical_sha256: commit.canonical_sha256,
    section_commit_id: commit.commit_id,
    quality_result: {
      machine_gate: 'pass', story_value_gate: 'pass', repetition_gate: 'pass',
      length_policy: { verdict: 'within_story_band', blocking: false },
    },
  });
  accepted.push({
    section_index: section.index, title: section.title, anchor_path: anchorRel,
    canonical_path: commit.canonical_path, sha256: commit.canonical_sha256,
    section_commit_id: commit.commit_id,
  });
}
atomicWriteJson(path.join(stateRoot, 'project-state.json'), {
  schema_version: '2.0.0', project_id: 'neutral-final', project_title: '中性测试短篇',
  planned_sections: 2, narrative: { planned_sections: 2 }, accepted_sections: accepted,
});
atomicWriteJson(path.join(stateRoot, 'section-title-lock.json'), {
  planned_sections: 2, sections: [{ section_index: 1 }, { section_index: 2 }],
});
const reviewRoot = `${task.task_dir}/artifacts/closure/editorial-review/attempts/${task.stage_execution.stage_attempt_id}`;
const storyHash = crypto.createHash('sha256').update(story).digest('hex');
const reviewReceiptRel = `${reviewRoot}/receipt.json`;
atomicWriteJson(path.join(root, reviewReceiptRel), {
  schema_version: '1.0.0', workflow_id: task.workflow_id, decision: 'pass',
  story_path: '正文.md', story_sha256: storyHash,
});
atomicWriteJson(path.join(root, task.task_dir, 'artifacts/closure/editorial-review/latest.json'), {
  schema_version: '1.0.0', workflow_id: task.workflow_id,
  stage_attempt_id: task.stage_execution.stage_attempt_id,
  receipt_path: reviewReceiptRel,
  receipt_sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(root, reviewReceiptRel))).digest('hex'),
});
task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'editorial_seeded', stage_id: 'editorial_review', decision: 'pass', next_stage: 'deslop',
}).task;
assert.equal(task.current_stage, 'deslop');
task = store.commitTask(root, task.workflow_id, task.state_version, (draft) => ({
  ...draft,
  short_full_story_review: {
    decision: 'revise', story_sha256: 'legacy-stale-story', visible_label: '旧裁决不得残留',
  },
  short_full_story_review_projection: { status: 'stale_projection' },
}));
const stagedRel = `${task.task_dir}/artifacts/deslop-candidate.md`;
fs.mkdirSync(path.dirname(path.join(root, stagedRel)), { recursive: true });
fs.writeFileSync(path.join(root, stagedRel), story);
const deslop = closure.finalizeDeslop({ projectRoot: root, task, stagedPath: stagedRel });
assert.equal(deslop.kind, 'completed', JSON.stringify(deslop));
assert.equal(deslop.source_canonical_sha256, storyHash);
assert.equal(deslop.canonical_sha256, storyHash);
assert.equal(deslop.preservation_result.status, 'pass');
const stateFile = path.join(stateRoot, 'project-state.json');
const anchorOne = path.join(stateRoot, 'section-001-anchor.json');
const stateBytes = fs.readFileSync(stateFile);
const anchorBytes = fs.readFileSync(anchorOne);
const repeatedDeslop = closure.finalizeDeslop({ projectRoot: root, task, stagedPath: stagedRel });
assert.equal(repeatedDeslop.kind, 'completed');
assert.equal(repeatedDeslop.deslop_commit_id, deslop.deslop_commit_id);
assert.deepEqual(fs.readFileSync(stateFile), stateBytes, 'identical deslop retry must keep project state byte-identical');
assert.deepEqual(fs.readFileSync(anchorOne), anchorBytes, 'identical deslop retry must keep anchors byte-identical');
task = engine.applyStageResult(root, task.workflow_id, task.state_version, deslop).task;
assert.equal(task.current_stage, 'final_check');
assert.equal(task.short_full_story_review.decision, 'pass');
assert.equal(task.short_full_story_review.story_sha256, storyHash);
assert.equal(task.short_full_story_review_projection.status, 'review_passed');
assert.equal(task.short_full_story_review_projection.source, 'workflow_v3_editorial_receipt_recovery');
const canonicalSectionFile = path.join(root, '正文/第001节.md');
const canonicalSectionBytes = fs.readFileSync(canonicalSectionFile);
fs.appendFileSync(canonicalSectionFile, '\n未进入正式合稿的计划外修改。\n');
const divergentSection = closure.runFinalCheck({ projectRoot: root, task });
assert.equal(divergentSection.kind, 'retryable_internal');
assert.ok((divergentSection.findings || []).some((finding) =>
  finding.code === 'accepted_section_proof_invalid' || finding.code === 'accepted_sections_story_mismatch'),
  JSON.stringify(divergentSection));
fs.writeFileSync(canonicalSectionFile, canonicalSectionBytes);
const deslopReceiptFile = path.join(root, deslop.receipt_path);
const deslopReceiptBytes = fs.readFileSync(deslopReceiptFile);
fs.appendFileSync(deslopReceiptFile, '\n');
const tampered = closure.runFinalCheck({ projectRoot: root, task });
assert.equal(tampered.kind, 'retryable_internal');
assert.ok((tampered.findings || []).some((finding) => finding.code === 'deslop_receipt_hash_mismatch'));
fs.writeFileSync(deslopReceiptFile, deslopReceiptBytes);
const final = closure.runFinalCheck({ projectRoot: root, task });
assert.equal(final.kind, 'completed', JSON.stringify(final));
assert.equal(final.canonical_sha256, storyHash);
assert.equal(final.completion_event.artifact_digest, `sha256:${storyHash}`);
const outcome = engine.applyStageResult(root, task.workflow_id, task.state_version, final);
assert.equal(outcome.task.status, 'completed');
assert.equal(outcome.task.lifecycle.status, 'completed');
assert.equal(outcome.task.current_stage, 'final_check');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 assembly rolls back a prepared transaction when canonical commit fails" {
  run node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const commitStorePath = path.join(repo, 'scripts/lib/chapter-commit-store.js');
const commitStore = require(commitStorePath);
const { commitAcceptedSection } = require(path.join(repo, 'scripts/lib/short-section-commit-store.js'));
const taskStore = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const { atomicWriteJson } = require(path.join(repo, 'scripts/lib/workflow-state-store.js'));

const task = taskStore.createTaskRecord(root, {
  workflow_id: 'wf-closure-rollback', workflow_type: 'short_write',
  current_stage: 'assembly', user_goal: '验证合稿失败事务回滚',
});
const commit = commitAcceptedSection(root, {
  task, sectionIndex: 1, title: '公开复核',
  text: '阿岚提交编号更正记录，主管确认责任并开放复核。',
  metadata: {}, projectTitle: '中性测试短篇',
});
const anchorRel = '追踪/story-system/short/section-001-anchor.json';
atomicWriteJson(path.join(root, anchorRel), {
  workflow_id: task.workflow_id, section_index: 1, status: 'accepted',
  canonical_path: commit.canonical_path, canonical_sha256: commit.canonical_sha256,
  section_commit_id: commit.commit_id,
  quality_result: {
    machine_gate: 'pass', story_value_gate: 'pass', repetition_gate: 'pass',
    length_policy: { verdict: 'within_story_band', blocking: false },
  },
});
atomicWriteJson(path.join(root, '追踪/story-system/short/project-state.json'), {
  schema_version: '2.0.0', project_id: 'neutral-rollback', project_title: '中性测试短篇',
  planned_sections: 1, narrative: { planned_sections: 1 },
  accepted_sections: [{
    section_index: 1, anchor_path: anchorRel, canonical_path: commit.canonical_path,
    sha256: commit.canonical_sha256, section_commit_id: commit.commit_id,
  }],
});
atomicWriteJson(path.join(root, '追踪/story-system/short/section-title-lock.json'), {
  planned_sections: 1, sections: [{ section_index: 1 }],
});
fs.writeFileSync(path.join(root, '小节大纲.md'), '## 第1节：公开复核\n');

const originalAccept = commitStore.acceptTransaction;
commitStore.acceptTransaction = () => {
  const error = new Error('injected assembly commit failure');
  error.status = 'blocked_injected_commit';
  throw error;
};
delete require.cache[require.resolve(path.join(repo, 'scripts/lib/short-production/closure.js'))];
const closure = require(path.join(repo, 'scripts/lib/short-production/closure.js'));
const result = closure.assembleStory({ projectRoot: root, task });
commitStore.acceptTransaction = originalAccept;

assert.equal(result.kind, 'retryable_internal', JSON.stringify(result));
assert.equal(result.code, 'blocked_injected_commit');
const txRoot = path.join(root, '追踪/story-system/transactions');
const transactions = fs.readdirSync(txRoot).map((name) =>
  JSON.parse(fs.readFileSync(path.join(txRoot, name, 'transaction.json'), 'utf8')));
const assemblyTransactions = transactions.filter((tx) => tx.volume === '短篇发布稿');
assert.equal(assemblyTransactions.length, 1, JSON.stringify(assemblyTransactions));
assert.equal(assemblyTransactions[0].status, 'rolled_back',
  'failed assembly must not leave a prepared orphan transaction');
assert.match(String(assemblyTransactions[0].rollback_reason || ''), /blocked_injected_commit/u);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "V3 closure service keeps V2 orchestration and menu rendering outside its boundary" {
  run node - "$REPO" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const modulePath = path.join(process.argv[2], 'scripts/lib/short-production/closure.js');
if (!fs.existsSync(modulePath)) process.exit(0);
const source = fs.readFileSync(modulePath, 'utf8');
for (const pattern of [
  /require\(\s*['"][^'"]*workflow-state-machine/u,
  /require\(\s*['"][^'"]*workflow-entry-guard/u,
  /require\(\s*['"][^'"]*workflow-task-inbox/u,
  /require\(\s*['"][^'"]*workflow-action-renderer/u,
  /require\(\s*['"][^'"]*interaction-arbiter/u,
  /require\(\s*['"][^'"]*workflow-v3\/engine/u,
]) assert.ok(!pattern.test(source), `forbidden closure import: ${pattern}`);
assert.ok(!/visible_response/u.test(source), 'closure must never construct visible_response');
assert.ok(!/spawn(?:Sync)?\s*\([^)]*workflow-state-machine/u.test(source),
  'closure must never spawn the V2 state machine');
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "all legacy closure CLIs reject a V3 task before V2 stage logic" {
  node - "$REPO" "$PROJECT" <<'NODE'
const path = require('path');
const store = require(path.join(process.argv[2], 'scripts/lib/workflow-v3/task-store.js'));
store.createTaskRecord(process.argv[3], {
  workflow_id: 'wf-closure-cli-guard', workflow_type: 'short_write',
  current_stage: 'assembly', user_goal: '验证入口隔离',
});
NODE
  for script in \
    short-story-assembly-finalize.js \
    short-story-review-finalize.js \
    short-story-deslop-finalize.js \
    short-story-final-check.js
  do
    run node "$REPO/scripts/$script" --project-root "$PROJECT" --workflow-id wf-closure-cli-guard --apply --json
    [ "$status" -eq 2 ] || { echo "$script: $output"; false; }
    node -e 'const out=JSON.parse(process.argv[1]);if(out.status!=="v3_engine_apply_required")throw new Error(JSON.stringify(out));' "$output"
  done
}

@test "Chinese section headings are recognized without an ASCII word boundary" {
  ! grep -q '节\\b' "$REPO/scripts/short-story-deslop-finalize.js"
  ! grep -q '节\\b' "$REPO/scripts/short-story-final-check.js"
  ! grep -q '节\\b' "$REPO/scripts/lib/short-production/closure.js"
}
