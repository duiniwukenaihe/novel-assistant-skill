#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = { sourceRoot: '', targetRoot: '', write: false, json: false };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--source-root') args.sourceRoot = path.resolve(argv[++index] || '');
    else if (arg === '--target-root') args.targetRoot = path.resolve(argv[++index] || '');
    else if (arg === '--write') args.write = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') {
      process.stdout.write('Usage: node scripts/sync-sanitized-release-tree.js --source-root <sanitized-worktree> --target-root <public-worktree> [--write] [--json]\n');
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.sourceRoot || !args.targetRoot) throw new Error('source-root and target-root are required');
  if (args.sourceRoot === args.targetRoot) throw new Error('source-root and target-root must be different');
  return args;
}

function topLevelEntries(root) {
  return fs.readdirSync(root, { withFileTypes: true })
    .map((entry) => entry.name)
    .filter((name) => name !== '.git');
}

function countFiles(root) {
  let count = 0;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (entry.name === '.git') continue;
    const target = path.join(root, entry.name);
    if (entry.isDirectory()) count += countFiles(target);
    else if (entry.isFile()) count += 1;
  }
  return count;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.sourceRoot)) throw new Error(`source-root not found: ${args.sourceRoot}`);
  if (!fs.existsSync(args.targetRoot)) throw new Error(`target-root not found: ${args.targetRoot}`);
  if (!fs.existsSync(path.join(args.targetRoot, '.git'))) {
    throw new Error('target-root must be a Git worktree');
  }

  const sourceEntries = topLevelEntries(args.sourceRoot);
  const targetEntries = topLevelEntries(args.targetRoot);
  const result = {
    schemaVersion: '1.0.0',
    status: args.write ? 'synced' : 'dry_run',
    sourceRoot: args.sourceRoot,
    targetRoot: args.targetRoot,
    sourceFiles: countFiles(args.sourceRoot),
    removedTopLevelEntries: targetEntries,
    copiedTopLevelEntries: sourceEntries,
    preserved: ['.git']
  };

  if (args.write) {
    for (const name of targetEntries) {
      fs.rmSync(path.join(args.targetRoot, name), { recursive: true, force: true });
    }
    for (const name of sourceEntries) {
      fs.cpSync(path.join(args.sourceRoot, name), path.join(args.targetRoot, name), {
        recursive: true,
        force: true,
        preserveTimestamps: true
      });
    }
  }

  if (args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else process.stdout.write(`${result.status}: ${result.sourceFiles} file(s) from sanitized source\n`);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
