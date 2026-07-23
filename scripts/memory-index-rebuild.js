#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { writeActiveMemoryIndex } = require('./lib/memory-active-index');

const args = parseArgs(process.argv);
if (!args.projectRoot) throw new Error('--project-root is required');
const root = path.resolve(args.projectRoot);
const factsFile = path.join(root, '追踪', 'memory', 'facts.jsonl');
const events = fs.existsSync(factsFile)
  ? fs.readFileSync(factsFile, 'utf8').split(/\r?\n/).map(line => line.trim()).filter(Boolean).map(JSON.parse)
  : [];
const result = writeActiveMemoryIndex(root, events);
const output = {
  status: 'rebuilt',
  index_file: result.file,
  sourceDigest: result.index.sourceDigest,
  replay_position: result.index.replay_position,
  statistics: result.index.statistics,
};
if (args.json) console.log(JSON.stringify(output, null, 2));
else console.log(`rebuilt ${output.index_file}`);

function parseArgs(argv) {
  const out = { projectRoot: '', json: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--project-root') out.projectRoot = argv[++index] || '';
    else if (arg === '--json') out.json = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return out;
}
