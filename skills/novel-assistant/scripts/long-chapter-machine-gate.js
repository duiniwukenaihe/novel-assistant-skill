#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { recoverableStageResult } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');
const { singleUnfinishedWorkflowId } = require('./lib/workflow-command-task-binding');
const { inferLongChapter, resolveChapterDraft } = require('./lib/long-stage-context-packet');
const { atomicWriteJson } = require('./lib/workflow-state-store');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const workflowId = String(args.workflowId || focusedWorkflowId(root));
  const authority = resolveTaskAuthority(root, workflowId);
  if (authority.status !== 'ok') return finish({ status: authority.status, workflow_id: workflowId }, 2, args.json);
  const task = authority.task;
  if (String(task.workflow_type || '') !== 'long_write' || String(task.current_stage || '') !== 'prose_acceptance') {
    return finish({ status: 'blocked_wrong_stage', expected: 'long_write.prose_acceptance', actual: `${task.workflow_type || ''}.${task.current_stage || ''}` }, 2, args.json);
  }
  const execution = task.stage_execution || {};
  if (String(execution.status || '') !== 'running' || String(execution.stage_id || '') !== 'prose_acceptance') return finish({ status: 'blocked_stage_execution_required' }, 2, args.json);
  const chapter = inferLongChapter(root, task, 'prose_acceptance');
  const volume = volumeFromTask(task);
  const draft = args.draft ? safeProjectFile(root, args.draft) : resolveChapterDraft(root, task, chapter, volume);
  if (!chapter || !draft || !fs.existsSync(draft)) return finish(recoverableStageResult(task, 'blocked_long_draft_missing', '恢复当前章候选稿后重新运行章节机器检查；不要创建空正文或跳到下一章。', { chapter, draft: args.draft || '' }), 0, args.json);
  const checks = runChecks(root, draft);
  const blocking = checks.filter((item) => item.blocking);
  const evidenceRel = `${task.task_dir}/artifacts/chapter-${String(chapter).padStart(3, '0')}-machine-gate.json`;
  atomicWriteJson(safeProjectFile(root, evidenceRel), { schemaVersion: '1.0.0', workflow_id: workflowId, chapter, volume, draft: relative(root, draft), checks, blocking_count: blocking.length, status: blocking.length ? 'blocking' : 'pass', created_at: new Date().toISOString() });
  const base = { workflow_id: workflowId, chapter, draft: relative(root, draft), evidence: evidenceRel, blocking_findings: blocking.map((item) => ({ code: item.id, message: item.message })), next_command: blocking.length ? '' : `node scripts/long-chapter-quality-gate.js --project-root . --workflow-id ${JSON.stringify(workflowId)} --decision <pass|revise> --apply --json` };
  if (blocking.length) return finish(recoverableStageResult(task, 'blocking', '只修当前章机器检查发现的问题，完成后重跑当前章节机器检查；不要重写大纲或继续下一章。', base), 0, args.json);
  return finish({ status: 'pass', ...base }, 0, args.json);
}

function runChecks(root, draft) {
  const commands = [
    ['check-ai-patterns', 'check-ai-patterns.js', ['--check', '--json', '--fail-on=blocking', draft]],
    ['anti-ai-diagnose', 'anti-ai-diagnose.js', ['--json', '--work-type=longform', '--prose-profile=fiction', draft]],
    ['output-pollution-check', 'output-pollution-check.js', ['--check', '--json', draft]],
    ['check-degeneration', 'check-degeneration.js', ['--check', '--json', '--fail-on=blocking', draft]],
    ['story-prose-gate', 'story-prose-gate.js', [draft, '--json']],
  ];
  return commands.map(([id, script, cliArgs]) => {
    const run = spawnSync(process.execPath, [path.join(__dirname, script), ...cliArgs], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
    const parsed = parseJson(run.stdout);
    const blocking = run.status !== 0 || hasBlocking(parsed);
    return { id, status: blocking ? 'blocking' : 'pass', blocking, exit_code: Number.isInteger(run.status) ? run.status : 1, message: blocking ? firstMessage(parsed, run.stderr) : '' };
  });
}
function hasBlocking(value) { if (!value || typeof value !== 'object') return false; if (Array.isArray(value)) return value.some(hasBlocking); return Object.entries(value).some(([key, child]) => (/blocking|blocked/i.test(key) && (child === true || Number(child) > 0)) || (/status|result|verdict/i.test(key) && typeof child === 'string' && /(block|fail|reject|error)/i.test(child)) || (/severity/i.test(key) && String(child).toLowerCase() === 'blocking') || hasBlocking(child)); }
function firstMessage(parsed, stderr) { const queue = [parsed]; while (queue.length) { const item = queue.shift(); if (!item || typeof item !== 'object') continue; if (typeof item.message === 'string' && item.message.trim()) return item.message.trim().slice(0, 300); queue.push(...(Array.isArray(item) ? item : Object.values(item))); } return String(stderr || '检查器未通过').trim().slice(0, 300); }
function volumeFromTask(task) { const match = `${task.scope || ''} ${task.user_goal || ''}`.match(/第\s*([0-9一二三四五六七八九十百]+)\s*卷/); return match ? `第${match[1]}卷` : ''; }
function parseArgs(argv) { const args = { projectRoot: '', workflowId: '', draft: '', json: false }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === '--project-root') args.projectRoot = argv[++i] || ''; else if (arg === '--workflow-id') args.workflowId = argv[++i] || ''; else if (arg === '--draft') args.draft = argv[++i] || ''; else if (arg === '--json') args.json = true; else usage(`unknown argument: ${arg}`); } return args; }
function focusedWorkflowId(root) { return singleUnfinishedWorkflowId(root); }
function safeProjectFile(root, rel) { const file = path.resolve(root, String(rel || '')); return file.startsWith(`${root}${path.sep}`) ? file : ''; }
function relative(root, file) { return path.relative(root, file).split(path.sep).join('/'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function parseJson(text) { try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; } }
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : value.status}\n`); return code; }
function usage(message) { process.stderr.write(`${message}\nUsage: node long-chapter-machine-gate.js --project-root <book> --workflow-id <id> [--draft file] [--json]\n`); process.exit(2); }

process.exitCode = main();
