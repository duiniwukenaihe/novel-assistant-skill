#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const {
  ensureDir,
  readText,
  nowIso,
  stripMarkdownBullet,
  writeJson,
  writeJsonl,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const markdownFile = firstPositional(args, ['--outdir', '--platform', '--channel', '--list-name', '--type', '--capture-mode']);
if (!markdownFile) fail('usage: scan-artifact-build.js <markdown-file> --outdir DIR [--platform manual] [--channel unknown] [--list-name imported] [--type long] [--capture-mode manual]');

const outdir = requireOption('--outdir');
const platform = readOption('--platform', 'manual');
const channel = readOption('--channel', 'unknown');
const listName = readOption('--list-name', 'imported');
const contentType = readOption('--type', 'long');
const captureMode = readOption('--capture-mode', 'manual');
if (!['long', 'short'].includes(contentType)) fail('--type must be long or short');

const artifacts = buildScanArtifacts(path.resolve(markdownFile), {
  outdir: path.resolve(outdir),
  platform,
  channel,
  listName,
  contentType,
  captureMode,
});
writeScanArtifacts(artifacts);
validateArtifacts(artifacts.outdir);
console.log(`scan artifacts built: ${artifacts.metadata.scanId} (${artifacts.items.length} items)`);

function buildScanArtifacts(file, options) {
  const text = readText(file);
  const capturedAt = nowIso();
  const scanId = `${datePart(capturedAt)}-${options.platform}-${slug(options.listName)}`;
  const items = parseItems(text).map(item => ({
    rank: item.rank,
    title: item.title,
    author: item.author || '未知作者',
    url: item.url || 'https://example.com/',
    genre: item.genre || '未分类',
    tags: splitTags(item.genre),
    summary: item.reason || item.title,
    metrics: {},
    signals: item.reason ? [item.reason] : [],
    dataQuality: item.author && item.url ? 'ok' : 'sparse',
  }));

  const warnings = [];
  for (const item of items) {
    if (item.dataQuality !== 'ok') warnings.push(`#${item.rank} ${item.title} missing author or url`);
  }

  const metadata = {
    schemaVersion: '0.8.0',
    scanId,
    platform: options.platform,
    platformName: platformName(options.platform),
    channel: options.channel,
    board: options.listName,
    contentLength: options.contentType,
    sourceUrl: items.find(item => item.url)?.url || '',
    captureMode: options.captureMode,
    capturedAt,
    dataQuality: {
      status: validatorStatus(items, warnings),
      completeness: completenessStatus(items, warnings),
      validItems: items.filter(item => item.dataQuality === 'ok').length,
      rawItems: items.length,
      warnings,
    },
  };

  const tagCounts = countTags(items);
  const signals = tagCounts.slice(0, 5).map(([tag, count], index) => ({
    id: `S-${slug(tag) || `signal-${index + 1}`}`,
    kind: 'genre',
    label: tag,
    strength: Math.min(1, Math.max(0.1, count / items.length)),
    evidenceCount: count,
    representativeTitles: items.filter(item => item.tags.includes(tag)).slice(0, 3).map(item => item.title),
  }));
  if (signals.length === 0) {
    signals.push({
      id: 'S-manual-scan',
      kind: 'manual',
      label: '手动扫榜样本',
      strength: 0.5,
      evidenceCount: items.length,
      representativeTitles: items.slice(0, 3).map(item => item.title),
    });
  }

  const candidates = items.slice(0, 3).map((item, index) => ({
    id: `T-${slug(item.title) || `topic-${index + 1}`}`,
    title: `${item.title} 方向验证`,
    platformFit: [options.platform],
    difficulty: 'medium',
    expectedLength: options.contentType === 'long' ? '80-150万字' : '8000-30000字',
    whyNow: item.summary,
    starterHook: item.title,
    risks: ['需要继续拆解同类样本验证差异化'],
    nextValidation: '拆解榜单前三作品黄金开篇',
  }));

  return {
    outdir: options.outdir,
    metadata,
    items,
    trendSignals: {
      scanId,
      signals,
    },
    topicCandidates: {
      scanId,
      candidates,
    },
    summary: renderSummary(metadata, items, signals, candidates),
  };
}

