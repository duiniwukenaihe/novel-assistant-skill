#!/usr/bin/env node
'use strict';
// src/internal-skills/story-setup/references/templates/hooks/workflow-tool-budget-guard.js
//
// Task 4: PreToolUse hook - 写作模式下的动态工具预算熔断。
//
// 部署:runtime sync 自动枚举到 .claude/hooks/,settings-hooks.json 注册 PreToolUse group。
// matcher: Bash|Read|Write|Edit|MultiEdit(写作相关的读/写/Bash 调用都评估)。
//
// 阻断策略(fail-open 优先,绝不误伤普通项目):
//   1. 读 payload + 找项目根
//   2. 读聚焦任务;找不到/非写作项目 -> exit 0 放行(兼容)
//   3. require lib/interactive-tool-budget.js;加载失败 -> fail-open exit 0 + stderr warning
//   4. evaluateToolCall -> pause 则写账本 + exit 2(stderr 给恢复提示),allow 则 append allow 事件 + exit 0
//
// 职责:平台诊断 + 受管源码保护 + 源码读取节流。转换失败熔断由 controller 负责。

const path = require('path');
const fs = require('fs');

function main() {
  const payload = readPayload();
  const toolName = String(payload.tool_name || '');
  const toolInput = (payload.tool_input && typeof payload.tool_input === 'object')
    ? payload.tool_input
    : {};

  const projectRoot = path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());

  // 读聚焦任务。失败/缺失 -> fail-open。
  const focused = readFocusedTask(projectRoot);
  if (!focused) {
    // 非写作项目(无任务):不阻断,不写账本。
    return allow('no focused writing task; workflow tool budget is inactive for this project');
  }

  let budget;
  try {
    budget = require(path.join(projectRoot, 'scripts', 'lib', 'interactive-tool-budget.js'));
  } catch (err) {
    // 库加载失败:fail-open,绝不阻断普通写作。
    process.stderr.write(`workflow-tool-budget-guard: budget library unavailable (${err.message}); fail-open\n`);
    return 0;
  }

  let priorEvents = [];
  try {
    priorEvents = budget.readLedger(projectRoot, focused.workflowId);
  } catch (_) {
    priorEvents = [];
  }

  let result;
  try {
    result = budget.evaluateToolCall({
      task: focused.task,
      stage: { id: String(focused.task.current_stage || '') },
      toolName,
      toolInput,
      priorEvents,
      projectRoot,
    });
  } catch (err) {
    // 评估抛错:fail-open。
    process.stderr.write(`workflow-tool-budget-guard: evaluation error (${err.message}); fail-open\n`);
    return 0;
  }

  // 写账本(allow 也写,用于累计源码读取计数)。
  const event = makeEvent(toolName, toolInput, result);
  try {
    budget.appendLedger(projectRoot, focused.workflowId, event);
  } catch (_) { /* 静默 */ }

  if (result.decision === 'pause') {
    return denyWithPause(result.reason || '写作模式下工具预算已耗尽,请从最后可信断点恢复。');
  }
  return 0;
}

function makeEvent(toolName, toolInput, result) {
  const ev = {
    tool_name: toolName,
    decision: result.decision,
    code: result.code,
  };
  if (result.target) ev.target = result.target;
  // 标记平台源码读取类别,供后续 countRecentPlatformReads 计数。
  try {
    const isPlatformRead = require(path.join(process.env.CLAUDE_PROJECT_DIR || process.cwd(), 'scripts', 'lib', 'interactive-tool-budget.js')).isPlatformSourceRead;
    if (isPlatformRead(toolName, toolInput)) {
      ev.reason = 'platform_source_read';
      ev.category = 'platform_source_read';
      if (toolName === 'Bash') ev.command = String((toolInput && toolInput.command) || '');
    }
  } catch (_) { /* ignore */ }
  return ev;
}

// 读聚焦任务。直接读 current-task.json 指针 + task_dir/task.json,不依赖
// workflow-task-authority(保持 hook 自包含、低加载开销)。失败/缺失 -> null。
function readFocusedTask(projectRoot) {
  const root = path.resolve(projectRoot || '');
  const pointerFile = path.join(root, '追踪', 'workflow', 'current-task.json');
  const pointer = readJsonSafe(pointerFile);
  if (!pointer || pointer.__error) return null;
  const workflowId = String(pointer.workflow_id || '');
  if (!workflowId) return null;
  const taskDir = String(pointer.task_dir || `追踪/workflow/tasks/${workflowId}`);
  const taskFile = path.join(root, taskDir, 'task.json');
  const task = readJsonSafe(taskFile);
  if (!task || task.__error) return null;
  return { workflowId, task };
}

function readJsonSafe(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    return { __error: err.message };
  }
}

function readPayload() {
  const raw = process.env.CLAUDE_TOOL_INPUT || readStdin();
  if (!raw || !raw.trim()) return {};
  try { return JSON.parse(raw); } catch (_) { return {}; }
}

function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch (_) { return ''; }
}

function allow(reason) {
  emit({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow', permissionDecisionReason: reason } });
  return 0;
}

// 阻断:同时输出结构化 deny(stdout)给 Claude Code + stderr 文本回给模型(exit 2)。
function denyWithPause(reason) {
  emit({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } });
  process.stderr.write(`${reason}\n`);
  return 2;
}

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

process.exitCode = main();
