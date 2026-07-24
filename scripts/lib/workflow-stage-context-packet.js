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
const { compactToTokens, estimateTokens } = require('./context-budget');
const { inferShortSectionIndex } = require('./short-workflow-state');
const { currentShortFeedbackRevisionSection } = require('./short-feedback-revision-queue');
const { atomicWriteJson, atomicWriteText } = require('./workflow-state-store');
const { buildShortMemorySnapshot } = require('./short-memory-snapshot');
const {
  buildShortSectionOutlineContract,
  renderOutlineCoverageTemplate,
} = require('./short-section-outline-contract');

const DRAFT_STAGES = new Set(['draft_first_section', 'draft_next_section', 'draft_section']);
const REVIEW_STAGES = new Set(['section_repair_loop', 'quality_gate', 'story_value_gate']);
const BRIEF_STAGES = new Set(['first_section_brief', 'section_brief', 'next_section_brief']);
const ACCEPTANCE_STAGES = new Set(['section_accept_anchor']);
const FEEDBACK_STAGES = new Set(['feedback_impact_sync', 'feedback_apply_patch']);
const CONTEXT_STAGES = new Set([...DRAFT_STAGES, ...REVIEW_STAGES, ...BRIEF_STAGES, ...ACCEPTANCE_STAGES, ...FEEDBACK_STAGES]);
const SHORT_WORKFLOW_TYPES = new Set(['short_write', 'short_startup', 'private_short_startup']);
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
  const sectionIndex = positiveInteger(
    currentShortFeedbackRevisionSection(task)
    ||
    inferShortSectionIndex({
      projectState,
      stageId,
      scope: String((task || {}).scope || ''),
    })
  );
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
  const packetScope = FEEDBACK_STAGES.has(stageId) && isWholeStoryFeedback(task)
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
    };
  }
  const identity = shortProjectIdentity(root, projectState, sectionIndex);
  const markdown = renderMarkdown({
    workflowId: taskId,
    sectionIndex,
    stageId,
    assets: assembled.entries,
    tokenBudget,
    usedTokens: assembled.used_tokens,
    omitted: assembled.omitted,
    identity,
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
    advisory,
    source_files: assembled.entries.map((entry) => ({
      id: entry.id,
      path: entry.path,
      kind: entry.kind,
      estimated_tokens: entry.estimated_tokens,
      truncated: entry.truncated,
    })),
    omitted: assembled.omitted,
    excludes: EXPLICIT_EXCLUDES,
    memory_contract: memorySnapshot.contract || null,
    memory_read_receipt: memorySnapshot.receipt || null,
    created_at: new Date().toISOString(),
  });

  return {
    status: 'assembled',
    packet_md: packetMdRel,
    packet_json: packetJsonRel,
    estimated_tokens: assembled.used_tokens,
    digest: assembled.digest,
    token_budget: tokenBudget,
    budget_source: budget.source,
    required_tokens: budget.required_tokens,
    optional_tokens_available: budget.optional_tokens_available,
    source_files: assembled.entries.map((entry) => ({ id: entry.id, path: entry.path, kind: entry.kind })),
    omitted: assembled.omitted,
    section_index: sectionIndex,
    project_title: identity.project_title,
    current_section_title: identity.current_section_title,
    memory_contract: memorySnapshot.contract || null,
    memory_read_receipt: memorySnapshot.receipt || null,
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
  const ratio = optionalBudgetRatio(stageId);
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
    ? `追踪/private-short-extension/section-${String(sectionIndex - 1).padStart(3, '0')}-anchor.json`
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
  if (stageId === 'section_repair_loop') {
    const gatePacket = String((((task || {}).machine || {}).last_result_packet) || '');
    return {
      gateFindings: gatePacket
        ? { id: gatePacket, path: gatePacket, kind: 'gate_findings', required: true }
        : null,
      brief: { id: briefPath, path: briefPath, kind: 'repair_constraints', required: true },
      currentDraft: currentDraftAsset(root, sectionIndex),
      memorySnapshot: memoryAsset,
    };
  }

  const includePlanSummaries = DRAFT_STAGES.has(stageId) || BRIEF_STAGES.has(stageId) || FEEDBACK_STAGES.has(stageId);
  const pendingFeedback = FEEDBACK_STAGES.has(stageId) && String((((task || {}).pending_feedback || {}).text) || '').trim()
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
    ? activeRevisionPlanAsset(task, sectionIndex)
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

function activeRevisionPlanAsset(task = {}, sectionIndex) {
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  const plan = task.accepted_plan && typeof task.accepted_plan === 'object'
    ? task.accepted_plan
    : null;
  if (!queue || String(queue.status || '') !== 'running' || !plan) return null;
  const item = (Array.isArray(queue.items) ? queue.items : [])
    .find(row => Number((row || {}).section_index || 0) === sectionIndex);
  if (!item || String(item.status || '') === 'accepted') return null;
  const group = (Array.isArray(queue.groups) ? queue.groups : [])
    .find(row => (Array.isArray((row || {}).section_indices) ? row.section_indices : []).map(Number).includes(sectionIndex));
  return {
    id: `${String(plan.plan_id || 'accepted-plan')}#section-${String(sectionIndex).padStart(3, '0')}`,
    path: String(task.accepted_plan_path || '[workflow accepted_plan]'),
    kind: 'accepted_revision_obligations',
    required: true,
    inline: JSON.stringify({
      plan_id: String(plan.plan_id || ''),
      feedback_id: String(queue.feedback_id || plan.feedback_id || ''),
      section_index: sectionIndex,
      plan_status: String(plan.status || ''),
      memory_constraint_source: '当前作品记忆快照.canon_constraints',
      queue_item: {
        brief_status: String(item.brief_status || ''),
        prose_status: String(item.prose_status || ''),
      },
      revision_group: group ? {
        group_id: String(group.group_id || ''),
        goal: String(group.goal || ''),
        completion_rule: String(group.completion_rule || ''),
      } : null,
      instruction: '本节 Brief、正文复检和质量判断必须兑现当前作品记忆快照中的已确认规划约束；如与当前大纲冲突，先返回规划影响链，不得静默忽略。',
    }, null, 2),
  };
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
      entries.push({ ...asset, content: payload, estimated_tokens: payloadTokens, truncated: false });
      used += payloadTokens;
      continue;
    }
    if (payloadTokens <= remaining) {
      entries.push({ ...asset, content: payload, estimated_tokens: payloadTokens, truncated: false });
      used += payloadTokens;
      continue;
    }
    if (remaining > 0) {
      const compacted = compactToTokens(payload, remaining);
      entries.push({ ...asset, content: compacted, estimated_tokens: estimateTokens(compacted), truncated: true });
      used += estimateTokens(compacted);
      omitted.push({ id: asset.id, reason: 'budget_truncated' });
      continue;
    }
    omitted.push({ id: asset.id, reason: 'budget_exceeded' });
  }

  return {
    entries,
    omitted,
    blocked_required: blockedRequired,
    used_tokens: used,
    digest: sha256(entries.map((entry) => `${entry.id}:${sha256(entry.content)}`).join('|')),
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

function renderMarkdown({ workflowId, sectionIndex, stageId, assets, tokenBudget, usedTokens, omitted, identity }) {
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
  const lock = readJsonFile(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const item = (Array.isArray(lock.sections) ? lock.sections : []).find((entry) => Number((entry || {}).section_index) === sectionIndex);
  return {
    project_title: String(projectState.working_title || projectState.book_title || projectState.title || '').trim(),
    current_section_title: item && item.confirmed === true ? String(item.title || '').trim() : '',
  };
}

function readJsonFile(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function currentDraftAsset(root, sectionIndex) {
  const padded = String(sectionIndex).padStart(3, '0');
  const candidates = [`草稿_第${padded}节_候选.md`, `正文_第${padded}节.md`];
  for (const candidate of candidates) {
    const file = safeResolve(root, candidate);
    if (file && fs.existsSync(file) && fs.statSync(file).isFile()) {
      return { id: candidate, path: candidate, kind: 'current_draft', required: true };
    }
  }
  return { id: candidates[0], path: candidates[0], kind: 'current_draft', required: true };
}

function readProjectState(root) {
  try {
    const file = path.join(root, '追踪/private-short-extension/project-state.json');
    if (!fs.existsSync(file)) return {};
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return parsed && !parsed.__error ? parsed : {};
  } catch {
    return {};
  }
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
