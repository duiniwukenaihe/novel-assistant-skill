'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const {
  analyzeShortOutlineNarrativeQuality,
  inferPlannedSections,
  outlineSections,
  sectionRole,
  hookAnchorId,
} = require('./short-plan-contract');

const NARRATIVE_FIELDS = Object.freeze([
  ['Q01', 'handoff_in', ['承接上节', '上节承接', '承接与场景动作']],
  ['V01', 'pressure_shift', ['压力变化', '局势起伏', '情绪起伏', '可见阻力与压力变化']],
  ['A01', 'scene_action', ['场景动作', '可见行动', '关键动作', '承接与场景动作']],
  ['O01', 'visible_opposition', ['可见阻力', '对手施压', '场景阻力', '可见阻力与压力变化']],
  ['P01', 'section_payoff', ['本节兑现', '信息兑现', '反转兑现', '局势变化', '主角选择与兑现']],
  ['R01', 'relationship_change', ['关系变化', '人物关系变化', '关系后果、代价与钩子', '关系后果、代价和钩子']],
  ['K01', 'cost_escalation', ['代价升级', '选择代价', '即时代价', '高潮代价', '关系后果、代价与钩子', '关系后果、代价和钩子']],
  ['I01', 'opening_hook', ['开篇钩子', '入场钩子']],
  ['M01', 'story_promise', ['故事承诺', '核心承诺']],
  ['X01', 'core_payoff', ['核心承诺兑现', '核心爆点兑现', '高潮兑现']],
  ['D01', 'decisive_action', ['决定性行动', '高潮行动']],
  ['N01', 'consequences', ['现实后果', '责任分配', '代价收束']],
  ['L01', 'relationship_closure', ['关系收束', '人物关系收束']],
  ['T01', 'theme_callback', ['主题回扣', '结尾回扣', '意义落点', '主题回扣与结尾钩子']],
]);

