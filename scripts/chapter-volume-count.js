#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node scripts/chapter-volume-count.js --project-root <book-dir> [--volumes "第1卷,第2卷"] [--exclude "_原稿_"] [--json]

Authorization-friendly chapter counter. It replaces brittle shell snippets such
as "cd && for v ... ls | grep | wc" with one deterministic read-only command.`;

function parseArgs(argv) {
  const args = { projectRoot: '', volumes: '', exclude: '_原稿_', json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--volumes') args.volumes = argv[++i] || '';
    else if (arg === '--exclude') args.exclude = argv[++i] || '';
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') {
      console.log(USAGE);
      process.exit(0);
    } else {
      die(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function die(message) {
  console.error(message);
  console.error(USAGE);
  process.exit(2);
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.projectRoot) die('--project-root is required');

  const projectRoot = path.resolve(args.projectRoot);
  const bodyRoot = path.join(projectRoot, '正文');
  const requestedVolumes = parseList(args.volumes);
  const volumes = requestedVolumes.length ? requestedVolumes : discoverVolumes(bodyRoot);
  const rows = volumes.map((volume) => countVolume(bodyRoot, volume, args.exclude));
  const total = rows.reduce((sum, row) => sum + row.count, 0);
  const result = {
    status: fs.existsSync(bodyRoot) ? 'ok' : 'missing_body_root',
    projectRoot,
    bodyRoot,
    exclude: args.exclude,
    total,
    volumes: rows,
  };

  if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  for (const row of rows) {
    console.log(`${row.volume}: ${row.count} 章节`);
  }
  console.log(`合计: ${total} 章节`);
}

function parseList(value) {
  return String(value || '')
    .split(/[,，\s]+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function discoverVolumes(bodyRoot) {
  if (!fs.existsSync(bodyRoot) || !fs.statSync(bodyRoot).isDirectory()) return [];
  return fs.readdirSync(bodyRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^第.+卷$/.test(entry.name))
    .map((entry) => entry.name)
    .sort(compareChineseVolumeName);
}

function countVolume(bodyRoot, volume, exclude) {
  const dir = path.join(bodyRoot, volume);
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
    return { volume, path: dir, count: 0, status: 'missing_volume' };
  }
  const files = fs.readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .filter((name) => /^第.+\.md$/.test(name))
    .filter((name) => !exclude || !name.includes(exclude));
  return { volume, path: dir, count: files.length, status: 'ok' };
}

function compareChineseVolumeName(a, b) {
  return volumeNumber(a) - volumeNumber(b) || a.localeCompare(b, 'zh-Hans-CN');
}

function volumeNumber(value) {
  const match = String(value || '').match(/^第([0-9一二三四五六七八九十百千零〇两]+)卷$/);
  if (!match) return Number.MAX_SAFE_INTEGER;
  if (/^\d+$/.test(match[1])) return Number(match[1]);
  return chineseNumberToInt(match[1]);
}

function chineseNumberToInt(text) {
  const digits = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
  if (Object.prototype.hasOwnProperty.call(digits, text)) return digits[text];
  let total = 0;
  let section = 0;
  let number = 0;
  const units = { 十: 10, 百: 100, 千: 1000 };
  for (const ch of text) {
    if (Object.prototype.hasOwnProperty.call(digits, ch)) {
      number = digits[ch];
    } else if (Object.prototype.hasOwnProperty.call(units, ch)) {
      section += (number || 1) * units[ch];
      number = 0;
    }
  }
  total += section + number;
  return total || Number.MAX_SAFE_INTEGER;
}

main();
