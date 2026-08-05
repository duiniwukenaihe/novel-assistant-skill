'use strict';

// Task 8: the run-stage production entry point.
//
// A thin, engine-neutral dispatcher that wires the V3 run-stage CLI command
// (scripts/workflow-v3.js) to the professional production services and back
// through the Engine. The CLI hands us six resolved values:
//
//   projectRoot, workflowId, expectedVersion, stage, contextFile.
//
// Authority boundary (BEFORE any service call):
//   1. The context-file is a flat JSON object describing the staged artifact
//      for the current stage (brief_rel, draft_rel, evidence_rel, etc.). It
//      must NEVER carry an engine-owned field — task, current_stage,
//      workflow_id, projectRoot, expectedVersion. The CLI parses the
//      authoritative fields from flags and re-reads task.json itself, so any
//      caller-injected authority value is rejected before the Engine can be
//      asked to commit a tampered version.
//
// Stage boundary (BEFORE any service call):
//   2. creative_entry / planning_confirmation / section_repair have specific
//      engine-owned or apply-result paths. The run-stage entry point is for
//      staged-artifact stages only and refuses these three ids outright so
//      the durable task.json stays byte-for-byte unchanged.
//
// Service boundary:
//   3. After rejecting the two boundaries, the runner re-reads task.json and
//      validates expected-version + current_stage BEFORE dispatch. Only then
//      does it call the matching professional service. The service returns a
//      Task 1 StageResult; the runner forwards it to engine.applyStageResult
//      and is done. The Engine is the single writer of current_stage and
//      retry_state — the runner never touches either.
//
// The runner must NOT import the V2 workflow-state-machine, the Interaction
// Arbiter, the renderer, or any menu/option numbering helper. It composes a
// flat success body ({ ok, stage_result, task, visible_response }) that
// downstream consumers can render; the Engine / Arbiter own the binding.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const engine = require('./engine');
const { withWorkflowExecutionLock } = require('./execution-lock');
const { finalizePlanningStage } = require('../short-production/planning');
const {
  finalizeBrief,
  finalizeDraft,
  runMachineGate,
  runStoryGate,
  acceptSection,
} = require('../short-production/section-loop');
const {
  assembleStory,
  finalizeEditorialReview,
  finalizeDeslop,
  runFinalCheck,
} = require('../short-production/closure');
const { readShortProjectState } = require('../short-project-state');
const { inferShortSectionIndex } = require('../short-workflow-state');
const { buildShortSectionOutlineContract } = require('../short-section-outline-contract');
const { resolveShortReaderMilestone } = require('../short-reader-milestone-policy');
const { buildShortQualityEvidenceSchema } = require('../short-section-quality-evidence');
const { refreshCurrentStageContext } = require('../workflow-stage-context-refresh');

// Context-file fields that are owned by the CLI/Engine. Their presence in the
// caller-supplied context-file means a host is trying to inject engine state
// the runner must not honor; reject before any service or Engine call so the
// durable task.json cannot be tainted.
const CONTEXT_AUTHORITY_FIELDS = Object.freeze([
  'task', 'current_stage', 'workflow_id', 'projectRoot', 'expectedVersion',
]);
const CONTEXT_EVIDENCE_OVERRIDE_FIELDS = Object.freeze([
  'metadata', 'memoryBasis', 'memory_basis',
]);

// Stages that are NOT invokable through the staged-artifact run-stage entry
// point. These author-driven stages advance through apply-result after the
// corresponding author choice or prose revision is ready.
const REFUSED_STAGES = Object.freeze([
  'creative_entry', 'planning_confirmation', 'section_repair',
]);

// Staged-artifact stages the runner dispatches. Kept as a Set so an unknown
// stage id (or a typo) is rejected before the service is ever called.
const SUPPORTED_STAGES = Object.freeze([
  'material_positioning', 'setting', 'section_outline',
  'section_brief', 'section_draft', 'machine_gate', 'story_gate', 'section_accept',
  'assembly', 'editorial_review', 'deslop', 'final_check',
]);

