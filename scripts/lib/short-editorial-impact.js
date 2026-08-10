'use strict';

const IMPACT_BY_FINDING_CODE = Object.freeze({
  // V3 has no direct full-story prose overwrite stage. Keep expression fixes
  // inside the current Brief/revision loop rather than bypassing that gate.
  prose_expression: 'current_brief',
  emotional_tension: 'current_brief',
  reader_pull: 'current_brief',
  professional_reader_milestone: 'current_brief',
  causal_progression: 'planning',
  protagonist_agency: 'planning',
  EndingCost: 'planning',
  section_responsibility_overload: 'structure',
});

const IMPACT_PRIORITY = Object.freeze({
  expression_only: 1,
  current_brief: 2,
  planning: 3,
  structure: 4,
  needs_analysis: 5,
});

function normalizeSectionIndices(values) {
  return [...new Set((Array.isArray(values) ? values : [])
    .map(Number)
    .filter(value => Number.isInteger(value) && value > 0))]
    .sort((left, right) => left - right);
}

function classifyEditorialImpact(finding = {}) {
  const code = String((finding && finding.code) || '').trim();
  const impactLevel = IMPACT_BY_FINDING_CODE[code]
    || (/^outline_/u.test(code) ? 'planning' : 'needs_analysis');
  return { code, impact_level: impactLevel };
}

function sectionsFromFindingScope(scope, sectionIndices = []) {
  const text = String(scope || '').trim();
  const available = normalizeSectionIndices(sectionIndices);
  if (!text) return [];
  if (/(?:全篇|整篇|全文|通篇|整体)/u.test(text)) return available;

  const range = text.match(/(\d+)\s*(?:-|–|—|~|～|至|到)\s*(?:第\s*)?(\d+)/u);
  if (range) {
    const start = Number(range[1]);
    const end = Number(range[2]);
    if (Number.isInteger(start) && Number.isInteger(end) && start > 0 && end >= start) {
      const values = Array.from({ length: end - start + 1 }, (_, index) => start + index);
      return available.length ? values.filter(value => available.includes(value)) : values;
    }
  }

  const explicit = normalizeSectionIndices([...text.matchAll(/\d+/gu)].map(match => Number(match[0])));
  if (explicit.length) return available.length ? explicit.filter(value => available.includes(value)) : explicit;
  if (/(?:结尾|终局)/u.test(text)) return available.length ? [available[available.length - 1]] : [];
  return [];
}

function summarizeEditorialImpact(findings = []) {
  const levels = (Array.isArray(findings) ? findings : [])
    .map(item => String((item || {}).impact_level || 'needs_analysis'));
  if (!levels.length || levels.includes('needs_analysis')) return 'needs_analysis';
  return levels.reduce((selected, candidate) => (
    IMPACT_PRIORITY[candidate] > IMPACT_PRIORITY[selected] ? candidate : selected
  ), 'expression_only');
}

module.exports = {
  IMPACT_BY_FINDING_CODE,
  classifyEditorialImpact,
  normalizeSectionIndices,
  sectionsFromFindingScope,
  summarizeEditorialImpact,
};
