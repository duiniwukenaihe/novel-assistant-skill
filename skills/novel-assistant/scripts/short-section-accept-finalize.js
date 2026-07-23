#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferShortSectionIndex, resolvePlannedSectionCount, resolveShortPlanProgress } = require('./lib/short-workflow-state');
const { deriveSectionLengthPolicy } = require('./lib/short-section-length-policy');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { commitAcceptedSection } = require('./lib/short-section-commit-store');
const { appendIntegrationEvent } = require('./lib/integration-outbox');
const { checkShortMemoryStage } = require('./lib/short-memory-stage-policy');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  const task = authority.task;
  if (String(task.current_stage || '') !== 'section_accept_anchor') return finish({ status: 'stage_action_not_applicable', expected: 'section_accept_anchor', actual: task.current_stage || '', instruction: '重新读取当前任务的 execution_command；不要重试旧阶段命令。' }, 0, args.json);
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'section_accept_anchor') {
    return finish({ status: 'stage_execution_not_ready', workflow_id: workflowId, instruction: '先由工作流启动采用阶段，再运行本命令。' }, 0, args.json);
  }

  const projectStateFile = path.join(root, '追踪/private-short-extension/project-state.json');
  const projectState = readJson(projectStateFile) || {};
  const sectionIndex = inferShortSectionIndex({ projectState, stageId: 'section_accept_anchor', scope: String(task.scope || '') });
  if (!sectionIndex) return finish({ status: 'blocked_short_section_identity_missing', instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复当前小节，不得默认写入第1节。' }, 0, args.json);
  const memoryGate = checkShortMemoryStage({ projectRoot: root, task, execution, sectionIndex, stageId: 'section_accept_anchor' });
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
  const metadataFile = safeProjectFile(root, args.metadata || `${task.task_dir}/artifacts/section-${String(sectionIndex).padStart(3, '0')}-acceptance.json`);
  let metadata = readJson(metadataFile);

  const machine = readStageResult(root, task, 'section_machine_gate', sectionIndex);
  const quality = readStageResult(root, task, 'story_value_gate', sectionIndex) || readStageResult(root, task, 'quality_gate', sectionIndex);
  const canonicalRel = args.canonical || firstExistingOutput(root, quality) || '正文.md';
  const canonicalFile = safeProjectFile(root, canonicalRel);
  if (!canonicalFile || !fs.existsSync(canonicalFile)) return finish({ status: 'short_canonical_missing', canonical_path: canonicalRel, instruction: '恢复当前节候选稿后重新运行机器门；不要创建空正文。' }, 0, args.json);
  const canonicalDigest = `sha256:${sha256File(canonicalFile)}`;
  const receiptIssue = validateGateReceipts({ root, machine, quality, canonicalRel, canonicalDigest });
  if (!gatePassed(machine, 'machine') || !gatePassed(quality, 'quality') || receiptIssue) {
    return rerunMachineGate({ root, workflowId, receiptIssue: receiptIssue || 'quality_receipt_not_passed', args });
  }
  const canonicalText = fs.readFileSync(canonicalFile, 'utf8');
  const sectionText = extractSection(canonicalText, sectionIndex);
  if (!sectionText.trim()) return finish({ status: 'short_section_binding_missing', canonical_path: canonicalRel, section_index: sectionIndex, instruction: '候选稿未绑定当前节，返回当前节草稿阶段检查目标文件。' }, 0, args.json);
  const currentSectionChars = (sectionText.match(/[\u3400-\u9fff]/g) || []).length;
  if (!metadata || String(metadata.source_digest || '') !== canonicalDigest || positiveInt(metadata.section_cjk_chars) !== currentSectionChars) {
    metadata = deriveAcceptanceMetadata({ root, sectionIndex, sectionText, quality, projectState });
    metadata.source_digest = canonicalDigest;
    atomicWriteJson(metadataFile, metadata);
  }
  const cjkChars = currentSectionChars;
  const lengthPolicy = deriveSectionLengthPolicy({ projectState, sectionIndex, actual: cjkChars, sectionRole: metadata.section_role || 'normal', exceptionReason: metadata.exception_reason || '' });
  if (lengthPolicy.blocking) return rerunMachineGate({ root, workflowId, receiptIssue: 'short_length_policy_requires_revision', lengthPolicy, args });

  const titleLock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const outlineText = readText(path.join(root, '小节大纲.md'));
  const plan = resolvePlannedSectionCount({ projectState, titleLock, outlineText });
  if (plan.status !== 'locked') {
    return finish({
      status: plan.status === 'conflict' ? 'short_section_plan_conflict' : 'short_section_plan_missing',
      section_index: sectionIndex,
      plan_evidence: plan.candidates,
      instruction: plan.status === 'conflict'
        ? '小节大纲、标题锁与项目状态的总节数不一致；先确认全篇小节数，再继续采用。'
        : '未找到已锁定的全篇小节数；先补齐小节大纲和标题锁，禁止自动生成下一节。',
    }, 0, args.json);
  }
  if (sectionIndex > plan.count) {
    return finish({ status: 'short_section_outside_plan', section_index: sectionIndex, planned_sections: plan.count, instruction: '当前小节超出已确认的全篇规划；必须先扩容小节大纲，不能直接采用。' }, 0, args.json);
  }

  const proposedAcceptedSections = upsertAccepted(projectState.accepted_sections, { section_index: sectionIndex });
  const proposedProgress = resolveShortPlanProgress({ plannedCount: plan.count, acceptedSections: proposedAcceptedSections, currentSection: sectionIndex });
  const missingBeforeCurrent = (proposedProgress.missing_sections || []).filter((index) => index < sectionIndex);
  if (proposedProgress.status === 'outside_plan' || missingBeforeCurrent.length) {
    return finish({
      status: proposedProgress.status === 'outside_plan' ? 'short_section_outside_plan' : 'short_section_plan_gap',
      section_index: sectionIndex,
      planned_sections: plan.count,
      missing_sections: missingBeforeCurrent,
      instruction: missingBeforeCurrent.length
        ? '当前节存在尚未采用的前置小节；正式正文没有写入。先补齐缺口或重新规划小节顺序。'
        : '当前节超出已确认规划；正式正文没有写入。先调整小节大纲。',
    }, 0, args.json);
  }

  const confirmedSectionTitle = resolveConfirmedSectionTitle(root, sectionIndex, metadata);
  let sectionCommit;
  try {
    sectionCommit = commitAcceptedSection(root, {
      task,
      sectionIndex,
      title: confirmedSectionTitle.title,
      text: sectionText,
      metadata,
      projectTitle: String(projectState.project_title || projectState.title || ''),
    });
  } catch (error) {
    return finish({
      status: String((error || {}).status || 'short_section_commit_blocked'),
      section_index: sectionIndex,
      instruction: '当前节未写入正式小节，项目进度未推进。修复提交条件后重试本阶段即可，不要重写已经通过质量门的候选稿。',
      detail: String((error || {}).message || error || ''),
    }, 0, args.json);
  }
  const acceptedCanonicalRel = String(sectionCommit.canonical_path || '');
  const canonicalHash = String(sectionCommit.canonical_sha256 || '');
  const anchorRel = `追踪/private-short-extension/section-${String(sectionIndex).padStart(3, '0')}-anchor.json`;
  const anchorFile = safeProjectFile(root, anchorRel);
  const acceptedSections = upsertAccepted(projectState.accepted_sections, {
    section_index: sectionIndex,
    title: confirmedSectionTitle.title,
    canonical_path: acceptedCanonicalRel,
    anchor_path: anchorRel,
    sha256: canonicalHash,
    section_commit_id: String(sectionCommit.commit_id || ''),
    length_chars: cjkChars,
    quality_status: 'machine_and_story_gates_passed',
  });
  const progress = resolveShortPlanProgress({ plannedCount: plan.count, acceptedSections, currentSection: sectionIndex });
  if (progress.status === 'outside_plan') {
    return finish({ status: 'short_section_outside_plan', section_index: sectionIndex, planned_sections: plan.count, instruction: '已采用小节超出全篇规划；先修复项目状态，禁止继续生成 Brief。' }, 0, args.json);
  }
  if (!progress.completed && !progress.next_section) {
    return finish({ status: 'short_section_plan_gap', section_index: sectionIndex, planned_sections: plan.count, missing_sections: progress.missing_sections, instruction: '已采用小节存在前置缺口；先补齐或明确跳过缺失小节，禁止生成计划外下一节。' }, 0, args.json);
  }
  const allCompleted = progress.completed;
  const remainingSections = progress.missing_sections;
  const anchor = {
    schema_version: '1.0.0', workflow_id: workflowId, project_id: String(projectState.project_id || ''),
    section_index: sectionIndex, section_title: confirmedSectionTitle.title, section_title_confirmed: confirmedSectionTitle.confirmed, status: 'accepted',
    canonical_path: acceptedCanonicalRel, canonical_sha256: canonicalHash, section_commit_id: String(sectionCommit.commit_id || ''),
    stage_attempt_id: String(execution.stage_attempt_id || ''), section_cjk_chars: cjkChars, accepted_at: new Date().toISOString(),
    section_summary: String(metadata.section_summary || '').slice(0, 800),
    revealed_information: stringArray(metadata.revealed_information), character_state: objectValue(metadata.character_state),
    relationship_state: objectValue(metadata.relationship_state), decisions: stringArray(metadata.decisions),
    knowledge_state: objectValue(metadata.knowledge_state), world_state: objectValue(metadata.world_state),
    present_characters: stringArray(metadata.present_characters), causal_links: arrayValue(metadata.causal_links),
    promise_deltas: arrayValue(metadata.promise_deltas), protagonist: String(metadata.protagonist || ''),
    open_hook: String(metadata.open_hook || '').slice(0, 500), style_anchor: stringArray(metadata.style_anchor),
    quality_result: { machine_gate: 'pass', story_value_gate: 'pass', quality_gate: 'pass', repetition_gate: 'pass', blocking_findings: [], length_policy: lengthPolicy },
    memory_basis: { status: memoryGate.memory_status, receipt: memoryGate.receipt },
    next_section_handoff: objectValue(metadata.next_section_handoff), remaining_sections: remainingSections,
  };
  atomicWriteJson(anchorFile, anchor);
  let integrationEvent;
  try {
    integrationEvent = appendIntegrationEvent(root, {
      event_type: 'section_accepted',
      workflow_id: workflowId,
      project_id: String(projectState.project_id || ''),
      project_title: String(projectState.project_title || projectState.title || ''),
      artifact_path: acceptedCanonicalRel,
      artifact_digest: canonicalHash,
      summary: String(metadata.section_summary || `第${sectionIndex}节已采用`).slice(0, 1000),
      tags: ['short_write', `section_${String(sectionIndex).padStart(3, '0')}`],
    });
  } catch (error) {
    integrationEvent = { status: 'deferred', message: String(error.message || error) };
  }

  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/section_accept_anchor.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId, workflow_type: String(task.workflow_type || 'short_write'), stage_id: 'section_accept_anchor', step_id: 'section_accept_anchor',
    owner_module: String(execution.owner_module || task.workflow_owner || ''), step_status: 'completed', outputs: [acceptedCanonicalRel, anchorRel],
    changed_files: [acceptedCanonicalRel, anchorRel, ...(integrationEvent.status === 'appended' ? ['追踪/integration/outbox.jsonl'] : [])], created_files: [acceptedCanonicalRel, anchorRel],
    evidence: [{ section_index: sectionIndex, section_commit_id: String(sectionCommit.commit_id || ''), canonical_sha256: canonicalHash, cjk_chars: cjkChars, machine_gate: 'pass', story_value_gate: 'pass', integration_event: integrationEvent.status }],
    verification_result: 'pass', blocking_findings: [], output_health_result: 'pass',
    section_acceptance: {
      workflow_id: workflowId,
      section_index: sectionIndex,
      section_title: confirmedSectionTitle.title,
      anchor_path: anchorRel,
      canonical_path: acceptedCanonicalRel,
      canonical_sha256: canonicalHash,
      section_commit_id: String(sectionCommit.commit_id || ''),
      length_chars: cjkChars,
      quality_status: 'machine_and_story_gates_passed',
    },
    current_section_index: sectionIndex, planned_sections: plan.count, remaining_sections: remainingSections, all_sections_completed: allCompleted,
    checkpoint_state: { current_stage: 'section_accept_anchor', completed_range: `第${sectionIndex}节已采用`, remaining_range: allCompleted ? '全篇组装' : `第${progress.next_section}节 Brief`, resume_from: allCompleted ? 'full_story_assembly' : 'next_section_brief' },
    next_stage_id: allCompleted ? 'full_story_assembly' : 'next_section_brief', next_recommendation: allCompleted ? '进入全篇组装。' : `自动生成第${progress.next_section}节 Brief，写正文前停靠。`,
    handoff_summary: `第${sectionIndex}节已采用；机器门、故事门和篇幅门通过。`,
    memory_updates: [],
    memory_read_receipt_status: memoryGate.memory_status,
    memory_read_receipt: memoryGate.receipt,
    integration_event: integrationEvent,
    section_memory_projection: { status: String(sectionCommit.projection_status || ''), commit_id: String(sectionCommit.commit_id || '') },
    result_packet_path: packetRel,
  });
  return applyOrFinish({ root, workflowId, packetFile, packetRel, sectionIndex, allCompleted, args });
}

