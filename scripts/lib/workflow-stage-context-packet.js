'use strict';

// workflow-stage-context-packet
//
// Responsibility boundary: build the MINIMUM context packet for one short-write
// stage. Drafting receives the complete current Brief; review receives only the
// Brief clauses needed to judge the already-written candidate.
//
// The short-sixth-section runaway-token incident showed the prose Agent reaching
// for the full task journal, historical result packets, script source files, and
// old chat transcriptions. This packet is the single allowlist the prose Agent
// is permitted to read for one section draft. Everything else stays out.
//
// Allowed assets (the only files this packet ever inlines or references):
//   - Current-story memory snapshot  accepted facts / promises / style rules
//   - Current section Brief        写作Brief_第NNN节.md
//   - Plan summaries (digests only) 素材卡.md / 设定.md / 小节大纲.md
//   - Previous section accepted anchor  追踪/private-short-extension/section-NNN-anchor.json
//   - Continuity tail fragment    last paragraph(s) of the previous accepted section
//   - Author voice card (optional) 风格卡.md
//
// Explicitly EXCLUDED (never inlined, never enumerated):
//   - Full task journal           追踪/workflow/tasks/<id>/journal.jsonl
//   - Historical result packets   追踪/workflow/tasks/<id>/result-packets/*
//   - Full script source          scripts/**/*.js
//   - Old chat transcriptions     any 旧聊天 / debug-*/scan-* / inspect-* output
//   - Previous Briefs / candidate prose  写作Brief_第NNN节.md for N != current
//
// Global memory context stays outside this packet. Short writing consumes only
// the compiled current-story snapshot so unrelated projects cannot leak in.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { readShortProjectState, resolveShortStateRelative, shortStateFile } = require('./short-project-state');
const { compactToTokens, estimateTokens } = require('./context-budget');
const { inferShortSectionIndex } = require('./short-workflow-state');
const { currentShortFeedbackRevisionSection } = require('./short-feedback-revision-queue');
const { atomicWriteJson, atomicWriteText } = require('./workflow-state-store');
const { buildShortMemorySnapshot } = require('./short-memory-snapshot');
const {
  buildShortSectionOutlineContract,
  renderOutlineCoverageTemplate,
} = require('./short-section-outline-contract');
const { SHORT_WORKFLOW_TYPES } = require('./short-workflow-types');

const DRAFT_STAGES = new Set(['draft_first_section', 'draft_next_section', 'draft_section']);
const REVIEW_STAGES = new Set(['section_repair_loop', 'quality_gate', 'story_value_gate']);
const BRIEF_STAGES = new Set(['first_section_brief', 'section_brief', 'next_section_brief']);
const ACCEPTANCE_STAGES = new Set(['section_accept_anchor']);
const FEEDBACK_STAGES = new Set(['feedback_impact_sync', 'feedback_apply_patch']);
const CONTEXT_STAGES = new Set([...DRAFT_STAGES, ...REVIEW_STAGES, ...BRIEF_STAGES, ...ACCEPTANCE_STAGES, ...FEEDBACK_STAGES]);
const PACKET_SCHEMA_VERSION = '1.0.0';
const CONTINUITY_TAIL_PARAGRAPHS = 2;

function buildStageContextPacket({ projectRoot, task, stage, options = {} } = {}) {
  const root = path.resolve(projectRoot || '');
  if (!root || !fs.existsSync(root)) {
    return notApplicable('project_root_missing');
  }
  const workflowType = String((task || {}).workflow_type || '');
  if (!SHORT_WORKFLOW_TYPES.has(workflowType)) return notApplicable('workflow_type_not_short');
  const stageId = String(stage || (task || {}).current_stage || '');
  if (!CONTEXT_STAGES.has(stageId)) return notApplicable('stage_not_short_section');

  const projectState = readProjectState(root);
  const wholeStoryFeedback = FEEDBACK_STAGES.has(stageId) && isWholeStoryFeedback(task);
  const sectionIndex = positiveInteger(
    currentShortFeedbackRevisionSection(task)
    ||
    inferShortSectionIndex({
      projectState,
      stageId,
      scope: String((task || {}).scope || ''),
    })
  ) || (wholeStoryFeedback ? 1 : 0);
  if (!sectionIndex) return notApplicable('section_identity_missing');

  const taskId = String((task || {}).workflow_id || `wf-short-${sectionIndex}`);
  const taskDir = String((task || {}).task_dir || `追踪/workflow/tasks/${taskId}`);
  const memorySnapshot = buildShortMemorySnapshot(root, {
    task,
    sectionIndex,
    stageId,
  });

  const assets = collectAllowedAssets({ root, sectionIndex, stageId, task, memorySnapshot });
  const runtimeEstimate = (((task || {}).runtime_guard || {}).token_estimate || {});
  const budget = resolveStageTokenBudget({
    root,
    assets,
    sectionIndex,
    stageId,
    runtimeEstimate,
    options,
  });
  const tokenBudget = budget.token_budget;
  const attemptId = safePathSegment((((task || {}).stage_execution || {}).stage_attempt_id) || 'attempt-pending');
  const packetScope = wholeStoryFeedback
    ? 'whole-story'
    : `section-${String(sectionIndex).padStart(3, '0')}`;
  const packetBase = `${taskDir}/context-packets/${stageId}/${packetScope}/${attemptId}`;
  const packetMdRel = `${packetBase}/stage-context.md`;
  const packetJsonRel = `${packetBase}/stage-context.json`;

  const assembled = assemblePacket({ root, assets, sectionIndex, stageId, tokenBudget });
  if (assembled.blocked_required.length > 0) {
    return {
      status: 'blocked_required_context_budget',
      stage_id: stageId,
      section_index: sectionIndex,
      token_budget: tokenBudget,
      budget_source: budget.source,
      required_context: assembled.blocked_required,
      omitted: assembled.omitted,
      deduplicated_items: assembled.deduplicated_items,
      included_assets: assembled.included_assets,
      omitted_assets: assembled.omitted_assets,
    };
  }
  const identity = shortProjectIdentity(root, projectState, sectionIndex);
  const modelProfile = ((((task || {}).runtime_guard || {}).model_profile) || {});
  const markdown = renderMarkdown({
    workflowId: taskId,
    sectionIndex,
    stageId,
    assets: assembled.entries,
    tokenBudget,
    usedTokens: assembled.used_tokens,
    omitted: assembled.omitted,
    identity,
    modelProfile,
  });

  const packetMdAbs = safeResolve(root, packetMdRel);
  const packetJsonAbs = safeResolve(root, packetJsonRel);
  if (!packetMdAbs || !packetJsonAbs) {
    return notApplicable('unsafe_packet_path');
  }
  atomicWriteText(packetMdAbs, markdown);
  atomicWriteJson(packetJsonAbs, {
    schemaVersion: PACKET_SCHEMA_VERSION,
    workflow_id: taskId,
    workflow_type: workflowType,
    stage_id: stageId,
    section_index: sectionIndex,
    project_title: identity.project_title,
    current_section_title: identity.current_section_title,
    packet_md: packetMdRel,
    token_budget: tokenBudget,
    budget_source: budget.source,
    required_tokens: budget.required_tokens,
    optional_tokens_available: budget.optional_tokens_available,
    estimated_tokens: assembled.used_tokens,
    digest: assembled.digest,
    deduplicated_items: assembled.deduplicated_items,
    included_assets: assembled.included_assets,
    omitted_assets: assembled.omitted_assets,
    advisory,
    source_files: assembled.entries.map((entry) => ({
      id: entry.id,
      artifact_id: entry.artifact_id,
      path: entry.path,
      kind: entry.kind,
      content_digest: entry.content_digest,
      estimated_tokens: entry.estimated_tokens,
      truncated: entry.truncated,
    })),
    omitted: assembled.omitted,
    excludes: EXPLICIT_EXCLUDES,
    memory_contract: memorySnapshot.contract || null,
    memory_read_receipt: memorySnapshot.receipt || null,
    model_profile: modelProfile,
    created_at: new Date().toISOString(),
  });

  return {
    status: 'assembled',
    packet_md: packetMdRel,
    packet_json: packetJsonRel,
    estimated_tokens: assembled.used_tokens,
    digest: assembled.digest,
    deduplicated_items: assembled.deduplicated_items,
    included_assets: assembled.included_assets,
    omitted_assets: assembled.omitted_assets,
    token_budget: tokenBudget,
    budget_source: budget.source,
    required_tokens: budget.required_tokens,
    optional_tokens_available: budget.optional_tokens_available,
    source_files: assembled.entries.map((entry) => ({
      id: entry.id,
      artifact_id: entry.artifact_id,
      path: entry.path,
      kind: entry.kind,
      content_digest: entry.content_digest,
    })),
    omitted: assembled.omitted,
    section_index: sectionIndex,
    project_title: identity.project_title,
    current_section_title: identity.current_section_title,
    memory_contract: memorySnapshot.contract || null,
    memory_read_receipt: memorySnapshot.receipt || null,
    model_profile: modelProfile,
    advisory,
  };
}

