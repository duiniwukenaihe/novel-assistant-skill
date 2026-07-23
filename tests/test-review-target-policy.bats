#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  POLICY="$REPO/scripts/lib/review-target-policy.js"
  PLANNER="$REPO/scripts/lib/review-batch-planner.js"
  WORKFLOW="$REPO/scripts/workflow-state-machine.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "resolves every lifecycle review target from author language" {
  run node - "$POLICY" <<'NODE'
const { resolveReviewTarget } = require(process.argv[2]);
const cases = [
  [{ text: '审阅总纲' }, 'master_outline'],
  [{ text: '审阅第一卷卷纲', volume: '第1卷' }, 'volume_outline'],
  [{ text: '审阅当前阶段细纲', stage: '高潮阶段' }, 'stage_detail_outline'],
  [{ text: '审阅第十章 Brief', chapter: '第10章' }, 'chapter_brief'],
  [{ text: '审阅当前正文', chapter: '第10章' }, 'prose_unit'],
  [{ text: '审阅当前阶段', stage: '高潮阶段' }, 'milestone'],
  [{ text: '审阅第一卷', volume: '第1卷' }, 'volume'],
  [{ text: '审阅全书' }, 'book'],
];
for (const [input, expected] of cases) {
  const target = resolveReviewTarget(input, {});
  if (target.kind !== expected) throw new Error(`${input.text}: ${JSON.stringify(target)}`);
  if (!target.visible_label.startsWith('审阅') || !target.narrative_scope) throw new Error(JSON.stringify(target));
}
NODE
  [ "$status" -eq 0 ]
}

@test "lifecycle state supplies an omitted review target" {
  run node - "$POLICY" <<'NODE'
const { resolveReviewTarget } = require(process.argv[2]);
const target = resolveReviewTarget({ text: '审阅当前资产' }, {
  current_node: 'volume_outline_review',
  asset_target: { kind: 'volume', id: '第2卷' },
});
if (target.kind !== 'volume_outline') throw new Error(JSON.stringify(target));
if (target.narrative_scope !== '第2卷卷纲') throw new Error(JSON.stringify(target));
NODE
  [ "$status" -eq 0 ]
}

@test "asset review reads only the target asset and upstream dependencies" {
  run node - "$POLICY" <<'NODE'
const { resolveReviewTarget, reviewEvidencePolicy } = require(process.argv[2]);
const target = resolveReviewTarget({ text: '审阅第2卷卷纲', volume: '第2卷' }, {});
const evidence = reviewEvidencePolicy(target);
if (evidence.mode !== 'asset_dependency_closure' || evidence.use_dynamic_batches) throw new Error(JSON.stringify(evidence));
if (evidence.user_visible_batches) throw new Error('internal batches leaked');
if (JSON.stringify(evidence.read_assets) !== JSON.stringify(['master_outline', 'volume_outline'])) throw new Error(JSON.stringify(evidence));
if (evidence.read_assets.some(kind => ['stage_detail_outline', 'chapter_brief', 'prose_unit'].includes(kind))) throw new Error(JSON.stringify(evidence));
NODE
  [ "$status" -eq 0 ]
}

@test "only prose stage volume and book reviews request internal dynamic batches" {
  run node - "$POLICY" <<'NODE'
const { reviewEvidencePolicy } = require(process.argv[2]);
const dynamic = new Set(['prose_unit', 'milestone', 'volume', 'book']);
const all = ['master_outline', 'volume_outline', 'stage_detail_outline', 'chapter_brief', ...dynamic];
for (const kind of all) {
  const evidence = reviewEvidencePolicy({ kind, visible_label: `审阅${kind}`, narrative_scope: kind });
  if (evidence.use_dynamic_batches !== dynamic.has(kind)) throw new Error(`${kind}: ${JSON.stringify(evidence)}`);
  if (evidence.user_visible_batches !== false) throw new Error(`${kind}: batches must remain internal`);
}
NODE
  [ "$status" -eq 0 ]
}

