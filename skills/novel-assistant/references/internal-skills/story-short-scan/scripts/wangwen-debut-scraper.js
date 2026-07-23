#!/usr/bin/env node
/**
 * 网文大数据 · 番茄首秀采集脚本
 *
 * 数据源： https://www.wangwendashuju.com/fq/debut
 * 接口：   POST /api/debut/list
 *
 * 本脚本只采集公开榜单指标并写 v0.8 扫榜产物；不自动下载正文。
 * 下载正文请先用 scan-download-hints.js 提取 bookId/pageUrl，再交给下载模块。
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const args = parseArgs(process.argv.slice(2));
const baseUrl = args.baseUrl || 'https://www.wangwendashuju.com';
const fanqieBaseUrl = args.fanqieBaseUrl || 'https://fanqienovel.com';
const outdir = path.resolve(args.outdir || `扫榜库/${dateStamp()}-wangwen-debut`);
const payload = buildPayload(args);

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });

async function main() {
  if (args.listCategories) {
    const categoryRaw = args.fixtureCategory
      ? fs.readFileSync(path.resolve(args.fixtureCategory), 'utf8')
      : await postJson(`${baseUrl}/api/debut/category`, {
        media: payload.media,
        gender: payload.gender,
        sxDate: payload.sxDate,
      });
    const categories = parseCategoryResponse(categoryRaw);
    console.log(JSON.stringify({
      status: 'ok',
      source: 'wangwen_debut',
      platform: 'fanqie',
      channel: payload.media === 'fqmm' ? 'female' : 'male',
      date: payload.sxDate,
      categories,
    }, null, 2));
    return;
  }

  const raw = args.fixtureList ? fs.readFileSync(path.resolve(args.fixtureList), 'utf8') : await postJson(`${baseUrl}/api/debut/list`, payload);
  const parsed = parseListResponse(raw);
  const categoryRaw = args.fixtureCategory
    ? fs.readFileSync(path.resolve(args.fixtureCategory), 'utf8')
    : await tryPostJson(`${baseUrl}/api/debut/category`, {
      media: payload.media,
      gender: payload.gender,
      sxDate: payload.sxDate,
    });
  const categories = categoryRaw ? parseCategoryResponse(categoryRaw) : [];

  const warnings = [];
  const scanId = `${compactDate(payload.sxDate)}-wangwen-debut-${payload.media}-${payload.sortField}`;
  const items = [];
  const limitedRecords = parsed.records.slice(0, payload.size);
  for (let index = 0; index < limitedRecords.length; index += 1) {
    let item = recordToRankingItem(limitedRecords[index], index + 1);
    if (args.enrichFanqie && item.metrics.bookId) {
      const official = await getFanqieOfficialInfo(item.metrics.bookId);
      if (official.data) {
        item = mergeFanqieOfficialInfo(item, official.data);
      } else {
        item.metrics.fanqieOfficial = {
          verified: false,
          source: 'fanqie_api_book_info',
          error: official.error || 'unknown official info error',
        };
        warnings.push(`番茄官方详情校验失败：${item.metrics.bookId} ${official.error || ''}`.trim());
      }
    }
    items.push(item);
  }
  if (items.length === 0) warnings.push('网文大数据首秀接口返回 0 条，可能是日期尚未更新或筛选条件过窄');

  const metadata = {
    schemaVersion: '0.8.0',
    scanId,
    platform: 'fanqie',
    platformName: '番茄小说',
    channel: payload.media === 'fqmm' ? 'female' : 'male',
    board: 'wangwen_debut',
    contentLength: 'long',
    sourceUrl: 'https://www.wangwendashuju.com/fq/debut',
    dataSources: args.enrichFanqie ? ['wangwen_debut', 'fanqie_api_book_info'] : ['wangwen_debut'],
    captureMode: 'api',
    capturedAt: new Date().toISOString(),
    selectors: payload,
    dataQuality: {
      status: items.length ? 'ok' : 'sparse',
      validItems: items.filter((item) => item.dataQuality === 'ok').length,
      rawItems: items.length,
      warnings,
    },
  };

  const trendSignals = buildTrendSignals(scanId, items, categories);
  const topicCandidates = buildTopicCandidates(scanId, items);

  fs.mkdirSync(outdir, { recursive: true });
  fs.writeFileSync(path.join(outdir, 'scan-metadata.json'), JSON.stringify(metadata, null, 2) + '\n', 'utf8');
  fs.writeFileSync(path.join(outdir, 'ranking-items.jsonl'), items.map((item) => JSON.stringify(item)).join('\n') + '\n', 'utf8');
  fs.writeFileSync(path.join(outdir, 'trend-signals.json'), JSON.stringify(trendSignals, null, 2) + '\n', 'utf8');
  fs.writeFileSync(path.join(outdir, 'topic-candidates.json'), JSON.stringify(topicCandidates, null, 2) + '\n', 'utf8');
  fs.writeFileSync(path.join(outdir, 'report.md'), renderReport(metadata, items, trendSignals, topicCandidates), 'utf8');

  validate(outdir);
  const result = {
    status: 'ok',
    outdir,
    scanId,
    total: parsed.total,
    count: items.length,
    downloadableCount: items.filter((item) => item.metrics && item.metrics.bookId).length,
  };
  console.log(JSON.stringify(result, null, 2));
}

function buildPayload(args) {
  const channel = String(args.channel || 'male').toLowerCase();
  const female = ['female', '女频', 'fqmm'].includes(channel);
  return {
    media: female ? 'fqmm' : 'fq',
    gender: female ? 0 : 1,
    page: positiveInt(args.page, 1),
    size: positiveInt(args.size, 20),
    sxDate: args.date || yesterday(),
    sortField: normalizeSortField(args.sortField || args.sort || 'readGrowth'),
    orderBy: String(args.orderBy || args.order || 'DESC').toUpperCase() === 'ASC' ? 'ASC' : 'DESC',
    viewMode: 'table',
    chartDateRangeType: 90,
    ...(args.category ? { category: args.category } : {}),
    ...(args.keyword ? { keyword: args.keyword } : {}),
  };
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'origin': baseUrl,
      'referer': `${baseUrl}/fq/debut`,
      'user-agent': 'Mozilla/5.0',
    },
    body: JSON.stringify(payload),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`wangwen debut api status ${response.status}: ${text.trim()}`);
  return text;
}

async function tryPostJson(url, payload) {
  try {
    return await postJson(url, payload);
  } catch {
    return '';
  }
}

async function getFanqieOfficialInfo(bookId) {
  try {
    if (args.fixtureFanqieInfoDir) {
      const file = path.join(path.resolve(args.fixtureFanqieInfoDir), `${bookId}.json`);
      const raw = fs.readFileSync(file, 'utf8');
      const parsed = JSON.parse(raw);
      return { data: parsed.data || parsed };
    }
    const response = await fetch(`${fanqieBaseUrl}/api/book/info?bookId=${encodeURIComponent(bookId)}`, {
      headers: {
        'accept': 'application/json,text/plain,*/*',
        'referer': `${fanqieBaseUrl}/page/${bookId}`,
        'user-agent': 'Mozilla/5.0',
      },
    });
    const text = await response.text();
    if (!response.ok) return { error: `fanqie api status ${response.status}: ${text.trim().slice(0, 200)}` };
    const parsed = JSON.parse(text);
    const data = parsed.data || parsed;
    if (!data || typeof data !== 'object') return { error: 'fanqie api missing data' };
    return { data };
  } catch (error) {
    return { error: error.message || String(error) };
  }
}

