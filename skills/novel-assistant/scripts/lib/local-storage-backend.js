'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');
const { STORAGE_BACKEND_VERSION } = require('./storage-backend-contract');

class LocalStorageBackend {
  constructor(projectRoot) {
    this.projectRoot = path.resolve(String(projectRoot || ''));
    if (!this.projectRoot || !fs.existsSync(this.projectRoot)) throw failure('project root does not exist');
  }

  capabilities() {
    return {
      contract_version: STORAGE_BACKEND_VERSION,
      backend: 'local-file',
      authority: true,
      supports: ['read', 'atomic_write', 'append_event', 'source_revision', 'project_relative_artifact'],
      transactions: 'repository_scoped',
    };
  }

  projectIdentity() {
    return this.ensureProjectIdentity({ write: false });
  }

  ensureProjectIdentity(options = {}) {
    const identityPath = '追踪/storage/project-identity.json';
    const existing = this.readJson(identityPath);
    if (existing && existing.project_id && existing.project_instance_id) return sanitizeIdentity(existing);
    const projectState = this.readJson('追踪/private-short-extension/project-state.json') || {};
    const bookState = this.readJson('.book-state.json') || {};
    const projectId = String(projectState.project_id || bookState.projectId || bookState.bookId || '').trim();
    if (!projectId) return { status: 'missing', project_id: '', project_instance_id: '' };
    if (!options.write) {
      return {
        schema_version: '1.0.0',
        status: 'uninitialized',
        project_id: projectId,
        project_instance_id: '',
        created_at: '',
      };
    }
    const identity = {
      schema_version: '1.0.0',
      status: 'current',
      project_id: projectId,
      project_instance_id: `instance-${crypto.randomUUID()}`,
      created_at: new Date().toISOString(),
    };
    atomicWriteJson(this.resolve(identityPath), identity);
    return identity;
  }

  readJson(relativePath) {
    try { return JSON.parse(fs.readFileSync(this.resolve(relativePath), 'utf8')); } catch (_) { return null; }
  }

  readText(relativePath) {
    try { return fs.readFileSync(this.resolve(relativePath), 'utf8'); } catch (_) { return ''; }
  }

  readJsonlLatest(relativePath, idFields) {
    const fields = Array.isArray(idFields) ? idFields : [idFields];
    const latest = new Map();
    for (const line of this.readText(relativePath).split(/\r?\n/).filter(Boolean)) {
      let row;
      try { row = JSON.parse(line); } catch (_) { continue; }
      const id = fields.map(field => String((row || {})[field] || '')).find(Boolean);
      if (id) latest.set(id, row);
    }
    return [...latest.values()];
  }

  sourceRevision(relativePath) {
    const file = this.resolve(relativePath);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return '';
    return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
  }

  exists(relativePath) {
    try { return fs.existsSync(this.resolve(relativePath)); } catch (_) { return false; }
  }

  resolve(relativePath) {
    const raw = String(relativePath || '');
    if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/).includes('..')) throw failure(`unsafe project-relative path: ${raw}`);
    const file = path.resolve(this.projectRoot, raw);
    if (file !== this.projectRoot && !file.startsWith(`${this.projectRoot}${path.sep}`)) throw failure(`path escapes project root: ${raw}`);
    return file;
  }
}

function sanitizeIdentity(value) {
  return {
    schema_version: String(value.schema_version || '1.0.0'),
    status: String(value.status || 'current'),
    project_id: String(value.project_id || ''),
    project_instance_id: String(value.project_instance_id || ''),
    created_at: String(value.created_at || ''),
  };
}

function failure(message) {
  const error = new Error(message);
  error.code = 'LOCAL_STORAGE_BACKEND_ERROR';
  return error;
}

module.exports = { LocalStorageBackend };
