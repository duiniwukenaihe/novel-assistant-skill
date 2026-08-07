#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { classifyWorkflowApply, recoverableStageResult } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferShortSectionIndex } = require('./lib/short-workflow-state');
const { currentShortFeedbackRevisionSection } = require('./lib/short-feedback-revision-queue');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { ensureShortProjectState, resolveShortStateRelative, shortStateFile } = require('./lib/short-project-state');
const {
  finalizeBrief,
  analyzeBriefQuality,
  countCausalBeats,
  evidenceMechanismCount,
  plannedTargetChars,
  sectionResponsibilityCount,
} = require('./lib/short-production/section-loop');
const { invokeApplyResult, invokeResolveAction, invokeRunnerCommand } = require('./lib/workflow-state-machine-invoke');
const { readJson, parseJson } = require('./lib/cli-utils');

const BRIEF_STAGES = new Set(['first_section_brief', 'section_brief', 'next_section_brief']);

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  const task = authority.task;
  if (Number(task.engine_version) === 3) return finish({ status: 'v3_engine_apply_required', workflow_id: workflowId, instruction: 'V3 任务必须直接调用共享 service，并通过 V3 Engine 应用 StageResult。' }, 2, args.json);
  const stageId = String(task.current_stage || '');
  if (!BRIEF_STAGES.has(stageId)) return finish({ status: 'stage_action_not_applicable', expected: [...BRIEF_STAGES], actual: stageId, instruction: '重新读取当前任务的 execution_command；不要重试旧阶段命令。' }, 0, args.json);
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== stageId) {
    return finish({ status: 'stage_execution_not_ready', workflow_id: workflowId, instruction: '先由工作流启动写作提要阶段，再运行本命令。' }, 0, args.json);
  }

  let projectState;
  try {
    projectState = ensureShortProjectState(root, { workflowId });
  } catch (error) {
    return finish({ status: String(error.status || error.code || 'short_project_ownership_conflict'), workflow_id: workflowId, instruction: '当前目录属于另一个未完成短篇任务，请先从任务收件箱恢复。' }, 0, args.json);
  }
  const sectionIndex = currentShortFeedbackRevisionSection(task)
    || inferShortSectionIndex({ projectState, stageId, scope: String(task.scope || '') });
  if (!sectionIndex) return finish({ status: 'blocked_short_section_identity_missing', instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复小节范围，不得默认生成第1节 Brief。' }, 0, args.json);
  const briefRel = args.brief || `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`;
  const briefFile = safeProjectFile(root, briefRel);
  const shared = finalizeBrief({ projectRoot: root, task, brief: briefRel });
  if (shared.kind === 'needs_author_choice' || (shared.kind === 'retryable_internal' && shared.failure_family === 'brief_quality')) {
    const text = briefFile && fs.existsSync(briefFile) ? fs.readFileSync(briefFile, 'utf8').trim() : '';
    const briefQuality = analyzeBriefQuality(text);
    const recovery = registerBriefRevision({ root, task, briefRel, text, briefQuality, apply: args.apply });
    if (recovery.exhausted && args.apply) {
      const choice = registerBriefOverloadChoice({ root, workflowId, briefRel, findings: shared.findings || briefQuality.findings });
      if (choice) return finish({ brief: briefRel, ...choice }, 0, args.json);
    }
    return finish({
      brief: briefRel,
      ...briefQuality,
      status: recovery.exhausted ? 'brief_revision_exhausted' : 'brief_revision_required',
      recovery_attempt: recovery.attemptCount,
      recovery_limit: 1,
      requires_user_input: recovery.exhausted,
      next_action: recovery.exhausted
        ? '停在当前写作提要，向用户说明超载项；不得再自动重写或读取更多文件。'
        : '只精简当前写作提要一次，然后重新运行原 execution_command；无需用户再确认。',
      recovery: '保留承接、目标与阻力、因果动作、人物/视角锁、禁写项、节尾钩子六部分；同一事实只出现一次。',
      recovery_record: recovery.recordRel,
    }, 0, args.json);
  }
  if (shared.kind !== 'completed') {
    const legacyStatus = shared.code === 'short_section_identity_missing'
      ? 'blocked_short_section_identity_missing'
      : shared.code;
    if (shared.kind === 'retryable_internal') {
      return finish(recoverableStageResult(task, legacyStatus, shared.instruction, {
        section_index: shared.section_index,
        brief: shared.brief,
        chars: shared.chars,
        missing_signals: shared.missing_signals,
        findings: shared.findings,
      }), 0, args.json);
    }
    return finish({ status: legacyStatus, ...shared }, 0, args.json);
  }
  const text = fs.readFileSync(briefFile, 'utf8').trim();
  const freshnessRel = String(shared.freshness_sidecar || '');
  const coverageRel = String(shared.outline_coverage_sidecar || '');

  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/${stageId}.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  if (!packetFile) return finish({ status: 'blocked_result_packet_path_unsafe', path: packetRel }, 2, args.json);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: stageId,
    step_id: stageId,
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: [briefRel, freshnessRel, coverageRel].filter(Boolean),
    changed_files: [briefRel, freshnessRel, coverageRel, resolveShortStateRelative(root, 'project-state.json', { forWrite: true })].filter(Boolean),
    created_files: [freshnessRel, coverageRel].filter(Boolean),
    evidence: [{
      brief: briefRel,
      section_index: sectionIndex,
      chars: text.length,
      freshness: freshnessRel ? 'snapshot_written' : 'unknown',
      outline_contract_digest: shared.outline_contract_digest,
      section_block_digest: shared.section_block_digest,
      outline_obligations: shared.outline_obligations,
      outline_coverage_mode: shared.outline_coverage_mode,
      outline_coverage_sidecar: coverageRel,
    }],
    verification_result: 'pass',
    blocking_findings: [],
    checkpoint_state: { current_stage: stageId, completed_range: `第${sectionIndex}节写作提要`, remaining_range: `第${sectionIndex}节正文`, resume_from: nextDraftStage(task) },
    output_health_result: 'pass',
    current_section_index: sectionIndex,
    next_stage_id: nextDraftStage(task),
    next_recommendation: `等待用户确认后只写第${sectionIndex}节。`,
    handoff_summary: `第${sectionIndex}节写作提要已验证并绑定当前规划依赖与小节合同。`,
    memory_updates: [],
    result_packet_path: packetRel,
  });
  return applyOrFinish({ root, workflowId, packetFile, packetRel, sectionIndex, args });
}

