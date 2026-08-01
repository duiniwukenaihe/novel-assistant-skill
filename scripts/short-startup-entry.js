#!/usr/bin/env node
'use strict';

const path = require('path');
const { spawnSync } = require('child_process');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot || process.cwd());
  const stateCommand = args.restart ? 'switch-intent' : 'create';
  const stateArgs = [
    stateCommand, '--workflow-type', 'short_write', '--project-root', root,
    '--user-goal', args.userGoal || '新开短篇',
  ];
  if (args.restart) stateArgs.push('--reason', args.reason || '重新规划热点资讯发现流程');
  stateArgs.push('--json');
  const created = runJson(root, 'workflow-state-machine.js', stateArgs);
  if (!created.ok) return finish({ status: 'short_startup_create_failed', detail: created.value }, created.code || 1, args.json);
  const workflowId = String(created.value.workflow_id || ((created.value.task || {}).workflow_id) || '');
  if (!workflowId) return finish({ status: 'short_startup_workflow_id_missing', create_result: created.value }, 1, args.json);
  const started = runJson(root, 'workflow-state-machine.js', [
    'resolve-action', '--project-root', root, '--input', '1', '--bind-current', '--json',
  ]);
  if (!started.ok || String(((started.value || {}).stage_execution || {}).stage_id || '') !== 'startup_scan') {
    return finish({ status: 'short_startup_scan_start_failed', workflow_id: workflowId, detail: started.value }, started.code || 1, args.json);
  }
  const scanned = runJson(root, 'short-startup-scan-finalize.js', [
    '--project-root', root, '--workflow-id', workflowId, '--json',
  ]);
  return finish(scanned.value, scanned.code, args.json);
}

function runJson(cwd, script, args) {
  const result = spawnSync(process.execPath, [path.join(__dirname, script), ...args], {
    cwd, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
  });
  let value;
  try { value = JSON.parse(String(result.stdout || '').trim()); } catch (_) {
    value = { status: 'invalid_script_output', stdout: String(result.stdout || '').trim().slice(0, 500), stderr: String(result.stderr || '').trim().slice(0, 500) };
  }
  return { ok: result.status === 0, code: Number(result.status || 0), value };
}
function parseArgs(argv) {
  const out = { projectRoot: '.', userGoal: '', restart: false, reason: '', json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '.';
    else if (arg === '--user-goal') out.userGoal = argv[++index] || '';
    else if (arg === '--restart') out.restart = true;
    else if (arg === '--reason') out.reason = argv[++index] || '';
    else if (arg === '--json') out.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return out;
}
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : String((value || {}).status || '')}\n`); return code; }

process.exitCode = main();
