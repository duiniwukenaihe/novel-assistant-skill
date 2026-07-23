#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const childProcess = require('child_process');
const {
  readText,
  readJson,
  readDirSafe,
  parseChapterNo,
} = require('./lib/oh-story-artifacts');
const { buildDomainProfile } = require('./story-domain-profile');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--'));
if (!projectRoot || args.includes('-h') || args.includes('--help')) {
  console.log('Usage: node story-progress-status.js <book-project-dir> [--json]');
  process.exit(projectRoot ? 0 : 1);
}

const root = path.resolve(projectRoot);
const jsonOutput = args.includes('--json');
const result = buildProgressStatus(root);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  printHuman(result);
}

process.exit(result.status === 'ok' ? 0 : 2);

function buildProgressStatus(projectDir) {
  const state = readBookState(projectDir);
  const domainProfile = buildDomainProfile(projectDir);
  const drafts = collectChapterFiles(projectDir, '正文', /^第.+章.*\.(md|txt)$/);
  const mixed = detectMixedVolumeLayout(projectDir, drafts, state);
  if (mixed) return { ...mixed, domainProfile };

  const assets = readAssets(projectDir);
  const chapters = assets.length ? assets : buildAssetsFromDrafts(drafts);
  if (!chapters.length) {
    return {
      status: 'missing_chapters',
      message: '未找到正文章节文件，无法确认当前写作进度。',
      nextActions: ['检查目标书目录', '运行写作协作环境更新', '导入或创建章节'],
    };
  }

  const latest = chapters.slice().sort(compareAssetProgress).at(-1);
  const volume = latest.volume || state.currentVolume || state.preferredVolume || '第1卷';
  const volumeChapterNo = Number(latest.volumeChapterNo || latest.chapterNo || 0);
  const globalDraftOrder = Number(latest.globalDraftOrder || latest.chapterNo || chapters.length);
  const title = latest.title || inferTitleFromPath(latest.draftPath || '');
  const display = `${volume}第${pad(volumeChapterNo)}章${title ? `《${title}》` : ''}（全书草稿顺序第${globalDraftOrder}章）`;

  return {
    status: 'ok',
    chapterLayout: normalizeLayout(state.chapterLayout || 'auto'),
    currentVolume: volume,
    currentVolumeChapter: volumeChapterNo,
    globalDraftOrder,
    title,
    currentDraftPath: latest.draftPath || '',
    currentOutline: latest.outlinePath || state.currentOutline || '',
    completedChapters: chapters.length,
    display,
    domainProfile,
    warnings: staleStateWarnings(state, latest),
  };
}

function readBookState(projectDir) {
  return readJson(path.join(projectDir, '.book-state.json'), {}) || {};
}

