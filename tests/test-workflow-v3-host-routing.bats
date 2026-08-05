#!/usr/bin/env bats

# Task 11: Entry, Inbox and Host Routing. A V3 task (engine_version 3) has
# exactly ONE source of author-visible output: the interaction rendered by
# workflow-v3.js show (which delegates to renderCommittedInteraction). The
# entry guard must only check and forward; the inbox must put that same
# envelope into the task card without rebuilding question/options/numbers;
# the Claude Code, Codex and ZCode host adapters must forward
# visible_response.text and the four-field binding byte-for-byte, never
# renumbering or paraphrasing.
#
# Fixtures stay project-neutral: no real book title, character, plot, id or
# project-specific wording.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    CLI="$REPO/scripts/workflow-v3.js"
    ENTRY_GUARD="$REPO/scripts/workflow-entry-guard.js"
    INBOX="$REPO/scripts/workflow-task-inbox.js"
    ADAPTERS="$REPO/scripts/lib/workflow-host-adapters.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

# Create a neutral V3 short_write task at creative_entry, then commit a
# needs_author_choice result so the durable task.json owns a pending action
# rendered by the Arbiter. Emits the workflow id on stdout.
commit_v3_pending_choice() {
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "中性短篇目标" \
        --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/create.json"

    # A neutral author choice committed through the real engine.
    printf '%s\n' '{"kind":"needs_author_choice","code":"pick_direction","stage_id":"creative_entry","question":"请选择下一步方向","options":[{"action_id":"proceed","label":"继续推进"},{"action_id":"adjust","label":"调整方向"}]}' > "$TMP_DIR/result.json"
    run node "$CLI" apply-result \
        --project-root "$PROJECT" \
        --workflow-id "$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")" \
        --expected-version 1 \
        --result-file "$TMP_DIR/result.json" \
        --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/apply.json"
}

# --- RED: a bare entry never leaks a V3 creative-stage menu past the inbox --

@test "a bare entry (no user-intent) returns the global four-item inbox even when a V3 task has a pending interaction" {
    commit_v3_pending_choice
    local wfid
    wfid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")

    # No --user-intent: this is a bare startup call. The pending V3 author
    # choice must NOT bypass the global task inbox, and no chapter/Brief stage
    # wording may leak into the visible menu.
    run node "$ENTRY_GUARD" --project-root "$PROJECT" --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/bare-entry.json"

    node - "$TMP_DIR/bare-entry.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (report.status !== 'task_inbox_ready') throw new Error(`expected task_inbox_ready, got ${report.status}`);
const vr = report.visible_response;
if (!vr || !Array.isArray(vr.options) || vr.options.length !== 4) throw new Error(JSON.stringify(vr));
const labels = vr.options.map((option) => String(option.label || ''));
if (!labels.some((label) => label.includes('查看未完成任务'))) throw new Error(JSON.stringify(labels));
if (!labels.some((label) => /智能推荐/.test(label))) throw new Error(JSON.stringify(labels));
if (!labels.some((label) => /新目标/.test(label))) throw new Error(JSON.stringify(labels));
if (!labels.some((label) => /其他/.test(label))) throw new Error(JSON.stringify(labels));
// A bare entry must never surface the V3 author-choice question/options.
const serialized = JSON.stringify(report);
if (/请选择下一步方向|继续推进|调整方向/.test(serialized)) throw new Error('V3 creative interaction leaked past the global inbox');
NODE
}

@test "a bare entry (no user-intent) returns the global inbox for a menu-free V3 task" {
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "中性无菜单任务" \
        --json
    [ "$status" -eq 0 ]

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/bare-menu-free.json"

    node - "$TMP_DIR/bare-menu-free.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (report.status !== 'task_inbox_ready') throw new Error(`expected task_inbox_ready, got ${report.status}`);
if (!report.visible_response || !Array.isArray(report.visible_response.options)) throw new Error(JSON.stringify(report.visible_response));
NODE
}

# --- RED: single visible authority for V3 tasks ----------------------------

