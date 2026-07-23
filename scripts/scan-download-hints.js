#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const args = parseArgs(process.argv.slice(2));
if (!args.input) {
  fail(`Usage: node scripts/scan-download-hints.js <scan-dir|ranking-items.jsonl> [--json] [--commands] [--select 1,3|bookId] [--ledger FILE] [--download-skill-dir DIR] [--output-dir DIR]

Reads v0.8 scan artifacts and extracts downloadable book hints.
Currently supported download source: fanqie page/bookId.`);
}

const sourceFile = resolveRankingItemsFile(args.input);
const items = readJsonl(sourceFile);
const hints = [];

for (const item of items) {
  const hint = fanqieHint(item);
  if (hint) hints.push(hint);
}

const selectedHints = filterSelected(hints, args.select);
const metricContext = buildMetricContext(selectedHints);
annotateQuality(selectedHints, metricContext);
const rankedHints = applyMetricPlan(selectedHints, args);
const ledger = args.ledger ? readLedger(args.ledger) : emptyLedger();
const skippedDuplicates = [];
const plannedHints = [];
for (const hint of rankedHints) {
  if (isDownloaded(ledger, hint)) skippedDuplicates.push(hint);
  else plannedHints.push(hint);
}

const runResults = args.run ? runDownloads(plannedHints, args, ledger) : [];
if (args.run && args.ledger) writeLedger(args.ledger, ledger);

const result = {
  status: 'ok',
  sourceFile,
  totalItems: items.length,
  downloadableCount: hints.length,
  sortBy: args.sortBy,
  top: args.top,
  metricAvailability: metricContext.availability,
  filters: metricFilters(args),
  selectedCount: plannedHints.length,
  skippedDuplicateCount: skippedDuplicates.length,
  runResults,
  skippedDuplicates,
  hints: plannedHints,
};

if (args.commands && !args.json) {
  if (plannedHints.length === 0) {
    console.log('# no downloadable fanqie hints found');
  } else {
    for (const hint of plannedHints) console.log(hint.downloadCommand);
  }
} else {
  console.log(JSON.stringify(result, null, 2));
}

function fanqieHint(item) {
  const metrics = normalizeMetrics(item);
  const rawUrl = firstString(item.pageUrl, item.detailUrl, item.url, item.URL, metrics.pageUrl, metrics.detailUrl, metrics.url);
  const sourceText = [
    item.platform,
    item.source,
    item.sourceName,
    metrics.platform,
    metrics.source,
    rawUrl,
  ].filter(Boolean).join(' ').toLowerCase();

  const bookId = normalizeBookId(
    firstString(
      item.bookId,
      item.bookID,
      item.book_id,
      metrics.bookId,
      metrics.bookID,
      metrics.book_id,
      extractFanqieBookId(rawUrl)
    )
  );

  const isFanqie = sourceText.includes('fanqie') || sourceText.includes('番茄') || /fanqienovel\.com/.test(String(rawUrl || ''));
  if (!isFanqie || !bookId) return null;

  const title = firstString(item.title, item.bookName, item.name, metrics.title, metrics.bookName) || `番茄作品_${bookId}`;
  const author = firstString(item.author, item.authorName, metrics.author, metrics.authorName) || '';
  const pageUrl = fanqiePageUrl(bookId);
  return {
    source: 'fanqie',
    rank: numberOrNull(item.rank),
    title,
    author,
    bookId,
    pageUrl,
    originalUrl: rawUrl || pageUrl,
    metrics,
    downloadCommand: buildDownloadCommand({ title, author, pageUrl, args }),
  };
}

function normalizeMetrics(item) {
  const metrics = { ...objectValue(item.metrics) };
  for (const key of ['readCount', 'readGrowth', 'wordCount', 'score']) {
    if (metrics[key] === undefined && item[key] !== undefined) metrics[key] = item[key];
  }
  return metrics;
}

function buildDownloadCommand({ title, author, pageUrl, args }) {
  return buildDownloadArgs({ title, author, pageUrl, args }).map(shellQuote).join(' ');
}

