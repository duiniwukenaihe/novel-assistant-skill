#!/usr/bin/env node
'use strict';

const path = require('path');
const compatibility = require('./lib/workflow-v3/compatibility-gateway');

function parseArgs(argv) {
  const args = { projectRoot: '', write: false, confirm: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--write') args.write = true;
    else if (arg === '--confirm') args.confirm = true;
    else if (arg === '--json') args.json = true;
    else fail(`Unknown argument: ${arg}`);
  }
  if (!args.projectRoot) fail('Missing --project-root');
  return args;
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(2);
}

const args = parseArgs(process.argv.slice(2));
const output = compatibility.migrateLegacyShortProject(path.resolve(args.projectRoot), {
  write: args.write,
  confirm: args.confirm,
});
process.stdout.write(`${JSON.stringify(output, null, args.json ? 2 : 0)}\n`);
process.exitCode = Number(output.exitCode || 0);
