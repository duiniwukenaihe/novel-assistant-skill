#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE="$REPO/scripts/workflow-state-machine.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "every workflow stage exports an explicit split memory contract" {
    node "$STATE" templates --no-private-registry --json > "$TMP_DIR/templates.json"

    node - "$TMP_DIR/templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const allowedReadModes = new Set(['required', 'optional', 'none']);
const allowedContextSources = new Set(['story_memory', 'stage_context', 'none']);
const allowedUpdateModes = new Set(['suggest', 'none']);
const allowedProjectionModes = new Set(['after_accept', 'none']);

for (const template of data.templates || []) {
  for (const stage of template.stages || []) {
    const contract = stage.memory_contract;
    if (!contract) throw new Error(`${template.workflow_type}.${stage.stage_id} missing memory_contract`);
    if (!allowedReadModes.has(contract.read_mode)) throw new Error(`${template.workflow_type}.${stage.stage_id} invalid read_mode`);
    if (!allowedContextSources.has(contract.context_source)) throw new Error(`${template.workflow_type}.${stage.stage_id} invalid context_source`);
    if (!allowedUpdateModes.has(contract.update_mode)) throw new Error(`${template.workflow_type}.${stage.stage_id} invalid update_mode`);
    if (!allowedProjectionModes.has(contract.projection_mode)) throw new Error(`${template.workflow_type}.${stage.stage_id} invalid projection_mode`);
    if (!String(contract.profile || '')) throw new Error(`${template.workflow_type}.${stage.stage_id} missing profile`);
    if (!Array.isArray(contract.needs)) throw new Error(`${template.workflow_type}.${stage.stage_id} missing typed needs`);
    if (contract.read_mode === 'required' && contract.receipt_required !== true) {
      throw new Error(`${template.workflow_type}.${stage.stage_id} required memory must require receipt`);
    }
    if (contract.read_mode === 'none' && (contract.receipt_required !== false || contract.context_source !== 'none')) {
      throw new Error(`${template.workflow_type}.${stage.stage_id} no-memory contract is inconsistent`);
    }
  }
}
NODE
}

@test "runtime resolves memory policy from the active stage contract" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const { BASE_TEMPLATES } = require(path.join(repo, 'scripts/lib/workflow-template-registry.js'));
const { resolveStageMemoryPolicy } = require(path.join(repo, 'scripts/lib/workflow-memory-policy.js'));

const prose = resolveStageMemoryPolicy(BASE_TEMPLATES.short_write, 'draft_section');
if (prose.mode !== 'required' || prose.context_source !== 'stage_context') throw new Error(JSON.stringify(prose));
if (prose.update_mode !== 'suggest' || prose.projection_mode !== 'after_accept') throw new Error(JSON.stringify(prose));
if (prose.receipt_required !== true || !Array.isArray(prose.needs) || prose.needs.length === 0) throw new Error(JSON.stringify(prose));

const machineGate = resolveStageMemoryPolicy(BASE_TEMPLATES.short_write, 'section_machine_gate');
if (machineGate.mode !== 'none' || machineGate.context_source !== 'none') throw new Error(JSON.stringify(machineGate));
if (machineGate.update_mode !== 'none' || machineGate.projection_mode !== 'none' || machineGate.receipt_required !== false) {
  throw new Error(JSON.stringify(machineGate));
}

const assembly = resolveStageMemoryPolicy(BASE_TEMPLATES.short_write, 'full_story_assembly');
if (assembly.mode !== 'none' || assembly.context_source !== 'none') throw new Error(JSON.stringify(assembly));
if (assembly.update_mode !== 'none' || assembly.projection_mode !== 'none' || assembly.receipt_required !== false) {
  throw new Error(JSON.stringify(assembly));
}

const fullReview = resolveStageMemoryPolicy(BASE_TEMPLATES.short_write, 'full_story_review');
if (fullReview.mode !== 'required' || fullReview.context_source !== 'stage_context') throw new Error(JSON.stringify(fullReview));
if (fullReview.token_budget !== 0 || fullReview.receipt_required !== true) throw new Error(JSON.stringify(fullReview));

