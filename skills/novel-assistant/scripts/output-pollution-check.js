#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node output-pollution-check.js [--check] [--json] [--learn --project-root <dir>] <file...>

Detect generated-output pollution in reports, repair plans, reviews and prose:
  - consecutive repeated filler phrases, e.g. a long domain term repeated without useful information
  - output-health failures, e.g. repeated lines, low-information loops, engineering terms leaked into prose
  - domain-token floods, e.g. a genre/domain token appears far beyond a normal report density
  - provider/runner artifacts, e.g. ]<]minimax[[ or CREATED REPORT FILE COMPLETE
  - learned project pollution phrases repeated beyond the learned threshold

With --learn, detected pollution is written to:
  - 追踪/schema/output-pollution-rules.jsonl
  - 追踪/schema/user-style-rules.jsonl
  - 设定/作者风格/禁用表达.md
  - 追踪/风格决策日志.md`;

const options = {
  json: false,
  learn: false,
  projectRoot: null,
  files: [],
};

const DOMAIN_TOKEN_RULES = [
  { phrase: '修真', threshold: 35, minDensity: 0.035 },
  { phrase: '修真节拍', threshold: 10, minDensity: 0.015 },
  { phrase: '修真高潮', threshold: 6, minDensity: 0.01 },
  { phrase: '高潮风格', threshold: 6, minDensity: 0.01 },
  { phrase: '修真进度', threshold: 10, minDensity: 0.015 },
  { phrase: '修真界原则', threshold: 8, minDensity: 0.012 },
  { phrase: '修真SSOT', threshold: 4, minDensity: 0.01 },
  { phrase: 'SSOT', threshold: 12, minDensity: 0.03 },
  { phrase: '修真进度阈值', threshold: 6, minDensity: 0.01 },
  { phrase: '修真界境界过渡4节点对齐', threshold: 5, minDensity: 0.008 },
];

const RAW_ARTIFACT_RULES = [
  {
    type: 'terminal-escape-residue',
    pattern: /(?:\x1B\[[0-?]*[ -/]*[@-~]|\[e~\[|\[(?:\?[0-9;]{1,16}[hl]|[0-9]{1,4}(?:;[0-9]{0,4})*[A-Za-z~]))/g,
    phrase: 'terminal escape residue',
    blockedStatus: 'blocked_output_pollution',
    message: '检测到终端转义残片；可见回复已污染，必须丢弃残片并重新生成干净回复。',
  },
  {
    type: 'provider-artifact',
    pattern: /minimax/gi,
    phrase: 'minimax provider artifact',
    message: '检测到模型/供应商协议噪声；该文本不是报告内容，必须删除污染段并复扫。',
  },
  {
    type: 'fake-completion-sentinel',
    pattern: /\bCREATED REPORT FILE COMPLETE\b/gi,
    phrase: 'CREATED REPORT FILE COMPLETE',
    message: '检测到伪完成哨兵文本；不能把运行器/模型状态串写入报告并声明完成。',
  },
  {
    type: 'fake-completion-sentinel',
    pattern: /\bREPORT FILE COMPLETE\b/gi,
    phrase: 'REPORT FILE COMPLETE',
    message: '检测到伪完成哨兵文本；不能把运行器/模型状态串写入报告并声明完成。',
  },
];

const USER_FACING_JARGON_RULES = [
  {
    type: 'user-facing-jargon-leak',
    pattern: /\bSSOT\b/g,
    phrase: 'SSOT',
    message: '用户可见回复不应展示工程缩写 SSOT；请改成“权威设定”“设定基准”或“唯一设定源”，例如“境界权威设定”。',
  },
  {
    type: 'user-facing-jargon-leak',
    pattern: /\bContext Pack\b/g,
    phrase: 'Context Pack',
    message: '用户可见回复不应展示 Context Pack；请改成“上下文包”“本章上下文包”或“最小上下文”。',
  },
  {
    type: 'user-facing-jargon-leak',
    pattern: /\bfull\s+审查/gi,
    phrase: 'full 审查',
    message: '用户可见回复不应展示 full 审查；请改成“完整审查”“多视角审查”或“全面审查”。',
  },
  {
    type: 'user-facing-jargon-leak',
    pattern: /\bpreflight\b/gi,
    phrase: 'preflight',
    message: '用户可见回复不应展示 preflight；请改成“前置检查”或“开始前检查”。',
  },
  {
    type: 'user-facing-jargon-leak',
    pattern: /\btoken\b/gi,
    phrase: 'token',
    message: '用户可见回复不应展示 token；请改成“上下文消耗”“成本”或“模型消耗”。',
  },
  {
    type: 'user-facing-jargon-leak',
    pattern: /\brecap\b/gi,
    phrase: 'recap',
    message: '用户可见回复不应展示 recap；请改成“运行摘要”“状态摘要”或“会话摘要”。',
  },
  {
    type: 'user-facing-jargon-leak',
    pattern: /\bcheckpoint\b/gi,
    phrase: 'checkpoint',
    message: '用户可见回复不应展示 checkpoint；请改成“断点”“恢复点”或“阶段断点”。',
  },
];

const ENGINEERING_TERMS = [
  '细纲',
  '任务描述',
  '执行范围',
  '审稿人',
  '作者输出格式',
  '修复清单',
  '阶段导航',
  'completion_policy',
  'workflow',
  'TaskCreate',
];

const INTERNAL_WORKFLOW_NARRATION_RULES = [
  /先快速看一下[^。\n]*(?:项目目录|工作流状态|设定|大纲|正文)/,
  /(?:我)?并行读取[^。\n]*(?:关键|设定|大纲|工作流|状态|文件)/,
  /我先读取[^。\n]*(?:正文|文件|目录|状态|素材|角色小传|大纲|设定)/,
  /继续读\s*§?\s*\d+(?:\s*[-~至]\s*§?\s*\d+)?/,
  /最小必要(?:回复|修订方案|修订|输出)/,
  /确认[^。\n]*(?:具体卡在哪|卡在哪里)/,
];

for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === '--check') {
    // Detection is always check-only unless --learn is provided.
  } else if (arg === '--json') {
    options.json = true;
  } else if (arg === '--learn') {
    options.learn = true;
  } else if (arg === '--project-root') {
    options.projectRoot = process.argv[++i];
    if (!options.projectRoot) die('--project-root requires a directory');
  } else if (arg === '-h' || arg === '--help') {
    process.stdout.write(`${USAGE}\n`);
    process.exit(0);
  } else if (arg.startsWith('-')) {
    die(`Unknown option: ${arg}`);
  } else {
    options.files.push(arg);
  }
}

if (options.files.length === 0) die('No files provided');
if (options.learn && !options.projectRoot) die('--learn requires --project-root <dir>');

const projectRoot = options.projectRoot ? path.resolve(options.projectRoot) : null;
const learnedRules = projectRoot ? loadLearnedRules(projectRoot) : [];
const allFindings = [];
let failed = false;

for (const file of options.files) {
  const fullPath = path.resolve(file);
  let input;
  try {
    input = fs.readFileSync(fullPath, 'utf8');
  } catch (error) {
    failed = true;
    if (!options.json) console.error(`${file}: unable to read (${error.message})`);
    continue;
  }

  const findings = scanDocument(input, learnedRules).map(finding => ({
    file,
    ...positionForOriginalOffset(input, finding.offset),
    ...finding,
  }));
  allFindings.push(...findings);
}

let learned = [];
if (options.learn && allFindings.length > 0) {
  learned = writeLearnedRules(projectRoot, allFindings);
}

if (options.json) {
  process.stdout.write(`${JSON.stringify({ findings: allFindings, learned }, null, 2)}\n`);
} else {
  for (const finding of allFindings) {
    console.log(`${finding.file}:${finding.line}:${finding.column}: ${finding.type}: ${finding.message} (${finding.phrase} x${finding.count})`);
  }
  if (learned.length > 0) {
    console.log(`learned ${learned.length} output pollution rule(s)`);
  }
}

if (failed) process.exit(2);
if (allFindings.length > 0) process.exit(1);

function die(message) {
  console.error(message);
  console.error(USAGE.trimEnd());
  process.exit(2);
}

function scanDocument(input, rules) {
  const normalized = normalizeForScan(input);
  const findings = findConsecutiveRepeats(normalized);
  findings.push(...findRepeatedLines(input));
  findings.push(...findEngineeringTermLeaks(input));
  findings.push(...findLowInformationOutput(normalized));
  findings.push(...findDomainTokenFloods(normalized));
  findings.push(...findLearnedRuleViolations(normalized, rules));
  findings.push(...findRawArtifactViolations(input));
  findings.push(...findUserFacingJargonViolations(input));
  findings.push(...findInternalWorkflowNarration(input));
  findings.push(...findEncodedGibberishBlobs(input));
  return dedupeFindings(findings);
}

function normalizeForScan(input) {
  const chars = [];
  let fence = null;
  const lines = input.split(/(\r?\n)/);
  let offset = 0;

  for (let i = 0; i < lines.length; i += 1) {
    const part = lines[i];
    const isLine = !/^\r?\n$/.test(part);
    if (isLine) {
      const trimmed = part.trim();
      const fenceMarker = /^(?:`{3,}|~{3,})/.exec(trimmed);
      if (fence) {
        if (fenceMarker && fenceMarker[0][0] === fence.char && fenceMarker[0].length >= fence.length) fence = null;
      } else if (fenceMarker) {
        fence = { char: fenceMarker[0][0], length: fenceMarker[0].length };
      } else {
        for (let j = 0; j < part.length; j += 1) {
          const char = part[j];
          if (isScannableChar(char)) chars.push({ char, offset: offset + j });
        }
      }
    }
    offset += part.length;
  }

  return {
    text: chars.map(entry => entry.char).join(''),
    offsets: chars.map(entry => entry.offset),
  };
}

