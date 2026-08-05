#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  CLI="$REPO/scripts/workflow-v3.js"
  ENTRY="$REPO/scripts/workflow-entry-guard.js"
  TMP_DIR="$(mktemp -d)"
  PROJECT="$TMP_DIR/book"
  mkdir -p "$PROJECT"
  printf '# 中性正文\n\n原始内容。\n' > "$PROJECT/正文.md"
}

teardown() {
  rm -rf "$TMP_DIR"
}

create_task() {
  node "$CLI" create-short --project-root "$PROJECT" --profile public \
    --user-goal "中性短篇目标" --json > "$TMP_DIR/create.json"
  WFID="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).task.workflow_id)" "$TMP_DIR/create.json")"
  TASK="$PROJECT/追踪/workflow/tasks/$WFID/task.json"
}

commit_menu() {
  printf '%s\n' '{"kind":"needs_author_choice","code":"pick_direction","stage_id":"creative_entry","question":"请选择方向","options":[{"action_id":"continue","label":"继续"},{"action_id":"chat","label":"修改方案"}]}' > "$TMP_DIR/result.json"
  node "$CLI" apply-result --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --result-file "$TMP_DIR/result.json" --json > "$TMP_DIR/apply.json"
}

@test "V3 submit-feedback records exact text, archives a menu, and leaves creative assets unchanged" {
  create_task
  commit_menu
  before_hash="$(shasum -a 256 "$PROJECT/正文.md" | awk '{print $1}')"
  cat > "$TMP_DIR/feedback.json" <<'JSON'
{"text":"这句不够生动，\n请保留原意。"}
JSON

  run node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/feedback.json" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/submitted.json"

  node - "$TMP_DIR/submitted.json" "$TASK" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [resultFile, taskFile] = process.argv.slice(2);
const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
assert.equal(result.ok, true);
assert.equal(result.feedback_receipt.status, 'pending_analysis');
assert.equal(task.state_version, 3);
assert.equal(task.current_stage, 'creative_entry');
assert.equal(task.pending_action, undefined);
assert.equal(task.pending_feedback.workflow_id, task.workflow_id);
assert.equal(task.pending_feedback.stage_id, 'creative_entry');
assert.equal(task.pending_feedback.status, 'pending_analysis');
assert.equal(task.pending_feedback.messages.length, 1);
assert.equal(task.pending_feedback.messages[0].text, '这句不够生动，\n请保留原意。');
assert.equal(task.pending_feedback.messages[0].stage_id, 'creative_entry');
assert.equal(task.interaction_history.length, 1);
assert.equal(task.interaction_history[0].question, '请选择方向');
assert.equal(task.interaction_history[0].status, 'pending');
NODE
  [ "$before_hash" = "$(shasum -a 256 "$PROJECT/正文.md" | awk '{print $1}')" ]
}

@test "V3 submit-feedback appends messages under one feedback id and stale versions cannot write" {
  create_task
  printf '%s\n' '{"text":"第一条意见。"}' > "$TMP_DIR/first.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/first.json" --json > "$TMP_DIR/first-out.json"
  first_id="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).feedback_receipt.feedback_id)" "$TMP_DIR/first-out.json")"
  printf '%s\n' '{"text":"第二条意见，继续补充。"}' > "$TMP_DIR/second.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/second.json" --json > "$TMP_DIR/second-out.json"

  node - "$TASK" "$first_id" <<'NODE'
const assert = require('assert');
const task = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
assert.equal(task.state_version, 3);
assert.equal(task.pending_feedback.id, process.argv[3]);
assert.deepEqual(task.pending_feedback.messages.map(item => item.text), ['第一条意见。', '第二条意见，继续补充。']);
NODE
  cp "$TASK" "$TMP_DIR/before-stale.json"
  run node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/second.json" --json
  [ "$status" -ne 0 ]
  cmp -s "$TASK" "$TMP_DIR/before-stale.json"
}

@test "V3 submit-feedback rejects blank or authority-shaped input before writing" {
  create_task
  cp "$TASK" "$TMP_DIR/before.json"
  printf '%s\n' '{"text":"   \n"}' > "$TMP_DIR/blank.json"
  run node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/blank.json" --json
  [ "$status" -ne 0 ]
  cmp -s "$TASK" "$TMP_DIR/before.json"

  printf '%s\n' '{"text":"修改这句。","current_stage":"section_repair"}' > "$TMP_DIR/authority.json"
  run node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/authority.json" --json
  [ "$status" -ne 0 ]
  cmp -s "$TASK" "$TMP_DIR/before.json"
}