const V3_CONTEXT_STAGE_MAP = Object.freeze({
  section_brief: 'section_brief',
  section_draft: 'draft_section',
  section_repair: 'section_repair_loop',
});
const PLANNING_STAGE_CONTRACTS = Object.freeze({
  material_positioning: Object.freeze({ target: '素材卡.md', source_files: Object.freeze([]) }),
  setting: Object.freeze({ target: '设定.md', source_files: Object.freeze(['素材卡.md']) }),
  section_outline: Object.freeze({ target: '小节大纲.md', source_files: Object.freeze(['素材卡.md', '设定.md']) }),
});

// Public entry point. Resolved flag values flow in directly from the CLI; this
// function is a pure dispatch, not a flag parser. Any failure is reported as
// a thrown Error; the CLI converts it to the { ok:false, error } JSON payload.
function runStage(input = {}) {
  const projectRootInput = String(input.projectRoot || '').trim();
  const workflowId = String(input.workflowId || '').trim();
  const stage = String(input.stage || '').trim();
  const contextFile = String(input.contextFile || '').trim();
  const expectedVersion = parseExpectedVersion(input.expectedVersion);

  if (!projectRootInput) throw new Error('project_root_required');
  if (!workflowId) throw new Error('workflow_id_required');
  if (!contextFile) throw new Error('context_file_required');
  if (!stage) throw new Error('stage_required');
  const projectRoot = path.resolve(projectRootInput);

  // Boundary 1: the context-file must not carry engine-owned authority
  // fields. Reject BEFORE any read or service call so a tampered call cannot
  // reach the Engine.
  const context = readContextFile(contextFile);
  const authorityField = findContextAuthorityField(context);
  if (authorityField) {
    throw new Error(`run-stage context-file must not carry authority field "${authorityField}"; the engine owns ${CONTEXT_AUTHORITY_FIELDS.join(', ')}`);
  }
  const evidenceOverride = findContextField(context, CONTEXT_EVIDENCE_OVERRIDE_FIELDS);
  if (evidenceOverride) {
    throw new Error(`run-stage context-file must not override accepted evidence field "${evidenceOverride}"`);
  }

  // Boundary 2: refuse stages that have specific engine-owned or apply-result
  // paths. Listed individually so the rejection names the refused stage and
  // the durable task.json is never touched.
  if (REFUSED_STAGES.includes(stage)) {
    throw new Error(`run-stage refuses stage "${stage}" (it has a specific engine or apply-result path; use apply-result or a different entry point)`);
  }
  if (!SUPPORTED_STAGES.includes(stage)) {
    throw new Error(`run-stage does not support stage "${stage}"`);
  }

  return runStageWithContext({ projectRoot, workflowId, expectedVersion, stage, context });
}

function runCurrentStage(input = {}) {
  const projectRoot = path.resolve(String(input.projectRoot || '').trim());
  const workflowId = String(input.workflowId || '').trim();
  const expectedVersion = parseExpectedVersion(input.expectedVersion);
  if (!workflowId) throw new Error('workflow_id_required');
  const task = engine.readTask(projectRoot, workflowId);
  if (Number(task.state_version) !== expectedVersion) {
    const error = new Error('durable task changed before stage execution');
    error.code = 'WORKFLOW_TASK_CONFLICT';
    error.status = 'blocked_workflow_state_conflict';
    throw error;
  }
  const stage = String(task.current_stage || '');
  if (stage === 'section_repair') {
    const applied = engine.applyStageResult(projectRoot, workflowId, expectedVersion, {
      kind: 'completed',
      code: 'short_section_repair_ready',
      stage_id: stage,
    });
    return { ok: true, stage_result: { kind: 'completed', code: 'short_section_repair_ready', stage_id: stage }, ...applied };
  }
  const contract = describeTaskStage(task, projectRoot);
  return runStageWithContext({ projectRoot, workflowId, expectedVersion, stage, context: contract.context });
}

