#!/usr/bin/env node
'use strict';

const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const BENCHMARK_VERSION = '2.0.0';
const CORPUS_SPECS = [
  { name: 'accepted.jsonl', expectedDetection: false },
  { name: 'rejected.jsonl', expectedDetection: true },
  { name: 'boundary.jsonl', expectedDetection: null },
];
const AGGREGATION_POLICY = {
  version: 'severity-any-v1',
  rule: 'A record is detected when it has one or more advisory or blocking findings.',
  includedSeverities: ['advisory', 'blocking'],
};
const PROVENANCE_FIELDS = ['claimStatus', 'kind', 'generator', 'model', 'revision', 'sourceNote'];
const VERDICTS = new Set(['retain', 'revise', 'reject']);
const EXPECTED_SEVERITIES = new Set(['none', 'advisory', 'blocking']);
const SEVERITY_RANK = Object.freeze({ none: 0, advisory: 1, blocking: 2 });
const USAGE = `Usage: node scripts/prose-quality-benchmark.js [--json] [--blind-packet | --lock-verdict <file> | --reveal <file>] [--fixtures-dir <dir> | --corpus <file> | --corpus-stdin]

Runs the versioned prose-quality calibration corpus through the existing deterministic
detectors. It records false positives and false negatives rather than changing detector
rules to fit the corpus. --blind-packet emits reader text without labels or provenance.
--lock-verdict creates a tamper-evident blind verdict artifact; --reveal verifies one
before revealing fixture metadata. --corpus-stdin reads private JSONL from stdin without
persisting author excerpts in the Skill repository.`;

const options = parseArgs(process.argv.slice(2));
const repoRoot = path.resolve(__dirname, '..');
const fixturesDir = path.resolve(options.fixturesDir || path.join(repoRoot, 'tests/fixtures/prose-quality'));

try {
  const corpus = options.corpusStdin
    ? loadCorpusContents(fs.readFileSync(0, 'utf8'), { mode: 'stdin', sourcePath: 'stdin', name: 'stdin.jsonl' })
    : (options.corpus ? loadSingleCorpus(options.corpus) : loadCorpus(fixturesDir));
  const corpusVersion = corpusVersionFor(corpus.records);
  const sourceIdentity = buildSourceIdentity(corpus);
  const packet = buildBlindPacket(corpus.records, corpusVersion);
  let result;
  if (options.lockVerdict) {
    result = lockVerdict(readJsonFile(options.lockVerdict, 'verdict input'), packet);
  } else if (options.reveal) {
    result = revealVerdict(readJsonFile(options.reveal, 'locked verdict artifact'), packet, corpus.records, sourceIdentity);
  } else if (options.blindPacket) {
    result = packet;
  } else {
    result = runBenchmark(corpus, corpusVersion, sourceIdentity);
  }
  print(result);
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(2);
}

function parseArgs(args) {
  const result = { json: false, blindPacket: false, fixturesDir: null, corpus: null, corpusStdin: false, lockVerdict: null, reveal: null };
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--json') result.json = true;
    else if (arg === '--blind-packet') result.blindPacket = true;
    else if (arg === '--fixtures-dir') result.fixturesDir = requiredOptionValue(args[++i], '--fixtures-dir');
    else if (arg === '--corpus') result.corpus = requiredOptionValue(args[++i], '--corpus');
    else if (arg === '--corpus-stdin') result.corpusStdin = true;
    else if (arg === '--lock-verdict') result.lockVerdict = requiredOptionValue(args[++i], '--lock-verdict');
    else if (arg === '--reveal') result.reveal = requiredOptionValue(args[++i], '--reveal');
    else if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    } else {
      throw new Error(`Unknown option: ${arg}`);
    }
  }
  const selectedModes = [result.blindPacket, Boolean(result.lockVerdict), Boolean(result.reveal)].filter(Boolean).length;
  if (selectedModes > 1) throw new Error('Choose only one of --blind-packet, --lock-verdict, or --reveal');
  const corpusSources = [Boolean(result.corpus), Boolean(result.fixturesDir), result.corpusStdin].filter(Boolean).length;
  if (corpusSources > 1) throw new Error('Choose only one of --fixtures-dir, --corpus, or --corpus-stdin');
  return result;
}

