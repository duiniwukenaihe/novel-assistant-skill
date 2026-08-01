#!/usr/bin/env node
'use strict';

const { ingestSource } = require('./lib/source-ingestion-cache');

function parseArgs(argv) {
  const args = { projectRoot: '', taskDir: '', source: '', json: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--json') args.json = true;
    else if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--task-dir') args.taskDir = argv[++index] || '';
    else if (arg === '--source') args.source = argv[++index] || '';
    else fail(`unknown argument: ${arg}`);
  }
  if (!args.projectRoot) fail('missing --project-root');
  if (!args.taskDir) fail('missing --task-dir');
  if (!args.source) fail('missing --source');
  return args;
}

function fail(message) {
  process.stderr.write(`Error: ${message}\n`);
  process.exit(2);
}

try {
  const args = parseArgs(process.argv);
  const result = ingestSource(args.projectRoot, args);
  process.stdout.write(args.json ? `${JSON.stringify(result)}\n` : `${result.cache_status}: ${result.artifact_path}\n`);
} catch (error) {
  fail(error.message);
}
