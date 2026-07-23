const fs = require('fs');
const path = require('path');

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function readText(file, fallback = '') {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (error) {
    if (error && error.code === 'ENOENT') return fallback;
    throw error;
  }
}

function readJson(file, fallback = null) {
  const text = readText(file, null);
  if (text === null) return fallback;
  return JSON.parse(text);
}

function writeJson(file, value) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function writeJsonl(file, rows) {
  ensureDir(path.dirname(file));
  fs.writeFileSync(file, rows.map(row => JSON.stringify(row)).join('\n') + (rows.length ? '\n' : ''), 'utf8');
}

function readDirSafe(dir) {
  try {
    return fs.readdirSync(dir).sort((a, b) => a.localeCompare(b, 'zh-Hans-CN'));
  } catch (error) {
    if (error && error.code === 'ENOENT') return [];
    throw error;
  }
}

function parseChapterNo(value) {
  const text = String(value || '');
  const match = text.match(/第\s*0*([1-9]\d*)\s*章/i)
    || text.match(/\bchapter[-_\s]+0*([1-9]\d*)\b/i)
    || text.match(/(?:^|[/\\_-])0*([1-9]\d*)(?:\.[^.]+)?$/);
  return match ? Number(match[1]) : null;
}

function nowIso() {
  return new Date().toISOString();
}

function stripMarkdownBullet(line) {
  return String(line || '')
    .replace(/^\s*(?:[-*+]|\d+[.)]|[（(]?\d+[）)]|[>])\s*/, '')
    .trim();
}

module.exports = {
  ensureDir,
  readText,
  readJson,
  writeJson,
  writeJsonl,
  readDirSafe,
  parseChapterNo,
  nowIso,
  stripMarkdownBullet,
};
