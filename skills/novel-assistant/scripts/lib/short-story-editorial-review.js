'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { collectShortReviewStaticEvidence } = require('./short-review-static-evidence');

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
  const staticEvidence = collectShortReviewStaticEvidence(storyPath);
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
    static_findings: staticEvidence.static_findings,
    detector_status: staticEvidence.detector_status,
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
    note: '结构信号和静态检测都是定位线索，不等于故事结论；总编辑必须引用正文原句作证。',
  };
}

function validateReaderResponseCard(card, evidencePack) {
  const findings = [];
  const readerResponse = card && card.reader_response ? card.reader_response : card;
  validateReaderResponse(readerResponse, evidencePack, findings);
  const storyText = readStoryTextFromPack(evidencePack);
  for (const quote of collectReaderEvidenceQuotes(readerResponse)) {
    if (quote && storyText && !normalizeText(storyText).includes(normalizeText(quote))) {
      findings.push(problem('evidence_quote', `正文中找不到专业读者引用：${quote.slice(0, 40)}`));
    }
  }
  return findings.length ? { status: 'invalid', findings } : { status: 'valid', findings: [] };
}

function validateEditorialReviewCard(card, evidencePack, options = {}) {
  const findings = [];
  if (!card || typeof card !== 'object' || Array.isArray(card)) return invalid('review_card_not_object');
  if (String(card.schemaVersion || '') !== SCHEMA_VERSION) findings.push(problem('schemaVersion', '审阅卡版本不匹配。'));
  if (String(card.workflow_id || '') !== String(evidencePack.workflow_id || '')) findings.push(problem('workflow_id', '审阅卡任务身份不匹配。'));
  if (String(card.story_sha256 || '') !== String(evidencePack.story_sha256 || '')) findings.push(problem('story_sha256', '审阅卡对应的正文已经变化。'));
  if (!VALID_DECISIONS.has(String(card.decision || ''))) findings.push(problem('decision', 'decision 只能是 pass 或 revise。'));

  const readerResponse = options.readerResponse || card.reader_response;
  validateReaderResponse(readerResponse, evidencePack, findings);

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
    for (const field of ['character', 'desire', 'independent_stake', 'active_action', 'cost', 'relationship_effect', 'change', 'verdict']) {
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
    for (const field of ['identity_or_trait', 'identity_type', 'setup_quote', 'payoff_quote', 'ongoing_participation', 'verdict']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`identity_payoff_matrix.${field}`, '身份效用矩阵字段缺失。'));
    }
    if ((row || {}).verdict && !VALID_VERDICTS.has(String((row || {}).verdict))) findings.push(problem('identity_payoff_matrix.verdict', '身份效用结论非法。'));
  }

  const revealMatrix = Array.isArray(card.reveal_aftershock_matrix) ? card.reveal_aftershock_matrix : [];
  if (!revealMatrix.length && !String(card.reveal_aftershock_not_applicable_reason || '').trim()) {
    findings.push(problem('reveal_aftershock_matrix', '必须检查关键揭示是否改变后续行动、关系或代价；确实没有揭示时说明理由。'));
  }
  for (const row of revealMatrix) {
    for (const field of ['reveal_section_index', 'revelation', 'immediate_consequence', 'downstream_change', 'verdict']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`reveal_aftershock_matrix.${field}`, '揭示余震矩阵字段缺失。'));
    }
    if (!Array.isArray((row || {}).evidence_quotes) || !(row || {}).evidence_quotes.length) findings.push(problem('reveal_aftershock_matrix.evidence_quotes', '揭示余震判断必须同时引用揭示与后续影响证据。'));
    if ((row || {}).verdict && !VALID_VERDICTS.has(String((row || {}).verdict))) findings.push(problem('reveal_aftershock_matrix.verdict', '揭示余震结论非法。'));
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
  for (const quote of collectEditorialEvidenceQuotes(card)) {
    if (quote && storyText && !normalizeText(storyText).includes(normalizeText(quote))) {
      findings.push(problem('evidence_quote', `正文中找不到引用：${quote.slice(0, 40)}`));
    }
  }
  return findings.length ? { status: 'invalid', findings } : { status: 'valid', findings: [] };
}

