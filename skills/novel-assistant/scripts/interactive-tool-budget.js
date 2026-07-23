#!/usr/bin/env node
'use strict';
// scripts/interactive-tool-budget.js
//
// Task 4: 交互式工具预算熔断的薄 CLI 包装。主要用于测试与人工诊断。
// Hook(workflow-tool-budget-guard.js)不依赖本 CLI,直接 require lib,以降低调用开销。

const path = require('path');
const {
  evaluateToolCall,
  readLedger,
  appendLedger,
  isPlatformSourceRead,
  buildStageToolBudget,
} = require('./lib/interactive-tool-budget');

main();

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.command === 'evaluate') {
    runEvaluate(args);
    return;
  }
  if (args.command === 'budget') {
    runBudget(args);
    return;
  }
  process.stderr.write('usage: interactive-tool-budget.js <evaluate|budget> --project-root <dir> [--workflow-id <id>] --tool-name <name> --tool-input <json> [--json]\n');
  process.exit(64);
}

function runEvaluate(args) {
  if (!args.project_root || !args.tool_name) {
    emit({ status: 'error', code: 'missing_args', message: '--project-root and --tool-name are required' });
    process.exit(64);
  }
  const projectRoot = path.resolve(args.project_root);
  const toolInput = parseToolInput(args.tool_input);
  const focused = readFocusedTaskSafely(projectRoot, args.workflow_id);

  // 缺失任务/非写作项目 -> fail-open allow。
  if (!focused || !focused.task) {
    const result = { decision: 'allow', code: 'no_focused_task', reason: 'no_focused_task', fail_open: true };
    emit(result);
    return;
  }

  const priorEvents = readLedger(projectRoot, focused.workflowId);
  const result = evaluateToolCall({
    task: focused.task,
    stage: { id: String(focused.task.current_stage || '') },
    toolName: args.tool_name,
    toolInput,
    priorEvents,
    projectRoot,
  });

  emit(result);
}

function runBudget(args) {
  if (!args.project_root) {
    emit({ status: 'error', code: 'missing_args', message: '--project-root is required' });
    process.exit(64);
  }
  const projectRoot = path.resolve(args.project_root);
  const focused = readFocusedTaskSafely(projectRoot, args.workflow_id);
  if (!focused || !focused.task) {
    emit({ status: 'idle', writing_mode: false, reason: 'no_focused_task' });
    return;
  }
  const budget = buildStageToolBudget(focused.task, { id: String(focused.task.current_stage || '') });
  emit({ status: 'ok', workflow_id: focused.workflowId, current_stage: focused.task.current_stage, budget });
}

// 读取聚焦任务。优先显式 --workflow-id(测试/诊断用),否则读 current-task.json 指针。
// 失败/缺失 -> 返回 null(永不抛错)。
function readFocusedTaskSafely(projectRoot, workflowId) {
  const fs = require('fs');
  const root = path.resolve(projectRoot || '');
  try {
    let id = String(workflowId || '');
    if (!id) {
      const pointerFile = path.join(root, '追踪', 'workflow', 'current-task.json');
      const pointer = readJsonSafe(pointerFile);
      id = String((pointer && pointer.workflow_id) || '');
    }
    if (!id) return null;
    // 显式 workflow_id 时直接读该任务;否则用指针指向的 task_dir。
    const pointer = readJsonSafe(path.join(root, '追踪', 'workflow', 'current-task.json'));
    const taskDir = (pointer && pointer.workflow_id === id && pointer.task_dir)
      ? pointer.task_dir
      : `追踪/workflow/tasks/${id}`;
    const taskFile = path.join(root, taskDir, 'task.json');
    const task = readJsonSafe(taskFile);
    if (!task || task.__error) return null;
    return { workflowId: id, task };
  } catch (_) {
    return null;
  }
}

function readJsonSafe(file) {
  const fs = require('fs');
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    return { __error: err.message };
  }
}

function parseToolInput(raw) {
  if (!raw) return {};
  try {
    return typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch (_) {
    return {};
  }
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--json') { out.json = true; continue; }
    if (a.startsWith('--')) {
      const key = a.slice(2).replace(/-/g, '_');
      out[key] = argv[i + 1];
      i += 1;
    } else if (!out.command) {
      out.command = a;
    } else {
      out._.push(a);
    }
  }
  return out;
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

module.exports = { runEvaluate, runBudget, parseArgs };
