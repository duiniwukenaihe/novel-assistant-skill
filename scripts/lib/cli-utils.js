'use strict';

// Shared CLI helper utilities. Top-level scripts used to redefine readJson /
// parseJson / safeProjectFile / finish / usage in every file (55-97 copies).
// New and refactored scripts should require this module instead of
// copy-pasting. Keep helpers behavior-compatible with the existing inline
// copies so refactoring is a pure mechanical substitution.

const fs = require('fs');
const path = require('path');

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function parseJson(text) {
  try { return JSON.parse(String(text || '').trim()); } catch (_) { return null; }
}

function safeProjectFile(root, rel) {
  const value = String(rel || '');
  if (!value) return '';
  const file = path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
  return file === root || file.startsWith(`${root}${path.sep}`) ? file : '';
}

function relative(root, file) {
  return file ? path.relative(root, file).split(path.sep).join('/') : '';
}

function finish(value, code, json) {
  process.stdout.write(`${json ? JSON.stringify(value) : `${value.status}\n`}\n`);
  return code;
}

function usage(message) {
  process.stderr.write(`${message}\n`);
  process.exit(2);
}

module.exports = {
  finish,
  parseJson,
  readJson,
  relative,
  safeProjectFile,
  usage,
};