function buildShortSectionOutlineContract(projectRoot, sectionIndex) {
  const root = path.resolve(projectRoot || '');
  const index = Number(sectionIndex || 0);
  if (!Number.isInteger(index) || index < 1) return invalid('section_index_invalid');
  const outlinePath = path.join(root, '小节大纲.md');
  if (!fs.existsSync(outlinePath) || !fs.statSync(outlinePath).isFile()) return invalid('outline_missing');
  const outlineText = fs.readFileSync(outlinePath, 'utf8');
  const sections = outlineSections(outlineText);
  const section = sections.find((item) => item.number === index);
  if (!section) return invalid('outline_section_missing');

  const settingText = readText(path.join(root, '设定.md'));
  const state = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const plannedSections = inferPlannedSections(settingText, state, sections);
  const role = sectionRole(index, plannedSections);
  const narrative = analyzeShortOutlineNarrativeQuality(outlineText, plannedSections);
  const narrativeFindings = narrative.findings.filter((item) => Number(item.section) === index);
  if (narrativeFindings.length) {
    return {
      ...invalid('outline_section_narrative_underfilled'),
      section_index: index,
      section_role: role,
      findings: narrativeFindings,
    };
  }

  const title = ((section.body.match(/^#{1,6}\s*第\s*0*\d+\s*节[：:]?\s*([^\n]*)$/mu) || [])[1] || '').trim();
  const sceneAction = labeledValue(section.body, ['场景动作', '可见行动', '关键动作', '承接与场景动作']);
  const opposition = labeledValue(section.body, ['可见阻力', '对手施压', '场景阻力', '可见阻力与压力变化']);
  const choice = labeledValue(section.body, ['角色选择', '主角选择', '主角选择与兑现']);
  const consequence = labeledValue(section.body, ['关系后果', '关系后果、代价与钩子', '关系后果、代价和钩子']);
  const structure = labeledValue(section.body, ['结构功能'])
    || [sceneAction, opposition, choice, consequence].filter(Boolean).join('；');
  const numberedBeats = numberedBlock(section.body, '子事件');
  const beats = numberedBeats.length >= 2
    ? numberedBeats
    : [sceneAction, opposition, choice, consequence].filter(Boolean);
  const hook = labeledValue(section.body, ['节尾钩子', '结尾回扣', '代价收束', '关系后果、代价与钩子', '关系后果、代价和钩子', '主题回扣与结尾钩子']);
  const causality = labeledValue(section.body, ['因果链', '因果推进']);
  const obligations = [];
  if (structure) obligations.push(obligation('S00', 'structure', structure, false));
  beats.forEach((text, offset) => obligations.push(obligation(`B${String(offset + 1).padStart(2, '0')}`, 'beat', text, true)));
  if (choice) obligations.push(obligation('C01', 'choice', choice, true));
  if (hook) obligations.push(obligation('H01', 'hook', hook, true));
  if (sceneAction) obligations.push(obligation('A01', 'scene_action', sceneAction, true));
  for (const [id, kind, labels] of NARRATIVE_FIELDS) {
    if (id === 'A01') continue;
    const value = labeledValue(section.body, labels);
    if (value) obligations.push(obligation(id, kind, value, true));
  }
  if (!structure || beats.length < 2 || !hook) {
    return {
      ...invalid('outline_section_underfilled'),
      section_index: index,
      missing: [!structure ? 'structure' : '', beats.length < 2 ? 'beats' : '', !hook ? 'hook' : ''].filter(Boolean),
    };
  }
  const blockDigest = sha256(section.body);
  return {
    status: 'current',
    schema_version: '1.0.0',
    outline_path: '小节大纲.md',
    outline_digest: sha256(outlineText),
    section_index: index,
    section_title: title,
    section_block_digest: blockDigest,
    contract_digest: sha256(JSON.stringify({ index, role, title, structure, beats, choice, hook, causality, obligations })),
    planned_sections: plannedSections,
    section_role: role,
    incoming_hook_anchor: index > 1 ? hookAnchorId(index - 1) : '',
    outgoing_hook_anchor: role === 'ending' ? '' : hookAnchorId(index),
    structure_function: structure,
    causality,
    obligations,
  };
}

function validateBriefOutlineCoverage(briefText, contract) {
  if (!contract || contract.status !== 'current') return { status: 'blocked', findings: [{ code: 'outline_contract_missing' }] };
  const source = String(briefText || '');
  const mappingSection = headingSection(source, /大纲覆盖映射/u);
  const actionSection = headingSection(source, /因果(?:动作|链)?|动作链|情节节拍|事件节拍/u);
  const mappings = new Map();
  for (const line of mappingSection.split(/\r?\n/u)) {
    const match = line.match(/^\s*[-*]\s*([A-Z]\d{2})\s*[：:]\s*(.+?)\s*$/u);
    if (match) mappings.set(match[1], match[2]);
  }
  const findings = [];
  if (!mappingSection) {
    const coverage = contract.obligations.map((item) => ({
      id: item.id,
      kind: item.kind,
      status: sameMeaningFingerprint(source, item.source_text) ? 'pass' : 'missing',
    }));
    const atomicCovered = coverage
      .filter((item) => item.kind !== 'structure')
      .every((item) => item.status === 'pass');
    if (atomicCovered) {
      const structure = coverage.find((item) => item.kind === 'structure');
      if (structure) structure.status = 'pass';
    }
    for (const item of coverage.filter(row => row.status !== 'pass')) {
      findings.push({ code: 'outline_obligation_missing', obligation_id: item.id, kind: item.kind });
    }
    return {
      status: findings.length ? 'blocked' : 'pass',
      coverage_mode: 'semantic_sidecar',
      contract_digest: contract.contract_digest,
      section_block_digest: contract.section_block_digest,
      obligation_count: contract.obligations.length,
      coverage,
      findings,
    };
  }
  for (const item of contract.obligations) {
    const mapped = mappings.get(item.id) || '';
    if (!mapped) {
      findings.push({ code: 'outline_obligation_missing', obligation_id: item.id, kind: item.kind });
      continue;
    }
    if (!sameMeaningFingerprint(mapped, item.source_text)) {
      findings.push({ code: 'outline_obligation_changed', obligation_id: item.id, kind: item.kind });
    }
    if (item.required_in_draft && !new RegExp(`\\[${item.id}\\]`, 'u').test(actionSection)) {
      findings.push({ code: 'outline_obligation_not_scheduled', obligation_id: item.id, kind: item.kind });
    }
  }
  return {
    status: findings.length ? 'blocked' : 'pass',
    coverage_mode: 'explicit_mapping',
    contract_digest: contract.contract_digest,
    section_block_digest: contract.section_block_digest,
    obligation_count: contract.obligations.length,
    coverage: contract.obligations.map(item => ({
      id: item.id,
      kind: item.kind,
      status: findings.some(finding => finding.obligation_id === item.id) ? 'blocked' : 'pass',
    })),
    findings,
  };
}

function validateDraftOutlineCoverage(review, contract, draftText) {
  if (!contract || contract.status !== 'current') return [{ code: 'outline_contract_missing' }];
  const source = normalizeText(draftText);
  const candidate = review && typeof review === 'object' && !Array.isArray(review) ? review : {};
  const findings = [];
  if (String(candidate.outline_contract_digest || '') !== contract.contract_digest) {
    findings.push({ code: 'outline_contract_digest_mismatch' });
  }
  const rows = Array.isArray(candidate.outline_coverage) ? candidate.outline_coverage : [];
  const byId = new Map(rows.map((item) => [String((item || {}).id || ''), item || {}]));
  const usedQuotes = new Map();
  for (const obligation of contract.obligations.filter((item) => item.required_in_draft)) {
    const row = byId.get(obligation.id);
    if (!row) {
      findings.push({ code: 'draft_outline_obligation_missing', obligation_id: obligation.id });
      continue;
    }
    if (String(row.status || '') !== 'pass') {
      findings.push({ code: 'draft_outline_obligation_revise', obligation_id: obligation.id });
      continue;
    }
    const quote = normalizeText(row.evidence_quote || '');
    if (quote.length < 4 || !source.includes(quote)) {
      findings.push({ code: 'draft_outline_evidence_not_found', obligation_id: obligation.id });
      continue;
    }
    const count = Number(usedQuotes.get(quote) || 0) + 1;
    usedQuotes.set(quote, count);
    if (count > 2) findings.push({ code: 'draft_outline_evidence_reused', obligation_id: obligation.id });
  }
  return findings;
}

function renderOutlineCoverageTemplate(contract) {
  if (!contract || contract.status !== 'current') return '';
  const lines = ['## 大纲覆盖映射'];
  for (const item of contract.obligations) lines.push(`- ${item.id}：${item.source_text}`);
  lines.push('', '## 因果动作链');
  lines.push(contract.obligations.filter((item) => item.required_in_draft).map((item) => `[${item.id}]`).join(' -> '));
  return lines.join('\n');
}

function obligation(id, kind, sourceText, requiredInDraft) {
  return { id, kind, source_text: String(sourceText || '').trim(), required_in_draft: Boolean(requiredInDraft) };
}

function labeledValue(body, labels) {
  for (const label of labels) {
    const escaped = label.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
    const match = String(body || '').match(new RegExp(`^\\s*[-*]\\s*${escaped}\\s*[：:]\\s*(.+?)\\s*$`, 'mu'));
    if (match) return match[1].trim();
  }
  return '';
}

function numberedBlock(body, label) {
  const lines = String(body || '').split(/\r?\n/u);
  const start = lines.findIndex((line) => new RegExp(`^\\s*[-*]\\s*${label}\\s*[：:]?\\s*$`, 'u').test(line));
  if (start < 0) return [];
  const values = [];
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^\s*[-*]\s*[^\s].*[：:]/u.test(lines[index])) break;
    const match = lines[index].match(/^\s*\d+[.、)]\s*(.+?)\s*$/u);
    if (match) values.push(match[1].trim());
  }
  return values;
}

