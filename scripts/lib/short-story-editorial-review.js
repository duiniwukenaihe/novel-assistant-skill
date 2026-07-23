'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const SCHEMA_VERSION = '1.0.0';
const VALID_DECISIONS = new Set(['pass', 'revise']);
const VALID_VERDICTS = new Set(['pass', 'concern', 'fail', 'not_applicable']);
const VALID_SEVERITIES = new Set(['S1', 'S2', 'S3', 'S4']);

function buildShortStoryEvidencePack(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const storyPath = path.resolve(root, options.storyPath || '正文.md');
  if (!storyPath.startsWith(`${root}${path.sep}`) || !fs.existsSync(storyPath)) {
    return { status: 'short_story_missing', story_path: options.storyPath || '正文.md' };
  }
  const storyText = fs.readFileSync(storyPath, 'utf8');
  const sections = splitSections(storyText);
  if (!sections.length) return { status: 'short_story_sections_missing', story_path: relative(root, storyPath) };

  const lengths = sections.map(section => section.cjk_chars);
  const median = medianNumber(lengths);
  const firstLength = lengths[0] || 0;
  const tailLengths = lengths.slice(Math.max(1, lengths.length - 3));
  const earlierLengths = lengths.slice(0, Math.max(1, lengths.length - tailLengths.length));
  const tailMedian = medianNumber(tailLengths);
  const earlierMedian = medianNumber(earlierLengths);
  const structuralSignals = [];
  if (sections.length >= 3 && median > 0 && firstLength > median * 1.35) {
    structuralSignals.push(signal('opening_overweight', '开篇篇幅明显高于全篇中位数，检查是否用叙述集中塞入背景。', { observed: firstLength, baseline: median }));
  }
  if (sections.length >= 5 && earlierMedian > 0 && tailMedian < earlierMedian * 0.72) {
    structuralSignals.push(signal('tail_weight_collapse', '后段篇幅明显低于前段，检查高潮与结尾是否被压缩。', { observed: tailMedian, baseline: earlierMedian }));
  }
  if (sections.length >= 3 && median > 0 && lengths[lengths.length - 1] < median * 0.68) {
    structuralSignals.push(signal('ending_underweight', '结尾篇幅明显低于作品基准，检查责任后果、关系余波与标题兑现。', { observed: lengths[lengths.length - 1], baseline: median }));
  }
  for (let index = 1; index < lengths.length; index += 1) {
    const previous = lengths[index - 1];
    const current = lengths[index];
    const base = Math.max(previous, current, 1);
    if (Math.abs(previous - current) / base > 0.42) {
      structuralSignals.push(signal('adjacent_weight_jump', `第${index}节与第${index + 1}节篇幅跳变较大，检查剧情功能是否失衡。`, { sections: [index, index + 1], values: [previous, current] }));
    }
  }

  const settingText = readText(path.join(root, '设定.md'));
  const outlineText = readText(path.join(root, '小节大纲.md'));
  const characterHints = extractCharacterHints(settingText, sections);
  const identityHints = extractIdentityHints(settingText);
  return {
    schemaVersion: SCHEMA_VERSION,
    status: 'ok',
    workflow_id: String(options.workflowId || ''),
    generated_at: new Date().toISOString(),
    story_path: relative(root, storyPath),
    story_sha256: hashText(storyText),
    story_cjk_chars: countCjk(storyText),
    section_count: sections.length,
    section_length_median: median,
    section_metrics: sections.map((section, index) => ({
      section_index: section.section_index,
      title: section.title,
      cjk_chars: section.cjk_chars,
      share: round(section.cjk_chars / Math.max(1, lengths.reduce((sum, value) => sum + value, 0)), 4),
      relative_to_median: median > 0 ? round(section.cjk_chars / median, 3) : 0,
      opening_excerpt: excerpt(section.body, 180, false),
      ending_excerpt: excerpt(section.body, 180, true),
    })),
    structural_signals: structuralSignals,
    character_hints: characterHints,
    identity_hints: identityHints,
    planning_excerpts: {
      setting: excerpt(settingText, 900, false),
      outline: excerpt(outlineText, 1400, false),
    },
    review_dimensions: [
      'opening_dramatization_and_information_load',
      'section_function_and_weight_curve',
      'supporting_character_agency',
      'opposition_motive_and_dual_pressure',
      'protagonist_identity_setup_and_payoff',
      'climax_runway_aftermath_and_title_promise',
    ],
    note: '结构信号是定位线索，不等于故事结论；总编辑必须引用正文原句作证。',
  };
}

