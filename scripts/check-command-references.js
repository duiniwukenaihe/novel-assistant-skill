#!/usr/bin/env node
'use strict';

// check-command-references.js — 校验运行时 execution_command 引用的脚本存在。
//
// 状态机、顶层脚本与 SKILL.md 里硬编码了 `node scripts/xxx.js` 命令字符串
//（execution_command、context_read_command、skill 内部示例等）。脚本重命名或删除时，
// 这些引用不会在构建期被发现，只能等宿主运行时失败。本工具扫描全仓库 .js/.sh/.md
// 文件，找出所有 `node scripts/xxx.js` 引用并确认目标脚本存在，防止静默漂移。
//
// 对于 skill 内部的 .md 文件（src/internal-skills/<skill>/ 或 bundle 对应路径），
// `node scripts/xxx.js` 是从 skill 运行时 cwd（skill 目录）看的，校验基准是该
// skill 目录下的 scripts/，而非仓库根 scripts/。
//
// 用法：node scripts/check-command-references.js [--repo-root <dir>] [--json]
// 退出码：0 = 全部存在；1 = 存在缺失引用。

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const repoRoot = path.resolve(extractFlag('--repo-root') || process.cwd());
const wantJson = args.includes('--json');

function extractFlag(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : '';
}

const SCAN_DIRS = ['scripts', 'src/internal-skills', 'skills/novel-assistant/references/internal-skills'];
const EXCLUDE_DIRS = ['node_modules', '.git', 'worktrees', '.worktrees', '.claude/worktrees'];
const FILE_RE = /\.(js|sh|md)$/;
const SKILL_DIR_RE = /[\\/]internal-skills[\\/][^\\/]+[\\/]/;

function walk(dir, out) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (EXCLUDE_DIRS.includes(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.isFile() && FILE_RE.test(entry.name) && entry.name !== 'check-command-references.js') out.push(full);
  }
}

// Scan for `node scripts/<name>.js` occurrences. Matches both template-literal
// and string-concatenated forms.
const CMD_RE = /node\s+scripts\/([A-Za-z0-9._-]+)\.js/g;

const findings = [];
const files = [];
for (const dir of SCAN_DIRS) walk(path.join(repoRoot, dir), files);

for (const file of files) {
  const content = fs.readFileSync(file, 'utf8');
  const relFile = path.relative(repoRoot, file);
  // For .md files inside a skill directory (src/internal-skills/<skill>/ or
  // bundle path), `node scripts/xxx.js` could be relative to either the
  // skill's own directory (if it has a scripts/ subdir) or the repo root.
  // Try the skill dir first, then fall back to repo root.
  const skillMatch = SKILL_DIR_RE.exec(relFile);
  const skillBase = skillMatch
    ? path.join(repoRoot, relFile.slice(0, skillMatch.index + skillMatch[0].length))
    : null;
  CMD_RE.lastIndex = 0;
  let match;
  while ((match = CMD_RE.exec(content)) !== null) {
    const scriptName = match[1];
    const rootPath = path.join(repoRoot, 'scripts', `${scriptName}.js`);
    const skillPath = skillBase ? path.join(skillBase, 'scripts', `${scriptName}.js`) : '';
    if (!fs.existsSync(rootPath) && !(skillPath && fs.existsSync(skillPath))) {
      findings.push({ file: relFile, script: `${scriptName}.js` });
    }
  }
}

if (wantJson) {
  console.log(JSON.stringify({ status: findings.length ? 'fail' : 'pass', findings }, null, 2));
} else {
  if (findings.length) {
    console.log('Missing command references:');
    for (const f of findings) console.log(`  ${f.file}: node scripts/${f.script}`);
    process.exit(1);
  }
  console.log('All node scripts/ command references resolve.');
}
