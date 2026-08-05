#!/usr/bin/env node
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..');
const CATEGORIES = new Set([
  'runner_incompatibility',
  'stale_contract',
  'real_regression',
  'environmental',
  'needs_codex_investigation',
]);
const DISALLOWED_TOOLS = [
  'Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'WebSearch',
  'Read', 'Glob', 'Grep', 'Agent', 'AskUserQuestion', 'EnterPlanMode',
  'ExitPlanMode', 'Skill', 'TaskStop', 'TodoRead', 'TodoWrite', 'SendMessage',
  'ReadSessionContext',
].join(',');
const ZCODE_CANDIDATES = [
  '/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs',
  '/usr/local/bin/zcode',
  '/opt/homebrew/bin/zcode',
];

function sha256(value) {
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex')}`;
}

function parseArgs(argv) {
  const args = { evidence: [], output: '', zcode: '', timeoutMs: 120_000 };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--evidence') args.evidence.push(argv[++index] || '');
    else if (arg === '--output') args.output = argv[++index] || '';
    else if (arg === '--zcode') args.zcode = argv[++index] || '';
    else if (arg === '--timeout-ms') args.timeoutMs = Number(argv[++index]);
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!args.evidence.length || args.evidence.some(file => !path.isAbsolute(file))) {
    throw new Error('evidence paths must be absolute');
  }
  if (!path.isAbsolute(args.output)) throw new Error('output must be absolute');
  if (!Number.isInteger(args.timeoutMs) || args.timeoutMs < 50 || args.timeoutMs > 600_000) {
    throw new Error('timeout-ms must be an integer from 50 to 600000');
  }
  if (args.zcode && !path.isAbsolute(args.zcode)) throw new Error('zcode path must be absolute');
  return args;
}

function findOnPath(name) {
  for (const directory of String(process.env.PATH || '').split(path.delimiter).filter(Boolean)) {
    const candidate = path.join(directory, name);
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) return candidate;
  }
  return '';
}

function resolveZcode(explicit) {
  const candidates = [explicit, findOnPath('zcode'), ...ZCODE_CANDIDATES].filter(Boolean);
  const resolved = candidates.find(candidate => fs.existsSync(candidate) && fs.statSync(candidate).isFile());
  if (!resolved) throw new Error('ZCode executable not found');
  return path.resolve(resolved);
}

function loadEvidence(files) {
  const loaded = files.map((file) => {
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) throw new Error(`missing evidence file: ${file}`);
    const raw = fs.readFileSync(file);
    let value;
    try {
      value = JSON.parse(raw.toString('utf8'));
    } catch {
      throw new Error(`invalid evidence JSON: ${file}`);
    }
    if (value.schemaVersion !== '1.0.0' || !value.runId || !value.runner
      || !Number.isInteger(value.total) || !Number.isInteger(value.failed)
      || !Array.isArray(value.failures) || typeof value.stdout !== 'string') {
      throw new Error(`invalid evidence contract: ${file}`);
    }
    return { file: path.resolve(file), raw, value, fileSha256: sha256(raw) };
  });
  const runIds = new Set(loaded.map(item => item.value.runId));
  if (runIds.size !== 1) throw new Error('evidence run-id mismatch');
  const descriptors = loaded.map(item => ({ name: path.basename(item.file), sha256: item.fileSha256 }));
  return {
    loaded,
    runId: loaded[0].value.runId,
    descriptors,
    evidenceSha256: sha256(Buffer.from(JSON.stringify(descriptors))),
  };
}

