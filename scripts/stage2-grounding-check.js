#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const positional = args.filter(arg => !arg.startsWith('--') && !isOptionValue(arg));
const sourcePath = positional[0];
const summaryPath = positional[1];
const jsonOutput = args.includes('--json');
const chaptersArg = valueAfter('--chapters');

if (!sourcePath) {
  fail('usage: stage2-grounding-check.js <chapter-source.txt> <summary.md> [--json]\n       stage2-grounding-check.js <deconstruction-dir> --chapters 81-86 [--json]');
}

const result = fs.existsSync(sourcePath) && fs.statSync(sourcePath).isDirectory()
  ? checkDeconstructionDir(sourcePath, chaptersArg)
  : checkSingleFilePair(sourcePath, summaryPath);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
} else if (result.status === 'pass') {
  process.stdout.write('stage2 grounding check passed\n');
} else {
  process.stdout.write(`stage2 grounding check failed: ${result.failures.map(row => row.type).join(', ')}\n`);
}

process.exit(result.status === 'pass' ? 0 : 1);

function checkSingleFilePair(chapterSourcePath, chapterSummaryPath) {
  if (!chapterSourcePath || !chapterSummaryPath) {
    fail('usage: stage2-grounding-check.js <chapter-source.txt> <summary.md> [--json]');
  }
  const source = readFile(chapterSourcePath);
  const summary = readFile(chapterSummaryPath);
  return checkGrounding(source, summary, {
    sourcePath: path.resolve(chapterSourcePath),
    summaryPath: path.resolve(chapterSummaryPath),
  });
}

function checkDeconstructionDir(deconstructionDir, rawChapters) {
  const root = path.resolve(deconstructionDir);
  const indexPath = path.join(root, '章节切片索引.jsonl');
  const hasIndex = fs.existsSync(indexPath);
  const sourceFile = hasIndex ? findSourceFile(root) : null;
  const source = sourceFile ? readFile(sourceFile) : null;
  const indexRows = hasIndex ? readJsonl(indexPath) : [];
  const requested = parseChapters(rawChapters, indexRows);
  const results = [];
  const failures = [];
  for (const chapter of requested) {
    const row = indexRows.find(item => Number(item.chapterNo) === chapter);
    const summaryPath = findSummaryFile(path.join(root, '章节'), chapter);
    const legacySourcePath = row ? null : findLegacyChapterSourceFile(root, chapter);
    if (!row && !legacySourcePath) {
      failures.push({ chapter, type: 'missing_chapter_slice', message: `章节切片索引缺少第${chapter}章` });
      continue;
    }
    if (!summaryPath) {
      failures.push({ chapter, type: 'missing_summary', message: `章节目录缺少第${chapter}章_摘要.md` });
      continue;
    }
    const sourceSlice = row ? source.slice(row.startOffset, row.endOffset) : readFile(legacySourcePath);
    const summary = readFile(summaryPath);
    const chapterResult = checkGrounding(sourceSlice, summary, {
      sourcePath: row ? `${sourceFile}#${row.startOffset}-${row.endOffset}` : legacySourcePath,
      summaryPath,
    });
    results.push({ chapter, ...chapterResult });
    for (const failure of chapterResult.failures) {
      failures.push({ chapter, ...failure });
    }
  }
  return {
    status: failures.length ? 'fail' : 'pass',
    deconstructionDir: root,
    checked: results.length,
    requested: requested.length,
    failures,
    results,
  };
}

function checkGrounding(sourceText, summaryText, meta) {
  const normalizedSource = normalize(sourceText);
  const failures = [];
  const unknownEntities = collectUnknownEntities(summaryText, normalizedSource);
  if (unknownEntities.length) {
    failures.push({
      type: 'unknown_entities',
      items: unknownEntities,
    });
  }

  const quoteFailures = collectQuoteFailures(summaryText, normalizedSource);
  failures.push(...quoteFailures);

  return {
    status: failures.length ? 'fail' : 'pass',
    sourcePath: meta.sourcePath,
    summaryPath: meta.summaryPath,
    failures,
  };
}

function collectUnknownEntities(summaryText, normalizedSource) {
  const names = new Set();
  const characterSection = extractSection(summaryText, /\*\*出场人物\*\*/, /\*\*情节点\*\*/);
  for (const row of extractMarkdownTableRows(characterSection)) {
    if (row.length >= 4 && row[0] && !isHeaderCell(row[0])) {
      addEntity(names, row[0]);
      for (const alias of splitEntityList(row[2] || '')) addEntity(names, alias);
    }
  }

  const involvedPattern = /涉及([^|。\n\r]*)/g;
  for (const match of summaryText.matchAll(involvedPattern)) {
    for (const entity of splitEntityList(match[1])) addEntity(names, entity);
  }

  const unknown = [];
  for (const name of names) {
    if (!isGroundableEntity(name)) continue;
    if (!entityGrounded(name, normalizedSource)) unknown.push(name);
  }
  return Array.from(new Set(unknown)).sort();
}