for (const stageId of ['deslop', 'final_check']) {
  const deterministic = resolveStageMemoryPolicy(BASE_TEMPLATES.short_write, stageId);
  if (deterministic.mode !== 'none' || deterministic.context_source !== 'none') throw new Error(`${stageId}: ${JSON.stringify(deterministic)}`);
}

const setup = resolveStageMemoryPolicy(BASE_TEMPLATES.setup_update, 'version_check');
if (setup.mode !== 'none' || setup.context_source !== 'none') throw new Error(JSON.stringify(setup));
if (setup.update_mode !== 'none' || setup.projection_mode !== 'none' || setup.receipt_required !== false) throw new Error(JSON.stringify(setup));
NODE
}

@test "stage execution policy and stage packet memory context keep one contract" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const { resolveExecutionMemoryPolicy } = require(path.join(repo, 'scripts/lib/workflow-memory-policy.js'));
const { memoryContextFromStagePacket } = require(path.join(repo, 'scripts/lib/workflow-memory-context.js'));

const contract = {
  read_mode: 'required', context_source: 'stage_context', profile: 'short_write.draft_section',
  needs: ['accepted_facts'], token_budget: 0, budget_policy: 'stage_context_adaptive',
  receipt_required: true, update_mode: 'suggest', projection_mode: 'after_accept',
};
const policy = resolveExecutionMemoryPolicy({ memory_contract: contract });
const memoryContract = { contract_digest: 'sha256:contract', memory_revision: 'sha256:memory' };
const memoryReceipt = { contract_digest: 'sha256:contract', memory_revision: 'sha256:memory' };
const context = memoryContextFromStagePacket(policy, {
  status: 'assembled', packet_md: 'context.md', packet_json: 'context.json', estimated_tokens: 321,
  memory_contract: memoryContract, memory_read_receipt: memoryReceipt,
});
if (context.status !== 'assembled' || context.context_source !== 'stage_context') throw new Error(JSON.stringify(context));
if (context.packet_md !== 'context.md' || context.estimated_tokens !== 321) throw new Error(JSON.stringify(context));
if (context.memory_contract !== memoryContract || context.memory_read_receipt !== memoryReceipt) throw new Error('stage packet memory identity was not preserved');
NODE
}

@test "required memory projection failure creates replayable debt and blocks advancement" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const { memoryProjectionAdvanceDecision } = require(path.join(repo, 'scripts/lib/workflow-memory-updates.js'));

const required = { projection_mode: 'after_accept', update_mode: 'suggest' };
const failed = memoryProjectionAdvanceDecision(required, { status: 'projection_failed', detail: 'write failed' });
if (failed.can_advance !== false) throw new Error(JSON.stringify(failed));
if (failed.task_status !== 'accepted_pending_projection') throw new Error(JSON.stringify(failed));
if (failed.retry_without_model !== true) throw new Error(JSON.stringify(failed));

for (const status of ['projected', 'projected_with_domain_quarantine', 'confirmation_required', 'no_updates', 'not_applicable']) {
  const accepted = memoryProjectionAdvanceDecision(required, { status });
  if (accepted.can_advance !== true) throw new Error(`${status}: ${JSON.stringify(accepted)}`);
}

const disabled = memoryProjectionAdvanceDecision({ projection_mode: 'none', update_mode: 'none' }, { status: 'projection_failed' });
if (disabled.can_advance !== true) throw new Error(JSON.stringify(disabled));
NODE
}