function resolveStageTokenBudget({ root, assets, sectionIndex, stageId, runtimeEstimate, options }) {
  const explicitTokenBudget = positiveInteger(options.tokenBudget);
  if (explicitTokenBudget) {
    return budgetDecision(explicitTokenBudget, 'explicit_token_budget', inspectAssetDemand({ root, assets, sectionIndex, stageId }));
  }

  const explicitCharBudget = positiveInteger(options.charBudget);
  if (explicitCharBudget) {
    return budgetDecision(Math.max(1, Math.floor(explicitCharBudget / 2)), 'explicit_char_budget', inspectAssetDemand({ root, assets, sectionIndex, stageId }));
  }

  const runtimeCharBudget = positiveInteger(runtimeEstimate.context_chars_budget)
    || positiveInteger(runtimeEstimate.host_context_chars);
  if (runtimeCharBudget) {
    return budgetDecision(Math.max(1, Math.floor(runtimeCharBudget / 2)), 'runtime_char_budget', inspectAssetDemand({ root, assets, sectionIndex, stageId }));
  }

  const demand = inspectAssetDemand({ root, assets, sectionIndex, stageId });
  const modelMultiplier = positiveMultiplier(runtimeEstimate.model_context_multiplier, 1);
  const ratio = optionalBudgetRatio(stageId) * modelMultiplier;
  const optionalAllowance = demand.optional_tokens > 0
    ? Math.min(demand.optional_tokens, Math.max(256, Math.ceil(demand.required_tokens * ratio)))
    : 0;
  const derived = Math.max(1, demand.required_tokens + optionalAllowance);
  return budgetDecision(derived, 'adaptive_required_assets', demand, optionalAllowance);
}

function inspectAssetDemand({ root, assets, sectionIndex, stageId }) {
  let requiredTokens = 0;
  let optionalTokens = 0;
  for (const asset of Object.values(assets || {}).filter(Boolean)) {
    const fileText = readAssetText(root, asset);
    if (fileText === null) continue;
    const payload = extractPayload(asset, fileText, sectionIndex, stageId);
    if (!payload) continue;
    if (asset.required) requiredTokens += estimateTokens(payload);
    else optionalTokens += estimateTokens(payload);
  }
  return { required_tokens: requiredTokens, optional_tokens: optionalTokens };
}

function optionalBudgetRatio(stageId) {
  if (stageId === 'section_repair_loop') return 0;
  if (REVIEW_STAGES.has(stageId) || ACCEPTANCE_STAGES.has(stageId)) return 0.25;
  if (DRAFT_STAGES.has(stageId)) return 0.75;
  if (BRIEF_STAGES.has(stageId) || FEEDBACK_STAGES.has(stageId)) return 1;
  return 0.5;
}

function positiveMultiplier(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 && number <= 2 ? number : fallback;
}

function budgetDecision(tokenBudget, source, demand, optionalAllowance) {
  return {
    token_budget: tokenBudget,
    source,
    required_tokens: Number(demand.required_tokens || 0),
    optional_tokens_available: optionalAllowance === undefined
      ? Math.max(0, tokenBudget - Number(demand.required_tokens || 0))
      : optionalAllowance,
  };
}

// advisory is the ONE-LINE cooperative-mode hint. It must NOT claim to interrupt
// hidden thinking — that is impossible from outside the model.
const advisory = '本小节上下文已压缩为最小包；若仍显著膨胀，建议由托管运行接管。不得声称可以中断宿主隐藏 thinking。';

const EXPLICIT_EXCLUDES = Object.freeze([
  '完整任务追踪日志',
  '历史阶段执行回执',
  '全量脚本源码',
  '旧聊天 / debug / scan / inspect 转录',
  '前序小节 Brief 或候选正文',
]);

