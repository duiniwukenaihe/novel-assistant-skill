#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { buildEvidenceMap, parseRange } = require('./lib/review-evidence');
const { buildSourceIdentity } = require('./lib/review-batch-planner');
const { classifyWorkflowApply } = require('./lib/workflow-apply-result');
const { resolveTaskAuthority } = require('./lib/workflow-task-authority');

const PROTOCOL_VERSION = '2.0.0';

const args = parseArgs(process.argv.slice(2));
if (!args.projectRoot || !args.range) fail('usage: review-batch-evidence-scan.js --project-root <book> --range <start-end> [--workflow-id <id> --write --apply-result] [--query text] [--json]');

const projectRoot = path.resolve(args.projectRoot);
const range = parseRange(args.range);
const evidence = buildEvidenceMap(projectRoot, range, {
  scriptDir: __dirname,
  skipChapterChecks: true,
  skipPriorReports: true,
});

if (evidence.status.startsWith('blocked_')) finish(compactResult(evidence, [], [], args.queries), 2);

const files = evidence.chapters.map(chapter => path.join(projectRoot, ...chapter.path.split('/')));
const findings = runBatchChecks(files, evidence.chapters);
const queryResults = scanQueries(projectRoot, evidence.chapters, args.queries);
const result = compactResult(evidence, findings, queryResults, args.queries);

if (args.write) {
  const target = path.join(projectRoot, 'evidence', `batch-scan-${pad(range.start)}-${pad(range.end)}.json`);
  atomicWriteJson(target, { ...result, generatedAt: new Date().toISOString() });
  result.output = path.relative(projectRoot, target).split(path.sep).join('/');
}

if (args.workflowId) {
  const workflow = buildWorkflowReceipt(projectRoot, range, result, args);
  if (workflow.status !== 'ok') finish(workflow, 2);
  if (!args.write) {
    result.workflow_receipt_preview = workflow.packet;
    finish(result, 0);
  }
  atomicWriteJson(workflow.packetFile, workflow.packet);
  result.result_packet_path = workflow.packet.result_packet_path;
  result.packet = workflow.packet;
  if (args.applyResult) {
    const outcome = applyWorkflowReceipt(projectRoot, workflow.packetFile);
    result.apply_result = outcome.result;
    result.workflow_status = outcome.workflowStatus;
    Object.assign(result, outcome.presentation);
    result.status = outcome.applied ? 'applied' : 'apply_blocked';
    finish(result, result.status === 'applied' ? 0 : 2);
  }
}

finish(result, 0);

function parseArgs(argv) {
  const out = { projectRoot: '', workflowId: '', range: '', queries: [], write: false, applyResult: false, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') out.projectRoot = argv[++i] || '';
    else if (arg === '--workflow-id') out.workflowId = argv[++i] || '';
    else if (arg === '--range') out.range = argv[++i] || '';
    else if (arg === '--query') out.queries.push(argv[++i] || '');
    else if (arg === '--write') out.write = true;
    else if (arg === '--apply-result') out.applyResult = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') {
      process.stdout.write('Usage: review-batch-evidence-scan.js --project-root <book> --range <start-end> [--workflow-id <id> --write --apply-result] [--query text] [--json]\n');
      process.exit(0);
    } else fail(`unknown argument: ${arg}`);
  }
  out.queries = Array.from(new Set(out.queries.map(value => value.trim()).filter(Boolean))).slice(0, 20);
  if (out.applyResult && (!out.write || !out.workflowId)) fail('--apply-result requires --workflow-id and --write');
  return out;
}

