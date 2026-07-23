#!/usr/bin/env node
'use strict';

const {
  acceptTransaction,
  inspectChapter,
  prepareTransaction,
  replayProjection,
} = require('./lib/chapter-commit-store');

try {
  const request = parseArgs(process.argv);
  let result;
  if (request.command === 'prepare') result = prepareTransaction(request.projectRoot, request.manifest);
  else if (request.command === 'accept') result = acceptTransaction(request.projectRoot, request.transaction);
  else if (request.command === 'inspect') result = inspectChapter(request.projectRoot, request.volume, request.chapter);
  else if (request.command === 'replay') result = replayProjection(request.projectRoot, request.commit);
  else throw cliFailure('blocked_invalid_command', `unknown command: ${request.command}`);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} catch (error) {
  const result = {
    status: error && error.status ? error.status : 'error',
    message: String(error && error.message ? error.message : error),
  };
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  process.exitCode = 2;
}

function parseArgs(argv) {
  const out = { command: argv[2] || '', projectRoot: '', manifest: '', transaction: '', commit: '', volume: '', chapter: 0 };
  for (let index = 3; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '';
    else if (arg === '--manifest') out.manifest = argv[++index] || '';
    else if (arg === '--transaction') out.transaction = argv[++index] || '';
    else if (arg === '--commit') out.commit = argv[++index] || '';
    else if (arg === '--volume') out.volume = argv[++index] || '';
    else if (arg === '--chapter') out.chapter = Number(argv[++index] || 0);
    else if (arg === '--json') continue;
    else if (arg === '-h' || arg === '--help') usage(0);
    else throw cliFailure('blocked_invalid_argument', `unknown argument: ${arg}`);
  }
  if (!out.projectRoot) throw cliFailure('blocked_invalid_argument', 'missing --project-root');
  if (out.command === 'prepare' && !out.manifest) throw cliFailure('blocked_invalid_argument', 'missing --manifest');
  if (out.command === 'accept' && !out.transaction) throw cliFailure('blocked_invalid_argument', 'missing --transaction');
  if (out.command === 'replay' && !out.commit) throw cliFailure('blocked_invalid_argument', 'missing --commit');
  if (out.command === 'inspect' && (!out.volume || !out.chapter)) throw cliFailure('blocked_invalid_argument', 'inspect requires --volume and --chapter');
  return out;
}

function cliFailure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function usage(code) {
  process.stdout.write('Usage: node chapter-commit.js <prepare|accept|inspect|replay> --project-root <book-dir> [options] [--json]\n');
  process.exit(code);
}
