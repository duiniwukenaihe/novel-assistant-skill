'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { validateShortSectionAcceptanceProof } = require('./short-section-acceptance-proof');
const { resolveShortAnchorNext, resolveShortQualityNext } = require('./short-section-acceptance-policy');
const { activeShortFeedbackRevision } = require('./short-feedback-revision-queue');

function validateDetailOutlineQualityResult(result, task, projectRoot = '') {
  if (!task || String(task.workflow_type || '') !== 'long_write' || String(task.current_stage || '') !== 'detail_outline_review') {
    return { status: 'not_applicable', code: '' };
  }

  const quality = result && result.outputs && result.outputs.detail_outline_quality;
  const code = 'detail_outline_quality_identity_missing';
  if (!quality || typeof quality !== 'object' || Array.isArray(quality)) return { status: 'identity_missing', code };

  const outlinePath = String(quality.outline_path || '');
  const outlineSha256 = String(quality.outline_sha256 || '');
  const sameWorkflow = String(quality.workflow_id || '') === String(task.workflow_id || '');
  const sameStage = String(quality.stage_id || '') === 'detail_outline_review';
  const safeRelativePath = outlinePath
    && !outlinePath.startsWith('/')
    && !outlinePath.split(/[\\/]/).includes('..');
  const validHash = /^[0-9a-f]{64}$/.test(outlineSha256);
  const evidenceMatches = Array.isArray(result.evidence) && result.evidence.some((item) => item
    && String(item.type || '') === 'detail_outline'
    && String(item.path || '') === outlinePath
    && String(item.outline_sha256 || '') === outlineSha256);
  if (!safeRelativePath) {
    return { status: 'invalid', code: 'detail_outline_quality_outline_path_unsafe' };
  }
  if (!sameWorkflow || !sameStage || !validHash || !evidenceMatches) {
    return { status: 'identity_missing', code };
  }

  const outlineIdentity = validateCurrentOutlineIdentity(task, outlinePath, outlineSha256, projectRoot);
  if (outlineIdentity) return outlineIdentity;

  const semanticReview = (((quality.execution || {}).semantic_review) || {});
  const semanticFindings = Array.isArray(semanticReview.findings) ? semanticReview.findings : null;
  if (semanticReview.status !== 'accepted'
    || !String(semanticReview.reviewer || '').trim()
    || !semanticFindings
    || !/^[0-9a-f]{64}$/.test(String(semanticReview.findings_sha256 || ''))
    || !Number.isInteger(semanticReview.finding_count)
    || semanticReview.finding_count < 0) {
    return { status: 'invalid', code: 'detail_outline_quality_semantic_review_required' };
  }
  const semanticFindingsSha256 = crypto.createHash('sha256')
    .update(JSON.stringify(semanticFindings), 'utf8')
    .digest('hex');
  const qualityFindingKeys = new Set((Array.isArray(quality.findings) ? quality.findings : [])
    .map((finding) => JSON.stringify(finding)));
  if (semanticReview.finding_count !== semanticFindings.length
    || semanticReview.findings_sha256 !== semanticFindingsSha256
    || semanticFindings.some((finding) => !qualityFindingKeys.has(JSON.stringify(finding)))) {
    return { status: 'invalid', code: 'detail_outline_quality_semantic_review_integrity_mismatch' };
  }
  const activatedDimensions = new Set(Array.isArray(quality.activated_dimensions) ? quality.activated_dimensions : []);
  const hasUnactivatedConditionalFinding = semanticFindings.some((finding) => {
    const dimension = String((finding || {}).dimension || '');
    return /^C[1-7]_/.test(dimension) && !activatedDimensions.has(dimension);
  });
  if (hasUnactivatedConditionalFinding) {
    return { status: 'invalid', code: 'detail_outline_quality_semantic_dimension_not_activated' };
  }

  const qualityStatus = String(quality.status || '');
  if (qualityStatus !== 'outline_underfilled') {
    const findings = Array.isArray(quality.findings) ? quality.findings : [];
    const expectedStatus = findings.some((finding) => String((finding || {}).severity || '') === 'blocking')
      ? 'revise'
      : findings.length > 0 ? 'pass_with_advisory' : 'pass';
    if (qualityStatus !== expectedStatus) {
      return { status: 'invalid', code: 'detail_outline_quality_status_findings_mismatch' };
    }
  }
  const projection = quality.contract_projection;
  const hasProjection = Array.isArray(projection) ? projection.length > 0 : Boolean(projection);
  if (qualityStatus === 'outline_underfilled' && hasProjection) {
    return { status: 'invalid', code: 'detail_outline_underfilled_projection_forbidden' };
  }
  if (qualityStatus === 'revise' || qualityStatus === 'outline_underfilled') {
    return { status: 'review_failed', code: 'detail_outline_quality_review_failed' };
  }
  if (qualityStatus === 'pass' || qualityStatus === 'pass_with_advisory') {
    return { status: 'accepted', code: '' };
  }
  return { status: 'invalid', code: 'detail_outline_quality_status_invalid' };
}

