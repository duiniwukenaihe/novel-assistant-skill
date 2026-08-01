#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const POLICY_FILE = 'config/github-public-release-files.json';

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

function walkFiles(root, base = '') {
  const directory = path.join(root, base);
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (!base && entry.name === '.git') return [];
    const relative = base ? `${base}/${entry.name}` : entry.name;
    if (entry.isDirectory()) return walkFiles(root, relative);
    return entry.isFile() ? [relative] : [];
  }).sort();
}

function safeRelativeFile(value) {
  if (typeof value !== 'string' || !value || value.includes('\\')
    || path.posix.isAbsolute(value) || path.win32.isAbsolute(value)) return false;
  const segments = value.split('/');
  return !segments.some((segment) => !segment || segment === '.' || segment === '..');
}

function loadPolicy(sourceRoot) {
  const policyPath = path.join(sourceRoot, POLICY_FILE);
  if (!fs.existsSync(policyPath)) return { additionalFiles: [], removedFiles: [] };
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));
  const removedFiles = policy?.removedFiles ?? [];
  if (!policy || policy.schemaVersion !== 1 || !Array.isArray(policy.additionalFiles)
    || !Array.isArray(removedFiles)) {
    throw new Error(`invalid public release file policy: ${policyPath}`);
  }
  for (const relative of [...policy.additionalFiles, ...removedFiles]) {
    if (!safeRelativeFile(relative)) throw new Error(`unsafe public release file: ${relative}`);
  }
  const additional = [...new Set(policy.additionalFiles)].sort();
  const removed = [...new Set(removedFiles)].sort();
  const removedSet = new Set(removed);
  const conflict = additional.find((relative) => removedSet.has(relative));
  if (conflict) throw new Error(`conflicting public release file policy: ${conflict}`);
  return { additionalFiles: additional, removedFiles: removed };
}

function trackedFiles(targetRoot) {
  const result = spawnSync('git', ['ls-files', '-z'], {
    cwd: targetRoot,
    encoding: 'utf8',
    shell: false,
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || 'could not read target Git index').trim());
  }
  return result.stdout.split('\0').filter(Boolean).sort();
}

function copyFile(sourceRoot, targetRoot, relative) {
  const source = path.join(sourceRoot, relative);
  if (!fs.existsSync(source) || !fs.statSync(source).isFile()) return false;
  const target = path.join(targetRoot, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(source, target);
  fs.chmodSync(target, fs.statSync(source).mode);
  return true;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.sourceRoot)) throw new Error(`source-root not found: ${args.sourceRoot}`);
  if (!fs.existsSync(args.targetRoot)) throw new Error(`target-root not found: ${args.targetRoot}`);
  if (!fs.existsSync(path.join(args.targetRoot, '.git'))) {
    throw new Error('target-root must be a Git worktree');
  }

  const sourceFiles = walkFiles(args.sourceRoot);
  const sourceFileSet = new Set(sourceFiles);
  const policy = loadPolicy(args.sourceRoot);
  for (const relative of policy.additionalFiles) {
    if (!sourceFileSet.has(relative)) throw new Error(`missing explicit public release file: ${relative}`);
  }
  const baselineFiles = trackedFiles(args.targetRoot);
  const approved = new Set([...baselineFiles, ...policy.additionalFiles]);
  for (const relative of policy.removedFiles) approved.delete(relative);
  if (fs.existsSync(path.join(args.sourceRoot, POLICY_FILE))) approved.add(POLICY_FILE);
  const targetEntries = topLevelEntries(args.targetRoot);
  const approvedFiles = [...approved].filter((relative) => sourceFileSet.has(relative)).sort();
  const skippedUnapproved = sourceFiles.filter((relative) => !approved.has(relative));
  const result = {
    schemaVersion: '1.0.0',
    status: args.write ? 'synced' : 'dry_run',
    sourceRoot: args.sourceRoot,
    targetRoot: args.targetRoot,
    policy: 'target_git_index_plus_explicit_additions',
    sourceFiles: sourceFiles.length,
    baselineTrackedFiles: baselineFiles.length,
    explicitAdditionalFiles: policy.additionalFiles,
    removedFiles: policy.removedFiles,
    approvedFiles: approvedFiles.length,
    skippedUnapprovedCount: skippedUnapproved.length,
    skippedUnapprovedFiles: skippedUnapproved.slice(0, 100),
    removedTopLevelEntries: targetEntries,
    copiedTopLevelEntries: [...new Set(approvedFiles.map((relative) => relative.split('/')[0]))].sort(),
    preserved: ['.git']
  };

  if (args.write) {
    for (const name of targetEntries) {
      fs.rmSync(path.join(args.targetRoot, name), { recursive: true, force: true });
    }
    for (const relative of approvedFiles) copyFile(args.sourceRoot, args.targetRoot, relative);
  }

  if (args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else process.stdout.write(`${result.status}: ${result.approvedFiles} approved file(s), ${result.skippedUnapprovedCount} skipped\n`);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
