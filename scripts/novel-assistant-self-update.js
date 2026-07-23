#!/usr/bin/env node
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const args = parseArgs(process.argv.slice(2));
const skillDir = path.resolve(args.skillDir || path.join(__dirname, '..'));
const manifestPath = path.resolve(args.manifest || path.join(skillDir, 'novel-assistant-manifest.json'));
const installedManifest = fs.existsSync(manifestPath) ? readJson(manifestPath) : {};
const sourceContext = resolveSourceContext(args, skillDir, manifestPath, installedManifest);
const sourceDir = sourceContext.sourceDir;
const remote = args.remote || 'origin';
const branch = args.branch || sourceContext.branch || 'main';
const remoteRef = `refs/remotes/${remote}/${branch}`;
const jsonOutput = Boolean(args.json);
const apply = Boolean(args.apply);
const channel = args.channel || '';
const installTargets = args.installTargets.length
  ? args.installTargets.map(expandHome)
  : [
      path.join(os.homedir(), '.claude', 'skills', 'novel-assistant'),
      path.join(os.homedir(), '.codex', 'skills', 'novel-assistant'),
    ];

main();

function main() {
  try {
    assertGitRepo(sourceDir);
    fetchRemote(sourceDir, remote, branch);
    const result = buildUpdateResult(sourceDir, remote, branch, remoteRef, sourceContext);
    attachProjectRuntime(result, sourceDir, args.projectRoot);

    if (apply) {
      if (sourceContext.sourceMode === 'source_dir' && !isWorktreeClean(sourceDir)) {
        return emitAndExit(
          {
            ...result,
            status: 'blocked_dirty_worktree',
            applied: false,
            message: '本地仓库有未提交改动，不能自动更新 skill。',
            recommendation: '请先提交、暂存或处理本地改动，再重新运行 /novel-assistant 更新 skill。',
          },
          1,
        );
      }
      applyUpdate(result);
      if (result.status === 'blocked_production_smoke') {
        return emitAndExit(result, 1);
      }
    }

    emit(result);
  } catch (error) {
    emitAndExit(
      {
        status: 'error',
        applied: false,
        message: error.message,
      },
      1,
    );
  }
}

function buildUpdateResult(repo, remoteName, branchName, ref, context) {
  const currentCommit = context.currentCommit || git(repo, ['rev-parse', 'HEAD']).stdout.trim();
  const currentShort = short(repo, currentCommit);
  const remoteCommit = git(repo, ['rev-parse', ref]).stdout.trim();
  const remoteShort = short(repo, remoteCommit);
  const latestStableTag = findLatestStableTag(repo, ref);
  const latestStableCommit = latestStableTag ? git(repo, ['rev-list', '-n', '1', latestStableTag]).stdout.trim() : '';
  const remoteBundle = readBundleManifestAt(repo, ref, context.bundleName);
  const stableBundle = latestStableTag ? readBundleManifestAt(repo, latestStableTag, context.bundleName) : null;
  const remoteSameBundle = Boolean(context.bundleId && remoteBundle.bundleId === context.bundleId);
  const stableSameBundle = Boolean(context.bundleId && stableBundle && stableBundle.bundleId === context.bundleId);
  const stableUpdateAvailable = Boolean(latestStableCommit && !stableSameBundle && !isAncestor(repo, latestStableCommit, currentCommit));
  const developmentUpdateAvailable = !remoteSameBundle && currentCommit !== remoteCommit && isAncestor(repo, currentCommit, remoteCommit);

  let status = 'current';
  let recommendedChannel = 'none';
  let isStable = true;
  let recommendation = '当前 novel-assistant skill 已是最新，无需更新。';

  if (stableUpdateAvailable) {
    status = 'stable_update_available';
    recommendedChannel = 'stable';
    isStable = true;
    recommendation = `发现稳定版 ${latestStableTag} 可更新。建议更新到最新稳定版，然后更新当前书籍项目的写作协作环境。`;
  } else if (developmentUpdateAvailable) {
    status = 'development_update_available';
    recommendedChannel = 'development';
    isStable = false;
    recommendation = `发现开发版更新 ${remoteName}/${branchName}@${remoteShort}，但没有新的稳定版本。开发版可能改变写作流程，是否仍要更新？`;
  }

  return {
    status,
    applied: false,
    sourceMode: context.sourceMode,
    skillDir: context.skillDir,
    manifestPath: context.manifestPath,
    updateSourceUrl: context.updateSourceUrl,
    currentBundleId: context.bundleId,
    remoteBundleId: remoteBundle.bundleId || '',
    latestStableBundleId: stableBundle && stableBundle.bundleId ? stableBundle.bundleId : '',
    sourceDir: repo,
    remote: remoteName,
    branch: branchName,
    currentCommit: currentShort,
    latestDevelopmentCommit: remoteShort,
    latestStableTag: latestStableTag || '',
    latestStableCommit: latestStableCommit ? short(repo, latestStableCommit) : '',
    recommendedChannel,
    isStable,
    requiresConfirmation: status !== 'current',
    recommendation: decorateRecommendationForSourceMode(recommendation, context),
    updateChoices: buildChoices(status, latestStableTag, remoteShort),
  };
}

