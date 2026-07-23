'use strict';

const FIRST_SECTION_STAGES = new Set(['draft_first_section', 'first_section_brief']);
const NEXT_SECTION_STAGES = new Set(['next_section_brief', 'draft_next_section']);

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

function acceptedSectionHighWater(projectState) {
  const accepted = Array.isArray((projectState || {}).accepted_sections)
    ? projectState.accepted_sections
    : [];
  let highWater = 0;
  for (let index = 0; index < accepted.length; index += 1) {
    highWater = Math.max(highWater, positiveInteger((accepted[index] || {}).section_index) || index + 1);
  }
  return highWater;
}

function outlineSectionCount(outlineText) {
  const text = String(outlineText || '');
  const explicit = text.match(/总小节数\s*[：:]\s*(\d+)\s*节?/u);
  if (explicit) return positiveInteger(explicit[1]);
  const indexes = [...text.matchAll(/^#{1,6}\s*第\s*0*(\d+)\s*节(?:\s*[：:]|\s|$)/gmu)]
    .map((match) => positiveInteger(match[1]))
    .filter(Boolean);
  return indexes.length ? Math.max(...indexes) : 0;
}

function resolvePlannedSectionCount({ projectState = {}, titleLock = {}, outlineText = '' } = {}) {
  const titleIndexes = (Array.isArray(titleLock.sections) ? titleLock.sections : [])
    .map((item) => positiveInteger((item || {}).section_index))
    .filter(Boolean);
  const candidates = [
    ['project_state.narrative.planned_sections', positiveInteger(((projectState.narrative || {}).planned_sections))],
    ['project_state.planned_sections', positiveInteger(projectState.planned_sections)],
    ['project_state.total_sections', positiveInteger(projectState.total_sections)],
    ['title_lock.planned_sections', positiveInteger(titleLock.planned_sections)],
    ['title_lock.total_sections', positiveInteger(titleLock.total_sections)],
    ['title_lock.sections', titleIndexes.length ? Math.max(...titleIndexes) : 0],
    ['outline', outlineSectionCount(outlineText)],
  ].filter((item) => item[1] > 0);
  const values = [...new Set(candidates.map((item) => item[1]))];
  return {
    status: values.length === 0 ? 'missing' : values.length === 1 ? 'locked' : 'conflict',
    count: values.length === 1 ? values[0] : 0,
    candidates: candidates.map(([source, count]) => ({ source, count })),
    conflicting_counts: values,
  };
}

function resolveShortPlanProgress({ plannedCount = 0, acceptedSections = [], currentSection = 0 } = {}) {
  const total = positiveInteger(plannedCount);
  const current = positiveInteger(currentSection);
  const accepted = new Set((Array.isArray(acceptedSections) ? acceptedSections : [])
    .map((item) => positiveInteger(typeof item === 'object' ? item.section_index : item))
    .filter(Boolean));
  if (!total) return { status: 'plan_missing', completed: false, missing_sections: [] };
  if (current > total || [...accepted].some((index) => index > total)) {
    return { status: 'outside_plan', completed: false, planned_sections: total, current_section: current, accepted_sections: [...accepted].sort((a, b) => a - b) };
  }
  const missing = Array.from({ length: total }, (_, index) => index + 1).filter((index) => !accepted.has(index));
  return {
    status: missing.length === 0 ? 'completed' : 'in_progress',
    completed: missing.length === 0,
    planned_sections: total,
    current_section: current,
    accepted_sections: [...accepted].sort((a, b) => a - b),
    missing_sections: missing,
    next_section: missing.find((index) => index > current) || 0,
  };
}

function inferShortSectionIndex({ projectState = {}, stageId = '', scope = '' } = {}) {
  if (FIRST_SECTION_STAGES.has(String(stageId || ''))) return 1;
  const acceptedHighWater = acceptedSectionHighWater(projectState);
  if (NEXT_SECTION_STAGES.has(String(stageId || '')) && acceptedHighWater) {
    const explicit = positiveInteger(projectState.current_section_index || projectState.current_section);
    return explicit > acceptedHighWater ? explicit : acceptedHighWater + 1;
  }
  const scopeMatch = String(scope || '').match(/第\s*0*(\d+)\s*节/);
  if (scopeMatch) return positiveInteger(scopeMatch[1]);
  const explicit = positiveInteger(projectState.current_section_index || projectState.current_section);
  if (explicit) return explicit;
  return acceptedHighWater || 0;
}

module.exports = {
  acceptedSectionHighWater,
  inferShortSectionIndex,
  outlineSectionCount,
  resolvePlannedSectionCount,
  resolveShortPlanProgress,
};
