'use strict';

const { buildActiveMemoryIndex } = require('./memory-active-index');

function rankChineseMemory(entries, query, options = {}) {
  const index = options.index && Array.isArray(options.index.documents)
    ? options.index
    : buildActiveMemoryIndex(Array.isArray(entries) ? entries : []);
  return retrieveFacts(index, query, options).map(item => ({ entry: item.entry, score: item.score, evidence: item.evidence, reasons: item.reasons }));
}

function retrieveFacts(index, query, options = {}) {
  const value = index && typeof index === 'object' ? index : buildActiveMemoryIndex([]);
  const documents = Array.isArray(value.documents) ? value.documents : [];
  const queryText = normalizeText(query);
  const queryAliases = expandedQueryAliases(query, options.aliases);
  const byId = new Map(documents.map(document => [document.fact_id, document]));
  const exactIds = new Set();
  const dependencyTerms = new Set();

  for (const document of documents) {
    const exactAliases = document.aliases.filter(alias => isMeaningfulAlias(alias) && (exactTermMatch(queryText, alias) || queryAliases.has(normalizeText(alias))));
    if (!exactAliases.length) continue;
    exactIds.add(document.fact_id);
    for (const dependency of document.dependencies || []) dependencyTerms.add(normalizeText(dependency));
  }

  const queryTerms = hanBigrams(queryText);
  const averageLength = Number((((value.statistics || {}).average_document_length)) || 1);
  const documentFrequency = value.document_frequency || {};
  const ranked = documents.map(document => {
    const reasons = [];
    let score = 0;
    if (exactIds.has(document.fact_id)) {
      score += 300;
      reasons.push({ code: 'typed_alias_exact', detail: 'subject_or_alias' });
    }
    const labels = new Set((document.labels || []).map(normalizeText));
    if (!exactIds.has(document.fact_id) && [...labels].some(label => dependencyTerms.has(label))) {
      score += 200;
      reasons.push({ code: 'causal_dependency', detail: 'one_hop' });
    }
    const bm25 = bm25Score(document, queryTerms, documentFrequency, documents.length, averageLength);
    if (bm25 > 0) {
      score += bm25;
      reasons.push({ code: 'han_bm25', detail: Number(bm25.toFixed(3)) });
    }
    return { fact_id: document.fact_id, entry: document.entry, score: Number(score.toFixed(3)), evidence: document.evidence, reasons };
  }).filter(item => item.score > 0 && item.evidence.length > 0);

  const limit = Math.max(0, Number.isFinite(Number(options.limit)) ? Math.floor(Number(options.limit)) : ranked.length);
  return ranked.sort((a, b) => b.score - a.score || a.fact_id.localeCompare(b.fact_id)).slice(0, limit);
}

function bm25Score(document, queryTerms, df, documentCount, averageLength) {
  const k1 = 1.2;
  const b = 0.75;
  const terms = new Set(document.terms || []);
  let score = 0;
  for (const term of queryTerms) {
    if (!terms.has(term)) continue;
    const frequency = 1;
    const docFrequency = Number(df[term] || 0);
    const idf = Math.log(1 + ((documentCount - docFrequency + 0.5) / (docFrequency + 0.5)));
    const denominator = frequency + k1 * (1 - b + b * (Number(document.length || 1) / Math.max(1, averageLength)));
    score += idf * ((frequency * (k1 + 1)) / denominator);
  }
  return score;
}

function expandedQueryAliases(query, aliases) {
  const result = new Set([normalizeText(query)].filter(Boolean));
  if (Array.isArray(aliases)) {
    for (const alias of aliases) result.add(normalizeText(alias));
  } else if (aliases && typeof aliases === 'object') {
    for (const [key, values] of Object.entries(aliases)) {
      if (!exactTermMatch(normalizeText(query), key)) continue;
      for (const alias of Array.isArray(values) ? values : [values]) result.add(normalizeText(alias));
    }
  }
  return result;
}

function exactTermMatch(query, term) {
  const normalized = normalizeText(term);
  return Boolean(query && normalized && query.includes(normalized));
}

function isMeaningfulAlias(alias) {
  return (String(alias || '').match(/[\u3400-\u9fff]/g) || []).length >= 2 || String(alias || '').length >= 3;
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

module.exports = { rankChineseMemory, retrieveFacts };