function validateCurrentOutlineIdentity(task, outlinePath, outlineSha256, projectRoot = '') {
  let root;
  try {
    root = fs.realpathSync(String(projectRoot || task.book_root || ''));
  } catch (_) {
    return { status: 'invalid', code: 'detail_outline_quality_project_root_missing' };
  }
  const candidate = path.resolve(root, outlinePath);
  if (candidate === root || !candidate.startsWith(`${root}${path.sep}`)) {
    return { status: 'invalid', code: 'detail_outline_quality_outline_path_unsafe' };
  }
  let outlineFile;
  try {
    outlineFile = fs.realpathSync(candidate);
  } catch (_) {
    return { status: 'invalid', code: 'detail_outline_quality_outline_missing' };
  }
  if (outlineFile === root || !outlineFile.startsWith(`${root}${path.sep}`)) {
    return { status: 'invalid', code: 'detail_outline_quality_outline_path_unsafe' };
  }
  try {
    if (!fs.statSync(outlineFile).isFile()) return { status: 'invalid', code: 'detail_outline_quality_outline_missing' };
    const actual = crypto.createHash('sha256').update(fs.readFileSync(outlineFile)).digest('hex');
    if (actual !== outlineSha256) return { status: 'invalid', code: 'detail_outline_quality_outline_sha256_mismatch' };
  } catch (_) {
    return { status: 'invalid', code: 'detail_outline_quality_outline_missing' };
  }
  return null;
}

function validateLifecycleTransitionRequest(stageDef = {}, currentStage = '', result = {}) {
  const request = result.lifecycle_transition_request;
  if (!request || typeof request !== 'object' || Array.isArray(request)) {
    return { status: 'invalid', code: 'lifecycle_transition_request_missing', requested_next: '' };
  }
  const action = String(request.action || '').trim().toLowerCase();
  const target = String(request.target || '').trim();
  const allowedNext = Array.isArray(stageDef.allowed_next) ? stageDef.allowed_next.map(String) : [];
  const failureReturn = String((((stageDef || {}).review_requirement || {}).failure_return) || '');
  const blocked = transitionResultIsBlocked(result);
  const explicitNext = String(result.next_stage_id || result.next_stage || result.target_stage || '').trim();

  if (!['advance', 'return', 'stay', 'pause'].includes(action)) {
    return { status: 'invalid', code: 'lifecycle_transition_action_invalid', action, target, requested_next: '' };
  }
  if (action === 'advance') {
    if (blocked) return { status: 'invalid', code: 'blocked_result_cannot_advance', action, target, requested_next: '' };
    const requestedNext = !target || target === currentStage ? '' : target;
    if (requestedNext && !allowedNext.includes(requestedNext)) {
      return { status: 'invalid', code: 'lifecycle_transition_target_not_allowed', action, target, allowed_next: allowedNext, requested_next: '' };
    }
    if (explicitNext && requestedNext && explicitNext !== requestedNext) {
      return { status: 'invalid', code: 'lifecycle_transition_target_conflict', action, target, explicit_next: explicitNext, requested_next: '' };
    }
    return { status: 'valid', code: '', action, target, requested_next: requestedNext || explicitNext };
  }
  if (action === 'return') {
    if (!blocked || !failureReturn || target !== failureReturn) {
      return { status: 'invalid', code: 'lifecycle_transition_return_invalid', action, target, failure_return: failureReturn, requested_next: '' };
    }
    return { status: 'valid', code: '', action, target, requested_next: failureReturn };
  }
  if (!blocked || (target && target !== currentStage)) {
    return { status: 'invalid', code: 'lifecycle_transition_stay_invalid', action, target, requested_next: '' };
  }
  return { status: 'valid', code: '', action, target: target || currentStage, requested_next: currentStage };
}