function readBundleManifestAt(repo, ref, bundleName) {
  const name = bundleName || 'novel-assistant';
  const res = git(repo, ['show', `${ref}:skills/${name}/novel-assistant-manifest.json`], { allowFailure: true });
  if (res.status !== 0 || !res.stdout.trim()) return {};
  try {
    return JSON.parse(res.stdout);
  } catch (_error) {
    return {};
  }
}

function decorateRecommendationForSourceMode(recommendation, context) {
  if (context.sourceMode !== 'installed_manifest') return recommendation;
  return `${recommendation} 本次检查通过 novel-assistant 自检更新通道完成，不需要用户执行 npx skills update。`;
}

function buildChoices(status, stableTag, devShort) {
  if (status === 'stable_update_available') {
    return [
      `更新到最新稳定版 ${stableTag}（推荐）`,
      `更新到最新开发版 main@${devShort}`,
      '取消',
    ];
  }
  if (status === 'development_update_available') {
    return [
      `更新到开发版 main@${devShort}`,
      '取消',
    ];
  }
  return [];
}

function attachProjectRuntime(result, repo, projectRoot) {
  if (!projectRoot) {
    result.projectRuntimeStatus = 'not_checked';
    result.shouldRunProjectSetup = false;
    return;
  }

  const manifestPath = path.join(repo, 'skills', 'novel-assistant', 'novel-assistant-manifest.json');
  const projectAbs = path.resolve(projectRoot);
  const deployedPath = path.join(projectAbs, '.story-deployed');
  if (!fs.existsSync(manifestPath)) {
    result.projectRuntimeStatus = 'manifest_missing';
    result.shouldRunProjectSetup = false;
    result.projectRecommendation = '未找到 novel-assistant manifest，无法判断当前写作协作环境是否需要更新。';
    return;
  }

  const current = readJson(manifestPath);
  const deployed = fs.existsSync(deployedPath) ? readSentinel(deployedPath) : null;
  if (!deployed) {
    result.projectRuntimeStatus = 'not_deployed';
    result.shouldRunProjectSetup = true;
    result.projectRecommendation = '当前书籍项目尚未部署 novel-assistant 写作协作环境，建议执行 /novel-assistant 准备写书。';
    return;
  }

  const stale =
    String(current.bundleId || '') !== String(deployed.novel_assistant_bundle_id || '') ||
    Number(current.agentsVersion || 0) > Number(deployed.agents_version || 0) ||
    String(current.setupSkillVersion || '') !== String(deployed.setup_skill_version || '');

  result.projectRuntimeStatus = stale ? 'update_available' : 'current';
  result.shouldRunProjectSetup = stale;
  result.projectRecommendation = stale
    ? 'skill 更新后需要更新当前书籍项目的写作协作环境：建议执行 /novel-assistant 更新写作协作环境，同步 hooks / agents / rules / scripts / references。'
    : '当前写作协作环境已匹配本地 skill。';
}

