#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const dir = process.argv[2];
if (!dir) fail('usage: scan-json-validate.js <scan-dir>');

const requiredFiles = [
  'scan-metadata.json',
  'ranking-items.jsonl',
  'trend-signals.json',
  'topic-candidates.json',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(path.join(dir, file))) fail(`missing ${file}`);
}

const metadata = readJSON('scan-metadata.json');
requiredString(metadata, 'schemaVersion');
requiredString(metadata, 'scanId');
requiredString(metadata, 'platform');
requiredString(metadata, 'platformName');
requiredString(metadata, 'board');
requiredString(metadata, 'contentLength');
if (!['long', 'short'].includes(metadata.contentLength)) fail('contentLength must be long or short');
if (!metadata.dataQuality || typeof metadata.dataQuality !== 'object') fail('dataQuality object required');
requiredString(metadata.dataQuality, 'status', 'dataQuality');
if (!['ok', 'sparse', 'partial', 'dirty', 'failed'].includes(metadata.dataQuality.status)) {
  fail('invalid dataQuality.status');
}
if (typeof metadata.dataQuality.validItems !== 'number') fail('dataQuality.validItems number required');
if (typeof metadata.dataQuality.rawItems !== 'number') fail('dataQuality.rawItems number required');
if (!Array.isArray(metadata.dataQuality.warnings)) fail('dataQuality.warnings array required');

const items = readJSONL('ranking-items.jsonl');
if (items.length === 0) fail('ranking-items.jsonl must contain at least one item');
for (const [index, item] of items.entries()) {
  const label = `ranking item ${index + 1}`;
  if (!Number.isInteger(item.rank) || item.rank <= 0) fail(`${label}: rank must be positive integer`);
  requiredString(item, 'title', label);
  requiredString(item, 'author', label);
  requiredString(item, 'url', label);
  if (item.metrics && typeof item.metrics !== 'object') fail(`${label}: metrics must be object`);
  if (item.signals && !Array.isArray(item.signals)) fail(`${label}: signals must be array`);
  if (item.dataQuality && !['ok', 'sparse', 'partial', 'dirty', 'failed'].includes(item.dataQuality)) {
    fail(`${label}: invalid dataQuality`);
  }
}

const trendSignals = readJSON('trend-signals.json');
if (trendSignals.scanId !== metadata.scanId) fail('trend-signals scanId does not match metadata');
if (!Array.isArray(trendSignals.signals)) fail('trend-signals.signals must be an array');
for (const signal of trendSignals.signals) {
  requiredString(signal, 'id', 'trend signal');
  requiredString(signal, 'kind', 'trend signal');
  requiredString(signal, 'label', 'trend signal');
  if (typeof signal.strength !== 'number' || signal.strength < 0 || signal.strength > 1) {
    fail(`trend signal ${signal.id}: strength must be 0..1`);
  }
  if (!Number.isInteger(signal.evidenceCount) || signal.evidenceCount < 0) {
    fail(`trend signal ${signal.id}: evidenceCount must be non-negative integer`);
  }
  if (!Array.isArray(signal.representativeTitles)) {
    fail(`trend signal ${signal.id}: representativeTitles must be array`);
  }
}

const topicCandidates = readJSON('topic-candidates.json');
if (topicCandidates.scanId !== metadata.scanId) fail('topic-candidates scanId does not match metadata');
if (!Array.isArray(topicCandidates.candidates)) fail('topic-candidates.candidates must be an array');
for (const candidate of topicCandidates.candidates) {
  requiredString(candidate, 'id', 'topic candidate');
  requiredString(candidate, 'title', 'topic candidate');
  requiredString(candidate, 'whyNow', 'topic candidate');
  requiredString(candidate, 'starterHook', 'topic candidate');
  if (!Array.isArray(candidate.platformFit)) fail(`topic candidate ${candidate.id}: platformFit must be array`);
  if (!['low', 'medium', 'high'].includes(candidate.difficulty)) {
    fail(`topic candidate ${candidate.id}: difficulty must be low, medium, or high`);
  }
  if (!Array.isArray(candidate.risks)) fail(`topic candidate ${candidate.id}: risks must be array`);
  requiredString(candidate, 'nextValidation', 'topic candidate');
}

console.log(`scan schema OK: ${metadata.scanId} (${items.length} items)`);

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
  } catch (error) {
    fail(`invalid ${file}: ${error.message}`);
  }
}

function readJSONL(file) {
  return fs.readFileSync(path.join(dir, file), 'utf8')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        fail(`invalid ${file}:${index + 1}: ${error.message}`);
      }
    });
}

function requiredString(object, key, context = 'object') {
  if (!object || typeof object[key] !== 'string' || object[key].trim() === '') {
    fail(`${context}: ${key} string required`);
  }
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
