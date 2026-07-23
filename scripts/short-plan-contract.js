#!/usr/bin/env node
'use strict';

const { checkShortPlanContract } = require('./lib/short-plan-contract');

function parseArgs(argv) {
  const args = { command: argv[2] || '', projectRoot: '', json: false };
  for (let index = 3; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--json') args.json = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (args.command !== 'check' || !args.projectRoot) {
    throw new Error('Usage: node scripts/short-plan-contract.js check --project-root <dir> [--json]');
  }
  return args;
}

try {
  const args = parseArgs(process.argv);
  const result = checkShortPlanContract(args.projectRoot);
  process.stdout.write(`${JSON.stringify(result, null, args.json ? 2 : 0)}\n`);
  process.exitCode = 0;
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
