#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const USAGE = `Usage:
  node review-state-ledger.js record --book-root <dir> --range <start-end> --report <path> [--scope-mode <mode>] [--gap <range>] [--dependency <path>] [--json]
  node review-state-ledger.js check --book-root <dir> [--write] [--json]

Maintain 追踪/review-state.json for range reviews:
  - records dependency_hashes for reports, hooks, timeline and explicit dependencies
  - marks reviews stale when dependency hashes change
  - suggests bounded recheck ranges without rerunning large chapter spans automatically`;

const args = parseArgs(process.argv.slice(2));
if (!args.command) die('missing command');
if (!args.bookRoot) die('--book-root is required');

const bookRoot = path.resolve(args.bookRoot);
const statePath = path.join(bookRoot, '追踪', 'review-state.json');

if (args.command === 'record') {
  recordReview();
} else if (args.command === 'check') {
  checkReviews();
} else {
  die(`unknown command: ${args.command}`);
}

function recordReview() {
  if (!args.range) die('--range is required for record');
  if (!args.report) die('--report is required for record');

  const state = readState();
  const dependencies = collectDependencies(args.report, args.dependencies);
  const dependencyHashes = hashDependencies(dependencies);
  const now = new Date().toISOString();
  const id = `review-${args.range}-${compactDate(now)}`;
  const gaps = args.gaps;

  const review = {
    id,
    range: args.range,
    report: normalizeRel(args.report),
    scope_mode: args.scopeMode || 'continuous',
    gaps,
    dependency_hashes: dependencyHashes,
    status: 'current',
    stale_reason: '',
    suggested_recheck_ranges: [],
    created_at: now,
    updated_at: now,
  };

  state.reviews = state.reviews.filter(existing => existing.id !== id);
  state.reviews.push(review);
  state.updated_at = now;
  writeState(state);
  output({ status: 'recorded', statePath, review });
}

function checkReviews() {
  const state = readState();
  const staleReviews = [];
  const now = new Date().toISOString();

  for (const review of state.reviews) {
    const changed = [];
    const hashes = review.dependency_hashes || {};
    for (const [rel, previous] of Object.entries(hashes)) {
      const current = hashFileIfExists(path.join(bookRoot, rel));
      if (current !== previous) changed.push(rel);
    }

    if (changed.length > 0) {
      review.status = 'stale';
      review.stale_reason = `dependency_hash_changed: ${changed.join(', ')}`;
      review.stale_dependencies = changed;
      review.suggested_recheck_ranges = unique([...(review.suggested_recheck_ranges || []), review.range, ...(review.gaps || [])]);
      review.updated_at = now;
      staleReviews.push(review);
    }
  }

  if (args.write) {
    state.updated_at = now;
    writeState(state);
  }

  output({ status: staleReviews.length ? 'stale_found' : 'current', statePath, staleReviews });
}

function collectDependencies(report, explicit) {
  const defaults = [
    report,
    '追踪/伏笔.md',
    '追踪/时间线.md',
    '追踪/角色状态.md',
    '追踪/人物状态.md',
    '追踪/主线承诺.md',
    '追踪/审查批次计划.md',
    '追踪/审查报告/批次交接摘要.md',
  ];
  return unique([...defaults, ...explicit].map(normalizeRel))
    .filter(rel => rel && fs.existsSync(path.join(bookRoot, rel)));
}

function hashDependencies(dependencies) {
  const out = {};
  for (const rel of dependencies) out[rel] = hashFileIfExists(path.join(bookRoot, rel));
  return out;
}

function hashFileIfExists(file) {
  if (!fs.existsSync(file)) return null;
  const stat = fs.statSync(file);
  if (!stat.isFile()) return null;
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function readState() {
  if (!fs.existsSync(statePath)) {
    return { version: 1, updated_at: new Date().toISOString(), reviews: [] };
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(statePath, 'utf8'));
    if (!Array.isArray(parsed.reviews)) parsed.reviews = [];
    if (!parsed.version) parsed.version = 1;
    return parsed;
  } catch (error) {
    throw new Error(`cannot parse ${statePath}: ${error.message}`);
  }
}

function writeState(state) {
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  fs.writeFileSync(statePath, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
}

function parseArgs(argv) {
  const parsed = {
    command: argv[0],
    bookRoot: '',
    range: '',
    report: '',
    scopeMode: '',
    gaps: [],
    dependencies: [],
    write: false,
    json: false,
  };

  for (let i = 1; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--book-root') parsed.bookRoot = argv[++i] || '';
    else if (arg === '--range') parsed.range = argv[++i] || '';
    else if (arg === '--report') parsed.report = argv[++i] || '';
    else if (arg === '--scope-mode') parsed.scopeMode = argv[++i] || '';
    else if (arg === '--gap') parsed.gaps.push(argv[++i] || '');
    else if (arg === '--dependency') parsed.dependencies.push(argv[++i] || '');
    else if (arg === '--write') parsed.write = true;
    else if (arg === '--json') parsed.json = true;
    else if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    } else {
      die(`unknown option: ${arg}`);
    }
  }
  parsed.gaps = parsed.gaps.filter(Boolean);
  parsed.dependencies = parsed.dependencies.filter(Boolean);
  return parsed;
}

function normalizeRel(input) {
  if (!input) return '';
  const absolute = path.isAbsolute(input) ? input : path.join(bookRoot, input);
  return path.relative(bookRoot, absolute).replace(/\\/g, '/');
}

function unique(items) {
  return [...new Set(items.filter(Boolean))];
}

function compactDate(iso) {
  return iso.replace(/[-:TZ.]/g, '').slice(0, 14);
}

function output(object) {
  if (args.json) process.stdout.write(`${JSON.stringify(object, null, 2)}\n`);
  else process.stdout.write(`${object.status}\n`);
}

function die(message) {
  console.error(message);
  console.error(USAGE);
  process.exit(2);
}