function validateReaderResponse(readerResponse, evidencePack, findings) {
  if (!readerResponse || typeof readerResponse !== 'object' || Array.isArray(readerResponse)) {
    findings.push(problem('reader_response', '缺少专业读者盲读结果。'));
    return;
  }
  const profile = readerResponse.reader_profile || {};
  if (!String(profile.target_platform || '').trim()) findings.push(problem('reader_response.reader_profile.target_platform', '缺少目标平台；未知时写未确认。'));
  if (!String(profile.platform_mode || '').trim()) findings.push(problem('reader_response.reader_profile.platform_mode', '缺少读者平台画像。'));
  if (!Array.isArray(profile.genre_lens)) findings.push(problem('reader_response.reader_profile.genre_lens', '题材观察重点必须是数组。'));
  if (!Array.isArray(profile.style_lens)) findings.push(problem('reader_response.reader_profile.style_lens', '文风观察重点必须是数组。'));
  if (!String(profile.reading_scene || '').trim()) findings.push(problem('reader_response.reader_profile.reading_scene', '缺少阅读场景。'));
  if (!String(profile.profile_basis || '').trim()) findings.push(problem('reader_response.reader_profile.profile_basis', '缺少读者画像依据。'));
  const platformUnconfirmed = /未确认|未知/u.test(String(profile.target_platform || ''));
  if (platformUnconfirmed && String(profile.platform_mode || '') !== 'general_fiction') {
    findings.push(problem('reader_response.reader_profile.platform_mode', '目标平台未确认时只能使用 general_fiction，不能从正文或目录反推平台。'));
  }
  if (/目录推断|书名推断|标题推断|模型常识/u.test(String(profile.profile_basis || ''))) {
    findings.push(problem('reader_response.reader_profile.profile_basis', '读者画像依据不得来自目录、书名、标题或模型常识推断。'));
  }

  const expectedSections = new Set((evidencePack.section_metrics || []).map(item => Number(item.section_index)));
  const sectionRows = Array.isArray(readerResponse.section_reader_response) ? readerResponse.section_reader_response : [];
  const covered = new Set();
  for (const row of sectionRows) {
    const index = Number((row || {}).section_index);
    if (expectedSections.has(index)) covered.add(index);
    for (const field of ['engagement', 'felt_emotion', 'reader_question', 'evidence_quote']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`reader_response.section_reader_response.${index || '?'}.${field}`, '逐节读者反应字段缺失。'));
    }
    if (!['engaged', 'wavering', 'drop_risk'].includes(String((row || {}).engagement || ''))) {
      findings.push(problem(`reader_response.section_reader_response.${index || '?'}.engagement`, 'engagement 非法。'));
    }
  }
  for (const index of expectedSections) {
    if (!covered.has(index)) findings.push(problem('reader_response.section_reader_response', `专业读者缺少第${index}节的阅读反应。`));
  }
  if (!Array.isArray(readerResponse.drop_off_points)) findings.push(problem('reader_response.drop_off_points', '掉线点必须是数组，可为空。'));
  const impressions = Array.isArray(readerResponse.character_impressions) ? readerResponse.character_impressions : [];
  if (!impressions.length) findings.push(problem('reader_response.character_impressions', '至少记录主角的人物印象变化。'));
  for (const row of impressions) {
    for (const field of ['character', 'first_impression', 'later_impression', 'trust_change']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`reader_response.character_impressions.${field}`, '人物印象字段缺失。'));
    }
    if (!Array.isArray((row || {}).evidence_quotes) || !(row || {}).evidence_quotes.length) findings.push(problem('reader_response.character_impressions.evidence_quotes', '人物印象必须引用正文证据。'));
  }
  const identityContinuity = Array.isArray(readerResponse.identity_continuity) ? readerResponse.identity_continuity : [];
  if ((evidencePack.identity_hints || []).length && !identityContinuity.length && !String(readerResponse.identity_continuity_not_applicable_reason || '').trim()) {
    findings.push(problem('reader_response.identity_continuity', '设定包含职业、能力、缺陷或身份，专业读者必须记录它在后文是否仍可感。'));
  }
  for (const row of identityContinuity) {
    for (const field of ['identity_or_trait', 'visibility', 'reader_effect']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`reader_response.identity_continuity.${field}`, '身份连续性字段缺失。'));
    }
    if (!['present', 'fading', 'abandoned'].includes(String((row || {}).visibility || ''))) findings.push(problem('reader_response.identity_continuity.visibility', 'visibility 非法。'));
    if (!Array.isArray((row || {}).evidence_quotes) || (row || {}).evidence_quotes.length < 2) findings.push(problem('reader_response.identity_continuity.evidence_quotes', '身份连续性至少需要前后两处正文证据。'));
  }
  const supportingReality = Array.isArray(readerResponse.supporting_character_reality) ? readerResponse.supporting_character_reality : [];
  if ((evidencePack.character_hints || []).length >= 2 && !supportingReality.length && !String(readerResponse.supporting_character_not_applicable_reason || '').trim()) {
    findings.push(problem('reader_response.supporting_character_reality', '存在多个重要人物时，专业读者必须记录至少一个配角是活人还是功能件。'));
  }
  for (const row of supportingReality) {
    for (const field of ['character', 'felt_status', 'apparent_want', 'decisive_choice', 'relationship_effect']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`reader_response.supporting_character_reality.${field}`, '配角真实感字段缺失。'));
    }
    if (!['alive', 'thin', 'functional'].includes(String((row || {}).felt_status || ''))) findings.push(problem('reader_response.supporting_character_reality.felt_status', 'felt_status 非法。'));
    if (!Array.isArray((row || {}).evidence_quotes) || !(row || {}).evidence_quotes.length) findings.push(problem('reader_response.supporting_character_reality.evidence_quotes', '配角真实感必须引用正文证据。'));
  }
  const revealAftershock = Array.isArray(readerResponse.reveal_aftershock) ? readerResponse.reveal_aftershock : [];
  if (expectedSections.size >= 3 && !revealAftershock.length && !String(readerResponse.reveal_aftershock_not_applicable_reason || '').trim()) {
    findings.push(problem('reader_response.reveal_aftershock', '多节故事必须记录至少一次关键揭示之后，读者是否看见行动、关系或代价发生变化。'));
  }
  for (const row of revealAftershock) {
    for (const field of ['reveal_section_index', 'revelation', 'immediate_reader_shift', 'consequence_seen']) {
      if (!String((row || {})[field] || '').trim()) findings.push(problem(`reader_response.reveal_aftershock.${field}`, '揭示余震字段缺失。'));
    }
    if (!['yes', 'partial', 'no'].includes(String((row || {}).consequence_seen || ''))) findings.push(problem('reader_response.reveal_aftershock.consequence_seen', 'consequence_seen 非法。'));
    if (!Array.isArray((row || {}).later_evidence_quotes) || !(row || {}).later_evidence_quotes.length) findings.push(problem('reader_response.reveal_aftershock.later_evidence_quotes', '揭示余震必须引用后续正文证据。'));
  }
  const promise = readerResponse.promise_response || {};
  for (const field of ['title_expectation', 'payoff_status', 'reader_aftertaste']) {
    if (!String(promise[field] || '').trim()) findings.push(problem(`reader_response.promise_response.${field}`, '标题承诺反应字段缺失。'));
  }
  if (!Array.isArray(promise.evidence_quotes) || !promise.evidence_quotes.length) findings.push(problem('reader_response.promise_response.evidence_quotes', '标题兑现判断必须引用正文证据。'));
  const finalState = readerResponse.final_reader_state || {};
  for (const field of ['would_continue_or_recommend', 'strongest_pull', 'biggest_resistance']) {
    if (!String(finalState[field] || '').trim()) findings.push(problem(`reader_response.final_reader_state.${field}`, '终读反应字段缺失。'));
  }
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

