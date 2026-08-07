#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { classifyWorkflowApply, recoverableStageResult } = require('./lib/workflow-apply-result');
const { finish, parseJson, readJson, relative } = require('./lib/cli-utils');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferShortSectionIndex } = require('./lib/short-workflow-state');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { renderPendingActionText } = require('./lib/workflow-action-renderer');
const { ensureCurrentShortMemoryStage } = require('./lib/short-memory-stage-recovery');
const { readShortProjectState } = require('./lib/short-project-state');
const { resolveShortReaderMilestone } = require('./lib/short-reader-milestone-policy');
const { runStoryGate } = require('./lib/short-production/section-loop');
const {
  LEGACY_CHECK_GROUPS,
  QUALITY_CHECKS: CHECKS,
  buildShortQualityEvidenceSchema,
} = require('./lib/short-section-quality-evidence');
const {
  buildShortSectionOutlineContract,
  validateBriefOutlineCoverage,
  validateDraftOutlineCoverage,
} = require('./lib/short-section-outline-contract');
const { invokeApplyResult } = require('./lib/workflow-state-machine-invoke');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  let task = authority.task;
  if (Number(task.engine_version) === 3) return finish({ status: 'v3_engine_apply_required', workflow_id: workflowId, instruction: 'V3 任务必须直接调用共享 service，并通过 V3 Engine 应用 StageResult。' }, 2, args.json);
  if (!['short_write', 'private_short_startup', 'short_startup'].includes(String(task.workflow_type || ''))) {
    return finish({ status: 'blocked_not_short_write', workflow_id: workflowId }, 2, args.json);
  }
  const stageId = String(task.current_stage || '');
  if (!['quality_gate', 'story_value_gate'].includes(stageId)) {
    return finish({ status: 'stage_action_not_applicable', expected: 'quality_gate', actual: stageId, instruction: '重新读取当前任务的 execution_command；不要重试旧阶段命令。' }, 0, args.json);
  }
  let execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== stageId) {
    return finish({ status: 'stage_execution_not_ready', workflow_id: workflowId, instruction: '先由工作流启动故事质量门，再运行本命令。' }, 0, args.json);
  }
  const projectState = readShortProjectState(root) || {};
  const sectionIndex = inferShortSectionIndex({ projectState, stageId, scope: String(task.scope || '') });
  if (!sectionIndex) return finish({ status: 'blocked_short_section_identity_missing', instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复小节范围，不得默认审查第1节。' }, 0, args.json);
  const memoryGate = ensureCurrentShortMemoryStage({ projectRoot: root, workflowId, task, execution, sectionIndex, stageId });
  if (memoryGate.blocking) {
    return finish({
      status: memoryGate.status,
      section_index: sectionIndex,
      memory_status: memoryGate.memory_status,
      stale_sources: memoryGate.stale_sources,
      resume_stage: memoryGate.resume_stage,
      instruction: memoryGate.instruction,
    }, 0, args.json);
  }
  task = memoryGate.task;
  execution = memoryGate.execution;
  const draft = resolveDraft(root, task, sectionIndex, args.draft);
  const brief = path.join(root, `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`);
  if (!draft || !fs.existsSync(brief)) {
    return finish(recoverableStageResult(task, 'short_quality_inputs_missing', '恢复当前节写作提要与候选稿后再做故事质量判断。', { section_index: sectionIndex, draft: relative(root, draft), brief: relative(root, brief) }), 0, args.json);
  }
  const outlineContract = buildShortSectionOutlineContract(root, sectionIndex);
  if (outlineContract.status !== 'current') {
    return finish(recoverableStageResult(task, 'short_outline_contract_required', '先回到小节大纲补足当前节合同，不得用正文临场补剧情。', { section_index: sectionIndex, finding: outlineContract.code || 'outline_contract_missing' }), 0, args.json);
  }
  const readerMilestone = resolveShortReaderMilestone({ sectionIndex, outlineContract, task });
  const briefText = fs.readFileSync(brief, 'utf8');
  const briefCoverage = validateBriefOutlineCoverage(briefText, outlineContract);
  if (briefCoverage.status !== 'pass') {
    return finish({ status: 'short_quality_brief_outline_drift', section_index: sectionIndex, findings: briefCoverage.findings, instruction: '当前 Brief 已偏离确认大纲；回到本节 Brief 重建，不审查也不采用当前正文。' }, 0, args.json);
  }

  const evidenceRel = String(args.evidenceFile || execution.quality_evidence_target || `${task.task_dir}/artifacts/section-${String(sectionIndex).padStart(3, '0')}-story-review.json`);
  const evidenceFile = safeProjectFile(root, evidenceRel);
  const evidenceRead = readQualityEvidence(evidenceFile);
  const review = normalizeQualityEvidence(evidenceRead.value || {}, {
    workflowId,
    sectionIndex,
    draft,
    outlineContract,
  });
  if (evidenceRead.repaired) atomicWriteJson(evidenceFile, evidenceRead.value);
  const canonicalEvidenceRel = `${task.task_dir}/artifacts/section-${String(sectionIndex).padStart(3, '0')}-story-review-normalized.json`;
  const canonicalEvidenceFile = safeProjectFile(root, canonicalEvidenceRel);
  if (!canonicalEvidenceFile) return finish({ status: 'blocked_quality_evidence_path_unsafe', path: canonicalEvidenceRel }, 2, args.json);
  atomicWriteJson(canonicalEvidenceFile, review);
  const draftRel = relative(root, draft);
  const shared = runStoryGate({
    projectRoot: root,
    task: {
      ...task,
      current_stage: 'story_gate',
      retry_state: null,
      stage_execution: { ...execution, stage_id: 'story_gate', section_index: sectionIndex },
    },
    draft: draftRel,
    evidenceFile: canonicalEvidenceRel,
  });
  if (shared.kind === 'blocked') {
    return finish(recoverableStageResult(task, shared.code, shared.instruction, {
      section_index: sectionIndex,
      evidence_file: evidenceRel,
      findings: shared.findings,
      evidence_schema: buildQualityEvidenceSchema({
        workflowId,
        sectionIndex,
        draft,
        outlineContract,
        readerMilestone,
      }),
    }), 0, args.json);
  }
  const sharedFindings = Array.isArray(shared.findings) ? shared.findings : [];
  const revisionOnly = new Set([
    'evidence_check_revise',
    'draft_outline_obligation_revise',
    'evidence_reader_milestone_revise',
  ]);
  const schemaFindings = sharedFindings.filter((finding) => !revisionOnly.has(String((finding || {}).code || '')));
  if (shared.kind !== 'completed' && schemaFindings.length) {
    return finish(recoverableStageResult(task, 'quality_evidence_required', '按 evidence_schema 补当前质量证据卡后重跑同一命令；不要改正文或读取工作流源码。', {
      section_index: sectionIndex,
      evidence_file: evidenceRel,
      findings: schemaFindings,
      evidence_schema: buildQualityEvidenceSchema({
        workflowId,
        sectionIndex,
        draft,
        outlineContract,
        readerMilestone,
      }),
    }), 0, args.json);
  }
  const failed = new Set(review.checks.filter((item) => item.status === 'revise').map((item) => item.id));
  const outlineFindings = validateDraftOutlineCoverage(review, outlineContract, fs.readFileSync(draft, 'utf8'));
  for (const finding of outlineFindings.filter((item) => item.code === 'draft_outline_obligation_revise')) {
    failed.add(`outline_${finding.obligation_id}`);
  }
  if (readerMilestone.required && String(((review || {}).reader_milestone || {}).status || '') === 'revise') {
    failed.add('professional_reader_milestone');
  }
  const decision = shared.kind === 'completed' ? 'pass' : 'revise';
  if (args.decision && args.decision !== decision) return finish({ status: 'quality_decision_conflict', decision: args.decision, evidence_decision: decision, failed: [...failed] }, 0, args.json);
  const passed = decision === 'pass';
  const packetRel = String(execution.expected_result_packet || `追踪/workflow/tasks/${workflowId}/result-packets/${stageId}.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  if (!packetFile) return finish({ status: 'blocked_result_packet_path_unsafe', path: packetRel }, 2, args.json);
  const draftDigest = digestFile(draft);
  const briefRel = relative(root, brief);
  const checks = review.checks.map((item) => ({ id: item.id, status: item.status, evidence: item.evidence, evidence_quote: item.evidence_quote }));
  const summary = String(review.summary || args.summary || (passed
    ? `第${sectionIndex}节角色、因果、情绪、钩子和吸引力通过。`
    : `第${sectionIndex}节需修订：${[...failed].join(', ')}。`)).slice(0, 500);
  const nextStage = passed ? 'section_accept_anchor' : resolveQualityRepairStage(execution);
  const repairAction = nextStage === 'feedback_impact_sync'
    ? '进入反馈影响链并生成当前节修订授权'
    : '重建当前节 Brief 后修订';
  const blockingFindings = buildQualityRevisionFindings({ review, outlineContract, outlineFindings, readerMilestone });
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: stageId,
    step_id: stageId,
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: [draftRel],
    changed_files: [],
    created_files: [],
    evidence: [{
      draft: draftRel,
      draft_digest: draftDigest,
      brief: briefRel,
      checks,
      reviewer_summary: summary,
      evidence_file: canonicalEvidenceRel,
      story_gate_receipt: String(shared.receipt || ''),
      outline_contract_digest: outlineContract.contract_digest,
      outline_coverage: review.outline_coverage,
      reader_milestone: readerMilestone.required ? review.reader_milestone : null,
    }],
    verification_result: passed ? 'pass' : 'revise',
    quality_gate_result: passed ? 'pass' : 'revise',
    story_value_result: passed ? 'pass' : 'revise',
    draft_digest: draftDigest,
    blocking_findings: blockingFindings,
    quality_revision_feedback: passed ? null : {
      source_stage: stageId,
      section_index: sectionIndex,
      scope_snapshot: `第${sectionIndex}节`,
      impact_level: 'current_brief',
      summary,
      findings: blockingFindings,
    },
    checkpoint_state: {
      current_stage: stageId,
      completed_range: passed ? `第${sectionIndex}节质量门完成` : '',
      remaining_range: passed ? `第${sectionIndex}节采用锚点` : repairAction,
      resume_from: nextStage,
    },
    output_health_result: 'pass',
    current_section_index: sectionIndex,
    candidate_count: 1,
    next_stage_id: nextStage,
    next_recommendation: passed ? '等待用户采用当前节' : repairAction,
    handoff_summary: summary,
    acceptance_metadata: normalizeAcceptanceMetadata(review.acceptance_metadata),
    memory_updates: [],
    memory_read_receipt_status: memoryGate.memory_status,
    memory_read_receipt: memoryGate.receipt,
    result_packet_path: packetRel,
  });

  if (!args.apply) return finish({ status: 'packet_ready', decision, section_index: sectionIndex, result_packet: packetRel }, 0, args.json);
  const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile });
  const outcome = classifyWorkflowApply(applied);
  const applyResult = outcome.result;
  const pending = applyResult && applyResult.task && applyResult.task.pending_action
    ? applyResult.task.pending_action
    : null;
  const nextCandidates = pending && Array.isArray(pending.options)
    ? pending.options.slice(0, 4).map((option) => ({
      number: Number(option.number || 0),
      action_id: String(option.action_id || option.action || ''),
      label: String(option.label || ''),
      recommended: Boolean(option.recommended),
    }))
    : [];
  const visibleResponse = nextCandidates.length === 4
    ? { text: renderPendingActionText({ ...pending, options: nextCandidates }) }
    : null;
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    section_index: sectionIndex,
    decision,
    result_packet: packetRel,
    next_stage: String(applyResult.current_stage || ((applyResult.task || {}).current_stage) || nextStage),
    next_action: passed ? '等待用户确认采用当前节' : repairAction,
    next_candidates: nextCandidates,
    visible_response: visibleResponse,
    interaction_contract: visibleResponse ? 'render_visible_response_text_verbatim' : 'continue_current_running_stage',
    ...outcome.presentation,
    ...(outcome.applied ? {} : { apply_result: applyResult }),
  }, outcome.exitCode, args.json);
}

function resolveQualityRepairStage(execution) {
  const allowed = (((execution || {}).transition_contract || {}).allowed_next || []).map(String);
  if (allowed.includes('section_brief')) return 'section_brief';
  if (allowed.includes('feedback_impact_sync')) return 'feedback_impact_sync';
  return 'section_brief';
}

function validateQualityEvidence(review, { workflowId, sectionIndex, draft, outlineContract, readerMilestone }) {
  const findings = [];
  if (String(review.workflow_id || '') !== workflowId) findings.push({ code: 'workflow_id_mismatch' });
  if (Number(review.section_index || 0) !== sectionIndex) findings.push({ code: 'section_index_mismatch' });
  const expectedDigest = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(draft)).digest('hex')}`;
  if (String(review.draft_digest || '') !== expectedDigest) findings.push({ code: 'draft_digest_mismatch' });
  const rows = Array.isArray(review.checks) ? review.checks : [];
  const byId = new Map(rows.map((item) => [String((item || {}).id || ''), item || {}]));
  const draftText = fs.readFileSync(draft, 'utf8');
  const normalizedDraft = normalizeQuote(draftText);
  const usedQuotes = new Map();
  for (const id of CHECKS) {
    const item = byId.get(id);
    if (!item) findings.push({ code: 'quality_dimension_missing', dimension: id });
    else if (!['pass', 'revise'].includes(String(item.status || ''))) findings.push({ code: 'quality_status_missing', dimension: id });
    else if (String(item.evidence || '').trim().length < 4) findings.push({ code: 'quality_evidence_missing', dimension: id });
    else {
      const quote = normalizeQuote(item.evidence_quote || '');
      if (quote.length < 6 || !normalizedDraft.includes(quote)) {
        findings.push({ code: 'quality_evidence_quote_not_found', dimension: id });
      } else {
        const count = Number(usedQuotes.get(quote) || 0) + 1;
        usedQuotes.set(quote, count);
        if (count > 2) findings.push({ code: 'quality_evidence_quote_reused', dimension: id });
      }
    }
  }
  findings.push(...validateDraftOutlineCoverage(review, outlineContract, draftText)
    .filter((item) => item.code !== 'draft_outline_obligation_revise'));
  const metadata = review.acceptance_metadata && typeof review.acceptance_metadata === 'object' && !Array.isArray(review.acceptance_metadata)
    ? review.acceptance_metadata
    : {};
  if (!Array.isArray(metadata.revealed_information) || !metadata.revealed_information.some((item) => String(item || '').trim().length >= 4)) {
    findings.push({ code: 'acceptance_revealed_information_missing' });
  }
  if (!metadata.character_state || typeof metadata.character_state !== 'object' || Array.isArray(metadata.character_state) || !Object.keys(metadata.character_state).length) {
    findings.push({ code: 'acceptance_character_state_missing' });
  }
  if (outlineContract.section_role !== 'ending' && String(metadata.open_hook || '').trim().length < 4) {
    findings.push({ code: 'acceptance_open_hook_missing' });
  }
  if (String(review.summary || '').trim().length < 12) findings.push({ code: 'quality_summary_underfilled' });
  if (readerMilestone && readerMilestone.required) {
    const reader = review.reader_milestone && typeof review.reader_milestone === 'object'
      ? review.reader_milestone
      : {};
    if (String(reader.reviewer || '') !== 'professional-reader') findings.push({ code: 'reader_milestone_reviewer_missing' });
    if (String(reader.kind || '') !== String(readerMilestone.kind || '')) findings.push({ code: 'reader_milestone_kind_mismatch' });
    if (!['pass', 'revise'].includes(String(reader.status || ''))) findings.push({ code: 'reader_milestone_status_missing' });
    if (!['yes', 'maybe', 'no'].includes(String(reader.would_continue || ''))) findings.push({ code: 'reader_milestone_continue_verdict_missing' });
    if (String(reader.strongest_pull || '').trim().length < 4) findings.push({ code: 'reader_milestone_pull_missing' });
    if (String(reader.biggest_resistance || '').trim().length < 4) findings.push({ code: 'reader_milestone_resistance_missing' });
    const readerQuote = normalizeQuote(reader.evidence_quote || '');
    if (readerQuote.length < 6 || !normalizedDraft.includes(readerQuote)) findings.push({ code: 'reader_milestone_quote_not_found' });
    if (String(reader.status || '') === 'revise' && String(reader.repair_direction || '').trim().length < 6) findings.push({ code: 'reader_milestone_repair_missing' });
  }
  return findings.length ? findings : null;
}

function normalizeQualityEvidence(value, { workflowId, sectionIndex, draft, outlineContract }) {
  const source = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  const expectedDigest = digestFile(draft);
  const checks = normalizeQualityChecks(source);
  const outlineCoverage = normalizeOutlineCoverage(source);
  const acceptanceMetadata = normalizeAcceptanceInput(source);
  return {
    ...source,
    workflow_id: workflowId,
    section_index: sectionIndex,
    draft_digest: expectedDigest,
    outline_contract_digest: String(outlineContract.contract_digest || ''),
    checks,
    outline_coverage: outlineCoverage,
    acceptance_metadata: acceptanceMetadata,
    reader_milestone: normalizeReaderMilestone(source.reader_milestone),
    summary: String(
      source.summary
      || ((source.quality_summary || {}).summary)
      || ((source.quality_summary || {}).reason)
      || ''
    ).trim(),
  };
}

function buildQualityRevisionFindings({ review, outlineContract, outlineFindings, readerMilestone }) {
  const labels = {
    causal_progression: '因果推进',
    protagonist_agency: '主角行动',
    emotional_tension: '情绪张力',
    reader_pull: '继续阅读动力',
  };
  const findings = (Array.isArray(review.checks) ? review.checks : [])
    .filter(item => String((item || {}).status || '') === 'revise')
    .map(item => ({
      code: String(item.id || ''),
      label: labels[String(item.id || '')] || '故事质量',
      message: String(item.evidence || '').trim() || '当前内容尚未完成这一项。',
    }));
  const obligationById = new Map((Array.isArray(outlineContract.obligations) ? outlineContract.obligations : [])
    .map(item => [String((item || {}).id || ''), item || {}]));
  for (const finding of (Array.isArray(outlineFindings) ? outlineFindings : [])) {
    if (String((finding || {}).code || '') !== 'draft_outline_obligation_revise') continue;
    const id = String((finding || {}).obligation_id || '');
    const obligation = obligationById.get(id) || {};
    findings.push({
      code: `outline_${id}`,
      label: '大纲兑现',
      message: String(obligation.source_text || '').trim() || '当前节尚未兑现已确认的大纲要求。',
    });
  }
  if (readerMilestone && readerMilestone.required && String((((review || {}).reader_milestone || {}).status) || '') === 'revise') {
    const reader = review.reader_milestone || {};
    findings.push({
      code: 'professional_reader_milestone',
      label: '读者体验',
      message: [String(reader.biggest_resistance || '').trim(), String(reader.repair_direction || '').trim()]
        .filter(Boolean).join('；') || '当前高潮兑现不足，需要按读者阻力做局部修订。',
    });
  }
  const seen = new Set();
  return findings.filter(item => {
    const key = `${item.label}\0${item.message}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function normalizeQualityChecks(source) {
  let rows = [];
  if (Array.isArray(source.checks) && source.checks.length) {
    rows = source.checks.map(normalizeQualityCheck).filter((item) => item.id);
  } else if (Array.isArray(source.quality_dimensions) && source.quality_dimensions.length) {
    rows = source.quality_dimensions.map(normalizeQualityCheck).filter((item) => item.id);
  } else {
    const statuses = source.quality_status && typeof source.quality_status === 'object' && !Array.isArray(source.quality_status)
      ? source.quality_status
      : {};
    rows = Object.entries(statuses).map(([id, item]) => normalizeQualityCheck({ id, ...(item || {}) }));
  }
  const ids = new Set(rows.map(item => item.id));
  if (CHECKS.every(id => ids.has(id))) return rows.filter(item => CHECKS.includes(item.id));
  return collapseLegacyChecks(rows);
}

function collapseLegacyChecks(rows) {
  const byId = new Map(rows.map(item => [item.id, item]));
  return CHECKS.flatMap(id => {
    const members = (LEGACY_CHECK_GROUPS[id] || []).map(member => byId.get(member)).filter(Boolean);
    if (!members.length) return [];
    const revised = members.some(item => item.status === 'revise');
    return [{
      id,
      status: revised ? 'revise' : 'pass',
      evidence: uniqueText(members.map(item => item.evidence)).join('；'),
      evidence_quote: String((members.find(item => item.evidence_quote) || {}).evidence_quote || ''),
    }];
  });
}

function normalizeQualityCheck(value) {
  const item = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  return {
    id: String(item.id || item.dimension || '').trim(),
    status: String(item.status || item.verdict || '').trim(),
    evidence: String(item.evidence || item.reason || item.judgment || '').trim(),
    evidence_quote: String(item.evidence_quote || item.quote || '').trim(),
  };
}

function normalizeOutlineCoverage(source) {
  if (Array.isArray(source.outline_coverage) && source.outline_coverage.length) {
    return source.outline_coverage.map(normalizeOutlineCoverageRow).filter((item) => item.id);
  }
  if (Array.isArray(source.draft_outline_obligations) && source.draft_outline_obligations.length) {
    return source.draft_outline_obligations.map(normalizeOutlineCoverageRow).filter((item) => item.id);
  }
  const coverage = source.outline_coverage && typeof source.outline_coverage === 'object' && !Array.isArray(source.outline_coverage)
    ? source.outline_coverage
    : {};
  return Object.entries(coverage).map(([id, item]) => normalizeOutlineCoverageRow({ id, ...(item || {}) }));
}

function normalizeOutlineCoverageRow(value) {
  const item = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  return {
    id: String(item.id || item.obligation_id || '').trim(),
    status: String(item.status || item.verdict || '').trim(),
    evidence_quote: String(item.evidence_quote || item.quote || '').trim(),
  };
}

function normalizeAcceptanceInput(source) {
  const nested = [
    source.acceptance_metadata,
    source.acceptance,
  ].find((item) => item && typeof item === 'object' && !Array.isArray(item)) || {};
  const revealed = nested.revealed_information ?? source.revealed_information;
  const characterState = nested.character_state ?? source.character_state;
  const openHook = nested.open_hook ?? source.open_hook;
  return {
    ...nested,
    revealed_information: Array.isArray(revealed)
      ? revealed.map(String).map((item) => item.trim()).filter(Boolean)
      : (String(revealed || '').trim() ? [String(revealed).trim()] : []),
    character_state: characterState && typeof characterState === 'object' && !Array.isArray(characterState)
      ? characterState
      : (String(characterState || '').trim() ? { summary: String(characterState).trim() } : {}),
    open_hook: String(openHook || '').trim(),
  };
}

function buildQualityEvidenceSchema({ workflowId, sectionIndex, draft, outlineContract, readerMilestone }) {
  return buildShortQualityEvidenceSchema({
    workflowId,
    sectionIndex,
    draftDigest: digestFile(draft),
    outlineContract,
    readerMilestone,
  });
}

function normalizeReaderMilestone(value) {
  const input = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  return {
    reviewer: String(input.reviewer || ''),
    kind: String(input.kind || ''),
    status: String(input.status || input.verdict || ''),
    would_continue: String(input.would_continue || input.continue_verdict || ''),
    strongest_pull: String(input.strongest_pull || ''),
    biggest_resistance: String(input.biggest_resistance || ''),
    evidence_quote: String(input.evidence_quote || input.quote || ''),
    repair_direction: String(input.repair_direction || ''),
  };
}

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function normalizeQuote(value) {
  return String(value || '')
    .replace(/\s+/gu, '')
    .replace(/["'“”‘’「」『』]/gu, '')
    .trim();
}

function normalizeAcceptanceMetadata(value) {
  const input = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  return {
    revealed_information: Array.isArray(input.revealed_information) ? input.revealed_information.map(String).filter(Boolean).slice(0, 12) : [],
    character_state: input.character_state && typeof input.character_state === 'object' && !Array.isArray(input.character_state) ? input.character_state : {},
    present_characters: Array.isArray(input.present_characters) ? input.present_characters.map(String).map(item => item.trim()).filter(Boolean).slice(0, 24) : [],
    relationship_state: plainObject(input.relationship_state),
    knowledge_state: plainObject(input.knowledge_state),
    world_state: plainObject(input.world_state),
    decisions: Array.isArray(input.decisions) ? input.decisions.map(String).map(item => item.trim()).filter(Boolean).slice(0, 16) : [],
    causal_links: Array.isArray(input.causal_links) ? input.causal_links.filter(item => typeof item === 'string' || (item && typeof item === 'object' && !Array.isArray(item))).slice(0, 16) : [],
    promise_deltas: Array.isArray(input.promise_deltas) ? input.promise_deltas.filter(item => item && typeof item === 'object' && !Array.isArray(item)).slice(0, 16) : [],
    protagonist: String(input.protagonist || '').trim(),
    open_hook: String(input.open_hook || '').slice(0, 500),
    carry_forward: Array.isArray(input.carry_forward) ? input.carry_forward.map(String).filter(Boolean).slice(0, 8) : [],
  };
}

function plainObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', decision: '', failed: [], summary: '', draft: '', evidenceFile: '', apply: false, json: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++i] || '';
    else if (arg === '--decision') args.decision = String(argv[++i] || '').toLowerCase();
    else if (arg === '--failed') args.failed = String(argv[++i] || '').split(',').map((item) => item.trim()).filter(Boolean);
    else if (arg === '--summary') args.summary = String(argv[++i] || '').trim().slice(0, 240);
    else if (arg === '--draft') args.draft = argv[++i] || '';
    else if (arg === '--evidence-file') args.evidenceFile = argv[++i] || '';
    else if (arg === '--apply' || arg === '--write') args.apply = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else return usage(`unknown argument: ${arg}`);
  }
  return args;
}

function printHelp() {
  process.stdout.write('Usage: node short-section-quality-gate.js --project-root <book> --workflow-id <id> [--evidence-file file] [--decision <pass|revise>] [--draft file] [--apply] [--json]\n');
  return 0;
}

function resolveDraft(root, task, sectionIndex, explicit) {
  const padded = String(sectionIndex).padStart(3, '0');
  const candidates = [explicit, `草稿_第${padded}节_候选.md`, `正文_第${padded}节.md`].filter(Boolean);
  const packetCandidates = [
    `追踪/workflow/tasks/${task.workflow_id}/result-packets/section_machine_gate.section-${padded}.result.json`,
    `追踪/workflow/tasks/${task.workflow_id}/result-packets/section_machine_gate.result.json`,
  ];
  const machinePacket = packetCandidates
    .map((candidate) => readJson(safeProjectFile(root, candidate) || ''))
    .find(Boolean);
  const packetDrafts = ((machinePacket || {}).outputs || [])
    .map(String)
    .filter((output) => /(?:草稿_第\d+节_候选|正文_第\d+节)\.md$/u.test(output));
  candidates.unshift(...packetDrafts);
  for (const candidate of candidates) {
    const file = safeProjectFile(root, candidate);
    if (file && fs.existsSync(file) && fs.statSync(file).isFile()) return file;
  }
  return '';
}

function focusedWorkflowId(root) {
  return singleUnfinishedWorkflowId(root);
}

function safeProjectFile(root, rel) {
  const value = String(rel || '');
  if (!value) return '';
  const file = path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
  return file === root || file.startsWith(`${root}${path.sep}`) ? file : '';
}

function readQualityEvidence(file) {
  if (!file || !fs.existsSync(file)) return { value: null, repaired: false };
  const raw = fs.readFileSync(file, 'utf8');
  try { return { value: JSON.parse(raw), repaired: false }; } catch (_) { /* constrained fallback below */ }
  const repairedText = raw.split(/\r?\n/u).map((line) => {
    const match = line.match(/^(\s*"evidence_quote"\s*:\s*")(.*)("\s*,?\s*)$/u);
    if (!match) return line;
    return `${match[1]}${match[2].replace(/(?<!\\)"/gu, '”')}${match[3]}`;
  }).join('\n');
  try { return { value: JSON.parse(repairedText), repaired: repairedText !== raw }; } catch (_) { return { value: null, repaired: false }; }
}

function usage(message) {
  process.stderr.write(`${message}\nUsage: node short-section-quality-gate.js --project-root <book> --workflow-id <id> --decision <pass|revise|blocked> [--failed a,b] [--summary text] [--apply] [--json]\n`);
  process.exit(2);
}

function uniqueText(values) {
  return [...new Set(values.map(value => String(value || '').trim()).filter(Boolean))];
}

if (require.main === module) process.exitCode = main();

module.exports = {
  buildQualityRevisionFindings,
  buildQualityEvidenceSchema,
  normalizeQualityChecks,
  validateQualityEvidence,
};