@test "entry guard forwards the V3 show interaction verbatim and does not rebuild a V3 menu" {
    commit_v3_pending_choice
    local wfid
    wfid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")

    # The canonical interaction the entry guard MUST forward unchanged.
    run node "$CLI" show --project-root "$PROJECT" --workflow-id "$wfid" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/show.json"

    # A non-empty, non-numeric, non-feedback intent (e.g. "查看当前进度") keeps
    # V3 routing active so contract 3 (verbatim forward) still applies, while a
    # bare empty intent now falls through to the global inbox (contract 1).
    run node "$ENTRY_GUARD" --project-root "$PROJECT" --user-intent "查看当前进度" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/guard.json"

    node - "$TMP_DIR/show.json" "$TMP_DIR/guard.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [showFile, guardFile] = process.argv.slice(2);
const show = JSON.parse(fs.readFileSync(showFile, 'utf8'));
const guard = JSON.parse(fs.readFileSync(guardFile, 'utf8'));

assert.ok(show.interaction, 'the V3 show interaction must exist for a pending choice');
const canonicalText = show.interaction.text;
const canonicalBinding = show.interaction.binding;

// The entry guard must surface the SAME interaction as its visible_response,
// never a rebuilt menu, renumbered options, or a paraphrased question.
const vr = guard.visible_response;
assert.ok(vr, 'entry guard must surface a visible_response for a pending V3 task');
assert.deepEqual(vr, show.interaction, 'entry guard must forward the complete V3 envelope unchanged');
assert.equal(vr.text, canonicalText, 'entry guard must forward V3 text byte-for-byte');
assert.deepEqual(vr.binding, canonicalBinding, 'entry guard must forward the four-field binding unchanged');

// The entry guard must not reconstruct its own numbered option list for a V3
// task: it forwards the Arbiter-owned interaction only.
assert.ok(!Array.isArray(vr.options), 'entry guard must not rebuild a V3 options array');
NODE
}

@test "entry guard resumes a menu-free V3 task through its V3 stage execution contract" {
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "中性恢复任务" \
        --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/v3-resume-create.json"
    mkdir -p "$PROJECT/追踪/story-system/short"
    printf '%s\n' '{"project_id":"neutral-short","project_title":"中性短篇","plan_revision":1,"planned_sections":1,"current_section_index":1,"accepted_sections":[]}' > "$PROJECT/追踪/story-system/short/project-state.json"
    printf '%s\n' '# 素材卡' '以公开记录推动责任落地。' > "$PROJECT/素材卡.md"
    printf '%s\n' '# 设定' '第一人称，主角负责档案复核。' > "$PROJECT/设定.md"
    cat > "$PROJECT/小节大纲.md" <<'EOF'
# 小节大纲
## 第1节：公开复核
- 结构功能：开篇建立可核验冲突
- 情绪目标：疑惑转为警觉
- 因果链：发现重复编号 -> 拒绝撤回 -> 保留复核记录
- 场景动作：主角在评审会上展示重复编号
- 角色选择：主角拒绝删除记录
- 可见阻力：主管要求立即撤回记录
- 本节兑现：重复编号第一次被公开展示
- 关系变化：主角与主管从配合转为公开分歧
- 代价升级：主角可能失去复核权限
- 核心承诺兑现：异常编号进入公开核验
- 决定性行动：主角保存扫描回放
- 即时代价：主管当场暂停她的操作权限
- 子事件：
  1. 主角发现两个批次编号重复
  2. 主管要求撤回，主角拒绝
- 节尾钩子：旧批次记录仍未公开
EOF
    node - "$PROJECT" "$TMP_DIR/v3-resume-create.json" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, createFile] = process.argv.slice(2);
const created = JSON.parse(fs.readFileSync(createFile, 'utf8'));
const taskFile = path.join(root, created.task.task_dir, 'task.json');
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.current_stage = 'section_brief';
task.current_section_index = 1;
task.stage_execution = {
  status: 'running',
  stage_id: 'section_brief',
  stage_attempt_id: 'sa-neutral-section-brief',
  section_index: 1,
};
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --user-intent "查看当前进度" \
        --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/v3-resume.json"

    node - "$TMP_DIR/v3-resume.json" <<'NODE'