function headingSection(text, pattern) {
  const lines = String(text || '').split(/\r?\n/u);
  const start = lines.findIndex((line) => /^#{1,6}\s+/u.test(line) && pattern.test(line));
  if (start < 0) return '';
  const body = [];
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^#{1,6}\s+/u.test(lines[index])) break;
    body.push(lines[index]);
  }
  return body.join('\n').trim();
}

function sameMeaningFingerprint(left, right) {
  const a = normalizeText(left);
  const b = normalizeText(right);
  if (!a || !b) return false;
  if (a.includes(b) || b.includes(a)) return true;
  // Briefs often distribute one outline obligation across several sections.
  // A moderate directional overlap is enough to prove the obligation is still
  // represented; professional story review remains responsible for judging
  // whether the execution is strong, rather than forcing verbatim restatement.
  if (b.length >= 8 && ngramCoverage(a, b) >= 0.3) return true;
  const clauses = String(right || '')
    .split(/[；。！？\n]+/u)
    .map(normalizeText)
    .filter((item) => item.length >= 6);
  if (!clauses.length) return false;
  const covered = clauses.filter((clause) => a.includes(clause) || ngramCoverage(a, clause) >= 0.48).length;
  return covered / clauses.length >= 0.6;
}

function ngramCoverage(left, right) {
  const leftPairs = ngrams(left, 2);
  const rightPairs = ngrams(right, 2);
  const overlap = [...rightPairs].filter((item) => leftPairs.has(item)).length;
  return overlap / Math.max(1, rightPairs.size);
}

function ngrams(text, size) {
  const output = new Set();
  for (let index = 0; index <= text.length - size; index += 1) output.add(text.slice(index, index + size));
  return output;
}

function normalizeText(value) {
  return String(value || '').replace(/[\s，。；：、“”‘’《》【】（）()\-—_]/gu, '');
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest('hex');
}

function invalid(code) {
  return { status: 'blocked', code, obligations: [] };
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch (_) { return ''; }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

module.exports = {
  buildShortSectionOutlineContract,
  renderOutlineCoverageTemplate,
  validateBriefOutlineCoverage,
  validateDraftOutlineCoverage,
};
