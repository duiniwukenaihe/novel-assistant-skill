#!/usr/bin/env node
'use strict';

const { performance } = require('perf_hooks');
const { buildActiveMemoryIndex } = require('./lib/memory-active-index');
const { retrieveFacts } = require('./lib/chinese-memory-retrieval');

const BASELINE_FACT_COUNT = 500;
const CANDIDATE_FACT_COUNT = 1000;
const MAX_ELAPSED_GROWTH_RATIO = 5;
const MAX_HEAP_GROWTH_RATIO = 3;

const args = parseArgs(process.argv.slice(2));
const baseline = benchmark(BASELINE_FACT_COUNT);
const candidate = benchmark(CANDIDATE_FACT_COUNT);
const growth = {
  elapsed_ratio: ratio(candidate.elapsed_ms, baseline.elapsed_ms),
  heap_ratio: ratio(candidate.heap_delta_bytes, baseline.heap_delta_bytes),
};
const failed = growth.elapsed_ratio > MAX_ELAPSED_GROWTH_RATIO || growth.heap_ratio > MAX_HEAP_GROWTH_RATIO;
const result = {
  schemaVersion: '1.0.0',
  status: failed ? 'fail' : 'pass',
  baseline,
  candidate,
  growth,
  thresholds: {
    elapsed_growth_ratio_max: MAX_ELAPSED_GROWTH_RATIO,
    heap_growth_ratio_max: MAX_HEAP_GROWTH_RATIO,
    rationale: '同机 500→1000 条事实的相对增长；不使用固定毫秒阈值。',
  },
  retrieval: candidate.retrieval,
};

if (args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
else process.stdout.write(`memory-index scale ${result.status}: elapsed x${growth.elapsed_ratio}, heap x${growth.heap_ratio}\n`);
process.exitCode = failed ? 1 : 0;

function benchmark(factCount) {
  const events = createEvents(factCount);
  const heapBefore = process.memoryUsage().heapUsed;
  const started = performance.now();
  const index = buildActiveMemoryIndex(events);
  const rows = retrieveFacts(index, `第${factCount}章 主线承诺`, { limit: 5 });
  const elapsed = performance.now() - started;
  const heapDelta = Math.max(0, process.memoryUsage().heapUsed - heapBefore);
  return {
    fact_count: factCount,
    active_documents: index.statistics.active_documents,
    elapsed_ms: Number(elapsed.toFixed(3)),
    heap_delta_bytes: heapDelta,
    retrieval: { top_fact_id: String((rows[0] || {}).fact_id || '') },
  };
}

function createEvents(count) {
  return Array.from({ length: count }, (_, offset) => {
    const chapter = offset + 1;
    return {
      fact_id: `fact.chapter.${String(chapter).padStart(4, '0')}`,
      subject: `角色${chapter}`,
      predicate: '主线承诺',
      object: `第${chapter}章兑现代价`,
      aliases: [`第${chapter}章`, `角色${chapter}`],
      dependencies: chapter > 1 ? [`第${chapter - 1}章`] : [],
      evidence: [{ path: `追踪/证据/第${chapter}章.md` }],
      status: 'active',
    };
  });
}

function ratio(candidate, baseline) {
  if (baseline <= 0) return candidate <= 0 ? 1 : candidate;
  return Number((candidate / baseline).toFixed(3));
}

function parseArgs(argv) {
  const out = { json: false };
  for (const arg of argv) {
    if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') {
      process.stdout.write('Usage: node scripts/memory-index-scale-check.js [--json]\n');
      process.exit(0);
    } else throw new Error(`unknown argument: ${arg}`);
  }
  return out;
}