function validateEditorialReviewCard(card, evidencePack) {
  const findings = [];
  if (!card || typeof card !== 'object' || Array.isArray(card)) return invalid('review_card_not_object');
  if (String(card.schemaVersion || '') !== SCHEMA_VERSION) findings.push(problem('schemaVersion', '审阅卡版本不匹配。'));
  if (String(card.workflow_id || '') !== String(evidencePack.workflow_id || '')) findings.push(problem('workflow_id', '审阅卡任务身份不匹配。'));
  if (String(card.story_sha256 || '') !== String(evidencePack.story_sha256 || '')) findings.push(problem('story_sha256', '审阅卡对应的正文已经变化。'));
  if (!VALID_DECISIONS.has(String(card.decision || ''))) findings.push(problem('decision', 'decision 只能是 pass 或 revise。'));

  validateAssessment(card.opening_assessment, 'opening_assessment', ['verdict', 'evidence_quote', 'reason'], findings);
  validateAssessment(card.climax_ending_assessment, 'climax_ending_assessment', ['verdict', 'climax_quote', 'ending_quote', 'reason'], findings);

  const sectionMatrix = Array.isArray(card.section_function_matrix) ? card.section_function_matrix : [];
  const expectedSections = new Set((evidencePack.section_metrics || []).map(item => Number(item.section_index)));
  const coveredSections = new Set();
  for (const row of sectionMatrix) {
    const sectionIndex = Number((row || {}).section_index);
    if (expectedSections.has(sectionIndex)) coveredSections.add(sectionIndex);
    for (const field of ['structural_role', 'function_verdict', 'evidence_quote']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`section_function_matrix.${sectionIndex || '?'}.${field}`, '小节功能矩阵字段缺失。'));
    }
    if ((row || {}).function_verdict && !VALID_VERDICTS.has(String((row || {}).function_verdict))) findings.push(problem(`section_function_matrix.${sectionIndex || '?'}.function_verdict`, '小节结论非法。'));
  }
  for (const sectionIndex of expectedSections) {
    if (!coveredSections.has(sectionIndex)) findings.push(problem('section_function_matrix', `缺少第${sectionIndex}节的功能验收。`));
  }

  const characterMatrix = Array.isArray(card.character_arc_matrix) ? card.character_arc_matrix : [];
  if (!characterMatrix.length) findings.push(problem('character_arc_matrix', '至少验收主角与一个承担剧情功能的重要角色。'));
  if ((evidencePack.character_hints || []).length >= 2 && characterMatrix.length < 2) findings.push(problem('character_arc_matrix', '设定中存在多个重要人物，不能只验收主角。'));
  for (const row of characterMatrix) {
    for (const field of ['character', 'desire', 'active_action', 'cost', 'change', 'verdict']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`character_arc_matrix.${field}`, '人物弧线矩阵字段缺失。'));
    }
    if (!Array.isArray((row || {}).evidence_quotes) || !(row || {}).evidence_quotes.length) findings.push(problem('character_arc_matrix.evidence_quotes', '人物判断必须引用正文证据。'));
    if ((row || {}).verdict && !VALID_VERDICTS.has(String((row || {}).verdict))) findings.push(problem('character_arc_matrix.verdict', '人物结论非法。'));
  }

  const identityMatrix = Array.isArray(card.identity_payoff_matrix) ? card.identity_payoff_matrix : [];
  if (!identityMatrix.length && !String(card.identity_not_applicable_reason || '').trim()) {
    findings.push(problem('identity_payoff_matrix', '必须检查主角职业、能力、缺陷或身份设定是否在后文持续参与；确实不适用时说明理由。'));
  }
  for (const row of identityMatrix) {
    for (const field of ['identity_or_trait', 'setup_quote', 'payoff_quote', 'verdict']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`identity_payoff_matrix.${field}`, '身份效用矩阵字段缺失。'));
    }
    if ((row || {}).verdict && !VALID_VERDICTS.has(String((row || {}).verdict))) findings.push(problem('identity_payoff_matrix.verdict', '身份效用结论非法。'));
  }

  const reviewFindings = Array.isArray(card.findings) ? card.findings : [];
  for (const item of reviewFindings) {
    for (const field of ['code', 'severity', 'scope', 'evidence_quote', 'repair_direction']) {
      if (!String((item || {})[field] || '').trim()) findings.push(problem(`findings.${field}`, '问题项字段缺失。'));
    }
    if (!VALID_SEVERITIES.has(String((item || {}).severity || ''))) findings.push(problem('findings.severity', 'severity 只能是 S1-S4。'));
  }
  if (String(card.decision || '') === 'pass' && reviewFindings.some(item => ['S1', 'S2'].includes(String((item || {}).severity || '')))) {
    findings.push(problem('decision', '存在 S1/S2 时不能判定 pass。'));
  }
  if (String(card.decision || '') === 'revise' && !reviewFindings.length) findings.push(problem('findings', 'revise 必须给出可执行问题项。'));

  const storyText = readStoryTextFromPack(evidencePack);
  for (const quote of collectEvidenceQuotes(card)) {
    if (quote && storyText && !normalizeText(storyText).includes(normalizeText(quote))) {
      findings.push(problem('evidence_quote', `正文中找不到引用：${quote.slice(0, 40)}`));
    }
  }
  return findings.length ? { status: 'invalid', findings } : { status: 'valid', findings: [] };
}

