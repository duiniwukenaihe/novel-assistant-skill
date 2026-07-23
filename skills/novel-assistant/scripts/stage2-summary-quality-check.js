#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const VALID_TONES = new Set(['紧张', '轻松', '悲伤', '热血', '爽', '甜', '温馨', '恐怖', '压抑', '其他']);
const VALID_TOPICS = new Set(['爱情', '亲情', '友情', '权力', '金钱', '成长', '复仇', '悬念', '搞笑', '热血', '日常', '其他']);

const args = process.argv.slice(2);
const positional = args.filter(arg => !arg.startsWith('--') && !isOptionValue(arg));
const chaptersDir = positional[0];
const jsonOutput = args.includes('--json');
const chaptersArg = valueAfter('--chapters');

if (!chaptersDir) {
  fail('usage: stage2-summary-quality-check.js <chapters-dir> [--chapters 81-86|81,82] [--json]');
}

const chapters = parseChapters(chaptersArg, chaptersDir);
const result = checkChapterSummaries(chaptersDir, chapters);

if (jsonOutput) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
} else if (result.status === 'pass') {
  process.stdout.write(`stage2 summary quality check passed: ${result.checked} chapters\n`);
} else {
  process.stdout.write(`stage2 summary quality check failed: ${result.failures.length} issues\n`);
  for (const failure of result.failures) {
    process.stdout.write(`- 第${failure.chapter}章 ${failure.type}: ${failure.message}\n`);
  }
}

process.exit(result.status === 'pass' ? 0 : 1);

function checkChapterSummaries(dir, chapterNumbers) {
  const failures = [];
  let checked = 0;
  for (const chapter of chapterNumbers) {
    const file = findSummaryFile(dir, chapter);
    if (!file) {
      failures.push({
        chapter,
        type: 'missing_file',
        message: `cannot find 第${chapter}章_摘要.md`,
      });
      continue;
    }
    checked += 1;
    const text = fs.readFileSync(file, 'utf8');
    failures.push(...checkOneSummary(text, chapter, file));
  }
  return {
    status: failures.length ? 'fail' : 'pass',
    checked,
    requested: chapterNumbers.length,
    failures,
  };
}

function checkOneSummary(text, chapter, file) {
  const failures = [];
  const lineStartPointCount = countMatches(text, /^P[0-9]+\s+\*\*/gm);
  const rawPointCount = countPlotPointMarkers(text);
  const pointCount = rawPointCount || lineStartPointCount;
  const tones = extractTones(text);
  const topics = extractTopics(text);

  if (pointCount === 0) {
    failures.push({
      chapter,
      file,
      type: 'missing_plot_points',
      message: 'no P情节点 found',
    });
  }

  if (rawPointCount > lineStartPointCount) {
    failures.push({
      chapter,
      file,
      type: 'plot_point_inline_marker',
      message: `P情节点疑似粘连：检测到 ${rawPointCount} 个 P 标记，但只有 ${lineStartPointCount} 个位于行首`,
    });
  }

  if (tones.length !== pointCount) {
    failures.push({
      chapter,
      file,
      type: 'tone_count_mismatch',
      message: `P情节点 ${pointCount}, 基调行 ${tones.length}`,
    });
  }

  if (topics.length !== pointCount) {
    failures.push({
      chapter,
      file,
      type: 'topic_count_mismatch',
      message: `P情节点 ${pointCount}, 主题标签行 ${topics.length}`,
    });
  }

  for (const tone of tones) {
    if (!VALID_TONES.has(tone)) {
      failures.push({
        chapter,
        file,
        type: 'invalid_tone',
        value: tone,
        message: `invalid 基调：${tone}`,
      });
    }
  }

  for (const topic of topics.flatMap(splitTags)) {
    if (!VALID_TOPICS.has(topic)) {
      failures.push({
        chapter,
        file,
        type: 'invalid_topic',
        value: topic,
        message: `invalid 主题标签${topic}`,
      });
    }
  }

  return failures;
}

function parseChapters(raw, dir) {
  if (!raw) {
    return fs.readdirSync(dir)
      .map(name => name.match(/^第0*([0-9]+)章_摘要\.md$/)?.[1])
      .filter(Boolean)
      .map(Number)
      .sort((a, b) => a - b);
  }
  const chapters = [];
  for (const part of String(raw).split(',')) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const range = trimmed.match(/^([0-9]+)-([0-9]+)$/);
    if (range) {
      const start = Number(range[1]);
      const end = Number(range[2]);
      const step = start <= end ? 1 : -1;
      for (let n = start; step > 0 ? n <= end : n >= end; n += step) chapters.push(n);
      continue;
    }
    const single = Number(trimmed);
    if (!Number.isInteger(single) || single <= 0) fail(`invalid --chapters value: ${raw}`);
    chapters.push(single);
  }
  return Array.from(new Set(chapters));
}

function findSummaryFile(dir, chapter) {
  const direct = [
    path.join(dir, `第${chapter}章_摘要.md`),
    path.join(dir, `第${String(chapter).padStart(3, '0')}章_摘要.md`),
  ];
  for (const file of direct) {
    if (fs.existsSync(file)) return file;
  }
  const prefix = new RegExp(`^第0*${chapter}章_摘要\\.md$`);
  const found = fs.readdirSync(dir).find(name => prefix.test(name));
  return found ? path.join(dir, found) : null;
}

function extractTones(text) {
  return Array.from(text.matchAll(/基调：([^ |\n\r，,。；;]+)/g), match => match[1].trim()).filter(Boolean);
}

function extractTopics(text) {
  return Array.from(text.matchAll(/主题标签[：:]?([^|\n\r。；;]+)/g), match => match[1].trim()).filter(Boolean);
}

function splitTags(value) {
  return String(value || '')
    .replace(/[，,、/／]/g, ' ')
    .split(/\s+/)
    .map(item => item.trim())
    .filter(Boolean);
}

function countMatches(text, pattern) {
  return Array.from(text.matchAll(pattern)).length;
}

function countPlotPointMarkers(text) {
  return Array.from(text.matchAll(/(?:^|[^\p{L}\p{N}_])P[0-9]+\s+\*\*/gu)).length;
}

function valueAfter(flag) {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : null;
}

function isOptionValue(arg) {
  const previous = args[args.indexOf(arg) - 1];
  return previous === '--chapters';
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
