#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const dryRun = args.includes('--dry-run');
const chaptersArg = valueAfter('--chapters');
const positional = args.filter(arg => !arg.startsWith('--') && !isOptionValue(arg));
const deconstructionDir = positional[0];

if (!deconstructionDir) {
  fail('usage: stage2-quote-repair.js <deconstruction-dir> [--chapters 1-8|1,2] [--dry-run] [--json]');
}

const result = repairDeconstructionDir(deconstructionDir, chaptersArg);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
} else {
  process.stdout.write(`stage2 quote repair ${dryRun ? 'dry-run ' : ''}${result.status}: repaired ${result.repairedBlocks} blocks in ${result.changedFiles} files\n`);
  for (const row of result.files) {
    if (row.repairedBlocks) process.stdout.write(`- 第${row.chapter}章: ${row.repairedBlocks} blocks\n`);
  }
}

process.exit(result.status === 'error' ? 1 : 0);

function repairDeconstructionDir(rootDir, rawChapters) {
  const root = path.resolve(rootDir);
  const indexPath = path.join(root, '章节切片索引.jsonl');
  if (!fs.existsSync(indexPath)) fail(`missing index: ${indexPath}`);
  const sourceFile = findSourceFile(root);
  const source = readFile(sourceFile);
  const indexRows = readJsonl(indexPath);
  const chapters = parseChapters(rawChapters, indexRows);
  const files = [];
  let changedFiles = 0;
  let repairedBlocks = 0;

  for (const chapter of chapters) {
    const row = indexRows.find(item => Number(item.chapterNo) === chapter);
    const summaryPath = findSummaryFile(path.join(root, '章节'), chapter);
    if (!row || !summaryPath) {
      files.push({ chapter, status: 'skipped', reason: row ? 'missing_summary' : 'missing_slice' });
      continue;
    }

    const sourceSlice = source.slice(row.startOffset, row.endOffset);
    const summary = readFile(summaryPath);
    const repaired = repairSummaryQuotes(summary, sourceSlice);
    if (repaired.repairedBlocks > 0) {
      changedFiles += 1;
      repairedBlocks += repaired.repairedBlocks;
      if (!dryRun) fs.writeFileSync(summaryPath, repaired.text);
    }
    files.push({
      chapter,
      status: repaired.repairedBlocks ? 'repaired' : 'unchanged',
      repairedBlocks: repaired.repairedBlocks,
      summaryPath,
    });
  }

  return {
    status: 'ok',
    deconstructionDir: root,
    dryRun,
    requested: chapters.length,
    changedFiles,
    repairedBlocks,
    files,
  };
}

function repairSummaryQuotes(summary, sourceSlice) {
  const normalizedSource = normalize(sourceSlice);
  const sourceUnits = splitSourceUnits(sourceSlice);
  const lines = summary.split(/\r?\n/);
  const out = [];
  let repairedBlocks = 0;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (!/^P[0-9]+\s+/.test(line)) {
      out.push(line);
      continue;
    }

    out.push(line);
    const quoteLines = [];
    let j = i + 1;
    while (j < lines.length) {
      const current = lines[j];
      if (/^主题标签/.test(current.trim())) break;
      quoteLines.push(current);
      j += 1;
    }

    const quote = quoteLines.map(item => item.trim()).filter(Boolean).join('');
    const needsRepair = !quote || !normalizedSource.includes(normalize(quote));
    if (needsRepair) {
      const replacement = pickSourceQuote(line, sourceUnits);
      out.push('');
      out.push(replacement);
      out.push('');
      repairedBlocks += 1;
    } else {
      out.push(...quoteLines);
    }

    i = j - 1;
  }

  return {
    text: out.join('\n').replace(/\n{4,}/g, '\n\n\n'),
    repairedBlocks,
  };
}

function splitSourceUnits(source) {
  return source
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .flatMap(line => line.split(/(?<=[。！？!?])/).map(item => item.trim()).filter(Boolean))
    .filter(line => normalize(line).length >= 8);
}

function pickSourceQuote(pointLine, sourceUnits) {
  const keywords = extractKeywords(pointLine);
  let best = null;
  for (let index = 0; index < sourceUnits.length; index += 1) {
    const unit = sourceUnits[index];
    const normalized = normalize(unit);
    let score = 0;
    for (const keyword of keywords) {
      if (normalized.includes(normalize(keyword))) score += keyword.length >= 3 ? 3 : 1;
    }
    if (!best || score > best.score) best = { unit, score, index };
  }
  const chosen = best && best.score > 0 ? best.unit : sourceUnits[0] || '';
  return trimExactQuote(chosen);
}

function extractKeywords(line) {
  const cleaned = line
    .replace(/^P[0-9]+\s+/, '')
    .replace(/类型[^|]+/g, '')
    .replace(/涉及|地点|物品|时间/g, ' ')
    .replace(/[A-Za-z0-9_]+/g, ' ');
  const words = cleaned.match(/[\u4e00-\u9fff]{2,8}/g) || [];
  const stop = new Set(['事件概括', '信息揭示', '状态变化', '原文未明确', '转折点']);
  return Array.from(new Set(words.filter(word => !stop.has(word))));
}

function trimExactQuote(value) {
  const text = String(value || '').trim();
  if (text.length <= 220) return text;
  return text.slice(0, 220);
}

function parseChapters(raw, indexRows) {
  if (!raw) return indexRows.map(row => Number(row.chapterNo)).filter(Number.isFinite);
  const chapters = [];
  for (const part of String(raw).split(',')) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const range = trimmed.match(/^([0-9]+)-([0-9]+)$/);
    if (range) {
      const start = Number(range[1]);
      const end = Number(range[2]);
      const step = start <= end ? 1 : -1;
      for (let n = start; step > 0 ? n <= end : n >= end; n += step) chapters.push(n);
      continue;
    }
    const single = Number(trimmed);
    if (!Number.isInteger(single) || single <= 0) fail(`invalid --chapters value: ${raw}`);
    chapters.push(single);
  }
  return Array.from(new Set(chapters));
}

function findSummaryFile(chaptersDir, chapter) {
  const direct = [
    path.join(chaptersDir, `第${chapter}章_摘要.md`),
    path.join(chaptersDir, `第${String(chapter).padStart(3, '0')}章_摘要.md`),
  ];
  for (const file of direct) {
    if (fs.existsSync(file)) return file;
  }
  if (!fs.existsSync(chaptersDir)) return null;
  const prefix = new RegExp(`^第0*${chapter}章_摘要\\.md$`);
  const found = fs.readdirSync(chaptersDir).find(name => prefix.test(name));
  return found ? path.join(chaptersDir, found) : null;
}

function findSourceFile(root) {
  const candidates = [
    path.join(root, '原文', '原文.txt'),
    path.join(root, '原文', '原文.md'),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  fail(`cannot find source text under: ${path.join(root, '原文')}`);
}

function readJsonl(file) {
  return readFile(file)
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        fail(`invalid jsonl at ${file}:${index + 1}: ${error.message}`);
      }
    });
}

function readFile(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    fail(`cannot read file: ${file}: ${error.message}`);
  }
}

function normalize(value) {
  return String(value || '')
    .replace(/\s+/g, '')
    .replace(/[，。！？、；：“”‘’"'《》「」（）()\[\]【】\-—…·.!,?:;]/g, '');
}

function valueAfter(flag) {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : null;
}

function isOptionValue(arg) {
  const previous = args[args.indexOf(arg) - 1];
  return previous === '--chapters';
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
