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
      const scope = factScope(entry);
      const identity = `${scope.identity}\u0000${fact.key}`;
      if (!byKey.has(identity)) byKey.set(identity, { factKey: fact.key, scope: scope.value, values: new Map() });
      const values = byKey.get(identity).values;
      if (!values.has(fact.value)) values.set(fact.value, []);
      values.get(fact.value).push(String(entry.id || ''));
    }
  }
  const conflicts = [];
  for (const { factKey, scope, values } of byKey.values()) {
    if (values.size < 2) continue;
    const entryIds = [...new Set([...values.values()].flat())].filter(Boolean).sort();
    conflicts.push({
      type: 'structured_fact_conflict',
      fact_key: factKey,
      scope,
      entry_ids: entryIds,
      values: [...values.keys()].sort(),
      message: `active memory has conflicting values for ${factKey}`,
    });
  }
  return conflicts.sort((a, b) => a.fact_key.localeCompare(b.fact_key));
}

function factScope(entry) {
  const raw = entry && entry.scope && typeof entry.scope === 'object' ? entry.scope : {};
  const value = {};
  for (const key of ['book', 'volume', 'volume_id', 'stage', 'stage_id', 'chapter', 'chapter_id', 'chapterRange', 'section', 'section_index', 'task', 'task_family_id', 'workflow_id']) {
    if (raw[key] !== undefined && raw[key] !== null && raw[key] !== '') value[key] = raw[key];
  }
  return { value, identity: stableObject(value) };
}

function stableObject(value) {
  return JSON.stringify(Object.keys(value).sort().reduce((result, key) => {
    result[key] = value[key];
    return result;
  }, {}));
}

function stableValue(value) {
  if (typeof value === 'string') return value;
  return JSON.stringify(value);
}

module.exports = { detectMemoryConflicts, extractFacts };