function requiredOptionValue(value, name) {
  if (!value) throw new Error(`${name} requires a file or directory`);
  return value;
}

function loadCorpus(dir) {
  const records = [];
  const files = [];
  const ids = new Set();
  for (const spec of CORPUS_SPECS) {
    const file = path.join(dir, spec.name);
    if (!fs.existsSync(file)) throw new Error(`Corpus fixture is missing: ${file}`);
    const contents = fs.readFileSync(file, 'utf8');
    const fileRecords = [];
    const lines = contents.split(/\r?\n/);
    for (const [index, line] of lines.entries()) {
      if (!line.trim()) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch (_) {
        throw new Error(`Invalid JSONL in ${file}:${index + 1}`);
      }
      validateRecord(record, { file, line: index + 1, spec, ids });
      fileRecords.push(record);
      records.push(record);
    }
    files.push({ name: spec.name, contents, records: fileRecords });
  }
  validateCorpusSupport(files, records, dir);
  return { records, files, mode: 'fixture_set', sourcePath: path.resolve(dir) };
}

function loadSingleCorpus(file) {
  const sourcePath = path.resolve(file);
  if (!fs.existsSync(sourcePath) || !fs.statSync(sourcePath).isFile()) {
    throw new Error(`Corpus file is missing: ${sourcePath}`);
  }
  const contents = fs.readFileSync(sourcePath, 'utf8');
  return loadCorpusContents(contents, { mode: 'single_file', sourcePath, name: path.basename(sourcePath) });
}

function loadCorpusContents(contents, source) {
  const records = [];
  const ids = new Set();
  const sourcePath = source.sourcePath;
  for (const [index, line] of contents.split(/\r?\n/).entries()) {
    if (!line.trim()) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch (_) {
      throw new Error(`Invalid JSONL in ${sourcePath}:${index + 1}`);
    }
    validateRecord(record, {
      file: sourcePath,
      line: index + 1,
      spec: { name: source.name, expectedDetection: null },
      ids,
    });
    records.push(record);
  }
  const files = [{ name: source.name, contents, records }];
  validateCorpusSupport(files, records, source.sourcePath);
  return { records, files, mode: source.mode, sourcePath: source.sourcePath };
}

function validateRecord(record, context) {
  const { file, line, spec, ids } = context;
  if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error(`Invalid record in ${file}:${line}`);
  for (const field of ['id', 'corpusVersion', 'category', 'text']) {
    if (!isNonEmptyString(record[field])) throw new Error(`Missing non-empty ${field} in ${file}:${line}`);
  }
  if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(record.id)) {
    throw new Error(`Corpus id must be a safe stable ID in ${file}:${line}`);
  }
  if (ids.has(record.id)) throw new Error(`Duplicate corpus id ${record.id} in ${file}:${line}`);
  ids.add(record.id);
  if (typeof record.expectedDetection !== 'boolean') throw new Error(`Missing expectedDetection in ${file}:${line}`);
  if (Object.hasOwn(record, 'expectedSeverity')) {
    if (!EXPECTED_SEVERITIES.has(record.expectedSeverity)) {
      throw new Error(`expectedSeverity must be none, advisory, or blocking in ${file}:${line}`);
    }
    const severityDetection = record.expectedSeverity !== 'none';
    if (severityDetection !== record.expectedDetection) {
      throw new Error(`expectedSeverity must agree with expectedDetection in ${file}:${line}`);
    }
  }
  if (spec.expectedDetection !== null && record.expectedDetection !== spec.expectedDetection) {
    throw new Error(`${spec.name} requires expectedDetection=${spec.expectedDetection} in ${file}:${line}`);
  }
  if (spec.name === 'boundary.jsonl') validateBoundaryRecord(record, file, line);
  validateProvenance(record.provenance, file, line);
}

