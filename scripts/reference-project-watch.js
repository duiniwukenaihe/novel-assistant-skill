#!/usr/bin/env node
/**
 * reference-project-watch.js
 *
 * Low-frequency watch report for inspiration/reference projects.
 * This is intentionally separate from check-upstream.sh:
 * - primary upstream backports remain under reports/upstream/
 * - reference projects are design inputs only and write reports/research/
 * - this script never merges, cherry-picks, fetches into local refs, or edits code
 */

const cp = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const args = parseArgs(process.argv.slice(2));
const repoRoot = findRepoRoot();
const registryPath = path.resolve(repoRoot, args.registry || 'docs/reference-projects.json');
const reportDir = path.resolve(repoRoot, args.reportDir || 'reports/research');

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});

async function main() {
  const registry = readJson(registryPath);
  validateRegistry(registry);
  const projects = registry.projects.map((project) => inspectProject(project));
  const distributionMirrorsChecked = args.includeDistributionMirrors === true;
  const skillSources = distributionMirrorsChecked
    ? await Promise.all((registry.skillSources || []).map((source) => inspectSkillSource(source)))
    : [];
  const knowledgeSources = normalizeSources(registry.knowledgeSources || []);
  const dataSources = normalizeSources(registry.dataSources || []);
  const excludedSources = normalizeSources(registry.excludedSources || []);
  const summary = {
    total: projects.length,
    changed: projects.filter((item) => item.status === 'changed').length,
    current: projects.filter((item) => item.status === 'current').length,
    untracked: projects.filter((item) => item.status === 'untracked').length,
    error: projects.filter((item) => item.status === 'error').length,
    primaryUpstream: registry.policy.primaryUpstream,
  };
  const sourceSummary = {
    distributionMirrorsChecked,
    skillSources: skillSources.length,
    changedSkillSources: skillSources.filter((item) => item.status === 'changed').length,
    skillSourceErrors: skillSources.filter((item) => item.status === 'error').length,
    knowledgeSources: knowledgeSources.length,
    dataSources: dataSources.length,
    excludedSources: excludedSources.length,
  };
  const result = {
    status: 'ok',
    checkedAt: new Date().toISOString(),
    registryPath,
    policy: registry.policy,
    summary,
    sourceSummary,
    projects,
    skillSources,
    knowledgeSources,
    dataSources,
    excludedSources,
  };

  if (args.write) {
    fs.mkdirSync(reportDir, { recursive: true });
    const reportPath = path.join(reportDir, `${timestamp()}-reference-project-watch.md`);
    fs.writeFileSync(reportPath, renderMarkdown(result), 'utf8');
    result.reportPath = reportPath;
  }

  if (args.json) {
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  } else {
    process.stdout.write(renderText(result));
  }
}