function parseListResponse(raw) {
  const api = JSON.parse(raw);
  if (Number(api.code) !== 200) throw new Error(`wangwen debut api code ${api.code}: ${api.message || ''}`);
  const data = api.data || {};
  return {
    records: Array.isArray(data.records) ? data.records : [],
    total: Number(data.total || 0),
  };
}

function parseCategoryResponse(raw) {
  const api = JSON.parse(raw);
  if (Number(api.code) !== 200 || !Array.isArray(api.data)) return [];
  return api.data.map((row) => ({
    name: String(row.name || row.category || '').trim(),
    count: Number(row.count || row.total || 0),
  })).filter((row) => row.name);
}

function recordToRankingItem(record, rank) {
  const bookId = String(record.bookId || '').trim();
  const title = String(record.bookName || '').trim() || `fanqie_${bookId || rank}`;
  const tags = Array.isArray(record.tags) ? record.tags.filter(Boolean).map(String) : [];
  const wordCount = Number(record.wordCount || 0);
  const readCount = Number(record.readCount || 0);
  const wordGrowth = Number(record.wordGrowth || 0);
  const readGrowth = Number(record.readGrowth || 0);
  const genre = String(record.category || '').trim() || '未分类';
  const pageUrl = bookId ? `https://fanqienovel.com/page/${bookId}` : '';
  return {
    rank,
    title,
    author: String(record.authorName || '').trim() || '未知作者',
    url: pageUrl || 'https://fanqienovel.com/',
    genre,
    tags,
    wordCount,
    heat: `总在读 ${readCount} / 首秀读增 ${readGrowth}`,
    summary: tags.length ? tags.join(' · ') : genre,
    updateText: dateOnly(record.sxDate || ''),
    metrics: {
      source: 'wangwen_debut',
      bookId,
      pageUrl,
      media: String(record.media || ''),
      gender: Number(record.gender || 0),
      authorLevel: String(record.authorLevel || ''),
      debutDate: dateOnly(record.sxDate || ''),
      readCount,
      wordGrowth,
      readGrowth,
      updateStatus: Number(record.updateStatus || 0),
      wordTrend: parseTrend(record.wordTrend),
      readTrend: parseTrend(record.readTrend),
      imageUrl: String(record.imageUrl || ''),
      downloadable: Boolean(bookId),
    },
    signals: [
      genre,
      ...tags.slice(0, 3),
      readGrowth > 0 ? `首秀读增 ${readGrowth}` : '',
    ].filter(Boolean),
    dataQuality: bookId ? 'ok' : 'sparse',
  };
}

