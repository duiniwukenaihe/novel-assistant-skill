#!/usr/bin/env node
'use strict';

// Task 4 subtask B: the V3 short lifecycle CLI. A thin command wrapper that
// delegates EVERY mutation and every render to the Engine and the Arbiter. The
// CLI itself NEVER writes current_stage transitions and NEVER constructs menu
// text or the four-field binding — the Engine drives the graph via nextNode
// inside its atomic commitTask, and renderCommittedInteraction is the sole
// source of interaction text and binding metadata.
//
// Commands:
//   create-short --project-root <root> --profile public|private --user-goal <text> --json
//   show --project-root <root> --workflow-id <id> --json
//   apply-result --project-root <root> --workflow-id <id> --expected-version <n> --result-file <json> --json
//   resolve --project-root <root> --workflow-id <id> --expected-version <n> --input-file <json> --json
//   submit-feedback --project-root <root> --workflow-id <id> --expected-version <n> --input-file <json> --json
//   propose-feedback --project-root <root> --workflow-id <id> --expected-version <n> --input-file <json> --json
//   run-stage --project-root <root> --workflow-id <id> --expected-version <n> --stage <id> --context-file <json> --json
//   describe-stage --project-root <root> --workflow-id <id> --json
//   run-current-stage --project-root <root> --workflow-id <id> --expected-version <n> --json
//
// On any precondition failure or engine error the CLI exits nonzero and prints
// a { ok:false, error } payload; it never prints a success body for a failed
// operation. Success bodies always carry ok:true.

const fs = require('fs');
const path = require('path');

const engine = require('./lib/workflow-v3/engine');
const { renderCommittedInteraction } = require('./lib/workflow-v3/interaction-arbiter');
const stageRunner = require('./lib/workflow-v3/stage-runner');
const stateStore = require('./lib/workflow-state-store');

// The canonical production kernel for the V3 short lifecycle. Both profiles
// declare this kernel; only the workflow_profile field differs.
const SHORT_V3_KERNEL = 'short-v3';
const DIRECT_APPLY_STAGES = Object.freeze(['creative_entry', 'planning_confirmation', 'section_repair']);

// The per-command flag whitelist. Each command accepts ONLY the flags listed
// here (plus the universal --json / -h / --help); any other flag — including a
// flag that is valid for a different command — is rejected as a usage error
// (exit 2) before any read or write. current_stage is deliberately ABSENT from
// every whitelist: the Engine owns that field and stamps it itself, so the CLI
// must never accept it from the command line.
const FLAG_WHITELIST = {
  'create-short': ['project-root', 'profile', 'user-goal'],
  show: ['project-root', 'workflow-id'],
  'apply-result': ['project-root', 'workflow-id', 'expected-version', 'result-file'],
  resolve: ['project-root', 'workflow-id', 'expected-version', 'input-file'],
  'submit-feedback': ['project-root', 'workflow-id', 'expected-version', 'input-file'],
  'propose-feedback': ['project-root', 'workflow-id', 'expected-version', 'input-file'],
  'run-stage': ['project-root', 'workflow-id', 'expected-version', 'stage', 'context-file'],
  'describe-stage': ['project-root', 'workflow-id'],
  'run-current-stage': ['project-root', 'workflow-id', 'expected-version'],
};

const argv = process.argv.slice(2);
const command = argv[0];

try {
  if (command === 'create-short') runCreateShort(parseFlags(argv.slice(1), 'create-short'));
  else if (command === 'show') runShow(parseFlags(argv.slice(1), 'show'));
  else if (command === 'apply-result') runApplyResult(parseFlags(argv.slice(1), 'apply-result'));
  else if (command === 'resolve') runResolve(parseFlags(argv.slice(1), 'resolve'));
  else if (command === 'submit-feedback') runSubmitFeedback(parseFlags(argv.slice(1), 'submit-feedback'));
  else if (command === 'propose-feedback') runProposeFeedback(parseFlags(argv.slice(1), 'propose-feedback'));
  else if (command === 'run-stage') runRunStage(parseFlags(argv.slice(1), 'run-stage'));
  else if (command === 'describe-stage') runDescribeStage(parseFlags(argv.slice(1), 'describe-stage'));
  else if (command === 'run-current-stage') runRunCurrentStage(parseFlags(argv.slice(1), 'run-current-stage'));
  else if (command === '--help' || command === '-h' || command === 'help' || command === undefined) printUsage();
  else fail(`unknown command: ${command}`);
} catch (error) {
  fail(error);
}

