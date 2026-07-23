'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

function buildActiveMemoryIndex(events) {
  const sourceEvents = Array.isArray(events) ? events.filter(item => item && typeof item === 'object') : [];
  const latest = new Map();
  for (const event of sourceEvents) {
    const id = entryId(event);
    if (id) latest.set(id, event);
  }
  const active = Array.from(latest.values()).filter(isActive);
  const documents = active.map(entry => {
    const labels = unique([entry.subject, entry.predicate, entry.object, entry.title, ...(entry.aliases || [])]);
    const aliases = unique([entry.subject, ...(entry.aliases || [])]);
    const dependencies = unique(entry.dependencies || []);
    const terms = hanBigrams(labels.join(''));
    return {
      fact_id: entryId(entry),
      entry,
      labels,
      aliases,
      dependencies,
      terms: Array.from(terms).sort(),
      length: Math.max(1, terms.size),
      evidence: entryEvidence(entry),
    };
  }).filter(document => document.fact_id && document.evidence.length > 0);
  const aliases = buildLookup(documents, 'aliases');
  const dependencies = buildLookup(documents, 'dependencies');
  const documentFrequency = {};
  for (const document of documents) {
    for (const term of document.terms) documentFrequency[term] = (documentFrequency[term] || 0) + 1;
  }
  const sourceDigest = crypto.createHash('sha256').update(JSON.stringify(sourceEvents)).digest('hex');
  return {
    schemaVersion: '1.0.0',
    sourceDigest,
    replay_position: sourceEvents.length,
    documents,
    aliases,
    dependencies,
    document_frequency: documentFrequency,
    statistics: {
      source_events: sourceEvents.length,
      active_documents: documents.length,
      alias_terms: Object.keys(aliases).length,
      dependency_terms: Object.keys(dependencies).length,
      average_document_length: documents.length ? documents.reduce((sum, document) => sum + document.length, 0) / documents.length : 0,
    },
  };
}

function loadOrBuildActiveMemoryIndex(projectRoot, events, options = {}) {
  const root = path.resolve(projectRoot || '');
  const expected = buildActiveMemoryIndex(events);
  const file = path.join(root, '追踪', 'memory', 'facts.active-index.json');
  if (!options.force && fs.existsSync(file)) {
    try {
      const stored = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (stored && stored.schemaVersion === expected.schemaVersion && stored.sourceDigest === expected.sourceDigest) {
        return { index: stored, source: 'snapshot', file };
      }
    } catch (_) {
      // The append-only journal remains canonical. A corrupt cache is rebuilt.
    }
  }
  return { index: expected, source: 'rebuilt', file };
}

function writeActiveMemoryIndex(projectRoot, events) {
  const root = path.resolve(projectRoot || '');
  const { index, file } = loadOrBuildActiveMemoryIndex(root, events, { force: true });
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temporary, `${JSON.stringify(index, null, 2)}\n`);
  fs.renameSync(temporary, file);
  return { index, file };
}

function buildLookup(documents, field) {
  const lookup = {};
  for (const document of documents) {
    for (const value of document[field] || []) {
      const key = normalizeText(value);
      if (!key) continue;
      if (!lookup[key]) lookup[key] = [];
      if (!lookup[key].includes(document.fact_id)) lookup[key].push(document.fact_id);
    }
  }
  for (const values of Object.values(lookup)) values.sort();
  return lookup;
}

function isActive(entry) {
  return String(entry.status || 'active') === 'active' && (entry.valid_to === undefined || entry.valid_to === null || entry.valid_to === '');
}

function entryEvidence(entry) {
  const value = Array.isArray(entry.evidence) && entry.evidence.length ? entry.evidence : entry.sourceRefs;
  return (Array.isArray(value) ? value : []).map(item => typeof item === 'string' ? { path: item } : item).filter(item => item && item.path);
}

function entryId(entry) {
  return String((entry || {}).fact_id || (entry || {}).id || '');
}

function unique(values) {
  return Array.from(new Set((Array.isArray(values) ? values : [values]).map(value => String(value || '').trim()).filter(Boolean)));
}

function hanBigrams(value) {
  const han = String(value || '').match(/[\u3400-\u9fff]/g) || [];
  const result = new Set();
  if (han.length === 1) result.add(han[0]);
  for (let index = 0; index < han.length - 1; index += 1) result.add(`${han[index]}${han[index + 1]}`);
  return result;
}

function normalizeText(value) {
  return String(value || '').normalize('NFKC').toLowerCase().replace(/[^a-z0-9\u3400-\u9fff]+/g, '');
}

module.exports = { buildActiveMemoryIndex, loadOrBuildActiveMemoryIndex, writeActiveMemoryIndex };
