#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferShortSectionIndex } = require('./lib/short-workflow-state');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { ensureCurrentShortMemoryStage } = require('./lib/short-memory-stage-recovery');
const { readShortProjectState } = require('./lib/short-project-state');
const { acceptSection } = require('./lib/short-production/section-loop');
const { invokeApplyResult, invokeResolveAction } = require('./lib/workflow-state-machine-invoke');
const { readJson, parseJson } = require('./lib/cli-utils');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  let task = authority.task;
  if (Number(task.engine_version) === 3) return finish({ status: 'v3_engine_apply_required', workflow_id: workflowId, instruction: 'V3 任务必须直接调用共享 service，并通过 V3 Engine 应用 StageResult。' }, 2, args.json);
  if (String(task.current_stage || '') !== 'section_accept_anchor') return finish({ status: 'stage_action_not_applicable', expected: 'section_accept_anchor', actual: task.current_stage || '', instruction: '重新读取当前任务的 execution_command；不要重试旧阶段命令。' }, 0, args.json);
  let execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'section_accept_anchor') {
    return finish({ status: 'stage_execution_not_ready', workflow_id: workflowId, instruction: '先由工作流启动采用阶段，再运行本命令。' }, 0, args.json);
  }

  const projectState = readShortProjectState(root) || {};
  const sectionIndex = inferShortSectionIndex({ projectState, stageId: 'section_accept_anchor', scope: String(task.scope || '') });
  if (!sectionIndex) return finish({ status: 'blocked_short_section_identity_missing', instruction: '当前任务没有可靠的小节身份；先由 workflow 恢复当前小节，不得默认写入第1节。' }, 0, args.json);
  const memoryGate = ensureCurrentShortMemoryStage({ projectRoot: root, workflowId, task, execution, sectionIndex, stageId: 'section_accept_anchor' });
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
  const metadataFile = safeProjectFile(root, args.metadata || `${task.task_dir}/artifacts/section-${String(sectionIndex).padStart(3, '0')}-acceptance.json`);
  const metadata = readJson(metadataFile) || null;
  const shared = acceptSection({
    projectRoot: root,
    task: {
      ...task,
      current_stage: 'section_accept',
      stage_execution: { ...execution, stage_id: 'section_accept', section_index: sectionIndex },
    },
    draft: args.canonical,
    metadata,
    memoryBasis: { status: memoryGate.memory_status, receipt: memoryGate.receipt },
  });
  if (shared.kind !== 'completed') {
    if (/^accept_/u.test(String(shared.code || ''))) {
      return rerunMachineGate({ root, workflowId, receiptIssue: shared.code, args });
    }
    return finish({
      status: shared.code === 'short_section_identity_missing'
        ? 'blocked_short_section_identity_missing'
        : shared.code,
      workflow_id: workflowId,
      section_index: shared.section_index || sectionIndex,
      expected_section: shared.expected_section,
      planned_sections: shared.planned_sections,
      missing_sections: shared.missing_sections,
      instruction: shared.instruction,
      detail: shared.detail,
    }, 0, args.json);
  }
  const acceptedCanonicalRel = String(shared.canonical_path || '');
  const canonicalHash = String(shared.canonical_sha256 || '');
  const anchorRel = String(shared.anchor_path || '');
  const allCompleted = shared.all_sections_completed === true;
  const remainingSections = Array.isArray(shared.remaining_sections) ? shared.remaining_sections : [];
  const nextSection = Number(shared.next_section || 0) || null;
  const integrationEvent = shared.integration_event || { status: 'unchanged' };
  const lengthPolicy = shared.length_policy || {};

  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/section_accept_anchor.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId, workflow_type: String(task.workflow_type || 'short_write'), stage_id: 'section_accept_anchor', step_id: 'section_accept_anchor',
    owner_module: String(execution.owner_module || task.workflow_owner || ''), step_status: 'completed', outputs: [acceptedCanonicalRel, anchorRel],
    changed_files: [acceptedCanonicalRel, anchorRel, ...(integrationEvent.status === 'appended' ? ['追踪/integration/outbox.jsonl'] : [])], created_files: [acceptedCanonicalRel, anchorRel],
    evidence: [{ section_index: sectionIndex, section_commit_id: String(shared.commit_id || ''), canonical_sha256: canonicalHash, machine_gate: 'pass', story_value_gate: 'pass', integration_event: integrationEvent.status }],
    verification_result: 'pass', blocking_findings: [], output_health_result: 'pass',
    section_acceptance: {
      workflow_id: workflowId,
      section_index: sectionIndex,
      section_title: shared.section_title,
      anchor_path: anchorRel,
      canonical_path: acceptedCanonicalRel,
      canonical_sha256: canonicalHash,
      section_commit_id: String(shared.commit_id || ''),
      quality_status: 'machine_and_story_gates_passed',
    },
    current_section_index: sectionIndex, planned_sections: shared.planned_sections, remaining_sections: remainingSections, all_sections_completed: allCompleted,
    checkpoint_state: { current_stage: 'section_accept_anchor', completed_range: `第${sectionIndex}节已采用`, remaining_range: allCompleted ? '全篇组装' : `第${nextSection}节 Brief`, resume_from: allCompleted ? 'full_story_assembly' : 'next_section_brief' },
    next_stage_id: allCompleted ? 'full_story_assembly' : 'next_section_brief', next_recommendation: allCompleted ? '进入全篇组装。' : `自动生成第${nextSection}节 Brief，写正文前停靠。`,
    handoff_summary: `第${sectionIndex}节已采用；机器门和故事门通过${lengthPolicy.verdict === 'outside_story_band_deferred' ? '，篇幅偏差已记录并留待整篇收束' : ''}。`,
    memory_updates: [],
    memory_read_receipt_status: memoryGate.memory_status,
    memory_read_receipt: memoryGate.receipt,
    integration_event: integrationEvent,
    section_memory_projection: { status: String(shared.projection_status || ''), commit_id: String(shared.commit_id || '') },
    result_packet_path: packetRel,
  });
  return applyOrFinish({ root, workflowId, packetFile, packetRel, sectionIndex, allCompleted, args });
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
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file.startsWith(`${root}${path.sep}`) ? file : ''; }


