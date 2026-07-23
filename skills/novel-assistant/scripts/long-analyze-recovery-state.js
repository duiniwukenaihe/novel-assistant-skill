#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const options = parseArgs(args);

if (!options.outputDir) {
  fail('usage: long-analyze-recovery-state.js <deconstruct-output-dir> [--log path] [--expect-total N] [--write] [--json]');
}

const state = buildRecoveryState(path.resolve(options.outputDir), options);

if (options.write) {
  fs.writeFileSync(
    path.join(state.outputDir, '_recovery-state.json'),
    `${JSON.stringify(state, null, 2)}\n`,
    'utf8',
  );
}

if (options.json || !process.stdout.isTTY) {
  process.stdout.write(`${JSON.stringify(state, null, 2)}\n`);
} else {
  console.log(renderHuman(state));
}

function buildRecoveryState(outputDir, opts) {
  const progressPath = path.join(outputDir, '_progress.md');
  const progressText = readText(progressPath);
  const chaptersDir = path.join(outputDir, '章节');
  const summaryChapters = scanSummaryChapters(chaptersDir);
  const totalChapters = resolveTotalChapters(outputDir, progressText, summaryChapters, opts.expectTotal);
  const continuousComplete = findContinuousComplete(summaryChapters, totalChapters);
  const firstMissing = totalChapters > 0 && continuousComplete < totalChapters ? continuousComplete + 1 : null;
  const artifacts = scanArtifacts(outputDir);
  const lastError = classifyLogs(opts.logs);
  const stage = classifyStage(totalChapters, continuousComplete, artifacts);
  const action = recommendAction(stage, lastError);
  const percent = totalChapters > 0 ? round((summaryChapters.length / totalChapters) * 100, 2) : 0;

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    outputDir,
    exists: fs.existsSync(outputDir),
    totalChapters,
    summaryCount: summaryChapters.length,
    continuousComplete,
    firstMissing,
    percent,
    stage,
    action,
    lastError,
    artifacts,
    retryPolicy: {
      perChapterExecutionRetry: 1,
      perChapterQualityUpgradeRetry: 1,
      maxProcessRestartsBeforeCircuitBreak: 3,
      quotaRetry: 'do_not_loop; wait for quota reset or switch provider/model',
      sourceConflict: 'do_not_guess; ask user only after deterministic rebuild fails',
    },
    recommendedPrompt: buildRecommendedPrompt(outputDir, totalChapters, continuousComplete, firstMissing, action),
  };
}

function parseArgs(values) {
  const result = {
    outputDir: null,
    logs: [],
    expectTotal: 0,
    json: false,
    write: false,
  };
  for (let i = 0; i < values.length; i += 1) {
    const value = values[i];
    if (value === '--json') {
      result.json = true;
    } else if (value === '--write') {
      result.write = true;
    } else if (value === '--log') {
      const next = values[i + 1];
      if (next) result.logs.push(path.resolve(next));
      i += 1;
    } else if (value === '--expect-total') {
      const next = Number(values[i + 1]);
      if (Number.isFinite(next) && next > 0) result.expectTotal = Math.floor(next);
      i += 1;
    } else if (!value.startsWith('--') && !result.outputDir) {
      result.outputDir = value;
    }
  }
  return result;
}

function resolveTotalChapters(outputDir, progressText, summaryChapters, explicitTotal) {
  if (explicitTotal > 0) return explicitTotal;

  const progressTotal = matchNumber(progressText, /总章数[：:]\s*([0-9]+)/);
  if (progressTotal > 0) return progressTotal;

  const planTotal = readPlanTotal(path.join(outputDir, '批次计划.json'));
  if (planTotal > 0) return planTotal;

  const indexTotal = readJsonlMaxChapter(path.join(outputDir, '章节切片索引.jsonl'));
  if (indexTotal > 0) return indexTotal;

  const tocTotal = readTocTotal(outputDir);
  if (tocTotal > 0) return tocTotal;

  return summaryChapters.length ? Math.max(...summaryChapters) : 0;
}

function scanSummaryChapters(chaptersDir) {
  if (!fs.existsSync(chaptersDir)) return [];
  return fs.readdirSync(chaptersDir)
    .map(name => {
      const match = /^第0*([0-9]+)章_摘要\.md$/.exec(name);
      return match ? Number(match[1]) : 0;
    })
    .filter(number => number > 0)
    .sort((a, b) => a - b);
}

function findContinuousComplete(summaryChapters, totalChapters) {
  const seen = new Set(summaryChapters);
  const limit = totalChapters > 0 ? totalChapters : (summaryChapters.at(-1) || 0);
  let current = 0;
  for (let chapter = 1; chapter <= limit; chapter += 1) {
    if (!seen.has(chapter)) break;
    current = chapter;
  }
  return current;
}

function scanArtifacts(outputDir) {
  const required = [
    '概要.md',
    '快速预览.md',
    '剧情/故事线.md',
    '剧情/节奏.md',
    '剧情/情绪模块.md',
    '角色/角色关系.md',
    '拆文报告.md',
    '作者吸收笔记.md',
    '文风.md',
  ];
  return required.map(relativePath => ({
    path: relativePath,
    exists: fs.existsSync(path.join(outputDir, relativePath)),
  }));
}

function classifyStage(totalChapters, continuousComplete, artifacts) {
  if (totalChapters <= 0) return 'needs_plan_or_source';
  if (continuousComplete < totalChapters) return 'stage2_resume';
  if (!artifactExists(artifacts, '拆文报告.md')) return 'stage3_to_5_resume';
  if (!artifactExists(artifacts, '文风.md')) return 'stage6_resume';
  return 'complete';
}

