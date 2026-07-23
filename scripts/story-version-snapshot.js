#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const {
  ensureDir,
  readText,
  nowIso,
  writeJson,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--'));
if (!projectRoot) fail('usage: story-version-snapshot.js <project-root> --reason <reason> --files <rel1,rel2> [--write] [--json]');

const root = path.resolve(projectRoot);
const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');
const reason = valueAfter('--reason') || 'manual-snapshot';
const fileList = (valueAfter('--files') || '')
  .split(',')
  .map(item => slash(item.trim()))
  .filter(Boolean);

if (fileList.length === 0) fail('--files must include at least one project-relative path');

const snapshot = createSnapshot(root, reason, fileList, shouldWrite);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(snapshot, null, 2)}\n`);
} else {
  console.log(`version snapshot prepared: ${snapshot.snapshotPath} (${snapshot.files.length} files)`);
  if (shouldWrite) console.log('wrote snapshot manifest and files');
}

function createSnapshot(projectDir, snapshotReason, relFiles, write) {
  const createdAt = nowIso();
  const id = `${createdAt.replace(/[:.]/g, '').replace('T', '_').replace('Z', '')}_${slug(snapshotReason)}`;
  const snapshotPath = slash(path.join('追踪', '版本', id));
  const files = [];

  for (const relPath of relFiles) {
    const absPath = safeProjectPath(projectDir, relPath);
    const exists = fs.existsSync(absPath) && fs.statSync(absPath).isFile();
    files.push({
      path: relPath,
      exists,
      bytes: exists ? Buffer.byteLength(readText(absPath), 'utf8') : 0,
    });
    if (write && exists) {
      const target = path.join(projectDir, snapshotPath, relPath);
      ensureDir(path.dirname(target));
      fs.copyFileSync(absPath, target);
    }
  }

  const manifest = {
    schemaVersion: '1.0.0',
    id,
    reason: snapshotReason,
    createdAt,
    projectRoot: projectDir,
    snapshotPath,
    files,
  };

  if (write) {
    writeJson(path.join(projectDir, snapshotPath, 'manifest.json'), manifest);
  }
  return manifest;
}

function valueAfter(flag) {
  const index = args.indexOf(flag);
  if (index < 0) return '';
  return args[index + 1] || '';
}

function safeProjectPath(projectDir, relPath) {
  const resolved = path.resolve(projectDir, relPath);
  if (resolved !== projectDir && !resolved.startsWith(`${projectDir}${path.sep}`)) {
    fail(`path escapes project root: ${relPath}`);
  }
  return resolved;
}

function slug(value) {
  const text = String(value || '')
    .trim()
    .replace(/[^\w\u4e00-\u9fff]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48);
  return text || 'snapshot';
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
