#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { classifyTaskComplexity } = require('./lib/task-complexity-policy');
const { compactToolOutput } = require('./lib/tool-output-compactor');

function parseArgs(argv) {
  const args = { fixtureDir: '', json: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--json') args.json = true;
    else if (arg === '--fixture-dir') args.fixtureDir = argv[++index] || '';
    else fail(`unknown argument: ${arg}`);
  }
  if (!args.fixtureDir) fail('missing --fixture-dir');
  return args;
}

function fail(message) {
  process.stderr.write(`Error: ${message}\n`);
  process.exit(2);
}

function sourceMetrics(requests) {
  const seen = new Set();
  let rawReads = 0;
  let reuses = 0;
  for (const request of Array.isArray(requests) ? requests : []) {
    const key = `${String(request.source_id || '')}\n${String(request.source_digest || '')}`;
    if (seen.has(key)) reuses += 1;
    else {
      seen.add(key);
      rawReads += 1;
    }
  }
  return { raw_source_reads: rawReads, artifact_reuses: reuses };
}

function run(fixtureDir) {
  const root = path.resolve(fixtureDir);
  const scenarios = JSON.parse(fs.readFileSync(path.join(root, 'scenarios.json'), 'utf8'));
  const noisyOutput = fs.readFileSync(path.join(root, 'noisy-tool.log'), 'utf8');
  const taskResults = {};
  for (const task of scenarios.tasks || []) {
    taskResults[task.id] = classifyTaskComplexity(task);
  }
  const toolOutput = compactToolOutput(noisyOutput, { kind: 'test' });
  const qualityGates = Array.from(new Set((scenarios.required_quality_gates || []).map(String)));
  const findings = [];
  if ((taskResults['short-section'] || {}).recommended_agent_count !== 1) findings.push('short_task_not_single_agent');
  if ((taskResults['long-review'] || {}).recommended_agent_count > 3) findings.push('large_review_agent_cap_exceeded');
  if (toolOutput.compression_ratio < 0.6) findings.push('tool_output_compression_below_target');
  for (const required of ['machine_gate', 'story_gate', 'continuity_gate']) {
    if (!qualityGates.includes(required)) findings.push(`quality_gate_missing:${required}`);
  }
  return {
    schemaVersion: '1.0.0',
    status: findings.length ? 'failed' : 'pass',
    task_results: taskResults,
    tool_output: toolOutput,
    sources: sourceMetrics(scenarios.source_requests),
    quality_gates: qualityGates,
    findings,
    note: '确定性 fixture 指标，不冒充宿主实际 Token 或费用。',
  };
}

try {
  const args = parseArgs(process.argv);
  const report = run(args.fixtureDir);
  process.stdout.write(args.json ? `${JSON.stringify(report, null, 2)}\n` : `${report.status}\n`);
  if (report.status !== 'pass') process.exitCode = 1;
} catch (error) {
  fail(error.message);
}

module.exports = { run, sourceMetrics };
