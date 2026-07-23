#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  readJson,
  readDirSafe,
  parseChapterNo,
  nowIso,
  writeJson,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = firstPositional(args, ['--mode']);
if (!projectRoot) failUsage();

const mode = readOption('--mode', 'all');
if (!['draft', 'scan', 'all'].includes(mode)) failUsage();

const root = path.resolve(projectRoot);
const jsonOutput = args.includes('--json');
const shouldWrite = args.includes('--write');
const report = buildDoctorReport(root, mode);
if (shouldWrite) writeJson(path.join(root, '追踪', 'doctor-report.json'), report);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} else {
  process.stdout.write(renderMarkdown(report));
}

process.exit(report.status === 'fail' ? 1 : 0);

function buildDoctorReport(projectDir, selectedMode) {
  const checks = [];
  if (selectedMode === 'draft' || selectedMode === 'all') checks.push(...draftChecks(projectDir));
  if (selectedMode === 'scan' || selectedMode === 'all') checks.push(...scanChecks(projectDir, selectedMode === 'scan'));
  const status = checks.some(check => check.status === 'fail')
    ? 'fail'
    : (checks.some(check => check.status === 'warn') ? 'warn' : 'pass');
  return {
    schemaVersion: '0.9.0',
    generatedAt: nowIso(),
    mode: selectedMode,
    projectRoot: projectDir,
    status,
    summary: {
      checks: checks.length,
      passed: checks.filter(check => check.status === 'pass').length,
      warnings: checks.filter(check => check.status === 'warn').length,
      failed: checks.filter(check => check.status === 'fail').length,
    },
    checks,
  };
}

function draftChecks(projectDir) {
  const checks = [];
  for (const relDir of ['大纲', '正文', '追踪']) {
    const abs = path.join(projectDir, relDir);
    checks.push({
      id: `dir:${relDir}`,
      status: fs.existsSync(abs) && fs.statSync(abs).isDirectory() ? 'pass' : 'fail',
      message: fs.existsSync(abs) ? `${relDir} exists` : `missing ${relDir}`,
    });
  }

  const outlineChapters = chapterSet(projectDir, '大纲', /^细纲_第.+\.md$/);
  const draftChapters = chapterSet(projectDir, '正文', /^第.+\.md$/);
  const contractChapters = chapterSet(projectDir, path.join('追踪', '章节契约'), /^第.+\.md$/);
  const handoffChapters = chapterSet(projectDir, path.join('追踪', '交接包'), /^第.+\.md$/);
  const allDraftChapters = uniqueNumbers([...outlineChapters, ...draftChapters]);
  for (const chapterNo of allDraftChapters) {
    checks.push({
      id: `contract:${chapterNo}`,
      status: contractChapters.includes(chapterNo) ? 'pass' : 'fail',
      message: contractChapters.includes(chapterNo)
        ? `第${padChapter(chapterNo)}章 has contract`
        : `第${padChapter(chapterNo)}章 missing contract`,
    });
    checks.push({
      id: `handoff:${chapterNo}`,
      status: handoffChapters.includes(chapterNo) ? 'pass' : 'fail',
      message: handoffChapters.includes(chapterNo)
        ? `第${padChapter(chapterNo)}章 has handoff`
        : `第${padChapter(chapterNo)}章 missing handoff`,
    });
  }
  checks.push({
    id: 'draft:outline-present',
    status: outlineChapters.length ? 'pass' : 'fail',
    message: outlineChapters.length ? `found ${outlineChapters.length} outline(s)` : 'no chapter outline found',
  });
  checks.push({
    id: 'draft:body-present',
    status: draftChapters.length ? 'pass' : 'fail',
    message: draftChapters.length ? `found ${draftChapters.length} draft(s)` : 'no chapter draft found',
  });
  const schemaDir = path.join(projectDir, '追踪', 'schema');
  if (hasAny(schemaDir, ['story-state.json', 'chapters.jsonl', 'promises.jsonl', 'health.json'])) {
    checks.push(runValidatorCheck(
      'schema:v08',
      path.join(__dirname, 'story-schema-validate.js'),
      [projectDir],
      'v0.8 story schema validates',
    ));
  }

  const currentContractPath = path.join(schemaDir, 'current-contract.json');
  if (fs.existsSync(currentContractPath)) {
    checks.push(validateCurrentContract(currentContractPath));
  }
  return checks;
}