function applyOrFinish({ root, workflowId, packetFile, packetRel, sectionIndex, allCompleted, args }) { if (!args.apply) return finish({ status: 'packet_ready', workflow_id: workflowId, section_index: sectionIndex, result_packet: packetRel }, 0, args.json); const applied = invokeApplyResult({ projectRoot: root, workflowId: workflowId, resultFile: packetFile }); const outcome = classifyWorkflowApply(applied); const result = outcome.result; return finish({ status: outcome.applied ? 'applied' : 'apply_blocked', workflow_status: outcome.workflowStatus, workflow_id: workflowId, section_index: sectionIndex, all_sections_completed: allCompleted, result_packet: packetRel, next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''), ...outcome.presentation, ...(outcome.applied ? {} : { recovery: result }) }, outcome.exitCode, args.json); }
function parseArgs(argv) { const args = { projectRoot: '', workflowId: '', metadata: '', canonical: '', apply: false, json: false, help: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') args.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') args.workflowId = argv[++i] || ''; else if (arg === '--metadata') args.metadata = argv[++i] || ''; else if (arg === '--canonical') args.canonical = argv[++i] || ''; else if (arg === '--apply' || arg === '--write') args.apply = true; else if (arg === '--json') args.json = true; else if (arg === '--help' || arg === '-h') args.help = true; else usage(`unknown argument: ${arg}`); } return args; }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-section-accept-finalize.js --project-root <book> --workflow-id <id> --metadata <json> [--canonical file] [--apply] [--json]\n`); process.exit(2); }
function printHelp() { process.stdout.write('Usage: node short-section-accept-finalize.js --project-root <book> --workflow-id <id> [--metadata file] [--canonical file] [--apply] [--json]\n'); return 0; }

process.exitCode = main();