@test "batch planner accepts only dynamic review targets and marks its plan internal" {
  run node - "$PLANNER" <<'NODE'
const { planReviewBatches } = require(process.argv[2]);
const chapters = [{ chapterKey: 'c1', globalDraftOrder: 1, chars: 3000 }];
let rejected = false;
try {
  planReviewBatches({ chapters, parentScope: '1-1', reviewTarget: { kind: 'chapter_brief' } });
} catch (error) {
  rejected = error && error.code === 'REVIEW_TARGET_NOT_BATCHABLE';
}
if (!rejected) throw new Error('asset review entered dynamic batch planner');
const plan = planReviewBatches({ chapters, parentScope: '1-1', reviewTarget: { kind: 'prose_unit' } });
if (plan.visibility !== 'internal_only' || plan.user_visible_batches !== false) throw new Error(JSON.stringify(plan));
NODE
  [ "$status" -eq 0 ]
}

@test "volume review remains one user task while prose evidence is internally partitioned" {
  mkdir -p "$BOOK/正文/第1卷" "$BOOK/追踪"
  for chapter in 1 2; do
    printf '# 第%s章\n\n正文内容。\n' "$chapter" > "$BOOK/正文/第1卷/第${chapter}章.md"
  done
  cat > "$BOOK/追踪/章节索引.json" <<'JSON'
{"schemaVersion":"1.0.0","chapters":[
  {"chapterKey":"v1-c1","globalDraftOrder":1,"volume":"第1卷","path":"正文/第1卷/第1章.md"},
  {"chapterKey":"v1-c2","globalDraftOrder":2,"volume":"第1卷","path":"正文/第1卷/第2章.md"}
]}
JSON

  run node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --scope 1-2 --user-goal '审阅第一卷' --json
  [ "$status" -eq 0 ]

  node - "$BOOK/追踪/workflow/current-task.json" <<'NODE'
const task = require(process.argv[2]);
if (task.review_target.kind !== 'volume' || task.review_target.visible_label !== '审阅第一卷') throw new Error(JSON.stringify(task.review_target));
if (!task.review_evidence_policy.use_dynamic_batches || !task.review_batches) throw new Error('missing internal evidence plan');
const visible = JSON.stringify({
  question: task.pending_action.question,
  labels: task.pending_action.options.map(option => option.label),
  user_goal: task.user_goal,
  visible_label: task.review_target.visible_label,
  narrative_scope: task.review_target.narrative_scope,
});
if (/batch-|批\s*0*\d+|\b\d+\s*[-到至~]\s*\d+\b/.test(visible)) throw new Error(`internal slice leaked: ${visible}`);
NODE
}

@test "asset review creates no dynamic review plan" {
  run node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --user-goal '审阅总纲' --json
  [ "$status" -eq 0 ]

  node - "$BOOK/追踪/workflow/current-task.json" <<'NODE'
const task = require(process.argv[2]);
if (task.review_target.kind !== 'master_outline') throw new Error(JSON.stringify(task.review_target));
if (task.review_evidence_policy.mode !== 'asset_dependency_closure') throw new Error(JSON.stringify(task.review_evidence_policy));
if (task.review_batches || task.review_plan_path || task.review_plan_digest) throw new Error('asset review created dynamic batches');
NODE
}

@test "asset review evidence scan accepts dependency evidence without batch scope" {
  mkdir -p "$BOOK/大纲"
  printf '# 总纲\n' > "$BOOK/大纲/总纲.md"
  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --user-goal '审阅总纲' --json >/dev/null

  node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const current = path.join(root, '追踪/workflow/current-task.json');
const task = JSON.parse(fs.readFileSync(current, 'utf8'));
const packet = `${task.task_dir}/result-packets/evidence_scan.result.json`;
task.current_stage = 'evidence_scan';
task.current_step = 'evidence_scan';
task.stage_execution = {
  status: 'running',
  stage_id: 'evidence_scan',
  step_id: 'evidence_scan',
  expected_result_packet: packet,
};
task.runtime_guard.checkpoint_policy.expected_result_packet = packet;
const taskFile = path.join(root, task.task_dir, 'task.json');
fs.writeFileSync(current, `${JSON.stringify(task, null, 2)}\n`);
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
const receipt = {
  workflow_id: task.workflow_id,
  workflow_type: task.workflow_type,
  stage_id: 'evidence_scan',
  step_id: 'evidence_scan',
  step_status: 'completed',
  outputs: [],
  changed_files: [],
  evidence: [{ asset_kind: 'master_outline', source_ref: '大纲/总纲.md', status: 'read' }],
  verification_result: 'pass',
  checkpoint_state: { evidence_mode: 'asset_dependency_closure' },
  output_health_result: 'pass',
  result_packet_path: packet,
};
const packetFile = path.join(root, packet);
fs.mkdirSync(path.dirname(packetFile), { recursive: true });
fs.writeFileSync(packetFile, `${JSON.stringify(receipt, null, 2)}\n`);
NODE

  packet="$(node -e "const x=require(process.argv[1]);process.stdout.write(require('path').join(process.argv[2],x.stage_execution.expected_result_packet))" "$BOOK/追踪/workflow/current-task.json" "$BOOK")"
  run node "$WORKFLOW" apply-result --project-root "$BOOK" --result "$packet" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "advanced"'* ]]
  node - "$output" <<'NODE'
const out = JSON.parse(process.argv[2]);
const allowed = new Set(['schemaVersion', 'status', 'visible_label', 'narrative_scope', 'progress', 'next_user_action']);
const unexpected = Object.keys(out).filter(key => !allowed.has(key));
if (unexpected.length > 0) throw new Error(`asset apply leaked fields: ${unexpected.join(',')}`);
NODE
}

