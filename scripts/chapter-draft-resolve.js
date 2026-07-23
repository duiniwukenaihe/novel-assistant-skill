#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node chapter-draft-resolve.js <book-dir> <chapter-no> [--volume 第1卷] [--json]

Resolve the actual prose draft path after narrative-writer writes a chapter.
Uses .book-state.json chapterLayout when available: flat keeps legacy drafts
such as 正文/第007章_章名.md; volume prefers 正文/第1卷/第007章_章名.md.
Fails on missing or ambiguous candidates so the caller does not verify a guessed path.
`;

const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const positional = args.filter(arg => !arg.startsWith('--') && !isOptionValue(arg));
const bookDir = positional[0];
const chapterNo = Number(positional[1] || 0);
const requestedVolume = readOption('--volume') || '';

if (!bookDir || !chapterNo || args.includes('-h') || args.includes('--help')) {
  if (args.includes('-h') || args.includes('--help')) {
    console.log(USAGE.trimEnd());
    process.exit(0);
  }
  fail('usage: chapter-draft-resolve.js <book-dir> <chapter-no> [--volume 第1卷]');
}

const root = path.resolve(bookDir);
const state = readBookState(root);
const volume = requestedVolume || state.preferredVolume || '第1卷';
const result = resolveDraft(root, chapterNo, volume, state);
if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else if (result.status === 'ok') {
  console.log(result.relPath);
} else {
  console.error(`${result.status}: ${result.message}`);
  for (const candidate of result.candidates || []) console.error(`- ${candidate.relPath}`);
}
process.exit(result.status === 'ok' ? 0 : 2);

function readOption(name) {
  const eq = args.find(arg => arg.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] || '' : '';
}

function isOptionValue(arg) {
  const index = args.indexOf(arg);
  return index > 0 && args[index - 1] === '--volume';
}

function resolveDraft(bookRoot, targetChapterNo, targetVolume, state) {
  const all = collectDrafts(bookRoot);
  const layout = inferLayout(state, all, targetChapterNo, targetVolume);
  const volumeDrafts = all.filter(item => item.volume === targetVolume && item.volumeLocal);
  if (layout === 'volume' && isGlobalNumberedVolume(targetVolume, volumeDrafts)) {
    return problem('noncanonical', `${targetVolume} 卷目录使用全书连续编号；第2卷应从第001章开始。请先做卷内重编号/结构迁移，或明确保持旧结构兼容后再继续。`, volumeDrafts, layout);
  }
  const volumeLocal = all.filter(item => item.volume === targetVolume && item.chapterNo === targetChapterNo && item.volumeLocal);
  const flat = all.filter(item => item.chapterNo === targetChapterNo && !item.volumeLocal);

  if (layout === 'flat') {
    if (flat.length === 1) return ok(flat[0], layout);
    if (flat.length > 1) {
      return problem('ambiguous', `旧扁平结构第${targetChapterNo}章存在多个正文候选。请保留唯一正文或在 .book-state.json 指定 chapterLayout。`, flat, layout);
    }
  }

  if (volumeLocal.length === 1) return ok(volumeLocal[0]);
  if (volumeLocal.length > 1) {
    return problem('ambiguous', `同卷同章存在多个正文候选：${targetVolume} 第${targetChapterNo}章。请保留唯一 canonical 正文。`, volumeLocal, layout);
  }

  const sameChapter = all.filter(item => item.chapterNo === targetChapterNo);
  if (sameChapter.length === 1) {
    const only = sameChapter[0];
    if (!only.volumeLocal && state.allowLegacyFlat !== false) return ok(only, 'flat');
    return problem('noncanonical', `找不到 ${targetVolume} 的卷内正文；发现其他结构候选。请确认 .book-state.json 的 chapterLayout 或迁移后再继续。`, sameChapter, layout);
  }
  if (sameChapter.length > 1) {
    return problem('ambiguous', `找不到 ${targetVolume} 的唯一卷内正文，且第${targetChapterNo}章存在多个候选。请确认当前项目使用 flat 还是 volume 结构。`, sameChapter, layout);
  }

  return problem('missing', `未找到 ${targetVolume} 第${String(targetChapterNo).padStart(3, '0')}章正文。narrative-writer 可能未落盘、写入了错误目录，或只返回了 Done。`, [], layout);
}

function readBookState(bookRoot) {
  const file = path.join(bookRoot, '.book-state.json');
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return {
      chapterLayout: normalizeLayout(parsed.chapterLayout || parsed.draftPathMode || ''),
      preferredVolume: typeof parsed.preferredVolume === 'string' && parsed.preferredVolume.trim() ? parsed.preferredVolume.trim() : '',
      allowLegacyFlat: parsed.allowLegacyFlat !== false,
    };
  } catch {
    return { chapterLayout: 'auto', preferredVolume: '', allowLegacyFlat: true };
  }
}

function normalizeLayout(value) {
  const text = String(value || '').trim().toLowerCase();
  if (['flat', 'legacy', 'legacy-flat', 'legacy_flat'].includes(text)) return 'flat';
  if (['volume', 'volume-local', 'volume_local', '卷内'].includes(text)) return 'volume';
  return 'auto';
}

function inferLayout(state, drafts, targetChapterNo, targetVolume) {
  if (state.chapterLayout === 'flat') return 'flat';
  if (state.chapterLayout === 'volume') return 'volume';
  const chapterDrafts = drafts.filter(item => item.chapterNo === targetChapterNo);
  if (chapterDrafts.some(item => item.volumeLocal && item.volume === targetVolume)) return 'volume';
  if (chapterDrafts.length && chapterDrafts.every(item => !item.volumeLocal)) return 'flat';
  return 'auto';
}

function collectDrafts(bookRoot) {
  const base = path.join(bookRoot, '正文');
  const files = [];
  walk(base, file => {
    const relPath = slash(path.relative(bookRoot, file));
    const baseName = path.basename(relPath);
    if (!/^第.+章.*\.(md|txt)$/i.test(baseName)) return;
    if (/\.bak/i.test(baseName) || relPath.includes('/legacy-flat-layout/')) return;
    const chapterNo = parseChapterNo(baseName);
    if (!chapterNo) return;
    files.push({
      absPath: file,
      relPath,
      chapterNo,
      volume: inferVolume(relPath),
      volumeLocal: isVolumeLocalPath(relPath),
      sizeBytes: safeStat(file)?.size || 0,
    });
  });
  return files.sort(compareDrafts);
}

function walk(dir, visit) {
  if (!fs.existsSync(dir)) return;
  for (const name of fs.readdirSync(dir)) {
    const abs = path.join(dir, name);
    const stat = safeStat(abs);
    if (!stat) continue;
    if (stat.isDirectory()) walk(abs, visit);
    else if (stat.isFile()) visit(abs);
  }
}

function safeStat(file) {
  try {
    return fs.statSync(file);
  } catch {
    return null;
  }
}

function parseChapterNo(base) {
  const match = String(base).match(/第\s*0*(\d+)\s*章/);
  return match ? Number(match[1]) : 0;
}

function inferVolume(relPath) {
  return slash(relPath).split('/').find(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part)) || '第1卷';
}

function isVolumeLocalPath(relPath) {
  return slash(relPath).split('/').some(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part));
}

function compareDrafts(a, b) {
  return volumeOrder(a.volume) - volumeOrder(b.volume)
    || a.chapterNo - b.chapterNo
    || a.relPath.localeCompare(b.relPath, 'zh-CN');
}

function volumeOrder(volumeName) {
  const arabic = String(volumeName).match(/第\s*([0-9]+)\s*卷/);
  if (arabic) return Number(arabic[1]);
  const chinese = String(volumeName).match(/第\s*([一二三四五六七八九十两]+)\s*卷/);
  if (!chinese) return 1;
  return chineseNumber(chinese[1]);
}

function isGlobalNumberedVolume(volumeName, volumeDrafts) {
  if (volumeOrder(volumeName) <= 1) return false;
  if (!volumeDrafts.length) return false;
  const numbers = volumeDrafts.map(item => item.chapterNo).filter(Boolean);
  if (!numbers.length) return false;
  return Math.min(...numbers) > 1 && !numbers.includes(1);
}

function chineseNumber(text) {
  const values = { 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  if (text === '十') return 10;
  const ten = text.indexOf('十');
  if (ten >= 0) {
    const left = text.slice(0, ten);
    const right = text.slice(ten + 1);
    return (left ? values[left] : 1) * 10 + (right ? values[right] : 0);
  }
  return values[text] || 1;
}

function ok(item, layout) {
  return {
    status: 'ok',
    relPath: item.relPath,
    absPath: item.absPath,
    volume: item.volume,
    chapterNo: item.chapterNo,
    layout: layout || (item.volumeLocal ? 'volume' : 'flat'),
    volumeLocal: item.volumeLocal,
    sizeBytes: item.sizeBytes,
  };
}

function problem(status, message, candidates, layout) {
  return {
    status,
    message,
    layout,
    candidates: candidates.map(item => ({
      relPath: item.relPath,
      volume: item.volume,
      chapterNo: item.chapterNo,
      volumeLocal: item.volumeLocal,
      sizeBytes: item.sizeBytes,
    })),
  };
}

function fail(message) {
  if (jsonOutput) process.stdout.write(`${JSON.stringify({ status: 'error', message }, null, 2)}\n`);
  else console.error(message);
  process.exit(2);
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}
