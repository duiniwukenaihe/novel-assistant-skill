#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { sourceCommit } = require('./lib/bundle-version');

const SCHEMA_VERSION = '1.0.0';
const REQUIRED_SCENARIOS = Object.freeze([
  'route-single-entry',
  'write-only-section-6',
  'review-1-200',
  'deconstruction-health-stop',
  'review-repair-staged-gate',
  'chapter-commit-conflict',
]);
const REQUIRED_HOSTS = Object.freeze(['claude', 'codex', 'zcode']);

function parseArgs(argv) {
  const args = { repoRoot: process.cwd(), json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') args.json = true;
    else if (arg === '--repo-root') args.repoRoot = path.resolve(argv[++i] || '');
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function currentBundle(repoRoot) {
  const manifestPath = path.join(repoRoot, 'skills', 'novel-assistant', 'novel-assistant-manifest.json');
  const manifest = readJson(manifestPath) || {};
  return {
    bundleId: String(manifest.bundleId || ''),
    sourceCommit: String(manifest.sourceCommit || sourceCommit(repoRoot) || ''),
    manifestPath,
  };
}

function summaryRoots(repoRoot) {
  return [
    path.join(repoRoot, 'reports', 'behavior-eval'),
    path.join(repoRoot, 'reports', 'private', 'behavior-eval'),
  ];
}

function findSummaries(repoRoot) {
  const files = [];
  for (const root of summaryRoots(repoRoot)) {
    if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) continue;
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const file = path.join(root, entry.name, 'summary.json');
      if (fs.existsSync(file)) files.push(file);
    }
  }
  return files;
}

function validateSummary(summary, file, bundle) {
  const scenario = String(((summary || {}).scenario || {}).id || '');
  const findings = [];
  if (!scenario) findings.push('missing_scenario_id');
  if (summary.status !== 'pass') findings.push('summary_not_pass');
  if (summary.paidExecution !== true) findings.push('not_paid_execution');
  if (String(((summary.release_evidence || {}).bundleId) || '') !== bundle.bundleId) findings.push('bundle_mismatch');
  const hosts = Array.isArray(summary.hosts) ? summary.hosts.map(String) : [];
  for (const host of REQUIRED_HOSTS) if (!hosts.includes(host)) findings.push(`missing_host:${host}`);
  const results = Array.isArray(summary.results) ? summary.results : [];
  for (const host of REQUIRED_HOSTS) {
    const result = results.find((item) => String((item || {}).host || '') === host);
    if (!result) {
      findings.push(`missing_host_result:${host}`);
      continue;
    }
    if (result.status !== 'pass') findings.push(`host_not_pass:${host}`);
    const usage = result.usage || {};
    if (usage.complete !== true || usage.source !== 'host') {
      findings.push(`usage_not_host_reported:${host}`);
    }
    const assertions = Array.isArray(result.assertions) ? result.assertions : [];
    if (assertions.length === 0 || assertions.some((item) => item.status !== 'pass' || !Array.isArray(item.evidence) || item.evidence.length === 0)) {
      findings.push(`assertion_evidence_missing:${host}`);
    }
  }
  return {
    scenario,
    file: path.relative(process.cwd(), file),
    ok: findings.length === 0,
    findings,
    updated_at: String(summary.updated_at || ''),
  };
}

function evaluateGate(repoRoot) {
  const root = path.resolve(repoRoot);
  const bundle = currentBundle(root);
  const summaries = findSummaries(root)
    .map((file) => ({ file, summary: readJson(file) }))
    .filter((item) => item.summary && !item.summary.__error)
    .map((item) => validateSummary(item.summary, item.file, bundle));
  const byScenario = new Map();
  for (const item of summaries) {
    if (!REQUIRED_SCENARIOS.includes(item.scenario)) continue;
    const previous = byScenario.get(item.scenario);
    if (!previous || (item.ok && !previous.ok)) byScenario.set(item.scenario, item);
  }
  const scenarioResults = REQUIRED_SCENARIOS.map((scenario) => byScenario.get(scenario) || {
    scenario,
    ok: false,
    findings: ['missing_scenarios'],
    file: '',
  });
  const findings = [];
  for (const item of scenarioResults) {
    if (!item.ok) findings.push({ scenario: item.scenario, findings: item.findings, file: item.file });
  }
  return {
    schemaVersion: SCHEMA_VERSION,
    status: findings.length === 0 ? 'pass' : 'blocked',
    bundle,
    required: {
      scenarios: REQUIRED_SCENARIOS,
      hosts: REQUIRED_HOSTS,
    },
    scenario_results: scenarioResults,
    findings,
  };
}

function printText(result) {
  console.log(`behavior eval release gate: ${result.status}`);
  for (const item of result.findings) {
    console.log(`- ${item.scenario}: ${item.findings.join(', ')}`);
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Usage: node scripts/behavior-eval-release-gate.js [--repo-root PATH] [--json]');
    return 0;
  }
  const result = evaluateGate(args.repoRoot);
  if (args.json) process.stdout.write(`${JSON.stringify(result)}\n`);
  else printText(result);
  return result.status === 'pass' ? 0 : 1;
}

if (require.main === module) {
  try {
    process.exit(main());
  } catch (error) {
    const result = { schemaVersion: SCHEMA_VERSION, status: 'error', error: error.message };
    process.stderr.write(`${JSON.stringify(result)}\n`);
    process.exit(2);
  }
}

module.exports = {
  evaluateGate,
  REQUIRED_SCENARIOS,
  REQUIRED_HOSTS,
};
