'use strict';

// Task 6: Engine-neutral short section production loop.
//
// Each of the five entry points (finalizeBrief, finalizeDraft, runMachineGate,
// runStoryGate, acceptSection) returns a Task 1 StageResult ONLY — no
// visible_response, no numbered options, no V3 task.json mutation. The V3 Engine
// is the single writer that persists stage transitions and retry_state; tests
// apply every returned StageResult through engine.applyStageResult.
//
// The service reuses the existing deterministic domain libraries directly
// (outline contract, brief freshness, machine-gate check scripts, section length
// policy, quality evidence, accepted-section commit store, project state,
// integration outbox). It must NOT import the V2 workflow-state-machine, the
// workflow entry guard, the task inbox, the action renderer, the Interaction
// Arbiter, any of the five CLI wrappers, or workflow-state-store#mutateTask. It
// never spawns the V2 workflow-state-machine.js apply-result path.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { atomicWriteJson } = require('../workflow-state-store');
const {
  buildShortSectionOutlineContract,
  validateBriefOutlineCoverage,
  validateDraftOutlineCoverage,
} = require('../short-section-outline-contract');
const { writeBriefFreshnessSnapshot } = require('../short-brief-freshness');
const {
  deriveSectionLengthPolicy,
} = require('../short-section-length-policy');
const {
  plannedTargetChars,
  resolveSectionLengthTarget,
} = require('../short-section-length-target');
const { checkShortMemoryStage } = require('../short-memory-stage-policy');
const {
  previewShortFeedbackRevisionAcceptance,
} = require('../short-feedback-revision-queue');
const { QUALITY_CHECKS } = require('../short-section-quality-evidence');
const { resolveShortReaderMilestone } = require('../short-reader-milestone-policy');
const {
  buildCanonicalSectionText,
  commitAcceptedSection,
} = require('../short-section-commit-store');
const {
  appendIntegrationEvent,
} = require('../integration-outbox');
const {
  readShortProjectState,
  resolveShortProjectTitle,
  resolveShortStateRelative,
  shortStateFile,
} = require('../short-project-state');
const {
  inferShortSectionIndex,
  resolvePlannedSectionCount,
  resolveShortPlanProgress,
} = require('../short-workflow-state');
const {
  acceptedSectionHighWater,
} = require('../short-workflow-state');
const { stageResult } = require('../workflow-v3/contracts');

const REQUIRED_SIGNALS = ['视角', '人物', '因果', '钩子', '禁止', '验收'];
const STORY_QUALITY_LABELS = Object.freeze({
  causal_progression: '因果推进',
  protagonist_agency: '主角主动性',
  emotional_tension: '情绪张力',
  reader_pull: '读者追读力',
});
const SEMANTIC_REVISION_CODES = new Set([
  'evidence_check_revise',
  'draft_outline_obligation_revise',
  'evidence_reader_milestone_revise',
]);

// V3 canonical stage ids. The shared service is called with these ids; the
// returned StageResult carries the V3 stage id from the durable task.
const BRIEF_STAGES = new Set(['first_section_brief', 'section_brief', 'next_section_brief']);
const DRAFT_STAGES = new Set(['draft_first_section', 'draft_section', 'draft_next_section']);

// Machine-gate check commands. The five real deterministic checks production V2
// runs, in the same order. story-prose-gate is invoked WITHOUT its --write
// report mode; V3 evidence lives in the task artifact directory.
const MACHINE_CHECK_COMMANDS = Object.freeze([
  ['check-ai-patterns', 'check-ai-patterns.js', (draft) => ['--check', '--json', '--fail-on=blocking', draft]],
  ['anti-ai-diagnose', 'anti-ai-diagnose.js', () => ['--json', '--work-type=shortform', '--prose-profile=fiction']],
  ['output-pollution-check', 'output-pollution-check.js', (draft) => ['--check', '--json', draft]],
  ['check-degeneration', 'check-degeneration.js', (draft) => ['--check', '--json', '--fail-on=blocking', draft]],
  ['story-prose-gate', 'story-prose-gate.js', (draft) => [draft, '--json']],
]);

// Unnumbered author-choice options for repeated same-family failures. The
// Interaction Arbiter assigns stable numbers AFTER the Engine persists the
// pending action; the professional service never numbers them itself.
const RETRY_EXHAUSTION_OPTIONS = Object.freeze([
  { action_id: 'inspect_current_state', label: '查看未通过项与已识别内容' },
  { action_id: 'free_text', label: '调整当前写作要求' },
  { action_id: 'retry_stage_contract', label: '重新生成当前候选稿一次' },
]);

// ---------------------------------------------------------------------------
// finalizeBrief
// ---------------------------------------------------------------------------

// Validate the current planned section, confirmed title, outline contract,
// Brief completeness/quality and freshness with the existing libraries.
// Success => completed (graph advances to section_draft). Overload requiring
// author judgment => needs_author_choice. Mechanical first failure =>
// retryable_internal.
//
// context:
//   projectRoot — absolute project root
//   task        — the freshly reread durable V3 task (its retry_state is the
//                 ONLY retry input the service consults)
//   brief       — optional relative path of the staged Brief; defaults to the
//                 canonical 写作Brief_第NNN节.md for the current section
function finalizeBrief(context = {}) {
  const root = path.resolve(context.projectRoot || '');
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = resolveBriefStageId(task);
  const workflowId = String(task.workflow_id || '');

  const projectState = readShortProjectState(root) || {};
  const sectionIndex = resolveSectionIndex({ projectState, task, stageId });
  if (!sectionIndex) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_identity_missing',
      stage_id: stageId,
      failure_family: 'section_identity_missing',
      instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复当前小节范围，不得默认生成第1节 Brief。',
    });
  }

  const briefRel = String(context.brief || `写作Brief_第${pad(sectionIndex)}节.md`);
  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const memoryCheck = checkShortMemoryStage({
    projectRoot: root,
    task,
    execution,
    sectionIndex,
    stageId,
  });
  if (memoryCheck.blocking) {
    return stageResult({
      kind: 'blocked',
      code: 'short_memory_context_refresh_required',
      stage_id: stageId,
      failure_family: 'memory_context_stale',
      section_index: sectionIndex,
      brief: briefRel,
      memory_status: memoryCheck.memory_status,
      stale_sources: memoryCheck.stale_sources,
      instruction: memoryCheck.instruction,
    });
  }

  const titleLock = readJson(shortStateFile(root, 'section-title-lock.json')) || {};
  const titleEntry = (Array.isArray(titleLock.sections) ? titleLock.sections : [])
    .find((item) => Number((item || {}).section_index) === sectionIndex);
  if (!titleEntry || titleEntry.confirmed !== true) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_title_confirmation_required',
      stage_id: stageId,
      failure_family: 'title_confirmation_required',
      section_index: sectionIndex,
      instruction: `第${sectionIndex}节标题尚未经用户确认，禁止 Brief 自行命名。`,
    });
  }
  if (String(titleLock.workflow_id || '') !== workflowId
      || String(titleLock.project_id || '') !== String(projectState.project_id || '')
      || Number(titleLock.plan_revision || 0) !== Number(projectState.plan_revision || 0)) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_title_lock_stale',
      stage_id: stageId,
      failure_family: 'title_lock_stale',
      section_index: sectionIndex,
      instruction: '标题清单不属于当前作品规划版本，必须重新确认后再生成 Brief。',
    });
  }

  const briefFile = safeProjectFile(root, briefRel);
  if (!briefFile || !fs.existsSync(briefFile) || !fs.statSync(briefFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_brief',
      stage_id: stageId,
      failure_family: 'brief_missing',
      brief: briefRel,
      instruction: '只生成当前节写作提要，然后重新运行本阶段。',
    });
  }
  const text = fs.readFileSync(briefFile, 'utf8').trim();
  if (!text) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_brief',
      stage_id: stageId,
      failure_family: 'brief_empty',
      brief: briefRel,
      instruction: '当前写作提要是空的；只补齐当前节写作提要后重跑。',
    });
  }
  const missingSignals = REQUIRED_SIGNALS.filter((signal) => !text.includes(signal));
  if (text.length < 240 || missingSignals.length > 2) {
    return briefFailure(task, stageId, {
      family: 'brief_completeness',
      code: 'short_brief_revision_required',
      brief: briefRel,
      chars: text.length,
      missing_signals: missingSignals,
      instruction: '只补齐当前写作提要缺失部分一次；不要读取全篇或进入正文。',
    });
  }

  const outlineContract = buildShortSectionOutlineContract(root, sectionIndex);
  if (outlineContract.status !== 'current') {
    return stageResult({
      kind: 'blocked',
      code: 'short_outline_contract_required',
      stage_id: stageId,
      failure_family: 'outline_contract_required',
      section_index: sectionIndex,
      finding: outlineContract.code || 'outline_contract_missing',
      instruction: '先回到小节大纲补足本节结构功能、子事件与节尾钩子；不得让 Brief 或正文临场补剧情。',
    });
  }
  const outlineCoverage = validateBriefOutlineCoverage(text, outlineContract);
  if (outlineCoverage.status !== 'pass') {
    return briefFailure(task, stageId, {
      family: 'brief_outline_drift',
      code: 'short_brief_outline_drift',
      brief: briefRel,
      section_index: sectionIndex,
      outline_contract_digest: outlineContract.contract_digest,
      findings: outlineCoverage.findings,
      instruction: '当前写作提要缺少已确认的大纲义务。只补缺失的剧情功能、因果动作或承接钩子；不要进入正文。',
    });
  }

  const briefQuality = analyzeBriefQuality(text);
  if (briefQuality.status !== 'pass') {
    if (briefQuality.findings.some((finding) => [
      'evidence_mechanism_overload',
      'section_responsibility_overload',
      'section_focus_overload',
    ].includes(finding))) {
      return stageResult({
        kind: 'needs_author_choice',
        code: 'short_brief_quality_revision_required',
        stage_id: stageId,
        failure_family: 'brief_quality',
        section_index: sectionIndex,
        question: '当前节承载的证据和收束责任过多，请决定本节保留到什么范围。',
        options: [
          { action_id: 'keep_primary_causal_chain', label: '只保留一条主因果链，其余后移' },
          { action_id: 'split_section_responsibilities', label: '拆分本节承担项后重新生成 Brief' },
          { action_id: 'free_text', label: '直接说明你希望保留和删减的内容' },
        ],
        brief: briefRel,
        findings: briefQuality.findings,
        instruction: '等待作者确定当前节的取舍边界，不得自动循环精简或擅自拆节。',
      });
    }
    return briefFailure(task, stageId, {
      family: 'brief_quality',
      code: 'short_brief_quality_revision_required',
      brief: briefRel,
      findings: briefQuality.findings,
      instruction: '只精简当前写作提要一次：保留承接、目标与阻力、因果动作、人物/视角锁、禁写项、节尾钩子；同一事实只出现一次。',
    });
  }

  const acceptedAnchor = sectionIndex > 1
    ? resolveShortStateRelative(root, `section-${pad(sectionIndex - 1)}-anchor.json`)
    : '';
  const freshness = writeBriefFreshnessSnapshot({
    projectRoot: root, briefPath: briefRel, sectionIndex, acceptedAnchorPath: acceptedAnchor, task,
  });
  if (freshness.status !== 'snapshot_written') {
    return briefFailure(task, stageId, {
      family: 'brief_dependencies_changed',
      code: 'short_brief_dependencies_changed',
      brief: briefRel,
      freshness,
      instruction: '规划依赖已变化，重新生成当前节写作提要。',
    });
  }

  const coverageRel = `${String(task.task_dir || '')}/artifacts/section-${pad(sectionIndex)}-brief-outline-coverage.json`;
  const coverageFile = safeProjectFile(root, coverageRel);
  if (coverageFile) {
    atomicWriteJson(coverageFile, {
      schema_version: '1.0.0',
      workflow_id: workflowId,
      section_index: sectionIndex,
      brief: briefRel,
      coverage_mode: outlineCoverage.coverage_mode,
      outline_contract_digest: outlineContract.contract_digest,
      section_block_digest: outlineContract.section_block_digest,
      coverage: outlineCoverage.coverage,
      generated_at: new Date().toISOString(),
    });
  }

  return stageResult({
    kind: 'completed',
    code: 'short_brief_accepted',
    stage_id: stageId,
    brief: briefRel,
    brief_chars: text.length,
    section_index: sectionIndex,
    outline_contract_digest: outlineContract.contract_digest,
    section_block_digest: outlineContract.section_block_digest,
    outline_obligations: outlineContract.obligations.map((item) => item.id),
    outline_coverage_mode: outlineCoverage.coverage_mode,
    freshness_sidecar: freshness.sidecar,
    outline_coverage_sidecar: coverageRel,
    // No next_stage: the canonical V3 graph is the ONLY transition authority
    // (section_brief -> section_draft is a single-edge node).
  });
}