function buildDownloadArgs({ title, author, pageUrl, args }) {
  const scriptPath = args.downloadSkillDir
    ? path.join(args.downloadSkillDir, 'scripts', 'novel_download.py')
    : path.join('scripts', 'novel_download.py');
  const parts = [
    scriptPath,
    '--url',
    pageUrl,
    '--book',
    title,
  ];
  if (author) parts.push('--author', author);
  if (args.outputDir) parts.push('--output-dir', args.outputDir);
  parts.push('--auto');
  return ['python3', ...parts];
}

function runDownloads(hints, args, ledger) {
  const results = [];
  for (const hint of hints) {
    const commandArgs = buildDownloadArgs({ title: hint.title, author: hint.author, pageUrl: hint.pageUrl, args });
    const result = spawnSync(commandArgs[0], commandArgs.slice(1), {
      encoding: 'utf8',
      maxBuffer: 10 * 1024 * 1024,
    });
    results.push({
      source: hint.source,
      bookId: hint.bookId,
      title: hint.title,
      status: result.status,
      error: result.error ? result.error.message : '',
      stdout: trimForJson(result.stdout),
      stderr: trimForJson(result.stderr),
    });
    if (result.status === 0) recordDownloaded(ledger, hint);
  }
  return results;
}

function extractFanqieBookId(url) {
  const text = String(url || '');
  const page = text.match(/fanqienovel\.com\/page\/(\d{8,})/);
  if (page) return page[1];
  const query = text.match(/[?&](?:book_id|bookId)=(\d{8,})/);
  if (query) return query[1];
  return '';
}

function fanqiePageUrl(bookId) {
  return `https://fanqienovel.com/page/${bookId}`;
}

function filterSelected(hints, selector) {
  const tokens = String(selector || '').split(/[,，\s]+/).map((item) => item.trim()).filter(Boolean);
  if (tokens.length === 0 || tokens.includes('all') || tokens.includes('全部')) return hints;
  const wanted = new Set(tokens);
  return hints.filter((hint) => wanted.has(String(hint.rank)) || wanted.has(hint.bookId) || wanted.has(hint.title));
}

function applyMetricPlan(hints, args) {
  let planned = hints.filter((hint) => passesMetricFilters(hint, args));
  const sortBy = normalizeSortBy(args.sortBy);
  planned = planned.slice().sort((a, b) => compareHints(a, b, sortBy));
  if (args.top > 0) planned = planned.slice(0, args.top);
  return planned;
}

function passesMetricFilters(hint, args) {
  const filters = metricFilters(args);
  if (filters.minQuality > 0 && Number(hint.qualityScore || 0) < filters.minQuality) return false;
  if (filters.minReadCount > 0 && metricNumber(hint, 'readCount') < filters.minReadCount) return false;
  if (filters.minReadGrowth > 0 && metricNumber(hint, 'readGrowth') < filters.minReadGrowth) return false;
  if (filters.minWordCount > 0 && metricNumber(hint, 'wordCount') < filters.minWordCount) return false;
  if (filters.minScore > 0 && metricNumber(hint, 'score') < filters.minScore) return false;
  return true;
}

function metricFilters(args) {
  return {
    minReadCount: args.minReadCount,
    minReadGrowth: args.minReadGrowth,
    minWordCount: args.minWordCount,
    minScore: args.minScore,
    minQuality: args.minQuality,
  };
}

function compareHints(a, b, sortBy) {
  if (sortBy === 'rank') return rankValue(a) - rankValue(b);
  if (sortBy === 'quality') {
    const diff = Number(b.qualityScore || 0) - Number(a.qualityScore || 0);
    if (diff !== 0) return diff;
    return rankValue(a) - rankValue(b);
  }
  const diff = metricNumber(b, sortBy) - metricNumber(a, sortBy);
  if (diff !== 0) return diff;
  return rankValue(a) - rankValue(b);
}

function buildMetricContext(hints) {
  const keys = ['readGrowth', 'readCount', 'wordCount', 'score', 'authorLevel'];
  const availability = {};
  const max = {};
  for (const key of keys) {
    const values = hints.map((hint) => metricNumber(hint, key)).filter((value) => value > 0);
    availability[key] = values.length;
    max[key] = values.length ? Math.max(...values) : 0;
  }
  return { availability, max, total: hints.length };
}

