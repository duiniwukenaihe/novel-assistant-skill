#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node scripts/safe-text-search.js --root <dir> --query <text> [--glob "*.md"] [--mode files|lines] [--limit N] [--json]

Authorization-friendly text search for writing workflows. It replaces brittle
"cd && grep ... 2>/dev/null | head" shell snippets with one deterministic Node command.`;

function parseArgs(argv) {
  const args = { root: '', query: '', glob: '*.md', mode: 'files', limit: 50, json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--root') args.root = argv[++i] || '';
    else if (arg === '--query') args.query = argv[++i] || '';
    else if (arg === '--glob') args.glob = argv[++i] || '*.md';
    else if (arg === '--mode') args.mode = argv[++i] || 'files';
    else if (arg === '--limit') args.limit = Math.max(1, Number(argv[++i] || 50) || 50);
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') {
      console.log(USAGE);
      process.exit(0);
    } else {
      die(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function die(message) {
  console.error(message);
  console.error(USAGE);
  process.exit(2);
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.root) die('--root is required');
  if (!args.query) die('--query is required');
  if (!['files', 'lines'].includes(args.mode)) die('--mode must be files or lines');

  const root = path.resolve(args.root);
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    emit(args, { status: 'missing_root', root, query: args.query, results: [] });
    return;
  }

  const matcher = compileGlob(args.glob);
  const results = [];
  for (const file of walk(root)) {
    if (!matcher(path.basename(file))) continue;
    const text = readText(file);
    if (!text.includes(args.query)) continue;
    if (args.mode === 'files') {
      results.push({ path: file });
    } else {
      const lines = text.split(/\r?\n/);
      for (let i = 0; i < lines.length; i += 1) {
        if (lines[i].includes(args.query)) {
          results.push({ path: file, line: i + 1, text: lines[i].slice(0, 240) });
          if (results.length >= args.limit) break;
        }
      }
    }
    if (results.length >= args.limit) break;
  }

  emit(args, {
    status: 'ok',
    root,
    query: args.query,
    glob: args.glob,
    mode: args.mode,
    limit: args.limit,
    count: results.length,
    results,
  });
}

function* walk(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true })
    .sort((a, b) => a.name.localeCompare(b.name, 'zh-Hans-CN'));
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(fullPath);
    else if (entry.isFile()) yield fullPath;
  }
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

function compileGlob(glob) {
  const normalized = String(glob || '*.md').trim();
  if (normalized === '*') return () => true;
  if (/^\*\.[A-Za-z0-9]+$/.test(normalized)) {
    const suffix = normalized.slice(1);
    return (name) => name.endsWith(suffix);
  }
  if (!/[?*[\]{}]/.test(normalized)) return (name) => name === normalized;
  const escaped = normalized
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*/g, '.*')
    .replace(/\?/g, '.');
  const re = new RegExp(`^${escaped}$`);
  return (name) => re.test(name);
}

function emit(args, payload) {
  if (args.json) {
    process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
    return;
  }
  for (const result of payload.results || []) {
    if (args.mode === 'lines') console.log(`${result.path}:${result.line}:${result.text}`);
    else console.log(result.path);
  }
}

main();
