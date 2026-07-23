#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const {
  ensureDir,
  readDirSafe,
  parseChapterNo,
  nowIso,
  writeJson,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--'));
if (!projectRoot) fail('usage: story-project-migrate.js <book-project-dir> [--write] [--json]');

const root = path.resolve(projectRoot);
const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');

const result = migrateProject(root, shouldWrite);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  console.log(`story project migration: ${result.status}`);
  console.log(`planned: ${result.actions.length}, migrated: ${result.migrated}, conflicts: ${result.conflicts.length}`);
  if (result.snapshotPath) console.log(`snapshot: ${result.snapshotPath}`);
}

function migrateProject(projectDir, write) {
  const createdAt = nowIso();
  const snapshotPath = slash(path.join('追踪', '版本', `${createdAt.replace(/[:.]/g, '').replace('T', '_').replace('Z', '')}_layout-migration`));
  const volumeMaps = buildVolumeRenumberMaps(projectDir);
  const actions = [
    ...collectFlatOutlines(projectDir),
    ...collectFlatDrafts(projectDir),
    ...collectFlatContracts(projectDir),
    ...collectFlatHandoffs(projectDir),
    ...collectGlobalNumberedVolumeActions(projectDir, volumeMaps),
  ].sort((a, b) => a.source.localeCompare(b.source, 'zh-Hans-CN'));
  const conflicts = [];
  let migrated = 0;
  const migratedActions = [];
  let referenceUpdates = [];

  for (const action of actions) {
    const source = path.join(projectDir, action.source);
    const target = path.join(projectDir, action.target);
    if (!fs.existsSync(source)) continue;
    if (fs.existsSync(target)) {
      conflicts.push({
        source: action.source,
        target: action.target,
        reason: 'target_exists',
      });
      continue;
    }
    if (!write) continue;
    const backup = path.join(projectDir, snapshotPath, 'legacy-flat-layout', action.source);
    ensureDir(path.dirname(backup));
    fs.copyFileSync(source, backup);
    ensureDir(path.dirname(target));
    fs.copyFileSync(source, target);
    rewriteMigratedFile(projectDir, action.target, action);
    fs.rmSync(source, { force: true });
    migratedActions.push(action);
    migrated += 1;
  }

  if (write && migratedActions.length) updateBookState(projectDir, migratedActions);
  if (write ? migratedActions.length : actions.length) {
    referenceUpdates = rewriteProjectReferences(projectDir, volumeMaps, { write });
  }

  const manifest = {
    schemaVersion: '1.0.0',
    createdAt,
    reason: 'layout-migration',
    projectRoot: projectDir,
    snapshotPath,
    actions,
    conflicts,
    referenceUpdates,
    migrated,
  };
  if (write) writeJson(path.join(projectDir, snapshotPath, 'manifest.json'), manifest);
  return {
    status: migrationStatus({ write, actions, conflicts, migrated }),
    ...manifest,
  };
}

function collectFlatOutlines(projectDir) {
  const relDir = '大纲';
  const dir = path.join(projectDir, relDir);
  const actions = [];
  for (const name of readDirSafe(dir)) {
    const source = slash(path.join(relDir, name));
    const abs = path.join(dir, name);
    if (!isFile(abs)) continue;
    if (/^细纲_第.+\.(md|txt)$/.test(name) && parseChapterNo(name)) {
      actions.push({ type: 'outline', source, target: slash(path.join('大纲', '第1卷', name)) });
    } else if (/^卷纲_第.+卷\.md$/.test(name)) {
      const volume = inferVolumeFromVolumeOutline(name);
      actions.push({ type: 'volume-outline', source, target: slash(path.join('大纲', volume, '卷纲.md')) });
    }
  }
  return actions;
}

function collectFlatDrafts(projectDir) {
  const relDir = '正文';
  const dir = path.join(projectDir, relDir);
  const actions = [];
  for (const name of readDirSafe(dir)) {
    const source = slash(path.join(relDir, name));
    const abs = path.join(dir, name);
    if (!isFile(abs)) continue;
    if (/^第.+章.*\.(md|txt)$/.test(name) && parseChapterNo(name)) {
      actions.push({ type: 'draft', source, target: slash(path.join('正文', '第1卷', name)) });
    }
  }
  return actions;
}

