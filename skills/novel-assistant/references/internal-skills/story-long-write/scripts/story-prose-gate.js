#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node story-prose-gate.js <book-dir|draft-file> [--chapter N] [--json] [--write]

Checks canonical prose drafts before a story skill may report completion:
  - rejects dash density overuse, invalid dash forms, ellipsis pauses, and markdown divider lines
  - rejects per-character dash corruption
  - detects legacy flat chapter duplicates when volume-local drafts exist
  - writes 追踪/checks/prose-gate/*.md when --write is provided
`;

const args = process.argv.slice(2);
const target = args.find(arg => !arg.startsWith('--'));
const jsonOutput = args.includes('--json');
const shouldWrite = args.includes('--write');
const chapterArg = readOption('--chapter');

if (!target || args.includes('-h') || args.includes('--help')) {
  console.log(USAGE.trimEnd());
  process.exit(target ? 0 : 2);
}

const targetPath = path.resolve(target);
const stat = safeStat(targetPath);
if (!stat) fail(`not found: ${target}`);

const root = stat.isFile() ? findBookRoot(path.dirname(targetPath)) : targetPath;
const inspected = stat.isFile()
  ? [draftInfo(root, targetPath)].filter(Boolean)
  : canonicalDrafts(root, chapterArg ? Number(chapterArg) : 0);

const findings = [];
if (!stat.isFile()) findings.push(...legacyDuplicateFindings(root, chapterArg ? Number(chapterArg) : 0));

for (const draft of inspected) {
  findings.push(...scanProseFile(draft.absPath, draft.relPath));
}

const status = findings.length ? 'fail' : 'pass';
const result = {
  status,
  root,
  inspected: inspected.map(item => item.relPath),
  findings,
};

if (shouldWrite && !stat.isFile()) writeReport(root, result, chapterArg || 'all');

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  printHuman(result);
}

process.exit(status === 'pass' ? 0 : 2);

function readOption(name) {
  const eq = args.find(arg => arg.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const index = args.indexOf(name);
  if (index >= 0) return args[index + 1] || '';
  return '';
}

function fail(message) {
  if (jsonOutput) process.stdout.write(`${JSON.stringify({ status: 'fail', error: message }, null, 2)}\n`);
  else console.error(message);
  process.exit(2);
}

function safeStat(file) {
  try {
    return fs.statSync(file);
  } catch {
    return null;
  }
}

function findBookRoot(startDir) {
  let current = path.resolve(startDir);
  for (;;) {
    if (fs.existsSync(path.join(current, '正文')) || fs.existsSync(path.join(current, '追踪'))) return current;
    const parent = path.dirname(current);
    if (parent === current) return path.resolve(startDir);
    current = parent;
  }
}

function canonicalDrafts(bookRoot, chapterNo) {
  return preferCanonicalDrafts(collectDrafts(bookRoot))
    .filter(item => !chapterNo || item.chapterNo === chapterNo)
    .sort(compareDrafts);
}

function collectDrafts(bookRoot) {
  const base = path.join(bookRoot, '正文');
  const out = [];
  walk(base, file => {
    const relPath = slash(path.relative(bookRoot, file));
    const baseName = path.basename(relPath);
    if (!/^第.+章.*\.(md|txt)$/i.test(baseName)) return;
    if (/\.bak/i.test(baseName) || relPath.includes('/legacy-flat-layout/')) return;
    const info = draftInfo(bookRoot, file);
    if (info) out.push(info);
  });
  return out;
}

function draftInfo(bookRoot, absPath) {
  const relPath = slash(path.relative(bookRoot, absPath));
  if (!isProseDraftRelPath(relPath)) return null;
  const chapterNo = parseChapterNo(path.basename(relPath)) || (isStandaloneBody(relPath) ? 1 : 0);
  if (!chapterNo) return null;
  return {
    absPath,
    relPath,
    volume: inferVolume(relPath),
    chapterNo,
    volumeLocal: isVolumeLocalPath(relPath),
  };
}

function isProseDraftRelPath(relPath) {
  const normalized = slash(relPath);
  if (isStandaloneBody(normalized)) return true;
  if (!normalized.startsWith('正文/')) return false;
  return /^第.+章.*\.(md|txt)$/i.test(path.basename(normalized));
}

function isStandaloneBody(relPath) {
  const normalized = slash(relPath);
  return normalized === '正文.md' || normalized.endsWith('/正文.md');
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

function preferCanonicalDrafts(files) {
  const byKey = new Map();
  for (const file of files) {
    const key = `${file.volume}|${file.chapterNo}`;
    const prev = byKey.get(key);
    if (!prev || compareCanonical(file, prev) < 0) byKey.set(key, file);
  }
  return Array.from(byKey.values());
}

function legacyDuplicateFindings(bookRoot, chapterNo) {
  const files = collectDrafts(bookRoot);
  const canonical = new Set(preferCanonicalDrafts(files).map(item => item.relPath));
  const findings = [];
  for (const file of files) {
    if (chapterNo && file.chapterNo !== chapterNo) continue;
    if (canonical.has(file.relPath)) continue;
    const preferred = [...canonical]
      .map(rel => files.find(item => item.relPath === rel))
      .find(item => item && item.volume === file.volume && item.chapterNo === file.chapterNo);
    findings.push({
      type: 'legacy-duplicate',
      severity: 'fail',
      file: file.relPath,
      line: 1,
      message: `同卷同章存在非 canonical 正文稿；当前应使用 ${preferred?.relPath || '卷内正文'}，请移入 正文/legacy-flat-layout 或版本快照。`,
    });
  }
  return findings;
}

function compareCanonical(a, b) {
  if (a.volumeLocal !== b.volumeLocal) return a.volumeLocal ? -1 : 1;
  return compareDrafts(a, b);
}

function compareDrafts(a, b) {
  return volumeOrder(a.volume) - volumeOrder(b.volume)
    || a.chapterNo - b.chapterNo
    || a.relPath.localeCompare(b.relPath, 'zh-CN');
}

function scanProseFile(absPath, relPath) {
  const text = fs.readFileSync(absPath, 'utf8');
  const lines = text.split(/\r?\n/);
  const findings = [];
  let inFence = false;
  let inFrontMatter = lines[0]?.trim() === '---';
  let dashCount = 0;
  let proseChars = 0;

  lines.forEach((line, index) => {
    const lineNo = index + 1;
    const trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      return;
    }
    if (inFrontMatter) {
      if (index > 0 && trimmed === '---') inFrontMatter = false;
      return;
    }
    if (inFence || trimmed.startsWith('#')) return;

    proseChars += line.replace(/\s/g, '').length;
    if (trimmed === '---') {
      findings.push(finding('markdown-divider', relPath, lineNo, 1, '正文中残留 markdown 分隔线。'));
    }
    for (const leak of metaLeakMatches(line)) {
      findings.push(finding('prose-meta-leak', relPath, lineNo, leak.column, `正文混入写作工程词“${leak.phrase}”；改成角色能感知的动作、物件、时间或情绪，不要让人物说出章节/细纲/任务描述。`));
    }
    if (looksLikePerCharacterDash(line)) {
      findings.push(finding('per-character-dash', relPath, lineNo, 1, '逐字破折号化坏稿，必须回炉重写。'));
      dashCount += (line.match(/——|—|--+/g) || []).length;
      return;
    }
    for (const match of line.matchAll(/--+|(?<!—)—(?!—)/g)) {
      findings.push(finding('invalid-dash', relPath, lineNo, match.index + 1, '正文不保留单个 — 或双连字符 --；改成逗号、句号、动作 beat 或短句。'));
    }
    for (const match of line.matchAll(/——/g)) {
      dashCount += 1;
    }
    for (const match of line.matchAll(/…+|\.{3,}/g)) {
      findings.push(finding('ellipsis', relPath, lineNo, match.index + 1, '正文不使用省略号硬造停顿。'));
    }
  });

  if (isDashDensityTooHigh(dashCount, proseChars)) {
    findings.push({
      type: 'dash-density',
      severity: 'fail',
      file: relPath,
      line: 1,
      column: 1,
      message: `正文约 ${proseChars} 字出现 ${dashCount} 处破折号；已超过“合理少量、有功能使用”边界，必须先修复再汇报完成。`,
    });
  }
  return findings;
}

function finding(type, file, line, column, message) {
  return { type, severity: 'fail', file, line, column, message };
}

function looksLikePerCharacterDash(text) {
  return /(?:[\u3400-\u9FFF0-9A-Za-z]——){4,}[\u3400-\u9FFF0-9A-Za-z]?/.test(text);
}

function metaLeakMatches(line) {
  if (isInWorldReadingContext(line)) return [];
  if (isInWorldSystemPanel(line)) return [];
  const patterns = [
    /该到下一章了/g,
    /(?<!该)到下一章了/g,
    /下一章再/g,
    /本章(?:任务|目标|节点|内容|剧情|完成|结束)/g,
    /这一章(?:任务|目标|节点|内容|剧情|完成|结束)/g,
    /(?:上一章|上章|前一章|前文|后文)(?:里|中|已经|还|的)?/g,
    /(?:细纲|章节契约|剧情节点|情节节点|爽点设计|读者期待)/g,
    /(?:本章|这一章|细纲|章节|执行范围|审稿人|作者输出格式).{0,8}任务描述/g,
    /任务描述.{0,8}(?:本章|这一章|细纲|章节|执行范围|审稿人|作者输出格式)/g,
  ];
  const out = [];
  for (const pattern of patterns) {
    for (const match of line.matchAll(pattern)) {
      addMetaLeak(out, match[0], match.index || 0);
    }
  }
  return out;
}

function addMetaLeak(out, phrase, index) {
  const start = index;
  const end = index + String(phrase).length;
  if (out.some(item => rangesOverlap(start, end, item.index, item.index + item.phrase.length))) return;
  out.push({ phrase, column: index + 1, index });
}

function rangesOverlap(aStart, aEnd, bStart, bEnd) {
  return aStart < bEnd && bStart < aEnd;
}

function isInWorldReadingContext(line) {
  return /(翻到|翻开|翻过|读到|看到|写着|抄到|念到|书中|旧书|经文|课本|教材|卷宗|竹简|书页|纸页|目录|卷册).{0,12}(上一章|下一章|这一章|本章)/.test(line)
    || /(上一章|下一章|这一章|本章).{0,12}(经文|课本|教材|卷宗|竹简|书页|纸页|旧书|书中)/.test(line);
}

function isInWorldSystemPanel(line) {
  const text = line.trim();
  return /^[【\[]?(任务描述|任务奖励|系统提示|主线任务|支线任务|当前任务)[：:]/.test(text)
    || /^[【\[]?(任务描述|任务奖励|系统提示|主线任务|支线任务|当前任务)[：:].*[】\]]$/.test(text);
}

function isDashDensityTooHigh(dashCount, proseChars) {
  if (dashCount <= 0) return false;
  const allowance = Math.max(2, Math.floor(proseChars / 1800));
  return dashCount > allowance;
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

function volumeOrder(volume) {
  const arabic = String(volume).match(/第\s*([0-9]+)\s*卷/);
  if (arabic) return Number(arabic[1]);
  const chinese = String(volume).match(/第\s*([一二三四五六七八九十两]+)\s*卷/);
  if (!chinese) return 1;
  const values = { 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  const text = chinese[1];
  if (text === '十') return 10;
  const ten = text.indexOf('十');
  if (ten >= 0) {
    const left = text.slice(0, ten);
    const right = text.slice(ten + 1);
    return (left ? values[left] : 1) * 10 + (right ? values[right] : 0);
  }
  return values[text] || 1;
}

function writeReport(bookRoot, result, chapter) {
  const dir = path.join(bookRoot, '追踪', 'checks', 'prose-gate');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `第${String(chapter).padStart(3, '0')}章.md`);
  const lines = [
    `# Prose Gate 第${chapter}章`,
    '',
    `- status: ${result.status}`,
    `- inspected: ${result.inspected.join('；') || '无'}`,
    '',
    '## Findings',
    ...(result.findings.length ? result.findings.map(item => `- ${item.type} ${item.file}:${item.line}:${item.column || 1} ${item.message}`) : ['- 无']),
    '',
  ];
  fs.writeFileSync(file, lines.join('\n'), 'utf8');
}

function printHuman(result) {
  console.log(`story prose gate: ${result.status}`);
  for (const file of result.inspected) console.log(`checked: ${file}`);
  for (const item of result.findings) {
    console.log(`${item.file}:${item.line}:${item.column || 1}: ${item.type}: ${item.message}`);
  }
}

function slash(value) {
  return String(value || '').replaceAll(path.sep, '/');
}