// ---------------------------------------------------------------------------
// finalizeDraft
// ---------------------------------------------------------------------------

// Validate a changed, non-empty candidate against the current memory receipt
// before success. Success => completed (graph advances to machine_gate).
//
// context:
//   projectRoot — absolute project root
//   task        — the freshly reread durable V3 task
//   draft       — relative path of the candidate draft under the project root
function finalizeDraft(context = {}) {
  const root = path.resolve(context.projectRoot || '');
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = resolveDraftStageId(task);

  const draftRel = String(context.draft || '');
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_draft',
      stage_id: stageId,
      failure_family: 'draft_missing',
      draft: draftRel,
      instruction: '只写当前节候选稿，然后重新运行本阶段。',
    });
  }
  const prose = fs.readFileSync(draftFile, 'utf8').trim();
  if (!prose || Array.from(prose).length < 80) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_draft',
      stage_id: stageId,
      failure_family: 'draft_too_short',
      draft: draftRel,
      chars: Array.from(prose).length,
      instruction: '当前候选稿过短；只补当前节正文后重跑。',
    });
  }

  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const projectState = readShortProjectState(root) || {};
  const sectionIndex = resolveSectionIndex({ projectState, task, stageId });
  const memoryCheck = checkShortMemoryStage({
    projectRoot: root,
    task,
    execution,
    sectionIndex,
    stageId,
  });
  if (memoryCheck.blocking) {
    return stageResult({
      kind: 'blocked',
      code: 'short_memory_context_refresh_required',
      stage_id: stageId,
      failure_family: 'memory_context_stale',
      section_index: sectionIndex,
      draft: draftRel,
      memory_status: memoryCheck.memory_status,
      stale_sources: memoryCheck.stale_sources,
      instruction: memoryCheck.instruction,
    });
  }
  const beforeDigest = String(execution.draft_input_digest || '');
  const afterDigest = digestFile(draftFile);
  if (beforeDigest && beforeDigest === afterDigest) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_draft_change',
      stage_id: stageId,
      failure_family: 'draft_unchanged',
      draft: draftRel,
      instruction: '候选稿相对上一版未变化；只修改当前节正文后重跑。',
    });
  }

  return stageResult({
    kind: 'completed',
    code: 'short_draft_accepted',
    stage_id: stageId,
    draft: draftRel,
    draft_digest: afterDigest,
    // No next_stage: the canonical V3 graph is the ONLY transition authority
    // (section_draft -> machine_gate is a single-edge node).
  });
}

// ---------------------------------------------------------------------------
// finalizeRepair
// ---------------------------------------------------------------------------

// A repair is only complete when the candidate prose differs from the exact
// bytes that caused the workflow to enter section_repair. The Engine records
// that input digest when it routes from a gate to section_repair; this service
// is deliberately read-only and returns a StageResult for the Engine to apply.
function finalizeRepair(context = {}) {
  const root = path.resolve(context.projectRoot || '');
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = 'section_repair';
  const draftRel = String(context.draft || '');
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_draft',
      stage_id: stageId,
      failure_family: 'draft_missing',
      draft: draftRel,
      instruction: '只修改当前节候选稿，然后重新运行本阶段。',
    });
  }
  if (!fs.readFileSync(draftFile, 'utf8').trim()) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_draft',
      stage_id: stageId,
      failure_family: 'draft_empty',
      draft: draftRel,
      instruction: '当前候选稿为空；恢复当前节正文后重新运行本阶段。',
    });
  }
  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const beforeDigest = String(execution.draft_input_digest || '');
  const afterDigest = digestFile(draftFile);
  if (!beforeDigest || beforeDigest === afterDigest) {
    return stageResult({
      kind: 'blocked',
      code: 'awaiting_short_draft_change',
      stage_id: stageId,
      failure_family: 'draft_unchanged',
      draft: draftRel,
      instruction: '候选稿相对进入回炉前未发生变化；只修改当前节正文后重新运行本阶段。',
    });
  }
  return stageResult({
    kind: 'completed',
    code: 'short_section_repair_ready',
    stage_id: stageId,
    draft: draftRel,
    draft_digest: afterDigest,
  });
}

// ---------------------------------------------------------------------------
// runMachineGate
// ---------------------------------------------------------------------------