@test "managed review cannot silently omit accepted story memory" {
    node - "$REPO" "$TMP_DIR" <<'NODE'
const path = require('path');
const [repo, root] = process.argv.slice(2);
const { projectAcceptedMemoryUpdates } = require(path.join(repo, 'scripts/lib/workflow-memory-updates.js'));
const task = { workflow_id: 'wf-memory-audit', workflow_type: 'long_write', task_dir: '追踪/workflow/tasks/wf-memory-audit' };
const execution = { stage_id: 'brief_review', stage_attempt_id: 'sa-brief-review', review_requirement: { required: true }, memory_contract: { read_mode: 'required', context_source: 'story_memory', update_mode: 'suggest', projection_mode: 'after_accept' } };
const base = { host_execution_mode: 'managed_runner', runner_packet_path: `${task.task_dir}/runner-packets/brief_review.run.json`, memory_updates: [] };
const missingReason = projectAcceptedMemoryUpdates(root, task, execution, base);
if (missingReason.status !== 'projection_failed') throw new Error(JSON.stringify(missingReason));
const justified = projectAcceptedMemoryUpdates(root, task, execution, { ...base, memory_update_omission_reason: '本次只复核既有约束，没有确认新事实或新增承诺。' });
if (justified.status !== 'no_updates') throw new Error(JSON.stringify(justified));
const drift = projectAcceptedMemoryUpdates(root, task, execution, { ...base, memory_update_omission_reason: '无新增', evidence: [{ kind: 'planning_tension_note', summary: '发现待后续处理的规划漂移。' }] });
if (drift.status !== 'projection_failed') throw new Error(JSON.stringify(drift));
NODE
}

@test "accepted memory projection separates current suggestions from historical confirmations" {
  node - "$REPO" "$TMP_DIR" <<'NODE'
const fs=require('fs'),path=require('path');
const repo=process.argv[2],root=process.argv[3];
const {projectAcceptedMemoryUpdates}=require(path.join(repo,'scripts/lib/workflow-memory-updates.js'));
const memoryDir=path.join(root,'追踪/memory');fs.mkdirSync(memoryDir,{recursive:true});
fs.writeFileSync(path.join(memoryDir,'memory-suggestions.jsonl'),JSON.stringify({suggestionId:'sg-old',action:'update',entryId:'char.old',type:'character',risk:'high',reason:'历史待确认',proposedContent:'历史角色状态变更。',sourceKind:'user_confirmed',accepted_artifact_id:'sa-old',sourceRefs:[],affects:['review'],status:'pending',createdAt:'2026-08-01T00:00:00Z'})+'\n');
const task={workflow_id:'wf-scoped-memory',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-scoped-memory'};
const execution={stage_id:'milestone_review',stage_attempt_id:'sa-current',owner_module:'story-review',review_requirement:{required:true,failure_return:'chapter_commit'},memory_contract:{read_mode:'required',update_mode:'suggest',projection_mode:'after_accept'}};
const result={stage_id:'milestone_review',host_execution_mode:'managed_runner',runner_packet_path:'runner.json',memory_updates:[{action:'create',entryId:'fact.current',type:'fact',risk:'low',reason:'本轮稳定事实',proposedContent:'本轮里程碑已经闭合。',sourceKind:'user_confirmed',accepted_artifact_id:'sa-current',sourceRefs:[],affects:['review']}]};
const projection=projectAcceptedMemoryUpdates(root,task,execution,result);
if(projection.recorded!==1||projection.applied!==1||projection.confirmation_required!==0||projection.pending_confirmation_total!==1) throw new Error(JSON.stringify(projection));
NODE
}

@test "longform lifecycle transition request cannot bypass the stage graph" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const { validateLifecycleTransitionRequest } = require(path.join(repo, 'scripts/lib/workflow-transition-service.js'));
const stage = {
  stage_id: 'prose_acceptance',
  allowed_next: ['prose', 'chapter_brief', 'chapter_commit'],
  review_requirement: { required: true, failure_return: 'prose' },
  transition_contract: { failure_returns: ['prose', 'chapter_brief'] },
};

const advance = validateLifecycleTransitionRequest(stage, 'prose_acceptance', {
  step_status: 'completed', verification_result: 'pass',
  lifecycle_transition_request: { action: 'advance', target: 'chapter_commit' },
});
if (advance.status !== 'valid' || advance.requested_next !== 'chapter_commit') throw new Error(JSON.stringify(advance));

const legacy = validateLifecycleTransitionRequest(stage, 'prose_acceptance', {
  step_status: 'completed', verification_result: 'pass',
  lifecycle_transition_request: { action: 'advance', target: 'prose_acceptance' },
});
if (legacy.status !== 'valid' || legacy.requested_next !== '') throw new Error(JSON.stringify(legacy));

const rollback = validateLifecycleTransitionRequest(stage, 'prose_acceptance', {
  step_status: 'blocked', verification_result: 'rejected',
  lifecycle_transition_request: { action: 'return', target: 'prose' },
});
if (rollback.status !== 'valid' || rollback.requested_next !== 'prose') throw new Error(JSON.stringify(rollback));

const upstreamRollback = validateLifecycleTransitionRequest(stage, 'prose_acceptance', {
  step_status: 'blocked', verification_result: 'rejected', next_stage_id: 'chapter_brief',
  lifecycle_transition_request: { action: 'return', target: 'chapter_brief' },
});
if (upstreamRollback.status !== 'valid' || upstreamRollback.requested_next !== 'chapter_brief') throw new Error(JSON.stringify(upstreamRollback));

const conflictingRollback = validateLifecycleTransitionRequest(stage, 'prose_acceptance', {
  step_status: 'blocked', verification_result: 'rejected', next_stage_id: 'prose',
  lifecycle_transition_request: { action: 'return', target: 'chapter_brief' },
});
if (conflictingRollback.status !== 'invalid' || conflictingRollback.code !== 'lifecycle_transition_target_conflict') throw new Error(JSON.stringify(conflictingRollback));

for (const request of [
  { action: 'advance', target: 'volume_acceptance' },
  { action: 'return', target: 'story_bible' },
  { action: 'teleport', target: 'chapter_commit' },
]) {
  const invalid = validateLifecycleTransitionRequest(stage, 'prose_acceptance', {
    step_status: 'completed', verification_result: 'pass', lifecycle_transition_request: request,
  });
  if (invalid.status !== 'invalid') throw new Error(JSON.stringify(invalid));
}
NODE
}

