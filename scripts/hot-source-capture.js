#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { resolvePrivateModule } = require('./lib/private-runtime-resolver');
const { buildHotSourceSelection } = require('./lib/hot-source-registry');

function main() {
  const privateRoot = resolvePrivateModule('private-short-extension', [
    path.join('scripts', 'hot_source_capture.js'),
    path.join('references', 'hot-source-profiles.json'),
    path.join('references', 'hot-source-providers.json'),
  ]);
  if (!privateRoot) {
    process.stdout.write(`${JSON.stringify({ status: 'private_hot_source_runtime_missing' })}\n`);
    return 1;
  }
  const argv = process.argv.slice(2);
  if (!argv.includes('--profiles')) argv.push('--profiles', path.join(privateRoot, 'references', 'hot-source-profiles.json'));
  if (!argv.includes('--providers')) argv.push('--providers', path.join(privateRoot, 'references', 'hot-source-providers.json'));
  if (!argv.includes('--source-ids')) {
    const profiles = readJson(path.join(privateRoot, 'references', 'hot-source-profiles.json'));
    const providers = readJson(path.join(privateRoot, 'references', 'hot-source-providers.json'));
    const selection = buildHotSourceSelection(profiles, {
      availableIds: Object.keys((providers || {}).source_routes || {}),
    });
    if (selection.selectedIds.length) argv.push('--source-ids', selection.selectedIds.join(','));
  }
  const child = spawnSync(process.execPath, [path.join(privateRoot, 'scripts', 'hot_source_capture.js'), ...argv], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (child.stdout) process.stdout.write(child.stdout);
  if (child.stderr) process.stderr.write(child.stderr);
  return Number.isInteger(child.status) ? child.status : 1;
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return {}; }
}

process.exitCode = main();