// Call the same real deterministic checks as production V2
// (check-ai-patterns, anti-ai-diagnose, output-pollution-check,
// check-degeneration, story-prose-gate) plus dynamic length policy.
// story-prose-gate runs WITHOUT its --write report mode; V3 evidence lives in
// the task artifact directory. Pass => completed, next_stage story_gate.
// Blocking checks => completed, next_stage section_repair, with structured
// findings.
//
// context:
//   projectRoot — absolute project root
//   task        — the freshly reread durable V3 task
//   draft       — relative path of the candidate draft under the project root
function runMachineGate(context = {}) {
  const root = path.resolve(context.projectRoot || '');
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = 'machine_gate';
  const workflowId = String(task.workflow_id || '');

  const projectState = readShortProjectState(root) || {};
  const sectionIndex = resolveSectionIndex({ projectState, task, stageId });
  if (!sectionIndex) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_identity_missing',
      stage_id: stageId,
      failure_family: 'section_identity_missing',
      instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复当前小节范围。',
    });
  }

  const draftRel = String(context.draft || '');
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'short_draft_missing',
      stage_id: stageId,
      failure_family: 'draft_missing',
      section_index: sectionIndex,
      instruction: '返回当前节草稿阶段恢复候选稿。',
    });
  }

  const draftText = fs.readFileSync(draftFile, 'utf8');
  const actualChars = (draftText.match(/[\u3400-\u9fff]/g) || []).length;
  const outlineContract = buildShortSectionOutlineContract(root, sectionIndex);
  const target = resolveSectionLengthTarget(root, projectState, sectionIndex);
  const lengthPolicy = deriveSectionLengthPolicy({
    projectState,
    sectionIndex,
    actual: actualChars,
    plannedTarget: target.chars,
    plannedTargetRange: target.range,
    plannedTargetSource: target.source,
    targetEnforcement: target.enforcement,
    sectionRole: outlineContract.status === 'current' ? outlineContract.section_role : 'normal',
  });
  const draftDigest = digestFile(draftFile);
  const evidenceRel = `${String(task.task_dir || '')}/artifacts/section-${pad(sectionIndex)}-machine-gate.json`;
  const evidenceFile = safeProjectFile(root, evidenceRel);
  const effectiveLengthPolicy = lengthPolicy;
  const checks = [
    ...runMachineChecks(root, draftFile),
    {
      id: 'short-section-length-policy',
      status: effectiveLengthPolicy.blocking ? 'blocking' : effectiveLengthPolicy.status,
      blocking: effectiveLengthPolicy.blocking === true,
      exit_code: 0,
      finding_count: ['advisory', 'warning', 'decision_required'].includes(String(effectiveLengthPolicy.status || '')) ? 1 : effectiveLengthPolicy.blocking ? 1 : 0,
      message: effectiveLengthPolicy.note || '',
      details: effectiveLengthPolicy,
    },
  ];
  const blocking = checks.filter((item) => item.blocking);

  // Write the machine-gate receipt under the task artifact directory so the
  // shared accept path can consume the real result without a second run.
  if (evidenceFile) {
    atomicWriteJson(evidenceFile, {
      schemaVersion: '1.0.0',
      workflow_id: workflowId,
      section_index: sectionIndex,
      draft: draftRel,
      draft_digest: draftDigest,
      checks,
      length_policy: effectiveLengthPolicy,
      blocking_count: blocking.length,
      created_at: new Date().toISOString(),
    });
  }

  const passed = blocking.length === 0;
  if (passed) {
    return stageResult({
      kind: 'completed',
      code: 'short_machine_gate_passed',
      stage_id: stageId,
      section_index: sectionIndex,
      draft: draftRel,
      draft_digest: draftDigest,
      evidence: evidenceRel,
      length_policy: effectiveLengthPolicy,
      next_stage: 'story_gate',
    });
  }

  return stageResult({
    kind: 'completed',
    code: 'short_machine_gate_blocking',
    stage_id: stageId,
    section_index: sectionIndex,
    draft: draftRel,
    draft_digest: draftDigest,
    evidence: evidenceRel,
    length_policy: effectiveLengthPolicy,
    blocking_findings: blocking.map((item) => ({ code: item.id, message: item.message || `${item.id} 未通过` })),
    next_stage: 'section_repair',
  });
}

// ---------------------------------------------------------------------------
// runStoryGate
// ---------------------------------------------------------------------------

// Validate the real evidence schema, outline obligations and professional
// reader milestone against the current draft digest. Pass => completed and
// graph advances to section_accept. A schema-valid semantic revise decision
// advances to section_repair; malformed or unbound evidence stays at this gate.
// Missing/invalid evidence cannot pass.
//
// context:
//   projectRoot  — absolute project root
//   task         — the freshly reread durable V3 task (retry_state is the ONLY
//                  retry authority the service consults)
//   draft        — relative path of the candidate draft under the project root
//   evidenceFile — relative path of the schema-valid story evidence card
function runStoryGate(context = {}) {
  const root = path.resolve(context.projectRoot || '');
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = 'story_gate';
  const workflowId = String(task.workflow_id || '');

  const projectState = readShortProjectState(root) || {};
  const sectionIndex = resolveSectionIndex({ projectState, task, stageId });
  if (!sectionIndex) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_identity_missing',
      stage_id: stageId,
      failure_family: 'section_identity_missing',
      instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复当前小节范围。',
    });
  }

  const draftRel = String(context.draft || '');
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'short_draft_missing',
      stage_id: stageId,
      failure_family: 'draft_missing',
      section_index: sectionIndex,
      instruction: '返回当前节草稿阶段恢复候选稿。',
    });
  }
  const draftDigest = digestFile(draftFile);
  const draftText = fs.readFileSync(draftFile, 'utf8');

  // Missing evidence cannot auto-pass. Without a supplied evidenceFile the
  // service returns a non-completed StageResult, never a fabricated pass.
  const evidenceRel = String(context.evidenceFile || '');
  const evidenceFile = safeProjectFile(root, evidenceRel);
  if (!evidenceFile || !fs.existsSync(evidenceFile) || !fs.statSync(evidenceFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'short_story_evidence_missing',
      stage_id: stageId,
      failure_family: 'story_evidence_missing',
      section_index: sectionIndex,
      instruction: '当前节缺少可核验的故事质量证据卡；先补齐证据后再运行故事质量门。',
    });
  }
  const evidence = readJson(evidenceFile);
  if (!evidence) {
    return storyFailure(task, stageId, {
      family: 'story_evidence_invalid',
      code: 'short_story_evidence_invalid',
      section_index: sectionIndex,
      evidence: evidenceRel,
      findings: [{ code: 'evidence_card_unreadable' }],
      instruction: '证据卡不可读或不是合法 JSON；只替换证据卡后再运行故事质量门。',
    });
  }

  const outlineContract = buildShortSectionOutlineContract(root, sectionIndex);
  if (outlineContract.status !== 'current') {
    return stageResult({
      kind: 'blocked',
      code: 'short_outline_contract_required',
      stage_id: stageId,
      failure_family: 'outline_contract_required',
      section_index: sectionIndex,
      finding: outlineContract.code || 'outline_contract_missing',
      instruction: '先回到小节大纲补足本节结构功能、子事件与节尾钩子。',
    });
  }

  const findings = validateStoryEvidence({
    evidence, draftDigest, draftText, outlineContract, sectionIndex, workflowId, task,
  });
  if (findings.length) {
    const evidenceFailures = findings.filter((finding) => !SEMANTIC_REVISION_CODES.has(String((finding || {}).code || '')));
    if (evidenceFailures.length === 0) {
      return stageResult({
        kind: 'completed',
        code: 'short_story_value_gate_revision_required',
        stage_id: stageId,
        section_index: sectionIndex,
        draft: draftRel,
        draft_digest: draftDigest,
        evidence: evidenceRel,
        outline_contract_digest: outlineContract.contract_digest,
        findings,
        revision_requirements: readableStoryRevisionRequirements({ findings, evidence, outlineContract }),
        instruction: '当前节需要局部修订；按下列可读要求最小修复，不要重写整节。',
        next_stage: 'section_repair',
      });
    }
    return storyFailure(task, stageId, {
      family: 'story_evidence_invalid',
      code: 'short_story_evidence_invalid',
      section_index: sectionIndex,
      evidence: evidenceRel,
      outline_contract_digest: outlineContract.contract_digest,
      findings: evidenceFailures,
      revision_requirements: readableStoryRevisionRequirements({
        findings: evidenceFailures, evidence, outlineContract,
      }),
      instruction: '当前证据卡与正文或审阅契约不一致；只修复证据卡后重跑，不要改正文。',
    });
  }

  const storyReceiptRel = `${String(task.task_dir || '')}/artifacts/section-${pad(sectionIndex)}-story-gate.json`;
  const storyReceiptFile = safeProjectFile(root, storyReceiptRel);
  if (!storyReceiptFile) {
    return stageResult({
      kind: 'blocked',
      code: 'short_story_receipt_path_invalid',
      stage_id: stageId,
      failure_family: 'story_receipt_invalid',
      section_index: sectionIndex,
      instruction: '当前任务目录无效，无法保存故事质量门回执。',
    });
  }
  atomicWriteJson(storyReceiptFile, {
    schema_version: '1.0.0',
    workflow_id: workflowId,
    section_index: sectionIndex,
    status: 'pass',
    draft: draftRel,
    draft_digest: draftDigest,
    evidence_file: evidenceRel,
    evidence_digest: digestFile(evidenceFile),
    outline_contract_digest: outlineContract.contract_digest,
    acceptance_metadata: evidence.acceptance_metadata && typeof evidence.acceptance_metadata === 'object'
      ? evidence.acceptance_metadata
      : {},
    created_at: new Date().toISOString(),
  });

  return stageResult({
    kind: 'completed',
    code: 'short_story_gate_passed',
    stage_id: stageId,
    section_index: sectionIndex,
    draft: draftRel,
    draft_digest: draftDigest,
    evidence: evidenceRel,
    receipt: storyReceiptRel,
    outline_contract_digest: outlineContract.contract_digest,
    next_stage: 'section_accept',
  });
}