// create-short generates the workflow_id via the shared createWorkflowId and
// hands a plain input record to engine.createTask. The Engine (via task-store)
// stamps the three contract versions AND the entry stage (creative_entry), and
// persists task.json as the sole authority. The CLI only supplies
// lifecycle-agnostic inputs: profile, kernel, and a portable book_root. It
// never defines or forwards current_stage — that is Engine authority.
function runCreateShort(flags) {
  const projectRoot = required(flags, 'project-root', 'create-short');
  const profile = normalizeProfile(required(flags, 'profile', 'create-short'));
  const userGoal = String(flags['user-goal'] || '').trim();
  if (!userGoal) usage('create-short: --user-goal is required');

  // The workflow_id is generated here, exactly as the V2 state machine does,
  // using the shared store helper so id shape stays consistent across hosts.
  const workflowId = stateStore.createWorkflowId('short_write');
  const task = engine.createTask(projectRoot, {
    workflow_id: workflowId,
    workflow_type: 'short_write',
    workflow_profile: profile,
    production_kernel: SHORT_V3_KERNEL,
    user_goal: userGoal,
    book_root: '.',
    resume_matching_family: true,
  });

  finish({ ok: true, task, resumed_existing: task.workflow_id !== workflowId });
}

// show reads the committed snapshot and renders an interaction ONLY when a
// committed pending action exists. The text and four-field binding come
// exclusively from renderCommittedInteraction; the CLI never assembles them.
function runShow(flags) {
  const projectRoot = required(flags, 'project-root', 'show');
  const workflowId = required(flags, 'workflow-id', 'show');
  const task = engine.readTask(projectRoot, workflowId);

  const pending = task.pending_action;
  const interaction = (pending && pending.status === 'pending')
    ? renderCommittedInteraction(task)
    : null;

  finish({ ok: true, task, interaction });
}

// apply-result reads a stage result from --result-file and forwards it to the
// Engine. The Engine validates stage identity, drives the graph transition via
// nextNode inside its atomic commit, and renders any visible response off the
// committed snapshot. The CLI performs no transition logic of its own.
function runApplyResult(flags) {
  const projectRoot = required(flags, 'project-root', 'apply-result');
  const workflowId = required(flags, 'workflow-id', 'apply-result');
  const expectedVersion = parseVersion(required(flags, 'expected-version', 'apply-result'));
  const task = engine.readTask(projectRoot, workflowId);
  if (!DIRECT_APPLY_STAGES.includes(String(task.current_stage || ''))) {
    throw new Error(`professional_stage_requires_run_stage:${String(task.current_stage || 'unknown')}`);
  }
  const result = readJsonFile(required(flags, 'result-file', 'apply-result'), 'apply-result');

  const outcome = engine.applyStageResult(projectRoot, workflowId, expectedVersion, result);
  finish({ ok: true, task: outcome.task, visible_response: outcome.visible_response });
}

// resolve reads an input-file carrying the four-field binding plus the author
// choice, and forwards it to engine.resolveAuthorInput. The Engine re-asserts
// the binding under the lock and atomically marks the pending action resolved.
function runResolve(flags) {
  const projectRoot = required(flags, 'project-root', 'resolve');
  const workflowId = required(flags, 'workflow-id', 'resolve');
  const expectedVersion = parseVersion(required(flags, 'expected-version', 'resolve'));
  const input = readJsonFile(required(flags, 'input-file', 'resolve'), 'resolve');

  const selection = engine.resolveAuthorInput(projectRoot, workflowId, expectedVersion, input);
  finish({ ok: true, selection });
}