function mergeFanqieOfficialInfo(item, info) {
  const officialTitle = firstNonEmpty(info.bookName, info.book_name, item.title);
  const officialAuthor = firstNonEmpty(info.authorName, info.author, info.author_name, item.author);
  const officialGenre = firstNonEmpty(parseFanqieCategoryV2(info.categoryV2), info.categoryName, info.category, item.genre);
  const officialWordCount = numberValue(info.wordNumber, info.word_count, item.wordCount);
  const officialReadCount = numberValue(info.readCount, info.read_count, item.metrics.readCount);
  const officialSummary = firstNonEmpty(info.abstract, info.description, info.introduction, item.summary);

  const metrics = {
    ...item.metrics,
    marketTitle: item.title,
    marketAuthor: item.author,
    marketGenre: item.genre,
    marketWordCount: item.wordCount,
    marketReadCount: item.metrics.readCount,
    readCount: officialReadCount,
    fanqieOfficial: {
      verified: true,
      source: 'fanqie_api_book_info',
      bookId: firstNonEmpty(info.bookId, item.metrics.bookId),
      bookName: officialTitle,
      authorName: officialAuthor,
      category: officialGenre,
      wordNumber: officialWordCount,
      readCount: officialReadCount,
      abstract: officialSummary,
      lastChapterTitle: firstNonEmpty(info.lastChapterTitle, info.last_chapter_title, ''),
      thumbUrl: firstNonEmpty(info.thumbUrl, info.thumb_url, item.metrics.imageUrl),
      creationStatus: firstNonEmpty(info.creationStatus, info.creation_status, ''),
      verifiedAt: new Date().toISOString(),
    },
  };

  return {
    ...item,
    title: officialTitle,
    author: officialAuthor,
    genre: officialGenre,
    wordCount: officialWordCount,
    heat: `番茄官方在读 ${officialReadCount} / 第三方首秀读增 ${item.metrics.readGrowth}`,
    summary: officialSummary,
    tags: Array.from(new Set([officialGenre, ...item.tags].filter(Boolean))),
    metrics,
    signals: Array.from(new Set([officialGenre, ...item.signals].filter(Boolean))),
    dataQuality: item.metrics.bookId ? 'ok' : item.dataQuality,
  };
}