function readableStoryRevisionRequirements({ findings, evidence, outlineContract }) {
  const obligations = new Map((Array.isArray((outlineContract || {}).obligations)
    ? outlineContract.obligations : []).map((item) => [String((item || {}).id || ''), item || {}]));
  const checks = new Map((Array.isArray((evidence || {}).checks)
    ? evidence.checks : []).map((item) => [String((item || {}).id || ''), item || {}]));
  return findings.map((finding) => {
    const code = String((finding || {}).code || '');
    if (code === 'evidence_reader_milestone_kind_mismatch') {
      const expectedKind = String((finding || {}).expected_kind || '');
      const actualKind = String((finding || {}).actual_kind || '');
      return {
        kind: 'reader_milestone',
        id: 'professional_reader_milestone',
        label: '专业读者追读判断',
        requirement: `证据卡 reader_milestone.kind 必须为“${expectedKind}”，当前为“${actualKind}”；只修改证据卡，不要改正文。`,
        expected_kind: expectedKind,
        actual_kind: actualKind,
      };
    }
    if (code === 'draft_outline_obligation_revise') {
      const id = String((finding || {}).obligation_id || '');
      const obligation = obligations.get(id) || {};
      return {
        kind: 'outline_obligation',
        id,
        label: String(obligation.source_text || id),
        requirement: String(obligation.source_text || ''),
      };
    }
    if (code === 'evidence_check_revise') {
      const id = String((finding || {}).check_id || '');
      const check = checks.get(id) || {};
      return {
        kind: 'quality_dimension',
        id,
        label: STORY_QUALITY_LABELS[id] || id,
        requirement: String(check.evidence || '').trim(),
      };
    }
    const milestone = (evidence || {}).reader_milestone || {};
    return {
      kind: 'reader_milestone',
      id: 'professional_reader_milestone',
      label: '专业读者追读判断',
      requirement: String(milestone.repair_direction || milestone.biggest_resistance || '').trim(),
    };
  });
}

// Validate a story evidence card against the actual draft digest, the real
// outline contract digest/obligations, and the professional reader milestone.
// Returns an array of structured findings (empty => pass).
function validateStoryEvidence({ evidence, draftDigest, draftText, outlineContract, sectionIndex, workflowId, task }) {
  const findings = [];
  if (String(evidence.workflow_id || '') !== String(workflowId || '')) {
    findings.push({ code: 'evidence_workflow_mismatch' });
  }
  if (Number(evidence.section_index || 0) !== Number(sectionIndex)) {
    findings.push({ code: 'evidence_section_mismatch' });
  }
  if (String(evidence.draft_digest || '') !== String(draftDigest || '')) {
    findings.push({ code: 'evidence_draft_digest_mismatch' });
  }
  if (String(evidence.outline_contract_digest || '') !== String(outlineContract.contract_digest || '')) {
    findings.push({ code: 'evidence_outline_contract_digest_mismatch' });
  }

  const checks = Array.isArray(evidence.checks) ? evidence.checks : [];
  const knownCheckIds = new Set(QUALITY_CHECKS);
  const seenCheckIds = new Set();
  for (const row of checks) {
    const id = String((row || {}).id || '');
    if (!knownCheckIds.has(id)) continue;
    if (seenCheckIds.has(id)) {
      findings.push({ code: 'evidence_check_duplicate', check_id: id });
      continue;
    }
    seenCheckIds.add(id);
    const status = String((row || {}).status || '');
    if (!['pass', 'revise'].includes(status)) {
      findings.push({ code: 'evidence_check_status_invalid', check_id: id });
      continue;
    }
    if (status === 'revise') {
      findings.push({ code: 'evidence_check_revise', check_id: id });
    }
    const quote = String((row || {}).evidence_quote || '').trim();
    if (quote.length < 4 || !normalizeDraft(draftText).includes(normalizeDraft(quote))) {
      findings.push({ code: 'evidence_check_quote_not_found', check_id: id });
    }
  }
  for (const id of QUALITY_CHECKS) {
    if (!seenCheckIds.has(id)) findings.push({ code: 'evidence_check_missing', check_id: id });
  }

  // Outline obligations: reuse the real draft-coverage validator (digest match,
  // status validity, exact non-reused prose quotes).
  findings.push(...validateDraftOutlineCoverage(evidence, outlineContract, draftText));

  // Professional reader milestone: when the policy requires it, the evidence
  // card must carry a schema-valid reader_milestone bound to the same kind and
  // a real prose quote.
  const readerMilestone = resolveShortReaderMilestone({ sectionIndex, outlineContract, task });
  if (readerMilestone.required) {
    const milestone = evidence.reader_milestone && typeof evidence.reader_milestone === 'object' ? evidence.reader_milestone : null;
    if (!milestone) {
      findings.push({ code: 'evidence_reader_milestone_missing' });
    } else {
      if (String(milestone.reviewer || '') !== String(readerMilestone.reviewer || '')) {
        findings.push({ code: 'evidence_reader_milestone_reviewer_mismatch' });
      }
      if (String(milestone.kind || '') !== String(readerMilestone.kind || '')) {
        findings.push({
          code: 'evidence_reader_milestone_kind_mismatch',
          expected_kind: String(readerMilestone.kind || ''),
          actual_kind: String(milestone.kind || ''),
        });
      }
      const status = String(milestone.status || '');
      if (!['pass', 'revise'].includes(status)) {
        findings.push({ code: 'evidence_reader_milestone_status_invalid' });
      } else if (status === 'revise') {
        findings.push({ code: 'evidence_reader_milestone_revise' });
      }
      const quote = String(milestone.evidence_quote || '').trim();
      if (quote.length < 4 || !normalizeDraft(draftText).includes(normalizeDraft(quote))) {
        findings.push({ code: 'evidence_reader_milestone_quote_not_found' });
      }
    }
  }

  return findings;
}

// ---------------------------------------------------------------------------
// acceptSection
// ---------------------------------------------------------------------------