function applyUpdate(result) {
  const selected = channel || result.recommendedChannel;
  if (!['stable', 'development'].includes(selected)) {
    throw new Error('没有可应用的更新目标。');
  }
  if (selected === 'stable' && !result.latestStableTag) {
    throw new Error('没有可用的稳定版本 tag。');
  }
  if (selected === 'development' && result.status === 'current') {
    throw new Error('没有可用的开发版更新。');
  }

  const workDir = selected === 'stable' ? createStableWorktree(sourceDir, result.latestStableTag) : sourceDir;
  try {
    if (selected === 'development') {
      git(sourceDir, ['merge', '--ff-only', remoteRef]);
    }
    buildBundle(workDir);
    const productionSmoke = runProductionSmokeMatrix(workDir);
    result.productionSmokeStatus = productionSmoke.status;
    result.productionSmoke = productionSmoke.summary;
    if (productionSmoke.status !== 'pass') {
      result.status = 'blocked_production_smoke';
      result.applied = false;
      result.message = '生产验收矩阵未通过，已阻止安装 novel-assistant skill。请先修复 router/workflow/module/bundle 漂移。';
      result.productionSmokeFindings = productionSmoke.findings;
      return;
    }
    syncSkill(workDir, installTargets);
    result.applied = true;
    result.appliedChannel = selected;
    result.installTargets = installTargets;
    result.message =
      selected === 'stable'
        ? `已安装稳定版 ${result.latestStableTag}。`
        : `已安装开发版 ${result.latestDevelopmentCommit}。`;
  } finally {
    if (selected === 'stable' && workDir !== sourceDir) {
      git(sourceDir, ['worktree', 'remove', '--force', workDir], { allowFailure: true });
    }
  }
}

function runProductionSmokeMatrix(repo) {
  const script = path.join(repo, 'scripts', 'production-smoke-matrix.js');
  if (!fs.existsSync(script)) {
    return {
      status: 'fail',
      summary: {
        message: `缺少生产验收矩阵脚本：${script}`,
      },
      findings: [
        {
          target: 'scripts/production-smoke-matrix.js',
          message: 'required production smoke matrix is missing',
        },
      ],
    };
  }

  const res = run('node', [script, '--repo-root', repo, '--json'], { cwd: repo, allowFailure: true });
  let parsed = null;
  try {
    parsed = JSON.parse(res.stdout || '{}');
  } catch (error) {
    return {
      status: 'fail',
      summary: {
        message: `生产验收矩阵输出不是合法 JSON：${error.message}`,
        exitStatus: res.status,
      },
      findings: [
        {
          target: 'scripts/production-smoke-matrix.js',
          message: 'invalid json output',
        },
      ],
    };
  }

  const status = res.status === 0 && parsed.status === 'pass' ? 'pass' : 'fail';
  return {
    status,
    summary: {
      status: parsed.status || status,
      caseCount: parsed.caseCount || 0,
      globalCheckCount: Array.isArray(parsed.globalChecks) ? parsed.globalChecks.length : 0,
      findingCount: Array.isArray(parsed.findings) ? parsed.findings.length : 0,
    },
    findings: Array.isArray(parsed.findings) ? parsed.findings : [],
  };
}

function createStableWorktree(repo, tag) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-assistant-stable-'));
  git(repo, ['worktree', 'add', '--detach', dir, tag]);
  return dir;
}

function buildBundle(repo) {
  const script = path.join(repo, 'scripts', 'build-oh-story-bundle.sh');
  if (!fs.existsSync(script)) throw new Error(`缺少构建脚本：${script}`);
  run('bash', [script], { cwd: repo });
}

