#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { atomicWriteJson, atomicWriteText, mutateTask } = require('./lib/workflow-state-store');

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) return printHelp();
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  let task = authority.task;
  let execution = task.stage_execution || {};
  if (String(task.current_stage || '') !== 'section_repair_loop'
    || String(execution.status || '') !== 'running'
    || String(execution.stage_id || '') !== 'section_repair_loop') {
    const recovered = recoverStaleRepairExecution(root, task);
    if (!recovered) {
      return finish({
        status: 'repair_stage_not_started',
        workflow_id: workflowId,
        expected: {
          current_stage: 'section_repair_loop',
          stage_execution_status: 'running',
          stage_execution_stage_id: 'section_repair_loop',
        },
        actual: {
          current_stage: String(task.current_stage || ''),
          stage_execution_status: String(execution.status || ''),
          stage_execution_stage_id: String(execution.stage_id || ''),
        },
        instruction: '先由 workflow 启动当前小节修订阶段；不要把未启动视为写作失败。',
      }, 0, args.json);
    }
    task = persistRecoveredRepairExecution(root, task, recovered);
    execution = task.stage_execution || recovered;
  }

  const draftRel = String(args.draft || execution.repair_target || '');
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) {
    return finish({ status: 'short_repair_target_missing', repair_target: draftRel, instruction: '返回当前节草稿阶段恢复候选稿，不要新建其他文件。' }, 0, args.json);
  }
  const beforeDigest = String(execution.repair_input_digest || '');
  let deterministicRepair = '';
  if (args.normalizeQuotes) {
    const validation = validateQuoteOnlyRepair(root, task, draftRel);
    if (validation.status !== 'ok') return finish(validation, 0, args.json);
    const input = fs.readFileSync(draftFile, 'utf8');
    const output = normalizeMainlandQuotes(input);
    if (output === input) {
      return finish({
        status: 'deterministic_quote_repair_not_needed',
        workflow_id: workflowId,
        repair_target: draftRel,
        instruction: '候选稿已没有半角或直角引号；请直接重新运行机器门，不要重写正文。',
      }, 0, args.json);
    }
    atomicWriteText(draftFile, output);
    deterministicRepair = 'mainland_quote_normalization';
  }
  const afterDigest = digestFile(draftFile);
  const policyRecheck = args.recheckPolicy === true && beforeDigest && beforeDigest === afterDigest;
  if (beforeDigest && beforeDigest === afterDigest && !policyRecheck) {
    return finish({
      status: 'awaiting_short_repair_edit',
      workflow_id: workflowId,
      repair_target: draftRel,
      instruction: `只修改 ${draftRel}，完成后重新运行本命令。`,
    }, 0, args.json);
  }

  const packetRel = String(execution.expected_result_packet || `${task.task_dir}/result-packets/section_repair_loop.result.json`);
  const packetFile = safeProjectFile(root, packetRel);
  if (!packetFile) return finish({ status: 'blocked_result_packet_path_unsafe', path: packetRel }, 2, args.json);
  atomicWriteJson(packetFile, {
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: 'section_repair_loop',
    step_id: 'section_repair_loop',
    owner_module: String(execution.owner_module || task.workflow_owner || ''),
    step_status: 'completed',
    outputs: [draftRel],
    changed_files: policyRecheck ? [] : [draftRel],
    created_files: [],
    evidence: [{
      draft: draftRel,
      before_digest: beforeDigest,
      after_digest: afterDigest,
      reason: policyRecheck ? 'gate_policy_recheck_without_prose_change' : (deterministicRepair || 'prose_repaired'),
    }],
    verification_result: 'pass',
    blocking_findings: [],
    checkpoint_state: {
      current_stage: 'section_repair_loop',
      completed_range: String(task.scope || '当前小节修订'),
      remaining_range: '当前小节机器门复检',
      resume_from: 'section_machine_gate',
    },
    output_health_result: 'pass',
    next_stage_id: 'section_machine_gate',
    next_recommendation: '运行当前小节机器门；不得跳到故事质量门或下一节。',
    handoff_summary: `${String(task.scope || '当前小节')}已按反馈修订，等待机器门复检。`,
    memory_updates: [],
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
    deterministic_repair: deterministicRepair,
    ...outcome.presentation,
    ...(outcome.applied ? {} : { apply_result: result }),
  }, outcome.exitCode, args.json);
}

function validateQuoteOnlyRepair(root, task, draftRel) {
  const gatePacketRel = String(((task.machine || {}).last_result_packet) || `${String(task.task_dir || '')}/result-packets/section_machine_gate.result.json`);
  const gatePacket = readJson(safeProjectFile(root, gatePacketRel));
  const blocking = Array.isArray((gatePacket || {}).blocking_findings) ? gatePacket.blocking_findings : [];
  if (!gatePacket || !['blocking', 'blocked'].includes(String(gatePacket.machine_gate_result || gatePacket.verification_result || '')) || blocking.length === 0) {
    return { status: 'deterministic_quote_repair_not_applicable', reason: 'quote_gate_blocker_missing' };
  }
  const quoteOnly = blocking.every((item) => /(?:ascii-quote-style|quote-style|引号|quote)/iu.test(`${String((item || {}).code || '')} ${String((item || {}).message || '')}`));
  if (!quoteOnly) {
    return { status: 'deterministic_quote_repair_not_applicable', reason: 'mixed_blocking_findings', blocking_findings: blocking };
  }
  const outputs = Array.isArray(gatePacket.outputs) ? gatePacket.outputs.map(String) : [];
  if (outputs.length > 0 && !outputs.includes(draftRel)) {
    return { status: 'deterministic_quote_repair_not_applicable', reason: 'repair_target_not_in_gate_outputs', repair_target: draftRel };
  }
  return { status: 'ok' };
}