@test "asset evidence source must be a real in-project file for the expected target" {
  mkdir -p "$BOOK/大纲/第1卷" "$BOOK/大纲/第2卷"
  printf '# 总纲\n' > "$BOOK/大纲/总纲.md"
  printf '# 第一卷卷纲\n' > "$BOOK/大纲/第1卷/卷纲.md"
  printf '# 第二卷卷纲\n' > "$BOOK/大纲/第2卷/卷纲.md"

  run node - "$POLICY" "$BOOK" <<'NODE'
const { resolveReviewTarget, reviewEvidencePolicy, validateAssetDependencyEvidenceReceipt } = require(process.argv[2]);
const root = process.argv[3];
const policy = reviewEvidencePolicy(resolveReviewTarget({ text: '审阅第2卷卷纲', volume: '第2卷' }, {}));
const upstream = { asset_kind: 'master_outline', source_ref: '大纲/总纲.md' };
const missing = validateAssetDependencyEvidenceReceipt(policy, [
  upstream,
  { asset_kind: 'volume_outline', source_ref: '大纲/第2卷/不存在.md' },
], { project_root: root });
if (missing.valid) throw new Error('missing source_ref was accepted');
const wrongTarget = validateAssetDependencyEvidenceReceipt(policy, [
  upstream,
  { asset_kind: 'volume_outline', source_ref: '大纲/第1卷/卷纲.md' },
], { project_root: root });
if (wrongTarget.valid) throw new Error('evidence for the wrong review target was accepted');
const valid = validateAssetDependencyEvidenceReceipt(policy, [
  upstream,
  { asset_kind: 'volume_outline', source_ref: '大纲/第2卷/卷纲.md' },
], { project_root: root });
if (!valid.valid) throw new Error(JSON.stringify(valid));
NODE
  [ "$status" -eq 0 ]
}

