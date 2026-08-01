#!/usr/bin/env node
'use strict';

const path = require('path');
const { migrateShortStateStorage } = require('./lib/short-project-state');

function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectRoot = path.resolve(args.projectRoot || process.cwd());
  const result = migrateShortStateStorage(projectRoot);
  process.stdout.write(`${JSON.stringify({ schemaVersion: '1.0.0', ...result }, null, args.json ? 2 : 0)}\n`);
}

function parseArgs(argv) {
  const args = { projectRoot: '', json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--project-root') args.projectRoot = argv[++index] || '';
    else if (value === '--json') args.json = true;
    else if (value === '--help' || value === '-h') {
      process.stdout.write('Usage: node scripts/short-state-storage-migrate.js [--project-root <dir>] [--json]\n');
      process.exit(0);
    } else throw new Error(`unknown argument: ${value}`);
  }
  return args;
}

try {
  main();
} catch (error) {
  process.stdout.write(`${JSON.stringify({ schemaVersion: '1.0.0', status: 'blocked_short_state_storage_migration', message: String(error.message || error) })}\n`);
  process.exitCode = 2;
}