function recommendAction(stage, lastError) {
  if (lastError.type === 'quota_exhausted') return 'external_blocked_quota';
  if (lastError.type === 'source_missing') return 'repair_source_or_ask';
  if (stage === 'needs_plan_or_source') return 'rebuild_plan';
  if (stage === 'stage2_resume') return 'resume_from_first_missing';
  if (stage === 'stage3_to_5_resume') return 'aggregate_and_report';
  if (stage === 'stage6_resume') return 'generate_style_profile';
  return 'none';
}

function classifyLogs(logPaths) {
  const text = logPaths
    .map(logPath => tailText(logPath, 300000))
    .filter(Boolean)
    .join('\n');
  if (!text) return { type: 'none', recoverable: true, detail: '' };
  const sample = text.slice(-4000);
  if (/429|Token Plan|quota|rate limit|usage limit|用量上限|配额/i.test(sample)) {
    return { type: 'quota_exhausted', recoverable: false, detail: compact(sample) };
  }
  if (/source .*not found|原文.*缺失|章节切片.*缺失|no such file/i.test(sample)) {
    return { type: 'source_missing', recoverable: false, detail: compact(sample) };
  }
  if (/timed out|timeout|operation timed out|stream stalled/i.test(sample)) {
    return { type: 'timeout', recoverable: true, detail: compact(sample) };
  }
  if (/API Error|overloaded|ECONNRESET|ETIMEDOUT|network/i.test(sample)) {
    return { type: 'api_error', recoverable: true, detail: compact(sample) };
  }
  if (/tool error|tool_use_error|permission denied|not permitted|command not found/i.test(sample)) {
    return { type: 'tool_error', recoverable: true, detail: compact(sample) };
  }
  return { type: 'none', recoverable: true, detail: '' };
}

function buildRecommendedPrompt(outputDir, totalChapters, continuousComplete, firstMissing, action) {
  const book = path.basename(outputDir);
  if (action === 'external_blocked_quota') {
    return `/novel-assistant 继续拆《${book}》。先读取 _recovery-state.json、_progress.md 和 章节/，若配额已恢复则从实际第一缺口继续；若仍是配额上限，保持断点并停止重试。`;
  }
  if (action === 'rebuild_plan') {
    return `/novel-assistant 继续拆《${book}》。先定位原文并重建章节切片索引/批次计划，再以实际落盘文件为准续跑。`;
  }
  if (firstMissing) {
    return `/novel-assistant 继续拆《${book}》。以当前输出目录为准：总章数 ${totalChapters || '未知'}，连续完成到第 ${continuousComplete} 章，第一缺口第 ${firstMissing} 章；不要重跑已完成摘要，继续 Stage 2 后续章节并在完成后进入聚合、设定关系、报告和文风。`;
  }
  return `/novel-assistant 继续拆《${book}》。章节摘要已覆盖 ${totalChapters || '未知'} 章，继续完成聚合、设定关系、拆文报告与文风，并写最终状态。`;
}

function readPlanTotal(planPath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(planPath, 'utf8'));
    return Number(parsed.totalChapters) || 0;
  } catch {
    return 0;
  }
}

function readJsonlMaxChapter(jsonlPath) {
  if (!fs.existsSync(jsonlPath)) return 0;
  let max = 0;
  for (const line of fs.readFileSync(jsonlPath, 'utf8').split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line);
      const chapterNo = Number(row.chapterNo);
      if (chapterNo > max) max = chapterNo;
    } catch {
      return max;
    }
  }
  return max;
}

function readTocTotal(outputDir) {
  const candidates = [
    path.join(outputDir, 'source', 'chapter-toc.tsv'),
    path.join(outputDir, '..', 'source', 'chapter-toc.tsv'),
    path.join(outputDir, '..', '..', 'source', 'chapter-toc.tsv'),
    path.join(outputDir, '..', '..', '..', 'source', 'chapter-toc.tsv'),
  ];
  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) continue;
    const rows = fs.readFileSync(candidate, 'utf8')
      .split(/\r?\n/)
      .filter(line => /^[0-9]+\t/.test(line));
    if (rows.length) return rows.length;
  }
  return 0;
}

function tailText(filePath, maxBytes) {
  try {
    const stat = fs.statSync(filePath);
    const start = Math.max(0, stat.size - maxBytes);
    const fd = fs.openSync(filePath, 'r');
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    fs.closeSync(fd);
    return buffer.toString('utf8');
  } catch {
    return '';
  }
}

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch {
    return '';
  }
}

function matchNumber(text, pattern) {
  const match = pattern.exec(text || '');
  return match ? Number(match[1]) || 0 : 0;
}

function artifactExists(artifacts, relativePath) {
  return artifacts.some(item => item.path === relativePath && item.exists);
}

function compact(text) {
  return String(text || '').replace(/\s+/g, ' ').trim().slice(-1000);
}

function round(number, places) {
  const factor = 10 ** places;
  return Math.round(number * factor) / factor;
}

function renderHuman(state) {
  return [
    `output: ${state.outputDir}`,
    `chapters: ${state.summaryCount}/${state.totalChapters || 'unknown'} (${state.percent}%)`,
    `continuous: ${state.continuousComplete}; first missing: ${state.firstMissing || '-'}`,
    `stage: ${state.stage}; action: ${state.action}; last error: ${state.lastError.type}`,
    `prompt: ${state.recommendedPrompt}`,
  ].join('\n');
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