function isScannableChar(char) {
  return /[\p{Script=Han}A-Za-z0-9]/u.test(char);
}

function findConsecutiveRepeats(normalized) {
  const findings = [];
  const text = normalized.text;
  let index = 0;

  while (index < text.length) {
    let best = null;
    for (let length = 12; length >= 2; length -= 1) {
      if (index + length * 6 > text.length) continue;
      const phrase = text.slice(index, index + length);
      if (!isMeaningfulPhrase(phrase)) continue;

      let count = 1;
      while (text.slice(index + length * count, index + length * (count + 1)) === phrase) count += 1;

      if (count >= 6 || (count >= 4 && phrase.length >= 5)) {
        best = { phrase, count, length };
        break;
      }
    }

    if (best) {
      findings.push({
        type: 'consecutive-repeat',
        phrase: best.phrase,
        count: best.count,
        offset: normalized.offsets[index] || 0,
        message: '疑似模型重复填充污染；必须回退到污染前版本或重写该段，不能把污染报告/修复方案落盘为完成品。',
      });
      index += best.length * best.count;
    } else {
      index += 1;
    }
  }

  return findings;
}

function findLearnedRuleViolations(normalized, rules) {
  const findings = [];
  const text = normalized.text;
  for (const rule of rules) {
    if (!rule.phrase || rule.phrase.length < 2) continue;
    const phrase = normalizePhrase(rule.phrase);
    if (!phrase) continue;

    let count = 0;
    let firstIndex = -1;
    let pos = 0;
    while (pos < text.length) {
      const found = text.indexOf(phrase, pos);
      if (found === -1) break;
      if (firstIndex === -1) firstIndex = found;
      count += 1;
      pos = found + phrase.length;
    }

    const threshold = Number(rule.maxOccurrences || rule.max_occurrences || 6);
    if (count >= threshold) {
      const blockedStatus = rule.blockedStatus || rule.blocked_status || 'blocked_output_pollution';
      findings.push({
        type: 'learned-pollution-repeat',
        phrase: rule.phrase,
        count,
        offset: normalized.offsets[firstIndex] || 0,
        blockedStatus,
        message: `命中已学习输出污染/模型退化规则；该短语在当前产物中出现 ${count} 次，超过阈值 ${threshold}。`,
      });
    }
  }
  return findings;
}

