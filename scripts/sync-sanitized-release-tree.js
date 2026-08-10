#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const bundleVersion = require('./lib/bundle-version');

const POLICY_FILE = 'config/github-public-release-files.json';
const POLICY_NAME = 'explicit_review_with_exact_candidate_manifest';
const CANDIDATE_MANIFEST = 'config/github-public-release-candidate-manifest.json';
const BUNDLE_FILE_MANIFEST = 'config/novel-assistant-bundle-files.json';
const BUNDLE_PREFIX = 'skills/novel-assistant/';
const PUBLIC_RUNTIME_ENTRYPOINTS = [
  'scripts/workflow-state-machine.js',
  'scripts/workflow-v3.js',
  'scripts/workflow-entry-guard.js',
  'scripts/workflow-task-inbox.js',
  'scripts/production-smoke-matrix.js',
  'scripts/na-dev.js',
  'scripts/production-release-gate.js',
  'scripts/novel-assistant-self-update.js',
  'scripts/novel-assistant-sync-runtime.js',
  'scripts/behavior-eval.js',
  'skills/novel-assistant/scripts/workflow-state-machine.js',
  'skills/novel-assistant/scripts/workflow-v3.js',
  'skills/novel-assistant/scripts/workflow-entry-guard.js',
  'skills/novel-assistant/scripts/workflow-task-inbox.js',
  'skills/novel-assistant/scripts/production-smoke-matrix.js',
  'skills/novel-assistant/scripts/novel-assistant-self-update.js',
  'skills/novel-assistant/scripts/novel-assistant-sync-runtime.js',
  'skills/novel-assistant/scripts/behavior-eval.js',
];

// Private skill trees are never publishable, even if a caller mistakenly puts
// them in additionalFiles or they existed on an older public branch.
const HARD_DENY_PREFIXES = [
  'src/private-internal-skills/',
  'skills/novel-assistant/references/private-internal-skills/',
];

function hasPrefix(relative, prefixes) {
  return prefixes.some((prefix) => relative.startsWith(prefix));
}

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
    if (entry.isSymbolicLink()) {
      throw new Error(`symbolic link is not allowed in release source: ${relative}`);
    }
    if (entry.isDirectory()) return walkFiles(root, relative);
    if (entry.isFile()) return [relative];
    throw new Error(`unsupported source entry in release source: ${relative}`);
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