function parseItems(text) {
  const items = [];
  let current = null;
  let nextRank = 1;
  function finishCurrent() {
    if (!current) return;
    const hasEvidence = current._definite || current.author || current.genre || current.reason || current.url;
    if (hasEvidence) {
      if (!current.rank) current.rank = nextRank;
      nextRank = Math.max(nextRank, current.rank + 1);
      delete current._definite;
      items.push(current);
    }
    current = null;
  }
  for (const line of String(text || '').split(/\r?\n/)) {
    const heading = line.match(/^(#{2,3})\s+(?:#(\d+)\s+)?(.+?)\s*$/);
    if (heading) {
      finishCurrent();
      const level = heading[1].length;
      const explicitRank = heading[2] ? Number(heading[2]) : null;
      if (level === 2 && !explicitRank) continue;
      current = {
        rank: explicitRank,
        title: heading[3].trim(),
        _definite: Boolean(explicitRank) || level === 3,
      };
      continue;
    }
    if (!current) continue;
    const clean = stripMarkdownBullet(line);
    const url = clean.match(/https?:\/\/[^\s)）]+/);
    if (url && !current.url) current.url = url[0];
    const field = clean.match(/^(作者|类型|榜单理由|作品页)[：:]\s*(.+?)\s*$/);
    if (!field) continue;
    if (field[1] === '作者') current.author = field[2].trim();
    if (field[1] === '类型') current.genre = field[2].trim();
    if (field[1] === '榜单理由') current.reason = field[2].trim();
    if (field[1] === '作品页') current.url = field[2].trim();
  }
  finishCurrent();
  return items;
}

function writeScanArtifacts(artifacts) {
  ensureDir(artifacts.outdir);
  writeJson(path.join(artifacts.outdir, 'scan-metadata.json'), artifacts.metadata);
  writeJsonl(path.join(artifacts.outdir, 'ranking-items.jsonl'), artifacts.items);
  writeJson(path.join(artifacts.outdir, 'trend-signals.json'), artifacts.trendSignals);
  writeJson(path.join(artifacts.outdir, 'topic-candidates.json'), artifacts.topicCandidates);
  fs.writeFileSync(path.join(artifacts.outdir, 'summary.md'), artifacts.summary, 'utf8');
}

function validateArtifacts(outdir) {
  const result = spawnSync(process.execPath, [path.join(__dirname, 'scan-json-validate.js'), outdir], { encoding: 'utf8' });
  if (result.status !== 0) {
    const message = (result.stderr || result.stdout || 'scan-json-validate.js failed').trim();
    fail(message);
  }
}

function splitTags(genre) {
  return String(genre || '')
    .split(/[\/,，、|]+/)
    .map(part => part.trim())
    .filter(Boolean);
}

function countTags(items) {
  const counts = new Map();
  for (const item of items) {
    for (const tag of item.tags) counts.set(tag, (counts.get(tag) || 0) + 1);
  }
  return Array.from(counts.entries()).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'zh-Hans-CN'));
}

function renderSummary(metadata, items, signals, candidates) {
  return [
    `# ${metadata.platformName} ${metadata.board} 扫榜摘要`,
    '',
    `- scanId: ${metadata.scanId}`,
    `- items: ${items.length}`,
    `- dataQuality: ${metadata.dataQuality.status}`,
    '',
    '## Trend Signals',
    ...signals.map(signal => `- ${signal.label}: ${signal.evidenceCount}`),
    '',
    '## Topic Candidates',
    ...candidates.map(candidate => `- ${candidate.title}`),
    '',
  ].join('\n');
}

function platformName(platform) {
  const names = {
    qidian: '起点中文网',
    fanqie: '番茄小说',
    jjwxc: '晋江文学城',
    zhihu: '知乎盐言',
    manual: '手动导入',
  };
  return names[platform] || platform;
}

function slug(value) {
  const ascii = String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (ascii) return ascii;
  return Buffer.from(String(value || '')).toString('hex').slice(0, 16);
}

function datePart(iso) {
  return iso.slice(0, 10).replace(/-/g, '');
}

function requireOption(name) {
  const index = args.indexOf(name);
  if (index === -1 || !args[index + 1] || args[index + 1].startsWith('--')) fail(`missing ${name}`);
  return args[index + 1];
}

function readOption(name, fallback) {
  const index = args.indexOf(name);
  if (index === -1 || !args[index + 1] || args[index + 1].startsWith('--')) return fallback;
  return args[index + 1];
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

function validatorStatus(items, warnings) {
  if (items.length === 0) return 'failed';
  if (warnings.length === 0) return 'ok';
  if (items.some(item => item.dataQuality === 'ok')) return 'partial';
  return 'sparse';
}

function completenessStatus(items, warnings) {
  if (items.length === 0) return 'insufficient';
  if (items.length < 20) return 'partial';
  return 'complete';
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

module.exports = { buildScanArtifacts };