function collectQuoteFailures(summaryText, normalizedSource) {
  const failures = [];
  const lines = summaryText.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    if (!/^P[0-9]+\s+/.test(lines[i])) continue;
    const quoteLines = [];
    for (let j = i + 1; j < lines.length; j += 1) {
      const line = lines[j].trim();
      if (/^主题标签/.test(line)) break;
      if (!line || line.startsWith('|')) continue;
      quoteLines.push(line.replace(/^>\s*/, ''));
    }
    const quote = quoteLines.join('').trim();
    const point = lines[i].match(/^(P[0-9]+)/)?.[1] || `P${i + 1}`;
    if (!quote) {
      failures.push({ type: 'quote_missing', point });
      continue;
    }
    const normalizedQuote = normalize(quote);
    if (normalizedQuote.length >= 8 && !normalizedSource.includes(normalizedQuote)) {
      failures.push({
        type: 'quote_not_in_source',
        point,
        quote: quote.slice(0, 80),
      });
    }
  }
  return failures;
}

function extractMarkdownTableRows(text) {
  return text
    .split(/\r?\n/)
    .filter(line => /^\|.*\|$/.test(line.trim()))
    .map(line => line.trim().slice(1, -1).split('|').map(cell => cell.trim()))
    .filter(row => !row.every(cell => /^-+$/.test(cell.replace(/[:：]/g, ''))));
}

function extractSection(text, startPattern, endPattern) {
  const start = text.search(startPattern);
  if (start < 0) return '';
  const rest = text.slice(start);
  const end = rest.slice(1).search(endPattern);
  if (end < 0) return rest;
  return rest.slice(0, end + 1);
}

function splitEntityList(value) {
  return String(value || '')
    .replace(/[，、/／;；|]/g, ',')
    .split(',')
    .map(item => item.trim())
    .filter(Boolean);
}

function addEntity(set, raw) {
  const entity = sanitizeEntity(raw);
  if (entity) set.add(entity);
}

function sanitizeEntity(raw) {
  return String(raw || '')
    .replace(/\s+/g, '')
    .replace(/[（）()《》「」“”"']/g, '')
    .replace(/^(无|空|null|none|未知|不明)$/i, '')
    .trim();
}

function isHeaderCell(cell) {
  return /^(角色|人物|本章重要性|别名|涉及)$/.test(cell);
}

function isGroundableEntity(value) {
  if (!value || value.length < 2 || value.length > 12) return false;
  if (!/[\u4e00-\u9fff]/.test(value)) return false;
  if (/^(major|supporting|minor|无|空|未知|不明|多人|众人|路人|群体|地点|物品)$/i.test(value)) return false;
  if (/^(父亲|母亲|老师|先生|小姐|公子|掌柜|小二|众人|百姓|士兵|孩子|老人|男人|女人|少年|少女|青年|中年人|老者)$/.test(value)) return false;
  if (/^(白袍老者|白袍白须老者|老人家|管家老头)$/.test(value)) return false;
  if (/^第[一二三四五六七八九十百千万0-9]+代(族长|家主|掌门|宗主)$/.test(value)) return false;
  return true;
}

function entityGrounded(value, normalizedSource) {
  const normalized = normalize(value);
  if (normalizedSource.includes(normalized)) return true;

  const withoutSuffix = normalized.replace(/(之父|之母|爷爷|叔叔|伯伯|少爷|小姐|大人)$/, '');
  if (withoutSuffix.length >= 2 && normalizedSource.includes(withoutSuffix)) return true;

  const withoutPrefix = withoutSuffix.replace(/^小(?=[\u4e00-\u9fff]{2,})/, '');
  if (withoutPrefix.length >= 2 && normalizedSource.includes(withoutPrefix)) return true;

  const middleDotParts = String(value).split('·').map(part => normalize(part)).filter(Boolean);
  if (middleDotParts.length > 1 && middleDotParts.some(part => part.length >= 2 && normalizedSource.includes(part))) {
    return true;
  }

  return false;
}

function normalize(value) {
  return String(value || '')
    .replace(/\s+/g, '')
    .replace(/[，。！？、；：“”‘’"'《》「」（）()\[\]【】\-—…·.!,?:;]/g, '');
}

function readFile(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    fail(`cannot read file: ${file}: ${error.message}`);
  }
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

function parseChapters(raw, indexRows) {
  if (!raw) {
    return indexRows.map(row => Number(row.chapterNo)).filter(Number.isFinite);
  }
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
  const pattern = new RegExp(`^第0*${chapter}章_摘要\\.md$`);
  const found = fs.readdirSync(chaptersDir).find(name => pattern.test(name));
  return found ? path.join(chaptersDir, found) : null;
}

function findLegacyChapterSourceFile(root, chapter) {
  const pattern = new RegExp(`^第0*${chapter}章(?!_摘要)[^/]*\\.md$`);
  const found = fs.readdirSync(root).find(name => pattern.test(name));
  return found ? path.join(root, found) : null;
}

function valueAfter(flag) {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : null;
}

function isOptionValue(arg) {
  const index = args.indexOf(arg);
  return args[index - 1] === '--chapters';
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
