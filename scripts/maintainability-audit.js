#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node scripts/maintainability-audit.js [--repo-root <dir>] [--json]

Checks skill-layer maintainability contracts without calling a model or modifying projects.`;

const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const repoRoot = path.resolve(readOption('--repo-root') || path.join(__dirname, '..'));

if (args.includes('-h') || args.includes('--help')) {
  console.log(USAGE);
  process.exit(0);
}

const requiredContracts = [
  {
    id: 'maintainability_kernel',
    file: 'src/internal-skills/story-workflow/references/maintainability-kernel.md',
    anchors: ['single_entry', 'l2_l3_boundary', 'upstream_absorption_gate'],
  },
  {
    id: 'workflow_contract',
    file: 'src/internal-skills/story-workflow/references/workflow-contract.md',
    anchors: ['workflow packet', 'result packet', 'runtime_guard', 'pending_action'],
  },
  {
    id: 'output_safety_contract',
    file: 'src/internal-skills/story-workflow/references/output-safety-contract.md',
    anchors: ['blocked_model_degradation', 'blocked_tool_command_contaminated', 'blocked_write_failure'],
  },
];

const workflowModules = [
  'story-long-write',
  'story-review',
  'story-long-analyze',
  'story-deslop',
  'story-short-write',
  'story-setup',
];

const outputSafetyModules = [
  'story-long-write',
  'story-review',
  'story-long-analyze',
  'story-deslop',
  'story-short-write',
];

const checks = [];

for (const contract of requiredContracts) {
  checkFileAnchors(contract.id, contract.file, contract.anchors);
}

checkFileAnchors('story_workflow_contract_refs', 'src/internal-skills/story-workflow/SKILL.md', [
  'maintainability-kernel.md',
  'workflow-contract.md',
  'output-safety-contract.md',
]);

for (const module of workflowModules) {
  checkFileAnchors(`module_${module}_workflow_contract`, `src/internal-skills/${module}/SKILL.md`, [
    'workflow-contract.md',
  ]);
}

for (const module of outputSafetyModules) {
  checkFileAnchors(`module_${module}_output_safety_contract`, `src/internal-skills/${module}/SKILL.md`, [
    'output-safety-contract.md',
  ]);
}

checkFileAnchors('production_readiness_docs', 'docs/production-readiness.md', ['maintainability-audit.js']);
checkFileAnchors('scripts_readme_docs', 'scripts/README.md', ['maintainability-audit.js']);
checkFileAnchors('production_smoke_docs', 'scripts/production-smoke-matrix.js', ['maintainability-audit.js']);

for (const bundle of ['novel-assistant']) {
  for (const contract of requiredContracts) {
    const rel = contract.file.replace(
      'src/internal-skills/story-workflow/',
      `skills/${bundle}/references/internal-skills/story-workflow/`
    );
    checkFileAnchors(`bundle_${bundle}_${contract.id}`, rel, contract.anchors);
  }
}

const failCount = checks.filter((check) => check.status === 'fail').length;
const warnCount = checks.filter((check) => check.status === 'warn').length;
const status = failCount > 0 ? 'fail' : warnCount > 0 ? 'warn' : 'pass';
const result = {
  schemaVersion: '1.0.0',
  status,
  repoRoot,
  checks,
  findings: checks.filter((check) => check.status !== 'pass'),
};

if (jsonOutput) {
  process.stdout.write(JSON.stringify(result));
  process.stdout.write('\n');
} else {
  console.log(`Maintainability audit: ${status}`);
  for (const check of checks) {
    const suffix = check.missing && check.missing.length ? ` missing=${check.missing.join(',')}` : '';
    console.log(`- [${check.status}] ${check.id}: ${check.file}${suffix}`);
  }
}

process.exit(status === 'fail' ? 1 : 0);

function readOption(name) {
  const index = args.indexOf(name);
  if (index === -1) return null;
  const value = args[index + 1];
  if (!value || value.startsWith('--')) {
    console.error(`Error: ${name} requires a value`);
    process.exit(2);
  }
  return value;
}

function checkFileAnchors(id, relFile, anchors) {
  const abs = path.join(repoRoot, relFile);
  if (!fs.existsSync(abs)) {
    checks.push({ id, file: relFile, status: 'fail', missing: ['file'] });
    return;
  }

  const text = fs.readFileSync(abs, 'utf8');
  const missing = anchors.filter((anchor) => !text.includes(anchor));
  checks.push({
    id,
    file: relFile,
    status: missing.length ? 'fail' : 'pass',
    missing,
  });
}