const report = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (report.status !== 'v3_task_ready') throw new Error(JSON.stringify(report));
if (report.presentation_allowed !== false) throw new Error(JSON.stringify(report));
if (!report.stage_execution || report.stage_execution.selection_contract !== 'resume_running_stage') {
  throw new Error(JSON.stringify(report.stage_execution));
}
if (!String(report.stage_execution.execution_command || '').includes('workflow-v3.js')) {
  throw new Error(JSON.stringify(report.stage_execution));
}
if (String(report.stage_execution.execution_command || '').includes('workflow-state-machine.js')) {
  throw new Error(JSON.stringify(report.stage_execution));
}
NODE
}

@test "V3 planning stages expose resumable staged-artifact contracts after creative entry" {
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "中性规划恢复任务" \
        --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/planning-create.json"

    node - "$REPO" "$PROJECT" "$TMP_DIR/planning-create.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root, createFile] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const runner = require(path.join(repo, 'scripts/lib/workflow-v3/stage-runner.js'));
let task = JSON.parse(fs.readFileSync(createFile, 'utf8')).task;

task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'creative_entry_confirmed', stage_id: 'creative_entry',
}).task;

const expectations = [
  ['material_positioning', '素材卡.md', []],
  ['setting', '设定.md', ['素材卡.md']],
  ['section_outline', '小节大纲.md', ['素材卡.md', '设定.md']],
];
for (const [stage, target, sources] of expectations) {
  assert.equal(task.current_stage, stage);
  const described = runner.describeCurrentStage({ projectRoot: root, workflowId: task.workflow_id });
  assert.equal(described.selection_contract, 'resume_running_stage');
  assert.equal(described.section_index, 0);
  assert.equal(described.write_set.length, 1);
  assert.match(described.write_set[0], new RegExp(`/artifacts/planning/${stage}/[^/]+/${target.replace('.', '\\.')}$`, 'u'));
  assert.deepEqual(described.source_files, sources);
  assert.equal(described.current_required_action, 'write_then_complete_stage');
  assert.match(described.stage_completion_command, /workflow-v3\.js run-current-stage/u);
  assert.equal(described.completion_required_before_reply, true);
  task = engine.applyStageResult(root, task.workflow_id, task.state_version, {
    kind: 'completed', code: `${stage}_accepted`, stage_id: stage,
  }).task;
}
NODE
}