async function inspectSkillSource(source) {
  const base = {
    id: source.id,
    name: source.name,
    slug: source.slug,
    publisher: source.publisher || '',
    canonicalName: source.canonicalName || '',
    catalogUrl: source.catalogUrl || '',
    versionsApi: source.versionsApi || '',
    skillFileApi: source.skillFileApi || '',
    priority: source.priority || 'reference-low',
    cadenceDays: Number(source.cadenceDays || 90),
    license: source.license || 'unknown-check-before-use',
    absorbMode: source.absorbMode || 'clean-room-design-only',
    focusAreas: Array.isArray(source.focusAreas) ? source.focusAreas : [],
    sourceRepo: source.sourceRepo || '',
    sourceRepoId: source.sourceRepoId || '',
    sourceRepoVerified: source.sourceRepoVerified === true,
    sourceRepoCommit: source.sourceRepoCommit || '',
    artifactRelation: source.artifactRelation || 'unknown',
    lastObservedVersion: source.lastObservedVersion || '',
    lastReviewedVersion: source.lastReviewedVersion || '',
    lastObservedArtifactSha256: source.lastObservedArtifactSha256 || '',
    lastReviewedArtifactSha256: source.lastReviewedArtifactSha256 || '',
    notes: source.notes || '',
  };
  try {
    if (!base.versionsApi) throw new Error(`skill source has no versionsApi: ${base.id}`);
    const versionPayload = await fetchJson(expandSkillUrl(base.versionsApi, base));
    const versions = Array.isArray(versionPayload.versions) ? versionPayload.versions : [];
    const latestVersion = versions
      .map((item) => String(item && item.version || '').trim())
      .filter(Boolean)
      .sort(compareVersionStrings)
      .at(-1) || '';
    if (!latestVersion) throw new Error(`no versions returned for skill source: ${base.id}`);

    let artifactSha256 = '';
    let declaredVersion = '';
    if (base.skillFileApi) {
      const artifact = await fetchText(expandSkillUrl(base.skillFileApi, { ...base, version: latestVersion }));
      artifactSha256 = crypto.createHash('sha256').update(artifact).digest('hex');
      declaredVersion = parseDeclaredSkillVersion(artifact);
    }

    const versionBaseline = base.lastReviewedVersion || base.lastObservedVersion;
    const artifactBaseline = base.lastReviewedArtifactSha256 || base.lastObservedArtifactSha256;
    const versionStatus = versionBaseline ? (versionBaseline === latestVersion ? 'current' : 'changed') : 'untracked';
    const artifactStatus = artifactSha256
      ? (artifactBaseline ? (artifactBaseline === artifactSha256 ? 'current' : 'changed') : 'untracked')
      : 'not_checked';
    const warnings = [];
    if (declaredVersion && declaredVersion !== latestVersion) warnings.push('catalog_version_differs_from_artifact');
    if (versionStatus === 'current' && artifactStatus === 'changed') warnings.push('immutable_version_artifact_changed');
    if (!base.sourceRepoVerified) warnings.push('source_repo_unverified');
    const trustStatus = warnings.includes('catalog_version_differs_from_artifact')
      || warnings.includes('immutable_version_artifact_changed')
      ? 'quarantined'
      : (base.sourceRepoVerified ? 'source_repo_verified' : 'unverified');
    const status = versionStatus === 'changed' || artifactStatus === 'changed'
      ? 'changed'
      : (versionStatus === 'untracked' || artifactStatus === 'untracked' ? 'untracked' : 'current');
    return {
      ...base,
      latestVersion,
      declaredVersion,
      artifactSha256,
      versionStatus,
      artifactStatus,
      warnings,
      trustStatus,
      status,
      recommendedAction: skillSourceRecommendedAction({ ...base, status, warnings, trustStatus }),
    };
  } catch (error) {
    return {
      ...base,
      latestVersion: '',
      declaredVersion: '',
      artifactSha256: '',
      versionStatus: 'error',
      artifactStatus: 'error',
      warnings: [],
      trustStatus: 'unverified',
      status: 'error',
      error: error.message,
      recommendedAction: 'retry_later_or_verify_distribution_source',
    };
  }
}

function expandSkillUrl(template, source) {
  return String(template || '')
    .replaceAll('{slug}', encodeURIComponent(source.slug || ''))
    .replaceAll('{version}', encodeURIComponent(source.version || ''));
}

async function fetchJson(url) {
  return JSON.parse(await fetchText(url));
}

