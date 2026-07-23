#!/usr/bin/env node
'use strict';

const { checkShortProseEntry } = require('./lib/short-prose-entry-guard');

function parseArgs(argv) {
  const args = { command: argv[2] || '', projectRoot: '', briefPath: '', sectionIndex: 0, acceptedAnchorPath: '', json: false };
  for (let index = 3; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--brief') args.briefPath = argv[++index] || '';
    else if (arg === '--section-index') args.sectionIndex = Number(argv[++index] || 0);
    else if (arg === '--accepted-anchor') args.acceptedAnchorPath = argv[++index] || '';
    else if (arg === '--json') args.json = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (args.command !== 'check' || !args.projectRoot || !args.briefPath || !Number.isInteger(args.sectionIndex) || args.sectionIndex < 1) {
    throw new Error('Usage: node scripts/short-prose-entry-guard.js check --project-root <dir> --brief <relative.md> --section-index <n> [--accepted-anchor <relative>] [--json]');
  }
  return args;
}

try {
  const args = parseArgs(process.argv);
  const result = checkShortProseEntry(args);
  process.stdout.write(`${JSON.stringify(result, null, args.json ? 2 : 0)}\n`);
  process.exitCode = 0;
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}
