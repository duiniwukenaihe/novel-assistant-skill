'use strict';

// Task 3 V3 engine: the single writer that advances a V3 durable task.json.
//
// Contract:
//   - createTask stamps the three contract versions and persists task.json as
//     the sole source of truth.
//   - applyStageResult validates stage identity and that the lifecycle is not
//     already completed, prepares the interaction, commits exactly once, and
//     renders the visible response from the Arbiter off the committed snapshot
//     returned by commitTask.
//   - resolveAuthorInput validates the four host-supplied binding fields
//     against the committed pending action and atomically marks it resolved;
//     it also refuses a completed task so closure is the consistent reason
//     regardless of which entry point is replayed.
//
// All mutations go through task-store.commitTask, which takes the project lock,
// commits under it, and rereads the committed bytes back UNDER THE SAME LOCK,
// re-checking the expected state version before any binding logic can write.
// A stale expectedVersion always surfaces as WORKFLOW_TASK_CONFLICT.

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const store = require('./task-store');
const { hasWorkflowExecutionCapability, withWorkflowExecutionLock } = require('./execution-lock');
const { prepareInteraction, renderCommittedInteraction, consumeBinding } = require('./interaction-arbiter');
const { nextNode, SHORT_ENTRY_STAGE, isTerminalCompletion } = require('./short-graph');
const {
  acceptShortFeedbackRevisionSection,
  initializeShortFeedbackRevisionQueue,
  initializeAssemblyIntegrityRevisionQueue,
  initializeEditorialLengthRevisionQueue,
} = require('../short-feedback-revision-queue');
const { projectAcceptedShortPlanningFeedback } = require('../short-planning-memory');
const { buildEditorialFeedbackDraft } = require('../short-editorial-feedback');
const {
  parseShortSectionOrdinal,
  readShortProjectState,
  resolveShortStateRelative,
} = require('../short-project-state');
const { atomicWriteJson } = require('../workflow-state-store');

function createTask(projectRoot, input = {}) {
  const workflowId = String(input.workflow_id || '');
  if (!workflowId) throw new Error('workflow_id_required');
  // The Engine owns the entry stage. Any caller-supplied current_stage is
  // rejected before a task is written, even if the value happens to equal the
  // canonical entry: the field is engine authority, not a caller input.
  if (Object.prototype.hasOwnProperty.call(input, 'current_stage')) {
    throw new Error('current_stage_owned_by_engine');
  }
  return store.createTaskRecord(projectRoot, {
    ...input,
    workflow_id: workflowId,
    current_stage: SHORT_ENTRY_STAGE,
  });
}

// Compatibility imports sometimes need the very first durable V3 snapshot to
// already contain an Arbiter-bound author choice. Preparing that interaction
// from a conceptual version-0 task makes its binding target state_version 1,
// which is exactly the version createTaskRecord commits. The task and its
// pending action therefore become visible atomically; no host can observe a
// half-imported V3 task without its recovery choices.
function createTaskWithInitialInteraction(projectRoot, input = {}, result = {}) {
  const workflowId = String(input.workflow_id || '');
  if (!workflowId) throw new Error('workflow_id_required');
  if (Object.prototype.hasOwnProperty.call(input, 'current_stage')) {
    throw new Error('current_stage_owned_by_engine');
  }
  assertStageMatch(String(result.stage_id || ''), SHORT_ENTRY_STAGE);
  const prepared = prepareInteraction({
    ...input,
    workflow_id: workflowId,
    current_stage: SHORT_ENTRY_STAGE,
    state_version: 0,
  }, result);
  if (!prepared.pending_action) throw new Error('initial_author_choice_required');
  const task = store.createTaskRecord(projectRoot, {
    ...input,
    workflow_id: workflowId,
    current_stage: SHORT_ENTRY_STAGE,
    pending_action: prepared.pending_action,
  });
  return { task, visible_response: renderCommittedInteraction(task) };
}

function readTask(projectRoot, workflowId) {
  return store.readTaskRecord(projectRoot, workflowId);
}

function projectEditorialReviewCompatibility(task, result, source = 'workflow_v3_editorial_review') {
  const decision = String(result.decision || '');
  if (!['pass', 'revise'].includes(decision)) throw new Error('editorial_review_decision_required');
  const findings = Array.isArray(result.findings) ? result.findings : [];
  task.short_full_story_review = {
    decision,
    visible_verdict: decision === 'pass' ? 'story_ready' : 'revision_required',
    visible_label: decision === 'pass' ? '故事层可进入表达清理' : '故事层需先回炉',
    story_sha256: String(result.story_sha256 || ''),
    evidence_pack_path: String(result.evidence_pack_path || ''),
    reader_response_path: String(result.reader_response_path || ''),
    review_card_path: String(result.review_card_path || ''),
    review_card_sha256: String(result.review_card_sha256 || ''),
    receipt_path: String(result.receipt_path || ''),
    findings: JSON.parse(JSON.stringify(findings)),
    accepted_at: new Date().toISOString(),
  };
  task.short_full_story_review_projection = {
    status: decision === 'pass' ? 'review_passed' : 'review_revision_required',
    finding_count: findings.length,
    source,
    receipt_path: String(result.receipt_path || ''),
  };
}

