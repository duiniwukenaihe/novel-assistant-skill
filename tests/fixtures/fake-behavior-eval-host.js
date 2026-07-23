#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const mode = process.argv[2] || 'success';
const root = process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const runnerPacketRel = process.env.NOVEL_ASSISTANT_RUNNER_PACKET;
const resultPacketRel = process.env.NOVEL_ASSISTANT_RESULT_PACKET;
const attempt = Number(process.env.NOVEL_ASSISTANT_EVALUATION_ATTEMPT || 0);
const host = process.env.NOVEL_ASSISTANT_EVALUATION_HOST;

if (!root || !runnerPacketRel || !resultPacketRel) process.exit(20);

const marker = path.join(root, 'fake-host-invocations.log');
fs.appendFileSync(marker, `${mode}:${attempt}\n`);

if (mode === 'silent') {
  const pidFile = path.join(root, 'fake-host-pids.json');
  const child = spawn(process.execPath, ['-e', 'process.on("SIGTERM", () => {}); setInterval(() => {}, 1000);'], { stdio: 'ignore' });
  fs.writeFileSync(pidFile, JSON.stringify([process.pid, child.pid]));
  process.stdout.write(`${JSON.stringify({ type: 'ready_for_idle_cleanup' })}\n`);
  process.on('SIGTERM', () => {});
  setInterval(() => {}, 1000);
  return;
}

const packet = JSON.parse(fs.readFileSync(path.join(root, runnerPacketRel), 'utf8'));
if (!fs.existsSync(path.join(root, 'fixture', 'fixture.json'))) process.exit(21);

function writeResult() {
  const assertions = packet.scenario.assertions.map((name) => {
    const relative = path.posix.join('artifacts', `${name}.txt`);
    const target = path.join(root, relative);
    const contents = `${packet.scenario.id}:${name}:${attempt}\n`;
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, contents, { mode: 0o600 });
    return {
      name,
      status: 'pass',
      evidence: [{ path: relative, sha256: crypto.createHash('sha256').update(contents).digest('hex') }],
    };
  });
  const resultFile = path.join(root, resultPacketRel);
  fs.mkdirSync(path.dirname(resultFile), { recursive: true });
  fs.writeFileSync(resultFile, `${JSON.stringify({ scenario: packet.scenario.id, assertions }, null, 2)}\n`, { mode: 0o600 });
}

function successEvent(usage, cost) {
  return host === 'codex'
    ? { type: 'turn.completed', status: 'completed', usage, cost_usd: cost }
    : { type: 'result', status: 'completed', usage, cost_usd: cost };
}

if (mode === 'retry' && attempt === 0) {
  process.stdout.write(`${JSON.stringify(successEvent({ input_tokens: 100, output_tokens: 10 }, 0.1))}\n`);
  process.stderr.write('Invalid tool parameters\n'.repeat(4));
  process.exit(1);
}

if (mode === 'provider-unavailable') {
  process.stderr.write('API Error: rate limit exceeded\n');
  process.exit(1);
}

if (mode === 'budget-exhausted') {
  process.stdout.write(`${JSON.stringify({ type: 'result', subtype: 'error_max_budget_usd', usage: { input_tokens: 100, output_tokens: 10 }, total_cost_usd: 0.5 })}\n`);
  process.exit(1);
}

if (mode === 'zcode-response') {
  writeResult();
  process.stdout.write(`${JSON.stringify({ sessionId: 'fixture-zcode-session', response: 'completed without usage telemetry' })}\n`);
  process.exit(0);
}

if (mode === 'zcode-local-usage') {
  writeResult();
  process.stdout.write(`${JSON.stringify({ sessionId: 'sess_fixture-zcode-usage', traceId: 'trace-fixture-zcode-usage', response: 'completed with local telemetry' })}\n`);
  process.exit(0);
}

if (mode === 'zcode-pretty-response') {
  writeResult();
  process.stdout.write(`${JSON.stringify({ sessionId: 'fixture-zcode-session', response: 'completed pretty JSON without usage telemetry' }, null, 2)}\n`);
  process.exit(0);
}

if (mode !== 'no-result') writeResult();
if (mode === 'secret') process.stdout.write('Bearer top-secret-token sk-test-abcdefghijklmnopqrstuv api_key=leak-me\n');

if (mode === 'no-usage') {
  process.stdout.write(`${JSON.stringify(successEvent(undefined, undefined))}\n`);
} else {
  process.stdout.write(`${JSON.stringify(successEvent({ input_tokens: 200, output_tokens: 20, cache_read_input_tokens: 5, cache_creation_input_tokens: 2 }, mode === 'no-cost' ? undefined : 0.2))}\n`);
}