function annotateQuality(hints, context) {
  for (const hint of hints) {
    const scored = qualityScore(hint, context);
    hint.qualityScore = scored.score;
    hint.qualityReasons = scored.reasons;
  }
}

function qualityScore(hint, context) {
  const parts = [];
  function add(key, label, weight) {
    if (!context.max[key]) return;
    const value = metricNumber(hint, key);
    const normalized = Math.max(0, Math.min(1, value / context.max[key]));
    parts.push({ key, label, value, weight, score: normalized * weight });
  }

  add('readGrowth', '首秀读增', context.availability.readGrowth > 0 ? 0.32 : 0);
  add('readCount', '总在读', 0.34);
  add('wordCount', '字数成熟度', 0.14);
  add('score', '评分/热度分', context.availability.score > 0 ? 0.12 : 0);
  add('authorLevel', '作者等级', 0.08);

  const rankBonus = context.total > 1 && Number.isFinite(Number(hint.rank))
    ? ((context.total - rankValue(hint) + 1) / context.total) * 0.08
    : 0;
  if (rankBonus > 0) parts.push({ key: 'rank', label: '榜位', value: hint.rank, weight: 0.08, score: rankBonus });

  const weightSum = parts.reduce((sum, item) => sum + item.weight, 0) || 1;
  const score = parts.reduce((sum, item) => sum + item.score, 0) / weightSum;
  const reasons = parts
    .filter((item) => item.value > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, 4)
    .map((item) => `${item.label}: ${item.value}`);
  return { score: Math.round(score * 1000) / 1000, reasons };
}

function metricNumber(hint, key) {
  const metrics = objectValue(hint.metrics);
  const aliases = {
    readCount: ['readCount', 'readerCount', 'readingCount'],
    readGrowth: ['readGrowth', 'readerGrowth'],
    wordCount: ['wordCount', 'words'],
    score: ['score', 'rating', 'heatScore'],
    authorLevel: ['authorLevel', 'authorLv', 'level'],
  }[key] || [key];
  for (const alias of aliases) {
    const raw = metrics[alias] ?? hint[alias];
    const value = key === 'authorLevel' ? parseAuthorLevel(raw) : Number(raw);
    if (Number.isFinite(value)) return value;
  }
  return 0;
}

function parseAuthorLevel(value) {
  const text = String(value || '');
  const matched = text.match(/(?:Lv\.?|LV|等级)?\s*(\d+(?:\.\d+)?)/i);
  return matched ? Number(matched[1]) : 0;
}

function rankValue(hint) {
  return Number.isFinite(Number(hint.rank)) ? Number(hint.rank) : Number.MAX_SAFE_INTEGER;
}

function normalizeSortBy(value) {
  const text = String(value || 'rank').trim();
  const allowed = new Set(['rank', 'quality', 'readCount', 'readGrowth', 'wordCount', 'score']);
  if (!allowed.has(text)) fail(`invalid --sort-by: ${text} (rank|quality|readCount|readGrowth|wordCount|score)`);
  return text;
}

function emptyLedger() {
  return { downloaded: [] };
}

function readLedger(file) {
  const resolved = path.resolve(file);
  if (!fs.existsSync(resolved)) return emptyLedger();
  try {
    const parsed = JSON.parse(fs.readFileSync(resolved, 'utf8'));
    if (Array.isArray(parsed)) return { downloaded: parsed };
    if (parsed && typeof parsed === 'object') {
      return { downloaded: Array.isArray(parsed.downloaded) ? parsed.downloaded : [] };
    }
  } catch (error) {
    fail(`invalid ledger ${file}: ${error.message}`);
  }
  return emptyLedger();
}

function isDownloaded(ledger, hint) {
  return ledger.downloaded.some((entry) => {
    const source = String(entry.source || entry.platform || '').trim();
    const bookId = normalizeBookId(firstString(entry.bookId, entry.bookID, entry.book_id, entry.id));
    return source === hint.source && bookId === hint.bookId;
  });
}

