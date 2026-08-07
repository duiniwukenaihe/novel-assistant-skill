#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { acceptTransaction, prepareTransaction, rollbackPreparedTransaction } = require('./lib/chapter-commit-store');
const { classifyWorkflowApply, recoverableStageResult, stageRecoveryPresentation } = require('./lib/workflow-apply-result');
const { mutateTaskAuthority, resolveTaskAuthority } = require('./lib/workflow-task-authority');
const {
  buildShortSettingCandidatePendingAction,
  decoratePendingAction,
  renderPendingActionText,
} = require('./lib/workflow-action-renderer');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const {
  advanceShortPlanRevision,
  assertShortProjectOwnership,
  ensureShortProjectState,
  readShortProjectState,
  resolveShortStateRelative,
} = require('./lib/short-project-state');
const { appendIntegrationEvent } = require('./lib/integration-outbox');
const { ensureCurrentShortMemoryStage } = require('./lib/short-memory-stage-recovery');
const { invalidateBriefFreshnessSnapshot, sidecarRelativePath } = require('./lib/short-brief-freshness');
const { validateWorkflowConfirmation } = require('./lib/workflow-confirmation-context');
const { invokeApplyResult, invokeResolveAction } = require('./lib/workflow-state-machine-invoke');
const { readJson, parseJson } = require('./lib/cli-utils');
const {
  analyzeShortOutlineNarrativeQuality,
  inferPlannedSections,
  outlineSections,
} = require('./lib/short-plan-contract');
const {
  analyzeShortCharacterContract,
  projectShortCharacterMemory,
} = require('./lib/short-character-contract');
// The shared engine-neutral planning service owns: finalizePlanningStage (the
// REAL character/narrative/pollution validation + chapter-commit transaction +
// project-state/character-memory projection + integration outbox), the Task 1
// StageResult contract, the stage table, and the small file/process helpers
// (inferProjectTitle, runJson, hashFile, planningEventType, ...). The V2 wrapper
// imports the service for BOTH the delegated main planning path AND those
// helpers, so there is exactly one implementation of each — no duplicate copy
// here. The wrapper keeps ONLY V2-specific orchestration: the short-setting
// candidate gate/review, validation_recovery / result-packet / apply-result
// translation, reusable-commit replay, context-asset building, and the
// feedback_apply_patch path.
const planningService = require('./lib/short-production/planning');
const STAGE_TARGETS = planningService.STAGE_TARGETS;
const STAGE_NUMBERS = planningService.STAGE_NUMBERS;
// Shared helpers reused by the feedback_apply_patch path (a structurally
// distinct V2 orchestration) so the feedback path does not redefine them.
const inferProjectTitle = planningService.inferProjectTitle;
const planningEventType = planningService.planningEventType;
const sharedRunJson = planningService.runJson;
const sharedHashFile = planningService.hashFile;
const safeProjectFile = planningService.safeProjectFile;
const safeSegment = planningService.safeSegment;
const readText = planningService.readText;

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return help();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 0, args.json);
  let task = authority.task;
  let execution = task.stage_execution || {};
  const stageId = String(task.current_stage || '');
  if (stageId === 'feedback_apply_patch') {
    return runFeedbackPlanningPatch({ root, workflowId, task, execution, args });
  }
  const canonicalTarget = STAGE_TARGETS[stageId] || '';
  if (!canonicalTarget || String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== stageId) {
    return finish({ status: 'stage_action_not_applicable', expected: Object.keys(STAGE_TARGETS), actual: stageId, instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }
  if (String(execution.planning_canonical_target || '') !== canonicalTarget) {
    return finish({ status: 'short_planning_target_mismatch', expected: canonicalTarget, actual: String(execution.planning_canonical_target || ''), instruction: '重新启动当前规划阶段，恢复受控暂存目标。' }, 0, args.json);
  }
  const stagedRel = String(execution.planning_target || '');
  const stagedFile = safeProjectFile(root, stagedRel);
  if (!stagedFile || !fs.existsSync(stagedFile) || !fs.statSync(stagedFile).isFile()) {
    return finish({ status: 'short_planning_staged_artifact_missing', planning_target: stagedRel, instruction: '重新启动当前阶段生成暂存制品；不得直接写正式文件。' }, 0, args.json);
  }
  if (args.context) {
    return finish(buildPlanningContext({ root, workflowId, stageId, execution, stagedRel, stagedFile }), 0, args.json);
  }
  if (!fs.readFileSync(stagedFile, 'utf8').trim()) {
    return finish({ status: 'short_planning_staged_artifact_empty', planning_target: stagedRel, instruction: '补全当前规划制品后重跑同一 execution_command。' }, 0, args.json);
  }
  // The V2 wrapper owns ONLY V2-specific orchestration around the shared
  // planning service: the short-setting candidate gate/review (a pre-commit
  // author-confirmation flow with no V3 equivalent), validation_recovery /
  // result-packet / apply-result translation, and the feedback patch path
  // (handled above). The character/narrative/pollution validation, the
  // chapter-commit transaction, project-state projection, character-memory
  // projection, and integration outbox all live in the shared
  // finalizePlanningStage service — the wrapper calls it and translates the
  // StageResult back to the legacy V2 JSON / result-packet shape. There is no
  // second copy of that business logic here.
  if (stageId === 'short_setting' && !args.apply) {
    return runShortSettingCandidateGate({ root, workflowId, task, stagedRel, stagedFile, canonicalTarget, args });
  }

  // V2-only apply preflight: the reusable-commit check AND the planning memory
  // gate MUST run BEFORE the shared service commits with apply:true. A reusable
  // accepted commit is replayed without re-committing; a stale memory context
  // blocks before the transaction so the canonical artifact and accepted-commit
  // inventory stay unchanged. If the memory gate refreshes the task/execution,
  // the refreshed values flow into the shared service and the packet
  // translation below. The engine-neutral service stays V2-independent: it
  // never imports this memory/state-machine code.
  let memoryReceipt = null;
  if (args.apply) {
    const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/${stageId}.result.json`);
    const packetFile = safeProjectFile(root, packetRel);
    const existingPacket = readJson(packetFile);
    const reusableCommit = reusablePlanningCommit(root, existingPacket, workflowId, execution, canonicalTarget);
    if (reusableCommit) {
      return replayReusablePlanningCommit({ root, workflowId, task, execution, stageId, canonicalTarget, stagedRel, packetFile, packetRel, existingPacket, reusableCommit, args });
    }
    const memoryValidation = validatePlanningMemoryBeforeCommit({ root, task, execution, stageId });
    if (memoryValidation.blocking) return finish(memoryValidation.result, 0, args.json);
    task = memoryValidation.task;
    execution = memoryValidation.execution;
    memoryReceipt = memoryValidation.receipt;
  }

  // Delegate validation (+ commit when --apply) to the engine-neutral service.
  // The service reads the freshly reread durable task and runs the REAL
  // validators and the REAL chapter-commit transaction; the wrapper only
  // translates the resulting StageResult into the V2 JSON contract below.
  const stageResult = planningService.finalizePlanningStage({
    projectRoot: root,
    task,
    stageId,
    stagedRel,
    apply: Boolean(args.apply),
  });

  if (stageResult.kind === 'completed') {
    if (args.apply) {
      return applyAcceptedPlanningStageResult({ root, workflowId, task, execution, stageId, canonicalTarget, stagedRel, stageResult, memoryReceipt, args });
    }
    return finish({ status: 'short_planning_ready', stage_id: stageId, planning_target: stagedRel, canonical_target: canonicalTarget }, 0, args.json);
  }

  if (stageResult.kind === 'blocked') {
    return finish({
      status: String(stageResult.code || 'short_planning_blocked'),
      stage_id: stageId,
      planning_target: stagedRel,
      ...(stageResult.canonical_target ? { canonical_target: stageResult.canonical_target } : {}),
      ...(stageResult.workflow_id ? { workflow_id: stageResult.workflow_id } : {}),
      ...(stageResult.commit_id ? { commit_id: stageResult.commit_id } : {}),
      ...(stageResult.detail ? { detail: stageResult.detail } : {}),
      ...(stageResult.character_memory ? { character_memory: stageResult.character_memory } : {}),
      instruction: String(stageResult.instruction || '读取当前 execution_command，按未通过项修复后重跑。'),
    }, 0, args.json);
  }

  // retryable_internal / needs_author_choice: the shared service has decided the
  // content of the failure (family, findings). The wrapper keeps the V2-specific
  // validation_recovery retry budget (per-stage max_automatic_attempts) and the
  // workflow_choice_required / visible_response presentation. It does NOT
  // re-validate; it consumes the StageResult's findings.
  return translatePlanningFailureResult({
    root, workflowId, task, stageId, stagedRel, canonicalTarget, stageResult, args,
  });
}

// V2 short-setting candidate gate: a lightweight author-confirmation flow that
// runs before the full character contract and before any commit. The shared
// service has no notion of a "candidate awaiting confirmation", so this stays
// in the wrapper. The lightweight missing-field check filters obviously
// incomplete candidates before they reach the candidate review.
function runShortSettingCandidateGate({ root, workflowId, task, stagedRel, stagedFile, canonicalTarget, args }) {
  const candidateText = fs.readFileSync(stagedFile, 'utf8');
  const missing = [];
  if (!/(?:主角|女主|男主)/u.test(candidateText)) missing.push('主角');
  if (!/(?:目标|想要|要完成|要保住)/u.test(candidateText)) missing.push('主角目标');
  if (!/(?:软肋|恐惧|害怕|内在需求|缺陷|误信)/u.test(candidateText)) missing.push('软肋或缺陷');
  if (!/(?:压力角色|对手|阻力|主要人物)/u.test(candidateText)) missing.push('压力角色');
  if (!/(?:关系债|关系压力|利益冲突|人物关系)/u.test(candidateText)) missing.push('人物关系');
  if (!/(?:核心冲突|故事冲突)/u.test(candidateText)) missing.push('核心冲突');
  if (!/(?:升级|递进|第一层|第二层|三级)/u.test(candidateText)) missing.push('剧情升级');
  if (!/(?:反转|揭示|真相)/u.test(candidateText)) missing.push('关键反转');
  if (!/(?:结局|终局|结尾兑现)/u.test(candidateText)) missing.push('结局兑现');
  if (missing.length) {
    return finish({
      status: 'short_setting_candidate_revision_required',
      planning_target: stagedRel,
      missing_fields: missing,
      instruction: '只补齐候选卡缺失项，保持紧凑，不要扩写成完整设定书；完成后重跑同一 execution_command。',
    }, 0, args.json);
  }
  return prepareShortSettingCandidateReview({ root, workflowId, task, stagedRel, stagedFile, args });
}

// Translate a retryable_internal / needs_author_choice StageResult into the V2
// validation_recovery / workflow_choice_required JSON contract. The shared
// service owns WHAT failed (family, findings, instruction); the wrapper owns
// the V2 retry budget and the visible_response presentation. The blocklist of
// statuses below share the same workflow_choice_required shape.
function translatePlanningFailureResult({ root, workflowId, task, stageId, stagedRel, canonicalTarget, stageResult, args }) {
  const status = String(stageResult.code || 'short_planning_revision_required');
  const findings = Array.isArray(stageResult.findings) ? stageResult.findings : [];
  const extra = {};
  if (Array.isArray(stageResult.planned_sections)) extra.planned_sections = stageResult.planned_sections;
  if (stageResult.section_roles) extra.section_roles = stageResult.section_roles;
  if (stageResult.advisories) extra.advisories = stageResult.advisories;
  if (stageResult.canonical_target) extra.canonical_target = stageResult.canonical_target;
  return handlePlanningValidationFailure({
    root,
    workflowId,
    task,
    stageId,
    stagedRel,
    status,
    findings,
    extra,
    instruction: String(stageResult.instruction || '只修当前暂存规划中的未通过项，完成后重跑同一 execution_command。'),
    json: args.json,
  });
}

// Replay an already-accepted planning commit WITHOUT re-committing. This is the
// V2 reusable-commit path: the preflight in main() detected an accepted commit
// for this stage attempt whose canonical artifact hash still matches, so the
// shared service is never asked to commit again. The packet written here is the
// V2 receipt that apply-result consumes; the reused commit_id is the only
// commit identity. The memory gate has already run in the preflight.
function replayReusablePlanningCommit({ root, workflowId, execution, stageId, canonicalTarget, stagedRel, packetFile, packetRel, existingPacket, reusableCommit, args }) {
  try {
    assertShortProjectOwnership(root, readShortProjectState(root), workflowId);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_project_ownership_conflict'), workflow_id: workflowId, instruction: '当前目录已有未完成的短篇写作任务；请从任务收件箱恢复或明确结束旧任务。' }, 0, args.json);
  }
  existingPacket.chapter_commit = planningCommitReceipt(reusableCommit, stagedRel);
  existingPacket.memory_validation = {
    schema_version: '1.0.0',
    boundary: 'accepted_commit_replay',
    status: 'accepted_transaction',
    stage_attempt_id: String(execution.stage_attempt_id || ''),
    accepted_commit_id: String(reusableCommit.commit_id || ''),
  };
  atomicWriteJson(packetFile, existingPacket);
  const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile });
  const outcome = classifyWorkflowApply(applied);
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    stage_id: stageId,
    canonical_target: canonicalTarget,
    commit_id: reusableCommit.commit_id,
    result_packet: packetRel,
    reused_accepted_result: true,
    next_stage: String(outcome.result.current_stage || ((outcome.result.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

// Build the V2 result packet from a completed StageResult's structured commit
// evidence and apply it through the workflow state machine. The shared service
// already performed the real chapter-commit transaction, project-state
// projection, character-memory projection, and integration outbox event; the
// packet written here is the V2 receipt that apply-result consumes. The commit
// receipt and projection evidence come straight off the StageResult, so the
// wrapper never re-derives them. The reusable-commit check and the memory gate
// have already run in the main() preflight BEFORE the service committed, so
// they are intentionally NOT repeated here.
function applyAcceptedPlanningStageResult({ root, workflowId, task, execution, stageId, canonicalTarget, stagedRel, stageResult, memoryReceipt, args }) {
  try {
    assertShortProjectOwnership(root, readShortProjectState(root), workflowId);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_project_ownership_conflict'), workflow_id: workflowId, instruction: '当前目录已有未完成的短篇写作任务；请从任务收件箱恢复或明确结束旧任务。' }, 0, args.json);
  }
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/${stageId}.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  const integrationEventStatus = stageResult.integration_event && typeof stageResult.integration_event === 'object'
    ? String(stageResult.integration_event.status || 'not_applicable')
    : String(stageResult.integration_event || 'not_applicable');
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: stageId,
    step_id: stageId,
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: [canonicalTarget],
    changed_files: [canonicalTarget, resolveShortStateRelative(root, 'project-state.json', { forWrite: true }), ...(integrationEventStatus === 'appended' ? ['追踪/integration/outbox.jsonl'] : [])],
    created_files: [],
    evidence: [{ planning_target: stagedRel, canonical_target: canonicalTarget, commit_id: String(stageResult.commit_id || ''), projection_status: String(stageResult.projection_status || ''), project_id: String(stageResult.project_id || ''), plan_revision: Number(stageResult.plan_revision || 0), integration_event: integrationEventStatus, character_memory: String(stageResult.character_memory || 'not_applicable') }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: stageId, completed_range: `${canonicalTarget} 已受控接受`, remaining_range: '进入下一规划阶段', resume_from: '' },
    next_recommendation: '进入工作流给出的下一阶段。',
    handoff_summary: `${canonicalTarget} 已通过受控事务写入。`,
    chapter_commit: planningCommitReceipt(stageResult, stagedRel),
    memory_validation: memoryReceipt || { schema_version: '1.0.0', boundary: 'pre_commit', status: 'not_recorded', stage_attempt_id: String(execution.stage_attempt_id || '') },
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile });
  const outcome = classifyWorkflowApply(applied);
  const result = outcome.result;
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    stage_id: stageId,
    canonical_target: canonicalTarget,
    commit_id: String(stageResult.commit_id || ''),
    project_id: String(stageResult.project_id || ''),
    plan_revision: Number(stageResult.plan_revision || 0),
    integration_event: stageResult.integration_event || null,
    result_packet: packetRel,
    next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: result }),
  }, outcome.exitCode, args.json);
}

function handlePlanningValidationFailure({ root, workflowId, task, stageId, stagedRel, status, findings, extra = {}, instruction, json }) {
  const fingerprint = crypto.createHash('sha256')
    .update(JSON.stringify({ stageId, stagedRel, findings }), 'utf8')
    .digest('hex');
  let updated;
  try {
    updated = mutateTaskAuthority(root, workflowId, Number(task.state_version || 0), (draft) => {
      const execution = draft.stage_execution && typeof draft.stage_execution === 'object'
        ? draft.stage_execution
        : {};
      const previous = execution.validation_recovery && typeof execution.validation_recovery === 'object'
        ? execution.validation_recovery
        : {};
      const sameAttempt = String(previous.stage_attempt_id || '') === String(execution.stage_attempt_id || '');
      const attempts = sameAttempt ? Number(previous.attempts || 0) + 1 : 1;
      const maxAutomaticAttempts = stageId === 'section_outline' ? 0 : 1;
      const exhausted = attempts > maxAutomaticAttempts;
      execution.validation_recovery = {
        status: exhausted ? 'awaiting_user_decision' : 'retry_once',
        stage_attempt_id: String(execution.stage_attempt_id || ''),
        fingerprint,
        attempts,
        max_automatic_attempts: maxAutomaticAttempts,
        findings: Array.isArray(findings) ? findings : [],
        updated_at: new Date().toISOString(),
      };
      if (exhausted) {
        execution.status = 'awaiting_user_decision';
        execution.completion_required_before_reply = false;
        draft.status = 'paused_after_step';
        draft.pending_action = buildPlanningValidationPendingAction(draft, stageId);
        draft.machine = draft.machine || {};
        draft.machine.next_stop_reason = 'planning_validation_retry_exhausted';
      }
      draft.stage_execution = execution;
      return draft;
    });
  } catch (error) {
    return finish({
      status: String(error.code || 'short_planning_validation_state_conflict').toLowerCase(),
      instruction: '任务状态已变化，请重新显示当前任务；保留暂存规划，不要重新生成。',
    }, 0, json);
  }
  const recovery = (updated.stage_execution || {}).validation_recovery || {};
  if (Number(recovery.attempts || 0) <= Number(recovery.max_automatic_attempts || 0)) {
    return finish(recoverableStageResult(updated, status, instruction, {
      planning_target: stagedRel,
      findings,
      ...extra,
      automatic_retry: { current: 1, maximum: 1 },
    }), 0, json);
  }
  const pending = updated.pending_action || buildPlanningValidationPendingAction(updated, stageId);
  const automaticAttempts = Number(recovery.max_automatic_attempts || 0);
  const heading = automaticAttempts > 0
    ? '当前规划已自动修订一次，仍有未通过项；系统已停止自动改写，避免继续浪费 token。'
    : '当前规划存在未通过项；系统未自动改写，避免整份大纲反复重写和浪费 token。';
  return finish({
    status: 'workflow_choice_required',
    workflow_id: workflowId,
    stage_id: stageId,
    planning_target: stagedRel,
    findings,
    ...extra,
    pending_action: pending,
    next_candidates: pending.options,
    visible_response: {
      render_mode: 'text_numbers',
      status: 'planning_validation_retry_exhausted',
      options: pending.options,
      text: renderPendingActionText(pending, heading),
    },
    interaction_contract: 'render_visible_response_text_verbatim',
  }, 0, json);
}

function buildPlanningValidationPendingAction(task, stageId) {
  return decoratePendingAction({
    id: `pa-planning-validation-${String(task.workflow_id || 'short')}-${stageId}`,
    question: '请选择当前规划的处理方式',
    options: [
      { action_id: 'inspect_current_state', label: '查看未通过项与已识别内容（推荐）', risk_level: 'low', requires_user_confirm: false },
      { action_id: 'free_text', label: '调整当前大纲要求', risk_level: 'low', requires_user_confirm: false },
      { action_id: 'retry_stage_contract', label: '重新生成当前暂存大纲一次', target_stage: stageId, risk_level: 'low', requires_user_confirm: false },
      { action_id: 'pause', label: '暂停并保存断点', risk_level: 'low', requires_user_confirm: false },
    ],
    free_text_enabled: true,
  });
}

function clearPlanningValidationRecovery(root, workflowId, task, stageId) {
  const recovery = (((task || {}).stage_execution || {}).validation_recovery);
  if (!recovery || String(((task || {}).current_stage) || '') !== String(stageId || '')) {
    return { task, execution: (task || {}).stage_execution || {} };
  }
  try {
    const updated = mutateTaskAuthority(root, workflowId, Number(task.state_version || 0), (draft) => {
      const execution = { ...(draft.stage_execution || {}) };
      delete execution.validation_recovery;
      if (String(execution.status || '') === 'awaiting_user_decision') execution.status = 'running';
      draft.stage_execution = execution;
      draft.pending_action = null;
      return draft;
    });
    return { task: updated, execution: updated.stage_execution || {} };
  } catch (_) {
    return { task, execution: (task || {}).stage_execution || {} };
  }
}

function planningCommitReceipt(receipt, stagedRel) {
  // Accepts either the raw chapter-commit accept object (legacy feedback path)
  // or a completed planning StageResult carrying commit_id/commit_file/
  // projection_status evidence (main planning path delegated to the shared
  // service). Both expose the same commit-identity fields.
  return {
    mode: 'transactional',
    accepted_commit_id: String(receipt.commit_id || ''),
    commit_file: String(receipt.commit_file || ''),
    staged_artifacts: [stagedRel],
    projection_status: String(receipt.projection_status || 'projection_not_required'),
    projection_debt: String(receipt.projection_status || '') === 'projection_failed',
  };
}

function reusablePlanningCommit(root, packet, workflowId, execution, canonicalTarget) {
  if (!packet || packet.step_status !== 'completed') return null;
  if (String(packet.workflow_id || '') !== String(workflowId || '')) return null;
  if (String(packet.stage_id || '') !== String(execution.stage_id || '')) return null;
  const commitId = String((((packet || {}).chapter_commit || {}).accepted_commit_id)
    || ((((packet || {}).evidence || [])[0] || {}).commit_id)
    || '');
  if (!commitId) return null;
  const commitFile = path.join(root, '追踪', 'story-system', 'commits', `${commitId}.json`);
  const commit = readJson(commitFile);
  if (!commit || commit.status !== 'accepted' || String(commit.workflow_id || '') !== String(workflowId || '')) return null;
  if (String(((commit.provenance || {}).stage_attempt_id) || '') !== String(execution.stage_attempt_id || '')) return null;
  const artifact = (Array.isArray(commit.artifacts) ? commit.artifacts : [])
    .find(item => String((item || {}).target || '') === canonicalTarget);
  const canonical = path.join(root, canonicalTarget);
  if (!artifact || !fs.existsSync(canonical) || String(artifact.after_hash || '') !== sharedHashFile(canonical)) return null;
  return {
    commit_id: commitId,
    commit_file: path.relative(root, commitFile).split(path.sep).join('/'),
    projection_status: 'projection_not_required',
  };
}

function prepareShortSettingCandidateReview({ root, workflowId, task, stagedRel, stagedFile, args }) {
  const source = fs.readFileSync(stagedFile, 'utf8').trim();
  const digest = `sha256:${crypto.createHash('sha256').update(source, 'utf8').digest('hex')}`;
  let updated;
  try {
    updated = mutateTaskAuthority(root, workflowId, Number(task.state_version || 0), (draft) => {
      const previous = draft.short_setting_candidate && typeof draft.short_setting_candidate === 'object'
        ? draft.short_setting_candidate
        : {};
      draft.short_setting_candidate = {
        status: 'awaiting_author_confirmation',
        path: stagedRel,
        sha256: digest,
        revision: Math.max(1, Number(previous.revision || 0) + 1),
        generated_at: new Date().toISOString(),
        author_decision: 'pending',
        feedback: String(previous.feedback || ''),
      };
      draft.stage_execution = {
        ...(draft.stage_execution || {}),
        status: 'awaiting_author_confirmation',
        candidate_path: stagedRel,
        candidate_sha256: digest,
        execution_command: '',
        resume_hint: '先展示人物与剧情设定候选；作者确认前不得写入正式设定.md，也不得进入平台、节奏、小节大纲或正文。',
      };
      draft.pending_action = buildShortSettingCandidatePendingAction(draft);
      draft.machine = draft.machine || {};
      draft.machine.last_transition = 'short_setting_candidate_ready';
      draft.machine.last_execution_event = 'awaiting_author_confirmation';
      draft.machine.next_stop_reason = 'short_setting_author_confirmation_required';
      draft.machine.allowed_actions = ['confirm_setting', 'revise_setting', 'inspect', 'pause'];
      return draft;
    });
  } catch (error) {
    return finish({
      status: String(error.code || 'short_setting_candidate_state_conflict').toLowerCase(),
      planning_target: stagedRel,
      instruction: '任务状态已变化，请重新显示当前候选；不要重复生成设定。',
    }, 0, args.json);
  }
  return finish({
    status: 'short_setting_candidate_ready',
    workflow_id: workflowId,
    stage_id: 'short_setting',
    planning_target: stagedRel,
    candidate_sha256: digest,
    candidate_preview: source.slice(0, 6000),
    preview_truncated: source.length > 6000,
    pending_action: updated.pending_action,
    instruction: '展示候选与数字选项，等待作者确认或调整；不得自动运行提交命令。',
  }, 0, args.json);
}

function buildPlanningContext({ root, workflowId, stageId, execution, stagedRel, stagedFile }) {
  const inputs = Array.isArray(execution.planning_inputs) ? execution.planning_inputs : [];
  const assets = [];
  let remaining = stageId === 'section_outline' ? 12000 : 16000;
  for (const relative of [...inputs, stagedRel]) {
    if (remaining <= 0) break;
    const file = safeProjectFile(root, relative);
    if (!file || !fs.existsSync(file) || !fs.statSync(file).isFile()) continue;
    const source = fs.readFileSync(file, 'utf8');
    const limit = relative === stagedRel ? Math.min(5000, remaining) : Math.min(7000, remaining);
    const content = compactPlanningInput(relative, source, stageId, limit);
    assets.push({
      path: relative,
      role: relative === stagedRel ? 'staged_target' : 'planning_input',
      content,
      truncated: source.length > content.length,
    });
    remaining -= content.length;
  }
  const settingText = readText(path.join(root, '设定.md'));
  const currentState = readShortProjectState(root) || {};
  const stagedSections = stageId === 'section_outline' ? outlineSections(readText(stagedFile)) : [];
  const plannedSections = stageId === 'section_outline'
    ? inferPlannedSections(settingText, currentState, stagedSections)
    : 0;
  const outputContract = stageId === 'section_outline'
    ? {
      artifact: stagedRel,
      planned_sections: plannedSections,
      max_chars: Math.min(9000, Math.max(4200, plannedSections * 1100)),
      max_lines: Math.min(240, Math.max(90, plannedSections * 24 + 24)),
      per_section: ['压力变化', '场景动作', '可见阻力', '角色选择', '本节兑现', '关系变化', '代价', '新钩子'],
      rule: '每项只写一次；每节保留可执行动作和因果，不复述整份人物设定或证据原文。',
    }
    : null;
  return {
    status: 'short_planning_context_ready',
    workflow_id: workflowId,
    stage_id: stageId,
    planning_target: stagedRel,
    assets,
    ...(outputContract ? { output_contract: outputContract } : {}),
    instruction: 'assets 已包含当前阶段所需的权威摘要。只使用这份有界上下文；写入前用 Read 读取一次 planning_target，Markdown/纯文本不要传 pages 参数。禁止再列目录、读取历史 result packet、完整设定或 workflow 源码。',
  };
}

function compactPlanningInput(relative, source, stageId, limit) {
  const text = String(source || '');
  if (stageId !== 'section_outline' || relative !== '设定.md') return boundedText(text, limit);
  const blocks = markdownLevelTwoBlocks(text);
  const wanted = [
    /项目定位/u,
    /可执行人物|主要人物|角色/u,
    /故事承诺/u,
    /不可变事实|规划接口/u,
    /平台与题材|平台.*锁定/u,
    /节奏模式|节奏.*选择|节奏.*锁定/u,
    /风险边界|现实边界/u,
    /对话锚点|关键锚点/u,
  ];
  const selected = [];
  for (const pattern of wanted) {
    const block = blocks.find((item) => pattern.test(item.heading));
    if (block && !selected.includes(block)) selected.push(block);
  }
  const preamble = text.slice(0, Math.max(0, text.search(/^##\s+/mu)) || Math.min(text.length, 500));
  const compact = [preamble.trim(), ...selected.map((block) => compactMarkdownBlock(block.text, 1300))]
    .filter(Boolean)
    .join('\n\n');
  return boundedText(compact || text, limit);
}

function markdownLevelTwoBlocks(source) {
  const text = String(source || '');
  const matches = Array.from(text.matchAll(/^##\s+(.+)$/gmu));
  return matches.map((match, index) => ({
    heading: String(match[1] || '').trim(),
    text: text.slice(match.index, matches[index + 1] ? matches[index + 1].index : text.length).trim(),
  }));
}

function compactMarkdownBlock(value, limit) {
  const text = String(value || '');
  if (text.length <= limit) return text;
  const head = Math.max(1, Math.floor(limit * 0.72));
  const tail = Math.max(1, limit - head - 24);
  return `${text.slice(0, head).trimEnd()}\n[本节中段已压缩]\n${text.slice(-tail).trimStart()}`;
}

function boundedText(value, limit) {
  const text = String(value || '');
  if (text.length <= limit) return text;
  return compactMarkdownBlock(text, limit);
}

function runFeedbackPlanningPatch({ root, workflowId, task, execution, args }) {
  let currentTask = task;
  let currentExecution = execution;
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'feedback_apply_patch') {
    return finish({ status: 'stage_action_not_applicable', actual: String(task.current_stage || ''), instruction: '读取当前 execution_command，不要重试旧阶段命令。' }, 0, args.json);
  }
  if (String(((task.short_feedback_impact || {}).impact_level) || '') === 'current_brief') {
    return runFeedbackBriefInvalidation({ root, workflowId, task, execution, args });
  }
  const acceptedPlan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : {};
  const expectedAssets = normalizePlanningAssets((((acceptedPlan || {}).projection_plan || {}).planning_assets));
  const targets = Array.isArray(execution.planning_targets) ? execution.planning_targets
    .map(item => ({ canonical: normalizePlanningAsset((item || {}).canonical), staged: String((item || {}).staged || '') }))
    .filter(item => item.canonical && item.staged) : [];
  const actualAssets = targets.map(item => item.canonical).sort();
  if (!String(acceptedPlan.plan_id || '') || !expectedAssets.length || JSON.stringify(actualAssets) !== JSON.stringify(expectedAssets.slice().sort())) {
    return finish({
      status: 'short_feedback_planning_scope_mismatch',
      expected_assets: expectedAssets,
      actual_assets: actualAssets,
      instruction: '重新启动反馈回写阶段，从已确认方案重建受控暂存目标；不得手改工作流状态。',
    }, 0, args.json);
  }
  const missing = [];
  const empty = [];
  const pollutionFindings = [];
  for (const target of targets) {
    const stagedFile = safeProjectFile(root, target.staged);
    if (!stagedFile || !fs.existsSync(stagedFile) || !fs.statSync(stagedFile).isFile()) {
      missing.push(target.staged);
      continue;
    }
    if (!fs.readFileSync(stagedFile, 'utf8').trim()) empty.push(target.staged);
    if (target.canonical === '设定.md') {
      const characterContract = analyzeShortCharacterContract(fs.readFileSync(stagedFile, 'utf8'));
      if (characterContract.status !== 'pass') {
        const instruction = '只补齐暂存设定中的人物发动机、主要压力角色和关系债；不要继续改小节大纲或正文。';
        return finish({
          status: 'short_feedback_character_contract_revision_required',
          planning_target: target.staged,
          findings: characterContract.findings,
          advisories: characterContract.advisories,
          instruction,
          ...stageRecoveryPresentation(task, { status: 'short_feedback_character_contract_revision_required', instruction }),
        }, 0, args.json);
      }
    }
    const pollution = sharedRunJson(root, 'output-pollution-check.js', ['--check', '--json', stagedFile]);
    for (const finding of Array.isArray(pollution.findings) ? pollution.findings : []) {
      pollutionFindings.push({ target: target.staged, ...finding });
    }
    if (target.canonical === '小节大纲.md') {
      const outlineText = fs.readFileSync(stagedFile, 'utf8');
      const settingTarget = targets.find(item => item.canonical === '设定.md');
      const settingFile = settingTarget ? safeProjectFile(root, settingTarget.staged) : path.join(root, '设定.md');
      const currentState = readShortProjectState(root) || {};
      const sections = outlineSections(outlineText);
      const plannedSections = inferPlannedSections(readText(settingFile), currentState, sections);
      const narrative = analyzeShortOutlineNarrativeQuality(outlineText, plannedSections, { settingText: readText(settingFile) });
      if (narrative.status !== 'pass') {
        const instruction = '只修暂存小节大纲中受影响小节的重复版本、场景行动、可见阻力、人物选择、关系变化、兑现和承接；不要进入写作提要或正文。修完后重新运行当前阶段提交命令。';
        return finish({
          status: 'short_feedback_outline_revision_required',
          planning_target: target.staged,
          planned_sections: plannedSections,
          section_roles: narrative.section_roles,
          findings: narrative.findings.slice(0, 24),
          instruction,
          ...stageRecoveryPresentation(task, { status: 'short_feedback_outline_revision_required', instruction }),
        }, 0, args.json);
      }
    }
  }
  if (missing.length || empty.length) {
    return finish(recoverableStageResult(task, 'short_feedback_planning_artifact_incomplete', '补齐当前暂存规划资产后重跑同一阶段提交命令。', { missing, empty }), 0, args.json);
  }
  if (pollutionFindings.length) {
    return finish(recoverableStageResult(task, 'short_feedback_planning_revision_required', '只修暂存规划资产中的重复、工程词泄漏或模型污染，再重跑同一阶段提交命令。', { findings: pollutionFindings.slice(0, 16) }), 0, args.json);
  }
  if (!args.apply) return finish({ status: 'short_feedback_planning_ready', plan_id: acceptedPlan.plan_id, planning_targets: targets }, 0, args.json);

  try {
    assertShortProjectOwnership(root, readShortProjectState(root), workflowId);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_project_ownership_conflict'), workflow_id: workflowId, instruction: '从任务收件箱恢复当前短篇任务，不要新建第二个写作任务。' }, 0, args.json);
  }
  const affectedSections = normalizeSectionList(acceptedPlan.affected_sections);
  const projectionPlan = acceptedPlan.projection_plan || {};
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/feedback_apply_patch.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  const existingPacket = readJson(packetFile);
  const reusableCommit = reusableFeedbackCommit(root, existingPacket, workflowId, execution, actualAssets);
  if (reusableCommit) {
    existingPacket.memory_validation = {
      schema_version: '1.0.0',
      boundary: 'accepted_commit_replay',
      status: 'accepted_transaction',
      stage_attempt_id: String(execution.stage_attempt_id || ''),
      accepted_commit_id: String(reusableCommit.commit_id || ''),
    };
    atomicWriteJson(packetFile, existingPacket);
    const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile });
    const outcome = classifyWorkflowApply(applied);
    return finish({
      status: outcome.applied ? 'applied' : 'apply_blocked',
      workflow_status: outcome.workflowStatus,
      workflow_id: workflowId,
      stage_id: 'feedback_apply_patch',
      plan_id: acceptedPlan.plan_id,
      planning_assets: actualAssets,
      affected_sections: affectedSections,
      commit_id: reusableCommit.commit_id,
      result_packet: packetRel,
      reused_accepted_result: true,
      next_stage: String(outcome.result.current_stage || ((outcome.result.task || {}).current_stage) || ''),
      ...outcome.presentation,
      ...(outcome.applied ? {} : { recovery: outcome.result }),
    }, outcome.exitCode, args.json);
  }
  const memoryValidation = validatePlanningMemoryBeforeCommit({ root, task: currentTask, execution: currentExecution, stageId: 'feedback_apply_patch' });
  if (memoryValidation.blocking) return finish(memoryValidation.result, 0, args.json);
  currentTask = memoryValidation.task;
  currentExecution = memoryValidation.execution;
  const attempt = safeSegment(currentExecution.stage_attempt_id || 'attempt');
  const manifestRel = `${currentTask.task_dir}/artifacts/planning-commits/feedback_apply_patch-${attempt}.manifest.json`;
  const manifestFile = safeProjectFile(root, manifestRel);
  atomicWriteJson(manifestFile, {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    volume: '短篇规划反馈',
    chapter: 1,
    gates: { output_health: 'pass', prose_quality: 'pass', story_drift: 'pass' },
    artifacts: targets.map(item => ({ role: 'feedback_planning_patch', required: true, staged: item.staged, target: item.canonical })),
    facts: [],
  });
  let commit;
  try {
    const prepared = prepareTransaction(root, manifestRel);
    commit = acceptTransaction(root, prepared.transaction_id);
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_feedback_planning_commit_blocked'), detail: String(error.message || error), instruction: '暂存规划资产仍保留；修复提交条件后重跑同一 execution_command，不要重新生成。' }, 0, args.json);
  }

  const title = inferProjectTitle(readText(path.join(root, targets[0].canonical)), currentTask, root);
  let projectState;
  try {
    projectState = actualAssets.includes('小节大纲.md')
      ? advanceShortPlanRevision(root, { workflowId, title, outlinePath: '小节大纲.md' })
      : ensureShortProjectState(root, { workflowId, title, stageId: 'feedback_apply_patch', artifactPath: actualAssets[0] });
  } catch (error) {
    return finish({
      status: String(error.status || error.code || 'short_project_state_projection_blocked'),
      workflow_id: workflowId,
      commit_id: String(commit.commit_id || ''),
      instruction: '规划资产已安全提交但项目状态投影失败；修复状态后重放当前提交，不要重新生成内容。',
    }, 0, args.json);
  }
  let characterMemory = null;
  if (actualAssets.includes('设定.md')) {
    characterMemory = projectShortCharacterMemory(root, { workflowId });
    if (characterMemory.status !== 'projected') {
      return finish({
        status: 'short_character_memory_projection_blocked',
        workflow_id: workflowId,
        commit_id: String(commit.commit_id || ''),
        character_memory: characterMemory,
        instruction: '规划资产已安全提交，但人物记忆投影失败；修复投影后重放当前阶段，不要重新生成内容。',
      }, 0, args.json);
    }
  }

  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(currentTask.workflow_type || 'short_write'),
    stage_id: 'feedback_apply_patch',
    step_id: 'feedback_apply_patch',
    owner_module: String(currentExecution.owner_module || currentTask.workflow_owner || ''),
    step_status: 'completed',
    outputs: actualAssets,
    changed_files: [...actualAssets, resolveShortStateRelative(root, 'project-state.json', { forWrite: true })],
    changed_assets: actualAssets,
    created_files: [],
    evidence: [{ plan_id: acceptedPlan.plan_id, planning_assets: actualAssets, commit_id: String(commit.commit_id || ''), project_id: projectState.project_id, plan_revision: projectState.plan_revision, character_memory: characterMemory ? characterMemory.status : 'not_applicable' }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: 'feedback_apply_patch', completed_range: '已确认方案对应规划资产已受控提交', remaining_range: '按受影响小节重建 Brief 并复检正文', resume_from: '' },
    next_recommendation: '进入工作流给出的受影响小节修订队列。',
    handoff_summary: `已按 ${acceptedPlan.plan_id} 回写 ${actualAssets.join('、')}。`,
    feedback_id: String(acceptedPlan.feedback_id || ''),
    impact_level: String(acceptedPlan.impact_level || 'planning'),
    affected_sections: affectedSections,
    cross_section_impact: affectedSections.length > 1,
    brief_invalidated: true,
    accepted_section: Array.isArray(projectState.accepted_sections) && projectState.accepted_sections.length > 0,
    downstream_impact: {
      invalidate_briefs: Array.isArray(projectionPlan.invalidate_briefs) ? projectionPlan.invalidate_briefs : [],
      recheck_prose: Array.isArray(projectionPlan.recheck_prose) ? projectionPlan.recheck_prose : [],
    },
    chapter_commit: {
      mode: 'transactional',
      accepted_commit_id: String(commit.commit_id || ''),
      commit_file: String(commit.commit_file || ''),
      staged_artifacts: targets.map(item => item.staged),
      projection_status: String(commit.projection_status || 'projection_not_required'),
      projection_debt: String(commit.projection_status || '') === 'projection_failed',
    },
    memory_validation: memoryValidation.receipt,
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile });
  const outcome = classifyWorkflowApply(applied);
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    stage_id: 'feedback_apply_patch',
    plan_id: acceptedPlan.plan_id,
    planning_assets: actualAssets,
    affected_sections: affectedSections,
    commit_id: String(commit.commit_id || ''),
    result_packet: packetRel,
    next_stage: String(outcome.result.current_stage || ((outcome.result.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function runFeedbackBriefInvalidation({ root, workflowId, task, execution, args }) {
  const acceptedPlan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : {};
  const pending = task.pending_feedback && typeof task.pending_feedback === 'object' ? task.pending_feedback : {};
  if (String(acceptedPlan.feedback_id || '') !== String(pending.feedback_id || '')
      || String(acceptedPlan.proposal_id || '') !== String(((task.proposed_plan || {}).proposal_id) || '')) {
    return finish({ status: 'short_feedback_acceptance_mismatch', instruction: '重新显示当前反馈方案并确认；不得沿用旧方案。' }, 0, args.json);
  }
  if (!validateWorkflowConfirmation(task, execution).valid) {
    return finish({ status: 'blocked_confirmation_required', instruction: '当前确认已失效或与方案不匹配，请重新显示并确认当前操作。' }, 0, args.json);
  }
  const affectedSections = normalizeSectionList(acceptedPlan.affected_sections || (task.short_feedback_impact || {}).affected_sections);
  if (!affectedSections.length) {
    return finish({ status: 'short_feedback_brief_scope_missing', instruction: '当前 Brief 回炉必须明确受影响小节。' }, 0, args.json);
  }
  if (!args.apply) return finish({ status: 'short_feedback_brief_invalidation_ready', affected_sections: affectedSections }, 0, args.json);
  const sidecarPaths = affectedSections.map(sectionIndex => sidecarRelativePath(sectionIndex, root));
  const rollbackSnapshots = sidecarPaths.map(relative => {
    const file = safeProjectFile(root, relative);
    return { file, existed: Boolean(file && fs.existsSync(file)), content: file && fs.existsSync(file) ? fs.readFileSync(file) : null };
  });
  const changedFiles = affectedSections.map((sectionIndex) => invalidateBriefFreshnessSnapshot({
    projectRoot: root,
    sectionIndex,
    feedbackId: String(pending.feedback_id || ''),
  }).sidecar);
  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/feedback_apply_patch.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    schemaVersion: '1.0.0',
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    stage_id: 'feedback_apply_patch',
    step_id: 'feedback_apply_patch',
    step_status: 'completed',
    outputs: [],
    changed_files: changedFiles,
    changed_assets: [],
    created_files: [],
    evidence: [{ accepted_plan_id: String(acceptedPlan.plan_id || ''), invalidated_brief_sidecars: changedFiles }],
    verification_result: 'pass',
    blocking_findings: [],
    output_health_result: 'pass',
    checkpoint_state: { current_stage: 'feedback_apply_patch', completed_range: `第 ${affectedSections.join('、')} 节旧 Brief 已标记失效`, remaining_range: '重建当前 Brief', resume_from: '' },
    next_recommendation: '重建当前小节 Brief 后复检现有正文。',
    handoff_summary: '当前反馈方案已确认，旧 Brief 已失效并进入受控重建。',
    feedback_id: String(pending.feedback_id || ''),
    impact_level: 'current_brief',
    affected_sections: affectedSections,
    cross_section_impact: affectedSections.length > 1,
    brief_invalidated: true,
    accepted_section: true,
    downstream_impact: { invalidate_briefs: affectedSections, recheck_prose: affectedSections },
    revision_groups: Array.isArray((task.short_feedback_impact || {}).revision_groups) ? task.short_feedback_impact.revision_groups : [],
    memory_updates: [],
    result_packet_path: packetRel,
  });
  const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile });
  const outcome = classifyWorkflowApply(applied);
  if (!outcome.applied) {
    for (const snapshot of rollbackSnapshots) {
      if (!snapshot.file) continue;
      if (snapshot.existed) fs.writeFileSync(snapshot.file, snapshot.content);
      else if (fs.existsSync(snapshot.file)) fs.unlinkSync(snapshot.file);
    }
  }
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    stage_id: 'feedback_apply_patch',
    affected_sections: affectedSections,
    changed_files: changedFiles,
    next_stage: String(outcome.result.current_stage || ((outcome.result.task || {}).current_stage) || ''),
    ...outcome.presentation,
    ...(outcome.applied ? {} : { recovery: outcome.result }),
  }, outcome.exitCode, args.json);
}

function validatePlanningMemoryBeforeCommit({ root, task, execution, stageId }) {
  if (!execution.stage_context_packet
      || String(((execution.memory_context || {}).context_source) || '') !== 'stage_context') {
    return {
      blocking: false,
      task,
      execution,
      receipt: {
        schema_version: '1.0.0',
        boundary: 'pre_commit',
        status: 'not_recorded',
        stage_attempt_id: String(execution.stage_attempt_id || ''),
      },
    };
  }
  const checked = ensureCurrentShortMemoryStage({
    projectRoot: root,
    workflowId: String(task.workflow_id || ''),
    task,
    execution,
    sectionIndex: Number(((execution.stage_context_packet || {}).section_index) || 0) || undefined,
    stageId,
  });
  if (checked.blocking) {
    return {
      blocking: true,
      result: recoverableStageResult(
        task,
        'short_planning_memory_context_refresh_required',
        checked.instruction || '规划提交前作品记忆已变化；保留暂存规划，刷新当前阶段后复核，不要重新生成。',
        { stale_sources: checked.stale_sources || [], memory_status: checked.memory_status || '' },
      ),
    };
  }
  return {
    blocking: false,
    task: checked.task,
    execution: checked.execution,
    receipt: {
      schema_version: '1.0.0',
      boundary: 'pre_commit',
      status: 'pass',
      stage_attempt_id: String((checked.execution || {}).stage_attempt_id || ''),
      memory_status: String(checked.memory_status || 'not_recorded'),
      memory_revision: String(((((checked.execution || {}).memory_context || {}).memory_read_receipt || {}).memory_revision) || ''),
    },
  };
}

function reusableFeedbackCommit(root, packet, workflowId, execution, expectedAssets) {
  if (!packet || packet.step_status !== 'completed' || packet.stage_id !== 'feedback_apply_patch') return null;
  if (String(packet.workflow_id || '') !== String(workflowId || '')) return null;
  const packetAssets = normalizePlanningAssets(packet.changed_assets || packet.outputs);
  if (JSON.stringify(packetAssets.slice().sort()) !== JSON.stringify(expectedAssets.slice().sort())) return null;
  const commitId = String((((packet || {}).chapter_commit || {}).accepted_commit_id)
    || ((((packet || {}).evidence || [])[0] || {}).commit_id)
    || '');
  if (!commitId) return null;
  const commitFile = path.join(root, '追踪', 'story-system', 'commits', `${commitId}.json`);
  const commit = readJson(commitFile);
  if (!commit || commit.status !== 'accepted' || String(commit.workflow_id || '') !== String(workflowId || '')) return null;
  if (String(((commit.provenance || {}).stage_attempt_id) || '') !== String(execution.stage_attempt_id || '')) return null;
  const artifacts = Array.isArray(commit.artifacts) ? commit.artifacts : [];
  for (const target of expectedAssets) {
    const artifact = artifacts.find(item => String((item || {}).target || '') === target);
    const canonical = path.join(root, target);
    if (!artifact || !fs.existsSync(canonical) || String(artifact.after_hash || '') !== sharedHashFile(canonical)) return null;
  }
  return { commit_id: commitId, commit_file: commitFile };
}

function normalizePlanningAssets(values) {
  return [...new Set((Array.isArray(values) ? values : []).map(normalizePlanningAsset).filter(Boolean))];
}

function normalizePlanningAsset(value) {
  const normalized = String(value || '').replace(/\\/g, '/').replace(/^\.\//, '');
  return /^(?:素材卡|设定|小节大纲)\.md$/u.test(normalized) ? normalized : '';
}

function normalizeSectionList(values) {
  return [...new Set((Array.isArray(values) ? values : []).map(Number).filter(item => Number.isInteger(item) && item > 0))].sort((a, b) => a - b);
}

function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }

function parseArgs(argv) { const out = { projectRoot: '', workflowId: '', apply: false, context: false, json: false, help: false }; for (let index = 0; index < argv.length; index += 1) { const arg = argv[index]; if (arg === '--project-root') out.projectRoot = argv[++index] || ''; else if (arg === '--workflow-id') out.workflowId = argv[++index] || ''; else if (arg === '--apply' || arg === '--write') out.apply = true; else if (arg === '--context') out.context = true; else if (arg === '--json') out.json = true; else if (arg === '--help' || arg === '-h') out.help = true; else return usage(`unknown argument: ${arg}`); } return out; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-planning-stage-finalize.js --project-root <book> --workflow-id <id> [--context] [--apply] [--json]\n`); process.exit(2); }
function help() { process.stdout.write('Usage: node short-planning-stage-finalize.js --project-root <book> --workflow-id <id> [--context] [--apply] [--json]\n'); return 0; }

process.exitCode = main();