@test "entry guard consumes the previously displayed V3 binding once and resumes instead of redisplaying the same menu" {
    commit_v3_pending_choice
    local wfid
    wfid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --session-id "test:v3-host-a" \
        --user-intent "查看当前进度" --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/first-v3-menu.json"

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --session-id "test:v3-host-b" --user-intent "1" --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/other-session-v3-menu.json"
    node - "$TMP_DIR/other-session-v3-menu.json" "$PROJECT" "$wfid" <<'NODE'
const fs = require('fs');
const path = require('path');
const [reportFile, root, workflowId] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪', 'workflow', 'tasks', workflowId, 'task.json'), 'utf8'));
if (!report.visible_response || task.pending_action.status !== 'pending') throw new Error('another host session consumed an unseen V3 binding');
NODE

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --session-id "test:v3-host-a" --user-intent "1" --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/refreshed-session-v3-menu.json"
    node - "$TMP_DIR/refreshed-session-v3-menu.json" <<'NODE'
const report = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (!report.visible_response) throw new Error('returning host session consumed another session binding');
NODE

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --session-id "test:v3-host-a" --user-intent "1" --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/resolved-v3-menu.json"

    node - "$TMP_DIR/first-v3-menu.json" "$TMP_DIR/resolved-v3-menu.json" "$PROJECT" "$wfid" <<'NODE'
const fs = require('fs');
const path = require('path');
const [firstFile, resolvedFile, root, workflowId] = process.argv.slice(2);
const first = JSON.parse(fs.readFileSync(firstFile, 'utf8'));
const resolved = JSON.parse(fs.readFileSync(resolvedFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪', 'workflow', 'tasks', workflowId, 'task.json'), 'utf8'));
if (!first.visible_response || !first.visible_response.binding) throw new Error('first V3 menu was not durably displayed');
if (resolved.visible_response !== null) throw new Error('entry redisplayed the already consumed V3 menu');
if (resolved.recommended_next !== 'resume_unique_v3_checkpoint') throw new Error(JSON.stringify(resolved));
if (!task.pending_action || task.pending_action.status !== 'resolved') throw new Error('pending action was not resolved');
if (Number(task.pending_action.selection.number) !== 1) throw new Error('wrong V3 choice was resolved');
NODE
}

@test "entry guard rejects a stale displayed V3 binding and leaves the newer menu pending" {
    commit_v3_pending_choice
    local wfid
    wfid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --user-intent "查看当前进度" \
        --write --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/stale-first-menu.json"
    node - "$TMP_DIR/stale-first-menu.json" "$TMP_DIR/stale-choice.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
fs.writeFileSync(process.argv[3], `${JSON.stringify({ ...report.visible_response.binding, choice: '1' })}\n`);
NODE

    run node "$CLI" resolve --project-root "$PROJECT" --workflow-id "$wfid" \
        --expected-version 2 --input-file "$TMP_DIR/stale-choice.json" --json
    [ "$status" -eq 0 ]
    printf '%s\n' '{"kind":"needs_author_choice","code":"pick_new_direction","stage_id":"creative_entry","question":"请选择新的方向","options":[{"action_id":"new_a","label":"新方向甲"},{"action_id":"new_b","label":"新方向乙"}]}' > "$TMP_DIR/new-result.json"
    run node "$CLI" apply-result --project-root "$PROJECT" --workflow-id "$wfid" \
        --expected-version 3 --result-file "$TMP_DIR/new-result.json" --json
    [ "$status" -eq 0 ]

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --user-intent "1" --write --compact --json
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" > "$TMP_DIR/stale-blocked.json"

    node - "$TMP_DIR/stale-blocked.json" "$PROJECT" "$wfid" <<'NODE'
const fs = require('fs');
const path = require('path');
const [reportFile, root, workflowId] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪', 'workflow', 'tasks', workflowId, 'task.json'), 'utf8'));
if (report.status !== 'blocked_v3_binding_resolution') throw new Error(JSON.stringify(report));
if (!report.visible_response || !report.visible_response.text.includes('请选择新的方向')) throw new Error('latest menu was not refreshed');
if (task.state_version !== 4 || task.pending_action.status !== 'pending') throw new Error('stale choice mutated the newer menu');
NODE

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --user-intent "1" --write --compact --json
    [ "$status" -eq 0 ]
    node - "$PROJECT" "$wfid" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, workflowId] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪', 'workflow', 'tasks', workflowId, 'task.json'), 'utf8'));
if (task.state_version !== 5 || task.pending_action.status !== 'resolved') throw new Error('refreshed binding was not consumable');
if (task.pending_action.selection.action_id !== 'new_a') throw new Error('wrong refreshed choice was consumed');
NODE
}

@test "a V3 task without a pending interaction stays menu-free in entry and inbox" {
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "中性无菜单任务" \
        --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/create-only.json"
    local wfid
    wfid="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).task.workflow_id)" "$TMP_DIR/create-only.json")"

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --compact --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/no-menu-guard.json"

    run node "$INBOX" --project-root "$PROJECT" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/no-menu-inbox.json"

    node - "$TMP_DIR/no-menu-guard.json" "$TMP_DIR/no-menu-inbox.json" "$wfid" <<'NODE'
const fs = require('fs');
const [guardFile, inboxFile, workflowId] = process.argv.slice(2);
const guard = JSON.parse(fs.readFileSync(guardFile, 'utf8'));
const inbox = JSON.parse(fs.readFileSync(inboxFile, 'utf8'));
// A bare entry must land on the global inbox, not a fabricated V3 menu (contract 1).
if (guard.status !== 'task_inbox_ready') throw new Error(`expected task_inbox_ready, got ${guard.status}`);
const vr = guard.visible_response;
if (!vr || !Array.isArray(vr.options) || vr.options.length !== 4) throw new Error(JSON.stringify(vr));
if (/pick_direction/.test(JSON.stringify(vr))) throw new Error('entry fabricated a V3 creative menu');
const card = (inbox.task_cards || []).find((item) => String(item.id) === workflowId
  || String(item.head_workflow_id) === workflowId);
if (!card || (card.v3_interaction !== undefined && card.v3_interaction !== null)) {
  throw new Error('inbox fabricated a V3 interaction for a menu-free task');
}
if (!Array.isArray(card.next_actions) || card.next_actions.length !== 1) throw new Error('inbox lost the safe resume action');
NODE
}