function buildPrompt(evidence) {
  return `You are GLM acting only as a read-only test failure classifier.
Do not call tools. Do not run commands. Do not edit files. Compare only the attached compact evidence projection.

RUN_ID: ${evidence.runId}
EVIDENCE_SHA256: ${evidence.evidenceSha256}

Return exactly one JSON object with this contract:
{
  "schemaVersion":"1.0.0",
  "runId":"${evidence.runId}",
  "evidenceSha256":"${evidence.evidenceSha256}",
  "model":"glm model identifier",
  "summary":"short evidence-led summary",
  "categories":["runner_incompatibility|stale_contract|real_regression|environmental|needs_codex_investigation"],
  "failures":[{"name":"exact TAP test name","category":"allowed category","evidence":"short verbatim evidence fragment","reason":"why the evidence supports this category"}],
  "recommendedCodexChecks":["specific read-only reproduction or file inspection"]
}

Return at most eight failure entries: one representative exact name per distinct test-file family. Do not enumerate all failures.
Every returned failure name must come from the attachment. Classify uncertainty as needs_codex_investigation. Never propose or perform code edits.`;
}

function diagnosticFor(stdout, number) {
  const lines = String(stdout || '').split(/\r?\n/);
  const start = lines.findIndex(line => new RegExp(`^not ok ${number}(?:\\s|$)`).test(line));
  if (start < 0) return '';
  let end = start + 1;
  while (end < lines.length && !/^(?:not )?ok \d+(?:\s|$)/.test(lines[end])) end += 1;
  return lines.slice(start, end).join('\n').slice(0, 500);
}

function buildFailureGroups(loaded) {
  const failures = new Map();
  for (const { value } of loaded) {
    for (const failure of value.failures) {
      const diagnostic = diagnosticFor(value.stdout, failure.number);
      const current = failures.get(failure.name) || {
        name: failure.name,
        number: failure.number,
        diagnostic,
        runners: [],
      };
      if (!current.diagnostic && diagnostic) current.diagnostic = diagnostic;
      current.runners.push(value.runner);
      failures.set(failure.name, current);
    }
  }
  const groups = new Map();
  for (const failure of failures.values()) {
    const testFile = failure.diagnostic.match(/\b(tests\/[^\s,'")]+\.bats)\b/)?.[1] || 'unknown';
    if (!groups.has(testFile)) groups.set(testFile, []);
    groups.get(testFile).push(failure);
  }
  return [...groups.entries()].map(([testFile, groupedFailures]) => ({
    testFile,
    failures: groupedFailures,
  }));
}

function writeEvidenceProjection(evidence, outputPath) {
  const projectionPath = `${outputPath}.input.json`;
  const projection = {
    schemaVersion: '1.0.0',
    runId: evidence.runId,
    evidenceSha256: evidence.evidenceSha256,
    evidenceFiles: evidence.descriptors,
    runners: evidence.loaded.map(({ value }) => ({
      runner: value.runner,
      total: value.total,
      failed: value.failed,
      exitCode: value.exitCode,
      stdoutSha256: value.stdoutSha256,
    })),
    failureGroups: buildFailureGroups(evidence.loaded),
  };
  fs.mkdirSync(path.dirname(projectionPath), { recursive: true });
  fs.writeFileSync(projectionPath, `${JSON.stringify(projection, null, 2)}\n`);
  return projectionPath;
}

function parseJsonObject(text) {
  const value = String(text || '').trim();
  try {
    return JSON.parse(value);
  } catch {}
  const fence = value.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) {
    try {
      return JSON.parse(fence[1].trim());
    } catch {}
  }
  const start = value.indexOf('{');
  const end = value.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      return JSON.parse(value.slice(start, end + 1));
    } catch {}
  }
  throw new Error('could not parse GLM JSON response');
}