function describeCurrentStage(input = {}) {
  const projectRoot = path.resolve(String(input.projectRoot || '').trim());
  const workflowId = String(input.workflowId || '').trim();
  if (!workflowId) throw new Error('workflow_id_required');
  let task = engine.readTask(projectRoot, workflowId);
  let contract = describeTaskStage(task, projectRoot);
  const quotedWorkflowId = JSON.stringify(workflowId);
  const contextStage = V3_CONTEXT_STAGE_MAP[String(task.current_stage || '')] || '';
  if (contextStage) {
    const refresh = refreshCurrentStageContext(projectRoot, workflowId);
    if (!['stage_context_refreshed', 'stage_context_current'].includes(String(refresh.status || ''))) {
      const error = new Error(`required V3 stage context is unavailable: ${refresh.status}`);
      error.code = 'V3_STAGE_CONTEXT_UNAVAILABLE';
      error.status = 'blocked_stage_context_unavailable';
      error.stage_context_packet = refresh.packet || null;
      throw error;
    }
    task = engine.readTask(projectRoot, workflowId);
    contract = describeTaskStage(task, projectRoot);
  }
  const version = Number(task.state_version || 0);
  const acceptedPlan = activeAcceptedFeedbackPlan(task, contract.section_index);
  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const stageContextPacket = contextStage
    ? (execution.stage_context_packet && typeof execution.stage_context_packet === 'object' ? execution.stage_context_packet : null)
    : null;
  if (contextStage && (!stageContextPacket || stageContextPacket.status !== 'assembled')) {
    const error = new Error('required V3 stage context was not durably bound');
    error.code = 'V3_STAGE_CONTEXT_UNAVAILABLE';
    error.status = 'blocked_stage_context_unavailable';
    error.stage_context_packet = stageContextPacket;
    throw error;
  }
  const sourceFiles = stageContextPacket ? [stageContextPacket.packet_md] : contract.source_files;
  const contextReadCommand = stageContextPacket
    ? `node scripts/workflow-stage-context.js read-current --project-root . --workflow-id ${quotedWorkflowId} --json`
    : `node scripts/workflow-v3.js describe-stage --project-root . --workflow-id ${quotedWorkflowId} --json`;
  return {
    status: 'stage_execution_resume_ready',
    selection_contract: 'resume_running_stage',
    workflow_id: workflowId,
    current_stage: String(task.current_stage || ''),
    stage_id: String(task.current_stage || ''),
    stage_attempt_id: String(((task || {}).stage_execution || {}).stage_attempt_id || ''),
    state_version: version,
    section_index: contract.section_index,
    write_set: contract.write_set,
    source_files: sourceFiles,
    stage_context_packet: stageContextPacket,
    evidence_schema: contract.evidence_schema || null,
    accepted_feedback_plan: acceptedPlan,
    execution_workdir: '.',
    context_read_command: contextReadCommand,
    execution_command: `node scripts/workflow-v3.js run-current-stage --project-root . --workflow-id ${quotedWorkflowId} --expected-version ${version} --json`,
    stage_completion_command: `node scripts/workflow-v3.js run-current-stage --project-root . --workflow-id ${quotedWorkflowId} --expected-version ${version} --json`,
    current_required_action: String(task.current_stage || '') === 'editorial_review'
      ? 'prepare_evidence_then_write'
      : contract.write_set.length > 0 ? 'write_then_complete_stage' : 'complete_stage',
    completion_required_before_reply: true,
    resume_hint: buildResumeHint(task, contract),
  };
}