function parseFanqieCategoryV2(raw) {
  if (!raw) return '';
  try {
    const rows = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (!Array.isArray(rows)) return '';
    const main = rows.find((row) => row && (row.MainCategory === true || row.mainCategory === true));
    const selected = main || rows.find((row) => row && (row.Name || row.name));
    return selected ? String(selected.Name || selected.name || '').trim() : '';
  } catch {
    return '';
  }
}

function firstNonEmpty(...values) {
  for (const value of values) {
    const text = String(value || '').trim();
    if (text) return text;
  }
  return '';
}

function numberValue(...values) {
  for (const value of values) {
    const number = Number(value);
    if (Number.isFinite(number) && number >= 0) return number;
  }
  return 0;
}

function buildTrendSignals(scanId, items, categories) {
  const categoryCounts = new Map();
  for (const item of items) {
    categoryCounts.set(item.genre, (categoryCounts.get(item.genre) || 0) + 1);
  }
  for (const category of categories) {
    if (!categoryCounts.has(category.name)) categoryCounts.set(category.name, category.count);
  }
  const signals = Array.from(categoryCounts.entries())
    .filter(([name]) => name)
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'zh-Hans-CN'))
    .slice(0, 8)
    .map(([name, count], index) => ({
      id: `S-wangwen-${slug(name) || index + 1}`,
      kind: 'genre',
      label: name,
      strength: items.length ? Math.min(1, Math.max(0.1, count / Math.max(items.length, 1))) : 0.1,
      evidenceCount: Number(count || 0),
      representativeTitles: items.filter((item) => item.genre === name).slice(0, 3).map((item) => item.title),
      risk: '第三方首秀指标，仅代表当前采集页样本',
    }));
  if (signals.length === 0) {
    signals.push({
      id: 'S-wangwen-debut-empty',
      kind: 'platform',
      label: '网文大数据首秀样本为空',
      strength: 0.1,
      evidenceCount: 0,
      representativeTitles: [],
      risk: '日期或筛选条件可能无数据',
    });
  }
  return { scanId, signals };
}

function buildTopicCandidates(scanId, items) {
  const candidates = items.slice(0, 8).map((item, index) => ({
    id: `T-wangwen-${item.metrics.bookId || index + 1}`,
    title: `${item.genre} · ${item.title} 对标拆解`,
    platformFit: ['fanqie'],
    difficulty: item.metrics.readGrowth > 10000 ? 'high' : 'medium',
    expectedLength: '20-120万字',
    whyNow: `首秀读增 ${item.metrics.readGrowth}，总在读 ${item.metrics.readCount}。`,
    starterHook: item.title,
    risks: ['第三方榜单只能证明市场信号，不能替代拆文验证', '需要进一步拆黄金三章判断真实爽点'],
    nextValidation: '下载或打开作品页，拆黄金三章与前 10 章节奏',
  }));
  return { scanId, candidates };
}

function renderReport(metadata, items, trendSignals, topicCandidates) {
  return [
    `# 网文大数据 · 番茄首秀扫榜`,
    '',
    `- scanId: ${metadata.scanId}`,
    `- source: ${metadata.sourceUrl}`,
    `- capturedAt: ${metadata.capturedAt}`,
    `- count: ${items.length}`,
    `- downloadable: ${items.filter((item) => item.metrics.bookId).length}`,
    '',
    '## 榜单条目',
    ...items.map((item) => `- #${item.rank} [${item.title}](${item.url}) · ${item.author} · ${item.genre} · ${item.heat}`),
    '',
    '## 趋势信号',
    ...trendSignals.signals.map((signal) => `- ${signal.label}: ${signal.evidenceCount}`),
    '',
    '## 候选验证',
    ...topicCandidates.candidates.map((candidate) => `- ${candidate.title}: ${candidate.nextValidation}`),
    '',
  ].join('\n');
}

