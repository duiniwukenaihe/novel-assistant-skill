#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const {
  ensureDir,
  readDirSafe,
  readJson,
  nowIso,
  writeJson,
  parseChapterNo,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--'));
if (!projectRoot || args.includes('-h') || args.includes('--help')) {
  console.log('Usage: node story-expansion-plan.js <book-dir> --volume 第X卷 (--insert-before N | --insert-after N) --count K [--write] [--json]');
  process.exit(projectRoot ? 0 : 1);
}

const root = path.resolve(projectRoot);
const volume = option('--volume') || readJson(path.join(root, '.book-state.json'), {})?.preferredVolume || '第1卷';
const insertBefore = numberOption('--insert-before');
const insertAfter = numberOption('--insert-after');
const count = numberOption('--count');
const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');

if (!count || count < 1 || (!insertBefore && !insertAfter)) {
  fail('usage: require --count K and one of --insert-before N / --insert-after N');
}

const startNo = insertBefore || (insertAfter + 1);
const result = buildExpansionPlan(root, { volume, startNo, count, write: shouldWrite });

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  console.log(`story expansion: ${result.status}`);
  console.log(`volume: ${result.volume}, insertStart: ${result.insertStart}, count: ${result.insertCount}`);
  console.log(`planned: ${result.actions.length}, shifted: ${result.shifted}, conflicts: ${result.conflicts.length}`);
  if (result.snapshotPath) console.log(`snapshot: ${result.snapshotPath}`);
}

process.exit(result.status === 'blocked_conflict' || result.status === 'blocked_mixed_chapter_layout' ? 2 : 0);

function buildExpansionPlan(projectDir, request) {
  const createdAt = nowIso();
  const snapshotPath = slash(path.join('追踪', '版本', `${createdAt.replace(/[:.]/g, '').replace('T', '_').replace('Z', '')}_expansion-shift`));
  const mixed = detectMixedLayout(projectDir, request.volume);
  if (mixed) {
    return {
      status: 'blocked_mixed_chapter_layout',
      createdAt,
      projectRoot: projectDir,
      volume: request.volume,
      insertStart: request.startNo,
      insertCount: request.count,
      message: '当前卷目录仍使用全书连续编号；必须先迁移章节结构或明确保持旧结构兼容，再做扩容后移。',
      actions: [],
      conflicts: [],
      referenceUpdates: [],
      shifted: 0,
    };
  }

  const actions = collectShiftActions(projectDir, request.volume, request.startNo, request.count)
    .sort((a, b) => b.oldChapterNo - a.oldChapterNo || b.source.localeCompare(a.source, 'zh-Hans-CN'));
  const conflicts = detectConflicts(projectDir, actions);
  const chapterMap = buildChapterMap(actions);
  const referenceUpdates = collectReferenceUpdates(projectDir, request.volume, chapterMap);
  const plotUnitUpdates = collectPlotUnitUpdates(projectDir, request.volume, request.startNo, request.count);
  const expansionGap = buildExpansionGap(request.volume, request.startNo, request.count, createdAt);
  let shifted = 0;

  if (request.write && conflicts.length === 0) {
    for (const action of actions) {
      const source = path.join(projectDir, action.source);
      const target = path.join(projectDir, action.target);
      if (!fs.existsSync(source)) continue;
      const backup = path.join(projectDir, snapshotPath, 'before-expansion', action.source);
      ensureDir(path.dirname(backup));
      fs.copyFileSync(source, backup);
      ensureDir(path.dirname(target));
      fs.renameSync(source, target);
      shifted += 1;
    }
    const movedTargets = new Set(actions.map(action => action.target));
    rewriteMovedTargets(projectDir, actions, chapterMap);
    rewriteProjectReferences(projectDir, request.volume, chapterMap, movedTargets);
    writePlotUnitUpdates(projectDir, plotUnitUpdates, snapshotPath);
    writeExpansionGap(projectDir, expansionGap, snapshotPath);
    updateBookState(projectDir, request.volume, request.startNo, request.count, actions);
    writeJson(path.join(projectDir, snapshotPath, 'manifest.json'), {
      schemaVersion: '1.0.0',
      createdAt,
      reason: 'expansion-shift',
      projectRoot: projectDir,
      volume: request.volume,
      insertStart: request.startNo,
      insertCount: request.count,
      actions,
      referenceUpdates,
      plotUnitUpdates,
      expansionGap,
      shifted,
    });
  }

  return {
    status: conflicts.length ? 'blocked_conflict' : (request.write ? 'shifted' : 'needs_action'),
    createdAt,
    projectRoot: projectDir,
    snapshotPath,
    volume: request.volume,
    insertStart: request.startNo,
    insertCount: request.count,
    gapRange: {
      start: request.startNo,
      end: request.startNo + request.count - 1,
    },
    actions,
    conflicts,
    referenceUpdates,
    plotUnitUpdates,
    expansionGap,
    shifted,
    nextActions: [
      '先确认后移映射',
      '执行后移并保留版本快照',
      '填充新增缺口章节的大纲/细纲/契约/正文',
      '运行连续性复检',
    ],
  };
}