function normalizeMainlandQuotes(input) {
  let quoteOpen = false;
  let output = '';
  for (const ch of String(input || '')) {
    if (ch === '“') { quoteOpen = true; output += ch; continue; }
    if (ch === '”') { quoteOpen = false; output += ch; continue; }
    if (ch === '「' || ch === '『') { quoteOpen = true; output += '“'; continue; }
    if (ch === '」' || ch === '』') { quoteOpen = false; output += '”'; continue; }
    if (ch === '"') {
      output += quoteOpen ? '”' : '“';
      quoteOpen = !quoteOpen;
      continue;
    }
    output += ch;
  }
  return output;
}

function persistRecoveredRepairExecution(root, task, recovered) {
  const now = new Date().toISOString();
  return mutateTask({
    projectRoot: root,
    workflowId: String(task.workflow_id || ''),
    expectedStateVersion: Number(task.state_version || 0),
    owner: 'short-section-repair-finalize',
    mutation: (current) => {
      current.current_stage = 'section_repair_loop';
      current.current_step = 'section_repair_loop';
      current.status = 'running';
      current.pending_action = null;
      current.stage_execution = {
        ...recovered,
        action_id: 'recover_stale_repair_execution',
        selected_number: 0,
        started_at: now,
        completion_boundary: 'stage_completed',
      };
      current.machine = current.machine || {};
      current.machine.last_transition = 'repair_stage_execution_recovered';
      current.machine.next_stop_reason = 'stage_running_waiting_result_packet';
      current.machine.allowed_actions = ['await_result_packet', 'pause'];
      current.runtime_guard = current.runtime_guard || {};
      current.runtime_guard.heartbeat = {
        ...(current.runtime_guard.heartbeat || {}),
        updated_at: now,
        current_batch: 'section_repair_loop',
        workflow_id: String(current.workflow_id || ''),
      };
      current.runtime_guard.checkpoint_policy = {
        ...(current.runtime_guard.checkpoint_policy || {}),
        resume_from: 'section_repair_loop',
        expected_result_packet: recovered.expected_result_packet,
        project_root: '.',
      };
      return current;
    },
  });
}

function recoverStaleRepairExecution(root, task) {
  if (String(task.current_stage || '') !== 'section_repair_loop') return null;
  const gatePacketRel = String((((task.machine || {}).last_result_packet) || ''));
  const gatePacket = readJson(safeProjectFile(root, gatePacketRel));
  if (!gatePacket || !['blocking', 'blocked'].includes(String(gatePacket.machine_gate_result || gatePacket.verification_result || ''))) return null;
  const outputs = Array.isArray(gatePacket.outputs) ? gatePacket.outputs.map(String) : [];
  const draftRel = outputs.find((item) => /草稿_第\d+节_候选\.md$|正文_第\d+节\.md$/.test(item)) || '';
  const draftFile = safeProjectFile(root, draftRel);
  if (!draftFile || !fs.existsSync(draftFile) || !fs.statSync(draftFile).isFile()) return null;

  const artifactRel = outputs.find((item) => /machine-gate\.json$/.test(item)) || '';
  const artifact = readJson(safeProjectFile(root, artifactRel));
  let baselineDigest = String((artifact || {}).draft_digest || '');
  if (!baselineDigest) {
    const previousRepairRel = `${String(task.task_dir || '')}/result-packets/section_repair_loop.result.json`;
    const previousRepair = readJson(safeProjectFile(root, previousRepairRel));
    const evidence = (Array.isArray((previousRepair || {}).evidence) ? previousRepair.evidence : [])
      .find((item) => String((item || {}).draft || '') === draftRel);
    baselineDigest = String((evidence || {}).after_digest || '');
  }
  if (!/^sha256:[a-f0-9]{64}$/.test(baselineDigest) || digestFile(draftFile) === baselineDigest) return null;
  return {
    status: 'running',
    stage_id: 'section_repair_loop',
    step_id: 'section_repair_loop',
    owner_module: String(task.workflow_owner || ''),
    expected_result_packet: `${String(task.task_dir || '')}/result-packets/section_repair_loop.result.json`,
    repair_target: draftRel,
    repair_input_digest: baselineDigest,
    recovered_from_stale_execution: true,
  };
}

function parseArgs(argv) {
  const args = { projectRoot: '', workflowId: '', draft: '', apply: false, recheckPolicy: false, normalizeQuotes: false, json: false, help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++index] || '';
    else if (arg === '--draft') args.draft = argv[++index] || '';
    else if (arg === '--apply' || arg === '--write') args.apply = true;
    else if (arg === '--recheck-policy' || arg === '--recheck') args.recheckPolicy = true;
    else if (arg === '--normalize-quotes') args.normalizeQuotes = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else usage(`unknown argument: ${arg}`);
  }
  return args;
}
function printHelp() { process.stdout.write('Usage: node short-section-repair-finalize.js --project-root <book> --workflow-id <id> [--draft file] [--recheck-policy] [--normalize-quotes] [--apply] [--json]\n'); return 0; }

function focusedWorkflowId(root) {
  return singleUnfinishedWorkflowId(root);
}

function safeProjectFile(root, relativePath) {
  const file = path.resolve(root, String(relativePath || ''));
  return file.startsWith(`${root}${path.sep}`) ? file : '';
}

function digestFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function readJson(file) {
  try { return file && JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function parseJson(text) {
  try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; }
}

function finish(value, code, json) {
  process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`);
  return code;
}

function usage(message) {
  process.stderr.write(`${message}\nUsage: node short-section-repair-finalize.js --project-root <book> --workflow-id <id> [--draft file] [--recheck-policy] [--normalize-quotes] [--apply] [--json]\n`);
  process.exit(2);
}

if (require.main === module) process.exitCode = main();
