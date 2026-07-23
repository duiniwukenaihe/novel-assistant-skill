#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node chapter-text-stats.js <draft-file> [--json] [--sections]

Reports robust chapter text statistics without brittle title splitting:
  - cjk_chars: Chinese character count in body
  - all_chars: body character count including whitespace
  - nonspace_chars: body character count excluding whitespace
  - em_dash: Chinese em dash occurrences in body
  - ellipsis: ellipsis occurrences in body

The body starts after the first markdown heading if present and ends before
"（本章完）" / "(本章完)" if present.

Use --sections for short-story drafts that use section headings like "###1.".`;

const args = process.argv.slice(2);
const json = args.includes('--json');
const sections = args.includes('--sections');
const file = args.find(arg => !arg.startsWith('--'));

if (!file || args.includes('-h') || args.includes('--help')) {
  console.error(USAGE.trimEnd());
  process.exit(file ? 0 : 2);
}

const abs = path.resolve(file);
let text = '';
try {
  text = fs.readFileSync(abs, 'utf8');
} catch (error) {
  fail(`unable to read ${file}: ${error.message}`);
}

const body = extractBody(text);
const stats = {
  file: abs,
  ...measure(body),
};
if (sections) stats.sections = splitSections(body).map(section => ({
  heading: section.heading,
  ...measure(section.text),
}));

if (json) {
  process.stdout.write(`${JSON.stringify(stats, null, 2)}\n`);
} else {
  process.stdout.write(`cjk_chars=${stats.cjk_chars} all_chars=${stats.all_chars} nonspace_chars=${stats.nonspace_chars} em_dash=${stats.em_dash} ellipsis=${stats.ellipsis}\n`);
}

function extractBody(input) {
  let body = String(input || '').replace(/^\uFEFF/, '');
  const lines = body.split(/\r?\n/);
  const firstHeadingIndex = lines.findIndex(line => /^#{1,6}\s+/.test(line.trim()));
  if (firstHeadingIndex >= 0 && !isSectionHeading(lines[firstHeadingIndex])) {
    body = lines.slice(firstHeadingIndex + 1).join('\n');
  }
  body = body.replace(/(?:\r?\n)?[（(]\s*本章完\s*[）)][\s\S]*$/u, '');
  return body.trim();
}

function measure(body) {
  const text = String(body || '');
  return {
    cjk_chars: (text.match(/[\u3400-\u9FFF]/g) || []).length,
    all_chars: Array.from(text).length,
    nonspace_chars: Array.from(text.replace(/\s/g, '')).length,
    em_dash: (text.match(/——/g) || []).length,
    ellipsis: (text.match(/……|…|\.{3,}/g) || []).length,
    lines: text ? text.split(/\r?\n/).length : 0,
  };
}

function splitSections(body) {
  const lines = String(body || '').split(/\r?\n/);
  const result = [];
  let current = null;

  for (const line of lines) {
    if (isSectionHeading(line)) {
      if (current) result.push(current);
      current = { heading: line.trim(), lines: [] };
      continue;
    }
    if (!current) current = { heading: '全文', lines: [] };
    current.lines.push(line);
  }

  if (current) result.push(current);
  return result.map(section => ({
    heading: section.heading,
    text: section.lines.join('\n').trim(),
  }));
}

function isSectionHeading(line) {
  return /^#{2,6}\s*\d+[.、．)]?\s*/u.test(String(line || '').trim());
}

function fail(message) {
  if (json) process.stdout.write(`${JSON.stringify({ status: 'fail', error: message }, null, 2)}\n`);
  else console.error(message);
  process.exit(2);
}
