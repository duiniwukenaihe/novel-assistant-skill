#!/usr/bin/env node
'use strict';

// Task 4 subtask C: the host-facing startup router for a new short project.
//
// DEFAULT (no --legacy-v2): route to the canonical V3 lifecycle by invoking
// `workflow-v3.js create-short`, then wrap its durable task in the stable
// host-facing `short_startup_ready` payload. The V3 task is the sole authority;
// this wrapper writes no current_stage and asserts no startup_scan stage.
//
// --legacy-v2 remains accepted as a compatibility flag, but V2 short creation
// is frozen. It returns a structured block before invoking the V2 state
// machine, so old launchers fail closed without creating a second authority.
//
// --restart WITHOUT --legacy-v2 is the future compatibility gateway: it fails
// CLOSED (nonzero, no write) until the V3 restart path is defined, so a host
// can never silently re-enter a half-migrated restart.
//
// Profile flags: `--profile public` or `--no-private-registry` map to the
// public V3 profile; the default (no flag) maps to private.
//
// Argument safety: every value flag (--project-root, --user-goal, --reason,
// --profile) is validated at parse time. A missing value (end of args), a
// following --flag (which would otherwise be swallowed as the value), OR an
// empty/whitespace-only value is a usage error that exits 2 with a stable
// message before any path.resolve/write — so a typo like `--user-goal --json`
// can never create a directory named `--json`, and an empty --project-root or
// --profile can never resolve the cwd or start a task. Conflicting profile
// flags are rejected the same way.

const path = require('path');
const { spawnSync } = require('child_process');

// Usage error: a programmer mistake on the command line. Prints a single stable
// line to stderr and exits 2 — never a thrown stack trace. Called from parseArgs
// (before any write) and from profile-conflict detection, so the host always
// sees the same shape and exit code for a bad invocation.
function usageError(message) {
  process.stderr.write(`${message}\n`);
  process.exit(2);
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  // Conflicting profile flags are a usage error: --profile private and
  // --no-private-registry point at opposite profiles, so refuse before routing.
  if (args.noPrivateRegistry && args.profile === 'private') {
    usageError('conflicting profile flags: --profile private cannot combine with --no-private-registry');
  }

  const root = path.resolve(args.projectRoot);

  // The future compatibility gateway: a V3 restart is not yet defined, so fail
  // closed rather than silently routing to V2 or inventing a V3 restart.
  if (args.restart && !args.legacyV2) {
    return finish({ status: 'short_startup_restart_gateway_closed', reason: args.reason || '' }, 1, args.json);
  }

  if (args.legacyV2) return runLegacyV2(root, args);
  return runV3(root, args);
}

// V3 default: delegate to the canonical create-short CLI and wrap the durable
// task in the stable short_startup_ready output. The task carries the engine
// contract identity (engine_version 3, current_stage creative_entry,
// production_kernel short-v3); the wrapper only forwards it, and echoes the
// task's workflow_id at the top level so hosts can key off it directly.
function runV3(root, args) {
  const profile = args.profile || (args.noPrivateRegistry ? 'public' : 'private');
  const cliArgs = [
    'create-short', '--project-root', root, '--profile', profile,
    '--user-goal', args.userGoal || '新开短篇', '--json',
  ];
  const created = runJson(root, 'workflow-v3.js', cliArgs);
  if (!created.ok) return finish({ status: 'short_startup_create_failed', detail: created.value }, created.code || 1, args.json);
  const task = (created.value && created.value.ok && created.value.task) || null;
  if (!task) return finish({ status: 'short_startup_create_failed', detail: created.value }, 1, args.json);
  return finish({ status: 'short_startup_ready', workflow_id: task.workflow_id, task }, 0, args.json);
}

function runLegacyV2(_root, args) {
  return finish({
    status: 'blocked_v2_short_write_frozen',
    reason: 'V2 短篇写入口已冻结；新项目请移除 --legacy-v2，旧项目请通过兼容迁移入口恢复。',
  }, 2, args.json);
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

// Parses argv into a structured object. Value flags (--project-root,
// --user-goal, --reason, --profile) are validated here: a missing value (the
// token is the last arg) or a value that is itself another --flag is a usage
// error (exit 2) BEFORE path.resolve is ever called, so a malformed invocation
// can never start a task or create a stray directory. Boolean flags and unknown
// args are handled explicitly; an unknown arg is also a usage exit 2.
function parseArgs(argv) {
  const out = {
    projectRoot: '.', userGoal: '', restart: false, reason: '',
    legacyV2: false, profile: '', noPrivateRegistry: false, json: false,
  };
  const valueFlags = {
    '--project-root': 'projectRoot',
    '--user-goal': 'userGoal',
    '--reason': 'reason',
    '--profile': 'profile',
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (Object.prototype.hasOwnProperty.call(valueFlags, arg)) {
      const field = valueFlags[arg];
      const next = argv[index + 1];
      // A value flag with no following token, whose following token is
      // another flag, OR whose following token is empty/whitespace-only has no
      // real value: reject as a usage error so the flag token is never swallowed
      // as a directory path or task input, and an empty --project-root / --profile
      // never resolves the cwd or starts a task. This runs before path.resolve.
      if (next === undefined || next.startsWith('--') || String(next).trim() === '') {
        usageError(`${arg} requires a value`);
      }
      out[field] = next;
      index += 1;
    } else if (arg === '--restart') out.restart = true;
    else if (arg === '--legacy-v2') out.legacyV2 = true;
    else if (arg === '--no-private-registry') out.noPrivateRegistry = true;
    else if (arg === '--json') out.json = true;
    else usageError(`unknown argument: ${arg}`);
  }
  return out;
}
function finish(value, code, json) { process.stdout.write(`${json ? JSON.stringify(value) : String((value || {}).status || '')}\n`); return code; }

process.exitCode = main();
