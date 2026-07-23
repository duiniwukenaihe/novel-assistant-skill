#!/usr/bin/env node
'use strict';

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { raw += chunk; });
process.stdin.on('end', () => {
  let input = {};
  try { input = JSON.parse(raw || '{}'); } catch (_) { process.exit(0); }
  if (input.hook_event_name !== 'Stop' || input.stop_hook_active === true) return;
  const message = String(input.last_assistant_message || '');
  if (!hasTerminalResidue(message)) return;
  process.stdout.write(`${JSON.stringify({
    decision: 'block',
    reason: '最终回复含终端转义残片。立即重写为简短、干净的中文回复；删除 `[e~[`、CSI/ANSI 残片和多余代码围栏，不要重复工具日志，也不要返回任务首页。',
  })}\n`);
});

function hasTerminalResidue(message) {
  return /\u001b\[[0-?]*[ -\/]*[@-~]/.test(message)
    || /(?:^|[^A-Za-z0-9])\[(?:e~\[|[0-9;?]*[A-Za-z~])(?:$|[^A-Za-z0-9])/.test(message)
    || /```\s*\[(?:e~\[|[0-9;?]*[A-Za-z~])/.test(message);
}
