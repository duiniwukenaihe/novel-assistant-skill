'use strict';

function normalizeIdList(value) {
  return Array.isArray(value) ? value.map(item => String(item || '').trim()).filter(Boolean) : [];
}

function buildHotSourceSelection(config, { availableIds = null } = {}) {
  const profiles = Array.isArray(config && config.source_profiles) ? config.source_profiles : [];
  const policy = config && config.discovery_policy && typeof config.discovery_policy === 'object'
    ? config.discovery_policy
    : {};
  const byId = new Map(profiles.map(profile => [String((profile || {}).source_id || ''), profile]));
  const available = Array.isArray(availableIds)
    ? new Set(availableIds.map(item => String(item || '').trim()).filter(Boolean))
    : null;
  const activeIds = profiles
    .filter(profile => String((profile || {}).status || '') !== 'disabled')
    .map(profile => String((profile || {}).source_id || ''))
    .filter(id => Boolean(id) && (!available || available.has(id)));
  const coreIds = normalizeIdList(policy.core_source_ids).filter(id => byId.has(id) && activeIds.includes(id));
  const maxSources = Math.max(coreIds.length, Number(policy.max_sources_per_round) || 12);
  const selectedIds = [];
  const selectedSet = new Set();
  const add = id => {
    if (!id || selectedSet.has(id) || !byId.has(id) || !activeIds.includes(id) || selectedIds.length >= maxSources) return false;
    selectedSet.add(id);
    selectedIds.push(id);
    return true;
  };
  coreIds.forEach(add);

  const expansionGroups = policy.expansion_groups && typeof policy.expansion_groups === 'object'
    ? policy.expansion_groups
    : {};
  const selectedGroups = [];
  for (const [groupId, ids] of Object.entries(expansionGroups)) {
    const selected = normalizeIdList(ids).find(id => add(id));
    if (selected) selectedGroups.push({ group_id: groupId, source_id: selected });
  }
  activeIds.forEach(add);

  return {
    profiles,
    byId,
    policy,
    configuredIds: activeIds,
    coreIds,
    selectedIds,
    reserveIds: activeIds.filter(id => !selectedSet.has(id)),
    selectedGroups,
    minimumSuccessfulSources: Math.max(1, Number(policy.minimum_successful_sources) || 4),
    maximumSourcesPerRound: maxSources,
  };
}

module.exports = { buildHotSourceSelection };