function collectAllowedAssets({ root, sectionIndex, stageId, task, memorySnapshot }) {
  const briefPath = `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`;
  const anchorPath = sectionIndex > 1
    ? resolveShortStateRelative(root, `section-${String(sectionIndex - 1).padStart(3, '0')}-anchor.json`)
    : '';
  const previousAnchor = anchorPath ? readJsonFile(safeResolve(root, anchorPath)) : null;
  const previousCanonical = previousAnchor && String(previousAnchor.status || '') === 'accepted'
    ? String(previousAnchor.canonical_path || '')
    : '';
  const outlineContract = outlineContractAsset(root, sectionIndex, stageId);
  const memoryAsset = memorySnapshot && memorySnapshot.status === 'assembled'
    ? {
      id: `short-memory:${memorySnapshot.receipt.memory_revision}`,
      path: '[当前作品记忆快照]',
      kind: 'memory_snapshot',
      required: true,
      inline: JSON.stringify(memorySnapshot.payload, null, 2),
    }
    : null;
  const expressionOnlyRepair = isExpressionOnlyRepairStage(task, stageId);
  const pendingFeedback = (FEEDBACK_STAGES.has(stageId) || expressionOnlyRepair) && String((((task || {}).pending_feedback || {}).text) || '').trim()
    ? {
      id: String((((task || {}).pending_feedback || {}).feedback_id) || 'pending-feedback'),
      path: '[workflow pending_feedback]',
      kind: 'pending_feedback',
      required: true,
      inline: JSON.stringify({
        feedback_id: String((((task || {}).pending_feedback || {}).feedback_id) || ''),
        item_count: Number((((task || {}).pending_feedback || {}).item_count) || 1),
        items: Array.isArray((((task || {}).pending_feedback || {}).items))
          ? (task || {}).pending_feedback.items.map(item => ({
            feedback_id: String((item || {}).feedback_id || ''),
            text: String((item || {}).text || ''),
            impact_level_hint: String((item || {}).impact_level_hint || ''),
            affected_assets_hint: Array.isArray((item || {}).affected_assets_hint) ? item.affected_assets_hint : [],
          }))
          : [],
        section_index: positiveInteger((((task || {}).pending_feedback || {}).section_index)) || sectionIndex,
        scope_snapshot: String((((task || {}).pending_feedback || {}).scope_snapshot) || ''),
        affected_assets_hint: Array.isArray((((task || {}).pending_feedback || {}).affected_assets_hint))
          ? ((task || {}).pending_feedback.affected_assets_hint)
          : [],
        text: String((((task || {}).pending_feedback || {}).text) || '').trim(),
      }, null, 2),
    }
    : null;
  if (stageId === 'section_repair_loop') {
    const acceptedRevisionPlan = activeRevisionPlanAsset(root, task, sectionIndex);
    if (expressionOnlyRepair) {
      return {
        pendingFeedback,
        acceptedRevisionPlan,
        currentDraft: currentDraftAsset(root, sectionIndex, {
          kind: 'current_draft_expression_focus',
          feedbackText: String((((task || {}).pending_feedback || {}).text) || ''),
        }),
      };
    }
    const gatePacket = String((((task || {}).machine || {}).last_result_packet) || '');
    const repairOutlineContract = buildShortSectionOutlineContract(root, sectionIndex).status === 'current'
      ? outlineContract
      : null;
    return {
      gateFindings: gatePacket
        ? { id: gatePacket, path: gatePacket, kind: 'gate_findings', required: true }
        : null,
      memorySnapshot: memoryAsset,
      acceptedRevisionPlan,
      outlineContract: repairOutlineContract,
      brief: { id: briefPath, path: briefPath, kind: 'repair_constraints', required: true },
      currentDraft: currentDraftAsset(root, sectionIndex),
    };
  }

  const includePlanSummaries = DRAFT_STAGES.has(stageId) || BRIEF_STAGES.has(stageId) || FEEDBACK_STAGES.has(stageId);
  const acceptedPlan = stageId === 'feedback_apply_patch' && task.accepted_plan && typeof task.accepted_plan === 'object'
    ? {
      id: String(task.accepted_plan.plan_id || 'accepted-short-plan'),
      path: String(task.accepted_plan_path || '[workflow accepted_plan]'),
      kind: 'accepted_plan',
      required: true,
      inline: JSON.stringify(task.accepted_plan, null, 2),
    }
    : null;
  const acceptedRevisionPlan = (BRIEF_STAGES.has(stageId) || DRAFT_STAGES.has(stageId) || REVIEW_STAGES.has(stageId))
    ? activeRevisionPlanAsset(root, task, sectionIndex)
    : null;
  if (stageId === 'feedback_impact_sync') {
    return {
      pendingFeedback,
      settingDigest: { id: '设定.md', path: '设定.md', kind: 'plan_overview', required: false },
      outlineDigest: { id: '小节大纲.md', path: '小节大纲.md', kind: 'plan_overview', required: true },
      materialDigest: { id: '素材卡.md', path: '素材卡.md', kind: 'plan_overview', required: false },
    };
  }
  if (stageId === 'feedback_apply_patch') {
    return {
      acceptedPlan,
      pendingFeedback: acceptedPlan ? null : pendingFeedback,
      memorySnapshot: memoryAsset,
      settingDigest: { id: '设定.md', path: '设定.md', kind: 'plan_summary', required: true },
      outlineDigest: { id: '小节大纲.md', path: '小节大纲.md', kind: 'plan_summary', required: true },
      materialDigest: { id: '素材卡.md', path: '素材卡.md', kind: 'plan_summary', required: false },
    };
  }
  return {
    pendingFeedback,
    memorySnapshot: memoryAsset,
    acceptedRevisionPlan,
    outlineContract: FEEDBACK_STAGES.has(stageId) ? null : outlineContract,
    brief: BRIEF_STAGES.has(stageId)
      ? null
      : { id: briefPath, path: briefPath, kind: 'brief', required: DRAFT_STAGES.has(stageId) || REVIEW_STAGES.has(stageId) || ACCEPTANCE_STAGES.has(stageId) },
    currentDraft: (REVIEW_STAGES.has(stageId) || ACCEPTANCE_STAGES.has(stageId) || FEEDBACK_STAGES.has(stageId))
      ? currentDraftAsset(root, sectionIndex)
      : null,
    materialDigest: includePlanSummaries ? { id: '素材卡.md', path: '素材卡.md', kind: 'plan_summary', required: false } : null,
    settingDigest: includePlanSummaries ? { id: '设定.md', path: '设定.md', kind: 'plan_summary', required: false } : null,
    outlineDigest: includePlanSummaries ? { id: '小节大纲.md', path: '小节大纲.md', kind: 'plan_summary', required: false } : null,
    acceptedAnchor: anchorPath ? { id: anchorPath, path: anchorPath, kind: 'accepted_anchor', required: BRIEF_STAGES.has(stageId) } : null,
    continuityTail: previousCanonical
      ? { id: `${previousCanonical}#tail`, path: previousCanonical, kind: 'continuity_tail', required: BRIEF_STAGES.has(stageId) }
      : null,
    voiceCard: { id: '风格卡.md', path: '风格卡.md', kind: 'voice_card', required: false },
  };
}