function collectFlatContracts(projectDir) {
  const relDir = path.join('追踪', '章节契约');
  const dir = path.join(projectDir, relDir);
  const actions = [];
  for (const name of readDirSafe(dir)) {
    const source = slash(path.join(relDir, name));
    const abs = path.join(dir, name);
    if (!isFile(abs)) continue;
    if (/^第.+章.*\.(md|txt)$/.test(name) && parseChapterNo(name)) {
      actions.push({ type: 'contract', source, target: slash(path.join('追踪', '章节契约', '第1卷', name)) });
    }
  }
  return actions;
}

function collectFlatHandoffs(projectDir) {
  const relDir = path.join('追踪', '交接包');
  const dir = path.join(projectDir, relDir);
  const actions = [];
  for (const name of readDirSafe(dir)) {
    const source = slash(path.join(relDir, name));
    const abs = path.join(dir, name);
    if (!isFile(abs)) continue;
    if (/^第.+章.*_to_第.+章.*\.(md|txt)$/.test(name)) {
      actions.push({ type: 'handoff', source, target: slash(path.join('追踪', '交接包', '第1卷', name)) });
    }
  }
  return actions;
}

function collectGlobalNumberedVolumeActions(projectDir, volumeMaps) {
  const actions = [];
  actions.push(...collectVolumeChapterRenumber(projectDir, '正文', 'draft', volumeMaps));
  actions.push(...collectVolumeChapterRenumber(projectDir, '大纲', 'outline', volumeMaps));
  actions.push(...collectVolumeChapterRenumber(projectDir, path.join('追踪', '章节契约'), 'contract', volumeMaps));
  actions.push(...collectVolumeChapterRenumber(projectDir, path.join('追踪', '漂移门控'), 'drift-gate', volumeMaps));
  actions.push(...collectVolumeChapterRenumber(projectDir, path.join('追踪', 'context-pack'), 'context-pack', volumeMaps));
  actions.push(...collectVolumeHandoffRenumber(projectDir, path.join('追踪', '交接包'), volumeMaps));
  return actions;
}

function buildVolumeRenumberMaps(projectDir) {
  const volumeNumbers = new Map();
  for (const relRoot of [
    '正文',
    '大纲',
    path.join('追踪', '章节契约'),
    path.join('追踪', '漂移门控'),
    path.join('追踪', 'context-pack'),
    path.join('追踪', '交接包'),
  ]) {
    const rootDir = path.join(projectDir, relRoot);
    for (const volumeName of readDirSafe(rootDir)) {
      const volumeDir = path.join(rootDir, volumeName);
      if (!isVolumeDir(volumeName) || !isDirectory(volumeDir) || volumeOrder(volumeName) <= 1) continue;
      const numbers = volumeNumbers.get(volumeName) || new Set();
      for (const name of readDirSafe(volumeDir)) {
        const handoff = parseHandoffChapterNos(name);
        if (handoff) {
          numbers.add(handoff.from);
          numbers.add(handoff.to);
        } else {
          const chapterNo = parseChapterNo(name);
          if (chapterNo > 0) numbers.add(chapterNo);
        }
      }
      volumeNumbers.set(volumeName, numbers);
    }
  }

  const maps = new Map();
  for (const [volumeName, numbersSet] of volumeNumbers.entries()) {
    const numbers = Array.from(numbersSet).filter(Boolean).sort((a, b) => a - b);
    if (!looksGlobalNumberedVolume(numbers.map(chapterNo => ({ chapterNo })))) continue;
    maps.set(volumeName, new Map(numbers.map((chapterNo, index) => [chapterNo, index + 1])));
  }
  return maps;
}

function collectVolumeChapterRenumber(projectDir, relRoot, type, volumeMaps) {
  const rootDir = path.join(projectDir, relRoot);
  const actions = [];
  for (const volumeName of readDirSafe(rootDir)) {
    const volumeDir = path.join(rootDir, volumeName);
    if (!isVolumeDir(volumeName) || !isDirectory(volumeDir) || volumeOrder(volumeName) <= 1) continue;
    const map = volumeMaps.get(volumeName);
    if (!map) continue;
    const files = readDirSafe(volumeDir)
      .map(name => ({ name, chapterNo: parseChapterNo(name) }))
      .filter(item => item.chapterNo > 0)
      .sort((a, b) => a.chapterNo - b.chapterNo || a.name.localeCompare(b.name, 'zh-Hans-CN'));
    for (const item of files) {
      if (!map.has(item.chapterNo)) continue;
      const newNo = map.get(item.chapterNo);
      const targetName = replaceChapterNo(item.name, item.chapterNo, newNo);
      if (targetName === item.name) continue;
      actions.push({
        type,
        reason: 'volume_global_numbering',
        source: slash(path.join(relRoot, volumeName, item.name)),
        target: slash(path.join(relRoot, volumeName, targetName)),
        volume: volumeName,
        oldChapterNo: item.chapterNo,
        newChapterNo: newNo,
        renumberMap: serializableMap(map),
      });
    }
  }
  return actions;
}

