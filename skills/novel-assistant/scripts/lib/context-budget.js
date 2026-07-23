'use strict';

function estimateTokens(text) {
  return Math.ceil(String(text || '').length / 2);
}

function compactToTokens(text, tokenBudget) {
  const value = String(text || '').trim();
  if (tokenBudget <= 0 || !value) return '';
  const maxChars = tokenBudget * 2;
  if (value.length <= maxChars) return value;
  return value.slice(0, maxChars).trim();
}

function allocateContextBudget({ budget, sources, workflowLayer = '' }) {
  const requested = Math.max(0, Number.isFinite(Number(budget)) ? Math.floor(Number(budget)) : 0);
  const selected = [];
  const omitted = [];
  const blockedRequired = [];
  let used = 0;
  const ordered = [...(sources || [])].map(source => withDynamicAllocation(source, workflowLayer)).sort((a, b) => {
    if (Boolean(a.requiredComplete) !== Boolean(b.requiredComplete)) return a.requiredComplete ? -1 : 1;
    if (Boolean(a.mandatory) !== Boolean(b.mandatory)) return a.mandatory ? -1 : 1;
    if (b.dynamic_rank !== a.dynamic_rank) return b.dynamic_rank - a.dynamic_rank;
    return String(a.id).localeCompare(String(b.id));
  });

  for (const source of ordered) {
    const text = String(source.text || '').trim();
    if (!text) continue;
    const remaining = requested - used;
    const tokens = estimateTokens(text);
    if (tokens <= remaining) {
      selected.push({ ...source, text, estimated_tokens: tokens, truncated: false, required_complete: Boolean(source.requiredComplete) });
      used += tokens;
      continue;
    }
    if (source.requiredComplete) {
      blockedRequired.push({
        id: source.id,
        title: source.title || source.id,
        source: source.kind || '',
        required_tokens: tokens,
        remaining_tokens: Math.max(0, remaining),
      });
      continue;
    }
    if (source.mandatory && remaining > 0) {
      const bounded = compactToTokens(text, remaining);
      const boundedTokens = estimateTokens(bounded);
      selected.push({ ...source, text: bounded, estimated_tokens: boundedTokens, truncated: true });
      used += boundedTokens;
      omitted.push({ id: source.id, title: source.title || source.id, reason: 'budget_truncated', source: source.kind || '' });
      continue;
    }
    omitted.push({ id: source.id, title: source.title || source.id, reason: 'budget_exceeded', source: source.kind || '' });
  }

  return { requested, used, selected, omitted, blocked_required: blockedRequired };
}

function withDynamicAllocation(source, workflowLayer) {
  const sourceLayer = String(source.layer || '');
  const currentLayer = String(workflowLayer || '');
  const unresolved = Math.max(0, Number.isFinite(Number(source.unresolvedDependencyCount)) ? Math.floor(Number(source.unresolvedDependencyCount)) : 0);
  const layerBoost = sourceLayer && currentLayer ? layerAffinity(sourceLayer, currentLayer) : 0;
  return {
    ...source,
    dynamic_rank: Number(source.rank || 0) + layerBoost + (unresolved * 25),
    allocation_reason: {
      workflow_layer: currentLayer,
      source_layer: sourceLayer,
      unresolved_dependencies: unresolved,
      layer_boost: layerBoost,
    },
  };
}

function layerAffinity(sourceLayer, workflowLayer) {
  const order = ['book', 'volume', 'stage', 'chapter', 'task'];
  const sourceIndex = order.indexOf(sourceLayer);
  const workflowIndex = order.indexOf(workflowLayer);
  if (sourceIndex < 0 || workflowIndex < 0) return 0;
  const distance = Math.abs(workflowIndex - sourceIndex);
  return Math.max(0, 80 - (distance * 20));
}

module.exports = { allocateContextBudget, compactToTokens, estimateTokens };