@test "entry guard emits parseable JSON when a migrated V3 authority exceeds the stdout pipe buffer" {
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "中性大状态任务" \
        --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/large-create.json"
    local wfid
    wfid="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).task.workflow_id)" "$TMP_DIR/large-create.json")"

    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-neutral-large-secondary"
    node - "$PROJECT/追踪/workflow/tasks/wf-neutral-large-secondary/task.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = {
  workflow_id: 'wf-neutral-large-secondary',
  workflow_type: 'review',
  status: 'running',
  state_version: 1,
  user_goal: `中性辅助任务${'x'.repeat(96 * 1024)}`,
  current_stage: 'review',
  current_step: 'review',
};
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE

    run node "$ENTRY_GUARD" --project-root "$PROJECT" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/large-guard.json"

    node - "$TMP_DIR/large-guard.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
// The point of this test is parseable JSON across the pipe buffer. A bare call
// now lands on the global inbox (contract 1) instead of the V3 entry.
if (report.status !== 'task_inbox_ready') throw new Error(`unexpected status: ${report.status}`);
NODE
}

@test "V3 core emits parseable create output larger than the stdout pipe buffer" {
    run node "$CLI" create-short \
        --project-root "$PROJECT" \
        --profile public \
        --user-goal "$(node -e "process.stdout.write('中性大输出任务' + 'x'.repeat(96 * 1024))")" \
        --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/large-v3-create.json"

    node - "$TMP_DIR/large-v3-create.json" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (result.ok !== true || !result.task || result.task.user_goal.length < 96 * 1024) {
  throw new Error('large V3 create result was not emitted intact');
}
NODE
}

@test "inbox puts the committed V3 envelope into the task card without rebuilding question/options/numbers" {
    commit_v3_pending_choice
    local wfid
    wfid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")

    run node "$CLI" show --project-root "$PROJECT" --workflow-id "$wfid" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/show.json"

    run node "$INBOX" --project-root "$PROJECT" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/inbox.json"

    node - "$TMP_DIR/inbox.json" "$TMP_DIR/show.json" "$wfid" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [inboxFile, showFile, wfid] = process.argv.slice(2);
const inbox = JSON.parse(fs.readFileSync(inboxFile, 'utf8'));
const show = JSON.parse(fs.readFileSync(showFile, 'utf8'));

const card = (inbox.task_cards || []).find((c) => String(c.id) === String(wfid)
  || String(c.head_workflow_id) === String(wfid));
assert.ok(card, `V3 task card must be present: ${(inbox.task_cards || []).map((c) => c.id).join(',')}`);

// The card carries the SAME committed interaction envelope forwarded verbatim
// from workflow-v3.js show, including the exact text and four-field binding.
const envelope = card.v3_interaction;
assert.ok(envelope, 'task card must carry the V3 interaction envelope');
assert.equal(envelope.text, show.interaction.text, 'inbox must forward V3 text byte-for-byte');
assert.deepEqual(envelope.binding, show.interaction.binding, 'inbox must forward the four-field binding unchanged');

// The inbox must NOT rebuild the question, options, or numbers for a V3 task.
// The Arbiter is the sole numbering authority; the inbox only forwards.
assert.ok(!Array.isArray(card.next_actions) || card.next_actions.length === 0
    || card.next_actions.every((a) => a.action_id !== 'continue_next_stage'
        && a.action_id !== 'resume'),
    'inbox must not synthesize V2-style resume actions for a V3 pending choice');
NODE
}