function collectVolumeHandoffRenumber(projectDir, relRoot, volumeMaps) {
  const rootDir = path.join(projectDir, relRoot);
  const actions = [];
  for (const volumeName of readDirSafe(rootDir)) {
    const volumeDir = path.join(rootDir, volumeName);
    if (!isVolumeDir(volumeName) || !isDirectory(volumeDir) || volumeOrder(volumeName) <= 1) continue;
    const map = volumeMaps.get(volumeName);
    if (!map) continue;
    const parsed = [];
    for (const name of readDirSafe(volumeDir)) {
      const handoff = parseHandoffChapterNos(name);
      if (!handoff) continue;
      parsed.push({ name, ...handoff });
    }
    for (const item of parsed) {
      if (!map.has(item.from) || !map.has(item.to)) continue;
      const targetName = item.name
        .replace(new RegExp(`第\\s*0*${item.from}\\s*章`), `第${padChapter(map.get(item.from))}章`)
        .replace(new RegExp(`第\\s*0*${item.to}\\s*章`), `第${padChapter(map.get(item.to))}章`);
      if (targetName === item.name) continue;
      actions.push({
        type: 'handoff',
        reason: 'volume_global_numbering',
        source: slash(path.join(relRoot, volumeName, item.name)),
        target: slash(path.join(relRoot, volumeName, targetName)),
        volume: volumeName,
        oldChapterNo: item.from,
        newChapterNo: map.get(item.from),
        renumberMap: serializableMap(map),
      });
    }
  }
  return actions;
}

function parseHandoffChapterNos(name) {
  const match = String(name).match(/第\s*0*(\d+)\s*章_to_第\s*0*(\d+)\s*章/);
  if (!match) return null;
  return { from: Number(match[1]), to: Number(match[2]) };
}

function rewriteMigratedFile(projectDir, relPath, action) {
  if (!action || action.reason !== 'volume_global_numbering') return;
  const file = path.join(projectDir, relPath);
  if (!isTextFile(file)) return;
  const text = fs.readFileSync(file, 'utf8');
  const rewritten = replaceChapterRefsByMap(text, action.renumberMap || { [action.oldChapterNo]: action.newChapterNo });
  if (rewritten !== text) fs.writeFileSync(file, rewritten, 'utf8');
}

function rewriteProjectReferences(projectDir, volumeMaps, options = {}) {
  const shouldWrite = options.write !== false;
  const updates = [];
  const candidates = [
    '大纲',
    path.join('追踪', '伏笔.md'),
    path.join('追踪', '时间线.md'),
    path.join('追踪', '上下文.md'),
    path.join('追踪', '角色状态.md'),
    path.join('追踪', '章节索引.tsv'),
  ];
  for (const candidate of candidates) {
    const abs = path.join(projectDir, candidate);
    if (!fs.existsSync(abs)) continue;
    const files = [];
    if (isDirectory(abs)) walkTextFiles(abs, file => files.push(file));
    else if (isTextFile(abs)) files.push(abs);
    for (const file of files) {
      if (slash(file).includes('/追踪/版本/')) continue;
      const relPath = slash(path.relative(projectDir, file));
      const before = fs.readFileSync(file, 'utf8');
      const volume = inferVolumeFromPath(relPath);
      let after = before;
      if (volume && volumeMaps.has(volume)) {
        after = replaceChapterRefsByMap(after, serializableMap(volumeMaps.get(volume)));
      } else {
        for (const map of volumeMaps.values()) after = replaceChapterRefsByMap(after, serializableMap(map));
      }
      if (after === before) continue;
      if (shouldWrite) fs.writeFileSync(file, after, 'utf8');
      updates.push({ path: relPath, reason: 'chapter_reference_renumber' });
    }
  }
  return updates;
}

