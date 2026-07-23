'use strict';

const DEFAULT_POLICY = {
  maxWindowChars: 65536,
  maxRepeatedLine: 4,
  maxRepeatedTerm: 12,
  maxToolFailure: 3,
  maxProviderFailure: 3,
  idleTimeoutMs: 5 * 60 * 1000,
  maxTotalBytes: 10 * 1024 * 1024,
};

const TOOL_FAILURE_PATTERNS = [
  /Invalid tool parameters/gi,
  /Error writing file/gi,
  /Error editing file/gi,
  /parse error near/gi,
  /PostToolUse:Edit hook returned blocking error/gi,
];

const PROVIDER_FAILURE_PATTERNS = [
  /API Error/gi,
  /output new_sensitive/gi,
  /Retrying(?: in \d+s| attempt \d+\/\d+)/gi,
  /Reconnecting\.\.\.\s*\d+\/\d+\s*\(request timed out\)/gi,
  /Falling back from WebSockets to HTTPS transport\.\s*request timed out/gi,
];

const TERMINAL_RUN_PATTERNS = [
  { pattern: /error_max_budget_usd/gi, reason: 'budget_exhausted' },
  { pattern: /max budget(?:\s+has)?\s+been reached/gi, reason: 'budget_exhausted' },
];

function createStreamHealthMonitor(overrides = {}) {
  const policy = { ...DEFAULT_POLICY, ...overrides };
  let window = '';
  let startedAt = null;
  let lastActivityAt = null;
  let totalBytes = 0;
  let stopReason = '';
  let stopEvidence = {};
  const events = [];
  const lineCounts = new Map();
  let pendingLine = '';
  const counters = {
    tool_failures: 0,
    provider_failures: 0,
    chunks: 0,
  };

  function start(now = Date.now()) {
    if (startedAt === null) startedAt = now;
    if (lastActivityAt === null) lastActivityAt = now;
    return snapshot(now);
  }

  function ingest(channel, chunk, now = Date.now()) {
    if (chunk === undefined || chunk === null || chunk === '') return snapshot(now);
    const text = Buffer.isBuffer(chunk) ? chunk.toString('utf8') : String(chunk);
    if (startedAt === null) startedAt = now;
    lastActivityAt = now;
    counters.chunks += 1;
    totalBytes += Buffer.byteLength(text);
    window = `${window}${text}`.slice(-policy.maxWindowChars);

    if (!stopReason && totalBytes > policy.maxTotalBytes) {
      stop('output_limit_exceeded', { total_bytes: totalBytes, limit_bytes: policy.maxTotalBytes });
    }

    scanFailures(text);
    scanLines(text);
    scanRepeatedTerm();
    return snapshot(now);
  }

  function scanLines(text) {
    const combined = `${pendingLine}${text}`;
    const lines = combined.split(/\r?\n/);
    pendingLine = lines.pop() || '';
    for (const line of lines) {
      const normalized = normalizeLine(line);
      if (normalized.length < 8) continue;
      const count = (lineCounts.get(normalized) || 0) + 1;
      lineCounts.set(normalized, count);
      if (!stopReason && count > policy.maxRepeatedLine) {
        stop('model_degradation_repeated_line', { line: normalized.slice(0, 240), count });
      }
    }
  }

  function scanFailures(text) {
    for (const terminal of TERMINAL_RUN_PATTERNS) {
      if (!stopReason && matchCount(text, terminal.pattern) > 0) {
        stop(terminal.reason, { host_signal: terminal.reason });
      }
    }
    const toolHits = TOOL_FAILURE_PATTERNS.reduce((sum, pattern) => sum + matchCount(text, pattern), 0);
    counters.tool_failures += toolHits;
    if (!stopReason && counters.tool_failures > policy.maxToolFailure) {
      stop('tool_failure_loop', { count: counters.tool_failures });
    }

    const providerHits = PROVIDER_FAILURE_PATTERNS.reduce((sum, pattern) => sum + matchCount(text, pattern), 0);
    counters.provider_failures += providerHits > 0 ? 1 : 0;
    if (!stopReason && counters.provider_failures > policy.maxProviderFailure) {
      stop('provider_failure_loop', { count: counters.provider_failures });
    }
  }

  function scanRepeatedTerm() {
    if (stopReason) return;
    const compact = window.replace(/[\s\p{P}\p{S}]+/gu, '');
    for (let length = 8; length >= 2; length -= 1) {
      for (let offset = Math.max(0, compact.length - 4096); offset + length * (policy.maxRepeatedTerm + 1) <= compact.length; offset += 1) {
        const term = compact.slice(offset, offset + length);
        if (!/[\p{Script=Han}]/u.test(term)) continue;
        let count = 1;
        let cursor = offset + length;
        while (compact.slice(cursor, cursor + length) === term) {
          count += 1;
          cursor += length;
        }
        if (count > policy.maxRepeatedTerm) {
          stop('model_degradation_repeated_term', { term, count });
          return;
        }
      }
    }
  }

  function stop(reason, evidence) {
    if (stopReason) return;
    stopReason = reason;
    stopEvidence = evidence || {};
    events.push({ reason: stopReason, evidence: { ...stopEvidence } });
  }

  function evaluateIdle(now) {
    if (!stopReason && startedAt !== null && lastActivityAt !== null && now - lastActivityAt > policy.idleTimeoutMs) {
      stop('idle_timeout', { idle_ms: now - lastActivityAt });
    }
  }

  function shouldAbort(now = Date.now()) {
    evaluateIdle(now);
    return Boolean(stopReason);
  }

  function snapshot(now = Date.now()) {
    evaluateIdle(now);
    return {
      status: stopReason ? 'blocked' : 'healthy',
      stop_reason: stopReason,
      evidence: stopEvidence,
      started_at_ms: startedAt,
      last_activity_at_ms: lastActivityAt,
      total_bytes: totalBytes,
      window_chars: window.length,
      counters: { ...counters },
      events: events.map((event) => ({ ...event, evidence: { ...event.evidence } })),
    };
  }

  return {
    abort: stop,
    ingest,
    start,
    shouldAbort,
    snapshot,
  };
}

function normalizeLine(line) {
  return String(line || '').trim().replace(/\s+/g, ' ');
}

function matchCount(text, pattern) {
  pattern.lastIndex = 0;
  const matches = String(text || '').match(pattern);
  pattern.lastIndex = 0;
  return matches ? matches.length : 0;
}

module.exports = {
  DEFAULT_POLICY,
  TERMINAL_RUN_PATTERNS,
  createStreamHealthMonitor,
};