function collectPlotUnitUpdates(projectDir, volumeName, startNo, offset) {
  const file = path.join(projectDir, '追踪', 'schema', 'plot-units.jsonl');
  return readJsonl(file).filter(unit => unit && unit.volume === volumeName).map((unit) => {
    const before = JSON.parse(JSON.stringify(unit));
    const range = unit.chapterRange && typeof unit.chapterRange === 'object' ? unit.chapterRange : {};
    const insertionInsideUnit = Number(range.start) < startNo && Number(range.end) >= startNo;
    const chapters = Array.isArray(unit.chapters) ? unit.chapters.map((chapter) => ({
      ...chapter,
      volumeChapterNo: Number(chapter.volumeChapterNo) >= startNo
        ? Number(chapter.volumeChapterNo) + offset
        : Number(chapter.volumeChapterNo),
    })) : [];
    const chapterNumbers = chapters.map(item => Number(item.volumeChapterNo)).filter(Number.isInteger);
    const chapterRange = chapterNumbers.length ? { start: Math.min(...chapterNumbers), end: Math.max(...chapterNumbers) } : {
      start: Number(range.start) >= startNo ? Number(range.start) + offset : Number(range.start),
      end: Number(range.end) >= startNo ? Number(range.end) + offset : Number(range.end),
    };
    const planningState = unit.planningMode === 'soft'
      ? 'stale'
      : insertionInsideUnit ? 'locked_with_pending_gap' : unit.planningState;
    return {
      id: unit.id,
      before,
      after: {
        ...unit,
        chapterRange,
        chapters,
        planningState,
        invalidationReason: unit.planningMode === 'soft' ? 'expansion_shifted_unwritten_unit' : (insertionInsideUnit ? 'expansion_gap_inside_locked_unit' : ''),
      },
    };
  });
}

function buildExpansionGap(volumeName, startNo, count, createdAt) {
  const volumeNo = (String(volumeName).match(/\d+/) || ['1'])[0];
  return {
    schemaVersion: '1.0.0',
    id: `GAP-${volumeNo}-${startNo}-${startNo + count - 1}`,
    volume: volumeName,
    chapterRange: { start: startNo, end: startNo + count - 1 },
    status: 'pending',
    reason: 'expansion_insert',
    createdAt,
    requiredAssets: ['卷纲调整', '细纲', '章节契约', '正文', '钩子与连续性交接'],
  };
}

function writePlotUnitUpdates(projectDir, updates, snapshotPath) {
  if (!updates.length) return;
  const file = path.join(projectDir, '追踪', 'schema', 'plot-units.jsonl');
  const rows = readJsonl(file);
  backupTrackingFile(projectDir, file, snapshotPath);
  const byId = new Map(updates.map(update => [update.id, update.after]));
  writeJsonl(file, rows.map(row => byId.get(row.id) || row));
}

function writeExpansionGap(projectDir, gap, snapshotPath) {
  const file = path.join(projectDir, '追踪', 'schema', 'expansion-gaps.jsonl');
  const rows = readJsonl(file);
  if (fs.existsSync(file)) backupTrackingFile(projectDir, file, snapshotPath);
  const next = rows.filter(item => item.id !== gap.id);
  next.push(gap);
  writeJsonl(file, next);
}

function backupTrackingFile(projectDir, file, snapshotPath) {
  if (!fs.existsSync(file)) return;
  const relative = path.relative(projectDir, file);
  const backup = path.join(projectDir, snapshotPath, 'before-expansion', relative);
  ensureDir(path.dirname(backup));
  fs.copyFileSync(file, backup);
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(line => line.trim()).filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch (_) { return []; }
  });
}