function readAssets(projectDir) {
  const text = readText(path.join(projectDir, '追踪', '章节资产.jsonl'), '');
  return text.split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function buildAssetsFromDrafts(drafts) {
  return drafts.slice().sort(compareChapterFiles).map((draft, index) => ({
    title: inferTitleFromFile(draft.absPath, draft.relPath),
    volume: draft.volume,
    volumeChapterNo: draft.chapterNo,
    globalDraftOrder: index + 1,
    draftPath: draft.relPath,
  }));
}

function collectChapterFiles(projectDir, relDir, pattern) {
  const baseDir = path.join(projectDir, relDir);
  const files = [];
  walk(baseDir, relDir, file => {
    const base = path.basename(file.relPath);
    if (!pattern.test(base)) return;
    const chapterNo = parseChapterNo(base);
    if (!chapterNo) return;
    files.push({
      ...file,
      chapterNo,
      volume: inferVolume(file.relPath),
      volumeLocal: isVolumeLocalPath(file.relPath),
    });
  });
  return files;
}

function walk(absDir, relDir, visit) {
  for (const name of readDirSafe(absDir)) {
    const absPath = path.join(absDir, name);
    const relPath = path.join(relDir, name);
    let stat;
    try {
      stat = fs.statSync(absPath);
    } catch {
      continue;
    }
    if (stat.isDirectory()) walk(absPath, relPath, visit);
    else if (stat.isFile()) visit({ absPath, relPath: slash(relPath) });
  }
}

function detectMixedVolumeLayout(projectDir, drafts, state) {
  const layout = normalizeLayout(state.chapterLayout || 'auto');
  const byVolume = new Map();
  for (const draft of drafts) {
    if (!draft.volumeLocal || volumeOrder(draft.volume) <= 1) continue;
    const list = byVolume.get(draft.volume) || [];
    list.push(draft);
    byVolume.set(draft.volume, list);
  }

  for (const [volume, files] of byVolume.entries()) {
    const sorted = files.slice().sort(compareChapterFiles);
    const first = sorted[0]?.chapterNo || 0;
    if (layout === 'volume' && first > 1) {
      return mixedResult(projectDir, volume, sorted);
    }
    if (layout === 'auto' && first > sorted.length + 1 && first > 10) {
      return mixedResult(projectDir, volume, sorted);
    }
  }
  return null;
}

function mixedResult(projectDir, volume, draftFiles) {
  const preview = migrationPreview(projectDir);

  return {
    status: 'blocked_mixed_chapter_layout',
    volume,
    message: `${volume} 使用了卷目录，但章节文件仍是全书连续编号。不能继续按第${pad(draftFiles.at(-1)?.chapterNo || 0)}章报告当前卷进度。`,
    reason: 'volume_directory_with_global_chapter_numbers',
    migrationStatus: preview.status || '',
    migrationActions: preview.actions || fallbackMigrationActions(volume, draftFiles),
    referenceUpdates: preview.referenceUpdates || [],
    conflicts: preview.conflicts || [],
    nextActions: [
      '迁移到卷内编号结构',
      '保持旧结构兼容',
      '先查看迁移预览',
    ],
  };
}

function migrationPreview(projectDir) {
  const script = path.join(__dirname, 'story-project-migrate.js');
  try {
    const output = childProcess.execFileSync(process.execPath, [script, projectDir, '--json'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 10 * 1024 * 1024,
    });
    return JSON.parse(output);
  } catch {
    return {};
  }
}

function fallbackMigrationActions(volume, draftFiles) {
  const renumberMap = new Map(draftFiles.map((file, index) => [file.chapterNo, index + 1]));
  return draftFiles.map(file => ({
    source: file.relPath,
    target: slash(path.join('正文', volume, replaceChapterNo(path.basename(file.relPath), file.chapterNo, renumberMap.get(file.chapterNo)))),
  }));
}

function staleStateWarnings(state, latest) {
  const warnings = [];
  const currentChapter = Number(state.currentChapter || 0);
  const globalDraftOrder = Number(latest.globalDraftOrder || 0);
  if (currentChapter && globalDraftOrder && currentChapter !== globalDraftOrder) {
    warnings.push({
      code: 'stale_currentChapter',
      message: `.book-state.json currentChapter=${currentChapter} 与章节资产 globalDraftOrder=${globalDraftOrder} 不一致，状态回答已采用章节资产。`,
    });
  }
  return warnings;
}

function normalizeLayout(value) {
  const text = String(value || '').trim().toLowerCase();
  if (['flat', 'legacy', 'legacy-flat', 'legacy_flat'].includes(text)) return 'flat';
  if (['volume', 'volume-local', 'volume_local', '卷内'].includes(text)) return 'volume';
  return 'auto';
}

function inferVolume(relPath) {
  return slash(relPath).split('/').find(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part)) || '第1卷';
}

function isVolumeLocalPath(relPath) {
  return slash(relPath).split('/').some(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part));
}

function inferTitleFromFile(absPath, relPath) {
  const heading = readText(absPath, '').split(/\r?\n/).find(line => /^#+\s*/.test(line));
  if (heading) {
    const title = heading.replace(/^#+\s*/, '').replace(/^第\s*0*[1-9]\d*\s*章[_\s-]*/, '').trim();
    if (title) return title;
  }
  return inferTitleFromPath(relPath);
}

function inferTitleFromPath(relPath) {
  const base = path.basename(relPath || '', path.extname(relPath || ''));
  return base.replace(/^第\s*0*[1-9]\d*\s*章[_\s-]*/, '').trim() || base;
}

function compareAssetProgress(a, b) {
  return volumeOrder(a.volume) - volumeOrder(b.volume)
    || Number(a.volumeChapterNo || a.chapterNo || 0) - Number(b.volumeChapterNo || b.chapterNo || 0)
    || Number(a.globalDraftOrder || 0) - Number(b.globalDraftOrder || 0)
    || String(a.draftPath || '').localeCompare(String(b.draftPath || ''), 'zh-Hans-CN');
}

function compareChapterFiles(a, b) {
  return volumeOrder(a.volume) - volumeOrder(b.volume)
    || a.chapterNo - b.chapterNo
    || a.relPath.localeCompare(b.relPath, 'zh-Hans-CN');
}

function volumeOrder(volume) {
  const arabic = String(volume || '').match(/第\s*([0-9]+)\s*卷/);
  if (arabic) return Number(arabic[1]);
  const chinese = String(volume || '').match(/第\s*([一二三四五六七八九十百千万两]+)\s*卷/);
  if (!chinese) return 1;
  return chineseNumber(chinese[1]);
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

function replaceChapterNo(name, oldNo, newNo) {
  return String(name).replace(new RegExp(`第\\s*0*${oldNo}\\s*章`), `第${pad(newNo)}章`);
}

function pad(value) {
  return String(Number(value || 0)).padStart(3, '0');
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}

function printHuman(result) {
  if (result.status === 'ok') {
    console.log(result.display);
    for (const warning of result.warnings || []) console.log(`警告：${warning.message}`);
    return;
  }
  console.log(result.message || result.status);
  for (const action of result.nextActions || []) console.log(`- ${action}`);
}
