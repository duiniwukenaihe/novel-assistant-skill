'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function laterCanonicalOutlineTargets(projectRoot, task) {
  const accepted = Array.isArray((task || {}).accepted_detail_outline_targets)
    ? task.accepted_detail_outline_targets.filter(item => item && item.outline_path)
    : [];
  if (accepted.length === 0) return [];
  const current = accepted.slice().sort((a, b) => Number(a.volume_chapter_no || 0) - Number(b.volume_chapter_no || 0)).at(-1);
  const currentNo = Number(current.volume_chapter_no || outlineNumber(current.outline_path));
  if (!Number.isInteger(currentNo) || currentNo < 1) return [];
  const root = path.resolve(projectRoot);
  const currentFile = resolveInside(root, String(current.outline_path || ''));
  if (!currentFile) return [];
  const outlineDir = path.dirname(currentFile);
  if (!fs.existsSync(outlineDir) || !fs.statSync(outlineDir).isDirectory()) return [];
  return fs.readdirSync(outlineDir)
    .map((name) => ({ name, number: outlineNumber(name) }))
    .filter(item => Number.isInteger(item.number) && item.number > currentNo)
    .sort((a, b) => a.number - b.number)
    .map((item) => {
      const file = path.join(outlineDir, item.name);
      if (!fs.statSync(file).isFile()) return null;
      return {
        outline_path: path.relative(root, file).split(path.sep).join('/'),
        outline_sha256: crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'),
      };
    })
    .filter(Boolean);
}

function outlineNumber(value) {
  const match = String(value || '').match(/细纲_第0*(\d+)章\.md$/u);
  return match ? Number(match[1]) : 0;
}

function resolveInside(root, relativePath) {
  const file = path.resolve(root, String(relativePath || ''));
  return file !== root && file.startsWith(`${root}${path.sep}`) ? file : '';
}

module.exports = { laterCanonicalOutlineTargets };