function validate(dir) {
  const validator = [
    path.resolve(__dirname, '../../../../scripts/scan-json-validate.js'),
    path.resolve(__dirname, '../../../scripts/scan-json-validate.js'),
  ].find((candidate) => fs.existsSync(candidate));
  if (!validator) return;
  const result = spawnSync(process.execPath, [validator, dir], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error((result.stderr || result.stdout || 'scan-json-validate.js failed').trim());
}

function parseTrend(raw) {
  if (!raw) return [];
  try {
    const rows = JSON.parse(String(raw));
    if (!Array.isArray(rows)) return [];
    return rows.flatMap((row) => Object.entries(row || {}).map(([date, value]) => ({ date, value: Number(value || 0) })));
  } catch {
    return [];
  }
}

function normalizeSortField(value) {
  const text = String(value || '').trim();
  const allowed = new Set(['readGrowth', 'wordGrowth', 'readCount', 'wordCount']);
  return allowed.has(text) ? text : 'readGrowth';
}

function parseArgs(argv) {
  const parsed = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--outdir') parsed.outdir = requireValue(argv, ++i, arg);
    else if (arg === '--date' || arg === '--sxDate') parsed.date = requireValue(argv, ++i, arg);
    else if (arg === '--channel' || arg === '--gender') parsed.channel = requireValue(argv, ++i, arg);
    else if (arg === '--category') parsed.category = requireValue(argv, ++i, arg);
    else if (arg === '--keyword') parsed.keyword = requireValue(argv, ++i, arg);
    else if (arg === '--sort-field' || arg === '--sortField' || arg === '--sort') parsed.sortField = requireValue(argv, ++i, arg);
    else if (arg === '--order-by' || arg === '--orderBy' || arg === '--order') parsed.orderBy = requireValue(argv, ++i, arg);
    else if (arg === '--page') parsed.page = requireValue(argv, ++i, arg);
    else if (arg === '--size' || arg === '--limit') parsed.size = requireValue(argv, ++i, arg);
    else if (arg === '--base-url') parsed.baseUrl = requireValue(argv, ++i, arg).replace(/\/+$/, '');
    else if (arg === '--fanqie-base-url') parsed.fanqieBaseUrl = requireValue(argv, ++i, arg).replace(/\/+$/, '');
    else if (arg === '--fixture-list') parsed.fixtureList = requireValue(argv, ++i, arg);
    else if (arg === '--fixture-category') parsed.fixtureCategory = requireValue(argv, ++i, arg);
    else if (arg === '--fixture-fanqie-info-dir') parsed.fixtureFanqieInfoDir = requireValue(argv, ++i, arg);
    else if (arg === '--enrich-fanqie') parsed.enrichFanqie = true;
    else if (arg === '--list-categories') parsed.listCategories = true;
    else if (arg === '--help' || arg === '-h') usage();
    else throw new Error(`unknown argument: ${arg}`);
  }
  return parsed;
}

function requireValue(argv, index, flag) {
  if (index >= argv.length || !argv[index]) throw new Error(`${flag} requires a value`);
  return argv[index];
}

function positiveInt(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

function yesterday() {
  const date = new Date();
  date.setDate(date.getDate() - 1);
  return date.toISOString().slice(0, 10);
}

function dateStamp() {
  return new Date().toISOString().slice(0, 10).replace(/-/g, '');
}

function compactDate(date) {
  return String(date || '').slice(0, 10).replace(/-/g, '') || dateStamp();
}

function dateOnly(value) {
  return String(value || '').slice(0, 10);
}

function slug(value) {
  const ascii = String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (ascii) return ascii;
  return Buffer.from(String(value || '')).toString('hex').slice(0, 16);
}

function usage() {
  console.log(`Usage: node wangwen-debut-scraper.js --outdir DIR [--date YYYY-MM-DD] [--channel male|female] [--category NAME] [--sort-field readGrowth|wordGrowth|readCount|wordCount] [--size 20] [--enrich-fanqie]

Writes v0.8 scan artifacts:
  scan-metadata.json
  ranking-items.jsonl
  trend-signals.json
  topic-candidates.json
  report.md

Notes:
  default source is wangwen_debut, a third-party market list.
  --enrich-fanqie verifies each bookId through Fanqie official /api/book/info.`);
  process.exit(0);
}
