'use strict';

const ROLE_CATALOG = [
  {
    subagent_type: 'story-explorer',
    dimensions: ['plot', 'hooks'],
    focus: '独立证据/情节/钩子',
  },
  {
    subagent_type: 'character-designer',
    dimensions: ['character'],
    focus: '人物/关系/动机',
  },
  {
    subagent_type: 'narrative-writer',
    dimensions: ['prose'],
    focus: '叙事/文字节奏/AI 写作指纹',
  },
  {
    subagent_type: 'consistency-checker',
    dimensions: ['canon'],
    focus: '设定/时间线/一致性',
  },
];

const HIGH_CONFLICT_ROLES = ['story-explorer', 'narrative-writer', 'consistency-checker'];

function planReviewRoles({ requiredDimensions, evidenceSignals, availableAgents, budgetPolicy }) {
  const dimensions = uniqueStrings(requiredDimensions);
  const signals = new Set(uniqueStrings(evidenceSignals).map(normalizeSignal));
  const available = normalizeAvailableAgents(availableAgents);
  const highConflict = hasHighConflict(signals);
  const wanted = new Set();

  if (dimensions.includes('plot') || dimensions.includes('hooks') || highConflict) wanted.add('story-explorer');
  if (dimensions.includes('canon') || highConflict) wanted.add('consistency-checker');
  if (dimensions.includes('character') && (hasCharacterRisk(signals) || highConflict)) wanted.add('character-designer');
  if (dimensions.includes('prose') && (hasProseRisk(signals) || highConflict)) wanted.add('narrative-writer');
  if (highConflict) for (const role of HIGH_CONFLICT_ROLES) wanted.add(role);

  const roleOrder = highConflict
    ? HIGH_CONFLICT_ROLES.concat(ROLE_CATALOG.map((role) => role.subagent_type).filter((role) => !HIGH_CONFLICT_ROLES.includes(role)))
    : ROLE_CATALOG.map((role) => role.subagent_type);
  const roles = roleOrder
    .filter((subagentType) => wanted.has(subagentType) && available.has(subagentType))
    .map((subagentType) => roleFor(subagentType, dimensions, highConflict));
  const covered = new Set(roles.flatMap((role) => role.dimensions));
  const deferredDimensions = dimensions.filter((dimension) => !covered.has(dimension));

  return {
    mode: roles.length ? 'agent_dispatch' : 'solo_fallback',
    roles,
    deferredDimensions,
    retryPolicy: 'missing_dimension_once',
  };
}

function acceptReviewResults({ dispatchPlan, primaryChapterKeys, result }) {
  const plan = dispatchPlan && typeof dispatchPlan === 'object' ? dispatchPlan : {};
  const plannedRoles = Array.isArray(plan.roles) ? plan.roles : [];
  const expectedKeys = uniqueStrings(primaryChapterKeys);
  const byRole = new Map((Array.isArray((result || {}).role_results) ? result.role_results : [])
    .map((entry) => [String((entry || {}).subagent_type || ''), entry]));
  const acceptedDimensions = new Set();
  const unresolvedDimensions = new Set(uniqueStrings(plan.deferredDimensions));
  const acceptedEvidence = [];
  const retryRoles = [];

  for (const role of plannedRoles) {
    const name = String((role || {}).subagent_type || '');
    const dimensions = uniqueStrings((role || {}).dimensions);
    const roleResult = byRole.get(name);
    if (validRoleResult(roleResult, dimensions, expectedKeys)) {
      for (const dimension of dimensions) acceptedDimensions.add(dimension);
      acceptedEvidence.push({ subagent_type: name, evidence_paths: uniqueStrings(roleResult.evidence_paths) });
      continue;
    }
    for (const dimension of dimensions) unresolvedDimensions.add(dimension);
    if (name) retryRoles.push(name);
  }

  return {
    status: unresolvedDimensions.size ? 'partial_evidence' : 'accepted',
    acceptedDimensions: Array.from(acceptedDimensions).sort(),
    unresolvedDimensions: Array.from(unresolvedDimensions).sort(),
    retryRoles: retryRoles.sort(),
    acceptedEvidence,
  };
}

function roleFor(subagentType, requestedDimensions, highConflict) {
  const definition = ROLE_CATALOG.find((role) => role.subagent_type === subagentType);
  const dimensions = definition.dimensions.filter((dimension) => requestedDimensions.includes(dimension));
  return {
    subagent_type: definition.subagent_type,
    dimensions,
    focus: definition.focus,
    independent_evidence: highConflict && subagentType === 'story-explorer',
  };
}

function validRoleResult(result, dimensions, expectedKeys) {
  if (!result || String(result.status || '') !== 'accepted') return false;
  if (!['healthy', 'pass'].includes(String(result.output_health || ''))) return false;
  const evidencePaths = uniqueStrings(result.evidence_paths);
  if (!evidencePaths.length) return false;
  const actualDimensions = new Set(uniqueStrings(result.dimensions));
  if (dimensions.some((dimension) => !actualDimensions.has(dimension))) return false;
  const actualKeys = new Set(uniqueStrings(result.chapter_keys));
  return expectedKeys.every((key) => actualKeys.has(key));
}

function normalizeAvailableAgents(availableAgents) {
  const values = Array.isArray(availableAgents) && availableAgents.length
    ? availableAgents
    : ROLE_CATALOG.map((role) => role.subagent_type);
  return new Set(values.map((entry) => typeof entry === 'string' ? entry : entry && entry.subagent_type).filter(Boolean));
}

function uniqueStrings(values) {
  return Array.from(new Set((Array.isArray(values) ? values : []).map((value) => String(value || '').trim()).filter(Boolean)));
}

function normalizeSignal(value) {
  return String(value || '').trim().toLowerCase().replace(/[\s-]+/g, '_');
}

function hasHighConflict(signals) {
  return ['high_conflict', 'conflict_high', 'evidence_conflict', 'canon_conflict'].some((signal) => signals.has(signal));
}

function hasCharacterRisk(signals) {
  return ['character_drift', 'character', 'motivation_drift', 'relationship_drift'].some((signal) => signals.has(signal));
}

function hasProseRisk(signals) {
  return ['prose', 'prose_high', 'ai_pattern', 'ai_high', 'degeneration', 'punctuation'].some((signal) => signals.has(signal));
}

module.exports = { acceptReviewResults, planReviewRoles };
