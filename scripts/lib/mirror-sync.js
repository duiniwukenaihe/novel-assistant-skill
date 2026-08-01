'use strict';

// scripts/lib/mirror-sync.js
//
// Manifest-driven mirror synchronizer + audit.
//
// 把 sourceDir 中 manifest 声明的脚本镜像到 mirrorDir：
//   - manifest.scriptFiles  : 根目录文件名（同步后强制加可执行位 `mode | 0o111`）
//   - manifest.scriptDirectories : 子目录名（递归同步，保持源权限不变）
// 未列入 manifest 的文件不会被同步（由 manifest 显式驱动，不再用 SOURCE_ONLY 黑名单）。
//
// auditMirror 用 sha256 内容哈希比对，返回：
//   { status: 'current' | 'drift', missing: [...], changed: [...], unexpected: [...] }
//   - missing   : manifest 期望存在、mirror 中缺失
//   - changed   : mirror 中存在但内容与 source 不一致
//   - unexpected: mirror 中存在、但不在 manifest 期望集合内
// 路径一律相对 POSIX（如 "lib/helper.js"）。
//
// CLI: node mirror-sync.js <sync|audit> <source> <mirror> <manifest.json>
//      audit 模式发现 drift 时 exit 1。

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// 构建以 manifest 为权威；该集合仅供无 manifest 的调用方判断明显的源仓库工具。
const SOURCE_ONLY = new Set([
  'build-github-release-artifact.sh',
  'build-oh-story-bundle.sh',
  'check-hook-locale-safety.sh',
  'check-python-invocation.sh',
  'maintainability-audit.js',
  'na-dev.js',
  'panlong-benchmark-compare.js',
  'plan-evidence-check.js',
  'prepare-github-public-release.sh',
  'public-release-audit.js',
]);

function shouldMirror(relativePath) {
  return !SOURCE_ONLY.has(path.basename(relativePath));
}

function hashBuffer(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function readManifest(manifest) {
  if (!manifest || typeof manifest !== 'object') {
    throw new Error('manifest must be an object');
  }
  const scriptFiles = Array.isArray(manifest.scriptFiles) ? manifest.scriptFiles : [];
  const scriptDirectories = Array.isArray(manifest.scriptDirectories) ? manifest.scriptDirectories : [];
  for (const name of scriptFiles) {
    if (typeof name !== 'string' || name === '' || name.includes('/') || name.includes('\\')) {
      throw new Error(`unsafe scriptFiles entry: ${name}`);
    }
  }
  for (const name of scriptDirectories) {
    if (typeof name !== 'string' || name === '' || name.includes('/') || name.includes('\\')) {
      throw new Error(`unsafe scriptDirectories entry: ${name}`);
    }
  }
  return { scriptFiles, scriptDirectories };
}

// 递归收集 dir 下所有文件的相对 POSIX 路径（相对 to dir）。
function walkFiles(dir) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      for (const sub of walkFiles(full)) {
        out.push(`${entry.name}/${sub}`);
      }
    } else if (entry.isFile()) {
      out.push(entry.name);
    }
  }
  return out;
}

// 计算 manifest 期望出现在 mirror 中的全部相对 POSIX 路径集合。
function expectedMirrorPaths(sourceDir, manifest) {
  const { scriptFiles, scriptDirectories } = readManifest(manifest);
  const paths = [];
  for (const name of scriptFiles) {
    const src = path.join(sourceDir, name);
    if (!fs.existsSync(src) || !fs.statSync(src).isFile()) {
      throw new Error(`missing mirror source: ${src}`);
    }
    paths.push(name);
  }
  for (const dir of scriptDirectories) {
    const srcDir = path.join(sourceDir, dir);
    if (!fs.existsSync(srcDir) || !fs.statSync(srcDir).isDirectory()) {
      throw new Error(`missing mirror source: ${srcDir}`);
    }
    for (const rel of walkFiles(srcDir)) paths.push(`${dir}/${rel}`);
  }
  return paths.sort();
}

