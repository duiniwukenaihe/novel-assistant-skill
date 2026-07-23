'use strict';

const STORAGE_BACKEND_VERSION = '1.0.0';
const STORAGE_DOMAINS = Object.freeze(['workflow', 'story_memory', 'artifact', 'user_profile', 'integration']);

function assertStorageBackend(backend) {
  if (!backend || typeof backend !== 'object') throw contractError('storage backend is required');
  for (const method of ['capabilities', 'projectIdentity', 'readJson', 'readText', 'readJsonlLatest', 'sourceRevision']) {
    if (typeof backend[method] !== 'function') throw contractError(`storage backend missing method: ${method}`);
  }
  const capabilities = backend.capabilities();
  if (!capabilities || String(capabilities.contract_version || '') !== STORAGE_BACKEND_VERSION) {
    throw contractError(`unsupported storage backend contract: ${String((capabilities || {}).contract_version || '')}`);
  }
  return backend;
}

function normalizeRecordAddress(value = {}) {
  const domain = String(value.domain || '');
  if (!STORAGE_DOMAINS.includes(domain)) throw contractError(`unsupported storage domain: ${domain}`);
  const projectId = nonEmpty(value.project_id, 'project_id');
  const projectInstanceId = nonEmpty(value.project_instance_id, 'project_instance_id');
  const recordType = safeIdentity(value.record_type, 'record_type');
  const recordId = safeIdentity(value.record_id, 'record_id');
  return {
    schema_version: STORAGE_BACKEND_VERSION,
    domain,
    project_id: projectId,
    project_instance_id: projectInstanceId,
    record_type: recordType,
    record_id: recordId,
  };
}

function storageRecord(address, payload, options = {}) {
  const normalized = normalizeRecordAddress(address);
  return {
    ...normalized,
    revision: String(options.revision || ''),
    payload: payload && typeof payload === 'object' ? payload : {},
    evidence: Array.isArray(options.evidence) ? options.evidence.slice() : [],
    updated_at: String(options.updated_at || new Date().toISOString()),
  };
}

function nonEmpty(value, field) {
  const normalized = String(value || '').trim();
  if (!normalized) throw contractError(`${field} is required`);
  return normalized;
}

function safeIdentity(value, field) {
  const normalized = nonEmpty(value, field);
  if (!/^[A-Za-z0-9._:-]+$/.test(normalized)) throw contractError(`${field} contains unsafe characters`);
  return normalized;
}

function contractError(message) {
  const error = new Error(message);
  error.code = 'STORAGE_CONTRACT_INVALID';
  return error;
}

module.exports = {
  STORAGE_BACKEND_VERSION,
  STORAGE_DOMAINS,
  assertStorageBackend,
  normalizeRecordAddress,
  storageRecord,
};