function runSubmitFeedback(flags) {
  const projectRoot = required(flags, 'project-root', 'submit-feedback');
  const workflowId = required(flags, 'workflow-id', 'submit-feedback');
  const expectedVersion = parseVersion(required(flags, 'expected-version', 'submit-feedback'));
  const input = readJsonFile(required(flags, 'input-file', 'submit-feedback'), 'submit-feedback');
  const keys = Object.keys(input).sort();
  if (keys.length !== 1 || keys[0] !== 'text') {
    fail('submit-feedback: --input-file must contain only text');
  }

  const outcome = engine.submitAuthorFeedback(projectRoot, workflowId, expectedVersion, input);
  finish({ ok: true, task: outcome.task, feedback_receipt: outcome.feedback_receipt });
}

function runProposeFeedback(flags) {
  const projectRoot = required(flags, 'project-root', 'propose-feedback');
  const workflowId = required(flags, 'workflow-id', 'propose-feedback');
  const expectedVersion = parseVersion(required(flags, 'expected-version', 'propose-feedback'));
  const input = readJsonFile(required(flags, 'input-file', 'propose-feedback'), 'propose-feedback');
  const expectedKeys = ['affected_sections', 'evidence', 'feedback_id', 'impact_level', 'proposed_changes', 'summary'];
  if (JSON.stringify(Object.keys(input).sort()) !== JSON.stringify(expectedKeys)) {
    fail(`propose-feedback: --input-file must contain exactly ${expectedKeys.join(', ')}`);
  }
  if (!Array.isArray(input.affected_sections)
      || !Array.isArray(input.evidence)
      || !Array.isArray(input.proposed_changes)) {
    fail('propose-feedback: affected_sections, evidence and proposed_changes must be arrays');
  }

  const outcome = engine.proposeAuthorFeedbackPlan(projectRoot, workflowId, expectedVersion, input);
  finish({
    ok: true,
    task: outcome.task,
    feedback_receipt: outcome.feedback_receipt,
    visible_response: outcome.visible_response,
  });
}

// run-stage is the production entry point for staged-artifact stages. It
// re-reads task.json, validates the version + current_stage, dispatches the
// professional service, and hands the returned StageResult to
// engine.applyStageResult. The success body surfaces the stage_result the
// service produced alongside the applied task and any rendered interaction,
// so callers (and the E2E) can see both the engine-stamped transition and the
// service-owned result in one response.
function runRunStage(flags) {
  const projectRoot = required(flags, 'project-root', 'run-stage');
  const workflowId = required(flags, 'workflow-id', 'run-stage');
  const expectedVersion = parseVersion(required(flags, 'expected-version', 'run-stage'));
  const stage = required(flags, 'stage', 'run-stage');
  const contextFile = required(flags, 'context-file', 'run-stage');

  const outcome = stageRunner.runStage({
    projectRoot,
    workflowId,
    expectedVersion,
    stage,
    contextFile,
  });
  finish({
    ok: true,
    stage_result: outcome.stage_result,
    task: outcome.task,
    visible_response: outcome.visible_response,
  });
}

function runDescribeStage(flags) {
  const projectRoot = required(flags, 'project-root', 'describe-stage');
  const workflowId = required(flags, 'workflow-id', 'describe-stage');
  finish({ ok: true, stage_execution: stageRunner.describeCurrentStage({ projectRoot, workflowId }) });
}

function runRunCurrentStage(flags) {
  const projectRoot = required(flags, 'project-root', 'run-current-stage');
  const workflowId = required(flags, 'workflow-id', 'run-current-stage');
  const expectedVersion = parseVersion(required(flags, 'expected-version', 'run-current-stage'));
  const outcome = stageRunner.runCurrentStage({ projectRoot, workflowId, expectedVersion });
  finish({
    ok: true,
    stage_result: outcome.stage_result,
    task: outcome.task,
    visible_response: outcome.visible_response,
  });
}

// --- helpers ---------------------------------------------------------------

