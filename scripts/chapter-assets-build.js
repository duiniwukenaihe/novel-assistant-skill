#!/usr/bin/env node
const path = require('path');
const {
  ensureDir,
  readText,
  readJson,
  readDirSafe,
  parseChapterNo,
  nowIso,
  writeJsonl,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--'));
if (!projectRoot) fail('usage: chapter-assets-build.js <project-root> [--write] [--json]');

const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');
const root = path.resolve(projectRoot);

const assets = buildChapterAssets(root);
if (shouldWrite) writeAssets(root, assets);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify({ assets }, null, 2)}\n`);
} else {
  console.log(`chapter assets built: ${assets.length}`);
  if (shouldWrite) console.log('wrote 追踪/章节资产.jsonl');
}

function buildChapterAssets(projectDir) {
  const existing = readExistingAssets(projectDir);
  const drafts = collectChapterFiles(projectDir, '正文', /^第.+章.*\.(md|txt)$/);
  const outlines = collectChapterFiles(projectDir, '大纲', /^细纲_第.+\.(md|txt)$/);
  const contracts = collectChapterFiles(projectDir, path.join('追踪', '章节契约'), /^第.+章.*\.(md|txt)$/);
  const chapters = preferCanonicalChapterFiles(drafts)
    .sort(compareChapterFiles)
    .map((draft, index) => {
      const outline = findMatching(outlines, draft);
      const contract = findMatching(contracts, draft);
      const previous = findExisting(existing, draft);
      return {
        assetId: previous?.assetId || `asset-${compactDate(nowIso())}-${String(index + 1).padStart(4, '0')}`,
        title: inferTitle(draft),
        volume: draft.volume,
        volumeChapterNo: draft.volumeChapterNo,
        globalDraftOrder: index + 1,
        draftPath: draft.relPath,
        outlinePath: outline ? outline.relPath : '',
        contractPath: contract ? contract.relPath : '',
        sourceAssetIds: Array.isArray(previous?.sourceAssetIds) ? previous.sourceAssetIds : [],
        status: previous?.status || 'draft',
        version: Number.isInteger(previous?.version) ? previous.version : 1,
        updatedAt: nowIso(),
      };
    });
  return chapters;
}

function preferCanonicalChapterFiles(files) {
  const byChapter = new Map();
  for (const file of files) {
    const key = `${file.volume}|${file.volumeChapterNo}`;
    const previous = byChapter.get(key);
    if (!previous || compareCanonicalChapterFile(file, previous) < 0) {
      byChapter.set(key, file);
    }
  }
  return Array.from(byChapter.values());
}

function compareCanonicalChapterFile(a, b) {
  const av = isVolumeLocalPath(a.relPath) ? 0 : 1;
  const bv = isVolumeLocalPath(b.relPath) ? 0 : 1;
  if (av !== bv) return av - bv;
  return compareChapterFiles(a, b);
}

function isVolumeLocalPath(relPath) {
  return slash(relPath).split('/').some(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part));
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
      text: readText(file.absPath),
      volume: inferVolumeFromRelPath(file.relPath),
      volumeChapterNo: chapterNo,
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
      stat = require('fs').statSync(absPath);
    } catch {
      continue;
    }
    if (stat.isDirectory()) {
      walk(absPath, relPath, visit);
    } else if (stat.isFile()) {
      visit({ absPath, relPath: slash(relPath) });
    }
  }
}

function readExistingAssets(projectDir) {
  const file = path.join(projectDir, '追踪', '章节资产.jsonl');
  const text = readText(file, '');
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

function findExisting(existing, draft) {
  return existing.find(item => item.draftPath === draft.relPath)
    || existing.find(item => item.title === inferTitle(draft) && item.volume === draft.volume)
    || null;
}

function findMatching(files, draft) {
  return files.find(item => item.volume === draft.volume && item.volumeChapterNo === draft.volumeChapterNo)
    || files.find(item => item.volumeChapterNo === draft.volumeChapterNo)
    || null;
}

function inferTitle(file) {
  const heading = file.text.split(/\r?\n/).find(line => /^#+\s*/.test(line));
  if (heading) {
    const title = heading.replace(/^#+\s*/, '').replace(/^第\s*0*[1-9]\d*\s*章[_\s-]*/, '').trim();
    if (title) return title;
  }
  const base = path.basename(file.relPath, path.extname(file.relPath));
  return base.replace(/^第\s*0*[1-9]\d*\s*章[_\s-]*/, '').trim() || base;
}

function inferVolumeFromRelPath(relPath) {
  const volume = slash(relPath).split('/').find(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part));
  return volume || '第1卷';
}

function compareChapterFiles(a, b) {
  return volumeOrder(a.volume) - volumeOrder(b.volume)
    || a.volumeChapterNo - b.volumeChapterNo
    || a.relPath.localeCompare(b.relPath, 'zh-Hans-CN');
}

function volumeOrder(volume) {
  const arabic = String(volume).match(/第\s*([0-9]+)\s*卷/);
  if (arabic) return Number(arabic[1]);
  const chinese = String(volume).match(/第\s*([一二三四五六七八九十]+)\s*卷/);
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

function writeAssets(projectDir, assets) {
  const file = path.join(projectDir, '追踪', '章节资产.jsonl');
  ensureDir(path.dirname(file));
  writeJsonl(file, assets);
}

function compactDate(iso) {
  return iso.slice(0, 10).replace(/-/g, '');
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