function runStageWithContext({ projectRoot, workflowId, expectedVersion, stage, context }) {
  return withWorkflowExecutionLock(projectRoot, `workflow-v3-run-stage:${stage}`, (capability) => {
    // Hold the same execution lock used by direct Engine mutations from the
    // authoritative reread through service side effects and Engine commit.
    const task = engine.readTask(projectRoot, workflowId);
    if (Number(task.state_version) !== Number(expectedVersion)) {
      const error = new Error('durable task changed before stage execution');
      error.code = 'WORKFLOW_TASK_CONFLICT';
      error.status = 'blocked_workflow_state_conflict';
      throw error;
    }
    if (String(task.current_stage) !== stage) {
      throw new Error(`stage_mismatch:expected=${stage}:current=${task.current_stage || ''}`);
    }

    const stageResult = dispatchStage({ projectRoot, task, stage, context });
    const applied = engine.applyStageResult(
      projectRoot,
      workflowId,
      expectedVersion,
      stageResult,
      capability,
    );

    return {
      ok: true,
      stage_result: stageResult,
      task: applied.task,
      visible_response: applied.visible_response,
    };
  });
}

function describeTaskStage(task, projectRoot) {
  const stage = String((task || {}).current_stage || '');
  const taskDir = String((task || {}).task_dir || '');
  const attempt = String((((task || {}).stage_execution || {}).stage_attempt_id) || 'current');
  if (stage === 'assembly') {
    return { section_index: 0, write_set: [], source_files: [], context: {} };
  }
  if (stage === 'editorial_review') {
    const root = `${taskDir}/artifacts/closure/editorial-review/attempts/${attempt}`;
    const readerRel = `${root}/reader-response.json`;
    const reviewRel = `${root}/editorial-review.json`;
    return {
      section_index: 0,
      write_set: [readerRel, reviewRel],
      source_files: ['正文.md'],
      context: { reader_response_path: readerRel, review_card_path: reviewRel },
    };
  }
  if (stage === 'deslop') {
    const stagedRel = `${taskDir}/artifacts/closure/deslop/attempts/${attempt}/正文-精修候选.md`;
    return {
      section_index: 0,
      write_set: [stagedRel],
      source_files: ['正文.md'],
      context: { staged_path: stagedRel },
    };
  }
  if (stage === 'final_check') {
    return { section_index: 0, write_set: [], source_files: ['正文.md'], context: {} };
  }
  const planning = PLANNING_STAGE_CONTRACTS[stage];
  if (planning) {
    const stagedRel = `${taskDir}/artifacts/planning/${stage}/${attempt}/${planning.target}`;
    return {
      section_index: 0,
      write_set: [stagedRel],
      source_files: [...planning.source_files],
      context: { staged_rel: stagedRel },
    };
  }
  const sectionIndex = currentSectionIndex(task, projectRoot, stage);
  if (!sectionIndex) throw new Error('current_section_index_required');
  const padded = String(sectionIndex).padStart(3, '0');
  const briefRel = `写作Brief_第${padded}节.md`;
  const draftRel = `草稿_第${padded}节_候选.md`;
  const evidenceRel = `${String(task.task_dir || '')}/artifacts/section-${padded}-story-review-pass.json`;
  const acceptedPlan = activeAcceptedFeedbackPlan(task, sectionIndex) || {};
  const planningAssets = String(acceptedPlan.projection_status || '') === 'completed'
    ? []
    : Array.isArray(((acceptedPlan || {}).projection_plan || {}).planning_assets)
    ? acceptedPlan.projection_plan.planning_assets.map(String).filter(Boolean)
    : [];
  if (stage === 'section_brief') {
    return {
      section_index: sectionIndex,
      write_set: [...new Set([...planningAssets, briefRel])],
      source_files: [],
      context: { brief_rel: briefRel, section_index: sectionIndex },
    };
  }
  if (stage === 'section_draft') {
    return { section_index: sectionIndex, write_set: [draftRel], source_files: [briefRel], context: { draft_rel: draftRel, section_index: sectionIndex } };
  }
  if (stage === 'machine_gate') {
    return { section_index: sectionIndex, write_set: [], source_files: [draftRel], context: { draft_rel: draftRel, section_index: sectionIndex } };
  }
  if (stage === 'section_repair') {
    return { section_index: sectionIndex, write_set: [draftRel], source_files: [draftRel], context: { draft_rel: draftRel, section_index: sectionIndex } };
  }
  if (stage === 'story_gate') {
    const draftFile = path.join(projectRoot, draftRel);
    const outlineContract = buildShortSectionOutlineContract(projectRoot, sectionIndex);
    const readerMilestone = resolveShortReaderMilestone({ sectionIndex, outlineContract, task });
    return {
      section_index: sectionIndex,
      write_set: [evidenceRel],
      source_files: [draftRel],
      evidence_schema: buildShortQualityEvidenceSchema({
        workflowId: String(task.workflow_id || ''),
        sectionIndex,
        draftDigest: digestFile(draftFile),
        outlineContract,
        readerMilestone,
      }),
      context: { draft_rel: draftRel, evidence_rel: evidenceRel, section_index: sectionIndex },
    };
  }
  if (stage === 'section_accept') {
    return { section_index: sectionIndex, write_set: [], source_files: [draftRel, evidenceRel], context: { draft_rel: draftRel, evidence_rel: evidenceRel, section_index: sectionIndex } };
  }
  throw new Error(`describe-stage does not support stage "${stage}"`);
}

