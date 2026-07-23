#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node normalize-punctuation.js [--check] [--quote-mode keep|ascii|yan|mainland] <file...>

Normalize正文 punctuation deterministically:
  - replace ellipses, em dashes, and double hyphens with Chinese punctuation
  - reject per-character dash corruption; this requires prose rewrite, not cleanup
  - remove markdown divider lines (---) from正文
  - keep quote style by default; convert quotes only when explicitly requested
`;

const options = {
  check: false,
  quoteMode: 'keep',
  files: [],
};

for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === '--check') {
    options.check = true;
  } else if (arg === '--quote-mode') {
    const value = process.argv[i + 1];
    if (!value) die('--quote-mode requires keep, ascii, yan, or mainland');
    options.quoteMode = value;
    i += 1;
  } else if (arg.startsWith('--quote-mode=')) {
    options.quoteMode = arg.slice('--quote-mode='.length);
  } else if (arg === '-h' || arg === '--help') {
    process.stdout.write(USAGE);
    process.exit(0);
  } else if (arg.startsWith('-')) {
    die(`Unknown option: ${arg}`);
  } else {
    options.files.push(arg);
  }
}

if (!['keep', 'ascii', 'yan', 'mainland'].includes(options.quoteMode)) {
  die(`Invalid --quote-mode: ${options.quoteMode}`);
}
if (options.files.length === 0) {
  die('No files provided');
}

let totalFindings = 0;
let changedFiles = 0;
let failed = false;

for (const file of options.files) {
  const fullPath = path.resolve(file);
  let input;
  try {
    input = fs.readFileSync(fullPath, 'utf8');
  } catch (error) {
    failed = true;
    console.error(`${file}: unable to read (${error.message})`);
    continue;
  }

  const result = normalizeDocument(input, options.quoteMode);
  totalFindings += result.findings.length;

  if (options.check) {
    for (const finding of result.findings) {
      console.log(`${file}:${finding.line}:${finding.column}: ${finding.type}: ${finding.message}`);
    }
    if (result.unrecoverable) failed = true;
    continue;
  }

  if (result.unrecoverable) {
    failed = true;
    for (const finding of result.findings) {
      console.error(`${file}:${finding.line}:${finding.column}: ${finding.type}: ${finding.message}`);
    }
    const hasPerCharacterDash = result.findings.some((finding) => finding.type === 'per-character-dash');
    if (hasPerCharacterDash) {
      console.error(`${file}: 检测到逐字破折号化坏稿，必须回炉重写；normalize-punctuation 不会机械删除后冒充修复。`);
    } else {
      console.error(`${file}: 检测到破折号密度失控，必须回炉重写或人工改写；normalize-punctuation 不会机械删除后冒充修复。`);
    }
    continue;
  }

  if (result.output !== input) {
    fs.writeFileSync(fullPath, result.output, 'utf8');
    changedFiles += 1;
    console.log(`${file}: normalized (${result.findings.length} issue${result.findings.length === 1 ? '' : 's'})`);
  }
}

if (failed) {
  process.exit(2);
}
if (options.check && totalFindings > 0) {
  process.exit(1);
}
if (!options.check) {
  console.log(`Done. Changed files: ${changedFiles}`);
}

function die(message) {
  console.error(message);
  console.error(USAGE.trimEnd());
  process.exit(2);
}

function normalizeDocument(input, quoteMode) {
  const newline = input.includes('\r\n') ? '\r\n' : '\n';
  const trailingNewline = input.endsWith('\n');
  const lines = input.split(/\r?\n/);
  if (trailingNewline) lines.pop();

  const findings = [];
  const outputLines = [];
  let inFence = false;
  let inFrontMatter = hasYamlFrontMatter(lines);
  let quoteOpen = false;
  let unrecoverable = false;
  let proseCharCount = 0;
  let preservedDashCount = 0;

  for (let index = 0; index < lines.length; index += 1) {
    const lineNo = index + 1;
    let line = lines[index];
    const trimmed = line.trim();

    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      outputLines.push(line);
      continue;
    }

    if (inFrontMatter) {
      outputLines.push(line);
      if (index > 0 && trimmed === '---') inFrontMatter = false;
      continue;
    }

    if (inFence) {
      outputLines.push(line);
      continue;
    }

    if (trimmed === '---') {
      findings.push({
        line: lineNo,
        column: line.indexOf('-') + 1,
        type: 'markdown-divider',
        message: '正文中不要使用 markdown 分隔线；建议移除该行。',
      });
      continue;
    }

    if (!trimmed.startsWith('#')) {
      proseCharCount += line.replace(/\s/g, '').length;
      preservedDashCount += (line.match(/——/g) || []).length;
      preservedDashCount += (line.match(/--+/g) || []).length;
      preservedDashCount += countSingleEmDashes(line);
    }

    const punctuationResult = normalizePausePunctuation(line, lineNo);
    findings.push(...punctuationResult.findings);
    if (punctuationResult.unrecoverable) unrecoverable = true;
    line = punctuationResult.line;

    const quoteResult = normalizeQuotes(line, quoteMode, quoteOpen, lineNo);
    findings.push(...quoteResult.findings);
    line = quoteResult.line;
    quoteOpen = quoteResult.quoteOpen;

    outputLines.push(line);
  }

  if (isDashDensityTooHigh(preservedDashCount, proseCharCount)) {
    findings.push({
      line: 1,
      column: 1,
      type: 'dash-density',
      message: `破折号密度失控：正文约 ${proseCharCount} 字出现 ${preservedDashCount} 处破折号；正文产物不保留破折号，反复用破折号制造停顿时必须回炉重写或人工改写。`,
    });
    unrecoverable = true;
  }

  return {
    output: outputLines.join(newline) + (trailingNewline ? newline : ''),
    findings,
    unrecoverable,
  };
}

function normalizePausePunctuation(line, lineNo) {
  const findings = [];
  const original = line;

  if (looksLikePerCharacterDashCorruption(original)) {
    let dashMatch;
    const dashPattern = /——|—|--+/g;
    while ((dashMatch = dashPattern.exec(original)) !== null) {
      findings.push({
        line: lineNo,
        column: dashMatch.index + 1,
        type: 'per-character-dash',
        message: '逐字破折号化文本不是标点问题，必须回炉重写。',
      });
    }
    return {
      line: original,
      findings,
      unrecoverable: true,
    };
  }

  const pattern = /…+|\.{3,}|——|—|--+/g;
  let output = '';
  let lastIndex = 0;
  let match;

  while ((match = pattern.exec(original)) !== null) {
    output += original.slice(lastIndex, match.index);
    const token = match[0];
    const replacement = choosePauseReplacement(original, match.index, token.length, token);
    if (replacement === null) {
      output += token;
      lastIndex = match.index + token.length;
      continue;
    }
    output += replacement;
    findings.push({
      line: lineNo,
      column: match.index + 1,
      type: getPauseType(token),
      message: replacement ? `替换为「${replacement}」。` : '移除重复标点。',
    });
    lastIndex = match.index + token.length;
  }

  output += original.slice(lastIndex);
  return { line: output, findings, unrecoverable: false };
}

function looksLikePerCharacterDashCorruption(text) {
  const dashCount = (text.match(/——|—|--+/g) || []).length;
  if (dashCount < 5) return false;

  // Typical bad generation: "最——后——一——件——事" or "本——系——统".
  // Normal prose can have several phrase-level dashes; require a run of
  // single CJK/alnum characters separated by dashes before treating it as
  // corruption and deleting the separators instead of converting to commas.
  return /(?:[\u3400-\u9FFF0-9A-Za-z]——){4,}[\u3400-\u9FFF0-9A-Za-z]?/.test(text);
}

function hasYamlFrontMatter(lines) {
  if (!lines[0] || lines[0].trim() !== '---') return false;
  let sawYamlField = false;
  for (let i = 1; i < Math.min(lines.length, 40); i += 1) {
    const trimmed = lines[i].trim();
    if (trimmed === '---') return sawYamlField;
    if (/^[A-Za-z0-9_-]+:\s*/.test(trimmed)) sawYamlField = true;
  }
  return false;
}

function getPauseType(token) {
  if (token.startsWith('-')) return 'double-hyphen';
  if (token.includes('—')) return 'em-dash';
  return 'ellipsis';
}

function choosePauseReplacement(text, start, length, token) {
  const before = previousNonSpace(text, start - 1);
  const after = nextNonSpace(text, start + length);
  const rest = text.slice(start + length).trimStart();

  // 正文产物不保留 `……`、`——`、`—` 或 `--`；对话打断和数字区间不设破折号例外。
  if (before === '') return '';
  // 紧跟开引号/开括号的停顿符号属于句首边界，删空即可，避免产出 `「，…」` 或 `「。」`。
  if (isOpeningDelimiter(before)) return '';
  if (/\d/.test(before) && /\d/.test(after)) return '到';
  if (isClosingQuote(after)) return isSentencePunctuation(before) ? '' : '。';

  if (!after) return isSentencePunctuation(before) ? '' : '。';
  if (isSentencePunctuation(before) || isPunctuation(after)) return '';
  if (/^(因为|原来|这是|那是|也就是|换句话|说白了|所谓|答案|原因|结果|真相|问题在于)/.test(rest)) return '：';
  if (/(原因|答案|真相|结果|结论|问题|选择|意思)$/.test(text.slice(0, start).trim())) return '：';
  return '，';
}

function isDashDensityTooHigh(dashCount, charCount) {
  if (dashCount <= 5) return false;
  const limit = Math.max(5, Math.ceil((charCount / 1000) * 2));
  return dashCount > limit;
}

function countSingleEmDashes(text) {
  let count = 0;
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] !== '—') continue;
    if (text[i - 1] === '—' || text[i + 1] === '—') continue;
    count += 1;
  }
  return count;
}

function previousNonSpace(text, index) {
  for (let i = index; i >= 0; i -= 1) {
    if (!/\s/.test(text[i])) return text[i];
  }
  return '';
}

function nextNonSpace(text, index) {
  for (let i = index; i < text.length; i += 1) {
    if (!/\s/.test(text[i])) return text[i];
  }
  return '';
}

function isSentencePunctuation(ch) {
  return /[，,。.!！?？;；:：…]$/.test(ch || '');
}

function isPunctuation(ch) {
  return /[，,。.!！?？;；:：、…"“”'‘’」』）)]/.test(ch || '');
}

function isClosingQuote(ch) {
  return /["”」』]/.test(ch || '');
}

function isOpeningDelimiter(ch) {
  return /[「『（(“‘]/.test(ch || '');
}

function normalizeQuotes(line, quoteMode, quoteOpen, lineNo) {
  if (quoteMode === 'keep') {
    return { line, findings: [], quoteOpen };
  }

  const findings = [];
  let output = '';

  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (quoteMode === 'ascii' && /[「」『』“”]/.test(ch)) {
      output += '"';
      findings.push({ line: lineNo, column: i + 1, type: 'quote-style', message: '按显式 quote-mode 转为半角双引号。' });
      continue;
    }
    if (quoteMode === 'yan' && (ch === '"' || ch === '“' || ch === '”')) {
      const replacement = quoteOpen || ch === '”' ? '」' : '「';
      output += replacement;
      quoteOpen = replacement === '「';
      findings.push({ line: lineNo, column: i + 1, type: 'quote-style', message: '按显式 quote-mode 转为盐言引号。' });
      continue;
    }
    if (quoteMode === 'mainland' && /[「」『』"]/.test(ch)) {
      const replacement = (quoteOpen || ch === '」' || ch === '』') ? '”' : '“';
      output += replacement;
      quoteOpen = replacement === '“';
      findings.push({ line: lineNo, column: i + 1, type: 'quote-style', message: '按显式 quote-mode 转为大陆中文引号。' });
      continue;
    }
    output += ch;
  }

  return { line: output, findings, quoteOpen };
}
