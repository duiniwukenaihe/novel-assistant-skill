#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const PUBLIC_REPO_URL = 'https://github.com/duiniwukenaihe/novel-assistant-skill.git';
const UPSTREAM_REPO_URL = 'https://github.com/worldwonderer/oh-story-claudecode.git';

const DEFAULT_REMOVE_PATHS = [
  'src/private-internal-skills',
  'skills/novel-assistant/references/private-internal-skills',
  '.superpowers',
  'docs/superpowers',
  'reports/upstream',
  'benchmarks',
  'demo',
  'scripts/sync-private-short-write-absorption.js',
  'tests/test-github-release-tooling.bats',
  'tests/test-private-short-workflow-coverage.bats'
];

const FILE_REMOVE_PATTERNS = [
  /^demo\/.*\.txt$/i,
  /^demo\/.*\/正文\//,
  /^demo\/.*\/原文\/原文\.txt$/,
  /^benchmarks\/.*\/原文\/原文\.txt$/,
  /^benchmarks\/.*\/input\/原文\.txt$/,
  /^benchmarks\/.*\/claude-run\.jsonl$/,
  /^benchmarks\/.*\/prompt\.txt$/,
  /^demo\/.*\.(png|jpe?g|webp)$/i
];

function parseArgs(argv) {
  const args = { repoRoot: process.cwd(), write: false, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--repo-root') {
      args.repoRoot = path.resolve(argv[++i] || '');
    } else if (arg === '--write') {
      args.write = true;
    } else if (arg === '--json') {
      args.json = true;
    } else if (arg === '--help' || arg === '-h') {
      process.stdout.write(`Usage: node scripts/sanitize-github-public-tree.js [--repo-root <dir>] [--write] [--json]

Remove files that must never be published to the public GitHub branch:
private internal skills, private workflow overlays, superpowers planning docs,
temporary upstream reports, raw source texts, personal demo chapters, and
benchmark runtime logs/prompts. Public story-workflow orchestration is kept.
`);
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function exists(target) {
  return fs.existsSync(target);
}

function removePath(target, write) {
  if (!exists(target)) return false;
  if (write) fs.rmSync(target, { recursive: true, force: true });
  return true;
}

function walkFiles(root, base = '') {
  const dir = path.join(root, base);
  if (!exists(dir)) return [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (entry.name === '.git') continue;
    const rel = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      files.push(...walkFiles(root, rel));
    } else if (entry.isFile()) {
      files.push(rel);
    }
  }
  return files;
}

function shouldRemoveFile(rel) {
  const normalized = rel.replace(/\\/g, '/');
  return FILE_REMOVE_PATTERNS.some((pattern) => pattern.test(normalized));
}

function isTextLike(rel) {
  return /\.(md|txt|json|jsonl|js|mjs|cjs|ts|tsx|jsx|sh|bats|yml|yaml|toml|lock|html|css)$/i.test(rel)
    || rel === 'README.md'
    || rel === 'README_EN.md'
    || rel === '.gitignore';
}

function sanitizeText(text) {
  return text
    .replace(/git@192\.168\.\d+\.\d+:skill\/novel-assistant-skill\.git/g, PUBLIC_REPO_URL)
    .replace(/git@192\.168\.\d+\.\d+:skill\/oh-story-claudecode\.git/g, UPSTREAM_REPO_URL)
    .replace(/192\.168\.\d+\.\d+/g, 'github.com')
    .replace(/\/Users\/zhangpeng/g, '<local-user-path>')
    .replace(/\/data\/workspace/g, '<server-workspace-path>')
    .replace(/private-short-extension/g, 'private-short-extension')
    .replace(/private-download-extension/g, 'private-download-extension')
    .replace(/private short-form extension/g, 'private short-form extension')
    .replace(/private-short-extension/g, 'private-short-extension');
}

function sanitizeTextFile(repoRoot, rel, write) {
  if (!isTextLike(rel)) return false;
  const file = path.join(repoRoot, rel);
  if (!exists(file)) return false;
  let before = '';
  try {
    before = fs.readFileSync(file, 'utf8');
  } catch {
    return false;
  }
  const after = sanitizeText(before);
  if (after === before) return false;
  if (write) fs.writeFileSync(file, after);
  return true;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const repoRoot = args.repoRoot;
  const removed = [];
  const rewritten = [];
  const kept = [];

  for (const rel of DEFAULT_REMOVE_PATHS) {
    if (removePath(path.join(repoRoot, rel), args.write)) {
      removed.push({ type: 'path', path: rel });
    }
  }

  for (const rel of walkFiles(repoRoot)) {
    if (!shouldRemoveFile(rel)) continue;
    if (removePath(path.join(repoRoot, rel), args.write)) {
      removed.push({ type: 'file', path: rel });
    }
  }

  for (const rel of walkFiles(repoRoot)) {
    if (sanitizeTextFile(repoRoot, rel, args.write)) rewritten.push(rel);
  }

  for (const rel of [
    'src/internal-skills/story-workflow/SKILL.md',
    'skills/novel-assistant/references/internal-skills/story-workflow/SKILL.md',
    'scripts/workflow-state-machine.js'
  ]) {
    if (exists(path.join(repoRoot, rel))) kept.push(rel);
  }

  const result = {
    schemaVersion: '1.0.0',
    status: args.write ? 'sanitized' : 'dry_run',
    repoRoot,
    removed,
    rewritten,
    keptPublicWorkflowOrchestration: kept,
    policy: {
      privateSkills: 'remove src/private-internal-skills and bundled private-internal-skills',
      workflow: 'remove private workflow overlays with private skills; keep public story-workflow and workflow-state-machine',
      publicBundle: 'rebuild with NOVEL_ASSISTANT_INCLUDE_PRIVATE=0 before audit'
    }
  };

  if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    console.log(`${result.status}: ${removed.length} removable item(s)`);
    for (const item of removed) console.log(`- ${item.path}`);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
