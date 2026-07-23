#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const {
  ensureDir,
  readText,
  writeJson,
  writeJsonl,
  nowIso,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const positional = args.filter(arg => !arg.startsWith('--'));
const sourcePath = positional[0];
const outputDir = positional[1];
if (!sourcePath || !outputDir) fail('usage: long-analyze-plan.js <source-text> <output-dir> [--write] [--json] [--batch-size N]');

const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');
const batchSize = readNumberArg('--batch-size', 30);

const sourceAbs = path.resolve(sourcePath);
const outAbs = path.resolve(outputDir);
const text = readText(sourceAbs, null);
if (text === null) fail(`source text not found: ${sourcePath}`);

const plan = buildAnalyzePlan(text, { batchSize });
if (shouldWrite) writeAnalyzePlan(outAbs, sourceAbs, text, plan);

const summary = {
  totalChapters: plan.chapters.length,
  totalChars: text.length,
  batchSize,
  batchCount: plan.batches.length,
  status: plan.chapters.length ? 'pass' : 'fail',
  outputDir: outAbs,
};

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
} else {
  console.log(`long analyze plan: ${summary.totalChapters} chapters, ${summary.batchCount} batches`);
  if (shouldWrite) console.log(`wrote ${outAbs}`);
}

function buildAnalyzePlan(raw, options) {
  const lineStarts = collectLineStarts(raw);
  const headings = collectChapterHeadings(raw);
  if (!headings.length) {
    return { chapters: [], batches: [] };
  }
  const chapters = headings.map((heading, index) => {
    const next = headings[index + 1];
    const startOffset = heading.index;
    const endOffset = next ? next.index : raw.length;
    const startLine = offsetToLine(lineStarts, startOffset);
    const endLine = offsetToLine(lineStarts, Math.max(startOffset, endOffset - 1));
    const body = raw.slice(startOffset, endOffset);
    return {
      chapterNo: heading.chapterNo || index + 1,
      title: heading.title || `第${index + 1}章`,
      heading: heading.heading,
      startLine,
      endLine,
      startOffset,
      endOffset,
      charCount: body.length,
      batchNo: Math.floor(index / options.batchSize) + 1,
      status: 'pending',
    };
  });
  const batches = [];
  for (let i = 0; i < chapters.length; i += options.batchSize) {
    const slice = chapters.slice(i, i + options.batchSize);
    batches.push({
      batchNo: batches.length + 1,
      startChapter: slice[0].chapterNo,
      endChapter: slice[slice.length - 1].chapterNo,
      chapterCount: slice.length,
      charCount: slice.reduce((sum, row) => sum + row.charCount, 0),
      status: 'pending',
    });
  }
  return { chapters, batches };
}

function writeAnalyzePlan(outDir, source, raw, plan) {
  ensureDir(outDir);
  ensureDir(path.join(outDir, '原文'));
  fs.copyFileSync(source, path.join(outDir, '原文', '原文.txt'));
  writeJsonl(path.join(outDir, '章节切片索引.jsonl'), plan.chapters);
  writeJson(path.join(outDir, '批次计划.json'), {
    schemaVersion: '1.0.0',
    generatedAt: nowIso(),
    batchPolicy: {
      batchSize,
      purpose: 'avoid context overflow by processing Stage 2 in resumable chapter windows',
    },
    totalChapters: plan.chapters.length,
    totalChars: raw.length,
    batches: plan.batches,
  });
  fs.writeFileSync(path.join(outDir, '_progress.md'), renderProgress(outDir, plan), 'utf8');
}

