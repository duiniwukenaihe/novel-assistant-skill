#!/usr/bin/env node
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { projectAcceptedQuality } = require('./lib/detail-outline-quality-projection');
const {
  readText,
  readDirSafe,
  parseChapterNo,
  nowIso,
  stripMarkdownBullet,
  writeJson,
} = require('./lib/oh-story-artifacts');

const args = process.argv.slice(2);
const projectRoot = firstPositional(args, ['--chapter', '--quality-result']);
const chapterIndex = args.indexOf('--chapter');
if (!projectRoot || chapterIndex === -1 || !args[chapterIndex + 1]) {
  fail('usage: current-contract-build.js <project-root> --chapter N [--quality-result <relative-path>] [--write] [--json]');
}

const root = path.resolve(projectRoot);
const chapterNo = Number(args[chapterIndex + 1]);
if (!Number.isInteger(chapterNo) || chapterNo <= 0) fail('--chapter must be positive integer');

const shouldWrite = args.includes('--write');
const jsonOutput = args.includes('--json');
const qualityResultPath = optionValue(args, '--quality-result');
const contract = buildCurrentContract(root, chapterNo, qualityResultPath);
if (shouldWrite) writeJson(path.join(root, '追踪', 'schema', 'current-contract.json'), contract);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(contract, null, 2)}\n`);
} else {
  console.log(`current contract: 第${padChapter(chapterNo)}章 (${contract.gate.status})`);
  if (shouldWrite) console.log('wrote 追踪/schema/current-contract.json');
}

function buildCurrentContract(projectDir, targetChapterNo, qualityResultPath = '') {
  const outline = findChapterFile(projectDir, '大纲', /^细纲_第.+\.md$/, targetChapterNo);
  const chapterContract = findChapterFile(projectDir, path.join('追踪', '章节契约'), /^第.+\.md$/, targetChapterNo);
  const handoff = findHandoffFile(projectDir, targetChapterNo - 1);
  const sourceFiles = {
    outline: outline ? outline.relPath : null,
    contract: chapterContract ? chapterContract.relPath : null,
    previousHandoff: handoff ? handoff.relPath : null,
  };
  const outlineText = outline ? outline.text : '';
  const contractText = chapterContract ? chapterContract.text : '';
  const handoffText = handoff ? handoff.text : '';
  const combined = [outlineText, contractText, handoffText].join('\n');
  const missingFindings = [];
  if (!outline) missingFindings.push(issue('missing_outline', `第${padChapter(targetChapterNo)}章缺少细纲`));
  if (!chapterContract) missingFindings.push(issue('missing_contract', `第${padChapter(targetChapterNo)}章缺少章节契约`));

  let status = 'pass';
  if (!outline && !chapterContract) status = 'fail';
  else if (!outline || !chapterContract) status = 'warn';

  const quality = evaluateQualityResult(projectDir, outline, outlineText, qualityResultPath);
  if (quality.blockingFinding) status = 'fail';
  else if (quality.warning && status === 'pass') status = 'warn';

  const mustInclude = unique([
    ...extractKeywordLines(outlineText, ['必须', '兑现', '推进', '出现', '处理'], true),
    ...extractKeywordLines(contractText, ['必须', '兑现', '推进', '出现', '处理'], true),
    ...extractKeywordLines(handoffText, ['必须', '兑现', '推进', '出现', '处理'], true),
    ...quality.projection.contractProjection.filter(value => typeof value === 'string'),
  ]);
  const forbiddenChanges = unique([
    ...extractKeywordLines(outlineText, ['禁止', '不得', '不可'], true),
    ...extractKeywordLines(contractText, ['禁止', '不得', '不可'], true),
    ...extractKeywordLines(handoffText, ['禁止', '不得', '不可'], true),
  ]);

  return {
    schemaVersion: '0.9.0',
    generatedAt: nowIso(),
    chapterNo: targetChapterNo,
    sourceFiles,
    mustInclude,
    forbiddenChanges,
    inheritedPromiseIds: unique(extractIds(combined, /\b(P-[A-Za-z0-9_\-\u4e00-\u9fff]+)/g)),
    buryPointIds: unique(extractIds(combined, /\b(B\d+-[A-Za-z0-9_\-\u4e00-\u9fff]+)/g)),
    chapterEndHook: findChapterEndHook(combined, contractText),
    qualityGate: quality.projection.beatSheetQualityGate,
    memoryProjection: quality.projection.memoryProjection,
    plotUnit: projectPlotUnit(quality.projection.narrativeContract),
    readerExperience: projectReaderExperience(quality.projection.narrativeContract),
    terminalReserve: projectTerminalReserve(quality.projection.narrativeContract),
    gate: {
      status,
      blockingFindings: [
        ...(status === 'fail' ? missingFindings : []),
        ...(quality.blockingFinding ? [quality.blockingFinding] : []),
      ],
      warnings: [
        ...(status === 'warn' ? missingFindings : []),
        ...(quality.warning ? [quality.warning] : []),
      ],
    },
  };
}

function projectPlotUnit(contract) {
  const value = contract && contract.plot_unit && typeof contract.plot_unit === 'object' ? contract.plot_unit : {};
  return { id: String(value.id || ''), beatPosition: String(value.beat_position || '') };
}

function projectReaderExperience(contract) {
  const value = contract && contract.reader_experience && typeof contract.reader_experience === 'object'
    ? contract.reader_experience
    : {};
  return {
    readerQuestion: String(value.reader_question || ''),
    plannedPayoff: String(value.planned_payoff || ''),
    keyTurn: String(value.key_turn || ''),
    netChange: String(value.net_change || ''),
    inheritedHookResponsibility: String(value.inherited_hook_responsibility || ''),
  };
}

function projectTerminalReserve(contract) {
  const value = contract && contract.terminal_reserve && typeof contract.terminal_reserve === 'object'
    ? contract.terminal_reserve
    : {};
  return { action: String(value.action || '') };
}

function evaluateQualityResult(projectDir, outline, outlineText, qualityResultPath) {
  const empty = {
    projection: projectAcceptedQuality(null),
    blockingFinding: null,
    warning: null,
  };
  if (!outline) return empty;

  const requiresQualityResult = isQualityManagedOutline(outlineText);
  if (!qualityResultPath) {
    if (requiresQualityResult) {
      return {
        ...empty,
        blockingFinding: issue('detail_outline_quality_missing', '新版细纲缺少已接受的细纲质量结果。'),
      };
    }
    return {
      ...empty,
      warning: issue('detail_outline_quality_legacy', '旧格式细纲尚未完成细纲质量审阅。'),
    };
  }

  let result;
  try {
    result = readQualityResult(projectDir, qualityResultPath);
  } catch (error) {
    return {
      ...empty,
      blockingFinding: issue('detail_outline_quality_result_invalid', `细纲质量结果不可用：${error.message}`),
    };
  }

  const quality = unwrapQualityResult(result);
  if (!quality) {
    return {
      ...empty,
      blockingFinding: issue('detail_outline_quality_result_invalid', '细纲质量结果缺少 detail_outline_quality 对象。'),
    };
  }
  if (!['pass', 'pass_with_advisory'].includes(String(quality.status || ''))) {
    return {
      ...empty,
      blockingFinding: issue('detail_outline_quality_not_accepted', '细纲质量结果尚未通过，不能投影到章节契约。'),
    };
  }

  let resultOutline;
  try {
    resultOutline = resolveProjectFile(projectDir, quality.outline_path, '细纲路径');
  } catch (error) {
    return {
      ...empty,
      blockingFinding: issue('detail_outline_quality_outline_path_mismatch', `细纲质量结果路径无效：${error.message}`),
    };
  }
  if (resultOutline !== fs.realpathSync(outline.absPath)) {
    return {
      ...empty,
      blockingFinding: issue('detail_outline_quality_outline_path_mismatch', '细纲质量结果不属于当前章节细纲。'),
    };
  }

  const actualHash = crypto.createHash('sha256').update(fs.readFileSync(outline.absPath)).digest('hex');
  if (String(quality.outline_sha256 || '') !== actualHash) {
    return {
      ...empty,
      blockingFinding: issue('detail_outline_quality_stale', '细纲已变更，质量结果的 outline_sha256 已过期。'),
    };
  }
  return {
    ...empty,
    projection: projectAcceptedQuality(quality),
  };
}

function isQualityManagedOutline(text) {
  const source = String(text || '');
  return /^\s*#{1,6}\s*质量触发\s*$/m.test(source)
    && /^\s*#{1,6}\s*呈现与连续性\s*$/m.test(source);
}

function readQualityResult(projectDir, relativePath) {
  const file = resolveProjectFile(projectDir, relativePath, '质量结果');
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`不是有效 JSON：${error.message}`);
  }
}

function unwrapQualityResult(result) {
  if (!result || typeof result !== 'object' || Array.isArray(result)) return null;
  const nested = result.outputs && result.outputs.detail_outline_quality;
  if (nested && typeof nested === 'object' && !Array.isArray(nested)) return nested;
  return result;
}

function resolveProjectFile(projectDir, relativePath, label) {
  const root = fs.realpathSync(projectDir);
  const value = String(relativePath || '');
  if (!value || path.isAbsolute(value)) throw new Error(`${label}必须是项目根目录内的相对路径`);
  const candidate = path.resolve(root, value);
  if (!isInside(root, candidate)) throw new Error(`${label}越出项目根目录`);
  let resolved;
  try {
    resolved = fs.realpathSync(candidate);
  } catch (_) {
    throw new Error(`${label}不存在`);
  }
  if (!isInside(root, resolved) || !fs.statSync(resolved).isFile()) {
    throw new Error(`${label}不是项目根目录内的普通文件`);
  }
  return resolved;
}

function isInside(root, target) {
  return target.startsWith(`${root}${path.sep}`);
}

function findChapterFile(projectDir, relDir, pattern, targetChapterNo) {
  const dir = path.join(projectDir, relDir);
  for (const name of readDirSafe(dir)) {
    if (!pattern.test(name)) continue;
    if (parseChapterNo(name) !== targetChapterNo) continue;
    return {
      relPath: path.join(relDir, name),
      absPath: path.join(dir, name),
      text: readText(path.join(dir, name)),
    };
  }
  return null;
}

function findHandoffFile(projectDir, fromChapterNo) {
  if (fromChapterNo <= 0) return null;
  const relDir = path.join('追踪', '交接包');
  const dir = path.join(projectDir, relDir);
  for (const name of readDirSafe(dir)) {
    if (!/^第.+\.md$/.test(name)) continue;
    if (parseChapterNo(name) !== fromChapterNo) continue;
    return {
      relPath: path.join(relDir, name),
      absPath: path.join(dir, name),
      text: readText(path.join(dir, name)),
    };
  }
  return null;
}

function extractValues(text, labels) {
  const values = [];
  for (const line of String(text || '').split(/\r?\n/)) {
    const clean = stripMarkdownBullet(line);
    for (const label of labels) {
      if (clean.startsWith(`${label}：`) || clean.startsWith(`${label}:`)) {
        const value = clean.replace(new RegExp(`^${escapeRegExp(label)}[：:]\\s*`), '').trim();
        if (value) values.push(value);
      }
    }
  }
  return values;
}

function extractKeywordLines(text, keywords, bulletOnly) {
  const values = [];
  for (const line of String(text || '').split(/\r?\n/)) {
    if (bulletOnly && !isMarkdownBullet(line)) continue;
    const clean = stripMarkdownBullet(line);
    if (keywords.some(keyword => clean.includes(keyword))) values.push(clean);
  }
  return values;
}

function findChapterEndHook(combinedText, contractText) {
  const hook = extractKeywordLines(combinedText, ['章尾', '钩子', '悬念'], false)[0];
  if (hook) return hook;
  return lastBullet(contractText);
}

function lastBullet(text) {
  const bullets = String(text || '')
    .split(/\r?\n/)
    .filter(isMarkdownBullet)
    .map(stripMarkdownBullet)
    .filter(Boolean);
  return bullets[bullets.length - 1] || '';
}

function isMarkdownBullet(line) {
  return /^\s*(?:[-*+]|\d+[.)]|[（(]?\d+[）)])\s+/.test(String(line || ''));
}

function extractIds(text, regex) {
  return Array.from(String(text || '').matchAll(regex)).map(match => match[1].replace(/[，。；;：:、,.!?！？]+$/, ''));
}

function unique(values) {
  return Array.from(new Set(values.filter(Boolean)));
}

function issue(code, message) {
  return { code, message };
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function padChapter(chapterNo) {
  return String(chapterNo).padStart(3, '0');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

function optionValue(argv, option) {
  const index = argv.indexOf(option);
  return index === -1 ? '' : (argv[index + 1] || '');
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

module.exports = { buildCurrentContract };