@test "V3 propose-feedback rejects malformed analysis before writing" {
  create_task
  printf '%s\n' '{"text":"需要调整人物动机。"}' > "$TMP_DIR/feedback.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/feedback.json" --json > "$TMP_DIR/feedback-out.json"
  feedback_id="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).feedback_receipt.feedback_id)" "$TMP_DIR/feedback-out.json")"
  cp "$TASK" "$TMP_DIR/before-plan.json"
  cat > "$TMP_DIR/bad-plan.json" <<JSON
{"feedback_id":"$feedback_id","summary":"调整方案","impact_level":"","affected_sections":[0],"evidence":[""],"proposed_changes":[]}
JSON
  run node "$CLI" propose-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/bad-plan.json" --json
  [ "$status" -ne 0 ]
  cmp -s "$TASK" "$TMP_DIR/before-plan.json"
}

@test "V3 propose-feedback rejects an empty affected section scope before writing" {
  create_task
  printf '%s\n' '{"text":"需要调整当前节。"}' > "$TMP_DIR/feedback.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/feedback.json" --json > "$TMP_DIR/feedback-out.json"
  feedback_id="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).feedback_receipt.feedback_id)" "$TMP_DIR/feedback-out.json")"
  cp "$TASK" "$TMP_DIR/before-empty-plan.json"
  cat > "$TMP_DIR/empty-plan.json" <<JSON
{"feedback_id":"$feedback_id","summary":"局部调整","impact_level":"current_brief","affected_sections":[],"evidence":["作者明确要求调整当前节"],"proposed_changes":["按确认意见局部修订"]}
JSON

  run node "$CLI" propose-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/empty-plan.json" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"feedback_plan_affected_sections_invalid"* ]]
  cmp -s "$TASK" "$TMP_DIR/before-empty-plan.json"
}

@test "V3 final check refuses legacy accepted feedback with no affected section" {
  node - "$REPO" "$PROJECT" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const [repo, root] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const store = require(path.join(repo, 'scripts/lib/workflow-v3/task-store.js'));
const task = store.createTaskRecord(root, {
  workflow_id: 'wf-empty-accepted-feedback',
  workflow_type: 'short_write',
  current_stage: 'final_check',
  user_goal: '中性终检任务',
  pending_feedback: {
    id: 'feedback-empty-scope',
    status: 'accepted',
    accepted_plan: {
      feedback_id: 'feedback-empty-scope',
      status: 'accepted_pending_projection',
      projection_status: 'pending',
      affected_sections: [],
    },
  },
});
const taskFile = path.join(root, task.task_dir, 'task.json');
const before = fs.readFileSync(taskFile);
assert.throws(() => engine.applyStageResult(root, task.workflow_id, task.state_version, {
  kind: 'completed', code: 'final_ok', stage_id: 'final_check',
}), /accepted_feedback_incomplete/u);
assert.deepEqual(fs.readFileSync(taskFile), before);
NODE
}