function sha256(file) {
  return require('crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function writeCandidateManifest(targetRoot, approvedFiles) {
  const files = {};
  for (const relative of approvedFiles) {
    const target = path.join(targetRoot, relative);
    if (fs.existsSync(target) && fs.statSync(target).isFile()) files[relative] = sha256(target);
  }
  const target = path.join(targetRoot, CANDIDATE_MANIFEST);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify({
    schemaVersion: '1.0.0',
    policy: POLICY_NAME,
    files,
  }, null, 2)}\n`);
}

function classifySourceFiles(sourceFiles, baselineFiles, policy) {
  const baselineSet = new Set(baselineFiles);
  const additionalSet = new Set(policy.additionalFiles);
  const removedSet = new Set(policy.removedFiles);
  const explicitAdditions = [];
  const inherited = [];
  const skippedUnapproved = [];
  for (const relative of sourceFiles) {
    if (removedSet.has(relative)) continue; // removedFiles always wins
    if (hasPrefix(relative, HARD_DENY_PREFIXES)) {
      skippedUnapproved.push(relative);
      continue;
    }
    if (additionalSet.has(relative)) {
      explicitAdditions.push(relative);
      continue;
    }
    if (baselineSet.has(relative)) {
      inherited.push(relative);
      continue;
    }
    skippedUnapproved.push(relative);
  }
  return {
    explicitAdditions: [...new Set(explicitAdditions)].sort(),
    inherited: [...new Set(inherited)].sort(),
    skippedUnapproved: [...new Set(skippedUnapproved)].sort(),
  };
}

function resolveRelativeDependency(sourceRoot, sourceFiles, from, specifier) {
  const base = path.resolve(path.dirname(path.join(sourceRoot, from)), specifier);
  const candidates = [base, `${base}.js`, `${base}.json`, path.join(base, 'index.js')];
  for (const candidate of candidates) {
    const relative = path.relative(sourceRoot, candidate).replace(/\\/gu, '/');
    if (!relative || relative.startsWith('../') || path.isAbsolute(relative)) continue;
    if (sourceFiles.has(relative)) return relative;
  }
  throw new Error(`public runtime dependency is missing from source: ${from} -> ${specifier}`);
}

function runtimeDependencyClosure(sourceRoot, sourceFiles) {
  const closure = new Set();
  const pending = PUBLIC_RUNTIME_ENTRYPOINTS.filter((entry) => sourceFiles.has(entry));
  while (pending.length > 0) {
    const current = pending.pop();
    if (closure.has(current)) continue;
    closure.add(current);
    const text = fs.readFileSync(path.join(sourceRoot, current), 'utf8');
    for (const match of text.matchAll(/require\(\s*(['"])(\.{1,2}\/[\w./-]+)\1\s*\)/gu)) {
      const dependency = resolveRelativeDependency(sourceRoot, sourceFiles, current, match[2]);
      if (!closure.has(dependency)) pending.push(dependency);
    }
  }
  return [...closure].sort();
}

function v3VerificationTests(sourceRoot, sourceFiles) {
  const runner = 'scripts/na-dev.js';
  if (!sourceFiles.has(runner)) return [];
  const text = fs.readFileSync(path.join(sourceRoot, runner), 'utf8');
  const start = text.indexOf("case 'verify-v3-short':");
  const end = text.indexOf("case 'verify':", start);
  if (start < 0 || end < 0) return [];
  return [...new Set([...text.slice(start, end).matchAll(/'(tests\/[^']+\.bats)'/gu)]
    .map((match) => match[1]))].sort();
}

function publicBundleSourceInputs(sourceRoot, sourceFiles) {
  if (!sourceFiles.has(BUNDLE_FILE_MANIFEST)) return [];
  const { exactPaths } = bundleVersion.bundleInputMatchers(
    sourceRoot,
    'novel-assistant',
    { includePrivate: false },
  );
  return [...exactPaths]
    .filter((relative) => sourceFiles.has(relative) && !hasPrefix(relative, HARD_DENY_PREFIXES))
    .sort();
}

function publicBundledFiles(sourceFiles) {
  return [...sourceFiles]
    .filter((relative) => relative.startsWith(BUNDLE_PREFIX) && !hasPrefix(relative, HARD_DENY_PREFIXES))
    .sort();
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
  const classification = classifySourceFiles(sourceFiles, baselineFiles, policy);
  const approved = new Set([
    ...classification.inherited,
    ...classification.explicitAdditions,
  ]);
  // removedFiles always win over inherited and explicit additions.
  for (const relative of policy.removedFiles) approved.delete(relative);
  if (fs.existsSync(path.join(args.sourceRoot, POLICY_FILE))) approved.add(POLICY_FILE);
  const requiredRuntime = runtimeDependencyClosure(args.sourceRoot, sourceFileSet);
  const missingRuntime = requiredRuntime.filter((relative) => !approved.has(relative));
  if (missingRuntime.length > 0) {
    throw new Error(`public runtime dependency missing from release policy: ${missingRuntime.join(', ')}`);
  }
  const requiredV3Tests = v3VerificationTests(args.sourceRoot, sourceFileSet);
  const missingV3Tests = requiredV3Tests.filter((relative) => !approved.has(relative));
  if (missingV3Tests.length > 0) {
    throw new Error(`public V3 verification test missing from release policy: ${missingV3Tests.join(', ')}`);
  }
  const requiredBundleInputs = publicBundleSourceInputs(args.sourceRoot, sourceFileSet);
  const missingBundleInputs = requiredBundleInputs.filter((relative) => !approved.has(relative));
  if (missingBundleInputs.length > 0) {
    throw new Error(`public bundle source input missing from release policy: ${missingBundleInputs.join(', ')}`);
  }
  const requiredBundledFiles = publicBundledFiles(sourceFileSet);
  const missingBundledFiles = requiredBundledFiles.filter((relative) => !approved.has(relative));
  if (missingBundledFiles.length > 0) {
    throw new Error(`public bundled file missing from release policy: ${missingBundledFiles.join(', ')}`);
  }
  const targetEntries = topLevelEntries(args.targetRoot);
  const approvedFiles = [...approved].filter((relative) => sourceFileSet.has(relative)).sort();
  const result = {
    schemaVersion: '1.0.0',
    status: args.write ? 'synced' : 'dry_run',
    sourceRoot: args.sourceRoot,
    targetRoot: args.targetRoot,
    policy: POLICY_NAME,
    sourceFiles: sourceFiles.length,
    baselineTrackedFiles: baselineFiles.length,
    hardDenyPrefixes: [...HARD_DENY_PREFIXES],
    explicitAdditionalFiles: classification.explicitAdditions,
    inheritedBaselineFiles: classification.inherited,
    removedFiles: policy.removedFiles,
    approvedFiles: approvedFiles.length,
    skippedUnapprovedCount: classification.skippedUnapproved.length,
    skippedUnapprovedFiles: classification.skippedUnapproved.slice(0, 100),
    removedTopLevelEntries: targetEntries,
    copiedTopLevelEntries: [...new Set(approvedFiles.map((relative) => relative.split('/')[0]))].sort(),
    candidateManifest: CANDIDATE_MANIFEST,
    runtimeDependencyCount: requiredRuntime.length,
    requiredV3VerificationTests: requiredV3Tests,
    publicBundleSourceInputCount: requiredBundleInputs.length,
    publicBundledFileCount: requiredBundledFiles.length,
    preserved: ['.git']
  };

  if (args.write) {
    for (const name of targetEntries) {
      fs.rmSync(path.join(args.targetRoot, name), { recursive: true, force: true });
    }
    for (const relative of approvedFiles) copyFile(args.sourceRoot, args.targetRoot, relative);
    writeCandidateManifest(args.targetRoot, approvedFiles);
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
