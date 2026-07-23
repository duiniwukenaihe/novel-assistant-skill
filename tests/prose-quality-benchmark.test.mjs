import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const script = path.join(repoRoot, 'scripts/prose-quality-benchmark.js');
const baselinePath = path.join(repoRoot, 'reports/verification/prose-quality-baseline.json');

function runBenchmark(...args) {
  return JSON.parse(execFileSync(process.execPath, [script, '--json', ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
  }));
}

function runBenchmarkFailure(...args) {
  return spawnSync(process.execPath, [script, '--json', ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
}

function runBenchmarkInput(records, ...args) {
  const result = spawnSync(process.execPath, [script, '--json', '--corpus-stdin', ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: `${records.map(record => JSON.stringify(record)).join('\n')}\n`,
  });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout);
  return JSON.parse(result.stdout);
}

function fixture({ id, expectedDetection, expectedSeverity, boundaryDisposition, provenance, text } = {}) {
  return {
    id: id ?? 'case-fixture',
    corpusVersion: 'v-test',
    category: 'test-category',
    expectedDetection: expectedDetection ?? false,
    text: text ?? '一段用于语料契约测试的自然文本。',
    ...(expectedSeverity ? { expectedSeverity } : {}),
    ...(boundaryDisposition ? { boundaryDisposition, boundaryReason: 'Adjudicated fixture boundary.' } : {}),
    provenance: provenance ?? {
      claimStatus: 'self-declared',
      kind: 'fixture',
      generator: 'unknown',
      model: 'unknown',
      revision: 'test',
      sourceNote: 'Fixture-declared provenance; not independently verified.',
    },
  };
}

function withFixtureCorpus(files, action) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prose-quality-test-'));
  try {
    for (const [name, records] of Object.entries(files)) {
      fs.writeFileSync(path.join(dir, name), `${records.map(record => JSON.stringify(record)).join('\n')}\n`, 'utf8');
    }
    return action(dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('reports a reproducible calibration schema with honest actual misses', () => {
  const result = runBenchmark();
  const total = Object.values(result.counts.confusionMatrix).reduce((sum, value) => sum + value, 0);
  const actualMisses = result.misses.filter(miss => miss.kind === 'false_positive' || miss.kind === 'false_negative');

  assert.equal(result.schemaVersion, '2.0.0');
  assert.equal(result.corpusVersion, 'v1');
  assert.equal(total, result.corpus.recordCount);
  assert.equal(actualMisses.length, result.counts.confusionMatrix.falsePositive + result.counts.confusionMatrix.falseNegative);
  assert.ok(actualMisses.every(miss => miss.id && miss.category && Array.isArray(miss.detectorFindings)));
  assert.deepEqual(Object.keys(result.metrics).sort(), ['falseNegativeRate', 'falsePositiveRate', 'precision', 'recall']);
  assert.ok(Object.values(result.metrics).every(metric => metric.status === 'available' && metric.value >= 0 && metric.value <= 1));
  assert.deepEqual(result.aggregationPolicy, {
    version: 'severity-any-v1',
    rule: 'A record is detected when it has one or more advisory or blocking findings.',
    includedSeverities: ['advisory', 'blocking'],
  });
  assert.ok(result.counts.bySeverity.advisory);
  assert.ok(result.counts.bySeverity.blocking);
  assert.equal(result.metricsBySeverity.blocking.precision.status, 'available');
  assert.equal(result.metricsBySeverity.blocking.falsePositiveRate.status, 'available');
  assert.equal(result.metricsBySeverity.advisory.recall.status, 'available');
  assert.match(result.sourceIdentity.benchmarkSourceHash, /^sha256:[a-f0-9]{64}$/);
  assert.match(result.sourceIdentity.corpusContentHash, /^sha256:[a-f0-9]{64}$/);
  assert.ok(result.sourceIdentity.sourceCommit);
  assert.doesNotMatch(JSON.stringify(result), /prose-quality-benchmark-/);
});

test('accepts a local single-file corpus without treating it as a public fixture set', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'prose-quality-private-corpus-'));
  try {
    const corpus = path.join(tmp, 'author-corpus.jsonl');
    fs.writeFileSync(corpus, [
      fixture({ id: 'author-accepted', expectedDetection: false }),
      fixture({ id: 'author-rejected', expectedDetection: true }),
    ].map(item => JSON.stringify(item)).join('\n') + '\n', 'utf8');
    const result = runBenchmark('--corpus', corpus);
    assert.equal(result.corpus.mode, 'single_file');
    assert.equal(result.corpus.recordCount, 2);
    assert.equal(result.corpus.sourcePath, corpus);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test('accepts a private corpus stream and reports severity agreement without persisting excerpts', () => {
  const records = [
    fixture({ id: 'stream-none', expectedDetection: false, expectedSeverity: 'none' }),
    fixture({
      id: 'stream-blocking',
      expectedDetection: true,
      expectedSeverity: 'blocking',
      text: '修真修真修真修真修真修真修真修真修真修真修真修真修真修真修真修真修真修真',
    }),
  ];
  const result = runBenchmarkInput(records);
  assert.equal(result.corpus.mode, 'stdin');
  assert.equal(result.corpus.sourcePath, 'stdin');
  assert.deepEqual(result.severityCalibration.counts, {
    evaluated: 2,
    matched: 2,
    underEscalated: 0,
    overEscalated: 0,
  });
  assert.doesNotMatch(JSON.stringify(result), /一段用于语料契约测试|修真修真/);
});

test('rejects inconsistent detection and severity labels from a platform corpus', () => {
  const record = fixture({ id: 'bad-severity', expectedDetection: false, expectedSeverity: 'blocking' });
  const result = spawnSync(process.execPath, [script, '--json', '--corpus-stdin'], {
    cwd: repoRoot,
    encoding: 'utf8',
    input: `${JSON.stringify(record)}\n`,
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /expectedSeverity.*expectedDetection/);
});

test('enforces file semantics, safe unique IDs, non-empty provenance, and two truth classes', () => {
  const base = {
    'accepted.jsonl': [fixture({ id: 'case-accepted', expectedDetection: false })],
    'rejected.jsonl': [fixture({ id: 'case-rejected', expectedDetection: true })],
    'boundary.jsonl': [fixture({ id: 'case-boundary', expectedDetection: false, boundaryDisposition: 'accepted' })],
  };

  withFixtureCorpus({ ...base, 'accepted.jsonl': [fixture({ id: 'case-accepted', expectedDetection: true })] }, (dir) => {
    const result = runBenchmarkFailure('--fixtures-dir', dir);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /accepted\.jsonl.*expectedDetection=false/);
  });
  withFixtureCorpus({ ...base, 'boundary.jsonl': [fixture({ id: 'case-boundary', expectedDetection: false })] }, (dir) => {
    const result = runBenchmarkFailure('--fixtures-dir', dir);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /boundaryDisposition/);
  });
  withFixtureCorpus({ ...base, 'rejected.jsonl': [fixture({ id: 'case-accepted', expectedDetection: true })] }, (dir) => {
    const result = runBenchmarkFailure('--fixtures-dir', dir);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Duplicate corpus id/);
  });
  withFixtureCorpus({ ...base, 'accepted.jsonl': [fixture({ id: '../case', expectedDetection: false })] }, (dir) => {
    const result = runBenchmarkFailure('--fixtures-dir', dir);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /safe stable ID/);
  });
  withFixtureCorpus({ ...base, 'accepted.jsonl': [fixture({ provenance: {}, expectedDetection: false })] }, (dir) => {
    const result = runBenchmarkFailure('--fixtures-dir', dir);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /provenance\.(claimStatus|kind)/);
  });
  withFixtureCorpus({
    'accepted.jsonl': [fixture({ id: 'case-accepted', expectedDetection: false })],
    'rejected.jsonl': [],
    'boundary.jsonl': [fixture({ id: 'case-boundary', expectedDetection: false, boundaryDisposition: 'accepted' })],
  }, (dir) => {
    const result = runBenchmarkFailure('--fixtures-dir', dir);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /positive and negative truth classes/);
  });
});

