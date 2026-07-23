'use strict';

function extractFacts(entry) {
  const facts = [];
  const append = (key, value) => {
    if (!key || value === undefined || value === null) return;
    facts.push({ key: String(key), value: stableValue(value) });
  };
  const read = value => {
    if (Array.isArray(value)) {
      for (const item of value) {
        if (item && typeof item === 'object') append(item.key || item.fact_key || item.factKey, item.value ?? item.fact_value ?? item.factValue);
      }
    } else if (value && typeof value === 'object') {
      for (const [key, factValue] of Object.entries(value)) append(key, factValue);
    }
  };
  read(entry && entry.facts);
  read(entry && entry.structuredFacts);
  if (entry && (entry.factKey || entry.fact_key)) append(entry.factKey || entry.fact_key, entry.factValue ?? entry.fact_value ?? entry.value);
  return facts;
}

function detectMemoryConflicts(entries) {
  const byKey = new Map();
  for (const entry of entries || []) {
    for (const fact of extractFacts(entry)) {
      if (!byKey.has(fact.key)) byKey.set(fact.key, new Map());
      const values = byKey.get(fact.key);
      if (!values.has(fact.value)) values.set(fact.value, []);
      values.get(fact.value).push(String(entry.id || ''));
    }
  }
  const conflicts = [];
  for (const [factKey, values] of byKey) {
    if (values.size < 2) continue;
    const entryIds = [...new Set([...values.values()].flat())].filter(Boolean).sort();
    conflicts.push({
      type: 'structured_fact_conflict',
      fact_key: factKey,
      entry_ids: entryIds,
      values: [...values.keys()].sort(),
      message: `active memory has conflicting values for ${factKey}`,
    });
  }
  return conflicts.sort((a, b) => a.fact_key.localeCompare(b.fact_key));
}

function stableValue(value) {
  if (typeof value === 'string') return value;
  return JSON.stringify(value);
}

module.exports = { detectMemoryConflicts, extractFacts };
