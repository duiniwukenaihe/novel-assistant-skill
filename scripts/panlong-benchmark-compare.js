#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node scripts/panlong-benchmark-compare.js [options]

Compares a Panlong deconstruction candidate against demo/拆文库-盘龙.

Options:
  --repo-root <dir>       Repository root, default cwd
  --candidate <dir>       Candidate deconstruction directory
  --json                  Print JSON
  --help                  Show help
`;

function parseArgs(argv) {
  const out = { repoRoot: process.cwd(), candidate: '', json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--repo-root') {
      out.repoRoot = path.resolve(argv[++i] || '');
    } else if (arg === '--candidate') {
      out.candidate = path.resolve(argv[++i] || '');
    } else if (arg === '--json') {
      out.json = true;
    } else if (arg === '--help' || arg === '-h') {
      process.stdout.write(USAGE);
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return out;
}

function exists(file) {
  return fs.existsSync(file);
}

function listFiles(dir, predicate = () => true) {
  if (!exists(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .filter(predicate)
    .sort((a, b) => a.localeCompare(b, 'zh-Hans-CN', { numeric: true }));
}

function summarize(root) {
  const chapters = listFiles(path.join(root, '章节'), (name) => /^第\d+章_摘要\.md$/.test(name));
  const deep = listFiles(path.join(root, '章节'), (name) => /^第[123]章_深度拆解\.md$/.test(name));
  const roleFiles = listFiles(path.join(root, '角色'), (name) => name.endsWith('.md'));
  const required = [
    { rel: '快速预览.md' },
    { rel: '拆文报告.md' },
    { rel: '文风.md' },
    { rel: '概要.md' },
    { rel: '剧情/故事线.md' },
    { rel: '角色/角色关系.md' },
    {
      rel: '设定/世界观/力量体系.md',
      alternatives: ['设定/世界观/能力与规则.md']
    },
    { rel: '设定/世界观/背景设定.md' },
    { rel: '设定/世界观/金手指.md' }
  ];
  const groups = {
    characters: roleFiles.length,
    plots: listFiles(path.join(root, '剧情'), (name) => name.endsWith('.md')).length,
    settings: countMarkdown(path.join(root, '设定'))
  };
  return {
    root,
    exists: exists(root),
    chapterSummaryCount: chapters.length,
    chapterSummaries: chapters,
    goldenThreeCount: deep.length,
    goldenThree: deep,
    roleFiles,
    requiredArtifacts: required.map((artifact) => {
      const candidates = [artifact.rel, ...(artifact.alternatives || [])];
      const matched = candidates.find((rel) => exists(path.join(root, rel))) || '';
      return {
        rel: artifact.rel,
        exists: Boolean(matched),
        matched,
        alternatives: artifact.alternatives || []
      };
    }),
    groups
  };
}

function countMarkdown(dir) {
  if (!exists(dir)) return 0;
  let count = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) count += countMarkdown(full);
    if (entry.isFile() && entry.name.endsWith('.md')) count += 1;
  }
  return count;
}

function compare(base, candidate) {
  const findings = [];
  if (!candidate.exists) findings.push({ id: 'candidate_missing', severity: 'S1' });
  if (candidate.chapterSummaryCount < base.chapterSummaryCount) {
    findings.push({
      id: 'missing_chapter_summaries',
      severity: 'S1',
      expected: base.chapterSummaryCount,
      actual: candidate.chapterSummaryCount
    });
  }
  if (candidate.goldenThreeCount < 3) {
    findings.push({ id: 'missing_golden_three', severity: 'S2', actual: candidate.goldenThreeCount });
  }
  for (const artifact of candidate.requiredArtifacts) {
    if (!artifact.exists) findings.push({ id: 'missing_artifact', severity: 'S2', rel: artifact.rel });
  }
  if (candidate.groups.characters < Math.min(base.groups.characters, 4)) {
    findings.push({ id: 'weak_character_artifacts', severity: 'S3', actual: candidate.groups.characters });
  }
  if (candidate.groups.plots < Math.min(base.groups.plots, 3)) {
    findings.push({ id: 'weak_plot_artifacts', severity: 'S3', actual: candidate.groups.plots });
  }
  if (candidate.groups.settings < Math.min(base.groups.settings, 3)) {
    findings.push({ id: 'weak_setting_artifacts', severity: 'S3', actual: candidate.groups.settings });
  }
  for (const role of missingCriticalPanlongRoles(candidate.roleFiles || [])) {
    findings.push({ id: 'missing_critical_role_file', severity: 'S2', role });
  }
  return findings;
}

function missingCriticalPanlongRoles(roleFiles) {
  const critical = [
    ['林雷', '林雷·巴鲁克'],
    ['霍格', '霍格·巴鲁克'],
    ['沃顿', '沃顿·巴鲁克'],
    ['希尔曼'],
    ['希里'],
    ['德林柯沃特']
  ];
  return critical
    .filter((aliases) => !aliases.some((alias) => roleFiles.some((file) => file === `${alias}.md`)))
    .map((aliases) => aliases[0]);
}

function printMarkdown(result) {
  console.log('# Panlong Benchmark Comparison');
  console.log('');
  console.log(`Baseline: ${result.baseline.root}`);
  console.log(`Candidate: ${result.candidate.root || '(not provided)'}`);
  console.log(`Status: ${result.status}`);
  console.log('');
  console.log('| Dimension | Baseline | Candidate |');
  console.log('|---|---:|---:|');
  console.log(`| Chapter summaries | ${result.baseline.chapterSummaryCount} | ${result.candidate.chapterSummaryCount} |`);
  console.log(`| Golden three | ${result.baseline.goldenThreeCount} | ${result.candidate.goldenThreeCount} |`);
  console.log(`| Characters | ${result.baseline.groups.characters} | ${result.candidate.groups.characters} |`);
  console.log(`| Plot artifacts | ${result.baseline.groups.plots} | ${result.candidate.groups.plots} |`);
  console.log(`| Setting artifacts | ${result.baseline.groups.settings} | ${result.candidate.groups.settings} |`);
  console.log('');
  if (result.findings.length) {
    console.log('## Findings');
    for (const finding of result.findings) console.log(`- ${finding.severity}: ${finding.id}`);
  } else {
    console.log('No structural regressions found.');
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const baseline = summarize(path.join(args.repoRoot, 'demo', '拆文库-盘龙'));
  const candidate = summarize(args.candidate || '');
  const findings = compare(baseline, candidate);
  const result = {
    schemaVersion: '1.0.0',
    status: findings.length ? 'fail' : 'pass',
    baseline,
    candidate,
    findings
  };
  if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    printMarkdown(result);
  }
  process.exit(findings.length ? 1 : 0);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