function activeRevisionPlanAsset(root, task = {}, sectionIndex) {
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  const plan = loadAcceptedPlan(root, task);
  const canonicalConstraints = readActivePlanningConstraints(root, task, sectionIndex);
  if (!queue || String(queue.status || '') !== 'running' || (!plan && !canonicalConstraints.length)) return null;
  const item = (Array.isArray(queue.items) ? queue.items : [])
    .find(row => Number((row || {}).section_index || 0) === sectionIndex);
  if (!item || String(item.status || '') === 'accepted') return null;
  const group = (Array.isArray(queue.groups) ? queue.groups : [])
    .find(row => (Array.isArray((row || {}).section_indices) ? row.section_indices : []).map(Number).includes(sectionIndex));
  const planId = String((plan || {}).plan_id || canonicalConstraints[0]?.provenance?.plan_id || 'accepted-plan');
  return {
    id: `${planId}#section-${String(sectionIndex).padStart(3, '0')}`,
    path: String(task.accepted_plan_path || '追踪/memory/planning-constraints.jsonl'),
    kind: 'accepted_revision_obligations',
    required: true,
    inline: JSON.stringify({
      plan_id: planId,
      feedback_id: String(queue.feedback_id || (plan || {}).feedback_id || ''),
      section_index: sectionIndex,
      plan_status: String((plan || {}).status || canonicalConstraints[0]?.status || ''),
      memory_constraint_source: '当前作品记忆快照.canon_constraints',
      task_accepted_requirements: (Array.isArray((plan || {}).requirements) ? plan.requirements : [])
        .map((row, index) => ({
          requirement_id: String((row || {}).requirement_id || `requirement-${index + 1}`),
          text: String((row || {}).text || (row || {}).content || '').trim(),
          affected_sections: sectionListFromRequirement(row, plan, queue),
        }))
        .filter(row => row.text && sectionApplies(row.affected_sections, sectionIndex)),
      canonical_planning_constraints: canonicalConstraints.map(row => ({
        constraint_id: String(row.constraint_id || ''),
        content: String(row.content || ''),
        affected_sections: Array.isArray(row.affected_sections) ? row.affected_sections.map(Number).filter(Boolean) : [],
        source_kind: String(row.source_kind || ''),
        provenance: row.provenance && typeof row.provenance === 'object' ? {
          workflow_id: String(row.provenance.workflow_id || ''),
          feedback_id: String(row.provenance.feedback_id || ''),
          plan_id: String(row.provenance.plan_id || ''),
        } : null,
      })),
      queue_item: {
        brief_status: String(item.brief_status || ''),
        prose_status: String(item.prose_status || ''),
      },
      revision_group: group ? {
        group_id: String(group.group_id || ''),
        goal: String(group.goal || ''),
        completion_rule: String(group.completion_rule || ''),
      } : null,
      instruction: '本节 Brief、正文复检和质量判断必须兑现 task_accepted_requirements 与 canonical_planning_constraints；如与当前大纲冲突，先返回规划影响链，不得静默忽略。',
    }, null, 2),
  };
}

function loadAcceptedPlan(root, task = {}) {
  if (task.accepted_plan && typeof task.accepted_plan === 'object') return task.accepted_plan;
  const rel = String(task.accepted_plan_path || '');
  const abs = rel ? safeResolve(root, rel) : '';
  return abs ? readJsonFile(abs) : null;
}

function readActivePlanningConstraints(root, task = {}, sectionIndex) {
  const file = safeResolve(root, '追踪/memory/planning-constraints.jsonl');
  const workflowId = String(task.workflow_id || '');
  const feedbackId = String(((task.feedback_revision_queue || {}).feedback_id) || ((task.pending_feedback || {}).feedback_id) || '');
  const latest = new Map();
  for (const row of readJsonlFile(file)) {
    const id = String((row || {}).constraint_id || '');
    if (!id) continue;
    latest.set(id, row);
  }
  return [...latest.values()]
    .filter(row => isActiveRow(row))
    .filter(row => {
      const provenance = row.provenance && typeof row.provenance === 'object' ? row.provenance : {};
      const rowWorkflowId = String(provenance.workflow_id || '');
      const rowFeedbackId = String(provenance.feedback_id || '');
      if (workflowId && rowWorkflowId && rowWorkflowId !== workflowId) return false;
      if (feedbackId && rowFeedbackId && rowFeedbackId !== feedbackId) return false;
      const sections = constraintSections(row);
      return sectionApplies(sections, sectionIndex);
    })
    .slice(-16);
}

function readJsonlFile(file) {
  if (!file || !fs.existsSync(file)) return [];
  try {
    return fs.readFileSync(file, 'utf8')
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(Boolean)
      .map(line => JSON.parse(line));
  } catch {
    return [];
  }
}

function isActiveRow(row) {
  const status = String((row || {}).status || 'active').toLowerCase();
  return !['superseded', 'rejected', 'quarantined', 'closed', 'invalid'].includes(status) && !(row || {}).valid_to;
}

function sectionListFromRequirement(row, plan = {}, queue = {}) {
  const textSections = inferSectionsFromText(`${String((row || {}).text || '')}\n${String((row || {}).content || '')}`);
  if (textSections.length) return textSections;
  const rowSections = Array.isArray((row || {}).affected_sections) ? row.affected_sections.map(Number).filter(Boolean) : [];
  if (rowSections.length) return rowSections;
  const planSections = Array.isArray((plan || {}).affected_sections) ? plan.affected_sections.map(Number).filter(Boolean) : [];
  if (planSections.length) return planSections;
  return Array.isArray((queue || {}).affected_sections) ? queue.affected_sections.map(Number).filter(Boolean) : [];
}

function constraintSections(row) {
  const affected = Array.isArray((row || {}).affected_sections) ? row.affected_sections.map(Number).filter(Boolean) : [];
  if (affected.length) return affected;
  return inferSectionsFromText(String((row || {}).content || ''));
}

function inferSectionsFromText(text) {
  const found = new Set();
  const source = String(text || '');
  source.replace(/第\s*0*(\d+)\s*(?:至|到|-|—|~)\s*0*(\d+)\s*节/gu, (_, a, b) => {
    const start = Number(a);
    const end = Number(b);
    if (Number.isInteger(start) && Number.isInteger(end)) {
      for (let n = Math.min(start, end); n <= Math.max(start, end); n += 1) found.add(n);
    }
    return _;
  });
  source.replace(/第\s*0*(\d+)\s*节/gu, (_, n) => {
    const value = Number(n);
    if (Number.isInteger(value) && value > 0) found.add(value);
    return _;
  });
  return [...found].sort((a, b) => a - b);
}

