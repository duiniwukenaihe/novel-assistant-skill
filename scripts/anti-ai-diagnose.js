#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const USAGE = `Usage: node anti-ai-diagnose.js [--json] [--project-root <book-dir>] [--work-type=shortform|longform|unknown_fragment] [--prose-profile=fiction|report|outline|chat|technical|unknown] <file...>

Aggregate anti-AI prose signals for novel-assistant workflow.
This script diagnoses; it does not rewrite.`;

const PROSE_PROFILES = ['fiction', 'report', 'outline', 'chat', 'technical', 'unknown'];
const ENGINEERING_LEAKS = ['细纲', '本章', '下一章', '任务描述', '读者会', '章节契约', 'workflow'];
const FICTION_CLICHES = ['不禁', '心中暗道', '暗自思忖', '嘴角微扬', '勾起一抹弧度', '缓缓说道', '缓缓开口', '淡淡地说', '脸色一变', '身形一顿', '眼中闪过一丝', '映入眼帘'];
const GENERIC_EMOTIONS = ['深深的绝望', '一丝悲伤', '难以言喻', '复杂的情绪', '说不清的感觉'];
const EXPLANATION_VOICE = ['这意味着', '他终于明白', '她终于明白', '终于明白', '注定无人入眠', '从某种意义上'];
const AI_VOCABULARY = [
  '此外',
  '至关重要',
  '深入探讨',
  '强调了',
  '持久的影响',
  '不断演变',
  '关键作用',
  '关键转折点',
  '宝贵的经验',
  '充满活力',
  '无缝',
  '直观',
  '强大的体验',
  '彰显了',
  '展现了',
  '相互作用',
];
const VAGUE_ATTRIBUTIONS = ['行业报告显示', '观察者指出', '专家认为', '行业专家认为', '一些批评者认为', '多个来源', '多家媒体', '据业内人士', '据相关人士'];
const KNOWLEDGE_CUTOFF_DISCLAIMERS = ['根据我最后的训练更新', '截至我的知识截止日期', '截至我所知', '虽然具体细节有限', '基于可用信息', '资料有限'];
const SYCOPHANTIC_TONE = ['好问题', '您说得完全正确', '你说得完全正确', '这是一个很好的观点', '当然可以', '非常棒的问题', '很高兴为您'];
const GENERIC_POSITIVE_CONCLUSIONS = ['未来看起来光明', '激动人心的时代即将到来', '向正确方向迈出', '继续追求卓越', '前景十分广阔'];
const TEMPLATE_SHELLS = [
  '真正重要的是',
  '真正决定',
  '真正的问题',
  '真正打动',
  '本质上',
  '核心在于',
  '底层逻辑',
  '这背后其实',
  '说白了',
  '值得注意的是',
  '不可否认的是',
  '总的来说',
  '由此可见',
  '不难看出',
  '这个问题很简单',
  '答案很简单',
  '下面我们来',
  '接下来我会',
  '希望这能帮到你',
  '你觉得呢',
  '你有没有类似经历',
];

const TOOL_FINGERPRINT_PATTERNS = [
  { re: /contentReference\[[^\]]+\]\{[^}]+\}/g, phrase: 'contentReference[...]', severity: 'blocking' },
  { re: /\bturn\d+(?:search|view|fetch|open)\d+\b/g, phrase: 'turn-search-citation-token', severity: 'blocking' },
  { re: /\boai_citation\b|\boaicite\b|\battached_file:\d+\b|\bgrok_card\b/g, phrase: 'ai-citation-token', severity: 'blocking' },
  { re: /\butm_source=(?:chatgpt\.com|claude\.ai|copilot\.com|openai|perplexity\.ai|grok\.com)\b/gi, phrase: 'ai-tool-url-param', severity: 'strong' },
];

const PLACEHOLDER_PATTERNS = [
  /\[(?:Your|INSERT|Insert|Add|Enter|Describe|Specify|Choose)[^\]]+\]/g,
  /\b\d{4}-XX-XX\b/g,
  /<!--\s*(?:TODO|add|fill in|insert)[\s\S]{0,120}?-->/gi,
];

const options = {
  json: false,
  projectRoot: null,
  workType: 'unknown_fragment',
  proseProfile: 'unknown',
  files: [],
};

for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === '--json') {
    options.json = true;
  } else if (arg === '--project-root') {
    options.projectRoot = process.argv[++i];
    if (!options.projectRoot) die('--project-root requires a directory');
  } else if (arg.startsWith('--work-type=')) {
    const value = arg.slice('--work-type='.length);
    if (!['shortform', 'longform', 'unknown_fragment'].includes(value)) die(`Invalid --work-type: ${value}`);
    options.workType = value;
  } else if (arg.startsWith('--prose-profile=')) {
    const value = arg.slice('--prose-profile='.length);
    if (!PROSE_PROFILES.includes(value)) die(`Invalid --prose-profile: ${value}`);
    options.proseProfile = value;
  } else if (arg === '-h' || arg === '--help') {
    console.log(USAGE);
    process.exit(0);
  } else if (arg.startsWith('-')) {
    die(`Unknown option: ${arg}`);
  } else {
    options.files.push(arg);
  }
}

if (options.files.length === 0) die('No files provided');

const projectRules = options.projectRoot ? loadProjectRules(path.resolve(options.projectRoot)) : [];

const result = {
  schemaVersion: '1.0.0',
  workType: options.workType,
  proseProfile: options.proseProfile,
  projectRoot: options.projectRoot ? path.resolve(options.projectRoot) : null,
  projectRulesLoaded: projectRules.length,
  files: options.files.map(scanFile),
};

if (options.json) {
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
  printText(result);
}

function scanFile(file) {
  const text = fs.readFileSync(file, 'utf8');
  const lines = text.split(/\r?\n/);
  const findings = [];

  for (let i = 0; i < lines.length; i += 1) {
    const lineNo = i + 1;
    const line = lines[i];
    if (shouldScanEngineeringLeaks(options.proseProfile)) {
      scanPhraseList(findings, line, lineNo, ENGINEERING_LEAKS, 'engineering-leak', 'blocking', '正文混入工程/流程词，需改成角色可感知的动作、物件或对话。');
    }
    if (options.proseProfile === 'fiction') {
      scanPhraseList(findings, line, lineNo, FICTION_CLICHES, 'fiction-cliche', 'advisory', '检测到小说套话；若密集出现，应改成角色独有动作、物件、声口或更具体的场面证据。');
    }
    scanPhraseList(findings, line, lineNo, GENERIC_EMOTIONS, 'generic-emotion', 'strong', '泛化情绪，需要接具体动作、物件、身体反应或对话。');
    scanPhraseList(findings, line, lineNo, EXPLANATION_VOICE, 'explanation-voice', 'strong', '解释腔/总结体，需要改成场景内证据或角色反应。');
    scanPhraseList(findings, line, lineNo, AI_VOCABULARY, 'ai-vocabulary', 'advisory', '检测到通用 AI 词汇，需确认是否有具体事实、动作或角色语气支撑。');
    scanPhraseList(findings, line, lineNo, VAGUE_ATTRIBUTIONS, 'vague-attribution', 'strong', '模糊归因会制造资料腔；报告需补明确来源，正文需改成角色可见证据。');
    scanPhraseList(findings, line, lineNo, KNOWLEDGE_CUTOFF_DISCLAIMERS, 'knowledge-cutoff-disclaimer', 'blocking', '知识截止/资料有限口吻是模型痕迹，交付物中必须删除或换成真实来源说明。');
    scanPhraseList(findings, line, lineNo, SYCOPHANTIC_TONE, 'sycophantic-tone', 'strong', '讨好式开场会暴露助手腔，需直接回应任务或进入文本本身。');
    scanPhraseList(findings, line, lineNo, GENERIC_POSITIVE_CONCLUSIONS, 'generic-positive-conclusion', 'strong', '泛泛乐观结尾没有叙事或事实价值，需改成具体后果、行动或留白。');
    scanPhraseList(findings, line, lineNo, TEMPLATE_SHELLS, 'template-shell', 'strong', '中文模板壳会制造助手腔，需改成具体事件、动作、证据或角色判断。');
    scanProjectRules(findings, line, lineNo, projectRules);
    scanToolFingerprints(findings, line, lineNo);
    scanPlaceholders(findings, line, lineNo);
    scanEmDash(findings, line, lineNo);
    scanNegativePositiveFlip(findings, line, lineNo);
  }

  scanCornerQuoteDensity(findings, text);
  scanAsciiQuoteStyle(findings, text);
  scanEmDashAbuse(findings, text);
  scanModelLoops(findings, text);
  normalizeNegativePositiveSeverity(findings, text);

  findings.sort((a, b) => a.line - b.line || a.column - b.column || a.type.localeCompare(b.type));
  return {
    file,
    fileName: path.basename(file),
    recommendedProfile: options.workType,
    proseProfile: options.proseProfile,
    humanVoiceProtection: humanVoiceProtection(text, options.projectRoot ? path.resolve(options.projectRoot) : null),
    summary: summarize(findings),
    clusterScore: clusterScore(findings),
    clusterLevel: clusterLevel(findings),
    qualityScore: qualityScore(findings),
    findings,
  };
}

function scanAsciiQuoteStyle(findings, text) {
  if (!(options.workType === 'shortform' || options.proseProfile === 'fiction')) return;
  const matches = Array.from(text.matchAll(/"/g));
  const cjkCount = (text.match(/[\u3400-\u9FFF]/g) || []).length;
  if (cjkCount < 10 || matches.length < 2) return;
  const loc = locateOffset(text, matches[0].index || 0);
  findings.push({
    type: 'ascii-quote-style',
    severity: 'blocking',
    line: loc.line,
    column: loc.column,
    phrase: '"',
    count: matches.length,
    message: '大陆中文小说正文混入半角直引号；使用确定性标点修复统一为中文弯引号“”，不要逐句重写。',
    excerpt: `${matches.length} ascii quote marks`,
  });
}

function normalizeNegativePositiveSeverity(findings, text) {
  const comparisons = findings.filter((finding) => finding.type === 'negative-positive-flip');
  if (!comparisons.length) return;
  const proseChars = Math.max(1, String(text || '').replace(/\s/g, '').length);
  const densityPerThousand = comparisons.length / (proseChars / 1000);
  const clustered = comparisons.length >= 5 || (comparisons.length >= 3 && densityPerThousand >= 2);
  for (const finding of comparisons) {
    finding.severity = clustered ? 'blocking' : 'advisory';
    finding.message = clustered
      ? '先否定再肯定的对比句在当前文本中密集出现；保留确有审判或人物声口功能的少数句，其余改成动作、物件或直接事实。'
      : '孤立对比句只作提示；有明确人物声口或叙事功能时可以保留。';
  }
}

function shouldScanEngineeringLeaks(proseProfile) {
  return ['fiction', 'chat', 'unknown'].includes(proseProfile);
}

function humanVoiceProtection(text, projectRoot) {
  const evidence = [];
  if (projectRoot) {
    if (fs.existsSync(path.join(projectRoot, '追踪/workflow/author-voice.json'))) evidence.push('author_voice_profile');
    if (fs.existsSync(path.join(projectRoot, '设定/作者风格/优秀样章.md'))) evidence.push('accepted_sample');
  }
  if (hasSceneVoice(text)) evidence.push('scene_or_dialogue_voice');
  if (hasConcreteDetail(text)) evidence.push('concrete_detail');

  return {
    mode: evidence.includes('author_voice_profile') || evidence.includes('accepted_sample')
      ? 'minimal_repair'
      : 'normal',
    evidence,
    policy: evidence.includes('author_voice_profile') || evidence.includes('accepted_sample')
      ? '只修硬污染、工具指纹、占位符、模型循环和用户硬禁表达；不要把已确认声口改成通用 humanizer 腔。'
      : '按常规诊断结果处理。',
  };
}

function hasSceneVoice(text) {
  return /[“"「『][^”"」』]{1,80}[”"」』]/.test(text) && /(我|他|她|问|说|笑|看|放|推|拿|走)/.test(text);
}

function hasConcreteDetail(text) {
  const matches = text.match(/(碗|桌|门|纸|手|杯|灯|鞋|雨|灰|油|粉笔|豆浆|塑料袋|衣角|窗|地面|钥匙|手机)/g) || [];
  return matches.length >= 2;
}

function scanPhraseList(findings, line, lineNo, phrases, type, severity, message) {
  for (const phrase of phrases) {
    let start = 0;
    while (true) {
      const index = line.indexOf(phrase, start);
      if (index < 0) break;
      findings.push({
        type,
        severity,
        line: lineNo,
        column: index + 1,
        phrase,
        message,
        excerpt: compact(line),
      });
      start = index + phrase.length;
    }
  }
}

function loadProjectRules(projectRoot) {
  const rules = [];
  rules.push(...loadJsonlRules(path.join(projectRoot, '追踪/schema/user-style-rules.jsonl'), 'user-style-rules'));
  rules.push(...loadJsonlRules(path.join(projectRoot, '追踪/schema/output-pollution-rules.jsonl'), 'output-pollution-rules'));
  rules.push(...loadForbiddenMarkdown(path.join(projectRoot, '设定/作者风格/禁用表达.md')));
  return dedupeProjectRules(rules);
}

function loadJsonlRules(file, source) {
  if (!fs.existsSync(file)) return [];
  const output = [];
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  for (const line of lines) {
    if (!line.trim()) continue;
    let rule;
    try {
      rule = JSON.parse(line);
    } catch (_) {
      continue;
    }

    const priority = String(rule.priority || '').toLowerCase();
    const category = String(rule.category || '');
    if (source === 'user-style-rules' && priority && priority !== 'hard') continue;
    if (source === 'user-style-rules' && category && !/(AI味|输出污染|标点|对话|节奏)/.test(category)) continue;

    for (const phrase of extractRulePhrases(rule)) {
      output.push({
        phrase,
        source,
        severity: source === 'output-pollution-rules' ? 'blocking' : 'strong',
        message: source === 'output-pollution-rules'
          ? '命中项目已学习的模型污染/输出污染短语，需回退或重写污染段。'
          : '命中项目已学习的用户风格禁用表达，需按用户偏好改写。',
      });
    }
  }
  return output;
}

function extractRulePhrases(rule) {
  const values = [];
  for (const key of ['phrase', 'bad_example', 'badExample', 'forbidden_expression', 'forbiddenExpression']) {
    if (typeof rule[key] === 'string') values.push(rule[key]);
  }
  for (const key of ['bad_examples', 'badExamples', 'phrases', 'forbidden']) {
    if (Array.isArray(rule[key])) values.push(...rule[key].filter((value) => typeof value === 'string'));
  }

  const phrases = [];
  for (const value of values) phrases.push(...extractSpecificPhrases(value));
  return phrases;
}

function loadForbiddenMarkdown(file) {
  if (!fs.existsSync(file)) return [];
  const text = fs.readFileSync(file, 'utf8');
  return extractSpecificPhrases(text).map((phrase) => ({
    phrase,
    source: 'forbidden-expressions',
    severity: 'strong',
    message: '命中作者风格禁用表达，需改成用户认可的表达方式。',
  }));
}

function extractSpecificPhrases(value) {
  const text = String(value || '').trim();
  if (!text) return [];
  const phrases = [];
  const inlineCode = text.match(/`([^`\n]{2,80})`/g) || [];
  for (const token of inlineCode) phrases.push(token.slice(1, -1));

  const quoted = text.match(/[“"「『']([^”"」』'\n]{2,80})[”"」』']/g) || [];
  for (const token of quoted) phrases.push(token.slice(1, -1));

  if (phrases.length === 0 && text.length >= 2 && text.length <= 80 && !/[。！？\n]/.test(text)) phrases.push(text);
  return phrases
    .map((phrase) => phrase.trim())
    .filter((phrase) => phrase.length >= 2 && phrase.length <= 80)
    .filter((phrase) => !/^(hard|soft|AI味|输出污染|标点|对话|节奏)$/i.test(phrase));
}

