#!/usr/bin/env node
// tool-call-degradation-check.js
// Detects contaminated tool payloads before Bash/Agent/Write/Edit execution.

const fs = require('fs');

function usage() {
  console.error('Usage: tool-call-degradation-check.js [--kind bash|agent|write|edit] [--strict] [--json] [--file path]');
}

function parseArgs(argv) {
  const args = { kind: 'tool', json: false, file: null, strict: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') {
      args.json = true;
    } else if (arg === '--strict') {
      args.strict = true;
    } else if (arg === '--kind') {
      args.kind = argv[++i] || '';
    } else if (arg === '--file') {
      args.file = argv[++i] || '';
    } else if (arg === '--help' || arg === '-h') {
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

function readPayload(file) {
  if (file) return fs.readFileSync(file, 'utf8');
  return fs.readFileSync(0, 'utf8');
}

function lineHits(payload, rules) {
  const lines = payload.split(/\r?\n/);
  const findings = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    for (const rule of rules) {
      if (rule.pattern.test(line)) {
        findings.push({
          type: rule.type,
          line: i + 1,
          phrase: rule.label,
          sample: line.slice(0, 160),
          message: rule.message,
        });
        break;
      }
    }
  }
  return findings;
}

function detect(payload, kind, options = {}) {
  const normalizedKind = String(kind || 'tool').toLowerCase();
  const commonRules = [
    {
      type: 'diff-hunk',
      label: '@@',
      pattern: /^\s*@@\s/,
      message: '工具参数中混入 diff hunk。',
    },
    {
      type: 'diff-file-marker',
      label: '---/+++',
      pattern: /^\s*(---|\+\+\+)\s+(a\/|b\/|\/|\S)/,
      message: '工具参数中混入 diff 文件标记。',
    },
    {
      type: 'patch-added-yaml',
      label: '+key: value',
      pattern: /^\s*(\d+\s+)?\+\s*[A-Za-z_][A-Za-z0-9_-]*\s*:/,
      message: '工具参数中混入补丁新增行。',
    },
    {
      type: 'patch-removed-yaml',
      label: '-key: value',
      pattern: /^\s*(\d+\s+)?-\s*[A-Za-z_][A-Za-z0-9_-]*\s*:/,
      message: '工具参数中混入补丁删除行。',
    },
    {
      type: 'claude-tool-output',
      label: '⎿',
      pattern: /⎿/,
      message: '工具参数中混入 Claude 工具输出块。',
    },
    {
      type: 'thinking-log',
      label: 'Thought for',
      pattern: /\b(Thought|Thinking|Brewed|Crunched|Churned|Sautéed|Actualizing|Transfiguring)\s+for\b/,
      message: '工具参数中混入模型执行日志。',
    },
    {
      type: 'edit-summary',
      label: 'Added/removed lines',
      pattern: /\bAdded\s+\d+\s+lines?,\s+removed\s+\d+\s+lines?\b/,
      message: '工具参数中混入 Edit/Write 汇总。',
    },
    {
      type: 'markdown-table',
      label: 'markdown table row',
      pattern: /^\s*\|[^|]+(\|[^|]+)+\|\s*$/,
      message: '工具参数中混入 Markdown 表格输出。',
    },
    {
      type: 'tool-command-label',
      label: 'Bash command',
      pattern: /^\s*(Bash command|Update\(|Write\(|Read\s+\d+\s+files?|Listing\s+\d+\s+directories)/,
      message: '工具参数中混入工具调用转录文本。',
    },
  ];

  const findings = lineHits(payload, commonRules);

  if (normalizedKind === 'bash') {
    const dangerousTranscript = payload.match(/\n\s*(\d+\s+[+-]?\s*[A-Za-z_][A-Za-z0-9_-]*\s*:|[+-]\s*[A-Za-z_][A-Za-z0-9_-]*\s*:)/);
    if (dangerousTranscript) {
      findings.push({
        type: 'bash-transcript-contamination',
        line: payload.slice(0, dangerousTranscript.index).split(/\r?\n/).length,
        phrase: dangerousTranscript[0].trim().slice(0, 80),
        sample: dangerousTranscript[0].trim().slice(0, 160),
        message: 'Bash 命令中混入文件内容、diff 或工具输出转录。',
      });
    }
    if (options.strict) {
      findings.push(...detectHighRiskBash(payload));
    }
  }

  const hasContamination = findings.some((finding) => !String(finding.type).startsWith('high-risk-'));
  const status = findings.length === 0
    ? 'ok'
    : hasContamination
      ? 'blocked_tool_command_contaminated'
      : 'needs_tool_task_decomposition';

  const result = {
    ok: findings.length === 0,
    status,
    kind: normalizedKind,
    findings,
  };
  result.recovery = buildRecovery(payload, normalizedKind, findings, status);
  return result;
}

function detectHighRiskBash(payload) {
  const findings = [];
  const lines = payload.split(/\r?\n/);
  const nonEmpty = lines.filter((line) => line.trim()).length;
  const firstHitLine = (pattern) => {
    const index = lines.findIndex((line) => pattern.test(line));
    return index < 0 ? 1 : index + 1;
  };
  const add = (type, pattern, message, phrase) => {
    const line = firstHitLine(pattern);
    findings.push({
      type,
      line,
      phrase,
      sample: (lines[line - 1] || '').slice(0, 160),
      message,
    });
  };

  if (/\b(python3?|node|ruby|perl)\s+(-c|-e)\b/.test(payload)) {
    add(
      'high-risk-inline-script',
      /\b(python3?|node|ruby|perl)\s+(-c|-e)\b/,
      '严格模式禁止直接执行内联解释器脚本；请改用仓库脚本或临时脚本文件。',
      'inline interpreter script'
    );
  }
  if (/<<-?\s*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/.test(payload)) {
    add(
      'high-risk-heredoc',
      /<<-?\s*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/,
      '严格模式禁止 heredoc 直接拼接脚本；请改用脚本文件。',
      'heredoc'
    );
  }
  if (nonEmpty > 1 && /\b(for|while)\b[\s\S]*\bdo\b[\s\S]*\bdone\b/.test(payload)) {
    add(
      'high-risk-multiline-loop',
      /\b(for|while)\b/,
      '严格模式禁止直接执行多行 Bash 循环；请改用脚本文件或已有脚本。',
      'multiline loop'
    );
  }
  if (hasPathResolutionBypassRisk(payload)) {
    add(
      'high-risk-path-resolution-bypass',
      /\bcd\s+/,
      '不要使用 cd + grep + 重定向/管道；请改用 scripts/safe-text-search.js 或 rg + 绝对路径的一行命令，避免 Claude Code 路径解析授权弹窗。',
      'cd grep redirection pipeline'
    );
  }
  if (nonEmpty > 8) {
    findings.push({
      type: 'high-risk-long-bash',
      line: 1,
      phrase: 'long bash payload',
      sample: lines[0].slice(0, 160),
      message: '严格模式禁止长 Bash payload；请拆成脚本文件或已有脚本调用。',
    });
  }
  return findings;
}

function hasPathResolutionBypassRisk(payload) {
  const text = String(payload || '');
  const hasCdChain = /\bcd\s+["']?[^;&|\n]+["']?\s*(?:&&|;)/.test(text);
  if (!hasCdChain) return false;
  const hasSearch = /\b(grep|rg|find)\b/.test(text);
  const hasRedirectOrPipe = /(?:^|\s)(?:[0-9]?>|&>)|[|]/.test(text);
  const hasRelativeGlobAfterSearch = /\b(grep|rg)\b[\s\S]*\s[\w\u4e00-\u9fff./*-]+\.(?:md|txt)\b/.test(text);
  return hasSearch && (hasRedirectOrPipe || hasRelativeGlobAfterSearch);
}

function buildRecovery(payload, kind, findings, status = 'blocked_tool_command_contaminated') {
  if (findings.length === 0) {
    return {
      action: 'execute_original',
      retryLimit: 0,
      message: 'payload is clean',
    };
  }

  const contaminatedLines = new Set(findings.map((finding) => finding.line));
  const lines = payload.split(/\r?\n/);
  const cleanedLines = lines.filter((_, index) => !contaminatedLines.has(index + 1));
  const cleanedPayload = cleanedLines.join('\n').trim();

  if (kind === 'bash') {
    if (status === 'needs_tool_task_decomposition') {
      return {
        action: 'decompose_and_execute_scripted_steps',
        retryLimit: 1,
        taskContinues: true,
        decompositionRequired: true,
        canDraftSanitizedPayload: false,
        decompositionPlan: [
          'extractIntentFromPayload',
          'splitIntoReadPlanWriteVerifySteps',
          'createOrReuseScript',
          'runOneLineScriptCommand',
          'verifyEachStepOutput',
        ],
        requiredChecks: [
          'do not execute high-risk inline payload',
          'do not treat this as task refusal',
          'decompose the task into read/plan/write/verify steps',
          'prefer existing repo scripts or create a small checked script file',
          'for text search, prefer scripts/safe-text-search.js or rg with absolute paths; avoid cd + grep + redirection/pipeline',
          'run tool-call-degradation-check.js --strict again before execution',
        ],
        message: 'Bash payload is high risk as a direct tool call; decompose the task and continue with scripted steps.',
      };
    }
    return {
      action: 'discard_and_rebuild_bash',
      retryLimit: 1,
      canDraftSanitizedPayload: cleanedPayload.length > 0,
      sanitizedPayload: cleanedPayload,
      requiredChecks: [
        'do not execute contaminated payload',
        'save blocked payload and findings under 追踪/工具调用恢复/',
        'rebuild from script path or clean command template, not from transcript text',
        'run tool-call-degradation-check.js again before execution',
      ],
      message: 'Bash payload is contaminated; rebuild from clean intent or a checked sanitized draft.',
    };
  }

  return {
    action: `discard_and_rebuild_${kind}`,
    retryLimit: 1,
    canDraftSanitizedPayload: false,
    requiredChecks: [
      'do not reuse contaminated payload',
      'save blocked payload and findings under 追踪/工具调用恢复/',
      're-read source files and rebuild from current workflow state',
      'run tool-call-degradation-check.js again before execution',
    ],
    message: `${kind} payload is contaminated; rebuild from source files and workflow state.`,
  };
}

function main() {
  const args = parseArgs(process.argv);
  let payload = '';
  try {
    payload = readPayload(args.file);
  } catch (error) {
    console.error(`Error reading payload: ${error.message}`);
    process.exit(2);
  }

  const result = detect(payload, args.kind, { strict: args.strict });
  if (args.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else if (result.ok) {
    console.log('tool call payload OK');
  } else {
    console.error(`${result.status}: ${result.findings[0].message}`);
    for (const finding of result.findings.slice(0, 5)) {
      console.error(`- line ${finding.line}: ${finding.type}: ${finding.sample}`);
    }
  }
  process.exit(result.ok ? 0 : 1);
}

if (require.main === module) {
  main();
}

module.exports = { detect };