@test "entry guard records V3 free Chat directly and never sends it to the frozen V2 state machine" {
  create_task
  commit_menu
  run node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-feedback" \
    --user-intent "这句要修改，后半段不够生动。" --write --compact --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/entry.json"

  node - "$TMP_DIR/entry.json" "$TASK" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [entryFile, taskFile] = process.argv.slice(2);
const entry = JSON.parse(fs.readFileSync(entryFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
assert.equal(entry.status, 'v3_feedback_recorded');
assert.equal(entry.recommended_next, 'analyze_v3_feedback');
assert.equal(entry.visible_response, null);
assert.equal(entry.feedback_receipt.feedback_id, task.pending_feedback.id);
assert.equal(task.pending_feedback.messages[0].text, '这句要修改，后半段不够生动。');
assert.equal(task.current_stage, 'creative_entry');
NODE
}

@test "entry guard treats continue as checkpoint recovery rather than feedback" {
  create_task
  run node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-continue" \
    --user-intent "继续" --write --compact --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/continue.json"
  node - "$TMP_DIR/continue.json" "$TASK" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [entryFile, taskFile] = process.argv.slice(2);
const entry = JSON.parse(fs.readFileSync(entryFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
assert.equal(entry.status, 'v3_task_ready');
assert.equal(entry.recommended_next, 'resume_unique_v3_checkpoint');
assert.equal(task.pending_feedback, undefined);
assert.equal(task.state_version, 1);
NODE
}

@test "entry guard consumes an exact V3 menu label instead of recording it as new feedback" {
  create_task
  node - "$TASK" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const task = JSON.parse(fs.readFileSync(file, 'utf8'));
task.current_stage = 'section_brief';
task.current_section_index = 1;
task.scope = '第1节';
task.stage_execution = {
  status: 'running',
  stage_id: 'section_brief',
  stage_attempt_id: 'sa-label-choice-section-brief',
  section_index: 1,
};
fs.writeFileSync(file, `${JSON.stringify(task, null, 2)}\n`);
NODE
  printf '%s\n' '{"text":"第1节篇幅不足，需要按已确认预算回炉。"}' > "$TMP_DIR/feedback.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/feedback.json" --json > "$TMP_DIR/feedback-out.json"
  feedback_id="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).feedback_receipt.feedback_id)" "$TMP_DIR/feedback-out.json")"
  cat > "$TMP_DIR/plan.json" <<JSON
{"feedback_id":"$feedback_id","summary":"按预算回炉第1节。","impact_level":"section_only","affected_sections":[1],"evidence":["正文低于预算下限"],"proposed_changes":["扩写并重新通过双门"]}
JSON
  node "$CLI" propose-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/plan.json" --json > "$TMP_DIR/plan-out.json"

  node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-label-choice" \
    --user-intent "查看当前进度" --write --compact --json > "$TMP_DIR/shown.json"
  run node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-label-choice" \
    --user-intent "采用方案" --write --compact --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/resolved-label.json"

  node - "$TMP_DIR/resolved-label.json" "$TASK" "$feedback_id" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [reportFile, taskFile, feedbackId] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
assert.equal(task.pending_feedback.id, feedbackId);
assert.equal(task.pending_feedback.status, 'accepted');
assert.equal(task.pending_feedback.messages.length, 1);
assert.equal(task.pending_feedback.decision.action_id, 'accept_feedback_plan');
assert.equal(report.status, 'v3_feedback_plan_accepted');
assert.equal(report.recommended_next, 'apply_accepted_v3_feedback_plan');
NODE

  run node - "$REPO" "$PROJECT" "$WFID" <<'NODE'
const assert = require('assert');
const path = require('path');
const [repo, root, workflowId] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine.js'));
const task = engine.readTask(root, workflowId);
const applied = engine.applyStageResult(root, workflowId, task.state_version, {
  kind: 'completed',
  code: 'short_brief_accepted',
  stage_id: 'section_brief',
  section_index: 1,
}).task;
assert.equal(applied.current_stage, 'section_draft');
assert.equal(applied.accepted_plan.projection_status, 'completed');
assert.equal(applied.feedback_revision_queue.status, 'running');
assert.equal(applied.feedback_revision_queue.current_section_index, 1);
assert.deepEqual(applied.feedback_revision_queue.affected_sections, [1]);
NODE
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "pending V3 feedback survives restart and an analyzed plan requires a four-choice confirmation" {
  create_task
  printf '%s\n' '{"text":"人物动机不够可信，请先调整方案。"}' > "$TMP_DIR/feedback.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/feedback.json" --json > "$TMP_DIR/feedback-out.json"
  feedback_id="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).feedback_receipt.feedback_id)" "$TMP_DIR/feedback-out.json")"

  run node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-feedback-resume" \
    --user-intent "查看当前进度" --write --compact --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/resume.json"
  node - "$TMP_DIR/resume.json" <<'NODE'
const report = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (report.status !== 'v3_feedback_pending_analysis'
    || report.recommended_next !== 'analyze_v3_feedback'
    || report.visible_response !== null) throw new Error(JSON.stringify(report));
NODE

  cat > "$TMP_DIR/plan.json" <<JSON
{
  "feedback_id":"$feedback_id",
  "summary":"先补足人物选择的利益与代价，再局部重写当前段落。",
  "impact_level":"planning_and_prose",
  "affected_sections":[9],
  "evidence":["当前选择缺少可见代价"],
  "proposed_changes":["补入选择前的现实阻力","保持既有结局不变"]
}
JSON
  run node "$CLI" propose-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/plan.json" --json
  [ "$status" -eq 0 ]

  node "$CLI" show --project-root "$PROJECT" --workflow-id "$WFID" --json > "$TMP_DIR/show-plan.json"
  node - "$TMP_DIR/show-plan.json" "$TMP_DIR/accept.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const show = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.ok(show.interaction && show.interaction.binding);
assert.equal(Object.keys(show.interaction.binding).length, 4);
assert.match(show.interaction.text, /1\. 采用方案/);
assert.match(show.interaction.text, /2\. 继续讨论/);
assert.match(show.interaction.text, /3\. 查看依据/);
assert.match(show.interaction.text, /4\. 暂停并保存/);
fs.writeFileSync(process.argv[3], `${JSON.stringify({ ...show.interaction.binding, choice: '1' })}\n`);
NODE

  node "$CLI" resolve --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 3 --input-file "$TMP_DIR/accept.json" --json > "$TMP_DIR/accepted.json"
  node - "$TASK" "$feedback_id" <<'NODE'
const assert = require('assert');
const task = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
assert.equal(task.state_version, 4);
assert.equal(task.pending_feedback.id, process.argv[3]);
assert.equal(task.pending_feedback.status, 'accepted');
assert.equal(task.pending_feedback.accepted_plan.summary, '先补足人物选择的利益与代价，再局部重写当前段落。');
assert.equal(task.pending_feedback.decision.action_id, 'accept_feedback_plan');
assert.equal(task.current_stage, 'creative_entry');
NODE

  run node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-feedback-accepted" \
    --user-intent "查看当前进度" --write --compact --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"v3_feedback_plan_accepted"'* ]]
  [[ "$output" == *'"recommended_next":"apply_accepted_v3_feedback_plan"'* ]]

  cp "$TASK" "$TMP_DIR/before-execute-intent.json"
  run node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-feedback-execute" \
    --user-intent "完成已经接受的方案并继续当前阶段，不要重新生成方案。" --write --compact --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/execute-intent.json"
  node - "$TMP_DIR/execute-intent.json" "$TASK" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const [entryFile, taskFile] = process.argv.slice(2);
const entry = JSON.parse(fs.readFileSync(entryFile, 'utf8'));
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
assert.equal(entry.status, 'v3_feedback_plan_accepted');
assert.equal(entry.recommended_next, 'apply_accepted_v3_feedback_plan');
assert.equal(task.pending_feedback.status, 'accepted');
assert.equal(task.state_version, 4);
NODE
  cmp -s "$TASK" "$TMP_DIR/before-execute-intent.json"

  mkdir -p "$PROJECT/追踪/story-system/short" "$PROJECT/正文"
  printf '%s\n' '{"project_id":"neutral-revision","project_title":"中性回炉短篇","plan_revision":1,"planned_sections":9,"current_section_index":9,"accepted_sections":[{"section_index":8}]}' > "$PROJECT/追踪/story-system/short/project-state.json"
  printf '%s\n' '{"workflow_id":"neutral-prior","section_index":8,"status":"accepted","canonical_path":"正文/第008节.md","section_summary":"前序复核已经留下公开记录。","open_hook":"最后一项责任仍待落地。"}' > "$PROJECT/追踪/story-system/short/section-008-anchor.json"
  printf '%s\n' '# 第8节' '前序复核已经留下公开记录。' '最后一项责任仍待落地。' > "$PROJECT/正文/第008节.md"
  printf '%s\n' '# 素材卡' '以公开复核完成责任落地。' > "$PROJECT/素材卡.md"
  printf '%s\n' '# 设定' '第一人称，主角承担最终复核责任。' > "$PROJECT/设定.md"
  cat > "$PROJECT/小节大纲.md" <<'EOF'
# 小节大纲
## 第9节：责任落地
- 结构功能：结尾收束责任与公开承诺
- 情绪目标：压力转为承担
- 因果链：承接未决责任 -> 提交最终记录 -> 开放长期复核
- 承接上节：最后一项责任仍待落地
- 场景动作：主角在公开评审会上提交最终记录
- 角色选择：主角选择承担延期并开放复核
- 可见阻力：主管要求暂缓公开
- 本节兑现：最终记录进入公开档案
- 关系变化：双方保留分歧但接受同一核验标准
- 代价升级：主角承担延期后果
- 核心承诺兑现：全部记录可以追溯
- 决定性行动：主角签署公开复核申请
- 即时代价：原定交付被推迟
- 现实后果：原定交付延期，旧权限被收回
- 关系收束：双方保留分歧，不再用情面替代责任
- 结尾回扣：公开记录终于可以持续追溯
- 子事件：
  1. 主角提交最终记录
  2. 记录进入长期公开复核
- 节尾钩子：所有人都能继续核验记录
EOF
  node - "$TASK" <<'NODE'
const fs = require('fs');
const taskFile = process.argv[2];
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.current_stage = 'section_brief';
task.stage_execution = {
  status: 'running',
  stage_id: 'section_brief',
  stage_attempt_id: 'sa-neutral-section-brief',
  section_index: 9,
};
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE
  run node "$ENTRY" --project-root "$PROJECT" --session-id "test:v3-feedback-contract" \
    --user-intent "查看当前进度" --write --compact --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$TMP_DIR/accepted-contract.json"
  node - "$TMP_DIR/accepted-contract.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const entry = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(entry.status, 'v3_feedback_plan_accepted');
assert.equal(entry.presentation_allowed, false);
assert.equal(entry.stage_execution.selection_contract, 'resume_running_stage');
assert.deepEqual(entry.stage_execution.write_set, ['小节大纲.md', '写作Brief_第009节.md']);
assert.match(entry.stage_execution.context_read_command, /workflow-stage-context\.js read-current/);
assert.equal(entry.stage_execution.source_files.length, 1);
assert.match(entry.stage_execution.source_files[0], /context-packets\/section_brief\/.+\/stage-context\.md$/u);
assert.match(entry.stage_execution.stage_completion_command, /workflow-v3\.js run-current-stage/);
assert.match(entry.stage_execution.resume_hint, /已接受方案/);
NODE
}

@test "new Chat during feedback confirmation archives the prior proposal before replacing it" {
  create_task
  printf '%s\n' '{"text":"先调整人物动机。"}' > "$TMP_DIR/first.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 1 --input-file "$TMP_DIR/first.json" --json > "$TMP_DIR/first-out.json"
  feedback_id="$(node -e "process.stdout.write(JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).feedback_receipt.feedback_id)" "$TMP_DIR/first-out.json")"
  cat > "$TMP_DIR/plan.json" <<JSON
{"feedback_id":"$feedback_id","summary":"补足人物选择的现实代价。","impact_level":"planning","affected_sections":[1],"evidence":["动机证据不足"],"proposed_changes":["补足现实代价"]}
JSON
  node "$CLI" propose-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 2 --input-file "$TMP_DIR/plan.json" --json > "$TMP_DIR/plan-out.json"
  printf '%s\n' '{"text":"再补充：不要改变既定结局。"}' > "$TMP_DIR/second.json"
  node "$CLI" submit-feedback --project-root "$PROJECT" --workflow-id "$WFID" \
    --expected-version 3 --input-file "$TMP_DIR/second.json" --json > "$TMP_DIR/second-out.json"

  node - "$TASK" "$feedback_id" <<'NODE'
const assert = require('assert');
const task = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
assert.equal(task.state_version, 4);
assert.equal(task.feedback_history.length, 1);
assert.equal(task.feedback_history[0].id, process.argv[3]);
assert.equal(task.feedback_history[0].status, 'awaiting_confirmation');
assert.equal(task.feedback_history[0].proposed_plan.summary, '补足人物选择的现实代价。');
assert.equal(task.feedback_history[0].archive_reason, 'author_feedback_superseded_previous_plan');
assert.equal(task.pending_feedback.status, 'pending_analysis');
assert.equal(task.pending_feedback.messages[0].text, '再补充：不要改变既定结局。');
assert.notEqual(task.pending_feedback.id, process.argv[3]);
assert.equal(task.interaction_history.at(-1).feedback_id, process.argv[3]);
NODE
}