@test "longform prose acceptance publishes scoped upstream failure returns without changing legacy review authority" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const { BASE_TEMPLATES } = require(path.join(repo, 'scripts/lib/workflow-template-registry.js'));
const stage = BASE_TEMPLATES.long_write.stages.find((item) => item.stage_id === 'prose_acceptance');
if (JSON.stringify(stage.review_requirement) !== JSON.stringify({ required: true, failure_return: 'prose' })) throw new Error(JSON.stringify(stage.review_requirement));
if (JSON.stringify(stage.transition_contract.failure_returns) !== JSON.stringify(['prose', 'chapter_brief'])) throw new Error(JSON.stringify(stage.transition_contract));
if (!stage.allowed_next.includes('chapter_brief')) throw new Error(JSON.stringify(stage.allowed_next));
NODE
}

@test "interactive long stage persists a verifiable memory context receipt" {
    project="$TMP_DIR/long-book"
    mkdir -p "$project"
    node "$STATE" create --workflow-type long_write --project-root "$project" --user-goal "开一本新书" --json >/dev/null

    node - "$STATE" "$project" <<'NODE'
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const state = process.argv[2];
const root = process.argv[3];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const taskFile = path.join(root, pointer.task_dir, 'task.json');
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
const pending = task.pending_action || {};
const run = spawnSync(process.execPath, [state, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', String(pending.pending_action_id || pending.id || ''),
  '--visible-choice-hash', String(pending.visible_choice_hash || ''),
  '--state-version', String(pending.state_version || task.state_version || ''),
  '--book-root', String(pending.book_root || '.'), '--json'], { encoding: 'utf8' });
if (run.status !== 0) throw new Error(run.stdout || run.stderr);
const current = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
const execution = current.stage_execution || {};
const memory = execution.memory_context || {};
if (execution.status !== 'running') throw new Error(JSON.stringify(execution));
if (memory.status !== 'assembled' || !memory.memory_contract || !memory.memory_read_receipt) throw new Error(JSON.stringify(memory));
if (!String(execution.context_read_command || '').includes('workflow-stage-context.js read-current')) throw new Error(JSON.stringify(execution));
NODE
}

