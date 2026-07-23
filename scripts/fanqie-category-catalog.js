#!/usr/bin/env node
/**
 * 番茄分类目录探测器
 *
 * 目标：
 * - 官方长篇/常规小说分类：从 fanqienovel.com/rank 页面解析 /rank/{gender}_{type}_{categoryId}
 * - 首秀/短篇候选分类：从网文大数据 debut category 接口读取，并明确标记为第三方来源
 */

const fs = require('fs');
const path = require('path');

const args = parseArgs(process.argv.slice(2));
const fanqieBaseUrl = args.fanqieBaseUrl || 'https://fanqienovel.com';
const wangwenBaseUrl = args.wangwenBaseUrl || 'https://www.wangwendashuju.com';

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error.message || error);
    process.exit(1);
  });

async function main() {
  const rankHtml = args.fixtureRankHtml
    ? fs.readFileSync(path.resolve(args.fixtureRankHtml), 'utf8')
    : await getText(`${fanqieBaseUrl}/rank/1_2_1141`);
  const appHtml = args.fixtureAppHtml
    ? fs.readFileSync(path.resolve(args.fixtureAppHtml), 'utf8')
    : await tryGetText(`${fanqieBaseUrl}/app_download`);
  const officialCatalogs = buildOfficialRankCatalogs(rankHtml, fanqieBaseUrl);
  const officialAppApiImport = buildOfficialAppApiImportCatalog(readAppCaptureInputs());

  const maleDebut = await readWangwenCategory('male', args.fixtureWangwenMaleCategory);
  const femaleDebut = await readWangwenCategory('female', args.fixtureWangwenFemaleCategory);

  const result = {
    status: 'ok',
    platform: 'fanqie',
    capturedAt: new Date().toISOString(),
    catalogs: {
      ...officialCatalogs,
      official_app_marketing: buildOfficialAppMarketingCatalog(appHtml),
      official_app_api_import: officialAppApiImport,
      third_party_debut_male: buildThirdPartyDebutCatalog('male', maleDebut),
      third_party_debut_female: buildThirdPartyDebutCatalog('female', femaleDebut),
    },
    notes: [
      'official_rank_* 来自 fanqienovel.com/rank 页面，可视为番茄公开 Web 排行榜分类。',
      'official_app_marketing 来自番茄 App 下载/介绍页，可证明 App 展示小说/短剧类型，但不是公开 Web rank 分类。',
      'official_app_api_import 来自用户提供的合法番茄 App API JSON/HAR 抓取文件；未提供时不伪造完整 App 分类树。',
      'third_party_debut_* 来自网文大数据首秀分类，不是番茄官方短篇分类，只能作为市场候选筛选。',
      '公开 Web 端暂未发现等价的番茄官方短篇分类榜单入口；若要复刻手机 App 内分类，需要导入 App API JSON/HAR 或接入合法可访问接口。',
    ],
  };

  if (args.outdir) {
    fs.mkdirSync(path.resolve(args.outdir), { recursive: true });
    fs.writeFileSync(path.join(path.resolve(args.outdir), 'fanqie-category-catalog.json'), JSON.stringify(result, null, 2) + '\n', 'utf8');
  }

  if (args.json || !args.outdir) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    console.log(`fanqie category catalog written: ${path.join(path.resolve(args.outdir), 'fanqie-category-catalog.json')}`);
  }
}

function buildOfficialRankCatalogs(html, baseUrl) {
  const rows = parseRankAnchors(html, baseUrl);
  return {
    official_rank_male_reading: buildRankCatalog(rows, '1', '2', '男频阅读榜'),
    official_rank_male_newbook: buildRankCatalog(rows, '1', '1', '男频新书榜'),
    official_rank_female_reading: buildRankCatalog(rows, '0', '2', '女频阅读榜'),
    official_rank_female_newbook: buildRankCatalog(rows, '0', '1', '女频新书榜'),
  };
}