// Verify the actual machine/story results and exact draft digest; validate
// plan bounds/gaps before committing. Commit through commitAcceptedSection,
// create one accepted anchor, project the accepted section into canonical short
// project-state.json, and append the integration event. Success returns
// completed with next_stage section_brief (another planned section remains) or
// assembly (final planned section). An already accepted identical section is
// idempotent; a changed accepted canonical section is rejected.
//
// context:
//   projectRoot — absolute project root
//   task        — the freshly reread durable V3 task
function acceptSection(context = {}) {
  const root = path.resolve(context.projectRoot || '');
  const task = context.task && typeof context.task === 'object' ? context.task : {};
  const stageId = 'section_accept';
  const workflowId = String(task.workflow_id || '');

  const projectState = readShortProjectState(root) || {};
  const sectionIndex = resolveSectionIndex({ projectState, task, stageId });
  if (!sectionIndex) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_identity_missing',
      stage_id: stageId,
      failure_family: 'section_identity_missing',
      instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复当前小节范围。',
    });
  }

  const revisionPreview = previewShortFeedbackRevisionAcceptance(task, sectionIndex);
  if (revisionPreview.status === 'blocked_feedback_revision_section_mismatch') {
    return stageResult({
      kind: 'blocked',
      code: revisionPreview.status,
      stage_id: stageId,
      failure_family: 'feedback_revision_section_mismatch',
      section_index: sectionIndex,
      expected_section: revisionPreview.next_section,
      instruction: `当前回炉游标在第${revisionPreview.next_section}节，不能采用第${sectionIndex}节。请恢复回炉队列的当前小节。`,
    });
  }

  // Consume the real machine/story receipts written by this service. Both must
  // exist and be bound to the same draft digest; a changed candidate after the
  // gates is rejected.
  const draftRel = resolveAcceptDraftRel(root, task, projectState, sectionIndex, context.draft);
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) {
    return stageResult({
      kind: 'blocked',
      code: 'short_canonical_missing',
      stage_id: stageId,
      failure_family: 'canonical_missing',
      section_index: sectionIndex,
      instruction: '恢复当前节候选稿后重新运行机器门；不要创建空正文。',
    });
  }
  const canonicalRel = `正文/第${pad(sectionIndex)}节.md`;
  const canonicalDigest = digestFile(draftFile);

  const machineArtifact = readMachineArtifact(root, task, sectionIndex);
  const storyArtifact = readStoryArtifact(root, task, sectionIndex);
  const outlineContract = buildShortSectionOutlineContract(root, sectionIndex);
  const receiptIssue = validateAcceptReceipts({
    root, workflowId, sectionIndex, machineArtifact, storyArtifact, draftRel,
    canonicalDigest, outlineContract,
  });
  if (receiptIssue) {
    return stageResult({
      kind: 'completed',
      code: receiptIssue,
      stage_id: stageId,
      section_index: sectionIndex,
      next_stage: 'machine_gate',
      instruction: '候选稿或门禁回执发生变化；重新运行机器门和故事质量门后再采用。',
    });
  }

  // Reject changing an already-accepted canonical section. The canonical file
  // must be byte-identical to the accepted one; a different body for the same
  // section index is an explicit blocked result, never a silent overwrite.
  const titleLock = readJson(shortStateFile(root, 'section-title-lock.json')) || {};
  const confirmedTitle = resolveConfirmedSectionTitle(titleLock, sectionIndex);
  const sectionText = extractSectionBody(fs.readFileSync(draftFile, 'utf8'), sectionIndex);
  const candidateCanonicalHash = crypto.createHash('sha256').update(buildCanonicalSectionText({
    sectionIndex,
    title: confirmedTitle.title,
    text: sectionText,
  })).digest('hex');
  const existingAnchorRel = resolveShortStateRelative(root, `section-${pad(sectionIndex)}-anchor.json`, { forWrite: true });
  const existingAnchorFile = safeProjectFile(root, existingAnchorRel);
  const existingAnchor = readJson(existingAnchorFile);
  const revisionActive = revisionPreview.status !== 'not_applicable';
  if (existingAnchor && String(existingAnchor.status || '') === 'accepted') {
    const acceptedHash = String(existingAnchor.canonical_sha256 || '').replace(/^sha256:/, '');
    if (acceptedHash && acceptedHash !== candidateCanonicalHash && !revisionActive) {
      return stageResult({
        kind: 'blocked',
        code: 'short_section_canonical_changed',
        stage_id: stageId,
        failure_family: 'canonical_changed',
        section_index: sectionIndex,
        instruction: '当前节已采用，且候选稿与已采用正文不一致；已采用正文不可覆盖。如需修订请走反馈回炉流程。',
      });
    }
  }

  // Plan bounds/gap validation. The section must be within the locked plan and
  // have no missing predecessor.
  const outlineText = readText(path.join(root, '小节大纲.md'));
  const plan = resolvePlannedSectionCount({ projectState, titleLock, outlineText });
  if (plan.status !== 'locked') {
    return stageResult({
      kind: 'blocked',
      code: plan.status === 'conflict' ? 'short_section_plan_conflict' : 'short_section_plan_missing',
      stage_id: stageId,
      failure_family: plan.status === 'conflict' ? 'plan_conflict' : 'plan_missing',
      section_index: sectionIndex,
      plan_evidence: plan.candidates,
      instruction: plan.status === 'conflict'
        ? '小节大纲、标题锁与项目状态的总节数不一致；先确认全篇小节数，再继续采用。'
        : '未找到已锁定的全篇小节数；先补齐小节大纲和标题锁，禁止自动生成下一节。',
    });
  }
  if (sectionIndex > plan.count) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_outside_plan',
      stage_id: stageId,
      failure_family: 'section_outside_plan',
      section_index: sectionIndex,
      planned_sections: plan.count,
      instruction: '当前小节超出已确认的全篇规划；必须先扩容小节大纲，不能直接采用。',
    });
  }
  const proposedAcceptedSections = upsertAccepted(projectState.accepted_sections, { section_index: sectionIndex });
  const proposedProgress = resolveShortPlanProgress({
    plannedCount: plan.count, acceptedSections: proposedAcceptedSections, currentSection: sectionIndex,
  });
  const missingBeforeCurrent = (proposedProgress.missing_sections || []).filter((index) => index < sectionIndex);
  if (proposedProgress.status === 'outside_plan' || missingBeforeCurrent.length) {
    return stageResult({
      kind: 'blocked',
      code: proposedProgress.status === 'outside_plan' ? 'short_section_outside_plan' : 'short_section_plan_gap',
      stage_id: stageId,
      failure_family: proposedProgress.status === 'outside_plan' ? 'section_outside_plan' : 'plan_gap',
      section_index: sectionIndex,
      planned_sections: plan.count,
      missing_sections: missingBeforeCurrent,
      instruction: missingBeforeCurrent.length
        ? '当前节存在尚未采用的前置小节；先补齐缺口或重新规划小节顺序。'
        : '当前节超出已确认规划；先调整小节大纲。',
    });
  }

  const metadata = readStoryArtifactMetadata(
    storyArtifact,
    sectionIndex,
    sectionText,
    projectState,
    context.metadata,
  );
  const cjkChars = (sectionText.match(/[\u3400-\u9fff]/g) || []).length;

  let sectionCommit;
  try {
    sectionCommit = commitAcceptedSection(root, {
      task,
      sectionIndex,
      title: confirmedTitle.title,
      text: sectionText,
      metadata,
      projectTitle: resolveShortProjectTitle(projectState, path.basename(root)),
    });
  } catch (error) {
    return stageResult({
      kind: 'blocked',
      code: String((error || {}).status || 'short_section_commit_blocked'),
      stage_id: stageId,
      failure_family: 'commit_blocked',
      section_index: sectionIndex,
      instruction: '当前节未写入正式小节，项目进度未推进。修复提交条件后重试本阶段，不要重写已通过质量门的候选稿。',
      detail: String((error || {}).message || error || ''),
    });
  }

  const acceptedCanonicalRel = String(sectionCommit.canonical_path || canonicalRel);
  const canonicalHash = String(sectionCommit.canonical_sha256 || '');
  const alreadyAccepted = Boolean(sectionCommit.already_accepted);
  const acceptedAt = readAcceptedCommitTime(root, sectionCommit, existingAnchor);

  // One canonical accepted anchor (idempotent on identical re-accept).
  const anchorRel = resolveShortStateRelative(root, `section-${pad(sectionIndex)}-anchor.json`, { forWrite: true });
  const anchorFile = safeProjectFile(root, anchorRel);
  const acceptedSections = upsertAccepted(projectState.accepted_sections, {
    section_index: sectionIndex,
    title: confirmedTitle.title,
    canonical_path: acceptedCanonicalRel,
    anchor_path: anchorRel,
    sha256: canonicalHash,
    section_commit_id: String(sectionCommit.commit_id || ''),
    length_chars: cjkChars,
    quality_status: 'machine_and_story_gates_passed',
  });
  const progress = resolveShortPlanProgress({
    plannedCount: plan.count, acceptedSections, currentSection: sectionIndex,
  });
  if (progress.status === 'outside_plan') {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_outside_plan',
      stage_id: stageId,
      failure_family: 'section_outside_plan',
      section_index: sectionIndex,
      planned_sections: plan.count,
      instruction: '已采用小节超出全篇规划；先修复项目状态，禁止继续生成 Brief。',
    });
  }
  if (!progress.completed && !progress.next_section) {
    return stageResult({
      kind: 'blocked',
      code: 'short_section_plan_gap',
      stage_id: stageId,
      failure_family: 'plan_gap',
      section_index: sectionIndex,
      planned_sections: plan.count,
      missing_sections: progress.missing_sections,
      instruction: '已采用小节存在前置缺口；先补齐或明确跳过缺失小节，禁止生成计划外下一节。',
    });
  }
  // A revision queue only owns the order while another affected section still
  // remains in that queue. Once the local queue is complete, resume the actual
  // locked story plan. Otherwise a one-section rework on a fresh three-section
  // project can falsely report the whole story complete and jump to assembly
  // while sections 2-3 do not exist.
  const workflowProgress = revisionActive && !revisionPreview.completed
    ? {
      ...progress,
      completed: false,
      next_section: revisionPreview.next_section,
      missing_sections: revisionPreview.remaining_sections,
    }
    : progress;

  const acceptedAnchorCurrent = isAcceptedAnchorCurrent(existingAnchor, canonicalHash, acceptedCanonicalRel);
  const acceptedProjectStateCurrent = isAcceptedProjectStateCurrent(
    projectState,
    sectionIndex,
    canonicalHash,
    acceptedCanonicalRel,
    anchorRel,
  );

  if ((!alreadyAccepted || !acceptedAnchorCurrent) && anchorFile) {
    atomicWriteJson(anchorFile, buildAcceptAnchor({
      workflowId, projectState, sectionIndex, confirmedTitle, acceptedCanonicalRel,
      canonicalHash, sectionCommit, execution: task.stage_execution || {}, cjkChars,
      metadata, acceptedSections, plan, progress: workflowProgress,
      lengthPolicy: machineArtifact.length_policy, acceptedAt,
      memoryBasis: context.memoryBasis,
    }));
  }

  // Canonical project-state accepted entry (single source of truth under
  // 追踪/story-system/short). Idempotent on identical re-accept.
  if (!alreadyAccepted || !acceptedProjectStateCurrent) {
    writeAcceptedProjectState(root, {
      projectState, acceptedSections, sectionIndex, confirmedTitle, progress: workflowProgress, plan,
    });
  }

  let integrationEvent;
  try {
    integrationEvent = appendIntegrationEvent(root, {
      event_type: 'section_accepted',
      workflow_id: workflowId,
      project_id: String(projectState.project_id || ''),
      project_title: resolveShortProjectTitle(projectState, path.basename(root)),
      artifact_path: acceptedCanonicalRel,
      artifact_digest: canonicalHash,
      summary: String(metadata.section_summary || `第${sectionIndex}节已采用`).slice(0, 1000),
      tags: ['short_write', `section_${pad(sectionIndex)}`],
    });
  } catch (error) {
    integrationEvent = { status: 'deferred', message: String(error.message || error) };
  }

  const allCompleted = workflowProgress.completed;
  const assemblyRevalidationContinues = revisionActive
    && ['full_story_assembly', 'full_story_editorial_length'].includes(
      String((((task || {}).feedback_revision_queue || {}).source_stage) || ''),
    )
    && !allCompleted;
  const recoveredDerivedState = alreadyAccepted && (
    !acceptedAnchorCurrent
    || !acceptedProjectStateCurrent
    || String((integrationEvent || {}).status || '') === 'appended'
  );
  return stageResult({
    kind: 'completed',
    code: recoveredDerivedState
      ? 'short_section_accept_recovered'
      : (alreadyAccepted ? 'short_section_accept_idempotent' : 'short_section_accepted'),
    stage_id: stageId,
    section_index: sectionIndex,
    section_title: confirmedTitle.title,
    canonical_path: acceptedCanonicalRel,
    canonical_sha256: canonicalHash,
    commit_id: String(sectionCommit.commit_id || ''),
    projection_status: String(sectionCommit.projection_status || ''),
    anchor_path: anchorRel,
    integration_event: integrationEvent,
    planned_sections: plan.count,
    remaining_sections: workflowProgress.missing_sections || [],
    next_section: workflowProgress.next_section || null,
    all_sections_completed: allCompleted,
    length_policy: machineArtifact.length_policy || null,
    next_stage: allCompleted ? 'assembly' : assemblyRevalidationContinues ? 'machine_gate' : 'section_brief',
  });
}