function buildWorkflowReceipt(root, currentRange, scan, options) {
  const authority = resolveTaskAuthority(root, options.workflowId);
  const task = authority.status === 'ok' ? authority.task : null;
  if (!task) {
    return { schemaVersion: '1.0.0', status: 'blocked_task_authority_missing', findings: [{ field: 'task.json', message: '未找到请求工作流的持久任务快照，不能生成可应用回执。' }] };
  }
  const execution = task.stage_execution || {};
  const expectedRange = String(execution.batch_scope || '');
  if (task.workflow_id !== options.workflowId || task.workflow_type !== 'review_repair' || task.current_stage !== 'evidence_scan' || execution.status !== 'running') {
    return { schemaVersion: '1.0.0', status: 'blocked_review_workflow_execution_mismatch', findings: [{ field: 'workflow', message: '当前不是可执行的审阅证据扫描阶段。' }] };
  }
  const expectedNumericRange = parseRange(expectedRange);
  if (!expectedNumericRange || expectedNumericRange.start !== currentRange.start || expectedNumericRange.end !== currentRange.end || String(execution.batch_id || '') === '') {
    return { schemaVersion: '1.0.0', status: 'blocked_review_workflow_scope_mismatch', findings: [{ field: 'range', message: '扫描范围必须与当前工作流批次完全一致。', expected: expectedRange, requested: `${currentRange.start}-${currentRange.end}` }] };
  }
  const packetPath = String(execution.expected_result_packet || '');
  const packetFile = safeProjectPath(root, packetPath);
  if (!packetFile) {
    return { schemaVersion: '1.0.0', status: 'blocked_review_workflow_packet_path_unsafe', findings: [{ field: 'expected_result_packet', message: '当前回执路径不安全。' }] };
  }
  const packet = {
    schemaVersion: '1.0.0',
    protocolVersion: PROTOCOL_VERSION,
    result_contract_version: 2,
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: 'evidence_scan',
    step_id: 'evidence_scan',
    step_status: 'completed',
    batch_id: String(execution.batch_id),
    batch_scope: expectedRange,
    result_packet_path: packetPath,
    sourceDigest: scan.sourceDigest,
    fullRangeCoverage: scan.fullRangeCoverage,
    outputs: {
      evidence_artifact: scan.output || '',
      summary: scan.summary,
      chapter_stats: scan.chapterStats,
      finding_counts: scan.findingCounts,
      hotspots: scan.hotspots,
    },
    changed_files: [],
    evidence: [{ type: 'batch_evidence_scan', path: scan.output || '', source_digest: scan.sourceDigest, full_range_coverage: scan.fullRangeCoverage }],
    verification_result: scan.status === 'ok' && scan.fullRangeCoverage.complete ? 'pass' : 'blocked',
    checkpoint_state: { batch_id: String(execution.batch_id), batch_scope: expectedRange, evidence_artifact: scan.output || '' },
    output_health_result: { status: 'pass', source: 'deterministic_review_batch_scanner' },
    next_recommendation: '继续下一审阅批次或进入综合分类。',
  };
  return { status: 'ok', packetFile, packet };
}

function safeProjectPath(root, relativePath) {
  if (!relativePath || path.isAbsolute(relativePath)) return '';
  const resolved = path.resolve(root, relativePath);
  return resolved === root || resolved.startsWith(`${root}${path.sep}`) ? resolved : '';
}

function applyWorkflowReceipt(root, relativePacketPath) {
  const command = spawnSync(process.execPath, [path.join(__dirname, 'workflow-state-machine.js'), 'apply-result', '--project-root', root, '--result', relativePacketPath, '--json'], {
    encoding: 'utf8', shell: false, maxBuffer: 8 * 1024 * 1024,
  });
  const outcome = classifyWorkflowApply(command);
  if (outcome.workflowStatus !== 'workflow_apply_process_failed') return outcome;
  return {
    ...outcome,
    result: { status: 'blocked_review_receipt_apply_failed', stderr: String(command.stderr || '').slice(0, 1000) },
    workflowStatus: 'blocked_review_receipt_apply_failed',
  };
}

function runBatchChecks(files, chapters) {
  if (!files.length) return [];
  const byAbsolute = new Map(chapters.map((chapter, index) => [path.resolve(files[index]), chapter]));
  const findings = [];
  const punctuation = runNode('normalize-punctuation.js', ['--check', ...files]);
  for (const line of String(punctuation.stdout || '').split(/\r?\n/)) {
    const match = line.match(/^(.*):(\d+):(\d+):\s*([^:]+):\s*(.*)$/);
    if (!match) continue;
    const chapter = byAbsolute.get(path.resolve(match[1]));
    if (!chapter) continue;
    findings.push(toFinding(chapter, 'punctuation', 'advisory', match[4], Number(match[2]), Number(match[3])));
  }
  for (const [script, detector] of [['check-ai-patterns.js', 'ai-pattern'], ['check-degeneration.js', 'degeneration']]) {
    const checked = runNode(script, ['--json', '--fail-on=all', ...files]);
    let parsed = {};
    try { parsed = JSON.parse(checked.stdout || '{}'); } catch (_) { parsed = {}; }
    for (const item of Array.isArray(parsed.findings) ? parsed.findings : []) {
      const chapter = byAbsolute.get(path.resolve(item.file || ''));
      if (!chapter) continue;
      findings.push(toFinding(chapter, detector, item.severity === 'blocking' ? 'blocking' : 'advisory', item.type, item.line, item.column));
    }
  }
  return findings.sort((a, b) => a.globalDraftOrder - b.globalDraftOrder || a.line - b.line || a.detector.localeCompare(b.detector));
}

function runNode(script, scriptArgs) {
  return spawnSync(process.execPath, [path.join(__dirname, script), ...scriptArgs], {
    encoding: 'utf8',
    shell: false,
    maxBuffer: 32 * 1024 * 1024,
  });
}

function toFinding(chapter, detector, severity, type, line, column) {
  return {
    globalDraftOrder: chapter.globalDraftOrder,
    path: chapter.path,
    detector,
    severity,
    type: String(type || ''),
    line: Number(line) || 0,
    column: Number(column) || 0,
  };
}

