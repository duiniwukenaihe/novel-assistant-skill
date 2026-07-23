#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');
const { readDirSafe, parseChapterNo } = require('./lib/oh-story-artifacts');

const USAGE = `Usage:
  node scripts/novel-assistant-project-smoke.js <book-project-dir> [--json] [--sample N]
  node scripts/novel-assistant-project-smoke.js --scan-root <dir> [--json] [--sample N]

Runs read-only smoke checks against novel-assistant book projects:
  - domain profile wording
  - progress status and mixed-layout detection
  - sampled prose gate without --write
`;

const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const sampleLimit = Math.max(0, Number(readOption('--sample') || 3));
const scanRoot = readOption('--scan-root');
const explicitProject = args.find(arg => !arg.startsWith('--'));

if (args.includes('-h') || args.includes('--help') || (!scanRoot && !explicitProject)) {
  console.log(USAGE.trimEnd());
  process.exit(scanRoot || explicitProject ? 0 : 1);
}

const roots = scanRoot ? discoverProjects(path.resolve(scanRoot)) : [path.resolve(explicitProject)];
const projects = roots.map(projectRoot => smokeProject(projectRoot, sampleLimit));
const status = aggregateStatus(projects);
const result = {
  schemaVersion: '0.1.0',
  status,
  generatedAt: new Date().toISOString(),
  projectCount: projects.length,
  projects,
};

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  printHuman(result);
}

process.exit(status === 'error' ? 2 : 0);

function readOption(name) {
  const eq = args.find(arg => arg.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const index = args.indexOf(name);
  if (index >= 0) return args[index + 1] || '';
  return '';
}

function discoverProjects(root) {
  const out = [];
  walkDirs(root, 0, 3, dir => {
    if (isBookProject(dir)) out.push(dir);
  });
  return Array.from(new Set(out)).sort((a, b) => a.localeCompare(b, 'zh-Hans-CN'));
}

function walkDirs(dir, depth, maxDepth, visit) {
  if (depth > maxDepth) return;
  visit(dir);
  if (isBookProject(dir) && depth > 0) return;
  for (const name of readDirSafe(dir)) {
    if (name.startsWith('.') && name !== '.book-state.json') continue;
    const abs = path.join(dir, name);
    try {
      if (fs.statSync(abs).isDirectory()) walkDirs(abs, depth + 1, maxDepth, visit);
    } catch {
      // Ignore transient files.
    }
  }
}

function isBookProject(dir) {
  return fs.existsSync(path.join(dir, '.book-state.json'))
    || fs.existsSync(path.join(dir, '正文'))
    || fs.existsSync(path.join(dir, '正文.md'));
}

function smokeProject(projectRoot, limit) {
  const domain = runJsonScript('story-domain-profile.js', [projectRoot]);
  const progress = runJsonScript('story-progress-status.js', [projectRoot]);
  const proseGate = runProseGateSamples(projectRoot, limit);
  const errors = [
    ...domain.errors,
    ...progress.errors,
    ...proseGate.errors,
  ];
  const needsAttention = errors.length > 0
    || progress.json?.status !== 'ok'
    || proseGate.proseIssues > 0;

  return {
    projectRoot,
    projectName: path.basename(projectRoot),
    status: errors.length ? 'error' : (needsAttention ? 'needs_attention' : 'pass'),
    domainProfile: domain.json || null,
    progressStatus: progress.json?.status || 'error',
    progress: progress.json || null,
    proseGate,
    errors,
  };
}

function runJsonScript(scriptName, scriptArgs) {
  const result = runNode(scriptName, [...scriptArgs, '--json']);
  if (!result.stdout.trim()) {
    return { json: null, errors: [`${scriptName}: empty stdout`] };
  }
  try {
    return { json: JSON.parse(result.stdout), errors: result.exitCode === 0 ? [] : [`${scriptName}: exit ${result.exitCode}`] };
  } catch (error) {
    return { json: null, errors: [`${scriptName}: invalid json: ${error.message}`] };
  }
}

function runNode(scriptName, scriptArgs) {
  const script = path.join(__dirname, scriptName);
  const result = childProcess.spawnSync(process.execPath, [script, ...scriptArgs], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 20 * 1024 * 1024,
  });
  return {
    exitCode: Number(result.status || 0),
    stdout: result.stdout || '',
    stderr: result.stderr || '',
  };
}

function runProseGateSamples(projectRoot, limit) {
  const samples = collectDraftSamples(projectRoot, limit);
  const reports = [];
  const errors = [];
  let proseIssues = 0;

  for (const file of samples) {
    const result = runNode('story-prose-gate.js', [file.absPath, '--json']);
    let json = null;
    try {
      json = result.stdout.trim() ? JSON.parse(result.stdout) : null;
    } catch (error) {
      errors.push(`story-prose-gate.js ${file.relPath}: invalid json: ${error.message}`);
    }
    const findings = json?.findings || [];
    proseIssues += findings.length;
    reports.push({
      file: file.relPath,
      status: json?.status || (result.exitCode === 0 ? 'pass' : 'error'),
      findings: findings.slice(0, 20),
    });
    if (!json && result.exitCode !== 0) errors.push(`story-prose-gate.js ${file.relPath}: exit ${result.exitCode}`);
  }

  return {
    sampled: samples.length,
    proseIssues,
    samples: reports,
    errors,
  };
}

function collectDraftSamples(projectRoot, limit) {
  if (limit <= 0) return [];
  const files = [];
  const standalone = path.join(projectRoot, '正文.md');
  if (fs.existsSync(standalone)) files.push({ absPath: standalone, relPath: '正文.md', chapterNo: 1 });
  walkFiles(path.join(projectRoot, '正文'), '正文', file => {
    const base = path.basename(file.relPath);
    if (!/^第.+章.*\.(md|txt)$/i.test(base)) return;
    const chapterNo = parseChapterNo(base);
    if (!chapterNo) return;
    files.push({ ...file, chapterNo });
  });
  return files
    .sort((a, b) => Number(a.chapterNo || 0) - Number(b.chapterNo || 0)
      || a.relPath.localeCompare(b.relPath, 'zh-Hans-CN'))
    .slice(0, limit);
}

function walkFiles(absDir, relDir, visit) {
  for (const name of readDirSafe(absDir)) {
    const absPath = path.join(absDir, name);
    const relPath = slash(path.join(relDir, name));
    try {
      const stat = fs.statSync(absPath);
      if (stat.isDirectory()) walkFiles(absPath, relPath, visit);
      else if (stat.isFile()) visit({ absPath, relPath });
    } catch {
      // Ignore transient files.
    }
  }
}

function aggregateStatus(projects) {
  if (!projects.length) return 'error';
  if (projects.some(project => project.status === 'error')) return 'error';
  if (projects.some(project => project.status === 'needs_attention')) return 'needs_attention';
  return 'pass';
}

function printHuman(result) {
  console.log(`novel-assistant project smoke: ${result.status}`);
  for (const project of result.projects) {
    const domain = project.domainProfile?.primaryDomain || 'unknown';
    const axis = project.domainProfile?.growthAxisLabel || 'unknown';
    console.log(`- ${project.projectName}: ${project.status} | ${domain} | ${axis} | progress=${project.progressStatus} | proseIssues=${project.proseGate.proseIssues}`);
  }
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}