function validateBoundaryRecord(record, file, line) {
  if (!['accepted', 'rejected'].includes(record.boundaryDisposition)) {
    throw new Error(`boundaryDisposition must be accepted or rejected in ${file}:${line}`);
  }
  if (!isNonEmptyString(record.boundaryReason)) {
    throw new Error(`Missing non-empty boundaryReason in ${file}:${line}`);
  }
  const expectedDetection = record.boundaryDisposition === 'rejected';
  if (record.expectedDetection !== expectedDetection) {
    throw new Error(`boundaryDisposition must agree with expectedDetection in ${file}:${line}`);
  }
}

function validateProvenance(provenance, file, line) {
  if (!provenance || typeof provenance !== 'object' || Array.isArray(provenance)) {
    throw new Error(`Missing provenance in ${file}:${line}`);
  }
  for (const field of PROVENANCE_FIELDS) {
    if (!isNonEmptyString(provenance[field])) throw new Error(`Missing non-empty provenance.${field} in ${file}:${line}`);
  }
  if (provenance.claimStatus !== 'self-declared') {
    throw new Error(`provenance.claimStatus must be self-declared in ${file}:${line}`);
  }
}

function validateCorpusSupport(files, records, dir) {
  for (const file of files) {
    if (file.records.length === 0) {
      throw new Error(`Corpus must include records in ${file.name} to support positive and negative truth classes: ${dir}`);
    }
  }
  if (!records.some(record => record.expectedDetection) || !records.some(record => !record.expectedDetection)) {
    throw new Error(`Corpus must support both positive and negative truth classes: ${dir}`);
  }
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function corpusVersionFor(records) {
  const versions = [...new Set(records.map(record => record.corpusVersion))];
  if (versions.length !== 1) throw new Error(`Corpus versions must match; found ${versions.join(', ')}`);
  return versions[0];
}

function runBenchmark(corpus, corpusVersion, sourceIdentity) {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'prose-quality-benchmark-'));
  try {
    const evaluated = corpus.records.map((record, index) => evaluateRecord(record, index, temporaryDirectory));
    const counts = countOutcomes(evaluated);
    const metrics = buildMetrics(counts.confusionMatrix);
    const metricsBySeverity = Object.fromEntries(AGGREGATION_POLICY.includedSeverities.map((severity) => [
      severity,
      buildMetrics(counts.bySeverity[severity].confusionMatrix),
    ]));
    const misses = evaluated
      .filter(entry => entry.outcome === 'false_positive' || entry.outcome === 'false_negative')
      .map(entry => ({
        id: entry.id,
        category: entry.category,
        kind: entry.outcome,
        expectedDetection: entry.expectedDetection,
        detectorFindings: entry.findings,
      }));

    return {
      schemaVersion: '2.0.0',
      corpusVersion,
      detectorVersion: buildDetectorVersion(sourceIdentity),
      sourceIdentity,
      benchmarkSourceHash: sourceIdentity.benchmarkSourceHash,
      corpusContentHash: sourceIdentity.corpusContentHash,
      precision: metrics.precision.value,
      recall: metrics.recall.value,
      falsePositiveRate: metrics.falsePositiveRate.value,
      falseNegativeRate: metrics.falseNegativeRate.value,
      metrics,
      metricsBySeverity,
      severityCalibration: buildSeverityCalibration(evaluated),
      aggregationPolicy: AGGREGATION_POLICY,
      counts,
      misses,
      corpus: {
        mode: corpus.mode,
        sourcePath: corpus.sourcePath,
        recordCount: corpus.records.length,
        coverage: [...new Set(corpus.records.map(record => record.category))].sort(),
        groups: {
          accepted: corpus.records.filter(record => record.expectedDetection === false).length,
          rejected: corpus.records.filter(record => record.expectedDetection === true).length,
          boundary: corpus.records.filter(record => Object.hasOwn(record, 'boundaryDisposition')).length,
        },
      },
      calibrationPolicy: 'Detectors are evaluated as-is; actual misses are recorded for human adjudication and must not be tuned away solely by this corpus.',
    };
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

function evaluateRecord(record, index, temporaryDirectory) {
  const file = path.join(temporaryDirectory, `${String(index + 1).padStart(2, '0')}-${record.id}.txt`);
  fs.writeFileSync(file, `${record.text}\n`, 'utf8');
  const allFindings = [
    ...runDetector('check-ai-patterns.js', file),
    ...runDetector('check-degeneration.js', file),
  ];
  const findings = allFindings.filter(finding => AGGREGATION_POLICY.includedSeverities.includes(finding.severity));
  const predictedDetection = findings.length > 0;
  const observedSeverity = findings.some(finding => finding.severity === 'blocking')
    ? 'blocking'
    : (findings.some(finding => finding.severity === 'advisory') ? 'advisory' : 'none');
  const outcome = record.expectedDetection
    ? (predictedDetection ? 'true_positive' : 'false_negative')
    : (predictedDetection ? 'false_positive' : 'true_negative');
  return {
    id: record.id,
    category: record.category,
    expectedDetection: record.expectedDetection,
    expectedSeverity: record.expectedSeverity || null,
    observedSeverity,
    outcome,
    findings,
    allFindings,
  };
}

function buildSeverityCalibration(evaluated) {
  const items = evaluated
    .filter(entry => entry.expectedSeverity)
    .map(entry => {
      const expectedRank = SEVERITY_RANK[entry.expectedSeverity];
      const observedRank = SEVERITY_RANK[entry.observedSeverity];
      const status = observedRank === expectedRank
        ? 'matched'
        : (observedRank < expectedRank ? 'under_escalated' : 'over_escalated');
      return {
        id: entry.id,
        category: entry.category,
        expectedSeverity: entry.expectedSeverity,
        observedSeverity: entry.observedSeverity,
        status,
      };
    });
  return {
    policyVersion: 'explicit-severity-v1',
    counts: {
      evaluated: items.length,
      matched: items.filter(item => item.status === 'matched').length,
      underEscalated: items.filter(item => item.status === 'under_escalated').length,
      overEscalated: items.filter(item => item.status === 'over_escalated').length,
    },
    mismatches: items.filter(item => item.status !== 'matched'),
  };
}

function runDetector(scriptName, file) {
  const script = path.join(repoRoot, 'scripts', scriptName);
  const result = childProcess.spawnSync(process.execPath, [script, '--json', '--fail-on=all', file], {
    encoding: 'utf8',
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && result.status !== 1) throw new Error(`${scriptName} failed: ${result.stderr.trim()}`);
  let parsed;
  try {
    parsed = JSON.parse(result.stdout);
  } catch (_) {
    throw new Error(`${scriptName} returned invalid JSON`);
  }
  return (parsed.findings || []).map(finding => ({
    detector: path.basename(scriptName, '.js'),
    ...finding,
    file: path.basename(finding.file),
  }));
}

function countOutcomes(evaluated) {
  const confusionMatrix = { truePositive: 0, falsePositive: 0, trueNegative: 0, falseNegative: 0 };
  const bySeverity = Object.fromEntries(AGGREGATION_POLICY.includedSeverities.map(severity => [severity, {
    findingCount: 0,
    recordCount: 0,
    confusionMatrix: { truePositive: 0, falsePositive: 0, trueNegative: 0, falseNegative: 0 },
  }]));
  for (const entry of evaluated) {
    const key = {
      true_positive: 'truePositive',
      false_positive: 'falsePositive',
      true_negative: 'trueNegative',
      false_negative: 'falseNegative',
    }[entry.outcome];
    confusionMatrix[key] += 1;
    for (const severity of AGGREGATION_POLICY.includedSeverities) {
      const severityFindings = entry.findings.filter(finding => finding.severity === severity);
      bySeverity[severity].findingCount += severityFindings.length;
      if (severityFindings.length > 0) bySeverity[severity].recordCount += 1;
      const severityOutcome = entry.expectedDetection
        ? (severityFindings.length > 0 ? 'truePositive' : 'falseNegative')
        : (severityFindings.length > 0 ? 'falsePositive' : 'trueNegative');
      bySeverity[severity].confusionMatrix[severityOutcome] += 1;
    }
  }
  return { confusionMatrix, bySeverity };
}

function buildMetrics(counts) {
  return {
    precision: metric(counts.truePositive, counts.truePositive + counts.falsePositive),
    recall: metric(counts.truePositive, counts.truePositive + counts.falseNegative),
    falsePositiveRate: metric(counts.falsePositive, counts.falsePositive + counts.trueNegative),
    falseNegativeRate: metric(counts.falseNegative, counts.falseNegative + counts.truePositive),
  };
}

function metric(numerator, denominator) {
  if (denominator === 0) return { status: 'unavailable', value: null, numerator, denominator };
  return { status: 'available', value: Number((numerator / denominator).toFixed(6)), numerator, denominator };
}

function buildSourceIdentity(corpus) {
  const detectorSourceHashes = Object.fromEntries(['check-ai-patterns.js', 'check-degeneration.js'].map(name => [
    path.basename(name, '.js'),
    hashFile(path.join(repoRoot, 'scripts', name)),
  ]));
  return {
    identityVersion: 'prose-quality-inputs-v1',
    benchmarkSourceHash: hashFile(__filename),
    corpusContentHash: hashString(corpus.files.map(file => `${file.name}\0${file.contents}`).join('\n\0')),
    detectorSourceHashes,
    sourceCommit: gitIdentity(['rev-parse', 'HEAD']),
    sourceTree: gitIdentity(['rev-parse', 'HEAD^{tree}']),
  };
}

function buildDetectorVersion(sourceIdentity) {
  const hashes = Object.entries(sourceIdentity.detectorSourceHashes)
    .map(([name, hash]) => `${name}@${hash.slice('sha256:'.length, 'sha256:'.length + 12)}`);
  return [`prose-quality-benchmark@${BENCHMARK_VERSION}`, ...hashes].join(';');
}

function gitIdentity(args) {
  const result = childProcess.spawnSync('git', args, { cwd: repoRoot, encoding: 'utf8' });
  return result.status === 0 ? result.stdout.trim() : 'unavailable';
}

function hashFile(file) {
  return hashString(fs.readFileSync(file));
}

function hashString(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function buildBlindPacket(records, corpusVersion) {
  const items = records.map(record => ({ id: record.id, text: record.text }));
  const packetDigest = hashCanonical({ packetVersion: 'v2', corpusVersion, items });
  return {
    packetVersion: 'v2',
    packetId: `blind-packet-v2-${packetDigest.slice('sha256:'.length, 'sha256:'.length + 16)}`,
    packetDigest,
    corpusVersion,
    instructions: 'Read each passage without guessing its source. Record retain, revise, or reject with textual evidence. Lock independent verdicts before metadata is revealed.',
    items,
  };
}

function lockVerdict(submission, packet) {
  validateVerdictSubmission(submission, packet);
  const lockedPayload = {
    schemaVersion: '1.0.0',
    protocolVersion: 'blind-verdict-lock-v1',
    artifactType: 'blind-verdict-lock',
    packetId: packet.packetId,
    packetDigest: packet.packetDigest,
    verdicts: submission.verdicts.map(verdict => ({ id: verdict.id, verdict: verdict.verdict, evidence: verdict.evidence })),
  };
  return {
    schemaVersion: '1.0.0',
    artifactType: 'blind-verdict-lock',
    protocolVersion: 'blind-verdict-lock-v1',
    lockedAt: new Date().toISOString(),
    lockedPayload,
    lockedVerdictHash: hashCanonical(lockedPayload),
  };
}

function validateVerdictSubmission(submission, packet) {
  if (!submission || typeof submission !== 'object' || Array.isArray(submission)) throw new Error('Verdict input must be an object');
  if (submission.schemaVersion !== '1.0.0') throw new Error('Verdict input requires schemaVersion=1.0.0');
  if (submission.packetId !== packet.packetId || submission.packetDigest !== packet.packetDigest) {
    throw new Error('Verdict input does not match the current blind packet');
  }
  if (!Array.isArray(submission.verdicts)) throw new Error('Verdict input requires verdicts[]');
  validateVerdicts(submission.verdicts, packet.items);
}

function validateVerdicts(verdicts, items) {
  const expectedIds = new Set(items.map(item => item.id));
  if (verdicts.length !== expectedIds.size) throw new Error('Verdict input must contain exactly one verdict for every blind packet item');
  const seen = new Set();
  for (const verdict of verdicts) {
    if (!verdict || typeof verdict !== 'object' || Array.isArray(verdict)) throw new Error('Each verdict must be an object');
    if (!expectedIds.has(verdict.id) || seen.has(verdict.id)) throw new Error('Verdict input contains an unknown or duplicate item id');
    if (!VERDICTS.has(verdict.verdict)) throw new Error('Verdict must be retain, revise, or reject');
    if (!isNonEmptyString(verdict.evidence)) throw new Error('Verdict evidence must be non-empty');
    seen.add(verdict.id);
  }
}

function revealVerdict(lock, packet, records, sourceIdentity) {
  if (!lock || typeof lock !== 'object' || Array.isArray(lock)) throw new Error('Locked verdict artifact must be an object');
  if (lock.schemaVersion !== '1.0.0' || lock.artifactType !== 'blind-verdict-lock' || lock.protocolVersion !== 'blind-verdict-lock-v1') {
    throw new Error('Locked verdict artifact has an unsupported schema');
  }
  if (lock.lockedVerdictHash !== hashCanonical(lock.lockedPayload)) throw new Error('lockedVerdictHash does not match lockedPayload');
  const payload = lock.lockedPayload;
  if (!payload || payload.packetId !== packet.packetId || payload.packetDigest !== packet.packetDigest) {
    throw new Error('Locked verdict artifact does not match the current blind packet');
  }
  validateVerdicts(payload.verdicts, packet.items);
  return {
    schemaVersion: '1.0.0',
    artifactType: 'blind-verdict-reveal',
    protocolVersion: 'blind-verdict-lock-v1',
    revealedAt: new Date().toISOString(),
    lockedAt: lock.lockedAt,
    lockedVerdictHash: lock.lockedVerdictHash,
    packetId: packet.packetId,
    packetDigest: packet.packetDigest,
    sourceIdentity,
    verdicts: payload.verdicts,
    reveal: records.map(record => ({
      id: record.id,
      category: record.category,
      expectedDetection: record.expectedDetection,
      ...(record.expectedSeverity ? { expectedSeverity: record.expectedSeverity } : {}),
      ...(Object.hasOwn(record, 'boundaryDisposition') ? { boundaryDisposition: record.boundaryDisposition, boundaryReason: record.boundaryReason } : {}),
      provenance: record.provenance,
    })),
  };
}

function readJsonFile(file, label) {
  let contents;
  try {
    contents = fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new Error(`Unable to read ${label}: ${error.message}`);
  }
  try {
    return JSON.parse(contents);
  } catch (_) {
    throw new Error(`Invalid JSON in ${label}: ${file}`);
  }
}

function hashCanonical(value) {
  return hashString(stableJson(value));
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function print(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}