@test "every workflow declares task shape repeat impact and interaction contracts" {
    node "$STATE" templates --no-private-registry --json > "$TMP_DIR/scheduling.json"
    node - "$TMP_DIR/scheduling.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const forms = new Set(['single_unit', 'linear_pipeline', 'bounded_loop', 'map_reduce', 'dependency_dag', 'long_running_family']);
for (const template of data.templates || []) {
  const scheduling = template.scheduling_contract || {};
  if (!forms.has(scheduling.task_form)) throw new Error(`${template.workflow_type} missing task_form`);
  if (!scheduling.unit_identity || !scheduling.repeat_policy || !scheduling.impact_policy || !scheduling.concurrency_policy) {
    throw new Error(`${template.workflow_type} incomplete scheduling contract`);
  }
  for (const stage of template.stages || []) {
    if (!stage.transition_contract || !Array.isArray(stage.transition_contract.allowed_next)) throw new Error(`${template.workflow_type}.${stage.stage_id} missing transition contract`);
    if (!stage.interaction_contract || stage.interaction_contract.menu_style !== 'numbered_1_4') throw new Error(`${template.workflow_type}.${stage.stage_id} missing interaction contract`);
    if (stage.interaction_contract.expose_as_top_level_task !== false) throw new Error(`${template.workflow_type}.${stage.stage_id} leaks substage as a task`);
  }
}
NODE
}

@test "created long task and running stage persist the scheduling contract" {
    project="$TMP_DIR/scheduled-book"
    mkdir -p "$project"
    node "$STATE" create --workflow-type long_write --project-root "$project" --user-goal "续写当前长篇" --json >/dev/null

    node - "$STATE" "$project" <<'NODE'
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const state = process.argv[2];
const root = process.argv[3];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const taskFile = path.join(root, pointer.task_dir, 'task.json');
let task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
if ((task.scheduling_contract || {}).task_form !== 'bounded_loop') throw new Error(JSON.stringify(task.scheduling_contract));
const pending = task.pending_action || {};
const run = spawnSync(process.execPath, [state, 'resolve-action', '--project-root', root, '--input', '1',
  '--pending-action-id', String(pending.pending_action_id || pending.id || ''),
  '--visible-choice-hash', String(pending.visible_choice_hash || ''),
  '--state-version', String(pending.state_version || task.state_version || ''),
  '--book-root', String(pending.book_root || '.'), '--json'], { encoding: 'utf8' });
if (run.status !== 0) throw new Error(run.stdout || run.stderr);
task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
const execution = task.stage_execution || {};
if ((execution.scheduling_contract || {}).task_form !== 'bounded_loop') throw new Error(JSON.stringify(execution));
if (((execution.interaction_contract || {}).expose_as_top_level_task) !== false) throw new Error(JSON.stringify(execution));
if (!Array.isArray(((execution.transition_contract || {}).allowed_next))) throw new Error(JSON.stringify(execution));
if (!String(execution.work_unit_id || '') || Number(execution.attempt_no || 0) !== 1) throw new Error(JSON.stringify(execution));
if (execution.repeat_scope !== 'current_unit_only') throw new Error(JSON.stringify(execution));
NODE
}