function dedupeProjectRules(rules) {
  const seen = new Set();
  const output = [];
  for (const rule of rules) {
    const key = `${rule.source}:${rule.phrase}`;
    if (seen.has(key)) continue;
    seen.add(key);
    output.push(rule);
  }
  return output;
}

function scanProjectRules(findings, line, lineNo, rules) {
  for (const rule of rules) {
    let start = 0;
    while (true) {
      const index = line.indexOf(rule.phrase, start);
      if (index < 0) break;
      findings.push({
        type: 'learned-project-rule',
        severity: rule.severity,
        line: lineNo,
        column: index + 1,
        phrase: rule.phrase,
        source: rule.source,
        message: rule.message,
        excerpt: compact(line),
      });
      start = index + rule.phrase.length;
    }
  }
}

function scanToolFingerprints(findings, line, lineNo) {
  for (const pattern of TOOL_FINGERPRINT_PATTERNS) {
    pattern.re.lastIndex = 0;
    let match;
    while ((match = pattern.re.exec(line)) !== null) {
      findings.push({
        type: 'tool-fingerprint-leak',
        severity: pattern.severity,
        line: lineNo,
        column: match.index + 1,
        phrase: pattern.phrase,
        message: '检测到 AI/搜索/聊天工具指纹泄露，正文或交付物中必须删除或替换为真实来源表述。',
        excerpt: compact(line),
      });
    }
  }
}