async function fetchText(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), Number(args.timeoutMs || 20000));
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${url}`);
    return await response.text();
  } finally {
    clearTimeout(timeout);
  }
}

function parseDeclaredSkillVersion(contents) {
  const frontmatter = String(contents || '').match(/^---\s*\n([\s\S]*?)\n---/);
  if (!frontmatter) return '';
  const version = frontmatter[1].match(/^version:\s*["']?([^\s"']+)/m);
  return version ? version[1].trim() : '';
}

function compareVersionStrings(left, right) {
  const parsedLeft = parseSemver(left);
  const parsedRight = parseSemver(right);
  if (parsedLeft && parsedRight) {
    for (const key of ['major', 'minor', 'patch']) {
      if (parsedLeft[key] !== parsedRight[key]) return parsedLeft[key] - parsedRight[key];
    }
    return parsedLeft.suffix.localeCompare(parsedRight.suffix, undefined, { numeric: true, sensitivity: 'base' });
  }
  if (parsedLeft) return 1;
  if (parsedRight) return -1;
  return String(left).localeCompare(String(right), undefined, { numeric: true, sensitivity: 'base' });
}

function skillSourceRecommendedAction(source) {
  if (source.status === 'error') return 'retry_later_or_verify_distribution_source';
  if (source.trustStatus === 'quarantined') return 'quarantine_distribution_use_verified_source_repo_only';
  if (source.status === 'untracked') return 'record_version_and_artifact_baseline';
  if (source.status === 'changed') return 'distribution_changed_verify_source_repo_then_triage';
  if (source.warnings.includes('catalog_version_differs_from_artifact')) return 'verify_distribution_metadata_before_absorption';
  if (source.warnings.includes('source_repo_unverified')) return 'observe_only_until_source_repo_verified';
  return 'no_action';
}

function normalizeSources(sources) {
  return sources.map((source) => ({
    id: source.id,
    name: source.name,
    type: source.type || 'manual',
    source: source.source || '',
    watchMode: source.watchMode || 'manual',
    priority: source.priority || 'reference-low',
    focusAreas: Array.isArray(source.focusAreas) ? source.focusAreas : [],
    absorbMode: source.absorbMode || 'design-only',
    notes: source.notes || '',
    reason: source.reason || '',
  }));
}

function inspectProject(project) {
  const base = {
    id: project.id,
    name: project.name,
    repo: project.repo,
    branch: project.branch || 'main',
    priority: project.priority || 'reference-low',
    cadenceDays: Number(project.cadenceDays || 90),
    license: project.license || 'unknown-check-before-use',
    absorbMode: project.absorbMode || 'clean-room-design-only',
    focusAreas: Array.isArray(project.focusAreas) ? project.focusAreas : [],
    lastReviewedCommit: project.lastReviewedCommit || '',
    lastObservedCommit: project.lastObservedCommit || '',
    lastReviewedTag: project.lastReviewedTag || '',
    lastObservedTag: project.lastObservedTag || '',
    lastReviewedTagSha: project.lastReviewedTagSha || '',
    lastObservedTagSha: project.lastObservedTagSha || '',
  };
  try {
    const remote = lsRemoteHead(base.repo, base.branch);
    const latestTag = lsRemoteLatestTag(base.repo, project.tagPattern);
    const head = remote.head;
    const baseline = base.lastReviewedCommit || base.lastObservedCommit;
    const headStatus = baseline
      ? (head === baseline ? 'current' : 'changed')
      : 'untracked';
    const tagBaseline = base.lastReviewedTag || base.lastObservedTag;
    const tagShaBaseline = base.lastReviewedTagSha || base.lastObservedTagSha;
    const tagStatus = latestTag.name
      ? (tagBaseline ? (latestTag.name === tagBaseline && (!tagShaBaseline || latestTag.sha === tagShaBaseline) ? 'current' : 'changed') : 'untracked')
      : 'none';
    const status = headStatus === 'changed' || tagStatus === 'changed'
      ? 'changed'
      : (headStatus === 'untracked' && tagStatus === 'untracked' ? 'untracked' : 'current');
    return {
      ...base,
      head,
      headStatus,
      latestTag: latestTag.name,
      latestTagSha: latestTag.sha,
      tagStatus,
      branchResolvedFromHead: remote.branchResolvedFromHead,
      status,
      recommendedAction: recommendedAction({ ...base, status, headStatus, tagStatus, latestTag: latestTag.name }),
    };
  } catch (error) {
    return {
      ...base,
      head: '',
      status: 'error',
      error: error.message,
      recommendedAction: 'retry_later_or_verify_repo',
    };
  }
}

function lsRemoteHead(repo, branch) {
  const result = cp.spawnSync('git', ['ls-remote', repo, `refs/heads/${branch}`], {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: Number(args.timeoutMs || 20000),
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error((result.stderr || result.stdout || `git ls-remote failed: ${repo}`).trim());
  const line = String(result.stdout || '').trim().split(/\r?\n/).find(Boolean);
  if (line) return { head: line.split(/\s+/)[0], branchResolvedFromHead: false };

  const fallback = cp.spawnSync('git', ['ls-remote', repo, 'HEAD'], {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: Number(args.timeoutMs || 20000),
    maxBuffer: 2 * 1024 * 1024,
  });
  if (fallback.error) throw fallback.error;
  if (fallback.status !== 0) throw new Error((fallback.stderr || fallback.stdout || `git ls-remote HEAD failed: ${repo}`).trim());
  const fallbackLine = String(fallback.stdout || '').trim().split(/\r?\n/).find(Boolean);
  if (!fallbackLine) throw new Error(`branch not found and HEAD unavailable: ${branch}`);
  return { head: fallbackLine.split(/\s+/)[0], branchResolvedFromHead: true };
}

function lsRemoteLatestTag(repo, tagPattern) {
  const result = cp.spawnSync('git', ['ls-remote', '--tags', '--refs', repo], {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: Number(args.timeoutMs || 20000),
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) return { name: '', sha: '' };
  const pattern = tagPattern ? new RegExp(tagPattern) : null;
  const tags = String(result.stdout || '')
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => {
      const [sha, ref] = line.split(/\s+/);
      const name = String(ref || '').replace(/^refs\/tags\//, '');
      return { sha, name };
    })
    .filter((tag) => tag.name && (!pattern || pattern.test(tag.name)));
  if (!tags.length) return { name: '', sha: '' };
  tags.sort(compareTags);
  return tags[tags.length - 1];
}

function compareTags(a, b) {
  const parsedA = parseSemver(a.name);
  const parsedB = parseSemver(b.name);
  if (parsedA && parsedB) {
    for (const key of ['major', 'minor', 'patch']) {
      if (parsedA[key] !== parsedB[key]) return parsedA[key] - parsedB[key];
    }
    return parsedA.suffix.localeCompare(parsedB.suffix, undefined, { numeric: true, sensitivity: 'base' });
  }
  if (parsedA) return 1;
  if (parsedB) return -1;
  return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });
}

function parseSemver(value) {
  const match = String(value || '').match(/^v?(\d+)\.(\d+)\.(\d+)(.*)$/);
  if (!match) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    suffix: match[4] || '',
  };
}

function recommendedAction(project) {
  if (project.status === 'current') return 'no_action';
  if (project.status === 'untracked') return 'record_baseline_then_research';
  if (project.status === 'error') return 'retry_later_or_verify_repo';
  if (project.latestTag && project.tagStatus === 'current' && project.headStatus === 'changed') {
    return 'light_commit_log_only_until_tag_changes';
  }
  if (project.latestTag && project.tagStatus === 'changed') {
    return 'tag_changed_research_report_then_triage';
  }
  if (/GPL|AGPL|unknown/i.test(project.license) || /clean-room|design|ideas|prompt|discovery/i.test(project.absorbMode)) {
    return 'research_report_then_clean_room_triage';
  }
  return 'triage_for_possible_backport';
}

function renderMarkdown(result) {
  const lines = [];
  lines.push('# 参考项目观察报告');
  lines.push('');
  lines.push(`- Checked at: \`${result.checkedAt}\``);
  lines.push(`- Registry: \`${relative(result.registryPath)}\``);
  lines.push(`- 主上游仍优先: \`${result.summary.primaryUpstream}\``);
  lines.push(`- 主上游命令: \`${result.policy.primaryCommand || 'node scripts/na-dev.js upstream --write'}\``);
  lines.push(`- 参考项目命令: \`${result.policy.referenceCommand || 'node scripts/na-dev.js reference-watch --write'}\``);
  lines.push('');
  lines.push('## Summary');
  lines.push('');
  lines.push(`- total: ${result.summary.total}`);
  lines.push(`- changed: ${result.summary.changed}`);
  lines.push(`- current: ${result.summary.current}`);
  lines.push(`- untracked: ${result.summary.untracked}`);
  lines.push(`- error: ${result.summary.error}`);
  if (result.sourceSummary.distributionMirrorsChecked) {
    lines.push(`- secondary distribution mirrors: ${result.sourceSummary.skillSources}`);
    lines.push(`- changed distribution mirrors: ${result.sourceSummary.changedSkillSources}`);
    lines.push(`- distribution mirror errors: ${result.sourceSummary.skillSourceErrors}`);
  }
  lines.push(`- manual knowledge sources: ${result.sourceSummary.knowledgeSources}`);
  lines.push(`- data sources: ${result.sourceSummary.dataSources}`);
  lines.push(`- excluded/special sources: ${result.sourceSummary.excludedSources}`);
  lines.push('');
  lines.push('## Policy');
  lines.push('');
  lines.push('- `worldwonderer/oh-story-claudecode` 是主上游，仍按 `reports/upstream/` 和上游反哺 SOP 高频跟踪。');
  lines.push('- 本报告覆盖参考 GitHub 项目、手工知识来源、数据来源和排除/特殊来源，输出到 `reports/research/`，用于低频观察和设计候选。');
  lines.push('- 参考项目默认不 merge、不 cherry-pick、不复制代码；GPL/AGPL/未知许可项目只做 clean-room 设计吸收。');
  lines.push('');
  lines.push('## Projects');
  lines.push('');
  lines.push('| Status | Project | Branch | Head | Head status | Latest tag | Tag status | Last reviewed | Last observed | Priority | License | Absorb mode | Recommended action | Focus |');
  lines.push('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (const project of result.projects) {
    lines.push(markdownRow([
      `\`${project.status}\``,
      markdownCell(project.name),
      `\`${project.branch}\``,
      `\`${shortSha(project.head)}\``,
      `\`${project.headStatus || '-'}\``,
      markdownCell(project.latestTag || '-'),
      `\`${project.tagStatus || '-'}\``,
      `\`${shortSha(project.lastReviewedCommit)}\``,
      `\`${shortSha(project.lastObservedCommit)}\``,
      `\`${project.priority}\``,
      `\`${project.license}\``,
      `\`${project.absorbMode}\``,
      `\`${project.recommendedAction}\``,
      markdownCell(project.focusAreas.join(', ')),
    ]));
  }
  if (result.skillSources.length) {
    lines.push('');
    lines.push('## Secondary Distribution Mirror Diagnostics');
    lines.push('');
    lines.push('| Status | Trust | Skill | Catalog version | Declared version | Artifact | Version status | Artifact status | Source repo | Relation | Warning | Action | Focus |');
    lines.push('|---|---|---|---|---|---|---|---|---|---|---|---|---|');
    for (const source of result.skillSources) {
      lines.push(markdownRow([
        `\`${source.status}\``,
        `\`${source.trustStatus}\``,
        markdownCell(source.canonicalName || source.name),
        `\`${source.latestVersion || '-'}\``,
        `\`${source.declaredVersion || '-'}\``,
        `\`${shortSha(source.artifactSha256)}\``,
        `\`${source.versionStatus}\``,
        `\`${source.artifactStatus}\``,
        markdownCell(source.sourceRepoVerified ? source.sourceRepo : `${source.sourceRepo || '-'} (unverified)`),
        `\`${source.artifactRelation}\``,
        markdownCell(source.warnings.join(', ') || '-'),
        `\`${source.recommendedAction}\``,
        markdownCell(source.focusAreas.join(', ')),
      ]));
    }
  }
  if (result.knowledgeSources.length) {
    renderSourceTable(lines, 'Manual Knowledge Sources', result.knowledgeSources);
  }
  if (result.dataSources.length) {
    renderSourceTable(lines, 'Data Sources', result.dataSources);
  }
  if (result.excludedSources.length) {
    renderSourceTable(lines, 'Excluded / Special Sources', result.excludedSources);
  }
  lines.push('');
  lines.push('## 下一步');
  lines.push('');
  lines.push('1. 对 `changed` 且 priority 为 `reference-high` 的项目，先写 `reports/research/<date>-<project>-absorption.md`。');
  lines.push('2. 如果 `recommendedAction=light_commit_log_only_until_tag_changes`，只读提交摘要和 README 级变更，不 clone 深读、不做大规模吸收，等 tag/release 变化后再 deep triage。');
  lines.push('3. 报告必须写清：可吸收设计、拒绝项、许可边界、与 `novel-assistant` 的映射、是否需要测试。');
  lines.push('4. 对 `knowledgeSources` 只做手工摘要和设计转译；对 `dataSources` 走对应专项脚本，不用 git HEAD 判断数据有效性。');
  lines.push('5. 只有通过 clean-room 设计评审后，才进入本项目脚本/skill 实现；仍不得复制参考项目源码或长段 prompt。');
  lines.push('6. 主上游更新不走本报告，继续用 `node scripts/na-dev.js upstream --write`。');
  lines.push('');
  return lines.join('\n');
}