function syncSkill(repo, targets) {
  const src = path.join(repo, 'skills', 'novel-assistant');
  if (!fs.existsSync(path.join(src, 'SKILL.md'))) throw new Error(`缺少 skill 包：${src}`);
  for (const target of targets) {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    run('rsync', ['-a', '--delete', `${src}/`, `${target}/`], { cwd: repo });
  }
}

function findLatestStableTag(repo, ref) {
  const out = git(repo, ['tag', '--merged', ref, '--list', 'v[0-9]*']).stdout.trim();
  const tags = out ? out.split(/\r?\n/).filter(Boolean) : [];
  tags.sort(compareSemverTags);
  return tags[tags.length - 1] || '';
}

function compareSemverTags(a, b) {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  for (let i = 0; i < 3; i += 1) {
    if (pa[i] !== pb[i]) return pa[i] - pb[i];
  }
  return a.localeCompare(b);
}

function parseSemver(tag) {
  const match = tag.match(/^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?/);
  return match ? [Number(match[1] || 0), Number(match[2] || 0), Number(match[3] || 0)] : [0, 0, 0];
}

function isAncestor(repo, ancestor, descendant) {
  const res = git(repo, ['merge-base', '--is-ancestor', ancestor, descendant], { allowFailure: true });
  return res.status === 0;
}

function isWorktreeClean(repo) {
  return git(repo, ['status', '--porcelain']).stdout.trim() === '';
}

function fetchRemote(repo, remoteName, branchName) {
  git(repo, ['fetch', '--quiet', '--tags', remoteName, `+refs/heads/${branchName}:refs/remotes/${remoteName}/${branchName}`]);
}

function assertGitRepo(repo) {
  if (!fs.existsSync(repo)) throw new Error(`source dir not found: ${repo}`);
  git(repo, ['rev-parse', '--git-dir']);
}

function short(repo, commit) {
  return git(repo, ['rev-parse', '--short', commit]).stdout.trim();
}

function git(repo, gitArgs, options = {}) {
  return run('git', gitArgs, { cwd: repo, allowFailure: options.allowFailure });
}

function run(cmd, cmdArgs, options = {}) {
  const res = spawnSync(cmd, cmdArgs, {
    cwd: options.cwd,
    encoding: 'utf8',
  });
  if (res.status !== 0 && !options.allowFailure) {
    const detail = (res.stderr || res.stdout || '').trim();
    throw new Error(`${cmd} ${cmdArgs.join(' ')} failed${detail ? `: ${detail}` : ''}`);
  }
  return res;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function readSentinel(file) {
  const rows = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^([A-Za-z0-9_.-]+):\s*(.*)$/);
    if (match) rows[match[1]] = match[2].trim();
  }
  return rows;
}

function parseArgs(argv) {
  const parsed = {
    installTargets: [],
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--source-dir') parsed.sourceDir = argv[++i];
    else if (arg === '--skill-dir') parsed.skillDir = argv[++i];
    else if (arg === '--manifest') parsed.manifest = argv[++i];
    else if (arg === '--source-url') parsed.sourceUrl = argv[++i];
    else if (arg === '--remote') parsed.remote = argv[++i];
    else if (arg === '--branch') parsed.branch = argv[++i];
    else if (arg === '--channel') parsed.channel = argv[++i];
    else if (arg === '--project-root') parsed.projectRoot = argv[++i];
    else if (arg === '--install-target') parsed.installTargets.push(argv[++i]);
    else if (arg === '--json') parsed.json = true;
    else if (arg === '--apply') parsed.apply = true;
    else if (arg === '--help' || arg === '-h') usage();
    else throw new Error(`unknown argument: ${arg}`);
  }
  return parsed;
}

