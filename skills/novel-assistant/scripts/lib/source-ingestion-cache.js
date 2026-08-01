'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { LocalStorageBackend } = require('./local-storage-backend');
const { appendJsonl } = require('./workflow-state-store');

function ingestSource(projectRoot, input = {}) {
  const backend = new LocalStorageBackend(projectRoot);
  const source = normalizeRelativePath(input.source, 'source');
  const taskDir = normalizeRelativePath(input.taskDir, 'taskDir');
  const sourceFile = backend.resolve(source);
  const sourceStat = fs.lstatSync(sourceFile);
  if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) throw failure('source must be a regular project file');
  const content = fs.readFileSync(sourceFile);
  const digest = `sha256:${crypto.createHash('sha256').update(content).digest('hex')}`;
  const sourceId = `source:${crypto.createHash('sha256').update(source).digest('hex').slice(0, 20)}`;
  const digestKey = digest.slice('sha256:'.length);
  const extension = safeExtension(path.extname(source));
  const artifactPath = `${taskDir}/artifacts/source-cache/${digestKey}${extension}`;
  const artifactFile = backend.resolve(artifactPath);
  const existed = fs.existsSync(artifactFile);
  const indexPath = `${taskDir}/artifacts/source-cache/index.jsonl`;
  const previous = latestSourceRevision(backend.resolve(indexPath), sourceId);

  if (!existed) {
    fs.mkdirSync(path.dirname(artifactFile), { recursive: true });
    const temporary = `${artifactFile}.tmp-${process.pid}`;
    fs.writeFileSync(temporary, content, { flag: 'wx' });
    fs.renameSync(temporary, artifactFile);
  }

  const result = {
    schemaVersion: '1.0.0',
    status: 'source_ingested',
    cache_status: previous && previous.source_digest === digest ? 'hit' : previous ? 'refreshed' : 'stored',
    source_id: sourceId,
    source_path: source,
    source_digest: digest,
    source_chars: content.toString('utf8').length,
    artifact_path: artifactPath,
    immutable: true,
  };
  appendJsonl(backend.resolve(indexPath), {
    ...result,
    observed_at: new Date().toISOString(),
  });
  return result;
}

function latestSourceRevision(indexFile, sourceId) {
  if (!fs.existsSync(indexFile)) return null;
  let latest = null;
  for (const line of fs.readFileSync(indexFile, 'utf8').split(/\r?\n/u).filter(Boolean)) {
    try {
      const entry = JSON.parse(line);
      if (entry.source_id === sourceId) latest = entry;
    } catch (_) {
      // A damaged historical line is ignored; the next append remains valid JSONL.
    }
  }
  return latest;
}

function normalizeRelativePath(value, field) {
  const normalized = String(value || '').trim().replace(/\\/g, '/');
  if (!normalized || path.posix.isAbsolute(normalized) || normalized.split('/').includes('..')) {
    throw failure(`unsafe ${field}: ${normalized}`);
  }
  return path.posix.normalize(normalized);
}

function safeExtension(value) {
  const extension = String(value || '').toLowerCase();
  return /^\.[a-z0-9]{1,8}$/u.test(extension) ? extension : '.bin';
}

function failure(message) {
  const error = new Error(message);
  error.code = 'SOURCE_INGESTION_ERROR';
  return error;
}

module.exports = { ingestSource };