// Parses --flag value pairs into a flat object, enforcing the command-specific
// whitelist. --json is a universal boolean flag; -h/--help prints usage and
// exits 0. Every other flag must be in the command's whitelist or it is a usage
// error (exit 2) before any read/write — a typo, a flag from the wrong command,
// or a forbidden engine-owned field like current_stage all stop here.
function parseFlags(tokens, command) {
  const allowed = FLAG_WHITELIST[command] || [];
  const out = {};
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token === '--json') { out.json = true; continue; }
    if (token === '-h' || token === '--help') { printUsage(); }
    if (token.startsWith('--')) {
      const key = token.slice(2);
      if (!allowed.includes(key)) {
        usage(`${command}: unknown flag --${key}`);
      }
      const value = tokens[i + 1];
      if (value === undefined || value.startsWith('--')) usage(`${command}: flag --${key} requires a value`);
      out[key] = value;
      i += 1;
    } else {
      usage(`${command}: unexpected argument: ${token}`);
    }
  }
  return out;
}

function required(flags, key, command) {
  const value = flags[key];
  if (value === undefined || String(value).trim() === '') usage(`${command}: --${key} is required`);
  return value;
}

function normalizeProfile(raw) {
  const profile = String(raw || '').trim();
  if (profile !== 'public' && profile !== 'private') usage(`--profile must be 'public' or 'private' (got: ${profile})`);
  return profile;
}

function parseVersion(raw) {
  const version = Number(raw);
  if (!Number.isInteger(version) || version < 0) usage(`--expected-version must be a non-negative integer (got: ${raw})`);
  return version;
}

function readJsonFile(file, command) {
  let parsed;
  try {
    const text = fs.readFileSync(path.resolve(file), 'utf8');
    parsed = JSON.parse(text);
  } catch (error) {
    fail(`${command}: cannot read --file ${file}: ${error.message}`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    fail(`${command}: --file ${file} must contain a JSON object`);
  }
  return parsed;
}

function printUsage() {
  process.stdout.write([
    'Usage: workflow-v3.js <command> [flags] --json',
    '',
    'Commands:',
    '  create-short  --project-root <root> --profile public|private --user-goal <text> --json',
    '  show          --project-root <root> --workflow-id <id> --json',
    '  apply-result  --project-root <root> --workflow-id <id> --expected-version <n> --result-file <json> --json',
    '  resolve       --project-root <root> --workflow-id <id> --expected-version <n> --input-file <json> --json',
    '  submit-feedback --project-root <root> --workflow-id <id> --expected-version <n> --input-file <json> --json',
    '  propose-feedback --project-root <root> --workflow-id <id> --expected-version <n> --input-file <json> --json',
    '  run-stage     --project-root <root> --workflow-id <id> --expected-version <n> --stage <id> --context-file <json> --json',
    '  describe-stage --project-root <root> --workflow-id <id> --json',
    '  run-current-stage --project-root <root> --workflow-id <id> --expected-version <n> --json',
    '',
  ].join('\n'));
  process.exit(0);
}

// Success: print the payload (always carrying ok:true) and exit 0.
function finish(value) {
  // Success payloads can include a migrated task history larger than the
  // stdout pipe buffer. Write synchronously before the deliberate exit so the
  // JSON cannot be truncated at 64 KiB.
  fs.writeSync(1, `${JSON.stringify(value, null, 2)}\n`);
  process.exit(0);
}

// Usage errors: programmer mistake in the command line. Print to stderr, exit 2.
function usage(message) {
  process.stderr.write(`${message}\n`);
  process.exit(2);
}

// Operation errors: a precondition failed or the Engine rejected the request
// (e.g. stale expected-version, stage mismatch, binding tamper). Print a
// structured { ok:false } payload to stdout and exit nonzero so callers can
// distinguish a rejected operation from a success.
function fail(error) {
  const message = error instanceof Error ? error.message : String(error);
  const payload = { ok: false, error: message };
  if (error && error.code) payload.code = error.code;
  if (error && error.status) payload.status = error.status;
  process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
  process.exit(1);
}
