#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const projectDir = process.argv[2];
if (!projectDir) fail('usage: story-schema-validate.js <book-project-dir>');

const schemaDir = path.join(projectDir, '追踪', 'schema');
for (const file of ['story-state.json', 'chapters.jsonl', 'promises.jsonl', 'health.json']) {
  if (!fs.existsSync(path.join(schemaDir, file))) fail(`missing 追踪/schema/${file}`);
}

const state = readJSON(path.join(schemaDir, 'story-state.json'));
requiredString(state, 'schemaVersion', 'story-state');
requiredString(state, 'bookTitle', 'story-state');
requiredString(state, 'mode', 'story-state');
if (state.mode !== 'longform') fail('story-state.mode must be longform');
if (!Number.isInteger(state.currentChapter) || state.currentChapter < 0) {
  fail('story-state.currentChapter must be non-negative integer');
}
requiredString(state, 'status', 'story-state');
requiredString(state, 'updatedAt', 'story-state');

const chapters = readJSONL(path.join(schemaDir, 'chapters.jsonl'));
if (chapters.length === 0) fail('chapters.jsonl must contain at least one chapter');
for (const chapter of chapters) {
  requiredString(chapter, 'chapterId', 'chapter');
  if (!Number.isInteger(chapter.chapterNo) || chapter.chapterNo <= 0) {
    fail(`${chapter.chapterId}: chapterNo must be positive integer`);
  }
  requiredString(chapter, 'title', 'chapter');
  if (chapter.volume !== undefined) {
    requiredString(chapter, 'volume', chapter.chapterId);
  }
  if (chapter.volumeChapterNo !== undefined && (!Number.isInteger(chapter.volumeChapterNo) || chapter.volumeChapterNo <= 0)) {
    fail(`${chapter.chapterId}: volumeChapterNo must be positive integer`);
  }
  if (chapter.globalDraftOrder !== undefined && (!Number.isInteger(chapter.globalDraftOrder) || chapter.globalDraftOrder <= 0)) {
    fail(`${chapter.chapterId}: globalDraftOrder must be positive integer`);
  }
  if (chapter.assetId !== undefined && typeof chapter.assetId !== 'string') {
    fail(`${chapter.chapterId}: assetId must be string`);
  }
  requiredString(chapter, 'auditStatus', chapter.chapterId);
}

const promises = readJSONL(path.join(schemaDir, 'promises.jsonl'));
for (const promise of promises) {
  requiredString(promise, 'id', 'promise');
  requiredString(promise, 'type', 'promise');
  requiredString(promise, 'status', 'promise');
  if (!['open', 'warming', 'paid_off', 'deferred', 'dropped', 'conflict'].includes(promise.status)) {
    fail(`${promise.id}: invalid promise status`);
  }
}

const plotUnitsFile = path.join(schemaDir, 'plot-units.jsonl');
if (fs.existsSync(plotUnitsFile)) {
  const plotUnits = readJSONL(plotUnitsFile);
  const ids = new Set();
  for (const unit of plotUnits) {
    requiredString(unit, 'id', 'plot unit');
    if (!/^PU-[^\s/]+$/.test(unit.id)) fail(`${unit.id}: invalid plot unit id`);
    if (ids.has(unit.id)) fail(`${unit.id}: duplicate plot unit id`);
    ids.add(unit.id);
    requiredString(unit, 'volume', unit.id);
    if (!['hard', 'soft'].includes(unit.planningMode)) fail(`${unit.id}: planningMode must be hard or soft`);
    if (!['pending', 'stale', 'active_locked_prefix', 'locked', 'locked_with_pending_gap'].includes(unit.planningState)) {
      fail(`${unit.id}: invalid planningState`);
    }
    if (!Array.isArray(unit.chapters) || !unit.chapters.length) fail(`${unit.id}: chapters must be non-empty`);
  }
}

const health = readJSON(path.join(schemaDir, 'health.json'));
requiredString(health, 'schemaVersion', 'health');
requiredString(health, 'status', 'health');
if (!['pass', 'warn', 'fail'].includes(health.status)) fail('health.status must be pass, warn, or fail');
if (!health.summary || typeof health.summary !== 'object') fail('health.summary required');
for (const field of ['chapters', 'openPromises', 'overduePromises', 'failedAudits', 'missingBeatSheets']) {
  if (!Number.isInteger(health.summary[field]) || health.summary[field] < 0) {
    fail(`health.summary.${field} must be non-negative integer`);
  }
}
if (!Array.isArray(health.issues)) fail('health.issues must be array');
for (const issue of health.issues) {
  requiredString(issue, 'code', 'health issue');
  requiredString(issue, 'severity', 'health issue');
  if (!['P0', 'P1', 'P2', 'P3'].includes(issue.severity)) fail(`${issue.code}: invalid severity`);
  requiredString(issue, 'target', 'health issue');
  requiredString(issue, 'message', 'health issue');
  requiredString(issue, 'suggestedAction', 'health issue');
}

const beatDir = path.join(schemaDir, 'beat-sheets');
if (fs.existsSync(beatDir)) {
  for (const file of fs.readdirSync(beatDir).filter(name => name.endsWith('.json'))) {
    const beatSheet = readJSON(path.join(beatDir, file));
    requiredString(beatSheet, 'schemaVersion', file);
    requiredString(beatSheet, 'chapterId', file);
    if (!Array.isArray(beatSheet.beats) || beatSheet.beats.length < 1) {
      fail(`${file}: beats must be non-empty`);
    }
    for (const beat of beatSheet.beats) {
      requiredString(beat, 'id', `${file} beat`);
      requiredString(beat, 'type', `${file} beat`);
      requiredString(beat, 'summary', `${file} beat`);
    }
    if (beatSheet.qualityGate !== undefined) validateQualityGate(beatSheet.qualityGate, file);
  }
}

console.log(`story schema OK: ${state.bookTitle} (${chapters.length} chapters, ${promises.length} promises)`);

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    fail(`invalid ${file}: ${error.message}`);
  }
}

function readJSONL(file) {
  return fs.readFileSync(file, 'utf8')
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

function requiredString(obj, field, label) {
  if (!obj || typeof obj[field] !== 'string' || obj[field].trim() === '') {
    fail(`${label}: ${field} must be a non-empty string`);
  }
}

function validateQualityGate(gate, file) {
  if (!gate || typeof gate !== 'object' || Array.isArray(gate)) fail(`${file}: qualityGate must be an object`);
  requiredString(gate, 'version', `${file}: qualityGate`);
  if (gate.version !== 'detail_outline_quality_v1') {
    fail(`${file}: qualityGate.version must be detail_outline_quality_v1`);
  }
  requiredString(gate, 'status', `${file}: qualityGate`);
  if (!['pass', 'pass_with_advisory'].includes(gate.status)) {
    fail(`${file}: qualityGate.status must be pass or pass_with_advisory`);
  }
  requiredString(gate, 'outlinePath', `${file}: qualityGate`);
  requiredString(gate, 'outlineSha256', `${file}: qualityGate`);
  if (!/^[a-f0-9]{64}$/.test(gate.outlineSha256)) {
    fail(`${file}: qualityGate.outlineSha256 must be 64 lowercase hexadecimal characters`);
  }
  if (!Array.isArray(gate.activatedDimensions) || gate.activatedDimensions.some(value => typeof value !== 'string' || !value)) {
    fail(`${file}: qualityGate.activatedDimensions must be an array of non-empty strings`);
  }
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
