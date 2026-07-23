#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { acquireBookWriteLease, atomicWriteJson, atomicWriteText } = require('./lib/workflow-state-store');

const SCHEMA_FILE = '追踪/schema/chapters.jsonl';
const ASSET_FILE = '追踪/章节资产.jsonl';
const SNAPSHOT_DIR = '追踪/workflow/metadata-snapshots';

try {
  const args = parseArgs(process.argv.slice(2));
  const root = path.resolve(args.projectRoot);
  const plan = buildPlan(root);
  if (plan.conflicts.length) finish({
    status: 'blocked_ambiguous_live_paths', changed: false,
    repairableCount: plan.repairs.length, conflictCount: plan.conflicts.length,
    conflicts: plan.conflicts.slice(0, 20),
  }, 2);
  if (!plan.repairs.length) finish({ status: 'current', changed: false, repairableCount: 0, conflictCount: 0 }, 0);
  if (!args.write) finish({
    status: 'repairable', changed: false, repairableCount: plan.repairs.length,
    conflictCount: 0, repairs: plan.repairs.slice(0, 20),
  }, 0);

  const release = acquireBookWriteLease(root, 'chapter-metadata-reconcile');
  try {
    const currentPlan = buildPlan(root);
    if (currentPlan.conflicts.length) finish({
      status: 'blocked_ambiguous_live_paths', changed: false,
      repairableCount: currentPlan.repairs.length, conflictCount: currentPlan.conflicts.length,
      conflicts: currentPlan.conflicts.slice(0, 20),
    }, 2);
    if (!currentPlan.repairs.length) finish({ status: 'current', changed: false, repairableCount: 0, conflictCount: 0 }, 0);
    const snapshot = writeSnapshot(root, currentPlan);
    const replacementByIndex = new Map(currentPlan.repairs.map(item => [item.assetIndex, item.to]));
    const nextAssets = currentPlan.assets.map((asset, index) => replacementByIndex.has(index)
      ? { ...asset, draftPath: replacementByIndex.get(index) }
      : asset);
    atomicWriteText(path.join(root, ASSET_FILE), renderJsonl(nextAssets));
    finish({
      status: 'reconciled', changed: true, repairableCount: currentPlan.repairs.length,
      conflictCount: 0, snapshot: relative(root, snapshot), repairs: currentPlan.repairs.slice(0, 20),
    }, 0);
  } finally {
    release();
  }
} catch (error) {
  finish({ status: error.status || 'error', changed: false, message: String(error.message || error) }, 2);
}

function parseArgs(argv) {
  const args = { projectRoot: '', write: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') args.projectRoot = argv[++index] || '';
    else if (arg === '--write') args.write = true;
    else if (arg === '--json') continue;
    else if (arg === '--help' || arg === '-h') {
      process.stdout.write('Usage: chapter-metadata-reconcile.js --project-root <book> [--write] [--json]\n');
      process.exit(0);
    } else throw failure('blocked_invalid_argument', `unknown argument: ${arg}`);
  }
  if (!args.projectRoot) throw failure('blocked_invalid_argument', 'missing --project-root');
  return args;
}

function buildPlan(root) {
  const schema = readJsonl(path.join(root, SCHEMA_FILE));
  const assets = readJsonl(path.join(root, ASSET_FILE));
  const schemaByIdentity = new Map(schema.map(item => [identity(item), item]).filter(([key]) => key));
  const repairs = [];
  const conflicts = [];
  assets.forEach((asset, assetIndex) => {
    const current = schemaByIdentity.get(identity(asset));
    if (!current || !current.draftPath || !asset.draftPath || slash(current.draftPath) === slash(asset.draftPath)) return;
    const schemaPath = slash(current.draftPath);
    const assetPath = slash(asset.draftPath);
    const schemaExists = fileExists(root, schemaPath);
    const assetExists = fileExists(root, assetPath);
    if (schemaExists && (isBackupPath(assetPath) || !assetExists)) {
      repairs.push({
        identity: identity(asset), assetIndex, from: assetPath, to: schemaPath,
        reason: isBackupPath(assetPath) ? 'asset_points_to_backup' : 'asset_target_missing',
      });
      return;
    }
    conflicts.push({
      identity: identity(asset), schemaPath, assetPath, schemaExists, assetExists,
      reason: 'ambiguous_live_paths',
    });
  });
  return { schema, assets, repairs, conflicts };
}

function writeSnapshot(root, plan) {
  const before = fs.readFileSync(path.join(root, ASSET_FILE));
  const digest = crypto.createHash('sha256').update(before).digest('hex').slice(0, 16);
  const stamp = new Date().toISOString().replace(/[:.]/g, '').replace('T', '_').replace('Z', '');
  const target = path.join(root, SNAPSHOT_DIR, `${stamp}_${digest}.json`);
  atomicWriteJson(target, {
    schemaVersion: '1.0.0',
    createdAt: new Date().toISOString(),
    source: ASSET_FILE,
    sourceSha256: crypto.createHash('sha256').update(before).digest('hex'),
    sourceContentBase64: before.toString('base64'),
    repairs: plan.repairs,
  });
  return target;
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map((line, index) => {
    try { return JSON.parse(line); } catch (_) { throw failure('blocked_invalid_metadata', `${relative(path.dirname(path.dirname(file)), file)}:${index + 1} is invalid JSON`); }
  });
}

function renderJsonl(rows) {
  return `${rows.map(row => JSON.stringify(row)).join('\n')}\n`;
}

function identity(item) {
  const volume = String(item.volume || '').trim();
  const local = Number(item.volumeChapterNo || 0);
  if (volume && Number.isInteger(local) && local > 0) return `${volume}|${local}`;
  const global = Number(item.globalDraftOrder || item.chapterNo || 0);
  return Number.isInteger(global) && global > 0 ? `global|${global}` : '';
}

function isBackupPath(value) {
  return /(?:_原稿_|_旧稿_|_备份_|\/备份\/|\/版本\/|\.bak(?:\.|$)|~$)/i.test(String(value || ''));
}

function fileExists(root, relativePath) {
  const target = path.resolve(root, ...String(relativePath).split('/'));
  return target.startsWith(`${root}${path.sep}`) && fs.existsSync(target) && fs.statSync(target).isFile();
}

function slash(value) { return String(value || '').replace(/\\/g, '/'); }
function relative(root, target) { return slash(path.relative(root, target)); }
function failure(status, message) { const error = new Error(message); error.status = status; return error; }
function finish(value, code) { process.stdout.write(`${JSON.stringify(value, null, 2)}\n`); process.exit(code); }
