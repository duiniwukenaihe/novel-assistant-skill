#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { compactToolOutput } = require('./lib/tool-output-compactor');

function parseArgs(argv) {
  const args = { input: '', output: '', kind: 'generic', json: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--json') args.json = true;
    else if (arg === '--input') args.input = argv[++index] || '';
    else if (arg === '--output') args.output = argv[++index] || '';
    else if (arg === '--kind') args.kind = argv[++index] || 'generic';
    else fail(`unknown argument: ${arg}`);
  }
  if (!args.input) fail('missing --input');
  if (!args.output) fail('missing --output');
  return args;
}

function fail(message) {
  process.stderr.write(`Error: ${message}\n`);
  process.exit(2);
}

function atomicWriteJson(file, value) {
  const absolute = path.resolve(file);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  const temporary = `${absolute}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  fs.renameSync(temporary, absolute);
}

const args = parseArgs(process.argv);
let raw = '';
try {
  raw = fs.readFileSync(path.resolve(args.input), 'utf8');
} catch (error) {
  fail(`cannot read input: ${error.message}`);
}
const summary = compactToolOutput(raw, { kind: args.kind });
atomicWriteJson(args.output, summary);
if (args.json) process.stdout.write(`${JSON.stringify({ status: 'compacted', output: path.resolve(args.output), ...summary })}\n`);
else process.stdout.write(`compacted ${summary.raw_chars} -> ${summary.compacted_chars} chars\n`);
