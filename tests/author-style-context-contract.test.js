#!/usr/bin/env node

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..');
const skillRoot = path.join(repoRoot, 'skills', 'novel-assistant');
const manifest = JSON.parse(fs.readFileSync(path.join(skillRoot, 'novel-assistant-manifest.json'), 'utf8'));
const contractPath = path.join(skillRoot, 'references', 'author-style-context-contract.md');
const indexPath = path.join(skillRoot, 'references', 'runtime-contract-index.md');

assert.ok(Array.isArray(manifest.platformContracts), 'manifest.platformContracts must be an array');
assert.ok(manifest.platformContracts.includes('author_style_context_v1'), 'manifest must declare author_style_context_v1');
assert.ok(manifest.platformContracts.includes('personal_calibration_v1'), 'manifest must declare personal_calibration_v1');

assert.ok(fs.existsSync(contractPath), 'author style context contract must exist');
const contract = fs.readFileSync(contractPath, 'utf8');
const runtimeIndex = fs.readFileSync(indexPath, 'utf8');

for (const requiredText of [
  'author_style_context_v1',
  'personal_calibration_v1',
  'storageOwner: novel-project-postgresql',
  '不得写入个人正文摘录、偏好、画像或校准结果',
  '独立 CLI',
  '无 envelope',
  'structured calibration result',
]) {
  assert.ok(contract.includes(requiredText), `contract missing: ${requiredText}`);
}

assert.ok(runtimeIndex.includes('author-style-context-contract.md'), 'runtime index must link the contract');

console.log('author style context contract: ok');