function findDomainTokenFloods(normalized) {
  const findings = [];
  const text = normalized.text;
  if (text.length === 0) return findings;

  for (const rule of DOMAIN_TOKEN_RULES) {
    const phrase = normalizePhrase(rule.phrase);
    if (!phrase) continue;
    let count = 0;
    let firstIndex = -1;
    let pos = 0;
    while (pos < text.length) {
      const found = text.indexOf(phrase, pos);
      if (found === -1) break;
      if (firstIndex === -1) firstIndex = found;
      count += 1;
      pos = found + phrase.length;
    }

    const density = (count * phrase.length) / text.length;
    if (count >= rule.threshold && density >= rule.minDensity) {
      findings.push({
        type: 'domain-token-flood',
        phrase: rule.phrase,
        count,
        offset: normalized.offsets[firstIndex] || 0,
        message: `疑似术语洪泛污染；“${rule.phrase}”在当前产物中出现 ${count} 次，密度 ${(density * 100).toFixed(1)}%，必须回到最后可信事实点重写。`,
      });
    }
  }

  return findings;
}

function findRawArtifactViolations(input) {
  const findings = [];
  for (const rule of RAW_ARTIFACT_RULES) {
    const matches = [...input.matchAll(rule.pattern)];
    if (matches.length === 0) continue;
    findings.push({
      type: rule.type,
      phrase: matches[0][0] || rule.phrase,
      count: matches.length,
      offset: matches[0].index || 0,
      ...(rule.blockedStatus ? { blockedStatus: rule.blockedStatus } : {}),
      message: rule.message,
    });
  }
  return findings;
}