// ---------------------------------------------------------------------------
// Shared helpers (module-private; not exported)
// ---------------------------------------------------------------------------

// Build a failure StageResult honoring the durable retry_state: the first
// same-family failure on a stage returns retryable_internal (the Engine then
// persists retry_state); a repeated same stage+family failure escalates to a
// structured, unnumbered needs_author_choice. The family is the only retry
// key — a different family resets the count and stays internal.
function briefFailure(task, stageId, detail) {
  return retryAwareFailure(task, stageId, detail);
}

function storyFailure(task, stageId, detail) {
  return retryAwareFailure(task, stageId, detail);
}

function retryAwareFailure(task, stageId, detail) {
  const family = String(detail.family || detail.code || 'stage_failure');
  const previous = task.retry_state && typeof task.retry_state === 'object' ? task.retry_state : null;
  const exhausted = Boolean(previous)
    && String(previous.stage_id || '') === String(stageId || '')
    && String(previous.failure_family || '') === family
    && Number(previous.count || 0) >= 1;

  if (!exhausted) {
    return stageResult({
      kind: 'retryable_internal',
      code: detail.code,
      stage_id: stageId,
      failure_family: family,
      section_index: detail.section_index,
      brief: detail.brief,
      draft: detail.draft,
      evidence: detail.evidence,
      findings: detail.findings,
      revision_requirements: detail.revision_requirements,
      freshness: detail.freshness,
      outline_contract_digest: detail.outline_contract_digest,
      chars: detail.chars,
      missing_signals: detail.missing_signals,
      instruction: detail.instruction,
    });
  }

  return stageResult({
    kind: 'needs_author_choice',
    code: detail.code,
    stage_id: stageId,
    failure_family: family,
    section_index: detail.section_index,
    question: '当前阶段已连续未通过同项校验；请选择处理方式，避免模型反复重写浪费 token。',
    options: RETRY_EXHAUSTION_OPTIONS,
    brief: detail.brief,
    draft: detail.draft,
    evidence: detail.evidence,
    findings: detail.findings,
    revision_requirements: detail.revision_requirements,
    freshness: detail.freshness,
    outline_contract_digest: detail.outline_contract_digest,
    instruction: detail.instruction,
  });
}

// Resolve the V3 brief stage id from the durable task. The shared service is
// called with the canonical V3 id (section_brief by default).
function resolveBriefStageId(task) {
  const stageId = String((task && task.current_stage) || '');
  return BRIEF_STAGES.has(stageId) ? stageId : 'section_brief';
}

function resolveDraftStageId(task) {
  const stageId = String((task && task.current_stage) || '');
  return DRAFT_STAGES.has(stageId) ? stageId : 'section_draft';
}

// Resolve the current section index from the durable task and project state.
// Reuses the real short-workflow-state inference (no test-injected override).
function resolveSectionIndex({ projectState, task, stageId }) {
  const executionSection = Number((((task || {}).stage_execution || {}).section_index) || 0);
  if (['section_brief', 'section_draft', 'machine_gate', 'section_repair', 'story_gate', 'section_accept'].includes(String(stageId || ''))
      && Number.isInteger(executionSection) && executionSection > 0) {
    return executionSection;
  }
  return inferShortSectionIndex({
    projectState: projectState || {},
    stageId: String(stageId || ''),
    scope: String((task || {}).scope || ''),
  }) || 0;
}

// Run the five real deterministic machine-gate checks. story-prose-gate runs
// without --write so no unrelated report file is produced.
function runMachineChecks(root, draftFile) {
  return MACHINE_CHECK_COMMANDS.map(([id, script, argsFor]) => {
    const cliArgs = argsFor(draftFile);
    // anti-ai-diagnose takes the draft as the final positional arg.
    const fullArgs = id === 'anti-ai-diagnose' ? [...cliArgs, draftFile] : cliArgs;
    const run = spawnSync(process.execPath, [path.join(__dirname, '..', '..', script), ...fullArgs], {
      cwd: root,
      encoding: 'utf8',
      maxBuffer: 4 * 1024 * 1024,
    });
    const parsed = parseJson(run.stdout);
    const findingCount = countFindings(parsed);
    const blocking = run.status !== 0 || hasBlocking(parsed);
    return {
      id,
      status: blocking ? 'blocking' : 'pass',
      blocking,
      exit_code: Number.isInteger(run.status) ? run.status : 1,
      finding_count: findingCount,
      message: blocking ? firstBlockingMessage(parsed, run.stderr) : '',
    };
  });
}

// Resolve the draft relative path the accept path should bind. The accept
// stage consumes the candidate draft that the gates just verified.
function resolveAcceptDraftRel(root, task, projectState, sectionIndex, explicit) {
  const padded = pad(sectionIndex);
  const candidates = [
    String(explicit || ''),
    `草稿_第${padded}节_候选.md`,
    `正文/第${padded}节.md`,
  ];
  for (const candidate of candidates) {
    const file = safeProjectFile(root, candidate);
    if (file && fs.existsSync(file) && fs.statSync(file).isFile()) return candidate;
  }
  return '';
}

// Read the machine-gate artifact written by runMachineGate for this section.
function readMachineArtifact(root, task, sectionIndex) {
  const rel = `${String((task || {}).task_dir || '')}/artifacts/section-${pad(sectionIndex)}-machine-gate.json`;
  return readJson(safeProjectFile(root, rel));
}

// Read the exact pass receipt written by runStoryGate for this section. The
// raw reviewer card remains separate evidence and is digest-bound by receipt.
function readStoryArtifact(root, task, sectionIndex) {
  const rel = `${String((task || {}).task_dir || '')}/artifacts/section-${pad(sectionIndex)}-story-gate.json`;
  return readJson(safeProjectFile(root, rel));
}