@test "running review target attaches to the existing task without pausing it" {
  mkdir -p "$BOOK/正文/第1卷" "$BOOK/追踪"
  printf '# 第一章\n\n正文。\n' > "$BOOK/正文/第1卷/第1章.md"
  cat > "$BOOK/追踪/章节索引.json" <<'JSON'
{"schemaVersion":"1.0.0","chapters":[
  {"chapterKey":"v1-c1","globalDraftOrder":1,"volume":"第1卷","path":"正文/第1卷/第1章.md"}
]}
JSON

  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --scope 1-1 --user-goal '审阅第一卷' --json > "$TMP_DIR/first.json"
  node - "$WORKFLOW" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const [script, root] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const pending = task.pending_action;
const out = cp.spawnSync(process.execPath, [script, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash,
  '--state-version', String(task.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
if (out.status) throw new Error(out.stdout || out.stderr);
NODE
  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --scope 1-1 --user-goal '审阅第一卷' --json > "$TMP_DIR/second.json"

  node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const [firstFile, secondFile, root] = process.argv.slice(2);
const first = JSON.parse(fs.readFileSync(firstFile, 'utf8'));
const second = JSON.parse(fs.readFileSync(secondFile, 'utf8'));
const current = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const taskFiles = fs.readdirSync(path.join(root, '追踪/workflow/tasks')).filter(name => name.startsWith('wf-'));
if (second.status !== 'attached_existing_family') throw new Error(JSON.stringify(second));
if (second.task.workflow_id !== first.task.workflow_id || current.workflow_id !== first.task.workflow_id) throw new Error('review task was replaced');
if (current.stage_execution.status !== 'running') throw new Error(JSON.stringify(current.stage_execution));
if (taskFiles.length !== 1) throw new Error(`duplicate review tasks: ${taskFiles.join(',')}`);
NODE
}

@test "review target without scope reuses its running family head" {
  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --user-goal '审阅总纲' --json > "$TMP_DIR/first.json"
  node - "$WORKFLOW" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const [script, root] = process.argv.slice(2);
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const pending = task.pending_action;
const out = cp.spawnSync(process.execPath, [script, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash,
  '--state-version', String(task.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
if (out.status) throw new Error(out.stdout || out.stderr);
NODE
  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --user-goal '审阅总纲' --json > "$TMP_DIR/second.json"

  node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const [firstFile, secondFile, root] = process.argv.slice(2);
const first = JSON.parse(fs.readFileSync(firstFile, 'utf8'));
const second = JSON.parse(fs.readFileSync(secondFile, 'utf8'));
const current = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const taskFiles = fs.readdirSync(path.join(root, '追踪/workflow/tasks')).filter(name => name.startsWith('wf-'));
if (second.status !== 'attached_existing_family') throw new Error(JSON.stringify(second));
if (second.task.workflow_id !== first.task.workflow_id || current.workflow_id !== first.task.workflow_id) throw new Error('review task was replaced');
if (current.stage_execution.status !== 'running') throw new Error(JSON.stringify(current.stage_execution));
if (taskFiles.length !== 1) throw new Error(`duplicate review tasks: ${taskFiles.join(',')}`);
NODE
}

@test "review repair later-stage apply uses the same public projection" {
  mkdir -p "$BOOK/大纲"
  printf '# 总纲\n' > "$BOOK/大纲/总纲.md"
  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --user-goal '审阅总纲' --json >/dev/null

  node - "$WORKFLOW" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const [script, root] = process.argv.slice(2);
function readTask() { return JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8')); }
function apply(body) {
  const task = readTask();
  const packet = task.stage_execution.expected_result_packet;
  const file = path.join(root, packet);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ workflow_id: task.workflow_id, workflow_type: task.workflow_type,
    stage_id: task.current_stage, step_id: task.current_step, step_status: 'completed', outputs: [], changed_files: [],
    evidence: [], verification_result: 'pass', checkpoint_state: {}, output_health_result: 'pass',
    result_packet_path: packet, ...body }, null, 2)}\n`);
  const out = cp.spawnSync(process.execPath, [script, 'apply-result', '--project-root', root, '--result', file, '--json'], { encoding: 'utf8' });
  if (out.status) throw new Error(out.stdout || out.stderr);
  return JSON.parse(out.stdout);
}
let task = readTask();
let pending = task.pending_action;
let resolved = cp.spawnSync(process.execPath, [script, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash,
  '--state-version', String(task.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
if (resolved.status) throw new Error(resolved.stdout || resolved.stderr);
apply({});
task = readTask(); pending = task.pending_action;
resolved = cp.spawnSync(process.execPath, [script, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash,
  '--state-version', String(task.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
if (resolved.status) throw new Error(resolved.stdout || resolved.stderr);
apply({ evidence: [{ asset_kind: 'master_outline', source_ref: '大纲/总纲.md' }] });
task = readTask(); pending = task.pending_action;
resolved = cp.spawnSync(process.execPath, [script, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash,
  '--state-version', String(task.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
if (resolved.status) throw new Error(resolved.stdout || resolved.stderr);
const out = apply({});
const allowed = new Set(['schemaVersion', 'status', 'visible_label', 'narrative_scope', 'progress', 'next_user_action']);
const unexpected = Object.keys(out).filter(key => !allowed.has(key));
if (unexpected.length > 0) throw new Error(`later-stage apply leaked fields: ${unexpected.join(',')}`);
NODE
}

@test "apply result exposes review target progress but keeps batch continuation private" {
  mkdir -p "$BOOK/正文/第1卷" "$BOOK/追踪"
  for chapter in 1 2; do
    { printf '# 第%s章\n\n' "$chapter"; head -c 7000 /dev/zero | tr '\0' '文'; printf '\n'; } > "$BOOK/正文/第1卷/第${chapter}章.md"
  done
  cat > "$BOOK/追踪/章节索引.json" <<'JSON'
{"schemaVersion":"1.0.0","chapters":[
  {"chapterKey":"v1-c1","globalDraftOrder":1,"volume":"第1卷","path":"正文/第1卷/第1章.md"},
  {"chapterKey":"v1-c2","globalDraftOrder":2,"volume":"第1卷","path":"正文/第1卷/第2章.md"}
]}
JSON

  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --scope 1-2 --user-goal '审阅第一卷' --json >/dev/null
  node - "$WORKFLOW" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const [script, root] = process.argv.slice(2);
function task() { return JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8')); }
function resolve() {
  const current = task(); const pending = current.pending_action;
  const out = cp.spawnSync(process.execPath, [script, 'resolve-action', '--project-root', root, '--input', '1',
    '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash,
    '--state-version', String(current.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
  if (out.status) throw new Error(out.stdout || out.stderr);
}
function applySimple() {
  const current = task(); const packet = current.stage_execution.expected_result_packet;
  const body = { workflow_id: current.workflow_id, workflow_type: current.workflow_type,
    stage_id: current.current_stage, step_id: current.current_step, step_status: 'completed',
    outputs: [], changed_files: [], evidence: [], verification_result: 'pass', checkpoint_state: {},
    output_health_result: 'pass', result_packet_path: packet };
  const file = path.join(root, packet); fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(body, null, 2)}\n`);
  const out = cp.spawnSync(process.execPath, [script, 'apply-result', '--project-root', root, '--result', file, '--json'], { encoding: 'utf8' });
  if (out.status) throw new Error(out.stdout || out.stderr);
}
resolve(); applySimple(); resolve();
NODE

  batch_scope="$(node -e "const x=require(process.argv[1]);process.stdout.write(x.stage_execution.batch_scope)" "$BOOK/追踪/workflow/current-task.json")"
  scan_json="$(node "$REPO/scripts/review-batch-evidence-scan.js" --project-root "$BOOK" --range "$batch_scope" --json)"
  node - "$BOOK" "$scan_json" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const scan = JSON.parse(process.argv[3]);
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const packet = { workflow_id: task.workflow_id, workflow_type: task.workflow_type,
  stage_id: 'evidence_scan', step_id: 'evidence_scan', step_status: 'completed',
  batch_id: task.stage_execution.batch_id, batch_scope: task.stage_execution.batch_scope,
  protocolVersion: scan.protocolVersion, sourceDigest: scan.sourceDigest, fullRangeCoverage: scan.fullRangeCoverage,
  outputs: [], changed_files: [], evidence: [], verification_result: 'pass', checkpoint_state: {},
  output_health_result: 'pass', result_packet_path: task.stage_execution.expected_result_packet };
const file = path.join(root, packet.result_packet_path);
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, `${JSON.stringify(packet, null, 2)}\n`);
NODE
  packet="$(node -e "const path=require('path'),x=require(process.argv[1]);process.stdout.write(path.join(process.argv[2],x.stage_execution.expected_result_packet))" "$BOOK/追踪/workflow/current-task.json" "$BOOK")"
  node "$WORKFLOW" apply-result --project-root "$BOOK" --result "$packet" --json > "$TMP_DIR/apply.json"

  node - "$TMP_DIR/apply.json" "$BOOK/追踪/workflow/current-task.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const task = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const visible = JSON.stringify(out);
if (!visible.includes('审阅第一卷') || !/50%/.test(visible)) throw new Error(`missing visible progress: ${visible}`);
for (const key of ['completed_batch_id', 'next_batch_id', 'next_command', 'expected_result_packet', 'remaining_batch_ranges']) {
  if (Object.prototype.hasOwnProperty.call(out, key)) throw new Error(`public JSON leaked ${key}: ${visible}`);
}
if (/batch-\d+|1-1|2-2|result-packets/.test(visible)) throw new Error(`internal continuation leaked: ${visible}`);
if (task.stage_execution.batch_id !== '002' || task.stage_execution.batch_scope !== '2-2') throw new Error('internal batch cursor missing');
if (!task.stage_execution.expected_result_packet || !task.runtime_guard.checkpoint_policy.resume_from.includes('batch-002')) throw new Error('internal continuation metadata missing');
NODE
}

@test "final dynamic review evidence batch exposes only the work-level advance summary" {
  mkdir -p "$BOOK/正文/第1卷" "$BOOK/追踪"
  { printf '# 第1章\n\n'; head -c 7000 /dev/zero | tr '\0' '文'; printf '\n'; } > "$BOOK/正文/第1卷/第1章.md"
  cat > "$BOOK/追踪/章节索引.json" <<'JSON'
{"schemaVersion":"1.0.0","chapters":[
  {"chapterKey":"v1-c1","globalDraftOrder":1,"volume":"第1卷","path":"正文/第1卷/第1章.md"}
]}
JSON

  node "$WORKFLOW" create --project-root "$BOOK" --workflow-type review_repair --scope 1-1 --user-goal '审阅第一卷' --json >/dev/null
  node - "$WORKFLOW" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const [script, root] = process.argv.slice(2);
function task() { return JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8')); }
function resolve() {
  const current = task(); const pending = current.pending_action;
  const out = cp.spawnSync(process.execPath, [script, 'resolve-action', '--project-root', root, '--input', '1',
    '--pending-action-id', pending.id, '--visible-choice-hash', pending.visible_choice_hash,
    '--state-version', String(current.state_version), '--book-root', root, '--json'], { encoding: 'utf8' });
  if (out.status) throw new Error(out.stdout || out.stderr);
}
function applySimple() {
  const current = task(); const packet = current.stage_execution.expected_result_packet;
  const body = { workflow_id: current.workflow_id, workflow_type: current.workflow_type,
    stage_id: current.current_stage, step_id: current.current_step, step_status: 'completed',
    outputs: [], changed_files: [], evidence: [], verification_result: 'pass', checkpoint_state: {},
    output_health_result: 'pass', result_packet_path: packet };
  const file = path.join(root, packet); fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(body, null, 2)}\n`);
  const out = cp.spawnSync(process.execPath, [script, 'apply-result', '--project-root', root, '--result', file, '--json'], { encoding: 'utf8' });
  if (out.status) throw new Error(out.stdout || out.stderr);
}
resolve(); applySimple(); resolve();
NODE

  batch_scope="$(node -e "const x=require(process.argv[1]);process.stdout.write(x.stage_execution.batch_scope)" "$BOOK/追踪/workflow/current-task.json")"
  scan_json="$(node "$REPO/scripts/review-batch-evidence-scan.js" --project-root "$BOOK" --range "$batch_scope" --json)"
  node - "$BOOK" "$scan_json" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const scan = JSON.parse(process.argv[3]);
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const packet = { workflow_id: task.workflow_id, workflow_type: task.workflow_type,
  stage_id: 'evidence_scan', step_id: 'evidence_scan', step_status: 'completed',
  batch_id: task.stage_execution.batch_id, batch_scope: task.stage_execution.batch_scope,
  protocolVersion: scan.protocolVersion, sourceDigest: scan.sourceDigest, fullRangeCoverage: scan.fullRangeCoverage,
  outputs: [], changed_files: [], evidence: [], verification_result: 'pass', checkpoint_state: {},
  output_health_result: 'pass', result_packet_path: task.stage_execution.expected_result_packet };
const file = path.join(root, packet.result_packet_path);
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, `${JSON.stringify(packet, null, 2)}\n`);
NODE
  packet="$(node -e "const path=require('path'),x=require(process.argv[1]);process.stdout.write(path.join(process.argv[2],x.stage_execution.expected_result_packet))" "$BOOK/追踪/workflow/current-task.json" "$BOOK")"
  run node "$WORKFLOW" apply-result --project-root "$BOOK" --result "$packet" --json
  [ "$status" -eq 0 ]

  node - "$output" <<'NODE'
const out = JSON.parse(process.argv[2]);
const allowed = new Set(['schemaVersion', 'status', 'visible_label', 'narrative_scope', 'progress', 'next_user_action']);
const unexpected = Object.keys(out).filter(key => !allowed.has(key));
if (out.status !== 'advanced') throw new Error(JSON.stringify(out));
if (out.visible_label !== '审阅第一卷' || out.narrative_scope !== '第一卷') throw new Error(JSON.stringify(out));
if (out.progress !== '100%' || !out.next_user_action) throw new Error(JSON.stringify(out));
if (unexpected.length > 0) throw new Error(`unexpected public fields: ${unexpected.join(',')}`);
const visible = JSON.stringify(out);
if (/review_batches|batch-|\brange\b|result-packets|"task"/.test(visible)) throw new Error(`internal review state leaked: ${visible}`);
NODE
}