function transitionResultIsBlocked(result = {}) {
  if (['blocked', 'failed'].includes(String(result.step_status || '').toLowerCase())) return true;
  for (const field of ['blocking_findings', 'blockingFindings', 'hard_blockers', 'hardBlockers']) {
    if (Array.isArray(result[field]) && result[field].length > 0) return true;
  }
  return ['verification_result', 'output_health_result', 'machine_gate_result', 'gate_result']
    .some((field) => /(blocking|blocked|fail|failed|reject|rejected|hard_blocker|error)/.test(String(result[field] || '').toLowerCase()));
}

// Pure stage-transition rules. The state-machine facade owns validation and
// persistence; this module only decides the next lifecycle state.
function createWorkflowTransitionService(deps) {
  const {
    findStage,
    currentUnitRole,
    unitLifecycle,
    validateLifecycleTransition,
  } = deps;

  function normalizeBlockingFindings(result) {
    const values = [];
    for (const field of ['blocking_findings', 'blockingFindings', 'hard_blockers', 'hardBlockers']) {
      if (Array.isArray(result[field])) values.push(...result[field]);
    }
    return values.filter(Boolean);
  }

  function resultHasBlocking(result) {
    const status = String(result.step_status || '').toLowerCase();
    if (['blocked', 'failed'].includes(status)) return true;
    if (normalizeBlockingFindings(result).length > 0) return true;
    for (const field of ['verification_result', 'output_health_result', 'machine_gate_result', 'gate_result']) {
      const value = String(result[field] || '').toLowerCase();
      if (/(blocking|blocked|fail|failed|reject|rejected|hard_blocker|error)/.test(value)) return true;
    }
    return false;
  }

  function machineGateResultIsAmbiguous(result) {
    if (!result) return true;
    if (['blocked', 'failed'].includes(String(result.step_status || '').toLowerCase())) return false;
    if (normalizeBlockingFindings(result).length > 0) return false;
    return !['verification_result', 'output_health_result', 'machine_gate_result', 'gate_result']
      .some((field) => String(result[field] || '').trim());
  }

  function nextLinearStage(ordered, stageId, completedStages, skipStageIds) {
    const index = ordered.indexOf(stageId);
    if (index < 0) return '';
    const completed = new Set(completedStages || []);
    const skip = new Set(skipStageIds || []);
    return ordered.slice(index + 1).find((item) => !completed.has(item) && !skip.has(item)) || '';
  }

  function buildRemainingForNext(tpl, stageId, nextStageId, completedStages, skipStageIds) {
    if (!tpl || !nextStageId) return [];
    const ordered = tpl.stages.map((item) => item.stage_id);
    const nextIndex = ordered.indexOf(nextStageId);
    if (nextIndex < 0) return [];
    const completed = new Set([...(completedStages || []), stageId]);
    const skip = new Set(skipStageIds || []);
    return ordered.slice(nextIndex).filter((item) => item === nextStageId || (!completed.has(item) && !skip.has(item)));
  }

  function buildMachineGateBlockingRemaining(tpl, machineGateStageId, repairStageId, completedStages) {
    if (!tpl || !repairStageId) return [];
    const ordered = tpl.stages.map((item) => item.stage_id);
    const gateIndex = ordered.indexOf(machineGateStageId);
    const completed = new Set(completedStages || []);
    const tail = gateIndex >= 0 ? ordered.slice(gateIndex + 1).filter((item) => item !== repairStageId && !completed.has(item)) : [];
    return Array.from(new Set([repairStageId, machineGateStageId, ...tail]));
  }

  function buildRepairLoopRemaining(tpl, repairStageId, nextStageId, completedStages) {
    if (!tpl || !nextStageId) return [];
    const ordered = tpl.stages.map((item) => item.stage_id);
    const nextIndex = ordered.indexOf(nextStageId);
    if (nextIndex < 0) return [];
    const completed = new Set([...(completedStages || []), repairStageId]);
    return ordered.slice(nextIndex).filter((item) => item === nextStageId || (item !== repairStageId && !completed.has(item)));
  }

  function validateLongformLifecycleTransition(stageDef, from, to, requestedRule) {
    const baseValidation = validateLifecycleTransition(from, to);
    if (baseValidation.allowed) return { ...baseValidation, rule: 'canonical_lifecycle_transition' };
    const requirement = (stageDef || {}).review_requirement || {};
    const allowedReviewRollback = requestedRule === 'required_review_failure_return'
      && requirement.required === true
      && String(requirement.failure_return || '') === String(to || '');
    return {
      allowed: allowedReviewRollback,
      from,
      to,
      rule: allowedReviewRollback ? 'required_review_failure_return' : 'rejected_lifecycle_transition',
      base_validation: baseValidation,
    };
  }

  function resolveLongformLifecycleTransition(tpl, machine, stageDef, stageId, explicitNext, blocked) {
    const ordered = tpl.stages.map((item) => item.stage_id);
    const allowed = stageDef && Array.isArray(stageDef.allowed_next) ? stageDef.allowed_next : [];
    const failureReturn = String((((stageDef || {}).review_requirement || {}).failure_return) || '');

    if (blocked && failureReturn) {
      const validation = validateLongformLifecycleTransition(stageDef, stageId, failureReturn, 'required_review_failure_return');
      if (!validation.allowed) {
        return {
          next_stage_id: stageId,
          complete_current_stage: false,
          remaining_stages: buildRemainingForNext(tpl, stageId, stageId, machine.completed_stages || [], []),
          blocked: true,
          reason: 'lifecycle_transition_invalid',
          lifecycle_validation: validation,
        };
      }
      const rollbackIndex = ordered.indexOf(failureReturn);
      const invalidatedNodes = rollbackIndex >= 0 ? ordered.slice(rollbackIndex) : [failureReturn];
      return {
        next_stage_id: failureReturn,
        complete_current_stage: false,
        remaining_stages: invalidatedNodes.slice(),
        invalidated_nodes: invalidatedNodes,
        blocked: true,
        reason: 'review_failed_return_to_asset',
        lifecycle_validation: validation,
      };
    }

    if (blocked) {
      const validation = validateLifecycleTransition(stageId, stageId);
      return {
        next_stage_id: stageId,
        complete_current_stage: false,
        remaining_stages: buildRemainingForNext(tpl, stageId, stageId, machine.completed_stages || [], []),
        blocked: true,
        reason: 'lifecycle_node_blocked',
        lifecycle_validation: validation,
      };
    }

    const nextStageId = explicitNext || nextLinearStage(ordered, stageId, machine.completed_stages || [], []);
    const validation = validateLongformLifecycleTransition(stageDef, stageId, nextStageId, 'declared_lifecycle_transition');
    const isTerminal = !nextStageId && stageId === ordered[ordered.length - 1];
    const allowedByTemplate = !nextStageId || allowed.includes(nextStageId);
    if ((!validation.allowed || !allowedByTemplate) && !isTerminal) {
      return {
        next_stage_id: stageId,
        complete_current_stage: false,
        remaining_stages: buildRemainingForNext(tpl, stageId, stageId, machine.completed_stages || [], []),
        blocked: true,
        reason: 'lifecycle_transition_invalid',
        lifecycle_validation: validation,
      };
    }

    const currentIndex = ordered.indexOf(stageId);
    const nextIndex = ordered.indexOf(nextStageId);
    const isLifecycleLoop = validation.allowed && nextIndex >= 0 && nextIndex <= currentIndex;
    if (isLifecycleLoop) {
      const invalidatedNodes = ordered.slice(nextIndex, currentIndex + 1);
      return {
        next_stage_id: nextStageId,
        complete_current_stage: true,
        remaining_stages: ordered.slice(nextIndex),
        invalidated_nodes: invalidatedNodes,
        blocked: false,
        reason: 'lifecycle_loop_started',
        lifecycle_validation: validation,
      };
    }

    return {
      next_stage_id: nextStageId,
      complete_current_stage: true,
      remaining_stages: buildRemainingForNext(tpl, stageId, nextStageId, machine.completed_stages || [], []),
      blocked: false,
      reason: nextStageId ? 'lifecycle_node_completed' : 'workflow_completed',
      lifecycle_validation: validation,
    };
  }

  function resolveStageTransition(tpl, machine, stageId, result, task, projectRoot = '') {
    const stageDef = findStage(tpl, stageId);
    const contract = (tpl && tpl.unit_lifecycle_contract) || unitLifecycle('workflow_batch', {});
    const ordered = tpl ? tpl.stages.map((item) => item.stage_id) : [];
    const allowed = stageDef && Array.isArray(stageDef.allowed_next) ? stageDef.allowed_next.slice() : [];
    const explicitNext = String(result.next_stage_id || result.next_stage || result.target_stage || '');
    const role = currentUnitRole(contract, stageId);
    const isMachineGate = role === 'machine_quality_gate' || /(^|_)machine_gate$/.test(stageId);
    const detailOutlineQuality = validateDetailOutlineQualityResult(result, task, projectRoot);
    const blocked = resultHasBlocking(result);

    // Defense-in-depth: if the resolved template no longer contains the stage
    // the task is trying to advance from (e.g. a degraded/missing registry or
    // a mismatched template), refuse to fabricate a linear next stage. The
    // primary guard is resolveTemplateForTask in applyResult; this catches the
    // same class of problem at the transition layer for any caller.
    if (!tpl || (!stageDef && !ordered.includes(stageId) && !explicitNext)) {
      return {
        next_stage_id: stageId,
        complete_current_stage: false,
        remaining_stages: [],
        blocked: true,
        reason: 'blocked_workflow_stage_transition_invalid',
      };
    }

    if (tpl && tpl.workflow_type === 'long_write') {
      if (detailOutlineQuality.status === 'identity_missing' || detailOutlineQuality.status === 'invalid') {
        return {
          next_stage_id: stageId,
          complete_current_stage: false,
          remaining_stages: buildRemainingForNext(tpl, stageId, stageId, machine.completed_stages || [], []),
          blocked: true,
          reason: detailOutlineQuality.code,
        };
      }
      if (detailOutlineQuality.status === 'review_failed') {
        return resolveLongformLifecycleTransition(tpl, machine, stageDef, stageId, explicitNext, true);
      }
      return resolveLongformLifecycleTransition(tpl, machine, stageDef, stageId, explicitNext, blocked);
    }

    const shortQualityNext = ['short_write', 'short_startup', 'private_short_startup'].includes(String((tpl || {}).workflow_type || ''))
      ? resolveShortQualityNext({ stageId, result, allowedNext: allowed })
      : '';
    if (!explicitNext && shortQualityNext) {
      return {
        next_stage_id: shortQualityNext,
        complete_current_stage: true,
        remaining_stages: buildRemainingForNext(tpl, stageId, shortQualityNext, machine.completed_stages || [], []),
        blocked: false,
        reason: shortQualityNext === 'section_candidate_compare' ? 'short_quality_requires_comparison' : 'short_quality_single_candidate_ready',
      };
    }

    if (!explicitNext && ['short_write', 'short_startup', 'private_short_startup'].includes(String((tpl || {}).workflow_type || ''))
      && stageId === 'section_accept_anchor' && !blocked) {
      if (!result.section_acceptance || typeof result.section_acceptance !== 'object') {
        return {
          next_stage_id: stageId,
          complete_current_stage: false,
          remaining_stages: buildRemainingForNext(tpl, stageId, stageId, machine.completed_stages || [], []),
          blocked: true,
          reason: 'short_section_acceptance_proof_missing',
        };
      }
      const acceptanceProof = validateShortSectionAcceptanceProof({
        projectRoot: projectRoot || (task || {}).book_root
          || ((((task || {}).runtime_guard || {}).checkpoint_policy || {}).project_root),
        workflowId: (task || {}).workflow_id,
        proof: result.section_acceptance,
        requireCommit: Number((task || {}).result_contract_version || 1) >= 2,
      });
      if (acceptanceProof.status !== 'accepted') {
        return {
          next_stage_id: stageId,
          complete_current_stage: false,
          remaining_stages: buildRemainingForNext(tpl, stageId, stageId, machine.completed_stages || [], []),
          blocked: true,
          reason: acceptanceProof.code || 'short_section_acceptance_proof_invalid',
        };
      }
      const shortAnchorNext = resolveShortAnchorNext({ result, allowedNext: allowed });
      const revisionQueue = task ? task.feedback_revision_queue : null;
      const revisionActive = activeShortFeedbackRevision(task || {});
      const revisionCompleted = revisionQueue && String(revisionQueue.status || '') === 'completed';
      const resolvedAnchorNext = revisionActive
        ? 'next_section_brief'
        : revisionCompleted ? 'full_story_assembly' : shortAnchorNext;
      return {
        next_stage_id: resolvedAnchorNext,
        complete_current_stage: true,
        remaining_stages: buildRemainingForNext(tpl, stageId, resolvedAnchorNext, machine.completed_stages || [], []),
        blocked: false,
        reason: revisionCompleted
          ? 'short_feedback_revision_completed'
          : revisionActive ? 'short_feedback_revision_next_section' : shortAnchorNext === 'full_story_assembly' ? 'short_story_sections_completed' : 'short_section_accepted_next_brief',
      };
    }

    if (explicitNext) {
      const nextStageId = allowed.includes(explicitNext) ? explicitNext : '';
      if (!nextStageId) {
        return {
          next_stage_id: stageId,
          complete_current_stage: false,
          remaining_stages: buildRemainingForNext(tpl, stageId, stageId, machine.completed_stages || [], []),
          blocked: true,
          reason: 'explicit_next_stage_invalid',
        };
      }
      return {
        next_stage_id: nextStageId,
        complete_current_stage: !blocked && String(result.step_status || '') !== 'blocked',
        remaining_stages: buildRemainingForNext(tpl, stageId, nextStageId, machine.completed_stages || [], []),
        blocked,
        reason: 'explicit_next_stage',
      };
    }

    if (isMachineGate && blocked) {
      const repairStageId = allowed.find((item) => /repair|fix|修/.test(item)) || allowed[0] || stageId;
      return {
        next_stage_id: repairStageId,
        complete_current_stage: false,
        remaining_stages: buildMachineGateBlockingRemaining(tpl, stageId, repairStageId, machine.completed_stages || []),
        blocked: true,
        reason: 'machine_gate_blocked_current_unit',
      };
    }

    if (isMachineGate) {
      const skipRepair = allowed.filter((item) => /repair|fix|修/.test(item));
      const nextStageId = allowed.find((item) => currentUnitRole(contract, item) === 'quality_gate')
        || allowed.find((item) => !skipRepair.includes(item))
        || nextLinearStage(ordered, stageId, machine.completed_stages || [], skipRepair);
      return {
        next_stage_id: nextStageId,
        complete_current_stage: true,
        remaining_stages: buildRemainingForNext(tpl, stageId, nextStageId, machine.completed_stages || [], skipRepair),
        blocked: false,
        reason: 'machine_gate_passed',
      };
    }

    if (/repair_loop$/.test(stageId) && allowed.length > 0) {
      const nextStageId = allowed[0];
      return {
        next_stage_id: nextStageId,
        complete_current_stage: !blocked,
        remaining_stages: buildRepairLoopRemaining(tpl, stageId, nextStageId, machine.completed_stages || []),
        blocked,
        reason: 'repair_loop_completed_rescan',
      };
    }

    // Default linear-successor branch. Most stages advance to the next
    // non-completed stage in registry order. But a "loop" draft stage such as
    // draft_next_section / draft_section writes one section and must return to
    // the machine gate, which sits EARLIER in the registry order — so linear
    // scan either skips it (finds a later stage like full_story_assembly) or
    // returns empty. When the linear successor is not in the stage's declared
    // allowed_next, honor the declared allowed_next[0] instead. This keeps
    // existing forward-linear behavior untouched (linear successor that IS
    // declared) while fixing the runaway routing loop.
    const linearNext = nextLinearStage(ordered, stageId, machine.completed_stages || [], []);
    const linearHonorsAllowed = linearNext && allowed.includes(linearNext);
    const nextStageId = linearHonorsAllowed
      ? linearNext
      : (allowed.length > 0 ? allowed[0] : linearNext);
    return {
      next_stage_id: nextStageId,
      complete_current_stage: !blocked,
      remaining_stages: buildRemainingForNext(tpl, stageId, nextStageId, machine.completed_stages || [], []),
      blocked,
      reason: nextStageId
        ? (blocked
          ? (linearHonorsAllowed ? 'stage_blocked_linear' : 'stage_blocked_at_declared_loop')
          : (linearHonorsAllowed ? 'stage_completed' : 'stage_completed_declared_loop'))
        : 'workflow_completed',
    };
  }

  return {
    machineGateResultIsAmbiguous,
    normalizeBlockingFindings,
    resolveStageTransition,
    validateDetailOutlineQualityResult,
  };
}

module.exports = { createWorkflowTransitionService, validateDetailOutlineQualityResult, validateLifecycleTransitionRequest };