function scanPlaceholders(findings, line, lineNo) {
  for (const pattern of PLACEHOLDER_PATTERNS) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(line)) !== null) {
      findings.push({
        type: 'placeholder-leak',
        severity: 'blocking',
        line: lineNo,
        column: match.index + 1,
        phrase: match[0].slice(0, 40),
        message: '检测到未填占位符，不能发布或写入正文；需填真实内容或删除该句。',
        excerpt: compact(line),
      });
    }
  }
}

function scanEmDash(findings, line, lineNo) {
  const re = /——|—|--+/g;
  let match;
  while ((match = re.exec(line)) !== null) {
    const canonical = match[0] === '——';
    findings.push({
      type: 'em-dash',
      severity: canonical ? 'advisory' : 'blocking',
      line: lineNo,
      column: match.index + 1,
      phrase: match[0],
      message: canonical
        ? '少量有功能的中文破折号可以保留；只有密度异常或反复充当万能停顿时才需要修订。'
        : '检测到非标准破折号或双连字符；统一为有功能的中文破折号，或按语义改为动作、逗号、句号。',
      excerpt: compact(line),
    });
  }
}

function scanEmDashAbuse(findings, text) {
  const prose = String(text || '');
  const dashCount = (prose.match(/——|—|--+/g) || []).length;
  const proseCharCount = prose.replace(/\s/g, '').length;
  const reviewLimit = Math.max(5, Math.ceil((proseCharCount / 1000) * 2));
  const blockingLimit = Math.max(10, Math.ceil((proseCharCount / 1000) * 4));
  if (dashCount > reviewLimit) {
    const blocking = dashCount >= blockingLimit;
    findings.push({
      type: 'dash-density',
      severity: blocking ? 'blocking' : 'advisory',
      line: 1,
      column: 1,
      phrase: '——',
      count: dashCount,
      message: blocking
        ? `破折号密度明显失控：正文约 ${proseCharCount} 字出现 ${dashCount} 处，阻断线为 ${blockingLimit} 处；保留有功能用法，修订反复制造停顿的句子。`
        : `破折号密度偏高：正文约 ${proseCharCount} 字出现 ${dashCount} 处，建议人工确认是否都承担明确语义功能；本项不阻断。`,
      excerpt: `${dashCount} dash marks`,
    });
  }
  if (dashCount >= 5 && /(?:[\u3400-\u9FFF0-9A-Za-z]——){4,}[\u3400-\u9FFF0-9A-Za-z]?/.test(prose)) {
    findings.push({
      type: 'per-character-dash',
      severity: 'blocking',
      line: 1,
      column: 1,
      phrase: '逐字破折号化',
      count: dashCount,
      message: '逐字破折号化属于模型退化或坏稿污染，必须回炉重写，不能机械删除符号后继续。',
      excerpt: 'per-character dash pattern',
    });
  }
}