function recoverEditorialReviewCompatibility(projectRoot, task) {
  const root = path.resolve(String(projectRoot || ''));
  const latestFile = path.resolve(root, String(task.task_dir || ''), 'artifacts/closure/editorial-review/latest.json');
  if (!latestFile.startsWith(`${root}${path.sep}`) || !fs.existsSync(latestFile)) return;
  let latest;
  try { latest = JSON.parse(fs.readFileSync(latestFile, 'utf8')); } catch (_) { return; }
  if (String(latest.workflow_id || '') !== String(task.workflow_id || '')) return;
  const receiptFile = path.resolve(root, String(latest.receipt_path || ''));
  if (!receiptFile.startsWith(`${root}${path.sep}`) || !fs.existsSync(receiptFile)) return;
  const receiptBytes = fs.readFileSync(receiptFile);
  const receiptHash = crypto.createHash('sha256').update(receiptBytes).digest('hex');
  if (receiptHash !== String(latest.receipt_sha256 || '').replace(/^sha256:/u, '')) return;
  let receipt;
  try { receipt = JSON.parse(receiptBytes.toString('utf8')); } catch (_) { return; }
  if (String(receipt.workflow_id || '') !== String(task.workflow_id || '')) return;
  if (!['pass', 'revise'].includes(String(receipt.decision || ''))) return;
  const current = task.short_full_story_review && typeof task.short_full_story_review === 'object'
    ? task.short_full_story_review
    : {};
  const projection = task.short_full_story_review_projection && typeof task.short_full_story_review_projection === 'object'
    ? task.short_full_story_review_projection
    : {};
  if (String(current.decision || '') === String(receipt.decision || '')
    && String(current.story_sha256 || '') === String(receipt.story_sha256 || '')
    && String(projection.status || '') === (String(receipt.decision || '') === 'pass' ? 'review_passed' : 'review_revision_required')) return;
  projectEditorialReviewCompatibility(task, {
    ...receipt,
    receipt_path: String(latest.receipt_path || ''),
  }, 'workflow_v3_editorial_receipt_recovery');
}

function applyStageResult(projectRoot, workflowId, expectedVersion, result, capability) {
  if (hasWorkflowExecutionCapability(capability, projectRoot)) {
    return applyStageResultUnderLock(projectRoot, workflowId, expectedVersion, result);
  }
  return withWorkflowExecutionLock(projectRoot, 'workflow-v3-apply-stage-result', () => (
    applyStageResultUnderLock(projectRoot, workflowId, expectedVersion, result)
  ));
}

