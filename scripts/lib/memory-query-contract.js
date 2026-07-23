'use strict';

const crypto = require('crypto');

const CONTRACT_VERSION = '1.0.0';
const NEEDS = new Set([
  'accepted_facts', 'active_cast', 'active_promises', 'confirmed_style_rules',
  'confirmed_quality_rules', 'continuity_obligations', 'canon_constraints',
  'review_dependencies', 'user_preferences',
]);

function normalizeMemoryQuery(value = {}) {
  const needs = unique(value.needs).map(String);
  const unknown = needs.filter(need => !NEEDS.has(need));
  if (unknown.length) throw invalid(`unsupported memory needs: ${unknown.join(', ')}`);
  if (!needs.length) throw invalid('memory query needs at least one typed need');
  return {
    schema_version: CONTRACT_VERSION,
    project_id: required(value.project_id, 'project_id'),
    project_instance_id: String(value.project_instance_id || ''),
    workflow_id: required(value.workflow_id, 'workflow_id'),
    workflow_type: String(value.workflow_type || ''),
    stage_id: required(value.stage_id, 'stage_id'),
    owner_module: String(value.owner_module || ''),
    scope: plainObject(value.scope),
    needs,
    query_text: String(value.query_text || ''),
  };
}

function createMemoryContract(options = {}) {
  const query = normalizeMemoryQuery(options.query || {});
  const body = {
    schema_version: CONTRACT_VERSION,
    provider: String(options.provider || 'story-memory'),
    query,
    memory_revision: required(options.memoryRevision, 'memoryRevision'),
    packet_path: String(options.packetPath || ''),
    packet_digest: String(options.packetDigest || ''),
    token_budget: positive(options.tokenBudget),
    used_tokens: positive(options.usedTokens),
    selected_entry_ids: unique(options.selectedEntryIds),
    omitted_count: Math.max(0, Number(options.omittedCount || 0)),
    read_receipt_required: options.readReceiptRequired !== false,
    accepts_memory_updates: options.acceptsMemoryUpdates !== false,
  };
  return { ...body, contract_digest: digest(body) };
}

function createMemoryReadReceipt(contract) {
  if (!contract || !contract.contract_digest) throw invalid('memory contract is required');
  return {
    schema_version: CONTRACT_VERSION,
    provider: String(contract.provider || 'story-memory'),
    workflow_id: String((contract.query || {}).workflow_id || ''),
    stage_id: String((contract.query || {}).stage_id || ''),
    contract_digest: String(contract.contract_digest || ''),
    memory_revision: String(contract.memory_revision || ''),
    packet_digest: String(contract.packet_digest || ''),
    selected_entry_ids: unique(contract.selected_entry_ids),
  };
}

function validateMemoryReadReceipt(contract, receipt) {
  if (!contract || !contract.read_receipt_required) return { status: 'not_required' };
  if (!receipt || typeof receipt !== 'object') return { status: 'missing' };
  const fields = ['provider', 'contract_digest', 'memory_revision', 'packet_digest'];
  const stale_fields = fields.filter(field => String(receipt[field] || '') !== String(contract[field] || ''));
  if (String(receipt.workflow_id || '') !== String((contract.query || {}).workflow_id || '')) stale_fields.push('workflow_id');
  if (String(receipt.stage_id || '') !== String((contract.query || {}).stage_id || '')) stale_fields.push('stage_id');
  return stale_fields.length ? { status: 'stale', stale_fields: unique(stale_fields) } : { status: 'current' };
}

function digest(value) {
  return `sha256:${crypto.createHash('sha256').update(stableJson(value)).digest('hex')}`;
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

function required(value, field) { const text = String(value || '').trim(); if (!text) throw invalid(`${field} is required`); return text; }
function plainObject(value) { return value && typeof value === 'object' && !Array.isArray(value) ? { ...value } : {}; }
function positive(value) { const number = Number(value); return Number.isFinite(number) && number > 0 ? number : 0; }
function unique(values) { return [...new Set((Array.isArray(values) ? values : []).map(item => String(item || '')).filter(Boolean))]; }
function invalid(message) { const error = new Error(message); error.code = 'MEMORY_QUERY_CONTRACT_INVALID'; return error; }

module.exports = {
  CONTRACT_VERSION,
  NEEDS,
  createMemoryContract,
  createMemoryReadReceipt,
  normalizeMemoryQuery,
  validateMemoryReadReceipt,
};
