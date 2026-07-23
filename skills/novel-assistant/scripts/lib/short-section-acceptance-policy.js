'use strict';

function resultPassed(result) {
  if (['blocked', 'failed'].includes(String((result || {}).step_status || '').toLowerCase())) return false;
  if (Array.isArray((result || {}).blocking_findings) && result.blocking_findings.length > 0) return false;
  const signal = String((result || {}).verification_result || (result || {}).gate_result || (result || {}).output_health_result || '').toLowerCase();
  return !signal || /^(pass|passed|accepted|approved|ok|completed)$/.test(signal);
}

function candidateCount(result) {
  const explicit = Number((result || {}).candidate_count);
  if (Number.isInteger(explicit) && explicit > 0) return explicit;
  if (Array.isArray((result || {}).candidates)) return Math.max(1, result.candidates.length);
  return 1;
}

function resolveShortQualityNext({ stageId, result, allowedNext }) {
  if (!['quality_gate', 'story_value_gate'].includes(String(stageId || '')) || !resultPassed(result)) return '';
  const allowed = new Set(Array.isArray(allowedNext) ? allowedNext : []);
  const compare = candidateCount(result) > 1 || (result || {}).comparison_requested === true;
  if (compare && allowed.has('section_candidate_compare')) return 'section_candidate_compare';
  if (allowed.has('section_accept_anchor')) return 'section_accept_anchor';
  if (allowed.has('section_candidate_compare')) return 'section_candidate_compare';
  return '';
}

function resolveShortAnchorNext({ result, allowedNext }) {
  const allowed = new Set(Array.isArray(allowedNext) ? allowedNext : []);
  const remaining = Array.isArray((result || {}).remaining_sections) ? result.remaining_sections.length : null;
  const hasExplicitCompletion = Object.prototype.hasOwnProperty.call(result || {}, 'all_sections_completed');
  const completed = hasExplicitCompletion
    ? (result || {}).all_sections_completed === true
    : remaining === 0;
  if (completed && allowed.has('full_story_assembly')) return 'full_story_assembly';
  if (allowed.has('next_section_brief')) return 'next_section_brief';
  if (allowed.has('full_story_assembly')) return 'full_story_assembly';
  return '';
}

module.exports = { candidateCount, resolveShortAnchorNext, resolveShortQualityNext, resultPassed };