function sectionApplies(sections, sectionIndex) {
  const normalized = Array.isArray(sections) ? sections.map(Number).filter(Boolean) : [];
  return !normalized.length || normalized.includes(Number(sectionIndex));
}

function assemblePacket({ root, assets, sectionIndex, stageId, tokenBudget }) {
  const entries = [];
  const omitted = [];
  const blockedRequired = [];

  // Ordered by importance. Required entries get budget priority and must fit;
  // optional entries fill the remainder and may be dropped on budget pressure.
  const orderedAssets = [
    assets.gateFindings,
    assets.acceptedPlan,
    assets.pendingFeedback,
    assets.memorySnapshot,
    assets.acceptedRevisionPlan,
    assets.outlineContract,
    assets.brief,
    assets.currentDraft,
    assets.acceptedAnchor,
    assets.settingDigest,
    assets.outlineDigest,
    assets.materialDigest,
    assets.continuityTail,
    assets.voiceCard,
  ].filter(Boolean);

  let used = 0;
  for (const asset of orderedAssets) {
    const fileText = readAssetText(root, asset);
    if (fileText === null) {
      if (asset.required) {
        blockedRequired.push({ id: asset.id, reason: 'missing_required_asset', required_tokens: 0, remaining_tokens: Math.max(0, tokenBudget - used) });
      } else {
        omitted.push({ id: asset.id, reason: 'missing_file' });
      }
      continue;
    }
    const payload = extractPayload(asset, fileText, sectionIndex, stageId);
    if (!payload) {
      if (asset.required) blockedRequired.push({ id: asset.id, reason: 'empty_required_asset', required_tokens: 0, remaining_tokens: Math.max(0, tokenBudget - used) });
      else omitted.push({ id: asset.id, reason: 'empty_payload' });
      continue;
    }
    const remaining = tokenBudget - used;
    const payloadTokens = estimateTokens(payload);
    if (asset.required) {
      if (payloadTokens > remaining) {
        blockedRequired.push({
          id: asset.id,
          reason: 'required_asset_exceeds_budget',
          required_tokens: payloadTokens,
          remaining_tokens: Math.max(0, remaining),
        });
        continue;
      }
      entries.push(withArtifactIdentity(asset, payload, payloadTokens, false));
      used += payloadTokens;
      continue;
    }
    if (payloadTokens <= remaining) {
      entries.push(withArtifactIdentity(asset, payload, payloadTokens, false));
      used += payloadTokens;
      continue;
    }
    if (remaining > 0) {
      const compacted = compactToTokens(payload, remaining);
      entries.push(withArtifactIdentity(asset, compacted, estimateTokens(compacted), true));
      used += estimateTokens(compacted);
      omitted.push({ id: asset.id, reason: 'budget_truncated' });
      continue;
    }
    omitted.push({ id: asset.id, reason: 'budget_exceeded' });
  }

  // Cross-asset dedup (P0.7). The same accepted-plan requirement text is carried
  // by BOTH the inline `accepted_plan` asset and the memory snapshot's
  // `canon_constraints` (short-memory-snapshot.js#taskAcceptedPlanningConstraints
  // copies task.accepted_plan.requirements into canon_constraints). When both are
  // in the packet the prose context would show the identical fact twice. We keep
  // the authoritative copy in `accepted_plan` and collapse the duplicate inside
  // the memory snapshot, annotating it with a pointer back to the plan so the
  // evidence trail stays queryable. We only ever match by normalized substring
  // overlap — no fuzzy / semantic similarity — to avoid silently dropping facts
  // that merely look alike.
  const dedup = crossAssetDeduplication(entries);
  for (const edit of dedup.edits) {
    const entry = entries[edit.entryIndex];
    if (!entry) continue;
    entry.content = edit.content;
    entry.estimated_tokens = estimateTokens(edit.content);
    entry.truncated = true;
    used += edit.tokenDelta;
  }

  const includedAssets = uniqueAssetLabels(entries);
  const omittedAssets = uniqueAssetLabels((omitted || []).map(item => ({ kind: assetKindFromId(item.id) })));

  return {
    entries,
    omitted,
    blocked_required: blockedRequired,
    used_tokens: Math.max(0, used),
    digest: sha256(entries.map((entry) => `${entry.id}:${sha256(entry.content)}`).join('|')),
    deduplicated_items: dedup.deduplicated_items,
    included_assets: includedAssets,
    omitted_assets: omittedAssets,
  };
}

// crossAssetDeduplication
//
// "Same fact" detection is deliberately conservative: a memory snapshot
// canon_constraint is treated as a duplicate of an accepted-plan requirement
// when, after normalizing both (strip punctuation/whitespace/case), one is a
// substring of the other. This catches the exact projection that
// short-memory-snapshot.js performs (requirement.text -> canon_constraint.content
// verbatim) without risking semantic false-positives. We only dedup canon_constraints
// against the inline accepted_plan asset; facts/promises/style rules are distinct
// semantic units and stay verbatim.
function crossAssetDeduplication(entries) {
  const planEntry = entries.find(entry => entry && entry.kind === 'accepted_plan');
  const memoryEntry = entries.find(entry => entry && entry.kind === 'memory_snapshot');
  const edits = [];
  if (!planEntry || !memoryEntry) {
    return { edits, deduplicated_items: 0 };
  }
  const requirementTexts = extractAcceptedPlanRequirementText(planEntry.content)
    .map(text => ({ raw: text, normalized: normalizeForDedup(text) }))
    .filter(item => item.normalized.length >= MIN_DEDUP_SUBSTRING_LEN);
  if (!requirementTexts.length) {
    return { edits, deduplicated_items: 0 };
  }
  const editedMemoryContent = collapseDuplicateMemoryConstraints(memoryEntry.content, requirementTexts);
  if (!editedMemoryContent || editedMemoryContent.collapsedCount <= 0) {
    return { edits, deduplicated_items: 0 };
  }
  const beforeTokens = memoryEntry.estimated_tokens || estimateTokens(memoryEntry.content);
  const afterTokens = estimateTokens(editedMemoryContent.text);
  edits.push({
    entryIndex: entries.indexOf(memoryEntry),
    content: editedMemoryContent.text,
    tokenDelta: afterTokens - beforeTokens,
  });
  return { edits, deduplicated_items: editedMemoryContent.collapsedCount };
}

const MIN_DEDUP_SUBSTRING_LEN = 6;