function renderSourceTable(lines, title, sources) {
  lines.push('');
  lines.push(`## ${title}`);
  lines.push('');
  lines.push('| Source | Type | Watch mode | Priority | Absorb mode | Focus | Notes / Reason |');
  lines.push('|---|---|---|---|---|---|---|');
  for (const source of sources) {
    lines.push(markdownRow([
      markdownCell(source.name),
      `\`${source.type}\``,
      `\`${source.watchMode}\``,
      `\`${source.priority}\``,
      `\`${source.absorbMode}\``,
      markdownCell(source.focusAreas.join(', ')),
      markdownCell([source.source, source.notes, source.reason].filter(Boolean).join(' / ')),
    ]));
  }
}

function markdownRow(cells) {
  return `| ${cells.join(' | ')} |`;
}

function renderText(result) {
  return [
    `reference project watch: ${result.summary.changed} changed, ${result.summary.error} error, ${result.summary.total} repo projects`,
    ...(result.sourceSummary.distributionMirrorsChecked
      ? [`secondary distribution mirrors: ${result.sourceSummary.skillSources} total, ${result.sourceSummary.changedSkillSources} changed, ${result.sourceSummary.skillSourceErrors} error`]
      : []),
    `manual sources: ${result.sourceSummary.knowledgeSources} knowledge, ${result.sourceSummary.dataSources} data, ${result.sourceSummary.excludedSources} excluded/special`,
    `primary upstream remains: ${result.summary.primaryUpstream}`,
    '',
  ].join('\n');
}