function scanCornerQuoteDensity(findings, text) {
  if (!(options.workType === 'shortform' || options.proseProfile === 'fiction')) return;
  const matches = Array.from(text.matchAll(/[「」『』]/g));
  if (matches.length < 8) return;
  const compactText = text.replace(/\s/g, '');
  const limit = Math.max(8, Math.ceil((compactText.length / 1000) * 4));
  if (matches.length <= limit) return;
  const loc = locateOffset(text, matches[0].index || 0);
  findings.push({
    type: 'corner-quote-density',
    severity: 'advisory',
    line: loc.line,
    column: loc.column,
    phrase: '「」',
    count: matches.length,
    message: '番茄/红果/黑岩短篇默认用中文弯引号“”；密集「」会显得盐言腔、翻译腔或 AI 格式腔。除盐言/港澳台/二次元/用户指定外，统一改为“”。',
    excerpt: `${matches.length} corner quote marks`,
  });
}

function scanNegativePositiveFlip(findings, line, lineNo) {
  const patterns = [
    /不是[^。！？\n]{1,80}?而是/g,
    /不是[^。！？\n]{1,80}?[，,；;：:]\s*是/g,
    /不是[^。！？\n]{1,80}?[。]\s*是/g,
  ];
  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(line)) !== null) {
      findings.push({
        type: 'negative-positive-flip',
        severity: 'blocking',
        line: lineNo,
        column: match.index + 1,
        phrase: match[0],
        message: '先否定再肯定是高风险 AI 模板句，改成直接动作、物件细节或后项事实。',
        excerpt: compact(line),
      });
    }
  }
}

