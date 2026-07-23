#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply, recoverableStageResult } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferShortSectionIndex } = require('./lib/short-workflow-state');
const { writeBriefFreshnessSnapshot } = require('./lib/short-brief-freshness');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { ensureShortProjectState } = require('./lib/short-project-state');
const {
  buildShortSectionOutlineContract,
  renderOutlineCoverageTemplate,
  validateBriefOutlineCoverage,
} = require('./lib/short-section-outline-contract');

const BRIEF_STAGES = new Set(['first_section_brief', 'section_brief', 'next_section_brief']);
const REQUIRED_SIGNALS = ['视角', '人物', '因果', '钩子', '禁止', '验收'];

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  const task = authority.task;
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
  const sectionIndex = inferShortSectionIndex({ projectState, stageId, scope: String(task.scope || '') });
  if (!sectionIndex) return finish({ status: 'blocked_short_section_identity_missing', instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复小节范围，不得默认生成第1节 Brief。' }, 0, args.json);
  const titleLock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const titleEntry = (Array.isArray(titleLock.sections) ? titleLock.sections : []).find((item) => Number((item || {}).section_index) === sectionIndex);
  if (!titleEntry || titleEntry.confirmed !== true) {
    return finish({
      status: 'short_section_title_confirmation_required',
      section_index: sectionIndex,
      message: `第${sectionIndex}节标题尚未经用户在全篇小节大纲阶段确认，禁止 Brief 自行命名。`,
      preview_command: `node scripts/short-section-title-lock.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(workflowId)} --json`,
    }, 0, args.json);
  }
  if (String(titleLock.workflow_id || '') !== workflowId
      || String(titleLock.project_id || '') !== String(projectState.project_id || '')
      || Number(titleLock.plan_revision || 0) !== Number(projectState.plan_revision || 0)) {
    return finish({
      status: 'short_section_title_lock_stale',
      section_index: sectionIndex,
      workflow_id: workflowId,
      message: '标题清单不属于当前作品规划版本，必须重新展示并确认后再生成 Brief。',
      preview_command: `node scripts/short-section-title-lock.js --project-root ${JSON.stringify(root)} --workflow-id ${JSON.stringify(workflowId)} --json`,
    }, 0, args.json);
  }
  const briefRel = args.brief || `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`;
  const briefFile = safeProjectFile(root, briefRel);
  if (!briefFile || !fs.existsSync(briefFile)) return finish({ status: 'awaiting_short_brief', brief: briefRel, instruction: '只生成当前节写作提要，然后重新运行本命令。' }, 0, args.json);
  const text = fs.readFileSync(briefFile, 'utf8').trim();
  const missingSignals = REQUIRED_SIGNALS.filter((signal) => !text.includes(signal));
  if (text.length < 240 || missingSignals.length > 2) {
    return finish(recoverableStageResult(task, 'short_brief_revision_required', '只补齐当前写作提要缺失部分一次；不要读取全篇或进入正文。', { brief: briefRel, chars: text.length, missing_signals: missingSignals }), 0, args.json);
  }
  const outlineContract = buildShortSectionOutlineContract(root, sectionIndex);
  if (outlineContract.status !== 'current') {
    return finish({
      status: 'short_outline_contract_required',
      section_index: sectionIndex,
      finding: outlineContract.code || 'outline_contract_missing',
      instruction: '先回到小节大纲补足本节结构功能、子事件与节尾钩子；不得让 Brief 或正文临场补剧情。',
    }, 0, args.json);
  }
  const outlineCoverage = validateBriefOutlineCoverage(text, outlineContract);
  if (outlineCoverage.status !== 'pass') {
    return finish({
      status: 'short_brief_outline_drift',
      section_index: sectionIndex,
      brief: briefRel,
      outline_contract_digest: outlineContract.contract_digest,
      findings: outlineCoverage.findings,
      required_template: renderOutlineCoverageTemplate(outlineContract),
      instruction: '当前写作提要漏写或改写了已确认大纲。只重建本节 Brief：逐项保留大纲义务并映射到因果动作链；不得进入正文。',
    }, 0, args.json);
  }
  const briefQuality = analyzeBriefQuality(text);
  if (briefQuality.status !== 'pass') {
    const recovery = registerBriefRevision({ root, task, briefRel, text, briefQuality, apply: args.apply });
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

  const acceptedAnchor = sectionIndex > 1
    ? `追踪/private-short-extension/section-${String(sectionIndex - 1).padStart(3, '0')}-anchor.json`
    : '';
  const freshness = writeBriefFreshnessSnapshot({ projectRoot: root, briefPath: briefRel, sectionIndex, acceptedAnchorPath: acceptedAnchor });
  if (freshness.status !== 'snapshot_written') return finish({ status: 'short_brief_dependencies_changed', freshness, instruction: '规划依赖已变化，重新生成当前节写作提要。' }, 0, args.json);

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
    outputs: [briefRel, freshness.sidecar],
    changed_files: [briefRel, freshness.sidecar, '追踪/private-short-extension/project-state.json'],
    created_files: [freshness.sidecar],
    evidence: [{
      brief: briefRel,
      section_index: sectionIndex,
      chars: text.length,
      freshness: freshness.status,
      outline_contract_digest: outlineContract.contract_digest,
      section_block_digest: outlineContract.section_block_digest,
      outline_obligations: outlineContract.obligations.map((item) => item.id),
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
  const applied = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
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
  const file = safeProjectFile(root, '追踪/private-short-extension/project-state.json');
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
  return { status: 'project_state_updated', path: '追踪/private-short-extension/project-state.json', section_index: Number(sectionIndex) };
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
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
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
  return {
    status: findings.length ? 'blocking' : 'pass',
    target_chars: targetChars,
    brief_chars: compactChars,
    dynamic_brief_budget: briefBudget,
    beat_count: beatCount,
    dynamic_beat_budget: beatBudget,
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
function plannedTargetChars(text) {
  const normalized = String(text || '').replace(/[，,]/gu, '');
  const range = normalized.match(/目标\s*([0-9]+)\s*(?:-|~|至|到)\s*([0-9]+)\s*(?:个)?中文/u);
  if (range) return Math.round((Number(range[1]) + Number(range[2])) / 2);
  const single = normalized.match(/(?:目标(?:字数)?|本节目标)\s*[:：=]?\s*([0-9]+)\s*(?:个)?中文/u);
  return single ? Number(single[1]) : 0;
}
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-section-brief-finalize.js --project-root <book> --workflow-id <id> [--brief file] [--apply] [--json]\n`); process.exit(2); }
function printHelp() { process.stdout.write('Usage: node short-section-brief-finalize.js --project-root <book> --workflow-id <id> [--brief file] [--apply] [--json]\n'); return 0; }

if (require.main === module) process.exitCode = main();

module.exports = { analyzeBriefQuality, countCausalBeats, plannedTargetChars, writeBriefReadyProjectState };