function parseRankAnchors(html, baseUrl = 'https://fanqienovel.com') {
  const rows = [];
  const seen = new Set();
  const re = /<a\b[^>]*href=["']\/rank\/(\d+)_(\d+)_(\d+)["'][^>]*>([\s\S]*?)<\/a>/g;
  let match;
  while ((match = re.exec(String(html || ''))) !== null) {
    const channel = match[1];
    const rankType = match[2];
    const id = match[3];
    const name = stripHtml(match[4]);
    if (!name) continue;
    const key = `${channel}_${rankType}_${id}_${name}`;
    if (seen.has(key)) continue;
    seen.add(key);
    rows.push({
      id,
      name,
      channel: channel === '1' ? 'male' : 'female',
      rankType: rankType === '2' ? 'reading' : 'newbook',
      url: `${baseUrl}/rank/${channel}_${rankType}_${id}`,
    });
  }
  return rows;
}

function buildRankCatalog(rows, channel, rankType, label) {
  const categories = rows
    .filter((row) => row.channel === (channel === '1' ? 'male' : 'female') && row.rankType === (rankType === '2' ? 'reading' : 'newbook'))
    .map(({ id, name, url }) => ({ id, name, url }));
  return {
    source: 'fanqie_rank_html',
    official: true,
    label,
    categories,
  };
}

async function readWangwenCategory(channel, fixturePath) {
  if (fixturePath) {
    return parseWangwenCategory(fs.readFileSync(path.resolve(fixturePath), 'utf8'));
  }
  try {
    const female = channel === 'female';
    const raw = await postJson(`${wangwenBaseUrl}/api/debut/category`, {
      media: female ? 'fqmm' : 'fq',
      gender: female ? 0 : 1,
      sxDate: args.date || yesterday(),
    });
    return parseWangwenCategory(raw);
  } catch (error) {
    return { error: error.message || String(error), categories: [] };
  }
}

function parseWangwenCategory(raw) {
  const parsed = JSON.parse(raw);
  if (Number(parsed.code) !== 200 || !Array.isArray(parsed.data)) return { categories: [] };
  return {
    categories: parsed.data
      .map((row) => ({
        name: String(row.name || row.category || '').trim(),
        count: Number(row.count || row.total || 0),
      }))
      .filter((row) => row.name),
  };
}

function buildThirdPartyDebutCatalog(channel, parsed) {
  return {
    source: 'wangwen_debut',
    official: false,
    label: channel === 'female' ? '网文大数据番茄女频首秀分类' : '网文大数据番茄男频首秀分类',
    categories: parsed.categories || [],
    ...(parsed.error ? { warning: parsed.error } : {}),
  };
}

async function getText(url) {
  const response = await fetch(url, { headers: { 'user-agent': 'Mozilla/5.0' } });
  const text = await response.text();
  if (!response.ok) throw new Error(`GET ${url} status ${response.status}: ${text.slice(0, 200)}`);
  return text;
}

async function tryGetText(url) {
  try {
    return await getText(url);
  } catch {
    return '';
  }
}

function buildOfficialAppMarketingCatalog(htmlText) {
  const text = stripHtml(htmlText);
  return {
    source: 'fanqie_app_download',
    official: true,
    label: '番茄 App 公开介绍页类型展示',
    novelCategories: pickKnownTerms(text, ['都市爽文', '言情穿越', '玄幻修仙', '武侠世界']),
    shortDramaCategories: pickKnownTerms(text, ['都市热血', '甜宠言情', '职场婚恋', '逆袭反转', '逆天改命']),
    caveat: '这是 App 公开介绍页展示的类型词，不是完整 App 内分类树，也不是 /rank 分类。',
  };
}

function pickKnownTerms(text, terms) {
  return terms.filter((term) => String(text || '').includes(term));
}

function readAppCaptureInputs() {
  const captures = [];
  const jsonPath = args.appApiJson || args.fixtureAppApiJson;
  const harPath = args.appHar || args.fixtureAppHar;
  if (jsonPath) {
    captures.push({
      kind: 'json',
      file: path.resolve(jsonPath),
      value: JSON.parse(fs.readFileSync(path.resolve(jsonPath), 'utf8')),
    });
  }
  if (harPath) {
    const har = JSON.parse(fs.readFileSync(path.resolve(harPath), 'utf8'));
    for (const entry of (((har || {}).log || {}).entries || [])) {
      const text = (((entry || {}).response || {}).content || {}).text;
      if (!text) continue;
      const decoded = (((entry || {}).response || {}).content || {}).encoding === 'base64'
        ? Buffer.from(text, 'base64').toString('utf8')
        : text;
      const parsed = tryParseJson(decoded);
      if (!parsed) continue;
      captures.push({
        kind: 'har',
        file: path.resolve(harPath),
        sourceUrl: (((entry || {}).request || {}).url || ''),
        value: parsed,
      });
    }
  }
  return captures;
}

function buildOfficialAppApiImportCatalog(captures) {
  if (!captures.length) {
    return {
      source: 'fanqie_app_api_capture',
      official: true,
      status: 'not_configured',
      label: '番茄 App API 分类导入',
      categories: [],
      caveat: '未提供 App API JSON/HAR 抓取文件；不会猜测或伪造完整 App 内分类树。',
    };
  }

  const categories = [];
  for (const capture of captures) {
    categories.push(...extractCategoryRows(capture.value, {
      sourceFile: capture.file,
      sourceUrl: capture.sourceUrl || '',
    }));
  }

  return {
    source: 'fanqie_app_api_capture',
    official: true,
    status: categories.length ? 'imported' : 'empty',
    label: '番茄 App API 分类导入',
    categories: dedupeCategoryRows(categories),
    caveat: '分类来自用户提供的合法 App API JSON/HAR 抓取文件；报告必须保留 sourceFile/sourceUrl，便于复核来源。',
  };
}

function extractCategoryRows(value, context = {}, pathParts = [], sectionStack = []) {
  if (!value || typeof value !== 'object') return [];
  if (Array.isArray(value)) {
    return extractCategoryArray(value, context, pathParts, sectionStack);
  }

  const rows = [];
  const localSection = categoryNameOf(value);
  const nextSectionStack = localSection && hasChildCategoryArray(value)
    ? [...sectionStack, localSection]
    : sectionStack;
  for (const [key, child] of Object.entries(value)) {
    rows.push(...extractCategoryRows(child, context, [...pathParts, key], nextSectionStack));
  }
  return rows;
}

function extractCategoryArray(array, context, pathParts, sectionStack) {
  const rows = [];
  const arrayLooksLikeCategories = array.some((row) => row && typeof row === 'object' && categoryNameOf(row));
  for (let index = 0; index < array.length; index += 1) {
    const row = array[index];
    const rowPath = [...pathParts, `[${index}]`];
    if (row && typeof row === 'object') {
      const name = categoryNameOf(row);
      const id = categoryIdOf(row);
      const isCategory = name && (id || (arrayLooksLikeCategories && !hasChildCategoryArray(row)));
      if (isCategory) {
        rows.push({
          id: id || stableId(name, rowPath),
          name,
          section: sectionStack[sectionStack.length - 1] || inferSection(pathParts),
          path: formatPath(rowPath),
          sourceFile: context.sourceFile,
          ...(context.sourceUrl ? { sourceUrl: context.sourceUrl } : {}),
        });
      }
      const nextStack = name && hasChildCategoryArray(row) ? [...sectionStack, name] : sectionStack;
      for (const [key, child] of Object.entries(row)) {
        rows.push(...extractCategoryRows(child, context, [...rowPath, key], nextStack));
      }
    }
  }
  return rows;
}

function categoryNameOf(row) {
  return firstString(row, ['category_name', 'categoryName', 'name', 'title', 'label']);
}

function categoryIdOf(row) {
  const value = firstScalar(row, ['category_id', 'categoryId', 'bookCategoryId', 'id', 'value']);
  return value == null ? '' : String(value).trim();
}

function firstString(row, keys) {
  const value = firstScalar(row, keys);
  return typeof value === 'string' ? value.trim() : '';
}

function firstScalar(row, keys) {
  if (!row || typeof row !== 'object') return undefined;
  for (const key of keys) {
    if (Object.prototype.hasOwnProperty.call(row, key) && row[key] != null && typeof row[key] !== 'object') return row[key];
  }
  return undefined;
}

function hasChildCategoryArray(row) {
  if (!row || typeof row !== 'object') return false;
  return ['categories', 'categoryList', 'category_list', 'children', 'tabs', 'list'].some((key) => Array.isArray(row[key]));
}

function inferSection(pathParts) {
  const pathText = pathParts.join('.');
  if (/short|duanju|drama|短剧/i.test(pathText)) return '短剧';
  if (/short|story|短篇/i.test(pathText)) return '短篇';
  return '未分组';
}

function formatPath(parts) {
  return parts.join('.').replace(/\.\[/g, '[');
}

function stableId(name, pathParts) {
  return `${pathParts.join('.')}:${name}`;
}

function dedupeCategoryRows(rows) {
  const seen = new Set();
  const result = [];
  for (const row of rows) {
    const key = `${row.section}|${row.id}|${row.name}|${row.sourceUrl || ''}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(row);
  }
  return result;
}

function tryParseJson(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'origin': wangwenBaseUrl,
      'referer': `${wangwenBaseUrl}/fq/debut`,
      'user-agent': 'Mozilla/5.0',
    },
    body: JSON.stringify(payload),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`POST ${url} status ${response.status}: ${text.slice(0, 200)}`);
  return text;
}

function stripHtml(value) {
  return String(value || '').replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
}

function yesterday() {
  const date = new Date();
  date.setDate(date.getDate() - 1);
  return date.toISOString().slice(0, 10);
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--json') parsed.json = true;
    else if (arg === '--outdir') parsed.outdir = requireValue(argv, ++index, arg);
    else if (arg === '--date') parsed.date = requireValue(argv, ++index, arg);
    else if (arg === '--fanqie-base-url') parsed.fanqieBaseUrl = requireValue(argv, ++index, arg).replace(/\/+$/, '');
    else if (arg === '--wangwen-base-url') parsed.wangwenBaseUrl = requireValue(argv, ++index, arg).replace(/\/+$/, '');
    else if (arg === '--fixture-rank-html') parsed.fixtureRankHtml = requireValue(argv, ++index, arg);
    else if (arg === '--fixture-app-html') parsed.fixtureAppHtml = requireValue(argv, ++index, arg);
    else if (arg === '--app-api-json') parsed.appApiJson = requireValue(argv, ++index, arg);
    else if (arg === '--app-har') parsed.appHar = requireValue(argv, ++index, arg);
    else if (arg === '--fixture-app-api-json') parsed.fixtureAppApiJson = requireValue(argv, ++index, arg);
    else if (arg === '--fixture-app-har') parsed.fixtureAppHar = requireValue(argv, ++index, arg);
    else if (arg === '--fixture-wangwen-male-category') parsed.fixtureWangwenMaleCategory = requireValue(argv, ++index, arg);
    else if (arg === '--fixture-wangwen-female-category') parsed.fixtureWangwenFemaleCategory = requireValue(argv, ++index, arg);
    else if (arg === '--help' || arg === '-h') usage();
    else throw new Error(`unknown argument: ${arg}`);
  }
  return parsed;
}

function requireValue(argv, index, flag) {
  if (index >= argv.length || !argv[index]) throw new Error(`${flag} requires a value`);
  return argv[index];
}

function usage() {
  console.log(`Usage: node fanqie-category-catalog.js [--json] [--outdir DIR] [--date YYYY-MM-DD]

Outputs:
  official_rank_male_reading/newbook
  official_rank_female_reading/newbook
  official_app_marketing
  official_app_api_import
  third_party_debut_male/female

Notes:
  official_rank_* comes from fanqienovel.com/rank public HTML.
  official_app_api_import is only populated from --app-api-json/--app-har user-provided legal App captures.
  third_party_debut_* comes from wangwendashuju.com and is not official Fanqie shortform taxonomy.`);
  process.exit(0);
}

module.exports = {
  parseRankAnchors,
  buildOfficialRankCatalogs,
  parseWangwenCategory,
  extractCategoryRows,
};
