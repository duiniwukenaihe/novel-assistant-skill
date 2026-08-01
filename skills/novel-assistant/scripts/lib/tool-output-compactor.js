'use strict';

const ERROR_PATTERN = /(?:^|\b)(?:error|failed|failure|fatal|exception|timeout|blocked|invalid|not ok)\b|错误|失败|阻塞|超时/iu;
const TEST_SUMMARY_PATTERN = /(?:tests?|suites?|passed|failed|skipped|duration|\d+\.\.\d+)/iu;
const CHANGED_FILE_PATTERN = /^\s*(?:M|A|D|R|C|U|\?\?)\s+(.+?)\s*$/u;

function compactToolOutput(raw, options = {}) {
  const text = String(raw || '').replace(/\r\n?/g, '\n');
  const kind = String(options.kind || 'generic');
  const maxKeyLines = positiveInteger(options.maxKeyLines, 24);
  const lines = text.split('\n');
  const seen = new Map();
  const unique = [];
  let repeatedLinesRemoved = 0;

  for (const line of lines) {
    const normalized = line.trim().replace(/\s+/g, ' ');
    if (!normalized) continue;
    const count = seen.get(normalized) || 0;
    seen.set(normalized, count + 1);
    if (count > 0) {
      repeatedLinesRemoved += 1;
      continue;
    }
    unique.push(line.trim());
  }

  const errors = boundedUnique(unique.filter((line) => ERROR_PATTERN.test(line)), 12);
  const testSummary = kind === 'test'
    ? boundedUnique(unique.filter((line) => TEST_SUMMARY_PATTERN.test(line)), 12)
    : [];
  const changedFiles = boundedUnique(unique.map(changedFile).filter(Boolean), 100).sort();
  const priority = boundedUnique([...errors, ...testSummary], maxKeyLines);
  const remaining = unique.filter((line) => !priority.includes(line));
  const room = Math.max(0, maxKeyLines - priority.length);
  const keyLines = boundedUnique([...priority, ...edgeLines(remaining, room)], maxKeyLines);
  const compactedChars = keyLines.join('\n').length;
  const rawChars = text.length;

  return {
    schemaVersion: '1.0.0',
    kind,
    raw_chars: rawChars,
    compacted_chars: compactedChars,
    compression_ratio: rawChars > 0 ? Number(Math.max(0, Math.min(1, 1 - compactedChars / rawChars)).toFixed(4)) : 0,
    raw_lines: lines.length,
    compacted_lines: keyLines.length,
    repeated_lines_removed: repeatedLinesRemoved,
    errors,
    test_summary: testSummary,
    changed_files: changedFiles,
    key_lines: keyLines,
  };
}

function changedFile(line) {
  const match = String(line || '').match(CHANGED_FILE_PATTERN);
  return match ? match[1].trim() : '';
}

function edgeLines(lines, limit) {
  if (limit <= 0 || lines.length <= limit) return lines.slice(0, limit);
  const head = Math.ceil(limit / 2);
  return [...lines.slice(0, head), ...lines.slice(-(limit - head))];
}

function boundedUnique(values, limit) {
  return Array.from(new Set(values.map((value) => String(value || '').trim()).filter(Boolean))).slice(0, limit);
}

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

module.exports = { compactToolOutput };
