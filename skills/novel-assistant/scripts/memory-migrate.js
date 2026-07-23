#!/usr/bin/env node
'use strict';

const { migrateLegacySources } = require('./lib/memory-projection');

try {
  const args = parseArgs(process.argv);
  if (!args.projectRoot) throw failure('blocked_invalid_argument', 'missing --project-root');
  const result = migrateLegacySources(args.projectRoot, args.sources, { write: args.write });
  const output = args.write ? result : {
    ...result,
    status: 'migration_preview',
    would_create_or_refresh: result.created,
  };
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
} catch (error) {
  process.stdout.write(`${JSON.stringify({
    status: error && error.status ? error.status : 'error',
    message: String(error && error.message ? error.message : error),
  }, null, 2)}\n`);
  process.exitCode = 2;
}

function parseArgs(argv) {
  const out = { projectRoot: '', sources: [], write: false, json: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '';
    else if (arg === '--source') out.sources.push(argv[++index] || '');
    else if (arg === '--write') out.write = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '-h' || arg === '--help') {
      process.stdout.write('Usage: node memory-migrate.js --project-root <book-dir> [--source <relative-path>] [--write] [--json]\n');
      process.exit(0);
    } else throw failure('blocked_invalid_argument', `unknown argument: ${arg}`);
  }
  return out;
}

function failure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}
