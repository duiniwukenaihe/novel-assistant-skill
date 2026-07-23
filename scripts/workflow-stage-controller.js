#!/usr/bin/env node
'use strict';

// workflow-stage-controller
//
// Thin CLI wrapper around lib/workflow-stage-controller.advanceStage.
// This is the single command hosts should call to advance one workflow stage
// atomically: it replaces the manual inspect / apply-result / reconcile-runtime
// chain that caused the short-sixth-section runaway-token incident.
//
// Usage:
//   node scripts/workflow-stage-controller.js advance \
//     --project-root <book> --workflow-id <id> \
//     --result <result.json> \
//     [--session-id <id>] \
//     [--private-registry-root <dir>] [--no-private-registry] \
//     --json
//
// Flags mirror workflow-state-machine.js for registry loading. The controller
// never shells out to other CLI tools; it composes the library components
// directly (template registry, transition service, task authority, state store).

const { advanceStage } = require('./lib/workflow-stage-controller');

const USAGE = `Usage: node scripts/workflow-stage-controller.js <command> [options]

Commands:
  advance   Atomically advance one workflow stage from a result packet.

advance:
  advance --project-root <book> --workflow-id <id> --result <file> \\
           [--session-id <id>] [--private-registry-root <dir>] \\
           [--no-private-registry] --json

Exit status:
  0  command produced a JSON result (including blocked / paused statuses —
     those are workflow states, not process errors)
  1  invalid arguments / unexpected internal error

Status values in --json output:
  advanced                  clean one-shot transition
  recovered_once            first attempt failed (stale state / transient), retry succeeded
  paused_transition_failure two consecutive same failures; task parked at trusted checkpoint
  blocked_*                 non-recoverable (registry unavailable, bad packet, etc.)`;

function parseArgs(argv) {
  const command = argv[2] || '';
  const args = {
    command,
    json: false,
    projectRoot: '',
    workflowId: '',
    result: '',
    sessionId: '',
    privateRegistryRoot: '',
    noPrivateRegistry: false,
    expectedStateVersion: null,
  };
  for (let i = 3; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') args.json = true;
    else if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--workflow-id') args.workflowId = argv[++i] || '';
    else if (arg === '--result') args.result = argv[++i] || '';
    else if (arg === '--session-id') args.sessionId = argv[++i] || '';
    else if (arg === '--private-registry-root') args.privateRegistryRoot = argv[++i] || '';
    else if (arg === '--no-private-registry') args.noPrivateRegistry = true;
    else if (arg === '--expected-state-version') {
      const raw = argv[++i];
      const parsed = Number(raw);
      args.expectedStateVersion = Number.isInteger(parsed) ? parsed : null;
    } else if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }
  if (!['advance'].includes(command)) fail('missing or invalid command');
  if (!args.projectRoot) fail('missing --project-root');
  if (!args.workflowId) fail('missing --workflow-id');
  if (command === 'advance' && !args.result) fail('missing --result');
  return args;
}

function fail(message) {
  process.stderr.write(`Error: ${message}\n`);
  process.stderr.write(`${USAGE}\n`);
  process.exit(1);
}

function main() {
  const args = parseArgs(process.argv);
  let result;
  try {
    result = advanceStage({
      projectRoot: args.projectRoot,
      workflowId: args.workflowId,
      resultPath: args.result,
      sessionId: args.sessionId,
      privateRegistryRoot: args.privateRegistryRoot,
      noPrivateRegistry: args.noPrivateRegistry,
      expectedStateVersion: args.expectedStateVersion,
    });
  } catch (error) {
    // Unexpected internal error: surface to stderr and exit non-zero so the
    // host can distinguish "controller itself crashed" from a workflow status.
    process.stderr.write(`workflow-stage-controller: ${error && error.message ? error.message : 'unexpected error'}\n`);
    process.exit(1);
  }
  if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    const summary = [
      `status=${result.status}`,
      result.workflow_id ? `workflow_id=${result.workflow_id}` : '',
      result.next_stage ? `next_stage=${result.next_stage}` : '',
      `recovery_count=${result.recovery_count === undefined ? 0 : result.recovery_count}`,
      result.last_trusted_artifact ? `last_trusted_artifact=${result.last_trusted_artifact}` : '',
      result.reason ? `reason=${result.reason}` : '',
    ].filter(Boolean).join(' ');
    process.stdout.write(`${summary}\n`);
  }
  // Workflow statuses (advanced / recovered_once / paused / blocked) all exit
  // 0 so callers can rely on exit status only for "the controller itself
  // failed to produce a decision".
  process.exit(0);
}

main();
