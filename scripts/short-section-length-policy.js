#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { deriveSectionLengthPolicy } = require('./lib/short-section-length-policy');

function parseArgs(argv) {
  const args = { projectRoot: '', sectionIndex: 0, actual: 0, plannedTarget: 0, sectionRole: 'normal', exceptionReason: '', json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--section-index') args.sectionIndex = Number(argv[++index]);
    else if (arg === '--actual') args.actual = Number(argv[++index]);
    else if (arg === '--planned-target') args.plannedTarget = Number(argv[++index]);
    else if (arg === '--section-role') args.sectionRole = argv[++index] || 'normal';
    else if (arg === '--exception-reason') args.exceptionReason = argv[++index] || '';
    else if (arg === '--json') args.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.projectRoot || !Number.isInteger(args.sectionIndex) || args.sectionIndex < 1) {
    throw new Error('missing --project-root or valid --section-index');
  }
  if (!args.actual && !args.plannedTarget) throw new Error('missing --actual or --planned-target');
  return args;
}

function readProjectState(projectRoot) {
  const root = fs.realpathSync(path.resolve(projectRoot));
  const statePath = path.join(root, '追踪', 'private-short-extension', 'project-state.json');
  const realState = fs.realpathSync(statePath);
  if (!realState.startsWith(`${root}${path.sep}`)) throw new Error('project state escapes project root');
  return JSON.parse(fs.readFileSync(realState, 'utf8'));
}

try {
  const args = parseArgs(process.argv.slice(2));
  const result = deriveSectionLengthPolicy({ ...args, projectState: readProjectState(args.projectRoot) });
  process.stdout.write(`${JSON.stringify(result, null, args.json ? 2 : 0)}\n`);
  // A length miss is a normal workflow decision, not a process failure. The
  // caller reads result.blocking and routes to one bounded repair pass.
  process.exit(0);
} catch (error) {
  process.stdout.write(`${JSON.stringify({ schemaVersion: '1.0.0', status: 'blocked', blocking: true, verdict: 'invalid_input', message: error.message })}\n`);
  process.exit(2);
}