function markdownCell(value) {
  return String(value || '').replace(/\|/g, '\\|');
}

function shortSha(value) {
  const text = String(value || '').trim();
  return text ? text.slice(0, 12) : '-';
}

function relative(file) {
  return path.relative(repoRoot, file) || '.';
}

function timestamp() {
  const date = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  return [
    date.getUTCFullYear(),
    pad(date.getUTCMonth() + 1),
    pad(date.getUTCDate()),
    '-',
    pad(date.getUTCHours()),
    pad(date.getUTCMinutes()),
    pad(date.getUTCSeconds()),
  ].join('');
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function validateRegistry(registry) {
  if (!registry || typeof registry !== 'object') throw new Error('registry must be an object');
  if (!registry.policy || typeof registry.policy !== 'object') throw new Error('registry.policy is required');
  if (!registry.policy.primaryUpstream) throw new Error('registry.policy.primaryUpstream is required');
  if (!Array.isArray(registry.projects)) throw new Error('registry.projects must be an array');
  for (const project of registry.projects) {
    for (const key of ['id', 'name', 'repo']) {
      if (!project[key]) throw new Error(`project.${key} is required`);
    }
  }
  for (const arrayKey of ['skillSources', 'knowledgeSources', 'dataSources', 'excludedSources']) {
    if (registry[arrayKey] !== undefined && !Array.isArray(registry[arrayKey])) {
      throw new Error(`registry.${arrayKey} must be an array`);
    }
    for (const source of registry[arrayKey] || []) {
      for (const key of ['id', 'name']) {
        if (!source[key]) throw new Error(`${arrayKey}.${key} is required`);
      }
      if (arrayKey === 'skillSources') {
        for (const key of ['slug', 'versionsApi']) {
          if (!source[key]) throw new Error(`${arrayKey}.${key} is required`);
        }
      }
    }
  }
}

function findRepoRoot() {
  const result = cp.spawnSync('git', ['rev-parse', '--show-toplevel'], {
    cwd: process.cwd(),
    encoding: 'utf8',
  });
  if (result.status === 0 && result.stdout.trim()) return result.stdout.trim();
  return path.resolve(__dirname, '..');
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--registry') parsed.registry = requireValue(argv, ++index, arg);
    else if (arg === '--report-dir') parsed.reportDir = requireValue(argv, ++index, arg);
    else if (arg === '--timeout-ms') parsed.timeoutMs = requireValue(argv, ++index, arg);
    else if (arg === '--include-distribution-mirrors') parsed.includeDistributionMirrors = true;
    else if (arg === '--write') parsed.write = true;
    else if (arg === '--json') parsed.json = true;
    else if (arg === '-h' || arg === '--help') usage();
    else throw new Error(`unknown argument: ${arg}`);
  }
  return parsed;
}

function requireValue(argv, index, flag) {
  if (index >= argv.length || !argv[index]) throw new Error(`${flag} requires a value`);
  return argv[index];
}

function usage() {
  process.stdout.write(`Usage: node scripts/reference-project-watch.js [options]

Options:
  --registry <file>     Registry JSON. Default: docs/reference-projects.json
  --write               Write markdown report to reports/research/
  --report-dir <dir>    Report directory. Default: reports/research
  --json                Print JSON result
  --timeout-ms <n>      git ls-remote timeout. Default: 20000
  --include-distribution-mirrors
                        Also diagnose secondary directory mirrors. GitHub remains authoritative.

This is for low-frequency reference project watching. It does not replace
scripts/check-upstream.sh and never merges/cherry-picks code.
`);
  process.exit(0);
}
