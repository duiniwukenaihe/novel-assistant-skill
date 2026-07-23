#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const mode = process.argv[2] || 'success';
const root = process.env.NOVEL_ASSISTANT_PROJECT_ROOT;
const runnerPacketRel = process.env.NOVEL_ASSISTANT_RUNNER_PACKET;
const resultPacketRel = process.env.NOVEL_ASSISTANT_RESULT_PACKET;
if (!root || !runnerPacketRel || !resultPacketRel) process.exit(20);

const marker = path.join(root, 'fake-host-invocations.log');
fs.appendFileSync(marker, `${mode}\n`);

if (mode === 'repeat-term') {
  process.stdout.write(`${'修真'.repeat(40)}\n`);
  setTimeout(() => process.exit(0), 20);
  return;
}
if (mode === 'tool-loop') {
  process.stderr.write('Invalid tool parameters\n'.repeat(8));
  setTimeout(() => process.exit(1), 20);
  return;
}
if (mode === 'no-result') {
  process.stdout.write('执行结束，但未生成结果包。\n');
  process.exit(0);
}

const runnerPacket = JSON.parse(fs.readFileSync(path.join(root, runnerPacketRel), 'utf8'));
const result = {
  workflow_id: runnerPacket.workflow_id,
  workflow_type: runnerPacket.workflow_type,
  stage_id: runnerPacket.stage_id,
  step_id: runnerPacket.stage_id,
  step_status: 'completed',
  outputs: [],
  changed_files: [],
  evidence: [],
  verification_result: 'pass',
  blocking_reason: '',
  next_recommendation: '继续下一阶段',
  handoff_summary: `${runnerPacket.stage_id} 已由 fake adapter 完成。`,
  checkpoint_state: { run_id: runnerPacket.run_id },
  output_health_result: 'pass',
  ...(runnerPacket.result_packet_template || runnerPacket.stage_contract || {}),
};
const resultFile = path.join(root, resultPacketRel);
fs.mkdirSync(path.dirname(resultFile), { recursive: true });
fs.writeFileSync(resultFile, `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${JSON.stringify({ type: 'result', status: 'completed', stage: runnerPacket.stage_id })}\n`);