function applyStageResultUnderLock(projectRoot, workflowId, expectedVersion, result) {
  const stageId = String((result || {}).stage_id || '');
  if (!stageId) throw new Error('stage_result_stage_required');

  const current = store.readTaskRecord(projectRoot, workflowId);
  // Stage identity guard: refuse a result that does not match the committed
  // current stage before any write is attempted.
  assertStageMatch(stageId, current.current_stage);
  // Terminal-closure guard: once the lifecycle is completed, no further result
  // may be applied — not a completed result, not a needs_author_choice result.
  // Checked BEFORE preparation so an in-flight Arbiter draft is never built for
  // a closed task, and rechecked inside the commit so a concurrent completion
  // cannot be overtaken before the mutation runs.
  assertNotCompleted(current);

  const editorialFeedbackDraft = stageId === 'editorial_review'
    && String((result || {}).decision || '') === 'revise'
    && String((result || {}).code || '') === 'short_story_editorial_revision_required'
    ? buildEditorialFeedbackDraft(current, result)
    : null;
  if (editorialFeedbackDraft && editorialFeedbackDraft.status !== 'feedback_draft_ready') {
    throw new Error('editorial_feedback_draft_required');
  }
  const transitionResult = editorialFeedbackDraft
    ? { ...result, ...editorialFeedbackDraft.interaction_result }
    : result;
  const prepared = prepareInteraction(current, transitionResult);

  // commitTask takes the project lock, commits exactly once, and rereads the
  // committed bytes back UNDER THE SAME LOCK, returning that causal snapshot.
  // The engine renders directly off it — there is no second reread here, so the
  // committed snapshot and the rendered binding can never diverge.
  const committed = store.commitTask(projectRoot, workflowId, expectedVersion, (draft) => {
    // Re-assert under the lock so a concurrent stage transition cannot slip in.
    assertStageMatch(stageId, draft.current_stage);
    // Re-assert completion under the lock too: a concurrent final_check commit
    // could have closed the lifecycle between the outer read and this mutation,
    // and no result (completed or otherwise) may land on a closed task.
    assertNotCompleted(draft);
    // A pending action is a single-shot slot: a still-pending action must not
    // be touched by a later result, whether that result would replace it OR
    // delete it (a completed result must not silently drop the host's
    // in-flight choice). Reject before either branch can write.
    if (draft.pending_action && draft.pending_action.status === 'pending') {
      throw new Error('pending_action_already_pending');
    }
    // Terminal completion is decided from the node the result is applied TO
    // (the current committed stage), BEFORE any graph transition runs. A
    // completed result on the terminal node (no outgoing edges) closes the
    // lifecycle; current_stage STAYS final_check and the completion side-effect
    // lands in THIS same single state-version commit — task.status and
    // lifecycle.status become 'completed' with a completed_at timestamp, so the
    // version advances exactly once. Only a completed result triggers this;
    // retryable_internal / blocked at the terminal node leave it open. This
    // MUST be computed before nextNode rewrites draft.current_stage.
    const completing = isTerminalCompletion(draft, result);
    if (completing) assertAcceptedFeedbackComplete(draft);
    // Graph-driven transition: nextNode is the ONLY validator. It is invoked
    // here, inside the same commitTask mutation as the StageResult, so the new
    // current_stage lands in the SAME single state-version commit. A rejected
    // transition (e.g. a multi-next completed result missing next_stage, or a
    // target outside the node's next list) throws here, before any write —
    // leaving the durable task byte-for-byte unchanged.
    const previousStage = String(draft.current_stage || '');
    if (['deslop', 'final_check'].includes(previousStage)) {
      recoverEditorialReviewCompatibility(projectRoot, draft);
    }
    const planningConfirmationAccepted = previousStage === 'planning_confirmation'
      && String(result.kind || '') === 'completed'
      && String(result.code || '') === 'planning_confirmed';
    if (planningConfirmationAccepted) {
      advancePlanningConfirmation(projectRoot, draft, transitionResult);
    } else {
      draft.current_stage = nextNode(draft, transitionResult);
    }
    if (['section_brief', 'feedback_apply_patch'].includes(previousStage)
      && String(result.kind || '') === 'completed') {
      projectAcceptedV3FeedbackPlan(projectRoot, draft, result);
    }
    if (previousStage === 'assembly'
      && String(result.code || '') === 'short_story_assembly_revalidation_started') {
      const initialized = initializeAssemblyIntegrityRevisionQueue(draft, result);
      if (initialized.status !== 'assembly_integrity_revision_queue_created') {
        throw new Error('assembly_integrity_revision_queue_required');
      }
    }
    if (previousStage === 'editorial_review'
      && String(result.code || '') === 'short_story_length_revision_required') {
      const initialized = initializeEditorialLengthRevisionQueue(draft, result);
      if (initialized.status !== 'editorial_length_revision_queue_created') {
        throw new Error('editorial_length_revision_queue_required');
      }
    }
    if (previousStage === 'editorial_review'
      && ['short_story_editorial_passed', 'short_story_editorial_revision_required'].includes(String(result.code || ''))) {
      projectEditorialReviewCompatibility(draft, result);
    }
    if (editorialFeedbackDraft) {
      const previousFeedback = draft.pending_feedback && typeof draft.pending_feedback === 'object'
        ? draft.pending_feedback
        : null;
      if (previousFeedback
          && String(previousFeedback.id || '') !== String(editorialFeedbackDraft.pending_feedback.id || '')) {
        draft.feedback_history = [
          ...(Array.isArray(draft.feedback_history) ? draft.feedback_history : []),
          {
            ...JSON.parse(JSON.stringify(previousFeedback)),
            archived_at: new Date().toISOString(),
            archive_reason: 'superseded_by_editorial_recheck',
          },
        ];
      }
      draft.pending_feedback = JSON.parse(JSON.stringify(editorialFeedbackDraft.pending_feedback));
    }
    if (String(result.kind || '') === 'completed'
      && previousStage === 'section_accept'
      && ['short_section_accepted', 'short_section_accept_idempotent', 'short_section_accept_recovered'].includes(String(result.code || ''))) {
      acceptShortFeedbackRevisionSection(draft, result.section_index, {
        section_commit_id: String(result.commit_id || ''),
      });
      markAcceptedFeedbackApplied(draft, result);
    }
    // Engine-owned stage_attempt_id rotation. When and only when a completed
    // result actually advances to a DIFFERENT graph node, the execution is
    // atomically replaced with a minimal ready execution for the new node
    // carrying a fresh, different attempt id (chapter-commit provenance keys off
    // this id). Same-node results (retryable_internal / blocked /
    // needs_author_choice, or a completed result on the terminal node) keep the
    // existing attempt id — the host is still working the same stage attempt.
    if (String(draft.current_stage || '') !== previousStage) {
      const sectionIndex = Number((previousStage === 'section_accept'
        && ['section_brief', 'machine_gate'].includes(String(draft.current_stage || ''))
        ? result.next_section
        : result.section_index)
        || ((draft.stage_execution || {}).section_index)
        || draft.current_section_index
        || 0);
      const repairInputDigest = String(result.draft_digest || '');
      if (draft.current_stage === 'section_repair' && !repairInputDigest) {
        throw new Error('section_repair_draft_digest_required');
      }
      draft.stage_execution = {
        status: 'running',
        stage_id: draft.current_stage,
        stage_attempt_id: store.createStageAttemptId(String(draft.workflow_id || ''), String(draft.current_stage || '')),
        ...(Number.isInteger(sectionIndex) && sectionIndex > 0 ? { section_index: sectionIndex } : {}),
        ...(draft.current_stage === 'section_repair' ? { draft_input_digest: repairInputDigest } : {}),
      };
    }
    if (completing) {
      const completedAt = new Date().toISOString();
      draft.status = 'completed';
      draft.completed_at = completedAt;
      draft.lifecycle = { ...(draft.lifecycle || {}), status: 'completed', completed_at: completedAt };
      draft.stage_execution = {
        ...(draft.stage_execution || {}),
        status: 'completed',
        stage_id: previousStage,
        completed_at: completedAt,
      };
    }
    // retry_state is the durable record of consecutive same-family retryable
    // failures on the same stage — task.json is the sole source of truth, so no
    // sidecar file exists. It lands in THIS same single state-version commit as
    // the retryable_internal result. The family comes from the structured
    // failure_family field, falling back to the result code. A retryable result
    // on the same stage AND same family accumulates the count; any other family
    // (or a cold start) resets it to 1. Any NON-retryable result leaves the
    // retry path and clears retry_state, so completed/needs_author_choice/blocked
    // never carry a stale retry budget forward.
    if (String(result.kind || '') === 'retryable_internal') {
      const family = String(result.failure_family || result.code || '');
      const stageId = String(result.stage_id || draft.current_stage || '');
      const previous = draft.retry_state && typeof draft.retry_state === 'object' ? draft.retry_state : null;
      const sameFamily = previous
        && String(previous.stage_id || '') === stageId
        && String(previous.failure_family || '') === family;
      draft.retry_state = {
        stage_id: stageId,
        failure_family: family,
        count: Number((sameFamily ? previous : {}).count || 0) + 1,
      };
    } else {
      delete draft.retry_state;
    }
    if (prepared.pending_action) {
      draft.pending_action = editorialFeedbackDraft
        ? { ...prepared.pending_action, feedback_id: editorialFeedbackDraft.pending_feedback.id }
        : prepared.pending_action;
    } else {
      delete draft.pending_action;
    }
    return draft;
  });

  const visible_response = committed.pending_action
    ? renderCommittedInteraction(committed)
    : null;

  return { task: committed, visible_response };
}

