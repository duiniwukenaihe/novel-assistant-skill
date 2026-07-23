#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { atomicWriteJson } = require('./lib/workflow-state-store');

const SCHEMA_VERSION = '1.0.0';
const DEFAULT_TTL_MS = 10 * 60 * 1000;

function workflowRoot(projectRoot) {
  return path.join(path.resolve(projectRoot), '追踪', 'workflow');
}

function sessionsRoot(projectRoot) {
  return path.join(workflowRoot(projectRoot), 'sessions');
}

function safeSessionFileName(sessionId) {
  return String(sessionId || '').trim().replace(/[^a-zA-Z0-9._:-]+/g, '_') || 'unknown';
}

function sessionHeartbeatPath(projectRoot, sessionId) {
  return path.join(sessionsRoot(projectRoot), `${safeSessionFileName(sessionId)}.json`);
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function normalizeCapability(value) {
  const cap = value && typeof value === 'object' ? value : {};
  return {
    host_execution_mode: String(cap.host_execution_mode || cap.mode || 'cooperative_interactive'),
    stream_abort: cap.stream_abort === true,
    process_liveness: cap.process_liveness === true,
    exact_usage: cap.exact_usage === true,
  };
}

function recordSessionHeartbeat(projectRoot, input = {}) {
  const root = path.resolve(projectRoot);
  const sessionId = String(input.sessionId || input.session_id || '').trim();
  if (!sessionId) throw new Error('session heartbeat requires sessionId');
  const observedAt = input.observedAt || input.observed_at || new Date().toISOString();
  const observedMs = new Date(observedAt).getTime();
  const expiresAt = input.expiresAt || input.expires_at || new Date((Number.isFinite(observedMs) ? observedMs : Date.now()) + DEFAULT_TTL_MS).toISOString();
  const record = {
    schemaVersion: SCHEMA_VERSION,
    session_id: sessionId,
    task_family_id: String(input.taskFamilyId || input.task_family_id || ''),
    host: String(input.host || os.hostname() || 'unknown'),
    observed_at: new Date(observedAt).toISOString(),
    expires_at: new Date(expiresAt).toISOString(),
    capability: normalizeCapability(input.capability),
    updated_at: new Date().toISOString(),
  };
  const file = sessionHeartbeatPath(root, sessionId);
  atomicWriteJson(file, record);
  return { status: 'recorded', heartbeat: record, path: file };
}

function readSessionHeartbeat(projectRoot, sessionId) {
  const parsed = readJson(sessionHeartbeatPath(projectRoot, sessionId));
  if (!parsed || parsed.__error) return null;
  return parsed;
}

function heartbeatLiveness(projectRoot, sessionId, now = new Date()) {
  const heartbeat = readSessionHeartbeat(projectRoot, sessionId);
  if (!heartbeat) return { status: 'unknown', heartbeat: null };
  const expiresAt = new Date(heartbeat.expires_at || '').getTime();
  if (!Number.isFinite(expiresAt)) return { status: 'expired_heartbeat', heartbeat };
  return expiresAt > now.getTime()
    ? { status: 'running', heartbeat }
    : { status: 'expired_heartbeat', heartbeat };
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (!item.startsWith('--')) continue;
    const key = item.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) out[key] = true;
    else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  const projectRoot = args.projectRoot || process.cwd();
  if (cmd === 'record') {
    const result = recordSessionHeartbeat(projectRoot, {
      sessionId: args.sessionId,
      taskFamilyId: args.taskFamilyId,
      host: args.host,
      observedAt: args.observedAt,
      expiresAt: args.expiresAt,
      capability: {
        host_execution_mode: args.hostExecutionMode || 'cooperative_interactive',
        stream_abort: args.streamAbort === true || args.streamAbort === 'true',
        process_liveness: args.processLiveness === true || args.processLiveness === 'true',
        exact_usage: args.exactUsage === true || args.exactUsage === 'true',
      },
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return;
  }
  if (cmd === 'inspect') {
    const heartbeat = readSessionHeartbeat(projectRoot, args.sessionId);
    const live = heartbeatLiveness(projectRoot, args.sessionId);
    process.stdout.write(`${JSON.stringify({ status: heartbeat ? 'ok' : 'missing', heartbeat, liveness: live.status }, null, 2)}\n`);
    return;
  }
  process.stderr.write('Usage: node scripts/workflow-session-heartbeat.js <record|inspect> --project-root <dir> --session-id <id> [--task-family-id <id>] [--host <host>]\n');
  process.exit(1);
}

if (require.main === module) main();

module.exports = {
  recordSessionHeartbeat,
  readSessionHeartbeat,
  heartbeatLiveness,
  sessionsRoot,
  sessionHeartbeatPath,
};
