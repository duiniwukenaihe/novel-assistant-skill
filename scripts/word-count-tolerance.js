#!/usr/bin/env node
'use strict';

const fs = require('fs');

const USAGE = `Usage: node scripts/word-count-tolerance.js --actual <chars> --target <chars> [--unit section|chapter|short] [--json]
       node scripts/word-count-tolerance.js --file <path> --target <chars> [--unit section|chapter|short] [--json]`;

function parseArgs(argv) {
  const args = { actual: NaN, target: NaN, unit: 'section', file: '', json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--actual') args.actual = Number(argv[++i]);
    else if (arg === '--target') args.target = Number(argv[++i]);
    else if (arg === '--unit') args.unit = String(argv[++i] || 'section');
    else if (arg === '--file') args.file = String(argv[++i] || '');
    else if (arg === '--json') args.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }
  if (args.file) args.actual = countCjkAndAsciiStoryChars(fs.readFileSync(args.file, 'utf8'));
  if (!Number.isFinite(args.actual) || args.actual < 0) fail('missing or invalid --actual/--file');
  if (!Number.isFinite(args.target) || args.target <= 0) fail('missing or invalid --target');
  return args;
}

function fail(message) {
  console.error(`${message}\n${USAGE}`);
  process.exit(2);
}

function countCjkAndAsciiStoryChars(text) {
  return (text.match(/[一-鿿A-Za-z0-9]/g) || []).length;
}

function toleranceFor(target, unit) {
  const lowerPercent = unit === 'short' ? 0.10 : 0.08;
  const upperPercent = unit === 'short' ? 0.12 : 0.08;
  const hardPercent = unit === 'short' ? 0.22 : 0.25;
  return {
    lower: Math.max(120, Math.ceil(target * lowerPercent)),
    upper: Math.max(150, Math.ceil(target * upperPercent)),
    hardShortfall: Math.max(300, Math.ceil(target * hardPercent)),
  };
}

function evaluate(actual, target, unit) {
  const tolerance = toleranceFor(target, unit);
  const lowerBand = Math.max(0, target - tolerance.lower);
  const upperBand = target + tolerance.upper;
  const hardFloor = Math.max(0, target - tolerance.hardShortfall);
  const delta = actual - target;

  const base = {
    schemaVersion: '1.0.0',
    unit,
    actual,
    target,
    delta,
    lower_tolerance: tolerance.lower,
    upper_tolerance: tolerance.upper,
    hard_floor: hardFloor,
  };

  if (actual < hardFloor) {
    return {
      ...base,
      status: 'blocking',
      verdict: 'under_hard_floor',
      blocking: true,
      recommended_action: 'add_story_events_or_redesign_section',
      note: '明显低于硬底线：先补真实子事件、对话冲突、选择代价或重构小节，不要用空描写凑字。',
    };
  }

  if (actual < target) {
    return {
      ...base,
      status: actual >= lowerBand ? 'warning' : 'warning',
      verdict: actual >= lowerBand ? 'under_target_within_tolerance' : 'under_target_review_completeness',
      blocking: false,
      recommended_action: actual >= lowerBand ? 'accept_if_story_complete' : 'review_story_completeness_before_padding',
      note: actual >= lowerBand
        ? '低于目标但在容忍带内：如果本节剧情功能、情绪和钩子已完成，接受；不要为了几十字或一两百字反复补水。'
        : '低于目标较多但未破硬底线：先检查是否缺子事件/冲突/承接钩子；只有缺故事功能才补，不为数字补水。',
    };
  }

  if (actual <= upperBand) {
    return {
      ...base,
      status: 'pass',
      verdict: 'within_target_band',
      blocking: false,
      recommended_action: 'keep_narrative_shape',
      note: '处于目标容忍带内：保持叙事形态，不要为了贴合精确字数机械压缩或扩写。',
    };
  }

  return {
    ...base,
    status: 'warning',
    verdict: 'over_target_review_pacing',
    blocking: false,
    recommended_action: 'review_pacing_not_mechanical_compress',
    note: '高于目标：只检查节奏是否拖沓、是否有重复信息；若内容有功能，不为压字数机械删改。',
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = evaluate(args.actual, args.target, args.unit);
  if (args.json) console.log(JSON.stringify(result));
  else {
    console.log(`${result.status}: ${result.verdict}`);
    console.log(result.note);
  }
  process.exit(result.blocking ? 2 : 0);
}

if (require.main === module) main();

module.exports = { evaluate, countCjkAndAsciiStoryChars };