function replaceChapterRefsByMap(text, mapObject) {
  let output = String(text);
  const entries = Object.entries(mapObject || {})
    .map(([oldNo, newNo]) => [Number(oldNo), Number(newNo)])
    .filter(([oldNo, newNo]) => oldNo > 0 && newNo > 0)
    .sort((a, b) => b[0] - a[0]);
  for (const [oldNo, newNo] of entries) {
    output = output.replace(new RegExp(`第\\s*0*${oldNo}\\s*章`, 'g'), `第${padChapter(newNo)}章`);
  }
  return output;
}

function serializableMap(map) {
  return Object.fromEntries(Array.from(map.entries()).map(([key, value]) => [String(key), value]));
}

function inferVolumeFromPath(relPath) {
  return slash(relPath).split('/').find(part => isVolumeDir(part)) || '';
}

function walkTextFiles(dir, visit) {
  for (const name of readDirSafe(dir)) {
    const abs = path.join(dir, name);
    if (isDirectory(abs)) walkTextFiles(abs, visit);
    else if (isTextFile(abs)) visit(abs);
  }
}

function updateBookState(projectDir, actions) {
  const stateFile = path.join(projectDir, '.book-state.json');
  if (!fs.existsSync(stateFile)) return;
  let state;
  try {
    state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  } catch {
    return;
  }
  const bySource = new Map(actions.map(action => [action.source, action]));
  const volumeAction = actions.find(action => action.volume && action.newChapterNo);
  if (volumeAction) {
    state.currentVolume = state.currentVolume || state.preferredVolume || volumeAction.volume;
    if ((state.preferredVolume || state.currentVolume) === volumeAction.volume && Number(state.currentChapter) === volumeAction.oldChapterNo) {
      state.currentVolumeChapter = volumeAction.newChapterNo;
      state.globalDraftOrder = state.globalDraftOrder || state.currentChapter;
    } else if (!Number.isInteger(state.currentVolumeChapter)) {
      state.currentVolumeChapter = volumeAction.newChapterNo;
    }
  }
  for (const [field, value] of Object.entries(state)) {
    if (typeof value !== 'string') continue;
    const normalized = slash(value);
    if (bySource.has(normalized)) state[field] = bySource.get(normalized).target;
  }
  const draftAction = actions.find(action => action.type === 'draft' && action.volume === (state.currentVolume || state.preferredVolume));
  if (draftAction && (Number(state.currentChapter) === draftAction.oldChapterNo || !state.currentDraftPath)) {
    state.currentDraftPath = draftAction.target;
    state.currentVolume = draftAction.volume;
    state.currentVolumeChapter = draftAction.newChapterNo;
    state.globalDraftOrder = state.globalDraftOrder || draftAction.oldChapterNo;
  }
  state.chapterLayout = 'volume';
  fs.writeFileSync(stateFile, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
}

function migrationStatus({ write, actions, conflicts, migrated }) {
  if (conflicts.length) return 'blocked_conflict';
  if (!actions.length) return 'current';
  if (!write) return 'needs_action';
  return migrated ? 'migrated' : 'current';
}

function looksGlobalNumberedVolume(files) {
  if (!files.length) return false;
  const numbers = files.map(item => item.chapterNo).filter(Boolean);
  if (!numbers.length || numbers.includes(1)) return false;
  return Math.min(...numbers) > 1;
}

function replaceChapterNo(name, oldNo, newNo) {
  return String(name).replace(new RegExp(`第\\s*0*${oldNo}\\s*章`), `第${padChapter(newNo)}章`);
}

function padChapter(value) {
  return String(value).padStart(3, '0');
}

function isVolumeDir(name) {
  return /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(String(name));
}

function isDirectory(dir) {
  try {
    return fs.statSync(dir).isDirectory();
  } catch {
    return false;
  }
}

function inferVolumeFromVolumeOutline(name) {
  const match = String(name).match(/^卷纲_(第.+卷)\.md$/);
  return match ? normalizeVolume(match[1]) : '第1卷';
}

function normalizeVolume(volume) {
  const chinese = String(volume).match(/^第([一二三四五六七八九十两]+)卷$/);
  if (!chinese) return volume;
  return `第${chineseNumber(chinese[1])}卷`;
}

function volumeOrder(volumeName) {
  const arabic = String(volumeName).match(/第\s*([0-9]+)\s*卷/);
  if (arabic) return Number(arabic[1]);
  const chinese = String(volumeName).match(/第\s*([一二三四五六七八九十两]+)\s*卷/);
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

function isFile(file) {
  try {
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function isTextFile(file) {
  return isFile(file) && /\.(md|txt|json|jsonl|tsv|csv)$/i.test(file);
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