function digestFile(file) {
  try {
    return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
  } catch (_) {
    return '';
  }
}

function currentSectionIndex(task, projectRoot, stage) {
  const candidates = [
    Number((((task || {}).stage_execution || {}).section_index) || 0),
    Number((task || {}).current_section_index || 0),
    Number((((task || {}).pending_feedback || {}).section_index) || 0),
  ];
  const durable = candidates.find((value) => Number.isInteger(value) && value > 0) || 0;
  if (durable) return durable;
  const projectState = readShortProjectState(projectRoot) || {};
  return inferShortSectionIndex({
    projectState,
    stageId: String(stage || ''),
    scope: String((task || {}).scope || ''),
  }) || 0;
}

function buildResumeHint(task, contract) {
  const summary = String((activeAcceptedFeedbackPlan(task, contract.section_index) || {}).summary || '').trim();
  const planText = summary ? `按已接受方案“${summary}”` : '按当前已确认规划';
  const stage = String((task || {}).current_stage || '');
  const assemblyRevalidation = String((((task || {}).feedback_revision_queue || {}).source_stage) || '') === 'full_story_assembly';
  if (stage === 'assembly') return '已完成逐节采用；直接运行 stage_completion_command 生成正式合稿。';
  if (stage === 'editorial_review') return '先运行 stage_completion_command 生成全篇证据包；再只填写 write_set 中的盲读卡与编辑裁决卡并重跑。';
  if (stage === 'deslop') return '只在 write_set 中生成全篇表达精修暂存稿，保持剧情、节数与节序不变；随后运行 stage_completion_command。';
  if (stage === 'final_check') return '本阶段不改文件，直接运行 stage_completion_command 完成终检。';
  if (PLANNING_STAGE_CONTRACTS[stage]) {
    return `只在 write_set 中完成当前“${PLANNING_STAGE_CONTRACTS[stage].target}”暂存稿；不得直接覆盖正式规划文件，完成后立即运行 stage_completion_command。`;
  }
  if (assemblyRevalidation && stage === 'story_gate') {
    return `保留当前正式正文，重新验收第${contract.section_index}节；只填写 write_set 中的故事质量证据并运行 stage_completion_command。`;
  }
  if (stage === 'machine_gate' || stage === 'section_accept') {
    return assemblyRevalidation
      ? `保留当前正式正文，重新验收第${contract.section_index}节；本阶段不改文件，直接运行 stage_completion_command。`
      : `${planText}继续当前第${contract.section_index}节；本阶段不改文件，直接运行 stage_completion_command。`;
  }
  return `${planText}只处理 write_set 中的当前第${contract.section_index}节资产；完成后立即运行 stage_completion_command，不得重新提交同一反馈或改动无关章节。`;
}

