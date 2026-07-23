'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { buildShortMemorySnapshot } = require('./short-memory-snapshot');

const REQUIRED_DEPENDENCIES = Object.freeze([
  ['素材卡.md', 'material_digest'],
  ['设定.md', 'setting_digest'],
  ['小节大纲.md', 'outline_digest'],
]);

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function safeProjectPath(projectRoot, relativePath) {
  const root = path.resolve(projectRoot);
  const raw = String(relativePath || '').trim();
  if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/).includes('..')) return '';
  const resolved = path.resolve(root, raw);
  return resolved.startsWith(`${root}${path.sep}`) ? resolved : '';
}

function digestProjectFile(projectRoot, relativePath, optional = false) {
  if (!relativePath && optional) return '';
  const file = safeProjectPath(projectRoot, relativePath);
  if (!file || !fs.existsSync(file) || !fs.statSync(file).isFile()) return null;
  return sha256(fs.readFileSync(file));
}

function sidecarRelativePath(sectionIndex) {
  return `追踪/private-short-extension/briefs/section-${String(sectionIndex).padStart(3, '0')}.json`;
}

function invalidatedBrief(text) {
  return /已失效|不得据此生成正文|invalidated(?:_tombstone)?/i.test(String(text || ''));
}

function buildBriefFreshnessSnapshot({ projectRoot, briefPath, sectionIndex, acceptedAnchorPath = '', task = {} }) {
  const root = path.resolve(projectRoot);
  const section = Number(sectionIndex);
  if (!Number.isInteger(section) || section < 1) throw new Error('sectionIndex must be a positive integer');
  const brief = String(briefPath || '').trim();
  const missing = [];
  const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const snapshot = {
    schema_version: '1.0.0',
    section_index: section,
    project_id: String(projectState.project_id || ''),
    plan_revision: Number(projectState.plan_revision || 0),
    brief_path: brief,
    material_digest: '',
    setting_digest: '',
    outline_digest: '',
    accepted_anchor_path: String(acceptedAnchorPath || ''),
    accepted_anchor_digest: '',
    memory_revision: '',
    brief_digest: '',
    generated_at: new Date().toISOString(),
  };
  if (!snapshot.project_id) missing.push('project-state.project_id');
  if (!Number.isInteger(snapshot.plan_revision) || snapshot.plan_revision < 1) missing.push('project-state.plan_revision');

  for (const [relativePath, field] of REQUIRED_DEPENDENCIES) {
    const digest = digestProjectFile(root, relativePath);
    if (!digest) missing.push(relativePath);
    else snapshot[field] = digest;
  }
  const briefDigest = digestProjectFile(root, brief);
  if (!briefDigest) missing.push(brief || 'Brief');
  else snapshot.brief_digest = briefDigest;

  if (acceptedAnchorPath) {
    const anchorDigest = digestProjectFile(root, acceptedAnchorPath, true);
    if (!anchorDigest) missing.push(String(acceptedAnchorPath));
    else snapshot.accepted_anchor_digest = anchorDigest;
  }

  const memory = buildShortMemorySnapshot(root, {
    task,
    sectionIndex: section,
    stageId: 'next_section_brief',
  });
  if (memory.status !== 'assembled' || !String((memory.receipt || {}).memory_revision || '')) {
    missing.push('当前作品记忆');
  } else {
    snapshot.memory_revision = memory.receipt.memory_revision;
  }

  return {
    status: missing.length ? 'missing_dependency' : 'snapshot_ready',
    sidecar: sidecarRelativePath(section),
    missing_dependencies: missing,
    snapshot,
  };
}

function writeBriefFreshnessSnapshot(options) {
  const built = buildBriefFreshnessSnapshot(options);
  if (built.status !== 'snapshot_ready') return built;
  const target = safeProjectPath(options.projectRoot, built.sidecar);
  if (!target) throw new Error('unsafe brief sidecar path');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify(built.snapshot, null, 2)}\n`, 'utf8');
  return { ...built, status: 'snapshot_written' };
}

function checkBriefFreshness({ projectRoot, briefPath, sectionIndex, acceptedAnchorPath = '', task = {} }) {
  const built = buildBriefFreshnessSnapshot({ projectRoot, briefPath, sectionIndex, acceptedAnchorPath, task });
  const sidecarFile = safeProjectPath(projectRoot, built.sidecar);
  if (!sidecarFile || !fs.existsSync(sidecarFile)) {
    return {
      status: 'missing',
      sidecar: built.sidecar,
      stale_dependencies: ['brief_freshness_snapshot'],
      missing_dependencies: built.missing_dependencies,
      invalidated_marker: false,
    };
  }

  let previous;
  try {
    previous = JSON.parse(fs.readFileSync(sidecarFile, 'utf8'));
  } catch (error) {
    return {
      status: 'missing',
      sidecar: built.sidecar,
      stale_dependencies: ['brief_freshness_snapshot'],
      missing_dependencies: [`invalid sidecar: ${error.message}`],
      invalidated_marker: false,
    };
  }

  const current = built.snapshot;
  const stale = [];
  const comparisons = [
    ['project-state.project_id', 'project_id'],
    ['project-state.plan_revision', 'plan_revision'],
    ['素材卡.md', 'material_digest'],
    ['设定.md', 'setting_digest'],
    ['小节大纲.md', 'outline_digest'],
    ['当前作品记忆', 'memory_revision'],
    [String(acceptedAnchorPath || 'accepted_anchor'), 'accepted_anchor_digest'],
    [String(briefPath || 'Brief'), 'brief_digest'],
  ];
  for (const [label, field] of comparisons) {
    if (String(previous[field] || '') !== String(current[field] || '')) stale.push(label);
  }
  const briefFile = safeProjectPath(projectRoot, briefPath);
  const marker = Boolean(briefFile && fs.existsSync(briefFile) && invalidatedBrief(fs.readFileSync(briefFile, 'utf8')));
  if (marker && !stale.includes(String(briefPath))) stale.push(String(briefPath));
  for (const missing of built.missing_dependencies) if (!stale.includes(missing)) stale.push(missing);

  return {
    status: stale.length ? 'stale' : 'current',
    sidecar: built.sidecar,
    stale_dependencies: stale,
    missing_dependencies: built.missing_dependencies,
    invalidated_marker: marker,
    snapshot: previous,
    current_digests: current,
  };
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

module.exports = {
  buildBriefFreshnessSnapshot,
  checkBriefFreshness,
  invalidatedBrief,
  sidecarRelativePath,
  writeBriefFreshnessSnapshot,
};
