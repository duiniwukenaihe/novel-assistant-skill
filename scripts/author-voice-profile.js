#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node author-voice-profile.js [--json] [--output <file>] <accepted-sample.md...>

Build a lightweight author voice profile from user-approved prose samples.
This script reads accepted samples and writes metrics only; it does not rewrite prose.`;

const options = {
  json: false,
  output: null,
  files: [],
};

for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === '--json') {
    options.json = true;
  } else if (arg === '--output') {
    options.output = process.argv[++i];
    if (!options.output) die('--output requires a file path');
  } else if (arg === '-h' || arg === '--help') {
    console.log(USAGE);
    process.exit(0);
  } else if (arg.startsWith('-')) {
    die(`Unknown option: ${arg}`);
  } else {
    options.files.push(arg);
  }
}

if (options.files.length === 0) die('No sample files provided');

const samples = options.files.map(readSample);
const mergedText = samples.map((sample) => sample.text).join('\n\n');
const profile = buildProfile(samples, mergedText);
const serialized = JSON.stringify(profile, null, 2);

if (options.output) {
  fs.mkdirSync(path.dirname(path.resolve(options.output)), { recursive: true });
  fs.writeFileSync(options.output, `${serialized}\n`, 'utf8');
}

if (options.json || !options.output) {
  process.stdout.write(`${serialized}\n`);
}

function readSample(file) {
  const text = fs.readFileSync(file, 'utf8');
  return {
    file,
    fileName: path.basename(file),
    text,
  };
}

function buildProfile(samples, text) {
  const paragraphs = text
    .split(/\n{2,}/)
    .map((part) => part.trim())
    .filter(Boolean)
    .filter((part) => !part.startsWith('#') && !/^---+$/.test(part));
  const sentences = splitSentences(text);
  const cjkChars = countCjk(text);
  const dialogueLines = text.split(/\r?\n/).filter((line) => /[“"「『]/.test(line.trim())).length;
  const nonEmptyLines = text.split(/\r?\n/).filter((line) => line.trim()).length || 1;

  return {
    schemaVersion: '1.0.0',
    generatedAt: new Date().toISOString(),
    sourceFiles: samples.map((sample) => sample.file),
    sampleStats: {
      files: samples.length,
      cjkChars,
      paragraphs: paragraphs.length,
      sentences: sentences.length,
      nonEmptyLines,
    },
    sentenceLength: summarizeNumbers(sentences.map(countCjk).filter((n) => n > 0)),
    paragraphShape: summarizeNumbers(paragraphs.map(countCjk).filter((n) => n > 0)),
    punctuationHabits: {
      comma: countMatches(text, /[，,]/g),
      period: countMatches(text, /[。.!！?？]/g),
      question: countMatches(text, /[?？]/g),
      exclamation: countMatches(text, /[!！]/g),
      ellipsis: countMatches(text, /……|…/g),
      emDash: countMatches(text, /——|—|--+/g),
      colon: countMatches(text, /[：:]/g),
      quoteLines: dialogueLines,
    },
    dialogueRatio: Number((dialogueLines / nonEmptyLines).toFixed(3)),
    paragraphStarts: topItems(
      paragraphs
        .map((p) => p.replace(/^[“"「『]/, '').trim().slice(0, 2))
        .filter(Boolean),
      12
    ),
    voiceHints: buildVoiceHints(text, sentences, paragraphs),
  };
}

function splitSentences(text) {
  return text
    .replace(/\r/g, '')
    .split(/(?<=[。！？!?])\s*/u)
    .map((s) => s.trim())
    .filter(Boolean)
    .filter((s) => !s.startsWith('#'));
}

function countCjk(text) {
  const m = text.match(/[\u4e00-\u9fff]/g);
  return m ? m.length : 0;
}

function countMatches(text, re) {
  const m = text.match(re);
  return m ? m.length : 0;
}

function summarizeNumbers(values) {
  if (values.length === 0) {
    return { count: 0, min: 0, max: 0, average: 0, median: 0 };
  }
  const sorted = [...values].sort((a, b) => a - b);
  const sum = sorted.reduce((acc, value) => acc + value, 0);
  return {
    count: sorted.length,
    min: sorted[0],
    max: sorted[sorted.length - 1],
    average: Number((sum / sorted.length).toFixed(1)),
    median: sorted[Math.floor(sorted.length / 2)],
  };
}

function topItems(items, limit) {
  const counts = new Map();
  for (const item of items) counts.set(item, (counts.get(item) || 0) + 1);
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0], 'zh-Hans-CN'))
    .slice(0, limit)
    .map(([text, count]) => ({ text, count }));
}

function buildVoiceHints(text, sentences, paragraphs) {
  const sentenceStats = summarizeNumbers(sentences.map(countCjk).filter((n) => n > 0));
  const paragraphStats = summarizeNumbers(paragraphs.map(countCjk).filter((n) => n > 0));
  const hints = [];
  if (sentenceStats.average && sentenceStats.average <= 16) hints.push('句子偏短，保留短促推进和留白。');
  if (sentenceStats.average > 24) hints.push('句子偏长，适合保留连续推理或氛围链。');
  if (paragraphStats.median && paragraphStats.median <= 45) hints.push('段落偏短，适合手机阅读和强情绪推进。');
  if (countMatches(text, /[“"「『]/g) > 0) hints.push('样本含对话行，改写时优先保留对话推进。');
  if (countMatches(text, /——|—|--+/g) === 0) hints.push('样本几乎不用破折号，改写时不要用破折号制造停顿。');
  return hints;
}

function die(message) {
  console.error(message);
  console.error(USAGE);
  process.exit(2);
}
