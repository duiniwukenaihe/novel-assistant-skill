#!/usr/bin/env node
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const {
  computeBundleId,
  computeManifestSourceInputDigest,
  computeManifestSourceTreeId,
  releaseSourceState,
  sourceCommit,
  sourceState,
} = require('./lib/bundle-version');

const SCHEMA_VERSION = '1.0.0';

function parseArgs(argv) {
  const args = { repoRoot: process.cwd(), json: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--json') {
      args.json = true;
    } else if (arg === '--repo-root') {
      args.repoRoot = path.resolve(argv[++i]);
    } else if (arg === '--help' || arg === '-h') {
      args.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function runGit(repoRoot, args) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    shell: false
  });
  return {
    status: result.status,
    stdout: (result.stdout || '').trim(),
    stderr: (result.stderr || '').trim()
  };
}

function currentBranch(repoRoot) {
  const result = runGit(repoRoot, ['branch', '--show-current']);
  return result.status === 0 ? result.stdout || null : null;
}

function currentCommit(repoRoot) {
  const result = runGit(repoRoot, ['rev-parse', '--short', 'HEAD']);
  return result.status === 0 ? result.stdout || null : null;
}

function remotes(repoRoot) {
  const result = runGit(repoRoot, ['remote', '-v']);
  if (result.status !== 0) return [];
  const seen = new Set();
  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const match = line.match(/^(\S+)\s+(\S+)\s+\((fetch|push)\)$/);
      if (!match) return null;
      return { name: match[1], url: match[2], direction: match[3] };
    })
    .filter(Boolean)
    .filter((remote) => {
      const key = `${remote.name}:${remote.url}:${remote.direction}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function worktrees(repoRoot) {
  const result = runGit(repoRoot, ['worktree', 'list', '--porcelain']);
  if (result.status !== 0) return [];
  const entries = [];
  let current = null;
  for (const line of result.stdout.split(/\r?\n/)) {
    if (!line.trim()) {
      if (current) entries.push(current);
      current = null;
      continue;
    }
    const [key, ...rest] = line.split(' ');
    const value = rest.join(' ');
    if (key === 'worktree') current = { path: value };
    else if (current && key === 'HEAD') current.head = value;
    else if (current && key === 'branch') current.branch = value.replace(/^refs\/heads\//, '');
    else if (current && key === 'detached') current.detached = true;
  }
  if (current) entries.push(current);
  return entries;
}

function publicReleaseInfo(repoRoot) {
  const trees = worktrees(repoRoot);
  const candidates = trees.filter((entry) => entry.branch === 'github/public-release');
  const preferred = candidates.find((entry) => /novel-assistant-public-release/.test(entry.path)) || candidates[0] || null;
  if (!preferred) {
    return {
      status: 'missing',
      branch: 'github/public-release',
      path: null,
      commit: null
    };
  }
  const commit = runGit(preferred.path, ['rev-parse', '--short', 'HEAD']);
  return {
    status: fs.existsSync(preferred.path) ? 'present' : 'missing_path',
    branch: preferred.branch,
    path: preferred.path,
    commit: commit.status === 0 ? commit.stdout : preferred.head || null
  };
}

function githubRemoteInfo(repoRoot) {
  const githubRemotes = remotes(repoRoot).filter((remote) => /github\.com[:/]/.test(remote.url));
  const pushRemote = githubRemotes.find((remote) => remote.direction === 'push') || githubRemotes[0] || null;
  if (!pushRemote) {
    return { status: 'missing', name: null, url: null };
  }
  return { status: 'present', name: pushRemote.name, url: pushRemote.url };
}

function privateRisk(repoRoot) {
  const paths = [
    'src/private-internal-skills',
    'skills/novel-assistant/references/private-internal-skills',
    'docs/superpowers'
  ];
  const present = paths.filter((relativePath) => fs.existsSync(path.join(repoRoot, relativePath)));
  return {
    status: present.length > 0 ? 'internal_branch_contains_private_assets' : 'clean_for_public_assets',
    present,
    note: present.length > 0
      ? '开发分支允许存在私有资产；发布 GitHub 必须使用清理后的 public-release worktree。'
      : '当前分支未发现已知私有资产目录。'
  };
}

function remoteTrackingRef(repoRoot, remoteName, branchName) {
  if (!remoteName) return null;
  const result = runGit(repoRoot, ['rev-parse', '--short', `refs/remotes/${remoteName}/${branchName}`]);
  if (result.status !== 0) return null;
  return result.stdout || null;
}

function bundleVersion(repoRoot) {
  const manifestPath = path.join(repoRoot, 'skills', 'novel-assistant', 'novel-assistant-manifest.json');
  if (!fs.existsSync(manifestPath)) return { status: 'missing', manifestPath };
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const sourceTreeId = manifest.sourceTreeId ? String(manifest.sourceTreeId) : null;
  const computedSourceTreeId = sourceTreeId
    ? computeManifestSourceTreeId(repoRoot, manifest.bundleName || 'novel-assistant', manifest.sourceLayout)
    : null;
  const sourceInputDigest = manifest.sourceInputDigest ? String(manifest.sourceInputDigest) : null;
  const computedSourceInputDigest = sourceInputDigest
    ? computeManifestSourceInputDigest(repoRoot, manifest.bundleName || 'novel-assistant', manifest.sourceLayout)
    : null;
  const currentCommit = sourceCommit(repoRoot);
  const bundleId = String(manifest.bundleId || '');
  const computedBundleId = computeBundleId(path.dirname(manifestPath));
  const sourceTreeCurrent = sourceTreeId && computedSourceTreeId ? sourceTreeId === computedSourceTreeId : null;
  const sourceInputCurrent = sourceInputDigest && computedSourceInputDigest
    ? sourceInputDigest === computedSourceInputDigest
    : null;
  const manifestSourceState = String(manifest.sourceState || '');
  const repositoryState = sourceState(repoRoot);
  const currentSourceState = releaseSourceState(repoRoot, manifest.bundleName || 'novel-assistant');
  const contentCurrent = bundleId === computedBundleId && sourceTreeCurrent === true && sourceInputCurrent !== false;
  const releaseReady = contentCurrent && manifestSourceState === 'clean' && currentSourceState === 'clean';
  return {
    status: 'present',
    manifestPath,
    bundleId,
    computedBundleId,
    sourceTreeId,
    computedSourceTreeId,
    sourceTreeCurrent,
    sourceInputDigest,
    computedSourceInputDigest,
    sourceInputCurrent,
    sourceLayout: manifest.sourceLayout || null,
    sourceState: manifestSourceState,
    currentSourceState,
    repositoryState,
    sourceCommit: String(manifest.sourceCommit || ''),
    sourceCommitRole: String(manifest.sourceCommitRole || ''),
    currentCommit,
    sourceCommitLag: Boolean(currentCommit && manifest.sourceCommit && manifest.sourceCommit !== currentCommit),
    contentCurrent,
    releaseReady,
    releaseStatus: releaseReady
      ? 'candidate_ready'
      : contentCurrent
        ? 'candidate_rebuild_required'
        : 'candidate_content_stale',
  };
}

function buildStatus(repoRoot) {
  const resolvedRoot = path.resolve(repoRoot);
  const githubRemote = githubRemoteInfo(resolvedRoot);
  const behaviorGate = behaviorGateInfo(resolvedRoot);
  return {
    schemaVersion: SCHEMA_VERSION,
    repoRoot: resolvedRoot,
    currentBranch: currentBranch(resolvedRoot),
    currentCommit: currentCommit(resolvedRoot),
    publicRelease: publicReleaseInfo(resolvedRoot),
    githubRemote,
    githubRefs: {
      main: remoteTrackingRef(resolvedRoot, githubRemote.name, 'main'),
      publicRelease: remoteTrackingRef(resolvedRoot, githubRemote.name, 'github/public-release')
    },
    bundleVersion: bundleVersion(resolvedRoot),
    behaviorGate,
    privateRisk: privateRisk(resolvedRoot)
  };
}

function behaviorGateInfo(repoRoot) {
  try {
    // Optional so release-status remains usable in minimal fixtures that copy only
    // release-status.js and bundle-version.js.
    const { evaluateGate } = require('./behavior-eval-release-gate');
    return evaluateGate(repoRoot);
  } catch (error) {
    if (error && error.code === 'MODULE_NOT_FOUND' && /behavior-eval-release-gate/.test(String(error.message || ''))) {
      return { status: 'unavailable', reason: 'behavior_eval_release_gate_not_installed' };
    }
    return { status: 'error', error: error.message };
  }
}

function printText(status) {
  console.log('novel-assistant release status');
  console.log(`repo: ${status.repoRoot}`);
  console.log(`current: ${status.currentBranch || 'unknown'} @ ${status.currentCommit || 'unknown'}`);
  console.log(`public worktree: ${status.publicRelease.status} ${status.publicRelease.path || ''}`.trim());
  console.log(`public commit: ${status.publicRelease.commit || 'unknown'}`);
  console.log(`github remote: ${status.githubRemote.status} ${status.githubRemote.name || ''} ${status.githubRemote.url || ''}`.trim());
  console.log(`github main: ${status.githubRefs.main || 'unknown'}`);
  console.log(`github public-release: ${status.githubRefs.publicRelease || 'unknown'}`);
  console.log(`bundle: ${status.bundleVersion.bundleId || 'unknown'} source tree: ${status.bundleVersion.sourceTreeId || 'unknown'}`);
  console.log(`release candidate: ${status.bundleVersion.releaseStatus || 'unknown'}`);
  console.log(`behavior gate: ${(status.behaviorGate || {}).status || 'unknown'}`);
  console.log(`private risk: ${status.privateRisk.status}`);
  if (status.privateRisk.present.length > 0) {
    console.log(`private paths: ${status.privateRisk.present.join(', ')}`);
  }
  console.log(status.privateRisk.note);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log('Usage: node scripts/release-status.js [--repo-root PATH] [--json]');
    return;
  }
  const status = buildStatus(args.repoRoot);
  if (args.json) {
    process.stdout.write(`${JSON.stringify(status)}\n`);
  } else {
    printText(status);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