function resolveAuthorInput(projectRoot, workflowId, expectedVersion, input = {}, capability) {
  if (hasWorkflowExecutionCapability(capability, projectRoot)) {
    return resolveAuthorInputUnderLock(projectRoot, workflowId, expectedVersion, input);
  }
  return withWorkflowExecutionLock(projectRoot, 'workflow-v3-resolve-author-input', () => (
    resolveAuthorInputUnderLock(projectRoot, workflowId, expectedVersion, input)
  ));
}

function submitAuthorFeedback(projectRoot, workflowId, expectedVersion, input = {}, capability) {
  if (hasWorkflowExecutionCapability(capability, projectRoot)) {
    return submitAuthorFeedbackUnderLock(projectRoot, workflowId, expectedVersion, input);
  }
  return withWorkflowExecutionLock(projectRoot, 'workflow-v3-submit-author-feedback', () => (
    submitAuthorFeedbackUnderLock(projectRoot, workflowId, expectedVersion, input)
  ));
}

function submitAuthorFeedbackUnderLock(projectRoot, workflowId, expectedVersion, input = {}) {
  const text = typeof input.text === 'string' ? input.text : '';
  if (!text.trim()) throw new Error('author_feedback_text_required');

  let receipt = null;
  const committed = store.commitTask(projectRoot, workflowId, expectedVersion, (draft) => {
    assertNotCompleted(draft);
    const now = new Date().toISOString();
    const targetVersion = Number(draft.state_version || 0) + 1;
    const stageId = String(draft.current_stage || '');
    const sectionIndex = currentSectionIndex(draft);
    const activeFeedback = draft.pending_feedback && typeof draft.pending_feedback === 'object'
      ? draft.pending_feedback
      : null;
    const existing = activeFeedback
      && String(activeFeedback.status || '') === 'pending_analysis'
      ? activeFeedback
      : null;
    const feedbackId = existing && String(existing.id || '')
      ? String(existing.id)
      : `fb-v3-${draft.workflow_id}-${targetVersion}`;
    const messageId = `fbmsg-v3-${draft.workflow_id}-${targetVersion}`;
    const message = {
      id: messageId,
      workflow_id: String(draft.workflow_id || ''),
      stage_id: stageId,
      ...(sectionIndex ? { section_index: sectionIndex } : {}),
      text,
      received_at: now,
    };

    if (draft.pending_action && typeof draft.pending_action === 'object') {
      const history = Array.isArray(draft.interaction_history) ? draft.interaction_history.slice() : [];
      history.push({
        ...JSON.parse(JSON.stringify(draft.pending_action)),
        archived_at: now,
        archive_reason: 'author_feedback_submitted',
      });
      draft.interaction_history = history;
      delete draft.pending_action;
    }
    if (activeFeedback && !existing) {
      const feedbackHistory = Array.isArray(draft.feedback_history) ? draft.feedback_history.slice() : [];
      feedbackHistory.push({
        ...JSON.parse(JSON.stringify(activeFeedback)),
        archived_at: now,
        archive_reason: 'author_feedback_superseded_previous_plan',
      });
      draft.feedback_history = feedbackHistory;
    }

    draft.pending_feedback = {
      ...(existing ? JSON.parse(JSON.stringify(existing)) : {}),
      id: feedbackId,
      status: 'pending_analysis',
      workflow_id: String(draft.workflow_id || ''),
      stage_id: stageId,
      ...(sectionIndex ? { section_index: sectionIndex } : {}),
      received_at: existing && existing.received_at ? existing.received_at : now,
      updated_at: now,
      messages: [
        ...(existing && Array.isArray(existing.messages) ? existing.messages : []),
        message,
      ],
    };
    receipt = {
      status: 'pending_analysis',
      feedback_id: feedbackId,
      message_id: messageId,
      workflow_id: String(draft.workflow_id || ''),
      stage_id: stageId,
      ...(sectionIndex ? { section_index: sectionIndex } : {}),
      state_version: targetVersion,
    };
    return draft;
  });
  return { task: committed, feedback_receipt: receipt };
}

function proposeAuthorFeedbackPlan(projectRoot, workflowId, expectedVersion, input = {}, capability) {
  if (hasWorkflowExecutionCapability(capability, projectRoot)) {
    return proposeAuthorFeedbackPlanUnderLock(projectRoot, workflowId, expectedVersion, input);
  }
  return withWorkflowExecutionLock(projectRoot, 'workflow-v3-propose-author-feedback', () => (
    proposeAuthorFeedbackPlanUnderLock(projectRoot, workflowId, expectedVersion, input)
  ));
}