function scanModelLoops(findings, text) {
  const compactText = text.replace(/[^\u4e00-\u9fff]+/g, '');
  const seen = new Set();
  for (let size = 2; size <= 6; size += 1) {
    for (let i = 0; i <= compactText.length - size; i += 1) {
      const phrase = compactText.slice(i, i + size);
      if (!/^[\u4e00-\u9fff]{2,6}$/.test(phrase) || seen.has(phrase)) continue;
      const repeat = countContiguousRepeats(compactText, phrase, i);
      if (repeat >= 8) {
        const loc = locatePhrase(text, phrase);
        findings.push({
          type: 'model-loop',
          severity: 'blocking',
          line: loc.line,
          column: loc.column,
          phrase,
          count: repeat,
          message: '检测到模型退化式重复词循环，不能进入正文/报告，需丢弃污染段并缩小范围重试。',
          excerpt: phrase.repeat(Math.min(repeat, 6)),
        });
        seen.add(phrase);
      }
    }
  }
}

function countContiguousRepeats(text, phrase, start) {
  let count = 0;
  let cursor = start;
  while (text.slice(cursor, cursor + phrase.length) === phrase) {
    count += 1;
    cursor += phrase.length;
  }
  return count;
}

function summarize(findings) {
  const summary = findings.reduce((acc, finding) => {
    acc.total = (acc.total || 0) + 1;
    acc[finding.severity] = (acc[finding.severity] || 0) + 1;
    acc.types[finding.type] = (acc.types[finding.type] || 0) + 1;
    return acc;
  }, { blocking: 0, strong: 0, advisory: 0, total: 0, types: {} });
  summary.clusterScore = clusterScore(findings);
  summary.clusterLevel = clusterLevel(findings);
  return summary;
}

