#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const {
  ensureDir,
  readText,
  readDirSafe,
  parseChapterNo,
  nowIso,
  stripMarkdownBullet,
  writeJson,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = firstPositional(args, ['--chapter', '--volume', '--mode']);
const chapterIndex = args.indexOf('--chapter');
if (!projectRoot || chapterIndex === -1 || !args[chapterIndex + 1]) {
  fail('usage: context-pack-build.js <project-root> --chapter N [--volume 第X卷] [--mode writing|review] [--write] [--json]');
}

const root = path.resolve(projectRoot);
const chapterNo = Number(args[chapterIndex + 1]);
if (!Number.isInteger(chapterNo) || chapterNo <= 0) fail('--chapter must be positive integer');

const volume = optionValue(args, '--volume') || null;
const mode = optionValue(args, '--mode') || 'writing';
const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');

const pack = buildContextPack(root, { chapterNo, volume, mode });
if (shouldWrite) {
  writeJson(contextPackPath(root, pack.target.chapterNo, pack.target.volume), pack);
}

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(pack, null, 2)}\n`);
} else {
  console.log(`context pack: 第${padChapter(chapterNo)}章 (${pack.gate.status})`);
  if (shouldWrite) console.log(`wrote ${path.relative(root, contextPackPath(root, pack.target.chapterNo, pack.target.volume))}`);
}

function buildContextPack(projectDir, options) {
  const targetChapter = options.chapterNo;
  const targetVolume = options.volume || inferCurrentVolume(projectDir, targetChapter);
  const previousChapter = targetChapter - 1;

  const outline = findChapterFile(projectDir, '大纲', /^细纲_第.+\.md$/, targetChapter, targetVolume);
  const volumeOutline = findVolumeOutline(projectDir, targetVolume);
  const currentContract = findChapterFile(projectDir, path.join('追踪', '章节契约'), /^第.+\.md$/, targetChapter, targetVolume);
  const previousContract = previousChapter > 0
    ? findChapterFile(projectDir, path.join('追踪', '章节契约'), /^第.+\.md$/, previousChapter, targetVolume)
    : null;
  const previousHandoff = previousChapter > 0 ? findHandoffFile(projectDir, previousChapter, targetChapter, targetVolume) : null;
  const previousDraft = previousChapter > 0 ? findChapterFile(projectDir, '正文', /^第.+\.md$/, previousChapter, targetVolume) : null;
  const tracking = {
    context: readProjectFile(projectDir, path.join('追踪', '上下文.md')),
    foreshadow: readProjectFile(projectDir, path.join('追踪', '伏笔.md')),
    timeline: readProjectFile(projectDir, path.join('追踪', '时间线.md')),
    characterState: readProjectFile(projectDir, path.join('追踪', '角色状态.md')),
  };

  const combinedForCharacters = [
    outline && outline.text,
    currentContract && currentContract.text,
    previousHandoff && previousHandoff.text,
    previousDraft && previousDraft.text,
  ].filter(Boolean).join('\n');
  const characterFiles = findRelevantNamedFiles(projectDir, path.join('设定', '角色'), combinedForCharacters);
  const invariantFiles = findRelevantNamedFiles(projectDir, path.join('设定', '角色不变量'), combinedForCharacters);

  const sourceFiles = {
    outline: rel(outline),
    volumeOutline: rel(volumeOutline),
    currentContract: rel(currentContract),
    previousContract: rel(previousContract),
    previousHandoff: rel(previousHandoff),
    previousDraft: rel(previousDraft),
    context: tracking.context.relPath,
    foreshadow: tracking.foreshadow.relPath,
    timeline: tracking.timeline.relPath,
    characterState: tracking.characterState.relPath,
    characterFiles: characterFiles.map(file => file.relPath),
    characterInvariantFiles: invariantFiles.map(file => file.relPath),
  };

  const gaps = [];
  expect(gaps, outline, `第${padChapter(targetChapter)}章缺少细纲`, expectedChapterPath('大纲', targetChapter, targetVolume, '细纲'));
  expect(gaps, currentContract, `第${padChapter(targetChapter)}章缺少章节契约`, expectedChapterPath(path.join('追踪', '章节契约'), targetChapter, targetVolume, 'contract'));
  if (previousChapter > 0) {
    expect(gaps, previousHandoff, `第${padChapter(previousChapter)}章到第${padChapter(targetChapter)}章缺少交接包`, expectedHandoffPath(previousChapter, targetChapter, targetVolume));
  }
  if (!tracking.characterState.relPath && characterFiles.length) {
    gaps.push({
      code: 'character_state_missing',
      severity: 'warn',
      message: '追踪/角色状态.md 缺失，已从角色档案和角色不变量降级组装角色状态',
      expectedPath: path.join('追踪', '角色状态.md'),
    });
  }

  const mustCarryForward = unique([
    ...keywordLines(previousHandoff && previousHandoff.text, ['必须', '继承', '承接', '推进', '回收', '仍未', '未解决']),
    ...keywordLines(currentContract && currentContract.text, ['必须', '承接', '推进', '回收', '章尾', '期待']),
    ...keywordLines(outline && outline.text, ['必须', '承接', '推进', '回收', '章尾', '期待']),
  ]).slice(0, 30);
  const forbiddenChanges = unique([
    ...keywordLines(currentContract && currentContract.text, ['禁止', '不得', '不可']),
    ...keywordLines(outline && outline.text, ['禁止', '不得', '不可']),
    ...keywordLines(previousHandoff && previousHandoff.text, ['禁止', '不得', '不可']),
  ]).slice(0, 20);
  const openForeshadows = unique([
    ...tableOrKeywordLines(tracking.foreshadow.text, ['已埋', '待回收', '未回收', 'open', 'late', '异常', `第${padChapter(targetChapter)}章`, `第${targetChapter}章`]),
    ...keywordLines(currentContract && currentContract.text, ['伏笔', '线索', '钩子', '悬念']),
    ...keywordLines(outline && outline.text, ['伏笔', '线索', '钩子', '悬念']),
  ]).slice(0, 30);
  const characterState = unique([
    ...keywordLines(tracking.characterState.text, characterFiles.map(file => file.name)),
    ...characterFiles.flatMap(file => [`${file.name}: ${compactText(file.text, 300)}`]),
    ...invariantFiles.flatMap(file => `${file.name}不变量: ${compactText(file.text, 240)}`),
  ]).slice(0, 30);
  const recentStateDelta = tailImportantLines(tracking.context.text, 18);
  const timeline = unique([
    ...tableOrKeywordLines(tracking.timeline.text, [`第${padChapter(targetChapter)}章`, `第${targetChapter}章`, `第${padChapter(previousChapter)}章`, `第${previousChapter}章`]),
  ]).slice(0, 20);

  const blocking = gaps.filter(gap => gap.severity === 'fail');
  const warnings = gaps.filter(gap => gap.severity !== 'fail');
  return {
    schemaVersion: '0.10.0',
    generatedAt: nowIso(),
    mode: options.mode || 'writing',
    target: {
      chapterNo: targetChapter,
      chapterId: `第${padChapter(targetChapter)}章`,
      volume: targetVolume,
      previousChapterNo: previousChapter > 0 ? previousChapter : null,
    },
    sourceFiles,
    summary: {
      mustCarryForward,
      forbiddenChanges,
      openForeshadows,
      characterState,
      recentStateDelta,
      timeline,
      continuityQuestions: buildContinuityQuestions({ mustCarryForward, openForeshadows, characterState, gaps }),
    },
    promptHints: {
      useAsInput: '将本 Context Pack 作为写作/审阅前的最小上下文包；只在发现证据冲突或 gaps 阻塞时再读完整源文件。',
      doNotDo: '不要用聊天记忆替代本包中的 sourceFiles；不要把缺失文件推断成已验证事实。',
    },
    gaps,
    gate: {
      status: blocking.length ? 'fail' : (warnings.length ? 'warn' : 'pass'),
      blockingFindings: blocking,
      warnings,
    },
  };
}

function contextPackPath(projectDir, chapterNo, volume) {
  const base = volume ? path.join(projectDir, '追踪', 'context-pack', volume) : path.join(projectDir, '追踪', 'context-pack');
  return path.join(base, `第${padChapter(chapterNo)}章.json`);
}

function findChapterFile(projectDir, relDir, pattern, targetChapterNo, preferredVolume) {
  const candidates = [];
  walkFiles(path.join(projectDir, relDir), relDir, file => {
    const base = path.basename(file.relPath);
    if (!pattern.test(base)) return;
    if (parseChapterNo(base) !== targetChapterNo) return;
    candidates.push({
      relPath: file.relPath,
      absPath: file.absPath,
      text: readText(file.absPath),
      volume: inferVolumeFromRelPath(file.relPath),
    });
  });
  return chooseVolumeCandidate(candidates, preferredVolume);
}

function findHandoffFile(projectDir, fromChapterNo, toChapterNo, preferredVolume) {
  const relDir = path.join('追踪', '交接包');
  const candidates = [];
  walkFiles(path.join(projectDir, relDir), relDir, file => {
    const base = path.basename(file.relPath);
    if (!/^第.+\.md$/.test(base)) return;
    if (parseChapterNo(base) !== fromChapterNo) return;
    if (!file.relPath.includes(`to_第${padChapter(toChapterNo)}章`) && !file.relPath.includes(`to_第${toChapterNo}章`)) return;
    candidates.push({
      relPath: file.relPath,
      absPath: file.absPath,
      text: readText(file.absPath),
      volume: inferVolumeFromRelPath(file.relPath),
    });
  });
  return chooseVolumeCandidate(candidates, preferredVolume);
}

function findVolumeOutline(projectDir, volume) {
  if (!volume) return readProjectFile(projectDir, path.join('大纲', '大纲.md'));
  const candidates = [
    path.join('大纲', volume, '卷纲.md'),
    path.join('大纲', `卷纲_${volume}.md`),
    path.join('大纲', '大纲.md'),
  ];
  for (const relPath of candidates) {
    const file = readProjectFile(projectDir, relPath);
    if (file.relPath) return file;
  }
  return null;
}

function findRelevantNamedFiles(projectDir, relDir, sourceText) {
  const baseDir = path.join(projectDir, relDir);
  const files = [];
  for (const name of readDirSafe(baseDir)) {
    if (!name.endsWith('.md')) continue;
    const displayName = path.basename(name, '.md');
    const absPath = path.join(baseDir, name);
    const text = readText(absPath);
    if (!sourceText || sourceText.includes(displayName) || text.includes(displayName)) {
      files.push({ name: displayName, relPath: path.join(relDir, name), absPath, text });
    }
  }
  return files.slice(0, 12);
}

function readProjectFile(projectDir, relPath) {
  const absPath = path.join(projectDir, relPath);
  if (!fs.existsSync(absPath)) return { relPath: null, absPath, text: '' };
  return { relPath, absPath, text: readText(absPath) };
}

function walkFiles(baseDir, relDir, onFile) {
  for (const name of readDirSafe(baseDir)) {
    const absPath = path.join(baseDir, name);
    const currentRel = path.join(relDir, name);
    let stat;
    try {
      stat = fs.statSync(absPath);
    } catch (_) {
      continue;
    }
    if (stat.isDirectory()) walkFiles(absPath, currentRel, onFile);
    else if (stat.isFile()) onFile({ absPath, relPath: currentRel });
  }
}

function keywordLines(text, keywords) {
  if (!text) return [];
  const needles = keywords.filter(Boolean);
  return String(text).split(/\r?\n/)
    .map(stripMarkdownBullet)
    .filter(Boolean)
    .filter(line => needles.some(keyword => line.includes(keyword)));
}

function tableOrKeywordLines(text, keywords) {
  if (!text) return [];
  return String(text).split(/\r?\n/)
    .map(line => line.trim())
    .filter(line => line && !/^[-|:\s]+$/.test(line))
    .filter(line => line.includes('|') || keywords.some(keyword => keyword && line.includes(keyword)))
    .map(stripMarkdownBullet);
}

function tailImportantLines(text, maxLines) {
  if (!text) return [];
  return String(text).split(/\r?\n/)
    .map(stripMarkdownBullet)
    .filter(Boolean)
    .slice(-maxLines);
}

function compactText(text, maxChars) {
  return String(text || '')
    .split(/\r?\n/)
    .map(stripMarkdownBullet)
    .filter(Boolean)
    .join('；')
    .slice(0, maxChars);
}

function buildContinuityQuestions({ mustCarryForward, openForeshadows, characterState, gaps }) {
  const questions = [];
  if (mustCarryForward.length) questions.push('本章是否承接了上一章交接包和当前 Chapter Contract 的必须继承项？');
  if (openForeshadows.length) questions.push('本章是否推进、保留或合理回收 open 伏笔/钩子，而不是遗忘或提前泄底？');
  if (characterState.length) questions.push('人物目标、关系、能力、伤势、资源和认知边界是否延续上一状态？');
  if (gaps.length) questions.push('gaps 中的缺失证据是否已经补读或在报告中标为证据不足？');
  return questions;
}

function expect(gaps, file, message, expectedPath) {
  if (file) return;
  gaps.push({ code: 'missing_context_source', severity: 'warn', message, expectedPath });
}

function expectedChapterPath(relDir, chapterNo, volume, kind) {
  const file = kind === '细纲' ? `细纲_第${padChapter(chapterNo)}章.md` : `第${padChapter(chapterNo)}章.md`;
  return volume ? path.join(relDir, volume, file) : path.join(relDir, file);
}

function expectedHandoffPath(fromChapterNo, toChapterNo, volume) {
  const file = `第${padChapter(fromChapterNo)}章_to_第${padChapter(toChapterNo)}章.md`;
  return volume ? path.join('追踪', '交接包', volume, file) : path.join('追踪', '交接包', file);
}

function inferCurrentVolume(projectDir, chapterNo) {
  const sources = [
    findChapterFile(projectDir, '大纲', /^细纲_第.+\.md$/, chapterNo, null),
    findChapterFile(projectDir, '正文', /^第.+\.md$/, chapterNo, null),
  ].filter(Boolean);
  return sources[0] && sources[0].volume ? sources[0].volume : null;
}

function inferVolumeFromRelPath(relPath) {
  const parts = String(relPath || '').split(/[\\/]/);
  return parts.find(part => /^第.+卷$/.test(part)) || null;
}

function chooseVolumeCandidate(candidates, preferredVolume) {
  if (!candidates.length) return null;
  if (preferredVolume) {
    const exact = candidates.find(candidate => candidate.volume === preferredVolume);
    if (exact) return exact;
  }
  const flat = candidates.find(candidate => !candidate.volume);
  return flat || candidates[0];
}

function rel(file) {
  return file && file.relPath ? file.relPath : null;
}

function unique(values) {
  return Array.from(new Set(values.filter(Boolean)));
}

function optionValue(argv, option) {
  const index = argv.indexOf(option);
  return index === -1 ? null : argv[index + 1];
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

function padChapter(chapterNo) {
  return String(chapterNo).padStart(3, '0');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

module.exports = { buildContextPack };