function recordDownloaded(ledger, hint) {
  if (isDownloaded(ledger, hint)) return;
  ledger.downloaded.push({
    source: hint.source,
    bookId: hint.bookId,
    title: hint.title,
    author: hint.author,
    pageUrl: hint.pageUrl,
    downloadedAt: new Date().toISOString(),
  });
}

function writeLedger(file, ledger) {
  const resolved = path.resolve(file);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, JSON.stringify(ledger, null, 2) + '\n', 'utf8');
}

function trimForJson(value) {
  const text = String(value || '').trim();
  return text.length > 4000 ? `${text.slice(0, 4000)}\n...[truncated]` : text;
}

function resolveRankingItemsFile(input) {
  const resolved = path.resolve(input);
  if (!fs.existsSync(resolved)) fail(`input not found: ${input}`);
  const stat = fs.statSync(resolved);
  const file = stat.isDirectory() ? path.join(resolved, 'ranking-items.jsonl') : resolved;
  if (!fs.existsSync(file)) fail(`ranking-items.jsonl not found: ${file}`);
  return file;
}

function readJsonl(file) {
  const rows = [];
  const text = fs.readFileSync(file, 'utf8');
  let lineNo = 0;
  for (const line of text.split(/\r?\n/)) {
    lineNo += 1;
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      rows.push(JSON.parse(trimmed));
    } catch (error) {
      fail(`invalid jsonl at ${file}:${lineNo}: ${error.message}`);
    }
  }
  return rows;
}

function objectValue(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function firstString(...values) {
  for (const value of values) {
    if (value === null || value === undefined) continue;
    const text = String(value).trim();
    if (text) return text;
  }
  return '';
}

function normalizeBookId(value) {
  const text = String(value || '').trim();
  const matched = text.match(/\d{8,}/);
  return matched ? matched[0] : '';
}

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function shellQuote(value) {
  const text = String(value);
  if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(text)) return text;
  return `'${text.replace(/'/g, `'\\''`)}'`;
}

function parseArgs(argv) {
  const parsed = {
    input: '',
    json: false,
    commands: false,
    run: false,
    select: '',
    ledger: '',
    sortBy: 'rank',
    top: 0,
    minReadCount: 0,
    minReadGrowth: 0,
    minWordCount: 0,
    minScore: 0,
    minQuality: 0,
    downloadSkillDir: '',
    outputDir: '',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') parsed.json = true;
    else if (arg === '--commands') parsed.commands = true;
    else if (arg === '--run') parsed.run = true;
    else if (arg === '--select') parsed.select = requireValue(argv, ++i, arg);
    else if (arg === '--all') parsed.select = 'all';
    else if (arg === '--ledger') parsed.ledger = requireValue(argv, ++i, arg);
    else if (arg === '--sort-by') parsed.sortBy = normalizeSortBy(requireValue(argv, ++i, arg));
    else if (arg === '--top' || arg === '--limit') parsed.top = nonNegativeNumber(requireValue(argv, ++i, arg), arg);
    else if (arg === '--min-read-count') parsed.minReadCount = nonNegativeNumber(requireValue(argv, ++i, arg), arg);
    else if (arg === '--min-read-growth') parsed.minReadGrowth = nonNegativeNumber(requireValue(argv, ++i, arg), arg);
    else if (arg === '--min-word-count') parsed.minWordCount = nonNegativeNumber(requireValue(argv, ++i, arg), arg);
    else if (arg === '--min-score') parsed.minScore = nonNegativeNumber(requireValue(argv, ++i, arg), arg);
    else if (arg === '--min-quality') parsed.minQuality = nonNegativeNumber(requireValue(argv, ++i, arg), arg);
    else if (arg === '--download-skill-dir') parsed.downloadSkillDir = path.resolve(requireValue(argv, ++i, arg));
    else if (arg === '--output-dir') parsed.outputDir = requireValue(argv, ++i, arg);
    else if (!parsed.input) parsed.input = arg;
    else fail(`unknown argument: ${arg}`);
  }
  return parsed;
}

function nonNegativeNumber(value, flag) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) fail(`${flag} requires a non-negative number`);
  return number;
}

function requireValue(argv, index, flag) {
  if (index >= argv.length || !argv[index]) fail(`${flag} requires a value`);
  return argv[index];
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