function resolveSourceContext(parsed, resolvedSkillDir, resolvedManifestPath, manifest) {
  if (parsed.sourceDir) {
    const repo = path.resolve(parsed.sourceDir);
    return {
      sourceMode: 'source_dir',
      sourceDir: repo,
      skillDir: resolvedSkillDir,
      manifestPath: resolvedManifestPath,
      updateSourceUrl: '',
      branch: parsed.branch || 'main',
      currentCommit: '',
      bundleName: manifest.bundleName || 'novel-assistant',
      bundleId: manifest.bundleId || '',
    };
  }

  if (isGitRepo(process.cwd())) {
    const repo = path.resolve(process.cwd());
    return {
      sourceMode: 'cwd_git_repo',
      sourceDir: repo,
      skillDir: resolvedSkillDir,
      manifestPath: resolvedManifestPath,
      updateSourceUrl: '',
      branch: parsed.branch || 'main',
      currentCommit: '',
      bundleName: manifest.bundleName || 'novel-assistant',
      bundleId: manifest.bundleId || '',
    };
  }

  const updateSourceUrl = parsed.sourceUrl || manifest.updateSourceUrl || manifest.sourceUrl || '';
  const updateSourceBranch = parsed.branch || manifest.updateSourceBranch || manifest.sourceBranch || 'main';
  if (!updateSourceUrl) {
    return {
      sourceMode: 'missing_source',
      sourceDir: path.resolve(process.cwd()),
      skillDir: resolvedSkillDir,
      manifestPath: resolvedManifestPath,
      updateSourceUrl: '',
      branch: updateSourceBranch,
      currentCommit: '',
      bundleName: manifest.bundleName || 'novel-assistant',
      bundleId: manifest.bundleId || '',
    };
  }

  const cloneDir = fs.mkdtempSync(path.join(os.tmpdir(), 'novel-assistant-update-src-'));
  run('git', ['clone', '--quiet', updateSourceUrl, cloneDir]);
  if (updateSourceBranch) {
    git(cloneDir, ['checkout', '--quiet', updateSourceBranch], { allowFailure: true });
  }
  return {
    sourceMode: 'installed_manifest',
    sourceDir: cloneDir,
    skillDir: resolvedSkillDir,
    manifestPath: resolvedManifestPath,
    updateSourceUrl,
    branch: updateSourceBranch,
    currentCommit: manifest.sourceCommit || '',
    bundleName: manifest.bundleName || 'novel-assistant',
    bundleId: manifest.bundleId || '',
  };
}

function isGitRepo(dir) {
  if (!fs.existsSync(dir)) return false;
  return run('git', ['-C', dir, 'rev-parse', '--git-dir'], { allowFailure: true }).status === 0;
}

function expandHome(value) {
  if (value === '~') return os.homedir();
  if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}

function usage() {
  process.stdout.write(`Usage: node scripts/novel-assistant-self-update.js [options]

Options:
  --source-dir <dir>       novel-assistant source repository. Default: cwd
  --source-url <url>       self-managed update source. Default: manifest updateSourceUrl
  --skill-dir <dir>        installed novel-assistant skill directory. Default: script parent
  --manifest <file>        installed manifest. Default: <skill-dir>/novel-assistant-manifest.json
  --remote <name>          Git remote to check. Default: origin
  --branch <name>          Remote branch to check. Default: main
  --project-root <dir>     Also check whether this book project needs setup refresh
  --json                   Print JSON
  --apply                  Apply selected update after confirmation by caller
  --channel <stable|development>
  --install-target <dir>   Repeatable install target. Default: Claude and Codex novel-assistant

Default mode only checks. It never pulls, merges, installs, or refreshes a book project.
`);
  process.exit(0);
}

function emit(result) {
  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  const lines = [
    `状态：${result.status}`,
    `当前：${result.currentCommit || 'unknown'}`,
    `稳定版：${result.latestStableTag || '无'}`,
    `开发版：${result.latestDevelopmentCommit || 'unknown'}`,
    result.recommendation || result.message || '',
  ].filter(Boolean);
  if (result.projectRecommendation) lines.push(result.projectRecommendation);
  process.stdout.write(`${lines.join('\n')}\n`);
}

function emitAndExit(result, code) {
  emit(result);
  process.exit(code);
}