function collectReaderEvidenceQuotes(reader) {
  const quotes = [];
  for (const row of arrayValues((reader || {}).section_reader_response)) quotes.push((row || {}).evidence_quote);
  for (const row of arrayValues((reader || {}).drop_off_points)) quotes.push((row || {}).evidence_quote);
  for (const row of arrayValues((reader || {}).character_impressions)) quotes.push(...arrayValues((row || {}).evidence_quotes));
  for (const row of arrayValues((reader || {}).identity_continuity)) quotes.push(...arrayValues((row || {}).evidence_quotes));
  for (const row of arrayValues((reader || {}).supporting_character_reality)) quotes.push(...arrayValues((row || {}).evidence_quotes));
  for (const row of arrayValues((reader || {}).reveal_aftershock)) quotes.push(...arrayValues((row || {}).later_evidence_quotes));
  quotes.push(...arrayValues((((reader || {}).promise_response) || {}).evidence_quotes));
  return quotes.map(value => String(value || '').trim()).filter(Boolean);
}

function collectEditorialEvidenceQuotes(card) {
  const quotes = [];
  const opening = card.opening_assessment || {};
  const ending = card.climax_ending_assessment || {};
  quotes.push(opening.evidence_quote, ending.climax_quote, ending.ending_quote);
  for (const row of arrayValues(card.section_function_matrix)) quotes.push((row || {}).evidence_quote);
  for (const row of arrayValues(card.character_arc_matrix)) quotes.push(...arrayValues((row || {}).evidence_quotes));
  for (const row of arrayValues(card.identity_payoff_matrix)) quotes.push((row || {}).setup_quote, (row || {}).payoff_quote);
  for (const row of arrayValues(card.reveal_aftershock_matrix)) quotes.push(...arrayValues((row || {}).evidence_quotes));
  for (const row of arrayValues(card.findings)) quotes.push((row || {}).evidence_quote);
  return quotes.map(value => String(value || '').trim()).filter(Boolean);
}

function readStoryTextFromPack(pack) {
  const file = String(pack.__story_file || '');
  return file && fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
}

function arrayValues(value) { return Array.isArray(value) ? value : []; }

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
  validateReaderResponseCard,
  validateEditorialReviewCard,
};
