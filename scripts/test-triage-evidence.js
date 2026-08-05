#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');

function sha256(value) {
  return `sha256:${crypto.createHash('sha256').update(String(value)).digest('hex')}`;
}

function parseTap(text) {
  const lines = String(text || '').split(/\r?\n/);
  let total = 0;
  const failures = [];
  for (const line of lines) {
    const plan = line.match(/^1\.\.(\d+)\s*$/);
    if (plan) total = Number(plan[1]);
    const failed = line.match(/^not ok\s+(\d+)\s*(?:-\s*)?(.*)$/);
    if (failed) {
      failures.push({ number: Number(failed[1]), name: failed[2].trim() || `test ${failed[1]}` });
    }
  }
  return { total, failed: failures.length, failures };
}

function parseArgs(argv) {
  const separator = argv.indexOf('--');
  if (separator === -1) throw new Error('missing -- before test files');
  const optionArgs = argv.slice(0, separator);
  const tests = argv.slice(separator + 1);
  const args = { runId: '', runner: '', output: '', tests };
  for (let index = 0; index < optionArgs.length; index += 1) {
    const arg = optionArgs[index];
    if (arg === '--run-id') args.runId = optionArgs[++index] || '';
    else if (arg === '--runner') args.runner = optionArgs[++index] || '';
    else if (arg === '--output') args.output = optionArgs[++index] || '';
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!/^[A-Za-z0-9._-]+$/.test(args.runId)) throw new Error('run-id must use letters, digits, dot, underscore, or dash');
  if (!['bats', 'lite'].includes(args.runner)) throw new Error('runner must be bats or lite');
  if (!path.isAbsolute(args.output)) throw new Error('output must be absolute');
  if (!args.tests.length) throw new Error('at least one test file is required');
  return args;
}

function normalizeTests(tests) {
  return tests.map((input) => {
    const absolute = path.resolve(REPO_ROOT, input);
    const relative = path.relative(REPO_ROOT, absolute).split(path.sep).join('/');
    if (!relative.startsWith('tests/') || !relative.endsWith('.bats') || relative.includes('/../')) {
      throw new Error(`test file must stay under tests and end in .bats: ${input}`);
    }
    if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) throw new Error(`missing test file: ${relative}`);
    return relative;
  });
}

function capture(args) {
  const tests = normalizeTests(args.tests);
  const runnerScript = args.runner === 'bats' ? 'scripts/run-bats-tests.sh' : 'scripts/run-bats-lite.sh';
  const command = ['bash', runnerScript, ...tests];
  const result = spawnSync(command[0], command.slice(1), {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    shell: false,
    maxBuffer: 100 * 1024 * 1024,
  });
  const stdout = String(result.stdout || '');
  const stderr = String(result.stderr || '');
  const combined = stderr ? `${stdout}${stdout && !stdout.endsWith('\n') ? '\n' : ''}${stderr}` : stdout;
  const parsed = parseTap(combined);
  const evidence = {
    schemaVersion: '1.0.0',
    runId: args.runId,
    runner: args.runner,
    command,
    testFiles: tests,
    exitCode: Number.isInteger(result.status) ? result.status : 1,
    signal: result.signal || '',
    total: parsed.total,
    failed: parsed.failed,
    failures: parsed.failures,
    stdoutSha256: sha256(combined),
    stdout: combined,
  };
  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, `${JSON.stringify(evidence, null, 2)}\n`);
  return evidence;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const evidence = capture(args);
  process.stdout.write(`${JSON.stringify({
    status: 'captured',
    output: args.output,
    runner: evidence.runner,
    total: evidence.total,
    failed: evidence.failed,
    exitCode: evidence.exitCode,
    stdoutSha256: evidence.stdoutSha256,
  })}\n`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}

module.exports = { capture, parseArgs, parseTap, sha256 };