function activeAcceptedFeedbackPlan(task, sectionIndex) {
  const feedback = (task || {}).pending_feedback;
  if (!feedback || String(feedback.status || '') !== 'accepted') return null;
  const plan = feedback.accepted_plan;
  if (!plan || typeof plan !== 'object' || Array.isArray(plan)) return null;
  const affected = Array.isArray(plan.affected_sections) ? plan.affected_sections.map(Number) : [];
  const section = Number(sectionIndex || 0);
  if (affected.length && section > 0 && !affected.includes(section)) return null;
  return plan;
}

// Map each supported stage to the professional service call. Keep this as a
// straight switch so the table is auditable in one place; the runner must NOT
// add a generic fallback or auto-derive a service name from a stage id.
function dispatchStage({ projectRoot, task, stage, context }) {
  switch (stage) {
    case 'material_positioning':
    case 'setting':
    case 'section_outline':
      return finalizePlanningStage({
        projectRoot,
        task,
        stageId: stage,
        stagedRel: String(context.staged_rel || ''),
        apply: true,
      });
    case 'section_brief':
      return finalizeBrief({
        projectRoot,
        task,
        brief: String(context.brief_rel || ''),
      });
    case 'section_draft':
      return finalizeDraft({
        projectRoot,
        task,
        draft: String(context.draft_rel || ''),
      });
    case 'machine_gate':
      return runMachineGate({
        projectRoot,
        task,
        draft: String(context.draft_rel || ''),
      });
    case 'story_gate':
      return runStoryGate({
        projectRoot,
        task,
        draft: String(context.draft_rel || ''),
        evidenceFile: String(context.evidence_rel || ''),
      });
    case 'section_accept': {
      const params = { projectRoot, task };
      if (context.draft_rel) params.draft = String(context.draft_rel);
      return acceptSection(params);
    }
    case 'assembly':
      return assembleStory({ projectRoot, task });
    case 'editorial_review':
      return finalizeEditorialReview({
        projectRoot,
        task,
        readerResponsePath: String(context.reader_response_path || ''),
        reviewCardPath: String(context.review_card_path || ''),
      });
    case 'deslop':
      return finalizeDeslop({
        projectRoot,
        task,
        stagedPath: String(context.staged_path || ''),
      });
    case 'final_check':
      return runFinalCheck({ projectRoot, task });
    default:
      // The stage was already validated against SUPPORTED_STAGES, so this
      // branch is unreachable in production; keeping the throw so a future
      // mismatch surfaces loudly.
      throw new Error(`run-stage dispatch missing for stage "${stage}"`);
  }
}

// --- helpers --------------------------------------------------------------

// Read the context-file as a flat JSON object. Anything else (array, scalar,
// unreadable file, non-object) is rejected as a context-file shape error so
// the runner does not silently coerce a malformed input.
function readContextFile(file) {
  let raw;
  try {
    raw = fs.readFileSync(path.resolve(file), 'utf8');
  } catch (error) {
    throw new Error(`run-stage context-file unreadable: ${error.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(`run-stage context-file is not valid JSON: ${error.message}`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('run-stage context-file must be a JSON object');
  }
  return parsed;
}

// Return the first CONTEXT_AUTHORITY_FIELDS key found in the context, or an
// empty string when the context is clean. Direct key check is intentional:
// nested object detection is the Engine's job, not the runner's.
function findContextAuthorityField(context) {
  return findContextField(context, CONTEXT_AUTHORITY_FIELDS);
}

function findContextField(context, fields) {
  for (const field of fields) {
    if (Object.prototype.hasOwnProperty.call(context, field)) return field;
  }
  return '';
}

// Parse the --expected-version value the CLI hands in. The CLI already
// validates the integer shape via parseVersion, so this is a defensive cast
// that throws on anything non-integer reaching the runner.
function parseExpectedVersion(value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 0) {
    throw new Error(`expected-version must be a non-negative integer (got: ${value})`);
  }
  return number;
}

module.exports = {
  runStage,
  runCurrentStage,
  describeCurrentStage,
};
