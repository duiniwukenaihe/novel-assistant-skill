#!/usr/bin/env node
// tool-task-decompose-plan.js
// Converts high-risk tool payloads into a scripted, verifiable execution plan.

const fs = require('fs');
const path = require('path');
const { detect } = require('./tool-call-degradation-check.js');

function usage() {
  console.error('Usage: tool-task-decompose-plan.js --kind bash --payload-file path [--project-root dir] [--intent text] [--write] [--json]');
}

function parseArgs(argv) {
  const args = { kind: 'bash', payloadFile: '', projectRoot: '', intent: '', write: false, json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--kind') args.kind = argv[++i] || '';
    else if (arg === '--payload-file') args.payloadFile = argv[++i] || '';
    else if (arg === '--project-root') args.projectRoot = argv[++i] || '';
    else if (arg === '--intent') args.intent = argv[++i] || '';
    else if (arg === '--write') args.write = true;
    else if (arg === '--json') args.json = true;
    else if (arg === '--help' || arg === '-h') {
      usage();
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${arg}`);
      usage();
      process.exit(2);
    }
  }
  return args;
}

function nowStamp() {
  return new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', '_');
}

function inferTaskShape(payload) {
  const text = String(payload || '');
  const knownTask = inferKnownTask(text);
  if (knownTask) return knownTask.taskShape;
  if (/章节|chapter|正文|第\d+章/.test(text)) return 'chapter_batch';
  if (/审查|review|rubric|finding|报告/.test(text)) return 'review_batch';
  if (/迁移|migrate|volume|卷/.test(text)) return 'migration';
  if (/拆文|analyze|summary|摘要/.test(text)) return 'deconstruction';
  return 'general_tool_task';
}

function buildPlan({ kind, payload, intent, projectRoot }) {
  const guard = detect(payload, kind, { strict: true });
  const combined = `${intent}\n${payload}`;
  const knownTask = inferKnownTask(combined);
  const taskShape = knownTask?.taskShape || inferTaskShape(combined);
  const status = guard.status === 'needs_tool_task_decomposition' ? 'planned' : guard.ok ? 'clean' : 'blocked';
  const scriptTarget = knownTask?.scriptTarget || defaultScriptTarget(taskShape);
  const safeCommands = knownTask ? knownTask.safeCommands : [];
  const nextCommandPattern = safeCommands[0]?.command || 'node scripts/<task-script>.js <project-root> --json';

  return {
    status,
    workflowStatus: guard.status,
    taskContinues: guard.status === 'needs_tool_task_decomposition',
    kind,
    taskShape,
    recognizedTask: knownTask?.id || '',
    intent: intent || '从 payload 提取意图后执行',
    projectRoot: projectRoot || '',
    guard,
    safeCommands,
    phases: [
      {
        id: 'read',
        goal: '读取当前 workflow 状态、目标目录和输入文件清单',
        output: '输入文件列表、目标路径、风险范围',
        verify: '文件存在且路径来自文件系统，不来自聊天转录',
      },
      {
        id: 'plan',
        goal: '把原高风险命令拆成最小可执行动作',
        output: 'read/write/verify 步骤表',
        verify: '每步只有一个职责，能单独失败和续跑',
      },
      {
        id: 'script',
        goal: '复用或创建脚本承载复杂逻辑',
        output: scriptTarget,
        verify: safeCommands.length
          ? '优先使用 safeCommands 中的一行命令；执行前仍用 tool-call-degradation-check.js --strict 复检'
          : '脚本文件落盘后通过静态检查或 --help/--json smoke test',
      },
      {
        id: 'execute',
        goal: '用一行命令调用脚本',
        output: '脚本 JSON 或短日志',
        verify: '先用 tool-call-degradation-check.js --strict 检查命令，再执行',
      },
      {
        id: 'verify',
        goal: '验证产物真实存在且未污染',
        output: '验证结果、失败恢复点、下一步',
        verify: '读取目标文件、运行污染门禁和必要 schema/check 脚本',
      },
    ],
    nextCommandPattern,
  };
}

function defaultScriptTarget(taskShape) {
  if (taskShape === 'review_batch') return 'scripts/review-state-ledger.js 或新建 scripts/tmp-review-batch.js';
  if (taskShape === 'migration') return 'scripts/story-project-migrate.js 或专用迁移脚本';
  if (taskShape === 'deconstruction') return 'scripts/long-analyze-plan.js / scripts/long-analyze-recovery-state.js';
  if (taskShape === 'chapter_batch') return 'scripts/story-progress-status.js / scripts/chapter-draft-resolve.js / 章节相关专用脚本';
  return '已有 scripts/* 或新建小脚本';
}

function inferKnownTask(text) {
  const payload = String(text || '');
  const proseFile = extractQuotedPath(payload, /(?:readFileSync|Path\(|open\(|cat|wc\s+-m)\s*\(?['"]([^'"]+\.(?:md|txt))['"]/)
    || extractQuotedPath(payload, /['"]([^'"]*正文[^'"]*第[^'"]+章[^'"]+\.(?:md|txt))['"]/);

  if (
    /\b(node|python3?|py)\s+(-e|-c)\b/.test(payload)
    && /(字数|cjk_chars|readFileSync|split\(|本章完|正文|第[^\\n]+章)/.test(payload)
  ) {
    return {
      id: 'prose_text_stats',
      taskShape: 'prose_stats',
      scriptTarget: 'scripts/chapter-text-stats.js',
      safeCommands: [{
        id: 'chapter-text-stats',
        command: proseFile
          ? `node scripts/chapter-text-stats.js ${shellQuote(proseFile)} --json`
          : 'node scripts/chapter-text-stats.js <正文文件路径> --json',
        verifies: '统计正文 cjk_chars/all_chars/nonspace_chars/em_dash/ellipsis；不依赖标题 split 或本章完 split',
      }],
    };
  }

  if (
    /(P\[0-9\]\+|P\\\[0-9\\\]|基调|主题标签|第\$\{?n\}?章_摘要|章节摘要|_摘要\.md)/.test(payload)
    && /(grep|for\s+\w+\s+in|while|awk|sed)/.test(payload)
  ) {
    const chaptersDir = extractDirectoryAfterCd(payload) || '<章节摘要目录>';
    const chapters = extractChapterRange(payload) || '<章节范围>';
    return {
      id: 'stage2_summary_quality',
      taskShape: 'deconstruction_summary_quality',
      scriptTarget: 'scripts/stage2-summary-quality-check.js',
      safeCommands: [{
        id: 'stage2-summary-quality-check',
        command: `node scripts/stage2-summary-quality-check.js ${shellQuote(chaptersDir)} --chapters ${shellQuote(chapters)} --json`,
        verifies: '检查每章摘要 P情节点、基调、主题标签数量和枚举合法性',
      }],
    };
  }

  if (
    /(现在第几卷|第几章|写到第几章|章节总数|currentChapter|globalDraftOrder|find\s+.*正文)/.test(payload)
    && /(正文|章节|chapter|第.+卷)/.test(payload)
  ) {
    return {
      id: 'progress_status',
      taskShape: 'progress_status',
      scriptTarget: 'scripts/story-progress-status.js',
      safeCommands: [{
        id: 'story-progress-status',
        command: 'node scripts/story-progress-status.js <book-project-dir> --json',
        verifies: '从真实正文、章节资产和目录结构回答当前卷/章，避免聊天记忆污染',
      }],
    };
  }

  const volumeCount = inferChapterVolumeCount(payload);
  if (volumeCount) {
    return {
      id: 'chapter_volume_count',
      taskShape: 'chapter_volume_count',
      scriptTarget: 'scripts/chapter-volume-count.js',
      safeCommands: [{
        id: 'chapter-volume-count',
        command: `node scripts/chapter-volume-count.js --project-root ${shellQuote(volumeCount.projectRoot)} --volumes ${shellQuote(volumeCount.volumes.join(','))} --exclude ${shellQuote(volumeCount.exclude)} --json`,
        verifies: '按卷统计正文目录中的章节数量；不使用 cd、for、ls、grep、wc、tr 或 shell 展开',
      }],
    };
  }

  const safeSearch = inferSafeTextSearch(payload);
  if (safeSearch) {
    return {
      id: 'safe_text_search',
      taskShape: 'text_search',
      scriptTarget: 'scripts/safe-text-search.js',
      safeCommands: [{
        id: 'safe-text-search',
        command: `node scripts/safe-text-search.js --root ${shellQuote(safeSearch.root)} --query ${shellQuote(safeSearch.query)} --glob ${shellQuote(safeSearch.glob)} --mode ${shellQuote(safeSearch.mode)} --limit ${safeSearch.limit} --json`,
        verifies: '用绝对路径执行文本搜索；不使用 cd、重定向、管道或相对 glob，减少 Claude Code 授权弹窗',
      }],
    };
  }

  return null;
}

function inferSafeTextSearch(payload) {
  const text = String(payload || '');
  if (!/\bcd\s+/.test(text) || !/\b(grep|rg)\b/.test(text)) return null;
  if (!/(?:^|\s)(?:[0-9]?>|&>)|[|]/.test(text)) return null;

  const cdDir = extractDirectoryAfterCd(text);
  const searchInvocation = extractSearchInvocation(text);
  const query = searchInvocation.query;
  const targetPattern = searchInvocation.targetPattern;
  if (!cdDir || !query || !targetPattern) return null;

  const targetDir = path.dirname(targetPattern);
  const glob = path.basename(targetPattern) || '*.md';
  const root = targetDir && targetDir !== '.'
    ? path.join(cdDir, targetDir)
    : cdDir;
  const limitMatch = text.match(/\|\s*head\s+-(\d+)/);
  const limit = limitMatch ? Math.max(1, Number(limitMatch[1]) || 20) : 50;
  const mode = /\b(grep|rg)\s+-[A-Za-z]*l[A-Za-z]*/.test(text) ? 'files' : 'lines';
  return { root, query, glob, mode, limit };
}

function inferChapterVolumeCount(payload) {
  const text = String(payload || '');
  const looksLikeVolumeCount =
    /\bfor\s+\w+\s+in\s+第.+卷[\s\S]*\bdone\b/.test(text)
    && /正文\/\$?\w+|正文\/第.+卷|章节|wc\s+-l|ls\s+正文/.test(text)
    && /\b(ls|find)\b[\s\S]*\b(wc|grep|tr)\b/.test(text);
  if (!looksLikeVolumeCount) return null;
  const projectRoot = extractDirectoryAfterCd(text) || '<book-project-dir>';
  const volumes = extractForLoopVolumes(text);
  const exclude = extractGrepVExclude(text) || '_原稿_';
  return {
    projectRoot,
    volumes: volumes.length ? volumes : ['<卷名列表>'],
    exclude,
  };
}

function extractForLoopVolumes(payload) {
  const match = String(payload || '').match(/\bfor\s+\w+\s+in\s+([^;\n]+?)\s*;\s*do/);
  if (!match) return [];
  return match[1]
    .split(/\s+/)
    .map((item) => item.trim().replace(/^["']|["']$/g, ''))
    .filter((item) => /^第.+卷$/.test(item));
}

function extractGrepVExclude(payload) {
  const match = String(payload || '').match(/\bgrep\s+-v\s+["']([^"']+)["']/);
  return match ? match[1] : '';
}

function extractQuotedPath(payload, pattern) {
  const match = String(payload || '').match(pattern);
  return match ? match[1] : '';
}

function extractDirectoryAfterCd(payload) {
  const text = String(payload || '');
  const quoted = text.match(/\bcd\s+["']([^"']+)["']/);
  if (quoted) return quoted[1];
  const bare = text.match(/\bcd\s+([^;&|\n]+?)\s*(?:&&|;|$)/);
  return bare ? bare[1].trim() : '';
}

function extractSearchQuery(payload) {
  return extractSearchInvocation(payload).query;
}

function extractSearchTargetPattern(payload, query) {
  const invocation = extractSearchInvocation(payload);
  return invocation.query === query ? invocation.targetPattern : '';
}

function extractSearchInvocation(payload) {
  const text = String(payload || '');
  const match = text.match(/\b(?:grep|rg)\b((?:\s+-[A-Za-z0-9]+)*)\s+(["'])([^"']+)\2\s+([^\s|;&]+)/);
  if (!match) return { query: '', targetPattern: '' };
  return {
    query: match[3],
    targetPattern: match[4],
  };
}

function extractChapterRange(payload) {
  const text = String(payload || '');
  const forList = text.match(/\bfor\s+\w+\s+in\s+([0-9 ,]+)\s*;/);
  if (forList) {
    const nums = forList[1]
      .split(/[,\s]+/)
      .map(Number)
      .filter(n => Number.isInteger(n) && n > 0);
    if (nums.length) return compressNumbers(nums);
  }
  const explicit = text.match(/([0-9]+)\s*[-~到至]\s*([0-9]+)\s*章?/);
  if (explicit) return `${explicit[1]}-${explicit[2]}`;
  return '';
}

function compressNumbers(nums) {
  const unique = Array.from(new Set(nums)).sort((a, b) => a - b);
  if (unique.length >= 2 && unique.every((n, i) => i === 0 || n === unique[i - 1] + 1)) {
    return `${unique[0]}-${unique.at(-1)}`;
  }
  return unique.join(',');
}

function shellQuote(value) {
  const text = String(value || '');
  if (/^<.+>$/.test(text)) return text;
  return `'${text.replace(/'/g, `'\\''`)}'`;
}