function findUserFacingJargonViolations(input) {
  const findings = [];
  for (const rule of USER_FACING_JARGON_RULES) {
    const matches = [...input.matchAll(rule.pattern)];
    if (matches.length === 0) continue;
    findings.push({
      type: rule.type,
      phrase: rule.phrase,
      count: matches.length,
      offset: matches[0].index || 0,
      blockedStatus: 'rewrite_visible_reply',
      message: rule.message,
    });
  }
  return findings;
}

function findInternalWorkflowNarration(input) {
  const hits = [];
  for (const rule of INTERNAL_WORKFLOW_NARRATION_RULES) {
    const match = rule.exec(input);
    if (match) hits.push({ phrase: match[0], index: match.index || 0 });
  }

  if (hits.length < 2) return [];
  hits.sort((a, b) => a.index - b.index);
  return [{
    type: 'internal-workflow-narration',
    phrase: hits.slice(0, 3).map(hit => hit.phrase).join(' | '),
    count: hits.length,
    offset: hits[0].index,
    message: '可见回复混入内部读取/并行/阶段旁白；必须改写为用户可读结论、当前阶段和下一步候选，不得暴露工具执行过程。',
  }];
}

function findEncodedGibberishBlobs(input) {
  const findings = [];
  const lines = input.split(/\r?\n/);
  let offset = 0;
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.length >= 120 && looksLikeEncodedBlob(trimmed)) {
      findings.push({
        type: 'encoded-gibberish-blob',
        phrase: `${trimmed.slice(0, 48)}...`,
        count: trimmed.length,
        offset: offset + line.indexOf(trimmed),
        message: '可见回复疑似混入编码/乱码块；必须停止复用该输出，回到最后可信断点重新生成干净摘要。',
      });
    }
    offset += line.length + 1;
  }
  return findings;
}

function looksLikeEncodedBlob(text) {
  if (/[\u4e00-\u9fff]/.test(text)) return false;
  if (/\s/.test(text)) return false;
  const base64ish = (text.match(/[A-Za-z0-9+/=]/g) || []).length / text.length;
  if (base64ish < 0.95) return false;
  return /[A-Z]/.test(text) && /[a-z]/.test(text);
}

function findRepeatedLines(input) {
  const findings = [];
  const lines = input.split(/\r?\n/);
  let offset = 0;
  let previous = null;
  let previousOffset = 0;
  let count = 0;

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed && trimmed.length >= 8 && trimmed === previous) {
      count += 1;
    } else {
      if (previous && count >= 4) {
        findings.push({
          type: 'repeated-line',
          phrase: previous,
          count,
          offset: previousOffset,
          message: '疑似模型损伤输出：连续重复行过多；必须丢弃本次输出，缩小任务粒度后重试。',
        });
      }
      previous = trimmed;
      previousOffset = offset;
      count = trimmed ? 1 : 0;
    }
    offset += line.length + 1;
  }

  if (previous && count >= 4) {
    findings.push({
      type: 'repeated-line',
      phrase: previous,
      count,
      offset: previousOffset,
      message: '疑似模型损伤输出：连续重复行过多；必须丢弃本次输出，缩小任务粒度后重试。',
    });
  }

  return findings;
}