// audit: 比对 source 与 mirror，不修改任何文件。
function auditMirror({ sourceDir, mirrorDir, manifest }) {
  if (!sourceDir || !mirrorDir) throw new Error('sourceDir and mirrorDir are required');
  const expected = expectedMirrorPaths(sourceDir, manifest);
  const missing = [];
  const changed = [];
  for (const rel of expected) {
    const mirrorPath = path.join(mirrorDir, rel);
    if (!fs.existsSync(mirrorPath)) {
      missing.push(rel);
      continue;
    }
    const srcBuf = fs.readFileSync(path.join(sourceDir, rel));
    const mirrorBuf = fs.readFileSync(mirrorPath);
    if (!srcBuf.equals(mirrorBuf) || hashBuffer(srcBuf) !== hashBuffer(mirrorBuf)) {
      changed.push(rel);
    }
  }
  const expectedSet = new Set(expected);
  const unexpected = walkFiles(mirrorDir).filter((rel) => !expectedSet.has(rel)).sort();
  const drift = missing.length > 0 || changed.length > 0 || unexpected.length > 0;
  return { status: drift ? 'drift' : 'current', missing, changed, unexpected };
}

function copyWithMode(src, dest, mode) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(src, dest);
  fs.chmodSync(dest, mode);
}

// sync: 按 manifest 把 source 文件复制到 mirror，返回 audit 结果。
function syncMirror({ sourceDir, mirrorDir, manifest }) {
  if (!sourceDir || !mirrorDir) throw new Error('sourceDir and mirrorDir are required');
  const { scriptFiles, scriptDirectories } = readManifest(manifest);
  const expected = new Set(expectedMirrorPaths(sourceDir, manifest));
  fs.mkdirSync(mirrorDir, { recursive: true });
  for (const rel of walkFiles(mirrorDir)) {
    if (!expected.has(rel)) fs.rmSync(path.join(mirrorDir, rel));
  }
  // 1) 根脚本：复制后强制加可执行位（`mode | 0o111`）。
  for (const name of scriptFiles) {
    const src = path.join(sourceDir, name);
    if (!fs.existsSync(src)) continue;
    const dest = path.join(mirrorDir, name);
    const srcMode = fs.statSync(src).mode & 0o777;
    copyWithMode(src, dest, srcMode | 0o111);
  }
  // 2) 子目录：递归复制，保持源权限不变。
  for (const dir of scriptDirectories) {
    const srcDir = path.join(sourceDir, dir);
    for (const rel of walkFiles(srcDir)) {
      const src = path.join(srcDir, rel);
      const dest = path.join(mirrorDir, dir, rel);
      const srcMode = fs.statSync(src).mode & 0o777;
      copyWithMode(src, dest, srcMode);
    }
  }
  return auditMirror({ sourceDir, mirrorDir, manifest });
}

function parseCli(argv) {
  if (argv.length < 4) {
    throw new Error('usage: mirror-sync.js <sync|audit> <source> <mirror> <manifest.json>');
  }
  const [command, sourceDir, mirrorDir, manifestPath] = argv;
  if (command !== 'sync' && command !== 'audit') {
    throw new Error(`unknown command: ${command} (expected sync|audit)`);
  }
  return { command, sourceDir, mirrorDir, manifest: JSON.parse(fs.readFileSync(manifestPath, 'utf8')) };
}

function main() {
  const args = parseCli(process.argv.slice(2));
  const fn = args.command === 'sync' ? syncMirror : auditMirror;
  const result = fn({ sourceDir: args.sourceDir, mirrorDir: args.mirrorDir, manifest: args.manifest });
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (args.command === 'audit' && result.status === 'drift') process.exit(1);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}

module.exports = {
  SOURCE_ONLY,
  auditMirror,
  shouldMirror,
  syncMirror,
};
