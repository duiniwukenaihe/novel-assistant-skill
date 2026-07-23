#!/usr/bin/env node
'use strict';

const {
  buildBriefFreshnessSnapshot,
  checkBriefFreshness,
  writeBriefFreshnessSnapshot,
} = require('./lib/short-brief-freshness');

const USAGE = `Usage:
  node scripts/short-brief-freshness.js snapshot --project-root <dir> --brief <relative.md> --section-index <n> [--accepted-anchor <relative>] [--write] --json
  node scripts/short-brief-freshness.js check --project-root <dir> --brief <relative.md> --section-index <n> [--accepted-anchor <relative>] --json`;

function parseArgs(argv) {
  const args = { command: argv[2] || '', projectRoot: '', briefPath: '', sectionIndex: 0, acceptedAnchorPath: '', write: false, json: false };
  for (let i = 3; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--brief') args.briefPath = argv[++i] || '';
    else if (arg === '--section-index') args.sectionIndex = Number(argv[++i] || 0);
    else if (arg === '--accepted-anchor') args.acceptedAnchorPath = argv[++i] || '';
    else if (arg === '--write') args.write = true;
    else if (arg === '--json') args.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!['snapshot', 'check'].includes(args.command) || !args.projectRoot || !args.briefPath || !Number.isInteger(args.sectionIndex) || args.sectionIndex < 1) {
    throw new Error(USAGE);
  }
  return args;
}

function main() {
  try {
    const args = parseArgs(process.argv);
    const options = args;
    const result = args.command === 'check'
      ? checkBriefFreshness(options)
      : args.write
        ? writeBriefFreshnessSnapshot(options)
        : buildBriefFreshnessSnapshot(options);
    process.stdout.write(`${JSON.stringify(result, null, args.json ? 2 : 0)}\n`);
    if (args.command === 'check' && result.status !== 'current') process.exitCode = 2;
    if (args.command === 'snapshot' && result.status === 'missing_dependency') process.exitCode = 2;
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

main();
