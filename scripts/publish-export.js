#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const {
  ensureDir,
  readText,
  readDirSafe,
  parseChapterNo,
  nowIso,
  writeJson,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--'));
if (!projectRoot) fail('usage: publish-export.js <project-root> [--write] [--json]');

const root = path.resolve(projectRoot);
const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');

const result = exportPublishDraft(root, shouldWrite);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  console.log(`publish export prepared: ${result.files.length} chapters`);
  if (shouldWrite) console.log(`wrote ${result.exportDir}`);
}

function exportPublishDraft(projectDir, write) {
  const assets = loadAssets(projectDir);
  const chapters = assets.length ? assets.map(assetToChapter).filter(Boolean) : scanDrafts(projectDir);
  chapters.sort(compareChapters);

  const exportDir = slash(path.join('导出', '发布版'));
  const files = chapters.map((chapter, index) => {
    const globalNo = index + 1;
    const fileName = `第${padChapter(globalNo)}章_${sanitizeTitle(chapter.title)}.md`;
    const targetPath = slash(path.join(exportDir, fileName));
    return {
      sourcePath: chapter.draftPath,
      targetPath,
      title: chapter.title,
      volume: chapter.volume,
      volumeChapterNo: chapter.volumeChapterNo,
      publishChapterNo: globalNo,
    };
  });

  const manifest = {
    schemaVersion: '1.0.0',
    generatedAt: nowIso(),
    sourceRoot: projectDir,
    exportDir,
    files,
  };

  if (write) {
    const absExportDir = path.join(projectDir, exportDir);
    ensureDir(absExportDir);
    for (const stale of readDirSafe(absExportDir).filter(name => /^第.+章.*\.md$/.test(name))) {
      fs.rmSync(path.join(absExportDir, stale), { force: true });
    }
    for (const file of files) {
      const source = safeProjectPath(projectDir, file.sourcePath);
      const target = path.join(projectDir, file.targetPath);
      ensureDir(path.dirname(target));
      fs.copyFileSync(source, target);
    }
    writeJson(path.join(absExportDir, 'manifest.json'), manifest);
  }

  return manifest;
}

function loadAssets(projectDir) {
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
    .filter(Boolean)
    .filter(asset => asset.draftPath && asset.title);
}

function assetToChapter(asset) {
  return {
    draftPath: slash(asset.draftPath),
    title: asset.title,
    volume: asset.volume || inferVolumeFromRelPath(asset.draftPath),
    volumeChapterNo: Number(asset.volumeChapterNo) || parseChapterNo(path.basename(asset.draftPath)) || 0,
    globalDraftOrder: Number(asset.globalDraftOrder) || 0,
  };
}

function scanDrafts(projectDir) {
  const chapters = [];
  walkFiles(path.join(projectDir, '正文'), '正文', file => {
    const base = path.basename(file.relPath);
    if (!/^第.+章.*\.(md|txt)$/.test(base)) return;
    const volumeChapterNo = parseChapterNo(base);
    if (!volumeChapterNo) return;
    chapters.push({
      draftPath: file.relPath,
      title: inferTitle(file.relPath, readText(file.absPath)),
      volume: inferVolumeFromRelPath(file.relPath),
      volumeChapterNo,
      globalDraftOrder: 0,
    });
  });
  return chapters;
}

function walkFiles(absDir, relDir, visit) {
  for (const name of readDirSafe(absDir)) {
    const absPath = path.join(absDir, name);
    const relPath = slash(path.join(relDir, name));
    let stat;
    try {
      stat = fs.statSync(absPath);
    } catch {
      continue;
    }
    if (stat.isDirectory()) {
      walkFiles(absPath, relPath, visit);
    } else if (stat.isFile()) {
      visit({ absPath, relPath });
    }
  }
}

function inferTitle(relPath, text) {
  const heading = String(text || '').split(/\r?\n/).find(line => /^#+\s*/.test(line));
  if (heading) {
    const title = stripChapterPrefix(heading.replace(/^#+\s*/, ''));
    if (title) return title;
  }
  const base = path.basename(relPath, path.extname(relPath));
  return stripChapterPrefix(base) || base;
}

function stripChapterPrefix(value) {
  return String(value || '').replace(/^第\s*0*[1-9]\d*\s*章[_\s-]*/, '').trim();
}

function compareChapters(a, b) {
  const leftOrder = Number(a.globalDraftOrder) || 0;
  const rightOrder = Number(b.globalDraftOrder) || 0;
  if (leftOrder || rightOrder) return leftOrder - rightOrder;
  return volumeOrder(a.volume) - volumeOrder(b.volume)
    || a.volumeChapterNo - b.volumeChapterNo
    || a.draftPath.localeCompare(b.draftPath, 'zh-Hans-CN');
}

function inferVolumeFromRelPath(relPath) {
  const volume = slash(relPath).split('/').find(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part));
  return volume || '第1卷';
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

function sanitizeTitle(title) {
  return String(title || '未命名')
    .replace(/[\\/:*?"<>|]/g, '_')
    .replace(/\s+/g, '')
    .slice(0, 80) || '未命名';
}

function safeProjectPath(projectDir, relPath) {
  const resolved = path.resolve(projectDir, relPath);
  if (resolved !== projectDir && !resolved.startsWith(`${projectDir}${path.sep}`)) {
    fail(`path escapes project root: ${relPath}`);
  }
  return resolved;
}

function padChapter(chapterNo) {
  return String(chapterNo).padStart(3, '0');
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
