#!/usr/bin/env node
'use strict';

// 用法: assert-stage-context.js --fixture <dir> --stage <id> --section <n>
//                              [--expect <text>] [--reject <text>]
// 退出码: 0 = 断言通过；1 = 断言失败；2 = 参数错误
const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = { expect: [], reject: [] };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = argv[i + 1];
    if (a === '--fixture') { args.fixture = next; i++; }
    else if (a === '--stage') { args.stage = next; i++; }
    else if (a === '--section') { args.section = Number(next); i++; }
    else if (a === '--expect') { args.expect.push(next); i++; }
    else if (a === '--reject') { args.reject.push(next); i++; }
  }
  return args;
}

const args = parseArgs(process.argv);
if (!args.fixture || !args.stage || !args.section) {
  console.error('用法: --fixture <dir> --stage <id> --section <n> [--expect <text>] [--reject <text>]');
  process.exit(2);
}

// fixture 目录里有 task.json，描述当前任务上下文
const taskFile = path.join(args.fixture, 'task.json');
if (!fs.existsSync(taskFile)) {
  console.error(`fixture 缺 task.json: ${taskFile}`);
  process.exit(2);
}
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));

// 调被测库
const repoRoot = path.resolve(__dirname, '..', '..');
const lib = require(path.join(repoRoot, 'scripts/lib/workflow-stage-context-packet.js'));
const out = lib.buildStageContextPacket({
  projectRoot: args.fixture,
  task,
  stage: args.stage,
});

if (out.status !== 'assembled') {
  console.error(`buildStageContextPacket 状态非 assembled: ${JSON.stringify(out.status)}`);
  console.error(`reason: ${out.reason || ''}`);
  console.error(`detail: ${JSON.stringify(out).slice(0, 1200)}`);
  process.exit(1);
}

// 读 packet_md 内容做断言
const packetMd = fs.readFileSync(path.join(args.fixture, out.packet_md), 'utf8');

let failed = false;
for (const text of args.expect) {
  if (!packetMd.includes(text)) {
    console.error(`EXPECT 失败: packet_md 不含 [${text}]`);
    failed = true;
  }
}
for (const text of args.reject) {
  if (packetMd.includes(text)) {
    console.error(`REJECT 失败: packet_md 不应含 [${text}]`);
    failed = true;
  }
}
process.exit(failed ? 1 : 0);
