#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function main() {
  const projectRoot = path.resolve(process.env.CLAUDE_PROJECT_DIR || process.cwd());
  const pointer = readJson(path.join(projectRoot, '追踪', 'workflow', 'current-task.json'));
  if (!pointer || !pointer.workflow_id) return 0;
  const toolName = String(readPayload().tool_name || 'host task tool');
  const reason = `当前小说任务已由 workflow task.json 管理；不要调用或重试 ${toolName}，直接继续当前 workflow 阶段。`;
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  })}\n`);
  return 0;
}

function readPayload() {
  const raw = process.env.CLAUDE_TOOL_INPUT || readStdin();
  try { return JSON.parse(raw || '{}'); } catch (_) { return {}; }
}

function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch (_) { return ''; }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

process.exitCode = main();