function scanQueries(root, chapters, queries) {
  return queries.map((query) => {
    let count = 0;
    let chapterCount = 0;
    const hits = [];
    for (const chapter of chapters) {
      const text = fs.readFileSync(path.join(root, ...chapter.path.split('/')), 'utf8');
      const occurrences = literalCount(text, query);
      if (!occurrences) continue;
      count += occurrences;
      chapterCount += 1;
      if (hits.length < 10) hits.push({ globalDraftOrder: chapter.globalDraftOrder, path: chapter.path, count: occurrences });
    }
    return { query, count, chapterCount, hits };
  });
}

function literalCount(text, query) {
  let count = 0;
  let offset = 0;
  while (query && (offset = text.indexOf(query, offset)) >= 0) {
    count += 1;
    offset += query.length;
  }
  return count;
}

function compactResult(evidence, findings, queries) {
  const chars = evidence.chapters.map(chapter => chapter.chars);
  const byKind = {};
  const byChapter = new Map();
  for (const finding of findings) {
    const key = `${finding.detector}:${finding.severity}:${finding.type}`;
    byKind[key] = (byKind[key] || 0) + 1;
    const item = byChapter.get(finding.globalDraftOrder) || { globalDraftOrder: finding.globalDraftOrder, path: finding.path, blocking: 0, advisory: 0 };
    item[finding.severity] += 1;
    byChapter.set(finding.globalDraftOrder, item);
  }
  const hotspots = Array.from(byChapter.values())
    .sort((a, b) => b.blocking - a.blocking || b.advisory - a.advisory || a.globalDraftOrder - b.globalDraftOrder)
    .slice(0, 12);
  const blockerCounts = {};
  for (const finding of evidence.staticFindings || []) {
    if (finding.severity !== 'blocking') continue;
    blockerCounts[finding.type] = (blockerCounts[finding.type] || 0) + 1;
  }
  const detectorBlocking = findings.filter(item => item.severity === 'blocking').length;
  const blockingFindings = (evidence.staticFindings || []).filter(item => item.severity === 'blocking');
  const coveredOrders = new Set((evidence.chapters || []).map(chapter => Number(chapter.globalDraftOrder)));
  const requestedChapters = evidence.range.end - evidence.range.start + 1;
  const completeCoverage = evidence.status === 'ok'
    && coveredOrders.size === requestedChapters
    && Array.from({ length: requestedChapters }, (_, index) => evidence.range.start + index).every(order => coveredOrders.has(order));
  return {
    schemaVersion: '1.0.0',
    protocolVersion: PROTOCOL_VERSION,
    sourceDigest: buildSourceIdentity(evidence).digest,
    fullRangeCoverage: {
      start: evidence.range.start,
      end: evidence.range.end,
      requestedChapters,
      coveredChapters: coveredOrders.size,
      complete: completeCoverage,
    },
    status: evidence.status,
    range: evidence.range,
    summary: {
      ...evidence.summary,
      blockingSignals: (evidence.summary.blockingSignals || 0) + detectorBlocking,
      advisorySignals: findings.filter(item => item.severity === 'advisory').length,
    },
    chapterStats: {
      totalChars: chars.reduce((sum, value) => sum + value, 0),
      minChars: chars.length ? Math.min(...chars) : 0,
      maxChars: chars.length ? Math.max(...chars) : 0,
      averageChars: chars.length ? Math.round(chars.reduce((sum, value) => sum + value, 0) / chars.length) : 0,
    },
    findingCounts: byKind,
    blockerCounts,
    ...(evidence.status.startsWith('blocked_') ? {
      blockedEvidence: {
        total: blockingFindings.length,
        samples: blockingFindings.slice(0, 5).map(blockerSample),
        recovery: [
          '核对追踪/schema/chapters.jsonl 与追踪/章节资产.jsonl，确保范围内每章只指向一个当前正文 draftPath。',
          '将备份稿移出正文目录或使用 _原稿_ 明确标记，修正后按同一 --range 重新扫描。',
        ],
      },
    } : {}),
    hotspots,
    queries,
  };
}

function blockerSample(finding) {
  return {
    type: finding.type,
    globalDraftOrder: finding.globalDraftOrder,
    path: finding.path,
    ...(Array.isArray(finding.observedPaths) ? { observedPaths: finding.observedPaths.slice(0, 3) } : {}),
    ...(Array.isArray(finding.observedGlobalDraftOrders)
      ? { observedGlobalDraftOrders: finding.observedGlobalDraftOrders.slice(0, 5) } : {}),
  };
}

function atomicWriteJson(target, value) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const temporary = `${target}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  fs.renameSync(temporary, target);
}

function pad(value) {
  return String(value).padStart(3, '0');
}

function finish(result, code) {
  if (args.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else process.stdout.write(`批次证据扫描：${result.status}，${result.summary.mappedChapters}/${result.summary.requestedChapters} 章，阻断 ${result.summary.blockingSignals || 0}，提醒 ${result.summary.advisorySignals || 0}\n`);
  process.exit(code);
}

function fail(message) {
  console.error(message);
  process.exit(2);
}
