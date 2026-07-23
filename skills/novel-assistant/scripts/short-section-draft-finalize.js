#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson } = require('./lib/workflow-state-store');
const { validateShortStageMemoryReceipt } = require('./lib/short-memory-snapshot');

const DRAFT_STAGES = new Set(['draft_first_section', 'draft_section', 'draft_next_section']);

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  const task = authority.task;
  const stageId = String(task.current_stage || '');
  const execution = task.stage_execution || {};
  if (!DRAFT_STAGES.has(stageId)
    || String(execution.status || '') !== 'running'
    || String(execution.stage_id || '') !== stageId) {
    return finish({ status: 'stage_action_not_applicable', expected: [...DRAFT_STAGES], actual: stageId, instruction: '重新读取当前任务的 execution_command；不要重试旧阶段命令。' }, 0, args.json);
  }
  const draftRel = String(args.draft || execution.draft_target || '');
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) {
    return finish({ status: 'awaiting_short_draft', workflow_id: workflowId, draft_target: draftRel }, 0, args.json);
  }
  const prose = fs.readFileSync(draftFile, 'utf8').trim();
  if (Array.from(prose).length < 80) {
    return finish({ status: 'awaiting_short_draft', workflow_id: workflowId, draft_target: draftRel, chars: Array.from(prose).length }, 0, args.json);
  }
  const beforeDigest = String(execution.draft_input_digest || '');
  const afterDigest = digestFile(draftFile);
  if (beforeDigest && beforeDigest === afterDigest) {
    return finish({ status: 'awaiting_short_draft_change', workflow_id: workflowId, draft_target: draftRel }, 0, args.json);
  }
  const memoryCheck = validateShortStageMemoryReceipt(root, task, execution);
  if (!['current', 'not_recorded'].includes(String(memoryCheck.status || ''))) {
    return finish({
      status: 'short_memory_context_refresh_required',
      workflow_id: workflowId,
      memory_status: memoryCheck.status,
      stale_sources: memoryCheck.stale_sources || [],
      draft_target: draftRel,
      instruction: '候选稿已保留。当前作品事实在本阶段启动后发生变化；重建本小节上下文包并仅复核受影响内容，不得重写整篇。',
    }, 0, args.json);
  }

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
    outputs: [draftRel],
    changed_files: [draftRel],
    created_files: beforeDigest ? [] : [draftRel],
    evidence: [{ draft: draftRel, before_digest: beforeDigest, after_digest: afterDigest, chars: Array.from(prose).length }],
    verification_result: 'pass',
    blocking_findings: [],
    checkpoint_state: {
      current_stage: stageId,
      completed_range: String(task.scope || '当前小节正文'),
      remaining_range: '当前小节机器门',
      resume_from: 'section_machine_gate',
    },
    output_health_result: 'pass',
    next_stage_id: 'section_machine_gate',
    next_recommendation: '运行当前小节机器门；不得继续写下一节。',
    handoff_summary: `${String(task.scope || '当前小节')}候选稿已落盘，等待机器门。`,
    memory_updates: [],
    memory_read_receipt_status: memoryCheck.status,
    memory_read_receipt: memoryCheck.current_receipt || null,
    result_packet_path: packetRel,
  });
  if (!args.apply) return finish({ status: 'packet_ready', workflow_id: workflowId, result_packet: packetRel }, 0, args.json);
  const applied = spawnSync(process.execPath, [
    path.join(__dirname, 'workflow-state-machine.js'),
    'apply-result', '--project-root', root, '--workflow-id', workflowId, '--result', packetFile, '--json',
  ], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  const outcome = classifyWorkflowApply(applied);
  const result = outcome.result;
  const nextExecution = result.stage_execution || ((result.task || {}).stage_execution) || {};
  return finish({
    status: outcome.applied ? 'applied' : 'apply_blocked',
    workflow_status: outcome.workflowStatus,
    workflow_id: workflowId,
    result_packet: packetRel,
    next_stage: String(result.current_stage || ((result.task || {}).current_stage) || ''),
    stage_execution: nextExecution,
    next_command: String(nextExecution.execution_command || ''),
    ...outcome.presentation,
    apply_result: outcome.applied ? undefined : result,
    apply_error: outcome.applied ? undefined : String(applied.stderr || '').trim().slice(0, 600),
  }, outcome.exitCode, args.json);
}

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', draft: '', apply: false, json: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++index] || '';
    else if (arg === '--draft') args.draft = argv[++index] || '';
    else if (arg === '--apply' || arg === '--write') args.apply = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else usage(`unknown argument: ${arg}`);
  }
  return args;
}
function printHelp() { process.stdout.write('Usage: node short-section-draft-finalize.js --project-root <book> --workflow-id <id> [--draft file] [--apply] [--json]\n'); return 0; }

function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, relativePath) { const file = path.resolve(root, String(relativePath || '')); return file.startsWith(`${root}${path.sep}`) ? file : ''; }
function digestFile(file) { return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`; }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node short-section-draft-finalize.js --project-root <book> --workflow-id <id> [--draft file] [--apply] [--json]\n`); process.exit(2); }

if (require.main === module) process.exitCode = main();