function extractAcceptedPlanRequirementText(planContent) {
  let plan;
  try {
    plan = JSON.parse(String(planContent || ''));
  } catch (_) {
    return [];
  }
  if (!plan || typeof plan !== 'object') return [];
  const requirements = Array.isArray(plan.requirements) ? plan.requirements : [];
  return requirements
    .map(row => String((row && (row.text || row.content)) || '').trim())
    .filter(Boolean);
}

function collapseDuplicateMemoryConstraints(memoryContent, requirementTexts) {
  let snapshot;
  try {
    snapshot = JSON.parse(String(memoryContent || ''));
  } catch (_) {
    return null;
  }
  if (!snapshot || typeof snapshot !== 'object') return null;
  const constraints = Array.isArray(snapshot.canon_constraints) ? snapshot.canon_constraints : [];
  if (!constraints.length) return null;
  let collapsedCount = 0;
  const rewritten = constraints.map(constraint => {
    if (!constraint || typeof constraint !== 'object') return constraint;
    const content = String(constraint.content || '').trim();
    if (!content) return constraint;
    const normalizedContent = normalizeForDedup(content);
    const match = requirementTexts.find(item => item.normalized.length >= MIN_DEDUP_SUBSTRING_LEN && (
      normalizedContent.includes(item.normalized) || item.normalized.includes(normalizedContent)
    ));
    if (!match) return constraint;
    collapsedCount += 1;
    // Do NOT re-emit the raw requirement text here — that would re-introduce the
    // duplicate the dedup is removing. Keep the constraint id + evidence so the
    // cross-reference is still queryable, and point back to accepted_plan.
    return {
      ...constraint,
      content: '见 accepted_plan（本条已与已接受规划去重，证据来源保留）',
      deduplicated_against: 'accepted_plan',
    };
  });
  if (collapsedCount === 0) return null;
  const text = JSON.stringify({ ...snapshot, canon_constraints: rewritten }, null, 2);
  return { text, collapsedCount };
}

function normalizeForDedup(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[\s\u3000]+/g, '')
    .replace(/[，。、；：！？“”「」『』（）()【】《》<>,.;:!?'"`~\-_=/\\|*+#@&]/g, '');
}

function uniqueAssetLabels(entries) {
  const labels = [];
  const seen = new Set();
  for (const entry of entries || []) {
    if (!entry || !entry.kind) continue;
    const label = ASSET_KIND_LABELS[entry.kind] || entry.kind;
    if (!seen.has(label)) {
      seen.add(label);
      labels.push(label);
    }
  }
  return labels;
}

// assetKindFromId recovers an asset kind label for an omitted entry. assemblePacket
// records omitted items as {id, reason}; the id is the asset's `id` field, whose
// prefix maps deterministically to the asset kind. This is a best-effort recovery
// for the budget receipt — when the id shape is unfamiliar we fall back to the id
// itself so the receipt stays honest about what we could not classify.
function assetKindFromId(id) {
  const raw = String(id || '');
  const entry = Object.values(ASSET_KIND_LABELS).find(label => raw.includes(label));
  if (entry) return entry;
  if (/写作Brief|repair_constraints/i.test(raw)) return 'brief';
  if (/memory|记忆快照/i.test(raw)) return 'memory_snapshot';
  if (/accepted_plan|accepted-plan/i.test(raw)) return 'accepted_plan';
  if (/anchor/i.test(raw)) return 'accepted_anchor';
  if (/素材卡|设定|小节大纲|outline/i.test(raw)) return 'plan_summary';
  if (/风格卡|voice/i.test(raw)) return 'voice_card';
  return raw || 'unknown';
}

const ASSET_KIND_LABELS = {
  accepted_plan: 'accepted_plan',
  accepted_revision_obligations: 'accepted_revision_obligations',
  accepted_anchor: 'accepted_anchor',
  brief: 'brief',
  repair_constraints: 'brief',
  continuity_tail: 'continuity_tail',
  current_draft: 'current_draft',
  current_draft_expression_focus: 'current_draft',
  gate_findings: 'gate_findings',
  memory_snapshot: 'memory_snapshot',
  outline_contract: 'outline_contract',
  plan_summary: 'plan_summary',
  plan_overview: 'plan_overview',
  pending_feedback: 'pending_feedback',
  voice_card: 'voice_card',
};

function withArtifactIdentity(asset, content, estimatedTokens, truncated) {
  const contentDigest = `sha256:${sha256(content)}`;
  return {
    ...asset,
    artifact_id: `artifact:${sha256(`${asset.kind}\n${asset.path}\n${contentDigest}`)}`,
    content_digest: contentDigest,
    content,
    estimated_tokens: estimatedTokens,
    truncated,
  };
}

function readAssetText(root, asset) {
  if (typeof asset.inline === 'string') return asset.inline;
  // asset.path is always a project-relative POSIX path; reject absolute / `..`.
  const raw = String(asset.path || '');
  if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/).includes('..')) return null;
  // Anchors reference a `#tail` anchor on 正文.md; the on-disk path is the prefix.
  const onDisk = raw.includes('#') ? raw.split('#')[0] : raw;
  const file = path.resolve(root, onDisk);
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return null;
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

