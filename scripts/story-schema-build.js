#!/usr/bin/env node
const path = require('path');
const fs = require('fs');
const {
  ensureDir,
  readText,
  readDirSafe,
  parseChapterNo,
  nowIso,
  stripMarkdownBullet,
  writeJson,
  writeJsonl,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = args.find(arg => !arg.startsWith('--'));
if (!projectRoot) fail('usage: story-schema-build.js <project-root> [--write] [--json]');

const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');
const root = path.resolve(projectRoot);

const schema = buildStorySchema(root);
if (schema.chapters.length === 0) fail('no chapters found');
if (shouldWrite) writeStorySchema(root, schema);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(schema, null, 2)}\n`);
} else {
  console.log(`story schema built: ${schema.storyState.bookTitle} (${schema.chapters.length} chapters, ${schema.promises.length} promises)`);
  if (shouldWrite) console.log('wrote 追踪/schema');
}

function buildStorySchema(projectDir) {
  const generatedAt = nowIso();
  const outlines = collectChapterFiles(projectDir, '大纲', /^细纲_第.+\.md$/);
  const drafts = collectChapterFiles(projectDir, '正文', /^第.+\.md$/);
  const contracts = collectChapterFiles(projectDir, path.join('追踪', '章节契约'), /^第.+\.md$/);
  const handoffs = collectHandoffFiles(projectDir);
  const assets = readChapterAssets(projectDir);
  const chapterKeys = Array.from(new Set([
    ...outlines.keys(),
    ...drafts.keys(),
    ...contracts.keys(),
    ...handoffs.keys(),
  ])).sort(compareChapterKeys);

  const chapters = chapterKeys.map((chapterKey, index) => buildChapter(projectDir, chapterKey, {
    outline: outlines.get(chapterKey),
    draft: drafts.get(chapterKey),
    contract: contracts.get(chapterKey),
    handoff: handoffs.get(chapterKey),
  }, generatedAt, index + 1, assets));

  const promises = extractPromises(projectDir, chapters);
  const plotUnits = extractPlotUnits(projectDir, chapters);
  const missingBeatSheets = 0;
  const failedAudits = chapters.filter(chapter => chapter.auditStatus === 'fail').length;
  const issues = [];
  for (const chapter of chapters) {
    for (const field of ['outlinePath', 'contractPath', 'draftPath']) {
      if (!chapter[field]) {
        issues.push({
          code: `Chapter_Missing_${field}`,
          severity: 'P2',
          target: chapter.chapterId,
          message: `${chapter.chapterId} 缺少 ${field}`,
          suggestedAction: '补齐章节大纲、正文和章节契约后重新生成 schema',
        });
      }
    }
  }
  for (const promise of promises.filter(item => ['open', 'warming', 'deferred'].includes(item.status))) {
    issues.push({
      code: 'Promise_Open',
      severity: 'P3',
      target: promise.id,
      message: '伏笔或承诺已记录，等待后续章节兑现',
      suggestedAction: '在后续交接包或章节契约中继续继承并安排兑现',
    });
  }

  const bookTitle = inferBookTitle(projectDir, chapters);
  const currentChapter = chapters.length ? Math.max(...chapters.map(chapter => chapter.chapterNo)) : 0;
  const currentVolume = chapters.length ? chapters[chapters.length - 1].volume : '第1卷';
  const activeArc = inferActiveArc(projectDir, chapters);
  const layers = buildStoryLayers(projectDir, chapters, outlines, drafts, contracts, handoffs, promises);
  const storyState = {
    schemaVersion: '0.8.0',
    bookTitle,
    mode: 'longform',
    currentChapter,
    currentVolume,
    status: 'drafting',
    updatedAt: generatedAt,
    activeArc,
    nextAction: {
      id: 'write-next-chapter',
      label: `写第${padChapter(currentChapter + 1)}章`,
      reason: currentChapter > 0 ? `第${padChapter(currentChapter)}章 schema 已生成` : '等待创建第一章',
    },
    project: {
      root: projectDir,
      generatedBy: 'story-schema-build.js',
    },
    layers: {
      plotHealth: layers.plotHealth,
      promiseHealth: layers.promiseHealth,
      characterHealth: layers.characterHealth,
      chapterHealth: layers.chapterHealth,
    },
  };

  const health = {
    schemaVersion: '0.8.0',
    status: issues.some(issue => issue.severity === 'P0' || issue.severity === 'P1') ? 'fail' : (issues.length ? 'warn' : 'pass'),
    updatedAt: generatedAt,
    summary: {
      chapters: chapters.length,
      openPromises: promises.filter(promise => promise.status === 'open').length,
      overduePromises: 0,
      failedAudits,
      missingBeatSheets,
    },
    issues,
  };

  const beatSheets = chapters.map(chapter => buildBeatSheet(projectDir, chapter));
  return {
    storyState,
    chapters,
    chapterIndex: chapters,
    promises,
    plotUnits,
    health,
    beatSheets,
    ledgers: buildLedgers(storyState, chapters, promises, layers),
  };
}

function collectChapterFiles(projectDir, relDir, pattern) {
  const baseDir = path.join(projectDir, relDir);
  const entries = new Map();
  walkFiles(baseDir, relDir, file => {
    const base = path.basename(file.relPath);
    if (!pattern.test(base)) return;
    const chapterNo = parseChapterNo(base);
    if (!chapterNo) return;
    const volume = inferVolumeFromRelPath(file.relPath);
    entries.set(chapterKey(volume, chapterNo), {
      relPath: file.relPath,
      absPath: file.absPath,
      text: readText(file.absPath),
      volume,
      volumeChapterNo: chapterNo,
    });
  });
  return entries;
}

function collectHandoffFiles(projectDir) {
  const relDir = path.join('追踪', '交接包');
  const baseDir = path.join(projectDir, relDir);
  const entries = new Map();
  walkFiles(baseDir, relDir, file => {
    const base = path.basename(file.relPath);
    if (!/^第.+\.md$/.test(base)) return;
    const chapterNo = parseChapterNo(base);
    if (!chapterNo) return;
    const volume = inferVolumeFromRelPath(file.relPath);
    entries.set(chapterKey(volume, chapterNo), {
      relPath: file.relPath,
      absPath: file.absPath,
      text: readText(file.absPath),
      volume,
      volumeChapterNo: chapterNo,
    });
  });
  return entries;
}

function buildChapter(projectDir, sourceKey, sources, updatedAt, globalDraftOrder, assets) {
  const source = sources.draft || sources.outline || sources.contract || sources.handoff || {};
  const volume = source.volume || splitChapterKey(sourceKey).volume || '第1卷';
  const volumeChapterNo = source.volumeChapterNo || splitChapterKey(sourceKey).volumeChapterNo || globalDraftOrder;
  const asset = findChapterAsset(assets, sourceKey, sources);
  const title = asset?.title || inferChapterTitle(volumeChapterNo, sources);
  const missing = ['outline', 'draft', 'contract'].filter(key => !sources[key]);
  return {
    chapterId: `第${padChapter(globalDraftOrder)}章`,
    chapterNo: globalDraftOrder,
    title,
    volume,
    volumeChapterNo,
    globalDraftOrder,
    assetId: asset?.assetId || '',
    outlinePath: sources.outline ? sources.outline.relPath : '',
    contractPath: sources.contract ? sources.contract.relPath : '',
    draftPath: sources.draft ? sources.draft.relPath : '',
    handoffPath: sources.handoff ? sources.handoff.relPath : '',
    auditStatus: missing.length ? 'warn' : 'pass',
    wordCount: sources.draft ? estimateWordCount(sources.draft.text) : 0,
    updatedAt,
  };
}

function inferChapterTitle(chapterNo, sources) {
  for (const source of [sources.draft, sources.outline, sources.contract]) {
    if (!source) continue;
    const heading = source.text.split(/\r?\n/).find(line => /^#\s+/.test(line));
    if (heading) {
      const title = heading.replace(/^#+\s*/, '').replace(/^第\s*0*[1-9]\d*\s*章\s*/, '').replace(/契约$/, '').trim();
      if (title) return title;
    }
    const base = path.basename(source.relPath, '.md').replace(/^细纲_/, '').replace(/^第\s*0*[1-9]\d*\s*章[_\s-]*/, '').trim();
    if (base && !/^第/.test(base)) return base;
  }
  return `第${padChapter(chapterNo)}章`;
}

function inferBookTitle(projectDir, chapters) {
  if (chapters.length && chapters[0].title && !/^第/.test(chapters[0].title)) return path.basename(projectDir);
  return path.basename(projectDir);
}

function inferActiveArc(projectDir, chapters) {
  for (const chapter of chapters) {
    if (!chapter.outlinePath) continue;
    const text = readText(path.join(projectDir, chapter.outlinePath));
    const line = findValueLine(text, ['主线目标', '本章目标', '目标']);
    if (line) return line;
  }
  return chapters.length ? `${chapters[0].chapterId} 起始剧情推进中` : '尚未生成章节';
}

function extractPromises(projectDir, chapters) {
  const byId = new Map(readExistingPromises(projectDir).map(item => [String(item.id || ''), item]));
  for (const chapter of chapters) {
    for (const relPath of [chapter.outlinePath, chapter.contractPath, chapter.handoffPath, chapter.draftPath].filter(Boolean)) {
      const text = readText(path.join(projectDir, relPath));
      for (const line of text.split(/\r?\n/)) {
        const matches = line.matchAll(/\b(P-[A-Za-z0-9_\-\u4e00-\u9fff]+)/g);
        for (const match of matches) {
          const id = match[1].replace(/[，。；;：:、,.!?！？]+$/, '');
          if (!byId.has(id)) {
            byId.set(id, {
              id,
              type: 'foreshadowing',
              introducedIn: chapter.chapterId,
              status: 'open',
              expectedPayoffRange: '',
              owner: 'story-architect',
              description: stripMarkdownBullet(line).replace(id, '').trim() || id,
              risk: 'untracked_payoff',
            });
          }
        }
      }
    }
  }
  return Array.from(byId.values()).sort((a, b) => a.id.localeCompare(b.id));
}

function readExistingPromises(projectDir) {
  const file = path.join(projectDir, '追踪', 'schema', 'promises.jsonl');
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(line => line.trim()).filter(Boolean).flatMap((line) => {
    try {
      const value = JSON.parse(line);
      return value && value.id ? [value] : [];
    } catch (_) {
      return [];
    }
  });
}

function extractPlotUnits(projectDir, chapters) {
  const grouped = new Map();
  for (const chapter of chapters) {
    if (!chapter.outlinePath) continue;
    const text = readText(path.join(projectDir, chapter.outlinePath));
    const id = findValueLine(text, ['剧情单元ID', '剧情单元 Id', '剧情单元 id', '单元ID']);
    if (!id) continue;
    const unit = grouped.get(id) || {
      id,
      volume: chapter.volume,
      chapters: [],
      readerExperience: [],
      terminalReserveActions: [],
    };
    unit.chapters.push({
      chapterId: chapter.chapterId,
      volume: chapter.volume,
      volumeChapterNo: chapter.volumeChapterNo,
      beatPosition: findValueLine(text, ['单元位置', '单元内位置', 'Beat Position']),
      outlinePath: chapter.outlinePath,
      draftPath: chapter.draftPath,
      drafted: Boolean(chapter.draftPath),
    });
    unit.readerExperience.push({
      chapterId: chapter.chapterId,
      readerQuestion: findValueLine(text, ['本章读者问题', '读者问题']),
      plannedPayoff: findValueLine(text, ['本章可见回报', '可见回报', '计划回报']),
    });
    const reserveAction = findValueLine(text, ['终局储备动作', '终局底牌动作']);
    if (reserveAction) unit.terminalReserveActions.push({ chapterId: chapter.chapterId, action: reserveAction });
    grouped.set(id, unit);
  }
  return Array.from(grouped.values()).map((unit) => {
    unit.chapters.sort((a, b) => a.volumeChapterNo - b.volumeChapterNo);
    const draftedCount = unit.chapters.filter(item => item.drafted).length;
    return {
      schemaVersion: '1.0.0',
      id: unit.id,
      volume: unit.volume,
      chapterRange: {
        start: unit.chapters[0].volumeChapterNo,
        end: unit.chapters[unit.chapters.length - 1].volumeChapterNo,
      },
      planningMode: draftedCount > 0 ? 'hard' : 'soft',
      planningState: draftedCount === 0
        ? 'pending'
        : draftedCount === unit.chapters.length ? 'locked' : 'active_locked_prefix',
      chapters: unit.chapters,
      readerExperience: unit.readerExperience,
      terminalReserveActions: unit.terminalReserveActions,
    };
  }).sort((a, b) => a.volume.localeCompare(b.volume, 'zh-Hans-CN') || a.chapterRange.start - b.chapterRange.start);
}

function buildBeatSheet(projectDir, chapter) {
  const sourceTexts = [chapter.contractPath, chapter.outlinePath, chapter.handoffPath]
    .filter(Boolean)
    .map(relPath => readText(path.join(projectDir, relPath)))
    .join('\n');
  const conflict = findValueLine(sourceTexts, ['必须出现', '主线目标', '本章目标']) || `${chapter.chapterId} 核心冲突推进`;
  const hook = findValueLine(sourceTexts, ['章尾钩子', '新增钩子']) || `${chapter.chapterId} 章尾留下后续问题`;
  const plotUnitId = findValueLine(sourceTexts, ['剧情单元ID', '剧情单元 Id', '剧情单元 id', '单元ID']);
  const beatPosition = findValueLine(sourceTexts, ['单元位置', '单元内位置', 'Beat Position']);
  const promiseIds = Array.from(new Set(Array.from(sourceTexts.matchAll(/\b(P-[A-Za-z0-9_\-\u4e00-\u9fff]+)/g)).map(match => match[1])));
  return {
    fileName: `${chapter.chapterId}.json`,
    data: {
      schemaVersion: '0.8.0',
      chapterId: chapter.chapterId,
      contractPath: chapter.contractPath,
      plotUnitId,
      beatPosition,
      beats: [
        {
          id: 'B1',
          type: 'conflict',
          summary: conflict,
          emotion: '压迫',
          mustShowOnPage: true,
          promiseIds,
          expectedPayoff: false,
        },
        {
          id: 'B2',
          type: 'hook',
          summary: hook,
          emotion: '疑问',
          mustShowOnPage: true,
          promiseIds,
          expectedPayoff: false,
        },
      ],
      required: {
        conflictBeat: true,
        emotionTurn: true,
        chapterEndHook: true,
      },
    },
  };
}

function findValueLine(text, labels) {
  for (const line of String(text || '').split(/\r?\n/)) {
    const clean = stripMarkdownBullet(line);
    for (const label of labels) {
      if (clean.startsWith(`${label}：`) || clean.startsWith(`${label}:`)) {
        return clean.replace(new RegExp(`^${escapeRegExp(label)}[：:]\\s*`), '').trim();
      }
    }
  }
  return '';
}

function writeStorySchema(projectDir, schema) {
  const schemaDir = path.join(projectDir, '追踪', 'schema');
  ensureDir(path.join(schemaDir, 'beat-sheets'));
  writeJson(path.join(schemaDir, 'story-state.json'), schema.storyState);
  writeJsonl(path.join(schemaDir, 'chapters.jsonl'), schema.chapters);
  writeJsonl(path.join(schemaDir, 'chapter-index.jsonl'), schema.chapterIndex);
  writeJsonl(path.join(schemaDir, 'promises.jsonl'), schema.promises);
  writeJsonl(path.join(schemaDir, 'plot-units.jsonl'), schema.plotUnits || []);
  writeJson(path.join(schemaDir, 'health.json'), schema.health);
  writeJson(path.join(schemaDir, 'character-ledger.json'), schema.ledgers.characterLedger);
  writeJson(path.join(schemaDir, 'plot-ledger.json'), schema.ledgers.plotLedger);
  writeJson(path.join(schemaDir, 'promise-ledger.json'), schema.ledgers.promiseLedger);
  for (const beatSheet of schema.beatSheets) {
    writeJson(path.join(schemaDir, 'beat-sheets', beatSheet.fileName), beatSheet.data);
  }
}

function buildStoryLayers(projectDir, chapters, outlines, drafts, contracts, handoffs, promises) {
  const plotFindings = [];
  const promiseFindings = [];
  const chapterFindings = [];

  if (outlines.size === 0) {
    plotFindings.push(finding('Plot_No_Outline', 'fail', '大纲', '未发现任何章节细纲'));
  }

  for (const chapter of chapters.filter(item => item.draftPath)) {
    const chapterId = chapter.chapterId;
    if (!outlines.has(chapterKey(chapter.volume, chapter.volumeChapterNo))) {
      plotFindings.push(finding('Plot_Draft_Without_Outline', 'warn', chapterId, '正文存在但缺少对应细纲'));
      chapterFindings.push(finding('Chapter_Text_Without_Outline', 'warn', chapterId, '正文存在但缺少对应细纲'));
    }
    if (!contracts.has(chapterKey(chapter.volume, chapter.volumeChapterNo))) {
      chapterFindings.push(finding('Chapter_Text_Without_Contract', 'fail', chapterId, '正文存在但缺少对应章节契约'));
    }
  }

  const writtenChapters = chapters.filter(chapter => chapter.draftPath);
  const latestWrittenChapter = writtenChapters[writtenChapters.length - 1];
  if (chapters.length > 1 && latestWrittenChapter && !handoffs.has(chapterKey(latestWrittenChapter.volume, latestWrittenChapter.volumeChapterNo))) {
    chapterFindings.push(finding(
      'Chapter_Latest_Missing_Handoff',
      'fail',
      latestWrittenChapter.chapterId,
      '最新已写章节缺少交接包',
    ));
  }

  for (const promise of promises.filter(item => ['open', 'warming', 'deferred'].includes(item.status))) {
    promiseFindings.push(finding('Promise_Open', 'warn', promise.id, promise.description || '承诺或伏笔等待兑现'));
  }
  for (const chapter of chapters) {
    const promiseIds = promiseIdsForChapter(projectDir, chapter);
    if (promiseIds.length && !chapter.contractPath) {
      promiseFindings.push(finding(
        'Promise_Without_Contract',
        'warn',
        chapter.chapterId,
        `${chapter.chapterId} 出现 promise IDs 但缺少章节契约: ${promiseIds.join(', ')}`,
      ));
    }
  }

  return {
    plotHealth: layerHealth(plotFindings),
    promiseHealth: layerHealth(promiseFindings),
    characterHealth: layerHealth([]),
    chapterHealth: layerHealth(chapterFindings),
  };
}

function layerHealth(findings) {
  return {
    status: findings.some(item => item.severity === 'fail') ? 'fail' : (findings.length ? 'warn' : 'pass'),
    findings,
  };
}

function finding(code, severity, target, message) {
  return { code, severity, target, message };
}

function promiseIdsForChapter(projectDir, chapter) {
  const text = [chapter.outlinePath, chapter.contractPath, chapter.handoffPath, chapter.draftPath]
    .filter(Boolean)
    .map(relPath => readText(path.join(projectDir, relPath)))
    .join('\n');
  return Array.from(new Set(Array.from(text.matchAll(/\b(P-[A-Za-z0-9_\-\u4e00-\u9fff]+)/g)).map(match => match[1])));
}

function buildLedgers(storyState, chapters, promises, layers) {
  return {
    characterLedger: {
      schemaVersion: '0.9.0',
      updatedAt: storyState.updatedAt,
      status: layers.characterHealth.status,
      characters: [],
      findings: layers.characterHealth.findings,
    },
    plotLedger: {
      schemaVersion: '0.9.0',
      updatedAt: storyState.updatedAt,
      status: layers.plotHealth.status,
      activeArc: storyState.activeArc,
      chapters: chapters.map(chapter => ({
        chapterId: chapter.chapterId,
        title: chapter.title,
        volume: chapter.volume,
        volumeChapterNo: chapter.volumeChapterNo,
        globalDraftOrder: chapter.globalDraftOrder,
        outlinePath: chapter.outlinePath,
        draftPath: chapter.draftPath,
      })),
      findings: layers.plotHealth.findings,
    },
    promiseLedger: {
      schemaVersion: '0.9.0',
      updatedAt: storyState.updatedAt,
      status: layers.promiseHealth.status,
      promises,
      findings: layers.promiseHealth.findings,
    },
  };
}

function estimateWordCount(text) {
  const compact = String(text || '').replace(/\s+/g, '');
  return compact.length;
}

function padChapter(chapterNo) {
  return String(chapterNo).padStart(3, '0');
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

function readChapterAssets(projectDir) {
  const text = readText(path.join(projectDir, '追踪', '章节资产.jsonl'), '');
  const byPath = new Map();
  const byKey = new Map();
  for (const line of text.split(/\r?\n/).map(item => item.trim()).filter(Boolean)) {
    let asset;
    try {
      asset = JSON.parse(line);
    } catch {
      continue;
    }
    if (asset.draftPath) byPath.set(asset.draftPath, asset);
    if (asset.volume && Number.isInteger(asset.volumeChapterNo)) {
      byKey.set(chapterKey(asset.volume, asset.volumeChapterNo), asset);
    }
  }
  return { byPath, byKey };
}

function findChapterAsset(assets, sourceKey, sources) {
  for (const source of [sources.draft, sources.outline, sources.contract, sources.handoff]) {
    if (source && assets.byPath.has(source.relPath)) return assets.byPath.get(source.relPath);
  }
  return assets.byKey.get(sourceKey) || null;
}

function inferVolumeFromRelPath(relPath) {
  const volume = slash(relPath).split('/').find(part => /^第\s*[0-9一二三四五六七八九十百千万两]+\s*卷$/.test(part));
  return volume || '第1卷';
}

function chapterKey(volume, volumeChapterNo) {
  return `${volume || '第1卷'}|${Number(volumeChapterNo) || 0}`;
}

function splitChapterKey(key) {
  const [volume, rawNo] = String(key || '').split('|');
  return { volume: volume || '第1卷', volumeChapterNo: Number(rawNo) || 0 };
}

function compareChapterKeys(a, b) {
  const left = splitChapterKey(a);
  const right = splitChapterKey(b);
  return volumeOrder(left.volume) - volumeOrder(right.volume)
    || left.volumeChapterNo - right.volumeChapterNo
    || a.localeCompare(b, 'zh-Hans-CN');
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

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

module.exports = { buildStorySchema, writeStorySchema };