@test "generic task overview shows parent workflow before its current substage" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const { BASE_TEMPLATES } = require(path.join(repo, 'scripts/lib/workflow-template-registry.js'));
const { buildWorkflowTaskOverview } = require(path.join(repo, 'scripts/lib/workflow-action-renderer.js'));
const tpl = BASE_TEMPLATES.long_write;
const task = {
  workflow_id: 'wf-long', workflow_type: 'long_write', user_goal: '完成当前长篇', current_stage: 'chapter_brief',
  machine: { completed_stages: ['positioning', 'story_bible', 'master_outline'], remaining_stages: tpl.stages.map(item => item.stage_id) },
  unit_lifecycle: { stage_roles: (tpl.unit_lifecycle_contract || {}).stage_roles || {} },
  scheduling_contract: tpl.scheduling_contract,
};
const overview = buildWorkflowTaskOverview(task, tpl);
if (!overview || overview.task_title !== '完成当前长篇') throw new Error(JSON.stringify(overview));
if (!overview.current_subtask || overview.current_subtask.id !== 'chapter_brief') throw new Error(JSON.stringify(overview));
if (!Array.isArray(overview.phases) || overview.phases.length < 2) throw new Error(JSON.stringify(overview));
if (!overview.text.includes('当前阶段') || !overview.text.includes('任务阶段')) throw new Error(overview.text);
for (const label of ['故事核心', '总纲', '卷纲', '阶段细纲', '章节 Brief', '正文与验收', '人物 / 伏笔 / 时间线提交', '复盘与跨卷交接']) {
  if (!overview.phases.some(phase => phase.label === label)) throw new Error(`missing author phase ${label}: ${overview.text}`);
}
if ((overview.interaction_contract || {}).expose_as_top_level_task !== false) throw new Error(JSON.stringify(overview));
NODE
}

@test "short task overview follows the README author workflow and hides internal checks" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const { BASE_TEMPLATES } = require(path.join(repo, 'scripts/lib/workflow-template-registry.js'));
const { buildWorkflowTaskOverview } = require(path.join(repo, 'scripts/lib/workflow-action-renderer.js'));
const tpl = BASE_TEMPLATES.short_write;
const task = {
  workflow_id: 'wf-short', workflow_type: 'short_write', user_goal: '完成当前短篇', current_stage: 'section_plan_lock',
  machine: { completed_stages: ['project_type_lock', 'material_source_choice', 'material_card', 'short_setting', 'platform_genre_lock', 'rhythm_pattern_selection', 'section_outline'], remaining_stages: [] },
  unit_lifecycle: { stage_roles: (tpl.unit_lifecycle_contract || {}).stage_roles || {} },
  scheduling_contract: tpl.scheduling_contract,
};
const overview = buildWorkflowTaskOverview(task, tpl);
const labels = overview.phases.map(phase => phase.label);
for (const label of ['资讯 / 素材 / 脑洞卡', '设定与人物', '确认总节数与小节标题', '当前节 Brief', '只写当前节', '双门验收与采用', '合稿 / 精修 / 发布检查']) {
  if (!labels.includes(label)) throw new Error(`missing author phase ${label}: ${overview.text}`);
}
for (const leaked of ['平台与题材方法', '节奏与爽点模型', '结构影响审计', '看点价值门']) {
  if (overview.text.includes(leaked)) throw new Error(`internal stage leaked: ${leaked}\n${overview.text}`);
}
if ((overview.current_subtask || {}).author_phase_label !== '确认总节数与小节标题') throw new Error(JSON.stringify(overview.current_subtask));

const sectionOverview = buildWorkflowTaskOverview({
  ...task,
  current_stage: 'section_brief',
  machine: { completed_stages: [...task.machine.completed_stages, 'section_plan_lock', 'short_structure_impact_audit', 'hook_value_gate'], remaining_stages: [] },
  author_execution_point: { kind: 'section', index: 2, total: 9, label: '第 2/9 节《哥哥说，只是设备升级》', compact_label: '第 2/9 节' },
}, tpl);
if (!sectionOverview.text.includes('当前执行：第 2/9 节《哥哥说，只是设备升级》')) throw new Error(sectionOverview.text);
if ((sectionOverview.execution_point || {}).index !== 2) throw new Error(JSON.stringify(sectionOverview.execution_point));
NODE
}

