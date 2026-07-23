'use strict';

const crypto = require('crypto');
const { estimateTokens } = require('./context-budget');

function deriveMemoryTokenBudget({ task = {}, query = '', stageId = '' } = {}) {
  const estimate = (((task || {}).runtime_guard || {}).token_estimate || {});
  const runtimeTokens = positiveInt(estimate.context_tokens_budget)
    || Math.floor((positiveInt(estimate.context_chars_budget) || positiveInt(estimate.host_context_chars)) / 2);
  const queryTokens = estimateTokens(String(query || ''));
  const ratio = /brief|plan|outline/u.test(String(stageId || '')) ? 0.18 : 0.12;
  const available = runtimeTokens || Math.max(2400, queryTokens * 4);
  const demand = 240 + Math.ceil(queryTokens * 0.3);
  return Math.max(240, Math.min(Math.ceil(available * ratio), demand));
}

function selectWithinTokenBudget({ priority = [], ranked = [], tokenBudget, serialize = JSON.stringify } = {}) {
  const budget = Math.max(1, positiveInt(tokenBudget) || 1);
  const entries = [];
  const selected = new Set();
  let used = 0;
  let priorityOverflow = false;

  for (const entry of uniqueEntries(priority)) {
    const tokens = entryTokens(entry, serialize);
    entries.push(entry);
    selected.add(entryIdentity(entry));
    used += tokens;
    if (used > budget) priorityOverflow = true;
  }
  for (const entry of uniqueEntries(ranked)) {
    const id = entryIdentity(entry);
    if (selected.has(id)) continue;
    const tokens = entryTokens(entry, serialize);
    if (used + tokens > budget) continue;
    entries.push(entry);
    selected.add(id);
    used += tokens;
  }
  return {
    entries,
    token_budget: budget,
    used_tokens: used,
    omitted_count: Math.max(0, uniqueEntries([...priority, ...ranked]).length - entries.length),
    priority_overflow: priorityOverflow,
  };
}

function buildMemoryRevision(value = {}) {
  const revisionInput = {
    project_id: String(value.project_id || ''),
    scope: value.scope && typeof value.scope === 'object' ? value.scope : {},
    selected_memory: value.selected_memory && typeof value.selected_memory === 'object' ? value.selected_memory : {},
  };
  return `sha256:${crypto.createHash('sha256').update(stableJson(revisionInput)).digest('hex')}`;
}

function uniqueEntries(values) {
  const result = [];
  const seen = new Set();
  for (const entry of Array.isArray(values) ? values : []) {
    const id = entryIdentity(entry);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    result.push(entry);
  }
  return result;
}

function entryIdentity(entry) {
  return String((entry || {}).id || (entry || {}).fact_id || (entry || {}).promise_id || (entry || {}).rule_id || '');
}

function entryTokens(entry, serialize) {
  let text;
  try { text = serialize(entry); } catch (_) { text = JSON.stringify(entry); }
  return Math.max(1, estimateTokens(String(text || '')));
}

function positiveInt(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

module.exports = {
  buildMemoryRevision,
  deriveMemoryTokenBudget,
  selectWithinTokenBudget,
};