function writeJsonl(file, rows) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, rows.length ? `${rows.map(row => JSON.stringify(row)).join('\n')}\n` : '', 'utf8');
}

function collectShiftActions(projectDir, volumeName, startNo, offset) {
  const actions = [];
  for (const relRoot of [
    '正文',
    '大纲',
    path.join('追踪', '章节契约'),
    path.join('追踪', '漂移门控'),
    path.join('追踪', 'context-pack'),
  ]) {
    actions.push(...collectChapterShift(projectDir, relRoot, volumeName, startNo, offset));
  }
  actions.push(...collectHandoffShift(projectDir, path.join('追踪', '交接包'), volumeName, startNo, offset));
  return actions;
}

function collectChapterShift(projectDir, relRoot, volumeName, startNo, offset) {
  const dir = path.join(projectDir, relRoot, volumeName);
  const actions = [];
  for (const name of readDirSafe(dir)) {
    const chapterNo = parseChapterNo(name);
    if (!chapterNo || chapterNo < startNo) continue;
    const newNo = chapterNo + offset;
    const targetName = replaceChapterNo(name, chapterNo, newNo);
    if (targetName === name) continue;
    actions.push({
      type: relRoot.replaceAll(path.sep, '/'),
      reason: 'expansion_shift',
      source: slash(path.join(relRoot, volumeName, name)),
      target: slash(path.join(relRoot, volumeName, targetName)),
      volume: volumeName,
      oldChapterNo: chapterNo,
      newChapterNo: newNo,
    });
  }
  return actions;
}

function collectHandoffShift(projectDir, relRoot, volumeName, startNo, offset) {
  const dir = path.join(projectDir, relRoot, volumeName);
  const actions = [];
  for (const name of readDirSafe(dir)) {
    const handoff = parseHandoffChapterNos(name);
    if (!handoff || (handoff.from < startNo && handoff.to < startNo)) continue;
    const newFrom = handoff.from >= startNo ? handoff.from + offset : handoff.from;
    const newTo = handoff.to >= startNo ? handoff.to + offset : handoff.to;
    const targetName = name
      .replace(new RegExp(`第\\s*0*${handoff.from}\\s*章`), `第${pad(newFrom)}章`)
      .replace(new RegExp(`第\\s*0*${handoff.to}\\s*章`), `第${pad(newTo)}章`);
    if (targetName === name) continue;
    actions.push({
      type: '追踪/交接包',
      reason: 'expansion_shift',
      source: slash(path.join(relRoot, volumeName, name)),
      target: slash(path.join(relRoot, volumeName, targetName)),
      volume: volumeName,
      oldChapterNo: handoff.from,
      newChapterNo: newFrom,
    });
  }
  return actions;
}

function detectConflicts(projectDir, actions) {
  const sources = new Set(actions.map(action => action.source));
  const conflicts = [];
  for (const action of actions) {
    const target = path.join(projectDir, action.target);
    if (fs.existsSync(target) && !sources.has(action.target)) {
      conflicts.push({ source: action.source, target: action.target, reason: 'target_exists' });
    }
  }
  return conflicts;
}

function buildChapterMap(actions) {
  const map = new Map();
  for (const action of actions) {
    if (action.oldChapterNo && action.newChapterNo && action.oldChapterNo !== action.newChapterNo) {
      map.set(action.oldChapterNo, action.newChapterNo);
    }
  }
  return map;
}

function collectReferenceUpdates(projectDir, volumeName, chapterMap) {
  const updates = [];
  for (const file of referenceFiles(projectDir)) {
    const relPath = slash(path.relative(projectDir, file));
    const before = fs.readFileSync(file, 'utf8');
    const after = replaceChapterRefsByMap(before, chapterMap);
    if (after !== before) updates.push({ path: relPath, volume: volumeName, reason: 'expansion_reference_shift' });
  }
  return updates;
}

function rewriteMovedTargets(projectDir, actions, chapterMap) {
  for (const action of actions) {
    const file = path.join(projectDir, action.target);
    if (!isTextFile(file)) continue;
    const before = fs.readFileSync(file, 'utf8');
    const after = replaceChapterRefsByMap(before, chapterMap);
    if (after !== before) fs.writeFileSync(file, after, 'utf8');
  }
}

