#!/usr/bin/env node
'use strict';

const path = require('path');
const { buildEvidenceMap, parseRange, writeEvidenceMap } = require('./lib/review-evidence');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--') && !arg.startsWith('-'));
const rangeIndex = args.indexOf('--range');
const rangeValue = rangeIndex >= 0 ? args[rangeIndex + 1] : '';
const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');

if (!projectRoot || !rangeValue) {
  fail('usage: review-evidence-map.js <book-project-dir> --range <start-end> [--write] [--json]');
}

try {
  const evidenceMap = buildEvidenceMap(path.resolve(projectRoot), parseRange(rangeValue), { scriptDir: __dirname });
  if (shouldWrite) writeEvidenceMap(path.resolve(projectRoot), evidenceMap);
  if (jsonOutput) process.stdout.write(`${JSON.stringify({
    status: evidenceMap.status,
    range: evidenceMap.range,
    summary: evidenceMap.summary,
    outputDir: shouldWrite ? 'evidence' : '',
  }, null, 2)}\n`);
  else console.log(`review evidence: ${evidenceMap.status} (${evidenceMap.summary.mappedChapters}/${evidenceMap.summary.requestedChapters} chapters)`);
  process.exit(evidenceMap.status.startsWith('blocked_') ? 2 : 0);
} catch (error) {
  fail(error.message);
}

function fail(message) {
  console.error(message);
  process.exit(2);
}
