'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { inspectChapter } = require('./chapter-commit-store');
const { SHORT_VOLUME } = require('./short-section-commit-store');

function invalid(code) {
  return { status: 'invalid', code };
}

function inside(root, target) {
  return target === root || target.startsWith(`${root}${path.sep}`);
}

function safeFile(root, relativePath) {
  if (!relativePath || path.isAbsolute(relativePath) || relativePath.split(/[\\/]/).includes('..')) return null;
  const candidate = path.resolve(root, relativePath);
  if (!inside(root, candidate)) return null;
  try {
    const real = fs.realpathSync(candidate);
    return inside(root, real) && fs.statSync(real).isFile() ? real : null;
  } catch (_) {
    return null;
  }
}

function readJson(file) {
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch (_) {
    return null;
  }
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function validateShortSectionAcceptanceProof({ projectRoot, workflowId, proof, requireCommit = false } = {}) {
  let root;
  try { root = fs.realpathSync(path.resolve(projectRoot)); } catch (_) { return invalid('short_section_project_root_missing'); }
  const candidate = proof && typeof proof === 'object' && !Array.isArray(proof) ? proof : {};
  if (String(candidate.workflow_id || '') !== String(workflowId || '')) return invalid('short_section_workflow_identity_mismatch');
  if (!Number.isInteger(Number(candidate.section_index)) || Number(candidate.section_index) < 1) return invalid('short_section_index_missing');

  const anchorFile = safeFile(root, String(candidate.anchor_path || ''));
  if (!anchorFile) return invalid('short_section_anchor_missing');
  const anchor = readJson(anchorFile);
  if (!anchor || String(anchor.status || '') !== 'accepted') return invalid('short_section_anchor_not_accepted');
  if (String(anchor.workflow_id || '') !== String(workflowId || '')
    || Number(anchor.section_index) !== Number(candidate.section_index)) return invalid('short_section_anchor_identity_mismatch');

  const canonicalPath = String(candidate.canonical_path || anchor.canonical_path || '');
  const canonicalFile = safeFile(root, canonicalPath);
  if (!canonicalFile) return invalid('short_section_canonical_missing');
  const actualHash = sha256File(canonicalFile);
  if (actualHash !== String(candidate.canonical_sha256 || '')
    || actualHash !== String(anchor.canonical_sha256 || '')) return invalid('short_section_canonical_sha256_mismatch');

  const commitId = String(candidate.section_commit_id || anchor.section_commit_id || '');
  if (requireCommit) {
    if (!commitId || commitId !== String(anchor.section_commit_id || '')) return invalid('short_section_commit_identity_missing');
    const inspected = inspectChapter(root, SHORT_VOLUME, Number(candidate.section_index));
    const commit = inspected.latest_commit;
    if (!commit || String(commit.commit_id || '') !== commitId || String(commit.workflow_id || '') !== String(workflowId || '')) {
      return invalid('short_section_commit_not_accepted');
    }
    const commitArtifact = (commit.artifacts || []).find((item) => String(item.target || '') === canonicalPath);
    if (!commitArtifact || normalizeHash(commitArtifact.after_hash || commitArtifact.content_hash) !== actualHash) {
      return invalid('short_section_commit_artifact_mismatch');
    }
  }

  const quality = anchor.quality_result && typeof anchor.quality_result === 'object' ? anchor.quality_result : {};
  const migration = anchor.migration_compatibility && typeof anchor.migration_compatibility === 'object'
    ? anchor.migration_compatibility
    : {};
  const confirmedLegacy = String(migration.source_kind || '') === 'user_confirmed'
    && migration.user_confirmed === true;
  if (migration.missing_v2_fields_marked === true) {
    return invalid(confirmedLegacy
      ? 'short_section_user_confirmed_quality_revalidation_required'
      : 'short_section_legacy_quality_revalidation_required');
  }
  if (!acceptedGateStatus(quality.machine_gate)) return invalid('short_section_machine_gate_missing');
  if (!acceptedGateStatus(quality.story_value_gate || quality.quality_gate)) return invalid('short_section_story_value_gate_missing');
  if (!acceptedGateStatus(quality.repetition_gate)) return invalid('short_section_repetition_gate_missing');
  const lengthPolicy = quality.length_policy && typeof quality.length_policy === 'object' ? quality.length_policy : {};
  const allowedLengthVerdicts = new Set(['baseline_not_established', 'within_story_band', 'explicit_story_exception', 'outside_story_band_deferred']);
  if (lengthPolicy.blocking !== false || !allowedLengthVerdicts.has(String(lengthPolicy.verdict || ''))) {
    return invalid('short_section_length_policy_missing');
  }
  return {
    status: 'accepted',
    code: '',
    section_index: Number(candidate.section_index),
    anchor_path: path.relative(root, anchorFile).split(path.sep).join('/'),
    canonical_path: path.relative(root, canonicalFile).split(path.sep).join('/'),
    canonical_sha256: actualHash,
    section_commit_id: commitId,
    quality_result: quality,
  };
}

function normalizeHash(value) {
  return String(value || '').replace(/^sha256:/, '');
}

function acceptedGateStatus(value) {
  return String(value || '') === 'pass';
}

module.exports = { validateShortSectionAcceptanceProof };