// Validate that both gate receipts are passes and bind to the same immutable
// candidate, evidence card, outline contract, workflow, and section.
function validateAcceptReceipts({
  root, workflowId, sectionIndex, machineArtifact, storyArtifact, draftRel,
  canonicalDigest, outlineContract,
}) {
  if (!machineArtifact) return 'accept_machine_receipt_missing';
  if (!storyArtifact) return 'accept_story_receipt_missing';
  if (String(machineArtifact.workflow_id || '') !== String(workflowId || '')
      || String(storyArtifact.workflow_id || '') !== String(workflowId || '')
      || Number(machineArtifact.section_index || 0) !== Number(sectionIndex)
      || Number(storyArtifact.section_index || 0) !== Number(sectionIndex)) {
    return 'accept_receipt_scope_mismatch';
  }
  const machineChecks = Array.isArray(machineArtifact.checks) ? machineArtifact.checks : [];
  if (Number(machineArtifact.blocking_count || 0) !== 0
      || machineChecks.some((check) => (check || {}).blocking === true
        || String((check || {}).status || '') === 'blocking')) {
    return 'accept_machine_gate_not_passed';
  }
  if (String(storyArtifact.status || '') !== 'pass') return 'accept_story_gate_not_passed';
  const machineDigest = normalizeHash(String(machineArtifact.draft_digest || ''));
  const storyDigest = normalizeHash(String(storyArtifact.draft_digest || ''));
  const canonical = normalizeHash(canonicalDigest);
  if (!machineDigest || !storyDigest) return 'accept_receipt_digest_missing';
  if (machineDigest !== canonical || storyDigest !== canonical) return 'accept_candidate_changed_after_gates';
  const machineDraft = String(machineArtifact.draft || '');
  const storyDraft = String(storyArtifact.draft || '');
  if ((machineDraft && machineDraft !== draftRel) || (storyDraft && storyDraft !== draftRel)) {
    return 'accept_receipt_candidate_mismatch';
  }
  const evidenceFile = safeProjectFile(root, String(storyArtifact.evidence_file || ''));
  if (!evidenceFile || !fs.existsSync(evidenceFile) || !fs.statSync(evidenceFile).isFile()
      || normalizeHash(digestFile(evidenceFile)) !== normalizeHash(storyArtifact.evidence_digest)) {
    return 'accept_story_evidence_changed';
  }
  if (!outlineContract || outlineContract.status !== 'current'
      || String(storyArtifact.outline_contract_digest || '') !== String(outlineContract.contract_digest || '')) {
    return 'accept_outline_contract_changed';
  }
  return '';
}

function readStoryArtifactMetadata(storyArtifact, sectionIndex, sectionText, projectState, override) {
  const explicit = storyArtifact && storyArtifact.acceptance_metadata && typeof storyArtifact.acceptance_metadata === 'object'
    ? storyArtifact.acceptance_metadata
    : {};
  const supplied = override && typeof override === 'object' && !Array.isArray(override) ? override : {};
  const accepted = { ...explicit, ...supplied };
  const paragraphs = String(sectionText || '').split(/\n\s*\n/).map((item) => item.trim()).filter(Boolean);
  const openHook = (String(accepted.open_hook || '').trim() || paragraphs.slice(-2).join('\n\n')).slice(-500);
  return {
    schema_version: '1.0.0',
    generated_by: 'short-production-section-loop',
    section_index: sectionIndex,
    section_summary: String(accepted.section_summary || paragraphs.slice(0, 2).join(' ').slice(0, 800)),
    open_hook: openHook,
    section_cjk_chars: (String(sectionText || '').match(/[\u3400-\u9fff]/g) || []).length,
    revealed_information: stringArray(accepted.revealed_information),
    present_characters: stringArray(accepted.present_characters),
    character_state: objectValue(accepted.character_state),
    relationship_state: objectValue(accepted.relationship_state),
    knowledge_state: objectValue(accepted.knowledge_state),
    world_state: objectValue(accepted.world_state),
    decisions: stringArray(accepted.decisions),
    causal_links: arrayValue(accepted.causal_links),
    promise_deltas: arrayValue(accepted.promise_deltas),
    protagonist: String(accepted.protagonist || '').trim(),
    next_section_handoff: {
      previous_section: sectionIndex,
      open_hook: openHook,
      carry_forward: stringArray(accepted.carry_forward).slice(0, 4),
    },
  };
}

function buildAcceptAnchor(input) {
  const { workflowId, projectState, sectionIndex, confirmedTitle, acceptedCanonicalRel,
    canonicalHash, sectionCommit, execution, cjkChars, metadata, acceptedSections, plan, progress,
    lengthPolicy, acceptedAt, memoryBasis } = input;
  return {
    schema_version: '1.0.0',
    workflow_id: workflowId,
    project_id: String(projectState.project_id || ''),
    section_index: sectionIndex,
    section_title: confirmedTitle.title,
    section_title_confirmed: confirmedTitle.confirmed,
    status: 'accepted',
    canonical_path: acceptedCanonicalRel,
    canonical_sha256: canonicalHash,
    section_commit_id: String(sectionCommit.commit_id || ''),
    stage_attempt_id: String((execution || {}).stage_attempt_id || ''),
    section_cjk_chars: cjkChars,
    accepted_at: acceptedAt,
    section_summary: String(metadata.section_summary || '').slice(0, 800),
    revealed_information: metadata.revealed_information,
    character_state: metadata.character_state,
    relationship_state: metadata.relationship_state,
    decisions: metadata.decisions,
    knowledge_state: metadata.knowledge_state,
    world_state: metadata.world_state,
    present_characters: metadata.present_characters,
    causal_links: metadata.causal_links,
    promise_deltas: metadata.promise_deltas,
    protagonist: metadata.protagonist,
    open_hook: String(metadata.open_hook || '').slice(0, 500),
    quality_result: {
      machine_gate: 'pass',
      story_value_gate: 'pass',
      quality_gate: 'pass',
      repetition_gate: 'pass',
      blocking_findings: [],
      length_policy: lengthPolicy || null,
    },
    memory_basis: memoryBasis && typeof memoryBasis === 'object' ? memoryBasis : null,
    remaining_sections: progress.missing_sections || [],
  };
}

// Project the accepted section into the canonical short project-state.json.
// Idempotent: upsertAccepted deduplicates by section_index, so re-accepting an
// identical section does not duplicate the entry.
function writeAcceptedProjectState(root, input) {
  const { projectState, acceptedSections, sectionIndex, confirmedTitle, progress, plan } = input;
  const file = shortStateFile(root, 'project-state.json', { forWrite: true });
  const current = readJson(file) || projectState || {};
  atomicWriteJson(file, {
    ...current,
    schema_version: String(current.schema_version || '2.0.0'),
    status: progress.completed ? 'all_sections_accepted' : `section_${pad(sectionIndex)}_accepted`,
    current_stage: progress.completed ? 'assembly_ready' : 'next_section_brief_ready',
    current_section_index: progress.completed ? Number(sectionIndex) : Number(progress.next_section),
    accepted_sections: acceptedSections,
    planned_sections: Number(plan.count || current.planned_sections || 0),
    updated_at: new Date().toISOString(),
  });
}

function resolveConfirmedSectionTitle(titleLock, sectionIndex) {
  const item = (Array.isArray((titleLock || {}).sections) ? titleLock.sections : [])
    .find((entry) => Number((entry || {}).section_index) === sectionIndex);
  if (item && item.confirmed === true) {
    return { title: String(item.title || '').trim() || `第${sectionIndex}节`, confirmed: true };
  }
  return { title: `第${sectionIndex}节`, confirmed: false };
}

// Extract the body of the current section from the candidate draft. If the
// draft has only a single section heading (or none), the whole text is the
// section body.
function extractSectionBody(text, sectionIndex) {
  const lines = String(text || '').split(/\r?\n/);
  const headings = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (/^#{1,6}\s+/.test(lines[index].trim())) headings.push(index);
  }
  if (headings.length <= 1) return String(text || '');
  const offset = Math.min(Math.max(sectionIndex - 1, 0), headings.length - 1);
  return lines.slice(headings[offset] + 1, headings[offset + 1] === undefined ? lines.length : headings[offset + 1]).join('\n');
}

function upsertAccepted(items, value) {
  const rows = Array.isArray(items) ? items.filter((item) => Number((item || {}).section_index) !== value.section_index) : [];
  rows.push(value);
  return rows.sort((a, b) => Number(a.section_index) - Number(b.section_index));
}

function isAcceptedAnchorCurrent(anchor, canonicalHash, canonicalPath) {
  if (!anchor || String(anchor.status || '') !== 'accepted') return false;
  return normalizeSha256(anchor.canonical_sha256) === normalizeSha256(canonicalHash)
    && String(anchor.canonical_path || '') === String(canonicalPath || '');
}

