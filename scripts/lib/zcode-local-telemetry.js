'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SESSION_ID_PATTERN = /^sess_[A-Za-z0-9-]+$/;
const TRACE_ID_PATTERN = /^[A-Za-z0-9-]+$/;

function readZcodeTurnUsage(options = {}) {
  const sessionId = String(options.sessionId || '');
  const traceId = String(options.traceId || '');
  if (!SESSION_ID_PATTERN.test(sessionId)) return null;
  if (traceId && !TRACE_ID_PATTERN.test(traceId)) return null;

  const database = path.resolve(String(options.database || defaultDatabasePath()));
  if (!fs.existsSync(database) || !fs.statSync(database).isFile()) return null;
  const sqlite = String(options.sqliteExecutable || 'sqlite3');
  const query = buildTurnUsageQuery(sessionId, traceId);
  const result = spawnSync(sqlite, ['-json', database, query], {
    encoding: 'utf8',
    timeout: Number(options.timeoutMs) || 1500,
    windowsHide: true,
  });
  if (result.error || result.status !== 0) return null;

  let rows;
  try {
    rows = JSON.parse(String(result.stdout || '[]'));
  } catch {
    return null;
  }
  const row = Array.isArray(rows) ? rows[0] : null;
  return normalizeTurnUsage(row, { sessionId, traceId });
}

function defaultDatabasePath() {
  return path.join(os.homedir(), '.zcode', 'cli', 'db', 'db.sqlite');
}

function buildTurnUsageQuery(sessionId, traceId) {
  const where = traceId
    ? `session_id = ${quoteSql(sessionId)} AND trace_id = ${quoteSql(traceId)}`
    : `session_id = ${quoteSql(sessionId)}`;
  return [
    'SELECT session_id, trace_id, status,',
    'input_tokens, output_tokens, reasoning_tokens, cache_creation_input_tokens,',
    'cache_read_input_tokens, computed_total_tokens, duration_ms, completed_at',
    'FROM turn_usage',
    `WHERE ${where} AND status = 'completed'`,
    'ORDER BY completed_at DESC',
    'LIMIT 1;',
  ].join(' ');
}

function quoteSql(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function normalizeTurnUsage(row, expected) {
  if (!row || row.session_id !== expected.sessionId || row.status !== 'completed') return null;
  if (expected.traceId && row.trace_id !== expected.traceId) return null;
  const inputTokens = finiteNonNegative(row.input_tokens);
  const outputTokens = finiteNonNegative(row.output_tokens);
  if (inputTokens === null || outputTokens === null) return null;
  return {
    type: 'zcode_local_turn_usage',
    sessionId: row.session_id,
    traceId: row.trace_id || '',
    source: 'zcode_local_sqlite',
    usage: {
      inputTokens,
      outputTokens,
      cacheReadTokens: finiteNonNegative(row.cache_read_input_tokens) || 0,
      cacheWriteTokens: finiteNonNegative(row.cache_creation_input_tokens) || 0,
      durationMs: finiteNonNegative(row.duration_ms) || 0,
    },
    totalTokens: finiteNonNegative(row.computed_total_tokens),
    completedAt: finiteNonNegative(row.completed_at),
  };
}

function finiteNonNegative(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}

module.exports = {
  buildTurnUsageQuery,
  defaultDatabasePath,
  normalizeTurnUsage,
  readZcodeTurnUsage,
};