@test "Claude Code, Codex and ZCode adapters forward visible_response text and binding byte-identically without renumbering" {
    commit_v3_pending_choice
    local wfid
    wfid=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$TMP_DIR/create.json','utf8')).task.workflow_id)")

    run node "$CLI" show --project-root "$PROJECT" --workflow-id "$wfid" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/show.json"

    node - "$ADAPTERS" "$TMP_DIR/show.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const adapters = require(process.argv[2]);
const show = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const interaction = show.interaction;
assert.ok(interaction && interaction.text && interaction.binding, 'canonical interaction missing');

const expectedBindingKeys = ['pending_action_id', 'state_version', 'visible_choice_hash', 'workflow_id'].sort();
const canonicalText = interaction.text;
const canonicalBinding = interaction.binding;
assert.deepEqual(Object.keys(canonicalBinding).sort(), expectedBindingKeys, 'canonical binding must be exactly the four fields');

// Each host adapter must return the SAME visible_response: byte-identical text
// and the unchanged four-field binding. No host may renumber options, drop a
// field, paraphrase, or add host-specific metadata to the binding.
const rendered = {};
for (const adapter of ['claude-code', 'codex', 'zcode']) {
  const out = adapters.renderHostVisibleResponse(adapter, interaction);
  assert.ok(out, `adapter ${adapter} returned no visible response`);
  assert.equal(out.text, canonicalText, `adapter ${adapter} text differs from canonical`);
  assert.deepEqual(Object.keys(out.binding).sort(), expectedBindingKeys,
    `adapter ${adapter} binding keys differ`);
  assert.deepEqual(out.binding, canonicalBinding, `adapter ${adapter} binding differs from canonical`);
  rendered[adapter] = out;
}

// All three hosts must agree byte-for-byte.
assert.deepEqual(rendered['claude-code'], rendered.codex, 'claude-code != codex');
assert.deepEqual(rendered['claude-code'], rendered.zcode, 'claude-code != zcode');

// An unsupported host must fail closed rather than silently fabricating a
// response.
let failed = false;
try {
  adapters.renderHostVisibleResponse('auto', interaction);
} catch (error) {
  failed = /unsupported adapter/.test(error.message);
}
assert.ok(failed, 'an unknown adapter must fail closed');
NODE
}

# --- V2 behavior must NOT change ------------------------------------------

@test "a V2 task still gets its existing rebuilt inbox menu (V3 routing is opt-in by engine_version)" {
    # A V2 short_write task WITHOUT engine_version 3 keeps the legacy behavior:
    # the inbox builds its own numbered next_actions. This guards against the
    # V3 path accidentally swallowing V2 tasks.
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-v2-short"
    cat > "$PROJECT/追踪/workflow/tasks/wf-v2-short/task.json" <<'JSON'
{
  "workflow_id": "wf-v2-short",
  "workflow_type": "short_write",
  "status": "running",
  "state_version": 5,
  "book_root": ".",
  "user_goal": "旧短篇继续",
  "current_stage": "section_outline",
  "current_step": "section_outline",
  "machine": {"next_stop_reason": "ready_for_current_stage"},
  "pending_action": {
    "options": [
      {"number": 1, "label": "继续小节大纲", "action_id": "continue_next_stage", "target_stage": "section_outline"}
    ]
  },
  "runtime_guard": {
    "heartbeat": {"updated_at": "2026-07-18T00:00:00.000Z"},
    "stall_policy": {"heartbeat_timeout_minutes": 999999},
    "checkpoint_policy": {"resume_from": "section_outline"}
  }
}
JSON
    node - "$PROJECT" <<'NODE'
const fs = require('fs'), path = require('path');
const root = process.argv[2];
const pointer = {
  schemaVersion: '1.0.0',
  workflow_id: 'wf-v2-short',
  task_dir: '追踪/workflow/tasks/wf-v2-short',
  focused_at: '2026-07-18T00:00:00.000Z',
  state_version: 5,
};
fs.writeFileSync(path.join(root, '追踪/workflow/current-task.json'), JSON.stringify(pointer, null, 2) + '\n');
NODE

    run node "$INBOX" --project-root "$PROJECT" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/v2-inbox.json"

    node - "$TMP_DIR/v2-inbox.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const inbox = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const card = (inbox.task_cards || []).find((c) => c.id === 'wf-v2-short');
assert.ok(card, 'V2 task card must still be present');

// V2 keeps its rebuilt, numbered next_actions (legacy behavior unchanged).
assert.ok(Array.isArray(card.next_actions) && card.next_actions.length > 0,
  'V2 task must keep its rebuilt next_actions');

// And a V2 task must NOT carry the V3 forwarding envelope: V3 routing is
// opt-in via engine_version 3 only.
assert.equal(card.v3_interaction, undefined,
  'V2 task must not be misrouted into the V3 forwarding path');
NODE
}