function clusterScore(findings) {
  const weights = { blocking: 3, strong: 2, advisory: 1 };
  const typeCount = new Set(findings.map((finding) => finding.type)).size;
  const base = findings.reduce((sum, finding) => sum + (weights[finding.severity] || 1), 0);
  return base + Math.max(0, typeCount - 1);
}

function clusterLevel(findings) {
  const score = clusterScore(findings);
  const typeCount = new Set(findings.map((finding) => finding.type)).size;
  if (findings.some((finding) => finding.type === 'model-loop')) return 'critical';
  if (score >= 12 || typeCount >= 4) return 'high';
  if (score >= 6 || typeCount >= 2) return 'medium';
  if (score > 0) return 'low';
  return 'clean';
}

function qualityScore(findings) {
  const counts = findings.reduce((acc, finding) => {
    acc[finding.type] = (acc[finding.type] || 0) + 1;
    return acc;
  }, {});

  const score = {
    directness: clampQuality(10
      - 2 * (counts['template-shell'] || 0)
      - 2 * (counts['vague-attribution'] || 0)
      - 3 * (counts['knowledge-cutoff-disclaimer'] || 0)
      - 1 * (counts['ai-vocabulary'] || 0)),
    rhythm: clampQuality(10
      - 2 * (counts['em-dash'] || 0)
      - 2 * (counts['negative-positive-flip'] || 0)
      - 1 * (counts['fiction-cliche'] || 0)
      - 1 * (counts['corner-quote-density'] || 0)
      - 4 * (counts['model-loop'] || 0)),
    readerTrust: clampQuality(10
      - 2 * (counts['explanation-voice'] || 0)
      - 2 * (counts['generic-positive-conclusion'] || 0)
      - 1 * (counts['template-shell'] || 0)),
    authenticity: clampQuality(10
      - 2 * (counts['sycophantic-tone'] || 0)
      - 3 * (counts['tool-fingerprint-leak'] || 0)
      - 3 * (counts['placeholder-leak'] || 0)
      - 2 * (counts['engineering-leak'] || 0)
      - 2 * (counts['learned-project-rule'] || 0)),
    concision: clampQuality(10
      - 1 * (counts['ai-vocabulary'] || 0)
      - 1 * (counts['generic-emotion'] || 0)
      - 2 * (counts['template-shell'] || 0)
      - 1 * (counts['learned-project-rule'] || 0)),
  };
  score.total = score.directness + score.rhythm + score.readerTrust + score.authenticity + score.concision;
  score.max = 50;
  score.level = score.total >= 45 ? 'clean'
    : score.total >= 36 ? 'watch'
      : score.total >= 25 ? 'revise'
        : 'reject';
  return score;
}

function clampQuality(value) {
  return Math.max(0, Math.min(10, value));
}

function compact(s) {
  return s.trim().replace(/\s+/g, ' ').slice(0, 120);
}

function locatePhrase(text, phrase) {
  const index = text.indexOf(phrase);
  if (index < 0) return { line: 1, column: 1 };
  return locateOffset(text, index);
}

function locateOffset(text, index) {
  const prefix = text.slice(0, index);
  const lines = prefix.split(/\r?\n/);
  return { line: lines.length, column: lines[lines.length - 1].length + 1 };
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function printText(output) {
  console.log(`Anti-AI diagnosis (${output.workType}, proseProfile=${output.proseProfile})`);
  for (const file of output.files) {
    console.log(`\n${file.file}`);
    console.log(`summary: blocking=${file.summary.blocking}, strong=${file.summary.strong}, advisory=${file.summary.advisory}`);
    console.log(`qualityScore: ${file.qualityScore.total}/${file.qualityScore.max} (${file.qualityScore.level})`);
    for (const finding of file.findings) {
      console.log(`${finding.line}:${finding.column} [${finding.severity}] ${finding.type}: ${finding.message}`);
    }
  }
}

function die(message) {
  console.error(message);
  console.error(USAGE);
  process.exit(2);
}