function proposeAuthorFeedbackPlanUnderLock(projectRoot, workflowId, expectedVersion, input = {}) {
  const feedbackId = String(input.feedback_id || '').trim();
  const summary = String(input.summary || '').trim();
  const impactLevel = String(input.impact_level || '').trim();
  const titleList = normalizeFeedbackSectionTitles(input.section_titles);
  if (!feedbackId) throw new Error('feedback_id_required');
  if (!summary) throw new Error('feedback_plan_summary_required');
  if (!impactLevel) throw new Error('feedback_plan_impact_level_required');
  if (impactLevel === 'needs_analysis') throw new Error('feedback_plan_impact_level_requires_author_classification');
  if (!Array.isArray(input.affected_sections)
      || input.affected_sections.length === 0
      || input.affected_sections.some(value => !Number.isInteger(Number(value)) || Number(value) < 1)) {
    throw new Error('feedback_plan_affected_sections_invalid');
  }
  for (const [field, value] of [['evidence', input.evidence], ['proposed_changes', input.proposed_changes]]) {
    if (!Array.isArray(value) || value.some(item => !String(item || '').trim())) {
      throw new Error(`feedback_plan_${field}_invalid`);
    }
  }
  if (Object.prototype.hasOwnProperty.call(input, 'section_titles') && !titleList) {
    throw new Error('feedback_plan_section_titles_invalid');
  }

  let receipt = null;
  const committed = store.commitTask(projectRoot, workflowId, expectedVersion, (draft) => {
    assertNotCompleted(draft);
    const feedback = draft.pending_feedback;
    if (!feedback || String(feedback.id || '') !== feedbackId) throw new Error('pending_feedback_mismatch');
    if (!['pending_analysis', 'evidence_requested'].includes(String(feedback.status || ''))) {
      throw new Error('pending_feedback_not_proposable');
    }
    if (draft.pending_action && String(draft.pending_action.status || '') === 'pending') {
      throw new Error('pending_action_already_pending');
    }
    if (draft.pending_action) archivePendingAction(draft, 'feedback_plan_replaced');

    const plan = JSON.parse(JSON.stringify(input));
    if (titleList) plan.section_titles = titleList;
    const titleConfirmation = titleList
      ? `\n小节标题变更（作者确认后才会回写）：\n${titleList.map(item => `- 第${item.section_index}节：${item.title || '（无标题）'}`).join('\n')}`
      : '';
    const interaction = prepareInteraction(draft, {
      kind: 'needs_author_choice',
      code: 'confirm_feedback_plan',
      stage_id: String(draft.current_stage || ''),
      question: `建议方案：${summary}${titleConfirmation}\n请选择如何处理。`,
      options: [
        { action_id: 'accept_feedback_plan', label: '采用方案' },
        { action_id: 'continue_feedback_chat', label: '继续讨论' },
        { action_id: 'view_feedback_evidence', label: '查看依据' },
        { action_id: 'pause_feedback', label: '暂停并保存' },
      ],
    });
    draft.pending_feedback = {
      ...JSON.parse(JSON.stringify(feedback)),
      status: 'awaiting_confirmation',
      proposed_plan: plan,
      proposed_at: new Date().toISOString(),
    };
    draft.pending_action = {
      ...interaction.pending_action,
      feedback_id: feedbackId,
    };
    receipt = {
      status: 'awaiting_confirmation',
      feedback_id: feedbackId,
      state_version: Number(draft.state_version || 0) + 1,
    };
    return draft;
  });
  return { task: committed, feedback_receipt: receipt, visible_response: renderCommittedInteraction(committed) };
}

function normalizeFeedbackSectionTitles(value) {
  if (!Array.isArray(value)) return null;
  const rows = value.map(item => ({
    section_index: Number((item || {}).section_index),
    title: String((item || {}).title || '').trim().replace(/\s+/gu, ' '),
  })).sort((left, right) => left.section_index - right.section_index);
  if (!rows.length
      || rows.some((item, index) => !Number.isInteger(item.section_index)
        || item.section_index !== index + 1)
      || new Set(rows.map(item => item.section_index)).size !== rows.length) return null;
  return rows;
}

function archivePendingAction(task, reason) {
  const history = Array.isArray(task.interaction_history) ? task.interaction_history.slice() : [];
  history.push({
    ...JSON.parse(JSON.stringify(task.pending_action)),
    archived_at: new Date().toISOString(),
    archive_reason: reason,
  });
  task.interaction_history = history;
  delete task.pending_action;
}

function currentSectionIndex(task) {
  const candidates = [
    Number(((task || {}).stage_execution || {}).section_index),
    Number((task || {}).current_section_index),
    Number(((task || {}).pending_feedback || {}).section_index),
  ];
  return candidates.find((value) => Number.isInteger(value) && value > 0) || 0;
}