function scanChecks(projectDir, strict) {
  const scanDirs = findScanDirs(projectDir);
  if (scanDirs.length === 0) {
    return strict ? [{
      id: 'scan:artifacts',
      status: 'fail',
      message: 'scan artifacts not found',
    }] : [];
  }
  return scanDirs.map(scanDir => runValidatorCheck(
    `scan:v08:${path.relative(projectDir, scanDir) || '.'}`,
    path.join(__dirname, 'scan-json-validate.js'),
    [scanDir],
    'v0.8 scan artifacts validate',
  ));
}

function validateCurrentContract(file) {
  let contract;
  try {
    contract = readJson(file, null);
  } catch (error) {
    return {
      id: 'current-contract:v09',
      status: 'fail',
      message: `current-contract.json malformed: ${error.message}`,
    };
  }
  if (!contract || contract.schemaVersion !== '0.9.0' || !Number.isInteger(contract.chapterNo) || !contract.gate) {
    return { id: 'current-contract:v09', status: 'fail', message: 'current-contract.json shape invalid' };
  }
  if (!['pass', 'warn', 'fail'].includes(contract.gate.status)) {
    return { id: 'current-contract:v09', status: 'fail', message: `invalid current contract gate status: ${contract.gate.status}` };
  }
  if (contract.gate.status === 'fail') {
    return { id: 'current-contract:v09', status: 'fail', message: 'current contract gate failed' };
  }
  return {
    id: 'current-contract:v09',
    status: contract.gate.status === 'warn' ? 'warn' : 'pass',
    message: `current contract gate ${contract.gate.status}`,
  };
}

function runValidatorCheck(id, command, commandArgs, successMessage) {
  const result = spawnSync(process.execPath, [command, ...commandArgs], { encoding: 'utf8' });
  return {
    id,
    status: result.status === 0 ? 'pass' : 'fail',
    message: result.status === 0 ? successMessage : (result.stderr || result.stdout || 'validator failed').trim(),
  };
}

function chapterSet(projectDir, relDir, pattern) {
  return uniqueNumbers(readDirSafe(path.join(projectDir, relDir))
    .filter(name => pattern.test(name))
    .map(parseChapterNo)
    .filter(Boolean));
}

function hasAny(dir, files) {
  return files.some(file => fs.existsSync(path.join(dir, file)));
}

function findScanDirs(projectDir) {
  const dirs = new Set();
  const required = ['scan-metadata.json', 'ranking-items.jsonl', 'trend-signals.json', 'topic-candidates.json'];
  if (required.every(file => fs.existsSync(path.join(projectDir, file)))) dirs.add(projectDir);

  const scanLibrary = path.join(projectDir, '扫榜库');
  for (const name of readDirSafe(scanLibrary)) {
    const child = path.join(scanLibrary, name);
    if (isDirectory(child) && required.every(file => fs.existsSync(path.join(child, file)))) dirs.add(child);
  }
  return Array.from(dirs).sort((a, b) => a.localeCompare(b, 'zh-Hans-CN'));
}

function isDirectory(dir) {
  try {
    return fs.statSync(dir).isDirectory();
  } catch (error) {
    return false;
  }
}

function uniqueNumbers(values) {
  return Array.from(new Set(values)).sort((a, b) => a - b);
}

function renderMarkdown(report) {
  const lines = [
    `# oh-story doctor`,
    '',
    `status: ${report.status}`,
    `mode: ${report.mode}`,
    '',
  ];
  for (const check of report.checks) {
    lines.push(`- [${check.status}] ${check.id}: ${check.message}`);
  }
  return `${lines.join('\n')}\n`;
}

function readOption(name, fallback) {
  const index = args.indexOf(name);
  return index === -1 ? fallback : args[index + 1];
}

function padChapter(chapterNo) {
  return String(chapterNo).padStart(3, '0');
}

function failUsage() {
  console.error('usage: oh-story-doctor.js <project-root> [--json] [--write] [--mode draft|scan|all]');
  process.exit(1);
}

function firstPositional(argv, optionsWithValues) {
  const optionsTakingValues = new Set(optionsWithValues);
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg.startsWith('--')) {
      if (optionsTakingValues.has(arg)) index += 1;
      continue;
    }
    return arg;
  }
  return null;
}