test('baseline identity matches the current benchmark inputs and exposes stale evidence', () => {
  const live = runBenchmark();
  const baseline = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));

  assert.deepEqual(bindingIdentity(baseline.sourceIdentity), bindingIdentity(live.sourceIdentity));
  assert.ok(baseline.sourceIdentity.sourceCommit);
  assert.ok(baseline.sourceIdentity.sourceTree);
  assert.deepEqual(baseline.aggregationPolicy, live.aggregationPolicy);
  assert.equal(baseline.corpusContentHash, live.sourceIdentity.corpusContentHash);
  assert.equal(baseline.benchmarkSourceHash, live.sourceIdentity.benchmarkSourceHash);
});

function bindingIdentity(identity) {
  return {
    identityVersion: identity.identityVersion,
    benchmarkSourceHash: identity.benchmarkSourceHash,
    corpusContentHash: identity.corpusContentHash,
    detectorSourceHashes: identity.detectorSourceHashes,
  };
}

test('blind-reader verdicts lock before reveal and fixture provenance remains a claim', () => {
  const packet = runBenchmark('--blind-packet');
  const serialized = JSON.stringify(packet);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'prose-quality-lock-'));
  try {
    assert.equal(packet.packetVersion, 'v2');
    assert.ok(packet.packetId.startsWith('blind-packet-v2-'));
    assert.ok(packet.items.length >= 6);
    assert.ok(packet.items.every(item => typeof item.id === 'string' && typeof item.text === 'string'));
    assert.doesNotMatch(serialized, /"(?:label|expectedDetection|model|generator|revision|provenance|category|claimStatus)"\s*:/i);

    const verdictInput = path.join(tmp, 'verdict.json');
    fs.writeFileSync(verdictInput, `${JSON.stringify({
      schemaVersion: '1.0.0',
      packetId: packet.packetId,
      packetDigest: packet.packetDigest,
      verdicts: packet.items.map(item => ({ id: item.id, verdict: 'retain', evidence: `Reviewed ${item.id}.` })),
    }, null, 2)}\n`, 'utf8');

    const locked = runBenchmark('--lock-verdict', verdictInput);
    assert.equal(locked.artifactType, 'blind-verdict-lock');
    assert.match(locked.lockedVerdictHash, /^sha256:[a-f0-9]{64}$/);
    assert.doesNotMatch(JSON.stringify(locked), /"(?:expectedDetection|model|generator|revision|provenance|category|claimStatus)"\s*:/i);

    const lockedPath = path.join(tmp, 'locked.json');
    fs.writeFileSync(lockedPath, `${JSON.stringify(locked, null, 2)}\n`, 'utf8');
    const revealed = runBenchmark('--reveal', lockedPath);
    assert.equal(revealed.artifactType, 'blind-verdict-reveal');
    assert.equal(revealed.lockedVerdictHash, locked.lockedVerdictHash);
    assert.ok(revealed.reveal.every(item => item.provenance.claimStatus === 'self-declared'));

    locked.lockedPayload.verdicts[0].evidence = 'tampered';
    fs.writeFileSync(lockedPath, `${JSON.stringify(locked, null, 2)}\n`, 'utf8');
    const tampered = runBenchmarkFailure('--reveal', lockedPath);
    assert.equal(tampered.status, 2);
    assert.match(tampered.stderr, /lockedVerdictHash does not match/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
