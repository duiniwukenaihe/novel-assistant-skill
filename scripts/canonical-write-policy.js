'use strict';

const {
  assertCanonicalWriteAllowed,
} = require('./lib/canonical-write-policy');
const {
  acquireChapterWriteLease,
  releaseChapterWriteLease,
} = require('./lib/workflow-state-store');

function main(argv) {
  const args = parseArgs(argv);
  if (args.command === 'check') {
    return assertCanonicalWriteAllowed(args.projectRoot, args.targets, { transactionId: args.transactionId });
  }
  const scope = { volume: args.volume, chapter: args.chapter };
  if (args.command === 'lease') {
    const release = acquireChapterWriteLease(args.projectRoot, scope, args.owner, args.ttlMs);
    return { status: 'leased', lease_file: release.file, lease: release.lease };
  }
  if (args.command === 'release') {
    if (!releaseChapterWriteLease(args.projectRoot, scope, args.token)) {
      throw failure('blocked_chapter_lease_ownership', 'chapter lease is missing or held by another writer');
    }
    return { status: 'released', scope };
  }
  throw failure('blocked_invalid_command', `unknown command: ${args.command}`);
}

function parseArgs(argv) {
  const out = { command: argv[0], targets: [], ttlMs: undefined };
  for (let index = 1; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--json') continue;
    if (arg === '--project-root') out.projectRoot = argv[++index];
    else if (arg === '--target') out.targets.push(argv[++index]);
    else if (arg === '--transaction-id') out.transactionId = argv[++index];
    else if (arg === '--volume') out.volume = argv[++index];
    else if (arg === '--chapter') out.chapter = Number(argv[++index]);
    else if (arg === '--owner') out.owner = argv[++index];
    else if (arg === '--token') out.token = argv[++index];
    else if (arg === '--ttl-ms') out.ttlMs = Number(argv[++index]);
    else throw failure('blocked_invalid_argument', `unknown argument: ${arg}`);
  }
  if (!out.projectRoot) throw failure('blocked_invalid_argument', 'missing --project-root');
  if (out.command === 'check' && !out.targets.length) throw failure('blocked_invalid_argument', 'check requires --target');
  if (['lease', 'release'].includes(out.command) && (!out.volume || !Number.isInteger(out.chapter) || out.chapter < 1)) {
    throw failure('blocked_invalid_argument', `${out.command} requires --volume and a positive --chapter`);
  }
  if (out.command === 'lease' && !out.owner) throw failure('blocked_invalid_argument', 'lease requires --owner');
  if (out.command === 'release' && !out.token) throw failure('blocked_invalid_argument', 'release requires --token');
  if (out.ttlMs !== undefined && (!Number.isFinite(out.ttlMs) || out.ttlMs <= 0)) throw failure('blocked_invalid_argument', '--ttl-ms must be positive');
  return out;
}

function failure(code, message) {
  const error = new Error(message);
  error.code = code;
  return error;
}

if (require.main === module) {
  try {
    process.stdout.write(`${JSON.stringify(main(process.argv.slice(2)), null, 2)}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ status: error.status || error.code || 'blocked_canonical_write_policy_error', message: error.message, targets: error.targets }, null, 2)}\n`);
    process.exitCode = 1;
  }
}

module.exports = { main, parseArgs };