function extractSection(text, sectionIndex) {
  const lines = String(text || '').split(/\r?\n/);
  const headings = [];
  for (let i = 0; i < lines.length; i += 1) if (/^#{1,6}\s+/.test(lines[i].trim())) headings.push(i);
  if (headings.length <= 1) return String(text || '');
  const offset = Math.min(Math.max(sectionIndex - 1, 0), headings.length - 1);
  return lines.slice(headings[offset] + 1, headings[offset + 1] === undefined ? lines.length : headings[offset + 1]).join('\n');
}
function deriveAcceptanceMetadata({ root, sectionIndex, sectionText, quality, projectState }) {
  const paragraphs = String(sectionText || '').split(/\n\s*\n/).map((item) => item.trim()).filter(Boolean);
  const briefText = readText(path.join(root, `写作Brief_第${String(sectionIndex).padStart(3, '0')}节.md`));
  const viewpointLocks = markdownBullets(briefText, '视角与称谓');
  const explicitMetadata = ((quality || {}).acceptance_metadata && typeof (quality || {}).acceptance_metadata === 'object')
    ? (quality || {}).acceptance_metadata
    : {};
  const openHook = (String(explicitMetadata.open_hook || '').trim() || paragraphs.slice(-2).join('\n\n')).slice(-500);
  const qualitySummary = String((quality || {}).handoff_summary || '').trim();
  const genericQualitySummary = /角色、因果、情绪、钩子和吸引力通过/u.test(qualitySummary);
  return {
    schema_version: '1.0.0',
    generated_by: 'short-section-accept-finalize',
    section_index: sectionIndex,
    section_title: `第${sectionIndex}节`,
    section_title_confirmed: false,
    section_summary: (!genericQualitySummary && qualitySummary)
      || paragraphs.slice(0, 2).join(' ').slice(0, 800),
    open_hook: openHook,
    section_cjk_chars: (String(sectionText || '').match(/[\u3400-\u9fff]/g) || []).length,
    total_sections: positiveInt((quality || {}).total_sections || ((projectState.narrative || {}).planned_sections) || projectState.total_sections || projectState.planned_sections),
    remaining_sections: projectState.remaining_sections || [],
    revealed_information: stringArray(explicitMetadata.revealed_information),
    present_characters: stringArray(explicitMetadata.present_characters),
    character_state: objectValue(explicitMetadata.character_state),
    relationship_state: objectValue(explicitMetadata.relationship_state),
    knowledge_state: objectValue(explicitMetadata.knowledge_state),
    world_state: objectValue(explicitMetadata.world_state),
    decisions: stringArray(explicitMetadata.decisions),
    causal_links: arrayValue(explicitMetadata.causal_links),
    promise_deltas: arrayValue(explicitMetadata.promise_deltas),
    protagonist: String(explicitMetadata.protagonist || '').trim(),
    style_anchor: viewpointLocks.slice(0, 6),
    next_section_handoff: {
      previous_section: sectionIndex,
      open_hook: openHook,
      carry_forward: stringArray(explicitMetadata.carry_forward).slice(0, 4),
    },
  };
}

function markdownSection(text, heading) {
  const lines = String(text || '').split(/\r?\n/);
  const output = [];
  let active = false;
  for (const line of lines) {
    const match = line.match(/^##\s+(.+?)\s*$/u);
    if (match) {
      if (active) break;
      active = match[1].trim() === heading;
      continue;
    }
    if (active) output.push(line);
  }
  return output.join('\n').trim();
}
function markdownBullets(text, heading) {
  return markdownSection(text, heading)
    .split(/\r?\n/)
    .map((line) => line.trim().replace(/^[-*]\s+/u, ''))
    .filter((line) => line && !/^#{1,6}\s+/u.test(line))
    .slice(0, 24);
}
function resolveConfirmedSectionTitle(root, sectionIndex, metadata) {
  const lock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const item = (Array.isArray(lock.sections) ? lock.sections : []).find((entry) => Number((entry || {}).section_index) === sectionIndex);
  if (item && item.confirmed === true) {
    return { title: String(item.title || '').trim() || `第${sectionIndex}节`, confirmed: true };
  }
  if (metadata.section_title_confirmed === true && String(metadata.section_title || '').trim()) {
    return { title: String(metadata.section_title).trim(), confirmed: true };
  }
  return { title: `第${sectionIndex}节`, confirmed: false };
}
function readStageResult(root, task, stageId, sectionIndex) {
  const packetDir = path.join(root, `${task.task_dir}/result-packets`);
  const unitFile = path.join(packetDir, `${stageId}.section-${String(sectionIndex).padStart(3, '0')}.result.json`);
  return readJson(unitFile) || readJson(path.join(packetDir, `${stageId}.result.json`));
}
function gatePassed(result, type) { if (!result || Array.isArray(result.blocking_findings) && result.blocking_findings.length) return false; const values = [result.verification_result, result.output_health_result, type === 'machine' ? result.machine_gate_result : result.story_value_result || result.quality_gate_result]; return values.some((value) => /^(pass|passed|accepted|approved|ok)$/i.test(String(value || ''))); }
function gateStatus(result) { return result ? String(result.verification_result || result.machine_gate_result || result.story_value_result || result.quality_gate_result || 'unknown') : 'missing'; }
function validateGateReceipts({ root, machine, quality, canonicalRel, canonicalDigest }) {
  const machineDigest = String((machine || {}).draft_digest || machineArtifactDigest(root, machine) || '');
  const qualityDigest = String((quality || {}).draft_digest || ((((quality || {}).evidence || [])[0] || {}).draft_digest) || '');
  const machineDraft = firstProseOutput(machine);
  const qualityDraft = firstProseOutput(quality);
  if (!machineDigest || !qualityDigest) return 'gate_receipt_digest_missing';
  if (machineDigest !== canonicalDigest || qualityDigest !== canonicalDigest) return 'candidate_changed_after_quality_gate';
  if ((machineDraft && machineDraft !== canonicalRel) || (qualityDraft && qualityDraft !== canonicalRel)) return 'gate_receipt_candidate_mismatch';
  return '';
}
function firstProseOutput(result) { return ((result || {}).outputs || []).map(String).find((item) => /\.md$/u.test(item)) || ''; }
function machineArtifactDigest(root, result) {
  const artifactRel = ((result || {}).outputs || []).map(String).find((item) => /machine-gate\.json$/u.test(item)) || '';
  return String((readJson(safeProjectFile(root, artifactRel)) || {}).draft_digest || '');
}
function rerunMachineGate({ root, workflowId, receiptIssue, lengthPolicy, args }) {
  const run = spawnSync(process.execPath, [
    path.join(__dirname, 'short-section-machine-gate.js'),
    '--project-root', root, '--workflow-id', workflowId, '--recheck-policy', '--apply', '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const result = parseJson(run.stdout) || {};
  const revisionRequired = String(result.gate_status || '') === 'blocking' || String(result.next_stage || '') === 'section_repair_loop';
  return finish({
    status: revisionRequired ? 'short_section_revision_required' : 'short_section_revalidation_started',
    workflow_id: workflowId,
    reason: receiptIssue,
    length_policy: lengthPolicy || result.length_policy || null,
    next_stage: String(result.next_stage || ''),
    next_command: String(result.next_command || ''),
    instruction: revisionRequired
      ? '当前候选稿尚未通过最新机器门，已自动回到本节修订流程；修订后重新过双门，再显示四项采用菜单。'
      : '候选稿或门禁回执发生变化，已自动重新执行机器门；通过故事质量门后再显示四项采用菜单。',
  }, 0, args.json);
}
function firstExistingOutput(root, result) { for (const item of ((result || {}).outputs || [])) { const file = safeProjectFile(root, item); if (file && fs.existsSync(file)) return String(item); } return ''; }
function upsertAccepted(items, value) { const rows = Array.isArray(items) ? items.filter((item) => Number((item || {}).section_index) !== value.section_index) : []; rows.push(value); return rows.sort((a, b) => Number(a.section_index) - Number(b.section_index)); }
function normalizeRemaining(value, sectionIndex, total) { const rows = Array.isArray(value) ? value.map(Number).filter((n) => Number.isInteger(n) && n > sectionIndex) : []; if (rows.length) return [...new Set(rows)].sort((a, b) => a - b); return total > sectionIndex ? Array.from({ length: total - sectionIndex }, (_, i) => sectionIndex + i + 1) : []; }
function stringArray(value) { return Array.isArray(value) ? value.map(String).filter(Boolean).slice(0, 20) : []; }
function objectValue(value) { return value && typeof value === 'object' && !Array.isArray(value) ? value : {}; }
function arrayValue(value) { return Array.isArray(value) ? value.slice(0, 24) : []; }
function positiveInt(value) { const n = Number(value); return Number.isInteger(n) && n > 0 ? n : 0; }
function sha256File(file) { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'); }
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file.startsWith(`${root}${path.sep}`) ? file : ''; }
function relative(root, file) { return file ? path.relative(root, file).split(path.sep).join('/') : ''; }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
function applyOrFinish({ root, workflowId, packetFile, packetRel, sectionIndex, allCompleted, args }) { if (!args.apply) return finish({ status: 'packet_ready', workflow_id: workflowId, section_index: sectionIndex, result_packet: packetRel }, 0, args.json); const applied = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json'], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 }); const outcome = classifyWorkflowApply(applied); const result = outcome.result; return finish({ status: outcome.applied ? 'applied' : 'apply_blocked', workflow_status: outcome.workflowStatus, workflow_id: workflowId, section_index: sectionIndex, all_sections_completed: allCompleted, result_packet: packetRel, next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''), ...outcome.presentation, ...(outcome.applied ? {} : { recovery: result }) }, outcome.exitCode, args.json); }
function parseArgs(argv) { const args = { projectRoot: '', workflowId: '', metadata: '', canonical: '', apply: false, json: false, help: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') args.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') args.workflowId = argv[++i] || ''; else if (arg === '--metadata') args.metadata = argv[++i] || ''; else if (arg === '--canonical') args.canonical = argv[++i] || ''; else if (arg === '--apply' || arg === '--write') args.apply = true; else if (arg === '--json') args.json = true; else if (arg === '--help' || arg === '-h') args.help = true; else usage(`unknown argument: ${arg}`); } return args; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-section-accept-finalize.js --project-root <book> --workflow-id <id> --metadata <json> [--canonical file] [--apply] [--json]\n`); process.exit(2); }
function printHelp() { process.stdout.write('Usage: node short-section-accept-finalize.js --project-root <book> --workflow-id <id> [--metadata file] [--canonical file] [--apply] [--json]\n'); return 0; }

process.exitCode = main();