// Planning confirmation is an author decision, not a display-only hop. Bind
// the title list that the approved canonical outline actually contains before
// entering the first Brief. This is intentionally separate from feedback
// planning: a later title change still requires the explicit title list on the
// accepted feedback plan.
function bindConfirmedShortSectionTitles(projectRoot, task) {
  const root = path.resolve(projectRoot || '');
  const state = readShortProjectState(root) || {};
  const outlineRel = safeProjectRelative(state.plan_path || '小节大纲.md');
  const outlineFile = outlineRel ? path.join(root, outlineRel) : '';
  if (!outlineFile || !fs.existsSync(outlineFile) || !fs.statSync(outlineFile).isFile()) {
    throw new Error('planning_confirmation_outline_missing');
  }
  const sections = parseConfirmedOutlineTitles(fs.readFileSync(outlineFile, 'utf8'));
  const plannedSections = Number(state.planned_sections || ((state.narrative || {}).planned_sections) || 0);
  if (!plannedSections || sections.length !== plannedSections
      || sections.some((item, index) => item.section_index !== index + 1)) {
    throw new Error('planning_confirmation_section_titles_invalid');
  }
  const lockRel = resolveShortStateRelative(root, 'section-title-lock.json', { forWrite: true });
  const lockFile = path.join(root, lockRel);
  const sourceDigest = crypto.createHash('sha256').update(fs.readFileSync(outlineFile)).digest('hex');
  atomicWriteJson(lockFile, {
    schema_version: '1.0.0',
    status: 'confirmed',
    workflow_id: String(task.workflow_id || ''),
    project_id: String(state.project_id || ''),
    plan_revision: Number(state.plan_revision || 0),
    planned_sections: plannedSections,
    source_outline: outlineRel,
    source_digest: sourceDigest,
    confirmation_basis: 'planning_confirmation',
    confirmed_at: new Date().toISOString(),
    sections: sections.map((item) => ({
      ...item,
      confirmed: true,
      title_source: 'user_confirmed_outline',
    })),
  });
}