function extractPayload(asset, fileText, sectionIndex, stageId) {
  const text = String(fileText || '');
  switch (asset.kind) {
    case 'brief':
      return REVIEW_STAGES.has(stageId)
        ? extractBriefConstraints(text, [
          '本节任务',
          '上节承接锁定',
          '视角与称谓',
          '主角动作与关系变化',
          '禁止漂移',
          '节尾钩子',
          '验收标准',
        ])
        : text.trim();
    case 'repair_constraints':
      return extractBriefConstraints(text, [
        '因果动作链',
        '承接',
        '目标与阻力',
        '人物与视角锁',
        '禁写项',
        '节尾钩子',
        '本节任务',
        '视角与称谓',
        '禁止漂移',
        '验收标准',
      ]);
    case 'gate_findings': {
      try {
        const packet = JSON.parse(text);
        return JSON.stringify({
          machine_gate_result: packet.machine_gate_result || packet.verification_result || '',
          blocking_findings: Array.isArray(packet.blocking_findings) ? packet.blocking_findings : [],
          evidence: (Array.isArray(packet.evidence) ? packet.evidence : [])
            .filter((item) => item && (item.blocking === true || String(item.status || '') === 'blocking'))
            .map((item) => ({ check: item.check || '', status: item.status || '', finding_count: item.finding_count || 0 })),
        }, null, 2);
      } catch {
        return '';
      }
    }
    case 'current_draft':
      return text.trim();
    case 'current_draft_expression_focus':
      return extractDraftFocus(text, String(asset.feedbackText || ''));
    case 'accepted_anchor': {
      try {
        const anchor = JSON.parse(text);
        return JSON.stringify({
          workflow_id: anchor.workflow_id || '',
          section_index: anchor.section_index || sectionIndex - 1,
          status: anchor.status || '',
          canonical_path: anchor.canonical_path || '',
          section_commit_id: anchor.section_commit_id || '',
          section_summary: anchor.section_summary || '',
          revealed_information: Array.isArray(anchor.revealed_information) ? anchor.revealed_information : [],
          character_state: anchor.character_state && typeof anchor.character_state === 'object' ? anchor.character_state : {},
          open_hook: anchor.open_hook || '',
          style_anchor: Array.isArray(anchor.style_anchor) ? anchor.style_anchor : [],
          next_section_handoff: anchor.next_section_handoff && typeof anchor.next_section_handoff === 'object' ? anchor.next_section_handoff : {},
          quality_result: anchor.quality_result || null,
        }, null, 2);
      } catch {
        // Fall back to a trimmed raw snapshot — still exclude other fields.
        return text.trim().slice(0, 1200);
      }
    }
    case 'plan_summary':
      // We deliberately surface only a short digest of the plan assets so the
      // prose Agent has POV / rhythm / outline context without re-reading the
      // full file. The full text stays on disk.
      return summarizePlan(asset.id, text, sectionIndex);
    case 'plan_overview':
      return summarizeWholePlan(asset.id, text);
    case 'pending_feedback':
      return text.trim();
    case 'memory_snapshot':
      return text.trim();
    case 'outline_contract':
      return text.trim();
    case 'continuity_tail':
      return lastParagraphs(text, CONTINUITY_TAIL_PARAGRAPHS);
    case 'voice_card':
      return text.trim();
    default:
      return text.trim();
  }
}

function outlineContractAsset(root, sectionIndex, stageId) {
  const contract = buildShortSectionOutlineContract(root, sectionIndex);
  if (contract.status !== 'current') {
    return {
      id: `小节大纲.md#section-${String(sectionIndex).padStart(3, '0')}-contract`,
      path: '[当前小节故事合同缺失]',
      kind: 'outline_contract',
      required: true,
    };
  }
  const instruction = BRIEF_STAGES.has(stageId)
    ? '必须在写作提要的自然结构中覆盖以下剧情义务；不要把机器 ID 或覆盖映射复制进写作提要，工作流会生成独立校验旁证。'
    : REVIEW_STAGES.has(stageId) || ACCEPTANCE_STAGES.has(stageId)
      ? '质量证据必须返回 outline_contract_digest 与 outline_coverage，每个必写 ID 都要引用正文中可核验的原句。'
      : '正文必须执行所有 required_in_draft 条目；不得在写作时改写小节功能、核心爆点或结尾后果。';
  return {
    id: `小节大纲.md#section-${String(sectionIndex).padStart(3, '0')}-contract`,
    path: '小节大纲.md',
    kind: 'outline_contract',
    required: true,
    inline: [
      `# 第${sectionIndex}节故事合同`,
      `- 合同摘要：${contract.contract_digest}`,
      `- 小节角色：${contract.section_role}`,
      `- 阶段要求：${instruction}`,
      '',
      renderOutlineCoverageTemplate(contract),
    ].join('\n'),
  };
}

function extractBriefConstraints(text, wantedHeadings) {
  const lines = String(text || '').split(/\r?\n/);
  const wanted = new Set(wantedHeadings);
  const kept = [];
  let active = false;
  for (const line of lines) {
    const heading = line.match(/^##\s+(.+?)\s*$/);
    if (heading) {
      active = wanted.has(heading[1]);
      if (active) kept.push(line);
      continue;
    }
    if (active) kept.push(line);
  }
  const selected = kept.join('\n').trim();
  if (selected) return selected;
  const legacyLines = lines
    .map((line) => line.trim())
    .filter((line) => /^(视角|人物|称谓|因果|钩子|禁止|验收|承接|本节任务)[：:]/.test(line));
  return legacyLines.length ? ['## 修订必要约束', ...legacyLines].join('\n') : '';
}

function summarizePlan(label, text, sectionIndex) {
  const source = String(text || '').trim();
  if (!source) return '';
  const sectionBlock = extractOutlineSection(source, sectionIndex);
  const lines = sectionBlock && /小节大纲/u.test(String(label || ''))
    ? []
    : source.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).slice(0, 8);
  const pov = (source.match(/(第一人称|第三人称|叙事方式|视角)[^\n]{0,40}/) || [])[0] || '';
  const rhythm = (source.match(/(主节奏|节奏模型|节奏：)[^\n]{0,40}/) || [])[0] || '';
  const labelLine = `# ${label}（摘要）`;
  return [labelLine, ...lines, sectionBlock, pov, rhythm].filter(Boolean).join('\n');
}

function summarizeWholePlan(label, text) {
  const source = String(text || '').trim();
  if (!source) return '';
  const lines = source.split(/\r?\n/);
  const structural = lines.filter((line) => {
    const value = line.trim();
    return /^#{1,6}\s+/u.test(value)
      || /^(?:[-*]\s*)?(?:结构功能|承接上节|场景动作|情绪目标|压力变化|因果链|角色选择|可见阻力|本节兑现|关系变化|代价升级|核心承诺兑现|决定性行动|即时代价|节尾钩子|人物功能|结局|终局|主题|主线)[：:]/u.test(value);
  });
  const selected = structural.length ? structural : lines.filter(line => line.trim()).slice(0, 24);
  return [`# ${label}（全篇结构摘要）`, ...selected].join('\n');
}

function isWholeStoryFeedback(task) {
  const pending = (task || {}).pending_feedback || {};
  return /(?:全篇|整篇|全文|通篇|结局|终局)/u.test(`${String(pending.scope_snapshot || '')}\n${String(pending.text || '')}`);
}

function isExpressionOnlyRepairStage(task, stageId) {
  if (stageId !== 'section_repair_loop') return false;
  const pending = (task || {}).pending_feedback || {};
  if (!String(pending.text || '').trim()) return false;
  const impact = (task || {}).short_feedback_impact || {};
  const matchesImpact = String(impact.feedback_id || '') === String(pending.feedback_id || '');
  if (matchesImpact && String(impact.impact_level || '') === 'expression_only') return true;
  const direct = String(pending.impact_level_hint || pending.impact_hint || '').trim();
  if (direct === 'expression_only') return true;
  const items = Array.isArray(pending.items) ? pending.items : [];
  return items.length > 0 && items.every(item => String((item || {}).impact_level_hint || '') === 'expression_only');
}