function parseOuterResponse(stdout) {
  const value = String(stdout || '').trim();
  try {
    return JSON.parse(value);
  } catch {}
  const lines = value.split(/\r?\n/).filter(Boolean).reverse();
  for (const line of lines) {
    try {
      const parsed = JSON.parse(line);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch {}
  }
  throw new Error('could not parse ZCode JSON output');
}

function validateResult(result, evidence) {
  if (!result || result.schemaVersion !== '1.0.0') throw new Error('invalid GLM result schemaVersion');
  if (result.runId !== evidence.runId) throw new Error('GLM run-id mismatch');
  if (result.evidenceSha256 !== evidence.evidenceSha256) throw new Error('evidence hash mismatch');
  if (typeof result.model !== 'string' || !result.model.trim()) throw new Error('missing GLM model');
  if (typeof result.summary !== 'string' || !result.summary.trim()) throw new Error('missing GLM summary');
  if (!Array.isArray(result.categories) || result.categories.some(category => !CATEGORIES.has(category))) {
    throw new Error('invalid GLM category');
  }
  if (!Array.isArray(result.failures) || !Array.isArray(result.recommendedCodexChecks)) {
    throw new Error('invalid GLM failure list');
  }
  const knownFailureNames = new Set(evidence.loaded.flatMap(item => item.value.failures.map(failure => failure.name)));
  for (const failure of result.failures) {
    if (!failure || typeof failure.name !== 'string' || !failure.name.trim()
      || !CATEGORIES.has(failure.category) || typeof failure.evidence !== 'string'
      || !failure.evidence.trim() || typeof failure.reason !== 'string' || !failure.reason.trim()) {
      throw new Error('invalid GLM failure entry');
    }
    if (!knownFailureNames.has(failure.name)) throw new Error(`unknown failure name: ${failure.name}`);
  }
  return result;
}

function runTriage(args) {
  const evidence = loadEvidence(args.evidence);
  const zcode = resolveZcode(args.zcode);
  const projectionPath = writeEvidenceProjection(evidence, args.output);
  const zcodeArgs = [
    '--prompt', buildPrompt(evidence),
    '--attach', projectionPath,
    '--cwd', REPO_ROOT,
    '--mode', 'build',
    '--max-turns', '2',
    '--disallowed-tools', DISALLOWED_TOOLS,
    '--json',
    '--no-color',
  ];
  const isNodeScript = /\.(?:c?js|mjs)$/i.test(zcode);
  const command = isNodeScript ? process.execPath : zcode;
  const invoke = (invocationArgs) => spawnSync(
    command,
    isNodeScript ? [zcode, ...invocationArgs] : invocationArgs,
    {
      cwd: REPO_ROOT,
      encoding: 'utf8',
      shell: false,
      timeout: args.timeoutMs,
      maxBuffer: 20 * 1024 * 1024,
    },
  );
  let host = invoke(zcodeArgs);
  const hostMessage = host.stderr || host.stdout || '';
  if (host.status !== 0 && /Unknown option ['"]--max-turns['"]/.test(hostMessage)) {
    const maxTurnsIndex = zcodeArgs.indexOf('--max-turns');
    host = invoke(zcodeArgs.filter((_, index) => index !== maxTurnsIndex && index !== maxTurnsIndex + 1));
  }
  if (host.error?.code === 'ETIMEDOUT') throw new Error('ZCode triage timed out');
  if (host.status !== 0) throw new Error(`ZCode triage failed: ${(host.stderr || host.stdout || `exit ${host.status}`).trim()}`);
  const outer = parseOuterResponse(host.stdout);
  const result = validateResult(parseJsonObject(outer.response), evidence);
  const output = {
    ...result,
    evidenceFiles: evidence.descriptors,
    zcodeSessionId: outer.sessionId || '',
    zcodeTraceId: outer.traceId || '',
  };
  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, `${JSON.stringify(output, null, 2)}\n`);
  return output;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const result = runTriage(args);
  process.stdout.write(`${JSON.stringify({
    status: 'triaged',
    output: args.output,
    runId: result.runId,
    evidenceSha256: result.evidenceSha256,
    categories: result.categories,
    failures: result.failures.length,
  })}\n`);
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exit(2);
  }
}

module.exports = {
  buildPrompt,
  loadEvidence,
  parseArgs,
  parseJsonObject,
  resolveZcode,
  runTriage,
  sha256,
  validateResult,
};
