#!/usr/bin/env node
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const PUBLIC_REPO_URL = 'https://github.com/duiniwukenaihe/novel-assistant-skill.git';

function parseArgs(argv) {
  const out = { repoRoot: process.cwd(), json: false, checkUpgradeGuide: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--repo-root') {
      out.repoRoot = path.resolve(argv[++i] || '');
    } else if (arg === '--json') {
      out.json = true;
    } else if (arg === '--check-upgrade-guide') {
      out.checkUpgradeGuide = true;
    } else if (arg === '--help' || arg === '-h') {
      process.stdout.write('Usage: node scripts/public-release-audit.js [--repo-root <dir>] [--check-upgrade-guide] [--json]\n');
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return out;
}

function auditUpgradeGuide(repoRoot) {
  const guide = path.join(repoRoot, 'src', 'internal-skills', 'story-setup', 'UPGRADING.md');
  if (!fs.existsSync(guide) || !fs.statSync(guide).isFile()) {
    return [{ id: 'missing_upgrade_guide', file: 'src/internal-skills/story-setup/UPGRADING.md', severity: 'S1' }];
  }
  const text = readText(guide);
  const topics = [
    '升级策略',
    '文件分类',
    '版本检测',
    '版本变更',
  ];
  return topics
    .filter(topic => !new RegExp(`^##\\s+${topic}(?:\\s|$)`, 'm').test(text))
    .map(topic => ({
      id: 'missing_upgrade_guide_topic',
      file: 'src/internal-skills/story-setup/UPGRADING.md',
      severity: 'S2',
      topic,
    }));
}

function git(repoRoot, args) {
  const result = spawnSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    shell: false
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || `git ${args.join(' ')} failed`).trim());
  }
  return result.stdout;
}

function trackedFiles(repoRoot) {
  return git(repoRoot, ['ls-files', '--cached', '--others', '--exclude-standard', '-z'])
    .split('\0')
    .filter(Boolean)
    .filter((rel) => fs.existsSync(path.join(repoRoot, rel)));
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

function isTextLike(rel) {
  return /\.(md|txt|json|jsonl|js|mjs|cjs|ts|tsx|jsx|sh|bats|yml|yaml|toml|lock|html|css)$/i.test(rel)
    || rel === 'README.md'
    || rel === 'README_EN.md'
    || rel === '.gitignore';
}

function hasForbiddenAsset(rel) {
  const normalized = rel.replace(/\\/g, '/');
  if (normalized.startsWith('.superpowers/')) return 'private_superpowers_planning_doc';
  if (normalized.startsWith('docs/superpowers/')) return 'private_superpowers_planning_doc';
  if (normalized.startsWith('src/private-internal-skills/')) return 'private_internal_skill_asset';
  if (normalized.startsWith('skills/novel-assistant/references/private-internal-skills/')) return 'private_internal_skill_asset';
  if (/^demo\/.*\.txt$/i.test(normalized)) return 'demo_text_asset';
  if (/^demo\/.*\/正文\//.test(normalized)) return 'personal_demo_chapter';
  if (/^demo\/.*\/原文\/原文\.txt$/.test(normalized)) return 'raw_source_text';
  if (/^benchmarks\/.*\/原文\/原文\.txt$/.test(normalized)) return 'benchmark_raw_source_text';
  if (/^benchmarks\/.*\/input\/原文\.txt$/.test(normalized)) return 'benchmark_input_source_text';
  if (/^benchmarks\/.*\/claude-run\.jsonl$/.test(normalized)) return 'claude_runtime_log';
  if (/^benchmarks\/.*\/prompt\.txt$/.test(normalized)) return 'benchmark_prompt_with_local_paths';
  if (/^demo\/.*\.(png|jpe?g|webp)$/i.test(normalized)) return 'demo_binary_image_asset';
  return '';
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const repoRoot = args.repoRoot;
  const files = args.checkUpgradeGuide ? [] : trackedFiles(repoRoot);
  const findings = [];

  findings.push(...auditUpgradeGuide(repoRoot));

  if (args.checkUpgradeGuide) {
    return emitResult({ args, files, findings });
  }

  for (const rel of files) {
    const assetReason = hasForbiddenAsset(rel);
    if (assetReason) {
      findings.push({ id: assetReason, file: rel, severity: 'S1' });
    }
  }

  const privateLanPrefix = '192' + '\\.' + '168';
  const privatePasswordExample = ['abc', '1234'].join('@');
  const privateFeatureSkillName = ['story', 'trend', 'forge'].join('-');
  const privateFeatureProjectName = ['Forge', 'Writer'].join(' ');
  const privateFeatureRepoName = ['forge', 'writer'].join('-');
  const privateDownloadSkillName = ['novel', 'download'].join('-');
  const privateDownloadRepoName = ['novel', 'download'].join('-') + '.git';
  const forbiddenText = [
    { id: 'private_lan_git_url', pattern: new RegExp(`git@${privateLanPrefix}\\.\\d+\\.\\d+:[^\\s\`"')]+`) },
    { id: 'private_lan_host', pattern: new RegExp(`${privateLanPrefix}\\.\\d+\\.\\d+`) },
    { id: 'local_user_path', pattern: /\/Users\/zhangpeng/ },
    { id: 'server_workspace_path', pattern: /\/data\/workspace/ },
    { id: 'example_password_leak', pattern: new RegExp(privatePasswordExample.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')) },
    { id: 'private_feature_name_leak', pattern: new RegExp(privateFeatureSkillName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i') },
    { id: 'private_feature_project_leak', pattern: new RegExp(privateFeatureProjectName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i') },
    { id: 'private_feature_repo_leak', pattern: new RegExp(privateFeatureRepoName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i') },
    { id: 'private_feature_name_leak', pattern: new RegExp(privateDownloadSkillName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i') },
    { id: 'private_feature_repo_leak', pattern: new RegExp(privateDownloadRepoName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i') }
  ];

  for (const rel of files.filter(isTextLike)) {
    const text = readText(path.join(repoRoot, rel));
    for (const rule of forbiddenText) {
      if (rule.pattern.test(text)) {
        findings.push({ id: rule.id, file: rel, severity: 'S1' });
      }
    }
  }

  const manifestPath = path.join(repoRoot, 'skills/novel-assistant/novel-assistant-manifest.json');
  if (!fs.existsSync(manifestPath)) {
    findings.push({ id: 'missing_novel_assistant_manifest', file: 'skills/novel-assistant/novel-assistant-manifest.json', severity: 'S1' });
  } else {
    const manifest = JSON.parse(readText(manifestPath));
    if (manifest.updateSourceUrl !== PUBLIC_REPO_URL) {
      findings.push({
        id: 'manifest_update_source_not_public_github',
        file: 'skills/novel-assistant/novel-assistant-manifest.json',
        severity: 'S1',
        expected: PUBLIC_REPO_URL,
        actual: manifest.updateSourceUrl || ''
      });
    }
  }

  return emitResult({ args, files, findings });
}

function emitResult({ args, files, findings }) {
  const result = {
    schemaVersion: '1.0.0',
    status: findings.length ? 'fail' : 'pass',
    publicRepoUrl: PUBLIC_REPO_URL,
    checkedFiles: files.length,
    findings
  };

  if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else if (findings.length) {
    console.error('Public release audit failed:');
    for (const finding of findings) {
      console.error(`- ${finding.severity} ${finding.id}: ${finding.file}`);
    }
  } else {
    console.log(`Public release audit passed (${files.length} tracked files checked).`);
  }

  process.exit(findings.length ? 1 : 0);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