function extractDraftFocus(text, feedbackText) {
  const source = String(text || '').trim();
  if (!source) return '';
  const quote = extractFeedbackQuote(feedbackText);
  if (!quote) return source;
  const index = source.indexOf(quote);
  if (index < 0) return source;
  const start = Math.max(0, source.lastIndexOf('\n', Math.max(0, index - 900)) + 1);
  const after = source.indexOf('\n', Math.min(source.length, index + quote.length + 900));
  const end = after >= 0 ? after : Math.min(source.length, index + quote.length + 900);
  return [
    '# 当前草稿局部片段',
    `- 反馈命中原句：${quote}`,
    '- 只允许修订这一句及其前后必要衔接；不得改写整节结构。',
    '',
    source.slice(start, end).trim(),
  ].join('\n');
}

function extractFeedbackQuote(feedbackText) {
  const value = String(feedbackText || '');
  const quoted = value.match(/[“「『"]([^”」』"]{6,160})[”」』"]/u);
  if (quoted) return quoted[1].trim();
  const bare = value.replace(/^\[意见\s*\d+\]\s*/u, '').split(/[。！？!?]/u)[0].trim();
  return bare.length >= 6 && bare.length <= 160 ? bare : '';
}

function extractOutlineSection(source, sectionIndex) {
  const lines = String(source || '').split(/\r?\n/);
  const wanted = Number(sectionIndex || 0);
  if (!Number.isInteger(wanted) || wanted < 1) return '';
  let start = -1;
  let level = 0;
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(/^(#{1,6})\s*第\s*0*(\d+)\s*节(?:\s*[：:]|\s|$)/u);
    if (!match || Number(match[2]) !== wanted) continue;
    start = index;
    level = match[1].length;
    break;
  }
  if (start < 0) return '';
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    const heading = lines[index].match(/^(#{1,6})\s+/u);
    if (heading && heading[1].length <= level) {
      end = index;
      break;
    }
  }
  return [`## 当前第${wanted}节大纲块`, ...lines.slice(start, end)].join('\n').trim();
}

function lastParagraphs(text, count) {
  const paragraphs = String(text || '').split(/\n\s*\n/).map((chunk) => chunk.trim()).filter(Boolean);
  if (!paragraphs.length) return '';
  const tail = paragraphs.slice(-Math.max(1, count)).join('\n\n');
  return `# 上一节正式稿承接片段（末尾 ${count} 段）\n${tail}`;
}

function safePathSegment(value) {
  return String(value || 'attempt-pending').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 96) || 'attempt-pending';
}

function renderMarkdown({ workflowId, sectionIndex, stageId, assets, tokenBudget, usedTokens, omitted, identity, modelProfile }) {
  const lines = [];
  lines.push(`# 短篇当前小节最小上下文包 (workflow=${workflowId}, stage=${stageId}, section=${sectionIndex})`);
  lines.push('');
  lines.push('> 这是本小节唯一允许读取的最小上下文包。只使用包内资产，不得自由搜索其他文件。');
  lines.push('');
  lines.push('## 作品身份锁');
  lines.push(`- 作品标题：${identity.project_title || '未命名短篇'}`);
  lines.push(`- 当前小节：第 ${sectionIndex} 节${identity.current_section_title ? `《${identity.current_section_title}》` : ''}`);
  lines.push('- 可见回复、recap 和任务名必须使用“作品标题”；不得用小节标题称呼整篇作品。');
  lines.push('');
  lines.push(`> 预算：${tokenBudget} tokens（已用 ${usedTokens}）。${advisory}`);
  lines.push('');
  if (modelProfile && modelProfile.family) {
    lines.push('## 当前模型运行约束');
    lines.push(`- 模型族：${modelProfile.family}`);
    for (const directive of (Array.isArray(modelProfile.prompt_directives) ? modelProfile.prompt_directives : [])) {
      lines.push(`- ${directive}`);
    }
    lines.push('');
  }
  lines.push('## 允许资产（最小集）');
  for (const asset of assets) {
    lines.push(`### ${asset.id}（${asset.kind}${asset.truncated ? ', 已按预算截断' : ''}）`);
    lines.push(`路径：${asset.path}`);
    lines.push('');
    lines.push(asset.content);
    lines.push('');
  }
  if (omitted.length) {
    lines.push('## 已排除（按预算或缺失）');
    for (const item of omitted) lines.push(`- ${item.id}: ${item.reason}`);
    lines.push('');
  }
  lines.push('## 明确排除（永远不得读取）');
  for (const exclude of EXPLICIT_EXCLUDES) lines.push(`- ${exclude}`);
  return `${lines.join('\n')}\n`;
}

function shortProjectIdentity(root, projectState, sectionIndex) {
  const lock = readJsonFile(shortStateFile(root, 'section-title-lock.json')) || {};
  const item = (Array.isArray(lock.sections) ? lock.sections : []).find((entry) => Number((entry || {}).section_index) === sectionIndex);
  return {
    project_title: String(projectState.working_title || projectState.book_title || projectState.title || '').trim(),
    current_section_title: item && item.confirmed === true ? String(item.title || '').trim() : '',
  };
}

function readJsonFile(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function currentDraftAsset(root, sectionIndex, options = {}) {
  const padded = String(sectionIndex).padStart(3, '0');
  const candidates = [`草稿_第${padded}节_候选.md`, `正文_第${padded}节.md`];
  for (const candidate of candidates) {
    const file = safeResolve(root, candidate);
    if (file && fs.existsSync(file) && fs.statSync(file).isFile()) {
      return {
        id: candidate,
        path: candidate,
        kind: String(options.kind || 'current_draft'),
        required: true,
        feedbackText: String(options.feedbackText || ''),
      };
    }
  }
  return {
    id: candidates[0],
    path: candidates[0],
    kind: String(options.kind || 'current_draft'),
    required: true,
    feedbackText: String(options.feedbackText || ''),
  };
}

function readProjectState(root) {
  const parsed = readShortProjectState(root);
  return parsed && !parsed.__error ? parsed : {};
}

function safeResolve(root, relativePath) {
  const raw = String(relativePath || '');
  if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/).includes('..')) return '';
  const resolved = path.resolve(root, raw);
  if (resolved !== path.resolve(root) && !resolved.startsWith(`${path.resolve(root)}${path.sep}`)) return '';
  return resolved;
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest('hex');
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

function notApplicable(reason) {
  return { status: 'not_applicable', reason, packet_md: '', packet_json: '', source_files: [] };
}

module.exports = {
  EXPLICIT_EXCLUDES,
  buildStageContextPacket,
};