function nextDraftStage(task) {
  const stageId = String((task.stage_execution || {}).stage_id || task.current_stage || '');
  if (stageId === 'first_section_brief') return 'draft_first_section';
  if (stageId === 'next_section_brief') return 'draft_next_section';
  return 'draft_section';
}

function applyOrFinish({ root, workflowId, packetFile, packetRel, sectionIndex, args }) {
  if (!args.apply) return finish({ status: 'packet_ready', workflow_id: workflowId, section_index: sectionIndex, result_packet: packetRel }, 0, args.json);
  const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile });
  const outcome = classifyWorkflowApply(applied);
  const result = outcome.result;
  let projectStateProjection = null;
  if (outcome.applied) projectStateProjection = writeBriefReadyProjectState(root, sectionIndex, packetRel);
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    section_index: sectionIndex,
    result_packet: packetRel,
    next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''),
    project_state_projection: projectStateProjection,
    ...outcome.presentation,
    apply_result: outcome.applied ? undefined : {
      status: String(result.status || 'unknown'),
      findings: Array.isArray(result.findings) ? result.findings.slice(0, 4) : [],
      message: String(result.message || ''),
    },
  }, outcome.exitCode, args.json);
}
function writeBriefReadyProjectState(root, sectionIndex, resultPacket = '') {
  const relativePath = resolveShortStateRelative(root, 'project-state.json', { forWrite: true });
  const file = shortStateFile(root, 'project-state.json', { forWrite: true });
  const current = readJson(file) || {};
  atomicWriteJson(file, {
    ...current,
    status: `section_${String(sectionIndex).padStart(3, '0')}_brief_ready`,
    current_stage: 'section_draft_ready',
    current_section_index: Number(sectionIndex),
    latest_brief: `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`,
    latest_brief_result_packet: String(resultPacket || ''),
    updated_at: new Date().toISOString(),
  });
  return { status: 'project_state_updated', path: relativePath, section_index: Number(sectionIndex) };
}

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', brief: '', apply: false, json: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++i] || '';
    else if (arg === '--brief') args.brief = argv[++i] || '';
    else if (arg === '--apply' || arg === '--write') args.apply = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else usage(`unknown argument: ${arg}`);
  }
  return args;
}

function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file.startsWith(`${root}${path.sep}`) ? file : ''; }


function registerBriefRevision({ root, task, briefRel, text, briefQuality, apply }) {
  const attemptId = String((((task || {}).stage_execution || {}).stage_attempt_id) || 'brief');
  const safeAttemptId = attemptId.replace(/[^A-Za-z0-9._-]/gu, '_');
  const recordRel = `${String(task.task_dir || '').replace(/\\/gu, '/')}/artifacts/brief-recovery-${safeAttemptId}.json`;
  const recordFile = safeProjectFile(root, recordRel);
  const previous = readJson(recordFile) || {};
  const previousCount = Number(previous.attempt_count || 0);
  const attemptCount = previousCount + 1;
  const exhausted = previousCount >= 1;
  if (apply && recordFile) {
    atomicWriteJson(recordFile, {
      schemaVersion: '1.0.0',
      workflow_id: String(task.workflow_id || ''),
      stage_id: String(task.current_stage || ''),
      stage_attempt_id: attemptId,
      brief: briefRel,
      brief_digest: crypto.createHash('sha256').update(String(text || '')).digest('hex'),
      attempt_count: attemptCount,
      retry_limit: 1,
      status: exhausted ? 'exhausted' : 'revision_required',
      findings: briefQuality.findings,
      updated_at: new Date().toISOString(),
    });
  }
  return { attemptCount, exhausted, recordRel: apply ? recordRel : '' };
}
function registerBriefOverloadChoice({ root, workflowId, briefRel, findings }) {
  const parsed = invokeRunnerCommand({
    command: 'register-short-brief-overload',
    projectRoot: root,
    workflowId,
    scope: briefRel,
    reason: (Array.isArray(findings) ? findings : []).join('|'),
  });
  return parsed && String(parsed.status || '') === 'workflow_choice_required' ? parsed : null;
}
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-section-brief-finalize.js --project-root <book> --workflow-id <id> [--brief file] [--apply] [--json]\n`); process.exit(2); }
function printHelp() { process.stdout.write('Usage: node short-section-brief-finalize.js --project-root <book> --workflow-id <id> [--brief file] [--apply] [--json]\n'); return 0; }

if (require.main === module) process.exitCode = main();

module.exports = { analyzeBriefQuality, countCausalBeats, evidenceMechanismCount, plannedTargetChars, sectionResponsibilityCount, writeBriefReadyProjectState };