function splitSections(text) {
  const source = String(text || '');
  const matches = [...source.matchAll(/^##\s+第\s*0*(\d+)\s*节(?:[：:·\s]+([^\n]+))?\s*$/gmu)];
  return matches.map((match, index) => {
    const start = match.index + match[0].length;
    const end = index + 1 < matches.length ? matches[index + 1].index : source.length;
    const body = source.slice(start, end).trim();
    return {
      section_index: Number(match[1]),
      title: String(match[2] || '').trim(),
      body,
      cjk_chars: countCjk(body),
    };
  });
}

function extractCharacterHints(settingText, sections) {
  const candidates = new Set();
  const source = String(settingText || '');
  for (const match of source.matchAll(/(?:主角|人物|角色|姓名|母亲|父亲|哥哥|姐姐|嫂子|舍友)[：:]\s*([\u3400-\u9fff·]{2,8})/gu)) candidates.add(match[1]);
  for (const match of source.matchAll(/^#{2,4}\s+([\u3400-\u9fff·]{2,8})(?:\s|$)/gmu)) candidates.add(match[1]);
  return [...candidates].slice(0, 16).map(name => ({
    character: name,
    section_mentions: sections.filter(section => section.body.includes(name)).map(section => section.section_index),
    heuristic_only: true,
  }));
}

function extractIdentityHints(settingText) {
  const lines = String(settingText || '').split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  return lines
    .filter(line => /(?:身份|职业|缺陷|渴望|恐惧|能力|特长|主播|记者|律师|医生|学生|员工)/u.test(line))
    .slice(0, 20)
    .map(line => line.slice(0, 240));
}

function validateAssessment(value, prefix, fields, findings) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    findings.push(problem(prefix, '验收块缺失。'));
    return;
  }
  for (const field of fields) if (!String(value[field] || '').trim()) findings.push(problem(`${prefix}.${field}`, '验收字段缺失。'));
  if (value.verdict && !VALID_VERDICTS.has(String(value.verdict))) findings.push(problem(`${prefix}.verdict`, 'verdict 非法。'));
}

function collectEvidenceQuotes(card) {
  const quotes = [];
  const opening = card.opening_assessment || {};
  const ending = card.climax_ending_assessment || {};
  quotes.push(opening.evidence_quote, ending.climax_quote, ending.ending_quote);
  for (const row of card.section_function_matrix || []) quotes.push((row || {}).evidence_quote);
  for (const row of card.character_arc_matrix || []) quotes.push(...((row || {}).evidence_quotes || []));
  for (const row of card.identity_payoff_matrix || []) quotes.push((row || {}).setup_quote, (row || {}).payoff_quote);
  for (const row of card.findings || []) quotes.push((row || {}).evidence_quote);
  return quotes.map(value => String(value || '').trim()).filter(Boolean);
}

function readStoryTextFromPack(pack) {
  const file = String(pack.__story_file || '');
  return file && fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
}

function attachEvidenceRuntime(pack, storyFile) {
  return Object.defineProperty(pack, '__story_file', { value: storyFile, enumerable: false });
}

function signal(code, message, details) { return { code, message, ...details }; }
function problem(field, message) { return { field, message }; }
function invalid(code) { return { status: 'invalid', findings: [problem('review_card', code)] }; }
function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; } }
function countCjk(text) { return (String(text || '').match(/[\u3400-\u9fff]/g) || []).length; }
function medianNumber(values) { const sorted = [...values].sort((a, b) => a - b); if (!sorted.length) return 0; const middle = Math.floor(sorted.length / 2); return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2); }
function excerpt(text, limit, fromEnd) { const compact = String(text || '').replace(/\s+/g, ' ').trim(); return fromEnd ? compact.slice(Math.max(0, compact.length - limit)) : compact.slice(0, limit); }
function normalizeText(text) { return String(text || '').replace(/[\s\u3000]+/g, '').replace(/[“”「」『』]/g, '"'); }
function round(value, digits) { const factor = 10 ** digits; return Math.round(value * factor) / factor; }
function hashText(value) { return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex'); }
function relative(root, file) { return path.relative(root, file).replace(/\\/g, '/'); }

module.exports = {
  SCHEMA_VERSION,
  attachEvidenceRuntime,
  buildShortStoryEvidencePack,
  splitSections,
  validateEditorialReviewCard,
};
