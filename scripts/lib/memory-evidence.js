'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const STATUS_PRIORITY = ['unsafe_path', 'symlink_escape', 'missing', 'hash_mismatch', 'invalid_shape'];

function validateMemoryEvidence(projectRoot, value, metadata = {}) {
  const root = path.resolve(projectRoot || '');
  const values = Array.isArray(value) ? value : value ? [value] : [];
  if (!root || !fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    return invalid('invalid_shape', '', 'project root is unavailable');
  }
  if (values.length === 0) return invalid('missing', '', 'evidence is required');

  const evidence = [];
  const findings = [];
  values.forEach((item, index) => {
    const result = validateEvidenceItem(root, item, metadata);
    if (result.status === 'valid') evidence.push(result.evidence);
    else findings.push({ index, status: result.status, path: result.path || '', message: result.message });
  });
  if (findings.length > 0) {
    const primary = findings.slice().sort((a, b) => STATUS_PRIORITY.indexOf(a.status) - STATUS_PRIORITY.indexOf(b.status))[0];
    return { status: primary.status, evidence: [], findings };
  }
  return { status: 'valid', evidence, findings: [] };
}

function validateEvidenceItem(root, input, metadata) {
  const item = typeof input === 'string' ? { path: input } : input;
  if (!item || typeof item !== 'object' || Array.isArray(item)) return invalid('invalid_shape', '', 'evidence item must be a path object');
  const relative = normalizeRelativePath(item.path || item.sourceRef || item.source_ref || '');
  if (!relative) return invalid('invalid_shape', '', 'evidence path is required');
  const absolute = path.resolve(root, relative);
  if (absolute === root || !absolute.startsWith(`${root}${path.sep}`)) return invalid('unsafe_path', relative, 'evidence path escapes project root');
  if (pathHasSymlink(root, relative)) return invalid('symlink_escape', relative, 'evidence path contains a symlink');
  if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) return invalid('missing', relative, 'evidence file is missing');
  const realRoot = fs.realpathSync(root);
  const realEvidence = fs.realpathSync(absolute);
  if (realEvidence === realRoot || !realEvidence.startsWith(`${realRoot}${path.sep}`)) return invalid('unsafe_path', relative, 'evidence path escapes project root');
  const hash = hashFile(absolute);
  if (item.hash && String(item.hash).toLowerCase() !== hash) return invalid('hash_mismatch', relative, 'evidence hash changed');
  return {
    status: 'valid',
    evidence: {
      ...item,
      path: relative,
      hash,
      evidence_type: String(item.evidence_type || item.evidenceType || item.type || 'file'),
      locator: String(item.locator || item.line || item.section || ''),
      source_commit_id: String(item.source_commit_id || item.sourceCommitId || metadata.commitId || ''),
      workflow_id: String(item.workflow_id || metadata.workflowId || ''),
      task_family_id: String(item.task_family_id || metadata.taskFamilyId || ''),
    },
  };
}

function invalid(status, evidencePath, message) {
  return { status, evidence: null, path: evidencePath, message };
}

function normalizeRelativePath(value) {
  return String(value || '').replace(/\\/g, '/').replace(/^\.\//, '').trim();
}

function pathHasSymlink(root, relativePath) {
  let current = root;
  for (const part of normalizeRelativePath(relativePath).split('/').filter(Boolean)) {
    current = path.join(current, part);
    if (!fs.existsSync(current)) break;
    if (fs.lstatSync(current).isSymbolicLink()) return true;
  }
  return false;
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

module.exports = { hashFile, validateMemoryEvidence };
