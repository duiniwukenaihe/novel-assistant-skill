'use strict';

const crypto = require('crypto');
const path = require('path');
const { LocalStorageBackend } = require('./local-storage-backend');
const { assertStorageBackend } = require('./storage-backend-contract');

class ArtifactRepository {
  constructor(projectRoot, options = {}) {
    this.backend = assertStorageBackend(options.backend || new LocalStorageBackend(projectRoot));
  }

  describe(relativePath, options = {}) {
    const normalizedPath = normalizeRelativePath(relativePath);
    const artifactType = safeType(options.artifactType || 'file');
    const contentDigest = this.backend.sourceRevision(normalizedPath);
    return {
      schema_version: '1.0.0',
      artifact_id: `artifact:${digest(`${artifactType}\n${normalizedPath}`)}`,
      artifact_type: artifactType,
      relative_path: normalizedPath,
      exists: Boolean(contentDigest),
      content_digest: contentDigest,
      revision: contentDigest,
    };
  }

  reviewCacheKey(value = {}) {
    const identity = {
      source_digest: required(value.sourceDigest, 'sourceDigest'),
      planning_digest: required(value.planningDigest, 'planningDigest'),
      memory_revision: required(value.memoryRevision, 'memoryRevision'),
      rubric_version: required(value.rubricVersion, 'rubricVersion'),
      detector_version: required(value.detectorVersion, 'detectorVersion'),
    };
    return `review-cache:${digest(JSON.stringify(identity))}`;
  }
}

function normalizeRelativePath(value) {
  const raw = String(value || '').trim().replace(/\\/g, '/');
  if (!raw || path.posix.isAbsolute(raw) || raw.split('/').includes('..')) {
    throw failure(`unsafe project-relative artifact path: ${raw}`);
  }
  return path.posix.normalize(raw);
}

function safeType(value) {
  const normalized = String(value || '').trim();
  if (!/^[A-Za-z0-9._:-]+$/.test(normalized)) throw failure(`unsafe artifact type: ${normalized}`);
  return normalized;
}

function required(value, field) {
  const normalized = String(value || '').trim();
  if (!normalized) throw failure(`${field} is required`);
  return normalized;
}

function digest(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function failure(message) {
  const error = new Error(message);
  error.code = 'ARTIFACT_REPOSITORY_ERROR';
  return error;
}

module.exports = { ArtifactRepository };