function writePlan(projectRoot, plan) {
  const base = projectRoot
    ? path.join(projectRoot, '追踪/workflow/tool-task-plan')
    : path.join(process.cwd(), '.novel-assistant-recovery/tool-task-plan');
  fs.mkdirSync(base, { recursive: true });
  const stem = `${nowStamp()}_${plan.taskShape}`;
  const jsonPath = path.join(base, `${stem}.json`);
  const mdPath = path.join(base, `${stem}.md`);
  fs.writeFileSync(jsonPath, `${JSON.stringify(plan, null, 2)}\n`, 'utf8');
  fs.writeFileSync(mdPath, renderMarkdown(plan), 'utf8');
  return { jsonPath, mdPath };
}

function renderMarkdown(plan) {
  const lines = [
    `# 工具任务分拆计划`,
    '',
    `- workflowStatus: ${plan.workflowStatus}`,
    `- taskShape: ${plan.taskShape}`,
    `- intent: ${plan.intent}`,
    '',
    '## Phases',
    ...plan.phases.map((phase, index) => `${index + 1}. ${phase.id}: ${phase.goal}\n   - output: ${phase.output}\n   - verify: ${phase.verify}`),
    '',
    ...(plan.safeCommands?.length ? [
      '## Safe Commands',
      ...plan.safeCommands.map(command => `- ${command.id}: \`${command.command}\`\n  - verifies: ${command.verifies}`),
      '',
    ] : []),
    `nextCommandPattern: ${plan.nextCommandPattern}`,
  ];
  return `${lines.join('\n')}\n`;
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.payloadFile) {
    usage();
    process.exit(2);
  }
  const payload = fs.readFileSync(args.payloadFile, 'utf8');
  const plan = buildPlan({ kind: args.kind, payload, intent: args.intent, projectRoot: args.projectRoot });
  if (args.write) {
    plan.written = writePlan(args.projectRoot, plan);
  }
  process.stdout.write(args.json ? `${JSON.stringify(plan, null, 2)}\n` : renderMarkdown(plan));
  process.exit(plan.status === 'blocked' ? 1 : 0);
}

if (require.main === module) main();

module.exports = { buildPlan };
