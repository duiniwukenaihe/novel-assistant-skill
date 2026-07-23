#!/usr/bin/env node
'use strict';

const { spawnSync } = require('child_process');

function parseArgs(argv) {
  return { json: argv.includes('--json') };
}

function processInfo(pid) {
  const result = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'ppid=', '-o', 'command='], { encoding: 'utf8' });
  if (result.status !== 0) return null;
  const line = String(result.stdout || '').trim();
  const match = line.match(/^(\d+)\s+(.*)$/s);
  return match ? { ppid: Number(match[1]), command: match[2] } : null;
}

function hostFromCommand(command) {
  if (/(^|[\\/\s])claude(?:\s|$)/i.test(command)) return 'claude';
  if (/(^|[\\/\s])codex(?:\s|$)/i.test(command)) return 'codex';
  if (/(^|[\\/\s])zcode(?:\s|$)/i.test(command)) return 'zcode';
  return '';
}

function resolveSessionId(env = process.env, startPid = process.ppid) {
  const explicitNovelSession = String(env.NOVEL_ASSISTANT_SESSION_ID || '').trim();
  if (explicitNovelSession) return environmentSession(explicitNovelSession, '');
  const claudeSession = String(env.CLAUDE_SESSION_ID || '').trim();
  if (claudeSession) return environmentSession(claudeSession, 'claude');
  const codexThread = String(env.CODEX_THREAD_ID || '').trim();
  if (codexThread) return environmentSession(codexThread, 'codex');
  let pid = Number(startPid);
  for (let depth = 0; depth < 12 && Number.isInteger(pid) && pid > 1; depth += 1) {
    const info = processInfo(pid);
    if (!info) break;
    const host = hostFromCommand(info.command);
    if (host) return { session_id: `${host}:${pid}`, source: 'host_ancestor', host, ancestor_pid: pid };
    pid = info.ppid;
  }
  const terminal = String(env.TERM_SESSION_ID || env.ITERM_SESSION_ID || '').trim();
  return {
    session_id: terminal ? `terminal:${terminal}` : `process:${process.ppid}`,
    source: terminal ? 'terminal_fallback' : 'process_fallback',
    host: terminal ? 'terminal' : 'process',
    ancestor_pid: 0,
  };
}

function environmentSession(value, fallbackHost) {
  const known = String(value || '').match(/^(claude|codex|zcode|runner|web):(.+)$/i);
  const host = known ? known[1].toLowerCase() : String(fallbackHost || 'host');
  const sessionId = known ? String(value) : (fallbackHost ? `${fallbackHost}:${value}` : String(value));
  return { session_id: sessionId, source: 'environment', host, ancestor_pid: 0 };
}

function main() {
  const args = parseArgs(process.argv);
  const result = resolveSessionId();
  if (args.json) process.stdout.write(`${JSON.stringify(result)}\n`);
  else process.stdout.write(`${result.session_id}\n`);
}

module.exports = { resolveSessionId, hostFromCommand };

if (require.main === module) main();