function parseConfirmedOutlineTitles(text) {
  const rows = [];
  for (const line of String(text || '').split(/\r?\n/u)) {
    const match = line.trim().match(/^#{1,6}\s*第\s*([0-9０-９一二三四五六七八九十百千两〇零]+)\s*节(?:\s*[:：·｜-]\s*(.*))?$/u);
    if (!match) continue;
    const sectionIndex = parseShortSectionOrdinal(match[1]);
    if (!Number.isInteger(sectionIndex) || sectionIndex < 1) continue;
    rows.push({ section_index: sectionIndex, title: String(match[2] || '').trim() });
  }
  return rows.sort((left, right) => left.section_index - right.section_index);
}

function advancePlanningConfirmation(projectRoot, task, result) {
  task.current_stage = nextNode(task, result);
  bindConfirmedShortSectionTitles(projectRoot, task);
  const state = readShortProjectState(projectRoot) || {};
  const sectionIndex = Number(state.current_section_index || 1);
  if (!Number.isInteger(sectionIndex) || sectionIndex < 1) {
    throw new Error('planning_confirmation_current_section_invalid');
  }
  task.current_section_index = sectionIndex;
  task.scope = `第${sectionIndex}节`;
  return sectionIndex;
}

function safeProjectRelative(value) {
  const relative = String(value || '').trim().replace(/\\/g, '/').replace(/^\.\//u, '');
  if (!relative || relative.startsWith('/') || relative.split('/').includes('..')) return '';
  return relative;
}

function resolveAuthorInputUnderLock(projectRoot, workflowId, expectedVersion, input = {}) {
  let selection = null;
  const resolvedAt = new Date().toISOString();
  store.commitTask(projectRoot, workflowId, expectedVersion, (draft) => {
    // The version check has already passed atomically inside commitTask, so a
    // replay never reaches here. A completed task is closed: refuse it BEFORE
    // the pending_action check so closure — not pending_action_missing — is the
    // reported reason regardless of which entry point is replayed.
    assertNotCompleted(draft);
    // Now validate the four host-supplied binding fields against the committed
    // pending action before consuming `choice`.
    const pending = draft.pending_action;
    if (!pending) throw new Error('pending_action_missing');
    if (String(input.workflow_id || '') !== String(draft.workflow_id)) {
      throw new Error('binding_workflow_mismatch');
    }
    if (Number(input.state_version) !== Number(draft.state_version)) {
      throw new Error('binding_version_mismatch');
    }
    if (String(input.pending_action_id || '') !== String(pending.id)) {
      throw new Error('binding_pending_action_mismatch');
    }
    if (String(input.visible_choice_hash || '') !== String(pending.visible_choice_hash)) {
      throw new Error('binding_hash_mismatch');
    }
    // Pass only `choice` to the Arbiter, which re-asserts its own committed
    // binding (status pending, workflow/version/hash) before mapping the number.
    selection = consumeBinding(draft, input.choice);
    applyFeedbackDecision(draft, pending, selection, resolvedAt, projectRoot);
    applyPlanningConfirmationDecision(draft, pending, selection, projectRoot);
    // Durable resolution metadata: the frozen selection and a resolve-time
    // timestamp land in task.json so a recovery read can re-establish the
    // settled choice without re-asking the host.
    draft.pending_action = {
      ...draft.pending_action,
      status: 'resolved',
      selection,
      resolved_at: resolvedAt,
    };
    return draft;
  });
  return selection;
}

function applyPlanningConfirmationDecision(task, pending, selection, projectRoot) {
  if (String(task.current_stage || '') !== 'planning_confirmation'
      || !Array.isArray((pending || {}).options)
      || !pending.options.some((option) => String((option || {}).action_id || '') === 'accept_planning')) return;
  const actionId = String((selection || {}).action_id || '');
  if (actionId === 'accept_planning') {
    const sectionIndex = advancePlanningConfirmation(projectRoot, task, {
      kind: 'completed',
      code: 'planning_confirmed',
      stage_id: 'planning_confirmation',
    });
    task.stage_execution = {
      status: 'running',
      stage_id: task.current_stage,
      stage_attempt_id: store.createStageAttemptId(String(task.workflow_id || ''), task.current_stage),
      section_index: sectionIndex,
    };
    return;
  }
  if (actionId === 'modify_planning_in_chat') return;
  throw new Error('planning_confirmation_action_invalid');
}

function applyFeedbackDecision(task, pending, selection, decidedAt, projectRoot) {
  const feedbackId = String((pending || {}).feedback_id || '');
  if (!feedbackId) return;
  const feedback = task.pending_feedback;
  if (!feedback || String(feedback.id || '') !== feedbackId) throw new Error('pending_feedback_mismatch');
  const actionId = String((selection || {}).action_id || '');
  const next = {
    ...JSON.parse(JSON.stringify(feedback)),
    decision: { ...selection, decided_at: decidedAt },
  };
  if (actionId === 'accept_feedback_plan') {
    next.status = 'accepted';
    next.accepted_plan = buildAcceptedFeedbackPlan(task, feedback, decidedAt, projectRoot);
    next.accepted_at = decidedAt;
    task.accepted_plan = JSON.parse(JSON.stringify(next.accepted_plan));
    const firstAffected = Number(next.accepted_plan.affected_sections[0] || 0);
    if (firstAffected > 0 && isSectionRevisionStage(task.current_stage)) {
      next.interrupted_stage = String(task.current_stage || '');
      const planningAssets = Array.isArray(((next.accepted_plan || {}).projection_plan || {}).planning_assets)
        ? next.accepted_plan.projection_plan.planning_assets.map(String).filter(Boolean)
        : [];
      task.current_stage = planningAssets.length ? 'feedback_apply_patch' : 'section_brief';
      task.current_section_index = firstAffected;
      task.scope = `第${firstAffected}节`;
      task.stage_execution = {
        status: 'running',
        stage_id: task.current_stage,
        stage_attempt_id: store.createStageAttemptId(String(task.workflow_id || ''), task.current_stage),
        section_index: firstAffected,
      };
    }
  } else if (actionId === 'continue_feedback_chat') {
    next.status = 'pending_analysis';
  } else if (actionId === 'view_feedback_evidence') {
    next.status = 'evidence_requested';
  } else if (actionId === 'pause_feedback') {
    next.status = 'paused';
  } else {
    throw new Error('feedback_decision_action_invalid');
  }
  task.pending_feedback = next;
}

function markAcceptedFeedbackApplied(task, result) {
  const feedback = task.pending_feedback;
  if (!feedback || String(feedback.status || '') !== 'accepted') return;
  const sectionIndex = Number(result.section_index || currentSectionIndex(task) || 0);
  const affected = Array.isArray(((feedback || {}).accepted_plan || {}).affected_sections)
    ? feedback.accepted_plan.affected_sections.map(Number)
    : [];
  if (affected.length > 0 && sectionIndex > 0 && !affected.includes(sectionIndex)) return;
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  if (queue
      && String(queue.feedback_id || '') === String(feedback.id || feedback.feedback_id || '')
      && String(queue.status || '') !== 'completed') return;
  task.pending_feedback = {
    ...JSON.parse(JSON.stringify(feedback)),
    status: 'applied',
    applied_at: new Date().toISOString(),
    ...(sectionIndex > 0 ? { applied_section_index: sectionIndex } : {}),
  };
}

function buildAcceptedFeedbackPlan(task, feedback, acceptedAt, projectRoot) {
  const proposed = feedback.proposed_plan && typeof feedback.proposed_plan === 'object'
    ? feedback.proposed_plan
    : {};
  const feedbackId = String(feedback.id || feedback.feedback_id || '');
  const impactLevel = String(proposed.impact_level || '');
  const affectedSections = [...new Set((Array.isArray(proposed.affected_sections) ? proposed.affected_sections : [])
    .map(Number)
    .filter(value => Number.isInteger(value) && value > 0))].sort((a, b) => a - b);
  const planningAssets = impactLevel === 'structure'
    ? ['设定.md', '小节大纲.md']
    : impactLevel.includes('planning') ? ['小节大纲.md'] : [];
  const proposalId = String(proposed.proposal_id || `proposal-v3.${feedbackId}`);
  const sourceBefore = planningAssets.map(relative => ({
    path: relative,
    sha256: digestProjectFile(projectRoot, relative),
  }));
  return {
    schema_version: '1.0.0',
    ...JSON.parse(JSON.stringify(proposed)),
    plan_id: String(proposed.plan_id || `accepted-plan.${feedbackId}`),
    proposal_id: proposalId,
    feedback_id: feedbackId,
    workflow_id: String(task.workflow_id || ''),
    status: 'accepted_pending_projection',
    projection_status: 'pending',
    requirements: (Array.isArray(proposed.proposed_changes) ? proposed.proposed_changes : [])
      .map((text, index) => ({
        requirement_id: `${proposalId}.requirement-${index + 1}`,
        text: String(text || '').trim(),
        impact_level: impactLevel,
      }))
      .filter(item => item.text),
    affected_sections: affectedSections,
    projection_plan: {
      planning_assets: planningAssets,
      source_before: sourceBefore,
      invalidate_briefs: affectedSections.map(index => `写作Brief_第${String(index).padStart(3, '0')}节.md`),
      recheck_prose: affectedSections.map(index => `正文/第${String(index).padStart(3, '0')}节.md`),
      order: ['planning_assets', 'briefs', 'prose_recheck', 'memory_projection'],
    },
    acceptance: {
      kind: 'explicit_user_confirmation',
      accepted_at: acceptedAt,
    },
    accepted_at: acceptedAt,
  };
}

function isSectionRevisionStage(stageId) {
  return [
    'planning_confirmation',
    'section_brief', 'section_draft', 'machine_gate', 'story_gate',
    'section_repair', 'section_accept', 'assembly', 'editorial_review',
    'deslop', 'final_check',
  ].includes(String(stageId || ''));
}

function projectAcceptedV3FeedbackPlan(projectRoot, task, result) {
  const feedback = task.pending_feedback && typeof task.pending_feedback === 'object'
    ? task.pending_feedback
    : null;
  if (!feedback || String(feedback.status || '') !== 'accepted') return;
  const accepted = task.accepted_plan && typeof task.accepted_plan === 'object'
    ? task.accepted_plan
    : feedback.accepted_plan;
  if (!accepted || typeof accepted !== 'object') return;
  // A planning patch projects accepted feedback before it advances to
  // section_brief. Do not try to project it again when the new Brief completes:
  // that result deliberately contains Brief evidence, not the planning
  // transaction receipt. Current-brief feedback stays pending until its Brief
  // result reaches this function.
  if (String(accepted.projection_status || '') === 'completed') return;
  const impactLevel = String(accepted.impact_level || '');
  const normalizedImpact = impactLevel === 'current_brief'
    ? 'current_brief'
    : impactLevel === 'structure' ? 'structure' : impactLevel.includes('planning') ? 'planning' : 'current_brief';
  const planningAssets = Array.isArray(((accepted || {}).projection_plan || {}).planning_assets)
    ? accepted.projection_plan.planning_assets
    : [];
  const sourceBefore = Array.isArray(((accepted || {}).projection_plan || {}).source_before)
    ? accepted.projection_plan.source_before
    : [];
  if (planningAssets.length) {
    const transaction = result.planning_transaction && typeof result.planning_transaction === 'object'
      ? result.planning_transaction
      : null;
    const transactionAssets = Array.isArray((transaction || {}).artifacts) ? transaction.artifacts : [];
    const byCanonical = new Map(transactionAssets.map(item => [String((item || {}).canonical || ''), item || {}]));
    if (!transaction || planningAssets.some(relative => !byCanonical.has(String(relative)))) {
      throw new Error('blocked_planning_transaction_evidence_missing');
    }
    const beforeByPath = new Map(sourceBefore.map(item => [String((item || {}).path || ''), String((item || {}).sha256 || '')]));
    const planningChanged = planningAssets.every(relative => {
      const canonical = String(relative || '');
      const artifact = byCanonical.get(canonical) || {};
      const after = digestProjectFile(projectRoot, canonical);
      return after
        && after === String(artifact.after_sha256 || '')
        && after !== String(beforeByPath.get(canonical) || '');
    });
    if (!planningChanged) throw new Error('blocked_planning_memory_evidence_missing');
  }
  const projectionResult = {
    stage_id: 'feedback_apply_patch',
    step_status: 'completed',
    impact_level: normalizedImpact,
    feedback_id: String(feedback.id || feedback.feedback_id || ''),
    affected_sections: Array.isArray(accepted.affected_sections) ? accepted.affected_sections : [],
    changed_files: planningAssets,
    downstream_impact: {
      invalidate_briefs: Array.isArray(((accepted || {}).projection_plan || {}).invalidate_briefs)
        ? accepted.projection_plan.invalidate_briefs
        : [],
      recheck_prose: Array.isArray(((accepted || {}).projection_plan || {}).recheck_prose)
        ? accepted.projection_plan.recheck_prose
        : [],
    },
    result_packet_path: String(result.result_packet_path || ''),
  };
  const projected = projectAcceptedShortPlanningFeedback(projectRoot, task, projectionResult);
  if (String(projected.status || '').startsWith('blocked_')) {
    throw new Error(projected.status);
  }
  const queued = initializeShortFeedbackRevisionQueue(task, projectionResult, {
    impact_level: normalizedImpact,
    affected_sections: projectionResult.affected_sections,
  });
  if (String(queued.status || '').startsWith('blocked_')) {
    throw new Error(queued.status);
  }
  if (task.accepted_plan && task.pending_feedback) {
    task.pending_feedback.accepted_plan = JSON.parse(JSON.stringify(task.accepted_plan));
  }
}

function digestProjectFile(projectRoot, relative) {
  const root = path.resolve(String(projectRoot || ''));
  const file = path.resolve(root, String(relative || ''));
  if (!file.startsWith(`${root}${path.sep}`) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return '';
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function assertStageMatch(stageId, currentStage) {
  if (stageId !== String(currentStage || '')) {
    throw new Error('stage_mismatch');
  }
}

// Terminal-closure guard. A completed task (status completed OR lifecycle
// status completed — both are stamped together by the terminal commit) is
// final: no further applyStageResult or resolveAuthorInput may mutate it. Any
// attempt throws workflow_already_completed before any write. Task 3 still
// stamps neither field at creation, so a fresh task (both undefined) is open.
function assertNotCompleted(task) {
  if (String((task || {}).status || '') === 'completed'
    || String(((task || {}).lifecycle || {}).status || '') === 'completed') {
    throw new Error('workflow_already_completed');
  }
}

function assertAcceptedFeedbackComplete(task) {
  const feedback = task && task.pending_feedback && typeof task.pending_feedback === 'object'
    ? task.pending_feedback
    : null;
  const acceptedPlan = task && task.accepted_plan && typeof task.accepted_plan === 'object'
    ? task.accepted_plan
    : null;
  const queue = task && task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  if ((feedback && String(feedback.status || '') === 'accepted')
    || (acceptedPlan && String(acceptedPlan.projection_status || '') === 'pending')
    || (queue && String(queue.status || '') !== 'completed')) {
    throw new Error('accepted_feedback_incomplete');
  }
}

module.exports = {
  createTask,
  createTaskWithInitialInteraction,
  readTask,
  applyStageResult,
  resolveAuthorInput,
  submitAuthorFeedback,
  proposeAuthorFeedbackPlan,
};