@test "task overview command keeps a multi-stage workflow above its substage menu" {
    # long_write creation is not frozen; the inbox branch below was dropped
    # because requiresTaskOverview (commit 455fff7) now always surfaces the
    # overview menu via `options` rather than `next_actions` once an overview is
    # required, which is authoritatively covered by test-workflow-task-inbox.bats.
    project="$TMP_DIR/overview-book"
    mkdir -p "$project"
    node "$STATE" create --workflow-type long_write --project-root "$project" --user-goal "完成当前长篇" --json >/dev/null
    run node "$STATE" task-overview --project-root "$project" --json
    [ "$status" -eq 0 ]
    node - "$output" <<'NODE'
const out = JSON.parse(process.argv[2]);
if (out.status !== 'workflow_task_overview') throw new Error(JSON.stringify(out));
const visible = out.visible_response || {};
if (visible.status !== 'workflow_task_overview' || !String(visible.text || '').includes('任务阶段')) throw new Error(JSON.stringify(out));
if (!String(visible.text || '').includes('当前阶段')) throw new Error(JSON.stringify(out));
if (!Array.isArray(visible.options) || visible.options.length !== 4) throw new Error(JSON.stringify(out));
if (visible.options[0].action_id !== 'open_current_subtask') throw new Error(JSON.stringify(out));
NODE
}

@test "short task overview reads the current section execution point from project state" {
    project="$TMP_DIR/short-execution-point"
    mkdir -p "$project"
    node "$STATE" create --workflow-type long_write --project-root "$project" --user-goal "准备短篇兼容态" --json >/dev/null
    node - "$project" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const taskFile = path.join(root, pointer.task_dir, 'task.json');
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
task.workflow_type = 'short_write';
task.current_stage = 'section_brief';
task.current_step = 'section_brief';
task.scope = '第2节';
task.machine.completed_stages = [
  'project_type_lock', 'material_source_choice', 'material_card', 'short_setting',
  'platform_genre_lock', 'rhythm_pattern_selection', 'section_outline', 'section_plan_lock',
  'short_structure_impact_audit', 'hook_value_gate',
];
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
const stateRoot = path.join(root, '追踪/story-system/short');
fs.mkdirSync(stateRoot, { recursive: true });
fs.writeFileSync(path.join(stateRoot, 'project-state.json'), `${JSON.stringify({ planned_sections: 9, current_section_index: 2, narrative: { planned_sections: 9 } }, null, 2)}\n`);
fs.writeFileSync(path.join(stateRoot, 'section-title-lock.json'), `${JSON.stringify({ sections: [{ section_index: 2, title: '哥哥说，只是设备升级' }] }, null, 2)}\n`);
NODE

    run node "$STATE" task-overview --project-root "$project" --json
    [ "$status" -eq 0 ]
    node - "$output" <<'NODE'
const out = JSON.parse(process.argv[2]);
const visible = out.visible_response || {};
if (!String(visible.text || '').includes('当前执行：第 2/9 节《哥哥说，只是设备升级》')) throw new Error(JSON.stringify(out));
if (!String((((visible.options || [])[0] || {}).label || '')).includes('第 2/9 节')) throw new Error(JSON.stringify(visible.options));
NODE
}

@test "task overview is shown once per task plan version" {
    node - "$REPO" <<'NODE'
const path = require('path');
const repo = process.argv[2];
const {
  markTaskOverviewPresented,
  taskOverviewPresentationRequired,
} = require(path.join(repo, 'scripts/lib/workflow-task-overview-state.js'));

const task = {
  workflow_id: 'wf-overview-once',
  workflow_type: 'short_write',
  user_goal: '整篇回炉',
  scheduling_contract: { task_form: 'bounded_loop' },
  feedback_revision_queue: {
    status: 'running',
    items: [
      { section_index: 1, title: '第一节', status: 'pending' },
      { section_index: 2, title: '第二节', status: 'pending' },
    ],
  },
};

if (!taskOverviewPresentationRequired(task)) throw new Error('first entry must show overview');
markTaskOverviewPresented(task, '2026-07-23T00:00:00.000Z');
if (taskOverviewPresentationRequired(task)) throw new Error('same plan must continue with current subtask');

task.feedback_revision_queue.items[0].status = 'accepted';
if (taskOverviewPresentationRequired(task)) throw new Error('progress changes must not reopen overview');

task.feedback_revision_queue.items.push({ section_index: 3, title: '第三节', status: 'pending' });
if (!taskOverviewPresentationRequired(task)) throw new Error('structural plan changes must reopen overview');
NODE
}