function findEngineeringTermLeaks(input) {
  const findings = [];
  let total = 0;
  let first = null;
  const hitTerms = [];

  for (const term of ENGINEERING_TERMS) {
    const pattern = new RegExp(escapeRegExp(term), 'g');
    const matches = [...input.matchAll(pattern)];
    if (matches.length === 0) continue;
    total += matches.length;
    hitTerms.push(`${term}x${matches.length}`);
    if (!first || matches[0].index < first.index) first = { term, index: matches[0].index };
  }

  if (total >= 6) {
    findings.push({
      type: 'engineering-term-leak',
      phrase: hitTerms.slice(0, 6).join(', '),
      count: total,
      offset: first ? first.index : 0,
      message: '疑似输出健康失败：正文/报告中混入过多工程流程词；不得把内部任务描述、细纲标签或审稿流程当作正文内容。',
    });
  }

  return findings;
}

function findLowInformationOutput(normalized) {
  const text = normalized.text;
  if (text.length < 1200) return [];
  const uniqueChars = new Set([...text]).size;
  const uniqueRatio = uniqueChars / text.length;
  if (uniqueRatio >= 0.08) return [];
  return [{
    type: 'low-information-output',
    phrase: 'unique-char-ratio',
    count: Number(uniqueRatio.toFixed(4)),
    offset: normalized.offsets[0] || 0,
    message: `疑似输出健康失败：长输出信息密度过低（unique ratio ${(uniqueRatio * 100).toFixed(1)}%）；必须缩小任务粒度重试。`,
  }];
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function isMeaningfulPhrase(phrase) {
  if (new Set([...phrase]).size <= 1) return false;
  if (/^\d+$/.test(phrase)) return false;
  if (/^[A-Za-z]+$/.test(phrase) && phrase.length < 4) return false;
  return true;
}

function normalizePhrase(phrase) {
  return [...phrase].filter(isScannableChar).join('');
}

function dedupeFindings(findings) {
  const seen = new Set();
  const out = [];
  for (const finding of findings) {
    const key = `${finding.type}:${finding.phrase}:${finding.offset}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(finding);
  }
  return out;
}

function positionForOriginalOffset(input, offset) {
  let line = 1;
  let lineStart = 0;
  for (let i = 0; i < input.length && i < offset; i += 1) {
    if (input[i] === '\n') {
      line += 1;
      lineStart = i + 1;
    }
  }
  return { line, column: offset - lineStart + 1 };
}

function loadLearnedRules(root) {
  const rulesPath = path.join(root, '追踪/schema/output-pollution-rules.jsonl');
  if (!fs.existsSync(rulesPath)) return [];
  return fs.readFileSync(rulesPath, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)
    .map(line => {
      try { return JSON.parse(line); } catch { return null; }
    })
    .filter(Boolean);
}

function writeLearnedRules(root, findings) {
  const now = new Date().toISOString();
  const unique = [];
  const seen = new Set();
  for (const finding of findings) {
    if (!finding.phrase || seen.has(finding.phrase)) continue;
    seen.add(finding.phrase);
    unique.push(finding);
  }

  if (unique.length === 0) return [];

  const schemaDir = path.join(root, '追踪/schema');
  const styleDir = path.join(root, '设定/作者风格');
  const trackingDir = path.join(root, '追踪');
  fs.mkdirSync(schemaDir, { recursive: true });
  fs.mkdirSync(styleDir, { recursive: true });
  fs.mkdirSync(trackingDir, { recursive: true });

  const pollutionRulesPath = path.join(schemaDir, 'output-pollution-rules.jsonl');
  const styleRulesPath = path.join(schemaDir, 'user-style-rules.jsonl');
  const bannedPath = path.join(styleDir, '禁用表达.md');
  const logPath = path.join(trackingDir, '风格决策日志.md');

  const existingPhrases = new Set(loadLearnedRules(root).map(rule => rule.phrase));
  const learned = [];

  for (const finding of unique) {
    const modelDegradation = isModelDegradationFinding(finding);
    const category = modelDegradation ? '模型退化' : '输出污染';
    const blockedStatus = modelDegradation ? 'blocked_model_degradation' : 'blocked_output_pollution';
    const rule = {
      id: `pollution-${compactDate(now)}-${slugify(finding.phrase)}`,
      scope: '当前书',
      priority: 'hard',
      category,
      phrase: finding.phrase,
      maxOccurrences: 5,
      blockedStatus,
      rule: `报告、修复方案、审查结论和正文中禁止重复填充“${finding.phrase}”；下次生成前先检查该规则，命中时进入 ${blockedStatus}，回退污染段并重写，复扫通过后才可汇报完成。`,
      evidence: `output-pollution-check 检测到 ${finding.type}，重复 ${finding.count} 次。`,
      bad_example: finding.phrase.repeat(Math.min(finding.count, 3)),
      preferred_fix: modelDegradation
        ? '回到最后可信断点，缩小任务粒度重试一次；下次生成前先检查该规则，不允许继续同一术语循环。'
        : '回到污染前事实点，用自然语言重写；必要时拆成短句或表格，不允许用同一术语填充篇幅。',
      source_files: [relativeToRoot(root, finding.file)],
      updatedAt: now,
    };

    if (!existingPhrases.has(rule.phrase)) {
      appendJsonLine(pollutionRulesPath, rule);
      appendJsonLine(styleRulesPath, {
        id: rule.id,
        scope: rule.scope,
        priority: rule.priority,
        category: rule.category,
        blockedStatus: rule.blockedStatus,
        rule: rule.rule,
        evidence: rule.evidence,
        bad_example: rule.bad_example,
        preferred_fix: rule.preferred_fix,
        source_files: rule.source_files,
        updatedAt: rule.updatedAt,
      });
      learned.push(rule);
    }
  }

  if (learned.length > 0) {
    appendMarkdown(bannedPath, renderBannedSection(learned));
    appendMarkdown(logPath, renderDecisionLog(learned));
  }

  return learned;
}

function isModelDegradationFinding(finding) {
  return [
    'consecutive-repeat',
    'repeated-line',
    'low-information-output',
    'domain-token-flood',
    'learned-pollution-repeat',
  ].includes(finding.type);
}

function appendJsonLine(file, object) {
  fs.appendFileSync(file, `${JSON.stringify(object)}\n`, 'utf8');
}

function appendMarkdown(file, text) {
  const prefix = fs.existsSync(file) && fs.statSync(file).size > 0 ? '\n' : '';
  fs.appendFileSync(file, `${prefix}${text}`, 'utf8');
}

function renderBannedSection(rules) {
  const lines = ['## 输出污染硬门禁', ''];
  for (const rule of rules) {
    lines.push(`- 禁止重复填充「${rule.phrase}」：${rule.preferred_fix}`);
  }
  return `${lines.join('\n')}\n`;
}

function renderDecisionLog(rules) {
  const lines = [`## ${new Date().toISOString()} - 输出污染学习`, ''];
  for (const rule of rules) {
    lines.push(`- 新增硬规则：${rule.phrase}（来源：${rule.source_files.join(', ')}）`);
  }
  return `${lines.join('\n')}\n`;
}

function compactDate(iso) {
  return iso.replace(/[-:TZ.]/g, '').slice(0, 14);
}

function slugify(text) {
  const ascii = text.replace(/[^A-Za-z0-9]+/g, '').slice(0, 24);
  if (ascii) return ascii.toLowerCase();
  let hash = 0;
  for (const char of text) hash = ((hash << 5) - hash + char.charCodeAt(0)) | 0;
  return Math.abs(hash).toString(36);
}

function relativeToRoot(root, file) {
  const absolute = path.resolve(file);
  const rel = path.relative(root, absolute);
  return rel.startsWith('..') ? file : rel;
}
