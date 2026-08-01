'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { buildShortMemorySnapshot } = require('./short-memory-snapshot');
const { readShortProjectState, resolveShortStateRelative } = require('./short-project-state');

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

function sidecarRelativePath(sectionIndex, projectRoot = '') {
  const leaf = `briefs/section-${String(sectionIndex).padStart(3, '0')}.json`;
  return projectRoot ? resolveShortStateRelative(projectRoot, leaf, { forWrite: true }) : leaf;
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
  const projectState = readShortProjectState(root) || {};
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
    sidecar: sidecarRelativePath(section, root),
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
      changed_dimensions: ['identity'],
      affects_current_section: true,
      recovery: 'rebuild_current_brief_once',
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
      changed_dimensions: ['identity'],
      affects_current_section: true,
      recovery: 'rebuild_current_brief_once',
      missing_dependencies: [`invalid sidecar: ${error.message}`],
      invalidated_marker: false,
    };
  }

  const current = built.snapshot;
  const stale = [];
  const changedDimensions = new Set();
  // Each comparison is tagged with a semantic dimension so callers can classify
  // why a brief went stale (planning / material / memory / anchor / identity /
  // brief) instead of only getting a flat list of file labels. The legacy
  // stale_dependencies string array is preserved for backward compatibility.
  const comparisons = [
    { label: 'project-state.project_id', field: 'project_id', dimension: 'identity' },
    { label: 'project-state.plan_revision', field: 'plan_revision', dimension: 'planning' },
    { label: '素材卡.md', field: 'material_digest', dimension: 'material' },
    { label: '设定.md', field: 'setting_digest', dimension: 'planning' },
    { label: '小节大纲.md', field: 'outline_digest', dimension: 'planning' },
    { label: '当前作品记忆', field: 'memory_revision', dimension: 'memory' },
    { label: String(acceptedAnchorPath || 'accepted_anchor'), field: 'accepted_anchor_digest', dimension: 'anchor' },
    { label: String(briefPath || 'Brief'), field: 'brief_digest', dimension: 'brief' },
  ];
  for (const { label, field, dimension } of comparisons) {
    if (String(previous[field] || '') !== String(current[field] || '')) {
      stale.push(label);
      changedDimensions.add(dimension);
    }
  }
  const briefFile = safeProjectPath(projectRoot, briefPath);
  const marker = Boolean(briefFile && fs.existsSync(briefFile) && invalidatedBrief(fs.readFileSync(briefFile, 'utf8')));
  if (marker && !stale.includes(String(briefPath))) {
    stale.push(String(briefPath));
    changedDimensions.add('brief');
  }
  if (previous.invalidated === true) {
    stale.push(`feedback:${String(previous.invalidated_by_feedback || 'current')}`);
    changedDimensions.add('brief');
  }
  for (const missing of built.missing_dependencies) {
    if (!stale.includes(missing)) stale.push(missing);
    // Missing dependencies are structural gaps; tag as identity so callers see
    // the brief cannot be trusted rather than silently treating it as current.
    changedDimensions.add('identity');
  }

  // affects_current_section: whether the detected change can influence the
  // brief for THIS section.
  //  - memory_revision drift is already section-aware: selectFacts and
  //    selectPlanningConstraints filter by sectionIndex, so a future-section
  //    fact/constraint cannot move the revision. A change here is real.
  //  - planning (设定/小节大纲) and material (素材卡) are whole-file digests
  //    with no per-section breakdown available in the snapshot; treat them as
  //    potentially affecting the current section (conservative default).
  //  - identity changes (project_id / plan_revision) always affect the section.
  //  - anchor / brief / pure-identity marker changes are about THIS section's
  //    accepted artifact, so they also count.
  const DIMENSIONS_AFFECTING_CURRENT = new Set(['planning', 'material', 'memory', 'identity', 'anchor', 'brief']);
  const affectsCurrentSection = [...changedDimensions].some(key => DIMENSIONS_AFFECTING_CURRENT.has(key));

  return {
    status: stale.length ? 'stale' : 'current',
    sidecar: built.sidecar,
    stale_dependencies: stale, // backward-compatible flat list of labels
    changed_dimensions: [...changedDimensions], // semantic dimension classification
    affects_current_section: affectsCurrentSection,
    recovery: stale.length ? 'rebuild_current_brief_once' : null,
    missing_dependencies: built.missing_dependencies,
    invalidated_marker: marker,
    snapshot: previous,
    current_digests: current,
  };
}

function invalidateBriefFreshnessSnapshot({ projectRoot, sectionIndex, feedbackId = '' }) {
  const relative = sidecarRelativePath(sectionIndex, projectRoot);
  const file = safeProjectPath(projectRoot, relative);
  if (!file) throw new Error('unsafe brief sidecar path');
  let snapshot = {};
  try { snapshot = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { snapshot = {}; }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({
    ...snapshot,
    schema_version: String(snapshot.schema_version || '1.0.0'),
    section_index: Number(sectionIndex),
    invalidated: true,
    invalidated_by_feedback: String(feedbackId || ''),
    invalidated_at: new Date().toISOString(),
  }, null, 2)}\n`, 'utf8');
  return { status: 'invalidated', sidecar: relative };
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

module.exports = {
  buildBriefFreshnessSnapshot,
  checkBriefFreshness,
  invalidateBriefFreshnessSnapshot,
  invalidatedBrief,
  sidecarRelativePath,
  writeBriefFreshnessSnapshot,
};
