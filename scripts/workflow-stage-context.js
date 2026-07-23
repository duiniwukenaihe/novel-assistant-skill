#!/usr/bin/env node
'use strict';

// workflow-stage-context
//
// Thin CLI wrapper around lib/workflow-stage-context-packet.buildStageContextPacket.
// Lets an interactive host (Claude Code / Codex / ZCode) build the minimal
// section-context packet for drafting one short section, without re-reading the
// full task.json / prose / history result-packets each time. This is the
// context-side companion to workflow-stage-controller.js advance.
//
// Usage:
//   node scripts/workflow-stage-context.js build \
//     --project-root <book> [--workflow-id <id>] [--stage <stage_id>] --json
//   node scripts/workflow-stage-context.js read-current \
//     --project-root <book> --workflow-id <id>
//
// If --workflow-id is omitted, the focused task (追踪/workflow/current-task.json)
// is resolved. If --stage is omitted, the task's current_stage is used.
//
// Exit status:
//   0  produced a JSON result (status=assembled or not_applicable)
//   1  invalid arguments / internal error
//
// Status values in --json output:
//   assembled        packet written to context-packets/<stage>/<run>/stage-context.{json,md}
//   not_applicable   non-short workflow or non-draft stage; read assets normally

const fs = require('fs');
const path = require('path');
const { buildStageContextPacket } = require('./lib/workflow-stage-context-packet');

const USAGE = `Usage: node scripts/workflow-stage-context.js <command> [options]

Commands:
  build   Build the minimal section-context packet for drafting one short section.
  read-current   Print the authoritative current stage packet without copying its path.

build:
  build --project-root <book> [--workflow-id <id>] [--stage <stage_id>] --json

read-current:
  read-current --project-root <book> --workflow-id <id> [--json]

Exit status:
  0  produced a JSON result (status=assembled or not_applicable)
  1  invalid arguments / internal error

Status values in --json output:
  assembled        packet written; read packet_md, use only its assets to draft
  not_applicable   non-short workflow or non-draft stage; read assets normally`;

function parseArgs(argv) {
  const command = argv[2] || '';
  const args = {
    command,
    json: false,
    projectRoot: '',
    workflowId: '',
    stage: '',
  };
  for (let i = 3; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') args.json = true;
    else if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++i] || '';
    else if (arg === '--stage') args.stage = argv[++i] || '';
    else if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    }
  }
  return args;
}

function readFocusedTask(root) {
  const pointerFile = path.join(root, '追踪', 'workflow', 'current-task.json');
  let pointer;
  try {
    pointer = JSON.parse(fs.readFileSync(pointerFile, 'utf8'));
  } catch (_) {
    return null;
  }
  const taskDir = pointer.task_dir || '';
  const taskFile = taskDir ? path.join(root, taskDir, 'task.json') : '';
  if (!taskFile || !fs.existsSync(taskFile)) return null;
  try {
    return JSON.parse(fs.readFileSync(taskFile, 'utf8'));
  } catch (_) {
    return null;
  }
}

function readTask(root, workflowId = '') {
  const id = String(workflowId || '').trim();
  if (!id) return readFocusedTask(root);
  if (!/^[A-Za-z0-9._-]+$/.test(id)) return null;
  const taskFile = path.join(root, '追踪', 'workflow', 'tasks', id, 'task.json');
  if (!fs.existsSync(taskFile)) return null;
  try {
    const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
    return String(task.workflow_id || '') === id ? task : null;
  } catch (_) {
    return null;
  }
}

function build(args) {
  const root = path.resolve(args.projectRoot);
  const task = readTask(root, args.workflowId);
  if (!task) {
    return {
      status: 'not_applicable',
      reason: 'no_focused_task',
      message: '找不到焦点任务；非写作项目按各阶段协议正常读取资产。',
    };
  }
  const stage = args.stage || String(task.current_stage || '');
  const result = buildStageContextPacket({ projectRoot: root, task, stage: String(stage || '') });
  return result;
}

function readCurrent(args) {
  const root = path.resolve(args.projectRoot);
  const task = readTask(root, args.workflowId);
  if (!task) return { status: 'blocked_task_not_found', workflow_id: String(args.workflowId || '') };
  const execution = task.stage_execution && typeof task.stage_execution === 'object' ? task.stage_execution : {};
  const packet = execution.stage_context_packet && typeof execution.stage_context_packet === 'object'
    ? execution.stage_context_packet
    : {};
  const memoryContext = execution.memory_context && typeof execution.memory_context === 'object'
    ? execution.memory_context
    : {};
  const packetRel = String(packet.packet_md || '').replace(/\\/g, '/').replace(/^\.\//, '');
  const memoryRel = String(memoryContext.packet_md || '').replace(/\\/g, '/').replace(/^\.\//, '');
  if (!packetRel && !memoryRel) {
    return {
      status: 'blocked_stage_context_missing',
      workflow_id: String(task.workflow_id || ''),
      stage_id: String(execution.stage_id || task.current_stage || ''),
    };
  }
  const packetFiles = [...new Set([packetRel, memoryRel].filter(Boolean))].map((relative) => ({
    relative,
    absolute: path.resolve(root, relative),
  }));
  const unsafe = packetFiles.find(({ absolute }) => absolute !== root && !absolute.startsWith(`${root}${path.sep}`));
  if (unsafe) return { status: 'blocked_stage_context_path_unsafe', workflow_id: String(task.workflow_id || '') };
  const missing = packetFiles.find(({ absolute }) => !fs.existsSync(absolute) || !fs.statSync(absolute).isFile());
  if (missing) {
    return {
      status: 'blocked_stage_context_file_missing',
      workflow_id: String(task.workflow_id || ''),
      stage_id: String(execution.stage_id || task.current_stage || ''),
      packet_md: missing.relative,
    };
  }
  const content = packetFiles.map(({ relative, absolute }, index) => {
    const label = relative === memoryRel && relative !== packetRel ? '作品记忆上下文' : '当前阶段上下文';
    return `${index > 0 ? '\n\n' : ''}# ${label}\n\n${fs.readFileSync(absolute, 'utf8')}`;
  }).join('');
  return {
    status: 'stage_context_ready',
    workflow_id: String(task.workflow_id || ''),
    stage_id: String(execution.stage_id || task.current_stage || ''),
    packet_md: packetRel,
    memory_packet_md: memoryRel,
    memory_read_receipt: memoryContext.memory_read_receipt || packet.memory_read_receipt || null,
    content,
  };
}

function main() {
  const args = parseArgs(process.argv);
  if (!['build', 'read-current'].includes(args.command)) {
    process.stderr.write(`${USAGE}\n`);
    process.exit(1);
  }
  if (!args.projectRoot) {
    process.stderr.write('missing --project-root\n');
    process.exit(1);
  }
  let result;
  try {
    result = args.command === 'read-current' ? readCurrent(args) : build(args);
  } catch (error) {
    result = { status: 'error', message: error.message };
  }
  if (args.command === 'read-current' && !args.json && result.status === 'stage_context_ready') {
    process.stdout.write(result.content);
  } else if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`${result.status || 'ok'}\n`);
  }
  process.exit(String(result.status || '').startsWith('blocked_') || result.status === 'error' ? 2 : 0);
}

main();
