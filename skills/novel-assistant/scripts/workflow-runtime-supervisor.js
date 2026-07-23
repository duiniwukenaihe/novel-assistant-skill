#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { resolveAuthoritativeStatus } = require('./workflow-state-validate');
const { readFocusedTask } = require('./lib/workflow-task-authority');

const USAGE = `Usage: node workflow-runtime-supervisor.js --project-root <book-dir> [--now ISO_TIME] [--json]

Reads 追踪/workflow/current-task.json and returns a deterministic runtime decision:
idle, continue, pause_at_checkpoint, resume_from_checkpoint, or repair_runtime_guard.`;

function parseArgs(argv) {
  const args = { projectRoot: '', now: '', json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--now') args.now = argv[++i] || '';
    else if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }
  if (!args.projectRoot) fail('missing --project-root');
  return args;
}

function fail(message) {
  console.error(`Error: ${message}`);
  console.error(USAGE);
  process.exit(1);
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function getPath(obj, dottedPath) {
  return dottedPath.split('.').reduce((current, part) => {
    if (current && Object.prototype.hasOwnProperty.call(current, part)) return current[part];
    return undefined;
  }, obj);
}

function minutesBetween(now, then) {
  const nowDate = new Date(now);
  const thenDate = new Date(then);
  if (Number.isNaN(nowDate.getTime()) || Number.isNaN(thenDate.getTime())) return null;
  return Math.floor((nowDate.getTime() - thenDate.getTime()) / 60000);
}

function supervise(projectRoot, nowIso) {
  const root = path.resolve(projectRoot);
  const currentTaskPath = path.join(root, '追踪', 'workflow', 'current-task.json');
  const now = nowIso || new Date().toISOString();
  const focused = readFocusedTask(root);
  const task = focused.authority.status === 'ok' ? focused.authority.task : null;
  const authority = resolveAuthoritativeStatus(root, { now });
  return {
    exitCode: authority.status === 'blocked' ? 2 : 0,
    result: {
      ...authority,
      ...(task ? readCostSummary(root, task) : {}),
    },
  };
}

function checkTrustedArtifact(root, artifactPath) {
  if (!artifactPath) return { status: 'not_declared', path: '' };
  const absPath = resolveInsideProject(root, artifactPath);
  if (!absPath) return { status: 'unsafe_path', path: artifactPath };
  return {
    status: fs.existsSync(absPath) ? 'exists' : 'missing',
    path: artifactPath,
  };
}

function checkExpectedResult(root, artifactPath) {
  if (!artifactPath) return { status: 'not_declared', path: '' };
  const absPath = resolveInsideProject(root, artifactPath);
  if (!absPath) return { status: 'unsafe_path', path: artifactPath };
  return { status: fs.existsSync(absPath) ? 'exists' : 'missing', path: artifactPath };
}

function resolveInsideProject(root, filePath) {
  const resolved = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(root, filePath);
  return resolved === root || resolved.startsWith(`${root}${path.sep}`) ? resolved : '';
}

function readCostSummary(root, task) {
  const configuredPath = getPath(task, 'runtime_guard.token_cost_governance.cost_summary_path') || '';
  if (!configuredPath) return {};
  const absPath = path.isAbsolute(configuredPath) ? configuredPath : path.join(root, configuredPath);
  if (!fs.existsSync(absPath)) {
    return {
      cost_summary_path: configuredPath,
      cost_summary_status: 'missing',
    };
  }
  const summary = readJson(absPath);
  if (summary.__error) {
    return {
      cost_summary_path: configuredPath,
      cost_summary_status: 'invalid',
      cost_summary_error: summary.__error,
    };
  }
  return {
    cost_summary_path: configuredPath,
    cost_summary_status: 'ok',
    should_notify_user: Array.isArray(summary.proactive_alerts) && summary.proactive_alerts.length > 0,
    cost_alerts: Array.isArray(summary.proactive_alerts) ? summary.proactive_alerts : [],
    passive_cost_report_available: true,
    token_saving_plan: summary.token_saving_plan || {
      mode: 'active_and_passive',
      passive_cost_report_available: true,
      actions: [],
    },
    cost_summary: {
      workflow_id: summary.workflow_id || '',
      events: Number(summary.events || 0),
      estimated_tokens: Number(getPath(summary, 'totals.estimated_tokens') || 0),
      tool_calls: Number(getPath(summary, 'totals.tool_calls') || 0),
      retry_count: Number(getPath(summary, 'totals.retry_count') || 0),
      failure_count: Number(getPath(summary, 'totals.failure_count') || 0),
      waste_signals: summary.waste_signals || {},
    },
  };
}

function blocked(status, action, root, currentTaskPath, extra) {
  return {
    exitCode: 2,
    result: {
      status,
      recommended_action: action,
      project_root: root,
      current_task_path: currentTaskPath,
      ...extra,
    },
  };
}

function print(result, json) {
  if (json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  console.log(`${result.status}: ${result.recommended_action}`);
  if (result.resume_from) console.log(`resume_from: ${result.resume_from}`);
  if (result.heartbeat_age_minutes !== null && result.heartbeat_age_minutes !== undefined) {
    console.log(`heartbeat_age_minutes: ${result.heartbeat_age_minutes}`);
  }
}

function main() {
  const args = parseArgs(process.argv);
  const { exitCode, result } = supervise(args.projectRoot, args.now);
  print(result, args.json);
  process.exit(exitCode);
}

main();