function rewriteProjectReferences(projectDir, volumeName, chapterMap, excludeRelPaths = new Set()) {
  for (const file of referenceFiles(projectDir)) {
    if (excludeRelPaths.has(slash(path.relative(projectDir, file)))) continue;
    const before = fs.readFileSync(file, 'utf8');
    const after = replaceChapterRefsByMap(before, chapterMap);
    if (after !== before) fs.writeFileSync(file, after, 'utf8');
  }
}

function referenceFiles(projectDir) {
  const files = [];
  for (const candidate of [
    '大纲',
    path.join('追踪', '伏笔.md'),
    path.join('追踪', '主线承诺.md'),
    path.join('追踪', '时间线.md'),
    path.join('追踪', '上下文.md'),
    path.join('追踪', '角色状态.md'),
    path.join('追踪', '章节索引.tsv'),
  ]) {
    const abs = path.join(projectDir, candidate);
    if (!fs.existsSync(abs)) continue;
    if (isDirectory(abs)) walkTextFiles(abs, file => files.push(file));
    else if (isTextFile(abs)) files.push(abs);
  }
  return files.filter(file => !slash(file).includes('/追踪/版本/'));
}

function updateBookState(projectDir, volumeName, startNo, offset, actions) {
  const stateFile = path.join(projectDir, '.book-state.json');
  const state = readJson(stateFile, null);
  if (!state || typeof state !== 'object') return;
  const bySource = new Map(actions.map(action => [action.source, action.target]));
  for (const [field, value] of Object.entries(state)) {
    if (typeof value === 'string' && bySource.has(slash(value))) state[field] = bySource.get(slash(value));
  }
  if ((state.currentVolume === volumeName || state.preferredVolume === volumeName) && Number(state.currentVolumeChapter) >= startNo) {
    state.currentVolumeChapter = Number(state.currentVolumeChapter) + offset;
  }
  writeJson(stateFile, state);
}

function detectMixedLayout(projectDir, volumeName) {
  const dir = path.join(projectDir, '正文', volumeName);
  const numbers = readDirSafe(dir).map(parseChapterNo).filter(Boolean).sort((a, b) => a - b);
  if (!numbers.length || volumeOrder(volumeName) <= 1) return false;
  return !numbers.includes(1) && Math.min(...numbers) > 1;
}

function parseHandoffChapterNos(name) {
  const match = String(name).match(/第\s*0*(\d+)\s*章_to_第\s*0*(\d+)\s*章/);
  if (!match) return null;
  return { from: Number(match[1]), to: Number(match[2]) };
}

function replaceChapterRefsByMap(text, chapterMap) {
  let output = String(text || '');
  const entries = Array.from(chapterMap.entries()).sort((a, b) => b[0] - a[0]);
  for (const [oldNo, newNo] of entries) {
    output = output.replace(new RegExp(`第\\s*0*${oldNo}\\s*章`, 'g'), `第${pad(newNo)}章`);
  }
  return output;
}

function walkTextFiles(dir, visit) {
  for (const name of readDirSafe(dir)) {
    const abs = path.join(dir, name);
    if (isDirectory(abs)) walkTextFiles(abs, visit);
    else if (isTextFile(abs)) visit(abs);
  }
}

function replaceChapterNo(name, oldNo, newNo) {
  return String(name).replace(new RegExp(`第\\s*0*${oldNo}\\s*章`), `第${pad(newNo)}章`);
}

function option(name) {
  const eq = args.find(arg => arg.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] || '' : '';
}

function numberOption(name) {
  const value = Number(option(name) || 0);
  return Number.isFinite(value) ? value : 0;
}

function volumeOrder(volumeName) {
  const arabic = String(volumeName).match(/第\s*([0-9]+)\s*卷/);
  return arabic ? Number(arabic[1]) : 1;
}

function isDirectory(dir) {
  try {
    return fs.statSync(dir).isDirectory();
  } catch {
    return false;
  }
}

function isTextFile(file) {
  try {
    return fs.statSync(file).isFile() && /\.(md|txt|json|jsonl|tsv|csv)$/i.test(file);
  } catch {
    return false;
  }
}

function pad(value) {
  return String(Number(value || 0)).padStart(3, '0');
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