function readAcceptedCommitTime(root, sectionCommit, existingAnchor) {
  const commitId = String((sectionCommit || {}).commit_id || '');
  if (/^[A-Za-z0-9._-]+$/u.test(commitId)) {
    const commit = readJson(path.join(root, '追踪', 'story-system', 'commits', `${commitId}.json`));
    if (commit && String(commit.accepted_at || '').trim()) return String(commit.accepted_at);
  }
  if (existingAnchor && String(existingAnchor.accepted_at || '').trim()) {
    return String(existingAnchor.accepted_at);
  }
  return new Date().toISOString();
}

function isAcceptedProjectStateCurrent(projectState, sectionIndex, canonicalHash, canonicalPath, anchorPath) {
  const entry = (Array.isArray((projectState || {}).accepted_sections)
    ? projectState.accepted_sections
    : []).find((item) => Number((item || {}).section_index) === Number(sectionIndex));
  if (!entry) return false;
  return normalizeSha256(entry.sha256) === normalizeSha256(canonicalHash)
    && String(entry.canonical_path || '') === String(canonicalPath || '')
    && String(entry.anchor_path || '') === String(anchorPath || '');
}

function normalizeSha256(value) {
  return String(value || '').replace(/^sha256:/u, '');
}

// Brief quality analysis (reused from the legacy Brief finalize so the shared
// service and the V2 wrapper apply the same dynamic budget rule).
function analyzeBriefQuality(text) {
  const source = String(text || '');
  const compactChars = source.replace(/\s/gu, '').length;
  const targetChars = plannedTargetChars(source);
  const briefBudget = targetChars ? Math.max(1200, Math.round(targetChars * 2.5)) : 6000;
  const beatCount = countCausalBeats(source);
  const beatBudget = targetChars ? Math.max(4, Math.ceil(targetChars / 220)) : 12;
  const findings = [];
  if (compactChars > briefBudget) findings.push('brief_repeats_or_exceeds_dynamic_budget');
  if (beatCount > beatBudget) findings.push('beat_density_exceeds_prose_capacity');
  const executionText = source.replace(/#{1,6}\s+大纲覆盖映射[^\n]*\n[\s\S]*?(?=\n#{1,6}\s+|$)/u, '');
  const evidenceCount = evidenceMechanismCount(executionText);
  const responsibilityCount = sectionResponsibilityCount(executionText);
  if (evidenceCount > 3) findings.push('evidence_mechanism_overload');
  if (responsibilityCount > 4) findings.push('section_responsibility_overload');
  if (evidenceCount >= 3 && responsibilityCount >= 4) findings.push('section_focus_overload');
  return {
    status: findings.length ? 'blocking' : 'pass',
    target_chars: targetChars,
    brief_chars: compactChars,
    dynamic_brief_budget: briefBudget,
    beat_count: beatCount,
    dynamic_beat_budget: beatBudget,
    evidence_mechanism_count: evidenceCount,
    section_responsibility_count: responsibilityCount,
    findings,
  };
}

function countCausalBeats(text) {
  const source = String(text || '');
  const section = extractHeadingSection(source, /(?:因果(?:动作|链)?|动作链|情节节拍|事件节拍)/u);
  if (!section) return 0;
  const numbered = section.split(/\r?\n/u).filter((line) => /^\s*\d+[.、)]\s*/u.test(line)).length;
  if (numbered) return numbered;
  return section
    .replace(/^\s*[-*]\s*/gmu, '')
    .split(/[;；\n]+/u)
    .map((item) => item.trim())
    .filter((item) => item && !/^#+\s*/u.test(item)).length;
}

function extractHeadingSection(text, headingPattern) {
  const lines = String(text || '').split(/\r?\n/u);
  const start = lines.findIndex((line) => /^#{1,6}\s+/u.test(line) && headingPattern.test(line));
  if (start < 0) return '';
  const body = [];
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^#{1,6}\s+/u.test(lines[index])) break;
    body.push(lines[index]);
  }
  return body.join('\n').trim();
}

function evidenceMechanismCount(text) {
  return countStructuredBriefItems(text, /(?:证据机制|证据载体|核验机制|验证材料)/u);
}

function sectionResponsibilityCount(text) {
  return countStructuredBriefItems(text, /(?:本节承担项|本节责任|收束责任|结果责任|后果处理)/u);
}

function countStructuredBriefItems(text, headingPattern) {
  const section = extractHeadingSection(String(text || ''), headingPattern);
  if (!section) return 0;
  const lines = section.split(/\r?\n/u).map((line) => line.trim()).filter(Boolean);
  const listed = lines.filter((line) => /^(?:[-*]\s+|\d+[.、)]\s*)/u.test(line)).length;
  if (listed) return listed;
  return section.split(/[;；\n]+/u).map((item) => item.trim()).filter(Boolean).length;
}

// Machine-gate check output helpers.
function hasBlocking(value) {
  if (!value || typeof value !== 'object') return false;
  if (Array.isArray(value)) return value.some(hasBlocking);
  for (const [key, child] of Object.entries(value)) {
    if (/blocking_count|blockingCount|blocking/i.test(key) && typeof child === 'number' && child > 0) return true;
    if (/blocking|blocked/i.test(key) && child === true) return true;
    if (/status|result|verdict/i.test(key) && typeof child === 'string' && /(block|fail|reject|error)/i.test(child)) return true;
    if (/severity/i.test(key) && String(child).toLowerCase() === 'blocking') return true;
    if (hasBlocking(child)) return true;
  }
  return false;
}

function countFindings(value) {
  if (!value || typeof value !== 'object') return 0;
  if (Array.isArray(value)) return value.reduce((sum, item) => sum + countFindings(item), 0);
  let count = 0;
  for (const [key, child] of Object.entries(value)) {
    if (/findings/i.test(key) && Array.isArray(child)) count += child.length;
    else count += countFindings(child);
  }
  return count;
}

function firstMessage(parsed, stderr) {
  const stack = [parsed];
  while (stack.length) {
    const item = stack.shift();
    if (!item || typeof item !== 'object') continue;
    if (typeof item.message === 'string' && item.message.trim()) return item.message.trim().slice(0, 300);
    stack.push(...(Array.isArray(item) ? item : Object.values(item)));
  }
  return String(stderr || '').trim().slice(0, 300);
}

function firstBlockingMessage(parsed, stderr) {
  const stack = [parsed];
  while (stack.length) {
    const item = stack.shift();
    if (!item || typeof item !== 'object') continue;
    if (!Array.isArray(item)
        && hasDirectBlocking(item)
        && typeof item.message === 'string'
        && item.message.trim()) {
      return item.message.trim().slice(0, 300);
    }
    stack.push(...(Array.isArray(item) ? item : Object.values(item)));
  }
  return firstMessage(parsed, stderr);
}

function hasDirectBlocking(value) {
  return Object.entries(value || {}).some(([key, child]) => {
    if (/blocking_count|blockingCount|blocking/i.test(key) && typeof child === 'number' && child > 0) return true;
    if (/blocking|blocked/i.test(key) && child === true) return true;
    if (/status|result|verdict/i.test(key) && typeof child === 'string' && /(block|fail|reject|error)/i.test(child)) return true;
    return /severity/i.test(key) && String(child).toLowerCase() === 'blocking';
  });
}

function firstProseOutput(result) {
  return ((result || {}).outputs || []).map(String).find((item) => /\.md$/u.test(item)) || '';
}

// Generic file/process helpers.
function safeProjectFile(root, rel) {
  const value = String(rel || '').trim();
  if (!value || path.isAbsolute(value) || value.split(/[\\/]+/).includes('..')) return '';
  const file = path.resolve(root, value);
  return value && file !== root && file.startsWith(`${root}${path.sep}`) ? file : '';
}

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function normalizeHash(value) {
  return String(value || '').replace(/^sha256:/, '');
}

function normalizeDraft(value) {
  return String(value || '').replace(/[\s，。；：、“”‘’《》【】（）()\-—_]/gu, '');
}

function pad(value) {
  return String(value).padStart(3, '0');
}

function readJson(file) {
  try {
    return file && fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
  } catch (_) {
    return null;
  }
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (_) {
    return '';
  }
}

function parseJson(text) {
  const value = String(text || '').trim();
  if (!value) return null;
  try {
    return JSON.parse(value);
  } catch (_) {
    const lines = value.split(/\r?\n/).filter(Boolean);
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      try {
        return JSON.parse(lines[index]);
      } catch (_) {
        // continue
      }
    }
    return null;
  }
}

function stringArray(value) {
  return Array.isArray(value) ? value.map(String).map((item) => item.trim()).filter(Boolean).slice(0, 20) : [];
}

function objectValue(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function arrayValue(value) {
  return Array.isArray(value) ? value.slice(0, 24) : [];
}

module.exports = {
  finalizeBrief,
  finalizeDraft,
  finalizeRepair,
  runMachineGate,
  runStoryGate,
  acceptSection,
  analyzeBriefQuality,
  countCausalBeats,
  evidenceMechanismCount,
  plannedTargetChars,
  sectionResponsibilityCount,
};
