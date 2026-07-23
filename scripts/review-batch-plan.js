#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { planReviewBatches } = require('./lib/review-batch-planner');
const { atomicWriteJson } = require('./lib/workflow-state-store');

try {
  const args = parseArgs(process.argv.slice(2));
  if (!args.projectRoot || !args.scope) throw new Error('usage: review-batch-plan.js <book-project-dir> --scope <start-end> [--budget-policy <json>] [--write] [--json]');
  const root = path.resolve(args.projectRoot);
  const chapters = readJsonl(path.join(root, 'evidence', 'chapter-evidence.jsonl'));
  const planned = planReviewBatches({
    chapters,
    parentScope: args.scope,
    requiredDimensions: args.requiredDimensions,
    budgetPolicy: args.budgetPolicy,
    availableAgents: args.agentsAvailable,
  });
  if (args.write) atomicWriteJson(path.join(root, 'evidence', 'review-batch-plan.json'), planned);
  process.stdout.write(`${JSON.stringify(args.json ? planned : { status: 'ok', batches: planned.batches.length }, null, 2)}\n`);
} catch (error) {
  fail(error.message);
}

function parseArgs(argv) {
  const out = { projectRoot: '', scope: '', budgetPolicy: {}, requiredDimensions: undefined, agentsAvailable: undefined, write: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (!value.startsWith('-') && !out.projectRoot) out.projectRoot = value;
    else if (value === '--scope') out.scope = argv[++index] || '';
    else if (value === '--budget-policy') {
      const raw = argv[++index];
      if (!raw || raw.startsWith('--')) throw new Error('missing value for --budget-policy');
      try {
        out.budgetPolicy = JSON.parse(raw);
      } catch (_error) {
        throw new Error('invalid --budget-policy JSON');
      }
    }
    else if (value === '--dimensions') out.requiredDimensions = (argv[++index] || '').split(',').filter(Boolean);
    else if (value === '--agents-available') out.agentsAvailable = (argv[++index] || '').split(',').map((item) => item.trim()).filter(Boolean);
    else if (value === '--write') out.write = true;
    else if (value === '--json') out.json = true;
    else throw new Error(`unknown argument: ${value}`);
  }
  return out;
}

function readJsonl(file) {
  if (!fs.existsSync(file)) throw new Error('chapter evidence map is missing');
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map(JSON.parse);
}

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(2);
}