function renderProgress(outDir, plan) {
  const title = path.basename(outDir);
  const firstBatch = plan.batches[0];
  const lines = [
    `# 深度拆解进度：${title}`,
    `- 小说：${title} | 总章数：${plan.chapters.length} | 输出目录：${outDir} | 开始：${nowIso()}`,
    '- 最终状态：pending',
    '- schema_version: 3',
    '## 管道进度',
    '| 阶段 | 状态 | 进度 | 备注 |',
    '|------|------|------|------|',
    `| Stage 0.5 机械切章 | done | ${plan.chapters.length}/${plan.chapters.length} | 已生成 章节切片索引.jsonl 与 批次计划.json |`,
    '## 章节边界（Stage 0.5 产物，唯一权威）',
    '| 章号 | 标题 | 起始行 | 字数 | 批次 |',
    '|------|------|--------|------|------|',
    ...plan.chapters.map(row => `| ${row.chapterNo} | ${escapePipe(row.title)} | ${row.startLine} | ${row.charCount} | ${row.batchNo} |`),
    '## 分块进度',
    '| 块 | 章节 | 状态 |',
    '|----|------|------|',
    ...plan.batches.map(row => `| Batch ${row.batchNo} | 第${row.startChapter}-${row.endChapter}章 | pending |`),
    '## 失败记录',
    '| 类型 | 章节/阶段 | 错误信息 | 重试状态 |',
    '|------|----------|---------|---------|',
    '## 质量检查',
    '| 检查项 | 阶段 | 结果 | 修正 |',
    '|--------|------|------|------|',
    '## 角色合并',
    '| 合并前 | 合并后 | 依据 | 确认 |',
    '|--------|--------|------|------|',
    '## 断点',
    firstBatch
      ? `- 最后处理：Stage 0.5 | Stage 2 逐章摘要 | 下一操作：Stage 2 从第${firstBatch.startChapter}章开始，先处理第${firstBatch.startChapter}-${firstBatch.endChapter}章`
      : '- 最后处理：Stage 0.5 | 章节识别失败 | 下一操作：检查章节标题格式',
    '',
  ];
  return lines.join('\n');
}

function collectChapterHeadings(raw) {
  const pattern = /^(第\s*([0-9零一二三四五六七八九十百千万两]+)\s*章[^\r\n]*|Chapter\s+([0-9]+)[^\r\n]*)/gim;
  const headings = [];
  for (const match of raw.matchAll(pattern)) {
    const heading = match[1].trim();
    const numberText = match[2] || match[3] || '';
    headings.push({
      index: match.index,
      heading,
      chapterNo: parseChapterNumber(numberText),
      title: normalizeTitle(heading),
    });
  }
  return headings
    .filter((row, index, arr) => index === 0 || row.index > arr[index - 1].index)
    .sort((a, b) => a.index - b.index);
}

function normalizeTitle(heading) {
  return heading
    .replace(/^第\s*[0-9零一二三四五六七八九十百千万两]+\s*章\s*/, '')
    .replace(/^Chapter\s+[0-9]+\s*/i, '')
    .trim() || heading.trim();
}

function parseChapterNumber(value) {
  const text = String(value || '').trim();
  if (/^[0-9]+$/.test(text)) return Number(text);
  return chineseNumber(text);
}

function chineseNumber(text) {
  const digits = { 零: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  if (!text) return 0;
  let result = 0;
  let section = 0;
  let number = 0;
  const units = { 十: 10, 百: 100, 千: 1000 };
  for (const char of text) {
    if (Object.prototype.hasOwnProperty.call(digits, char)) {
      number = digits[char];
    } else if (Object.prototype.hasOwnProperty.call(units, char)) {
      section += (number || 1) * units[char];
      number = 0;
    } else if (char === '万') {
      result += (section + number) * 10000;
      section = 0;
      number = 0;
    }
  }
  return result + section + number;
}

function collectLineStarts(raw) {
  const starts = [0];
  for (let i = 0; i < raw.length; i += 1) {
    if (raw[i] === '\n') starts.push(i + 1);
  }
  return starts;
}

function offsetToLine(starts, offset) {
  let lo = 0;
  let hi = starts.length - 1;
  while (lo <= hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (starts[mid] <= offset) lo = mid + 1;
    else hi = mid - 1;
  }
  return Math.max(1, hi + 1);
}

function escapePipe(value) {
  return String(value || '').replaceAll('|', '\\|');
}

function readNumberArg(name, fallback) {
  const index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  const value = Number(args[index + 1]);
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
