'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');

const CANONICAL_STATE_ROOT_REL = '追踪/story-system/short';
const LEGACY_STATE_ROOT_REL = '追踪/private-short-extension';
const STATE_REL = `${CANONICAL_STATE_ROOT_REL}/project-state.json`;
const LEGACY_STATE_REL = `${LEGACY_STATE_ROOT_REL}/project-state.json`;
const FINISHED = new Set(['completed', 'complete', 'closed', 'cancelled', 'canceled', 'superseded', 'archived']);

function readShortProjectState(projectRoot) {
  const file = path.join(path.resolve(projectRoot), resolveShortStateRelative(projectRoot, 'project-state.json'));
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function resolveShortStateRelative(projectRoot, leaf, options = {}) {
  const root = path.resolve(projectRoot);
  const safeLeaf = normalizeStateLeaf(leaf);
  const canonicalRel = `${CANONICAL_STATE_ROOT_REL}/${safeLeaf}`;
  const legacyRel = `${LEGACY_STATE_ROOT_REL}/${safeLeaf}`;
  const canonicalFile = path.join(root, canonicalRel);
  const legacyFile = path.join(root, legacyRel);

  if (!options.forWrite) {
    if (fs.existsSync(canonicalFile)) return canonicalRel;
    if (fs.existsSync(legacyFile)) return legacyRel;
  }

  if (fs.existsSync(path.join(root, STATE_REL)) || fs.existsSync(path.join(root, CANONICAL_STATE_ROOT_REL, '.storage-version.json'))) {
    return canonicalRel;
  }
  if (fs.existsSync(path.join(root, LEGACY_STATE_REL))) return legacyRel;
  return canonicalRel;
}

function shortStateFile(projectRoot, leaf, options = {}) {
  return path.join(path.resolve(projectRoot), resolveShortStateRelative(projectRoot, leaf, options));
}

function migrateShortStateStorage(projectRoot) {
  const root = path.resolve(projectRoot);
  const legacyRoot = path.join(root, LEGACY_STATE_ROOT_REL);
  const canonicalRoot = path.join(root, CANONICAL_STATE_ROOT_REL);
  if (!fs.existsSync(path.join(legacyRoot, 'project-state.json'))) {
    return { status: 'not_needed', copied: [], canonical_root: CANONICAL_STATE_ROOT_REL };
  }

  fs.mkdirSync(canonicalRoot, { recursive: true });
  const copied = [];
  for (const name of fs.readdirSync(legacyRoot)) {
    if (!isPublicShortStateAsset(name)) continue;
    const source = path.join(legacyRoot, name);
    const target = path.join(canonicalRoot, name);
    if (fs.existsSync(target)) continue;
    fs.cpSync(source, target, { recursive: true, errorOnExist: false });
    copied.push(name);
  }
  atomicWriteJson(path.join(canonicalRoot, '.storage-version.json'), {
    schema_version: '1.0.0',
    status: 'canonical',
    migrated_from: LEGACY_STATE_ROOT_REL,
    migrated_at: new Date().toISOString(),
  });
  return { status: 'migrated', copied, canonical_root: CANONICAL_STATE_ROOT_REL, legacy_root: LEGACY_STATE_ROOT_REL };
}

function assertShortProjectOwnership(projectRoot, state, workflowId) {
  const root = path.resolve(projectRoot);
  const requested = String(workflowId || '').trim();
  if (!requested) throw projectError('SHORT_PROJECT_WORKFLOW_ID_REQUIRED', 'short project mutation requires workflow_id');
  const owner = String((state || {}).active_write_workflow_id || '').trim();
  if (!owner || owner === requested) return { status: 'ok', workflow_id: requested };
  const ownerTask = readJson(path.join(root, '追踪', 'workflow', 'tasks', owner, 'task.json'));
  if (ownerTask && isUnfinished(ownerTask)) {
    throw projectError('SHORT_PROJECT_OWNERSHIP_CONFLICT', `short project is owned by unfinished workflow ${owner}`);
  }
  return { status: 'rebind_allowed', workflow_id: requested, previous_workflow_id: owner };
}

function ensureShortProjectState(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const workflowId = String(options.workflowId || '').trim();
  const current = readShortProjectState(root) || {};
  const ownership = assertShortProjectOwnership(root, current, workflowId);
  const now = new Date().toISOString();
  const previousOwner = String(current.active_write_workflow_id || '').trim();
  const history = Array.isArray(current.workflow_history) ? current.workflow_history.slice() : [];
  if (ownership.status === 'rebind_allowed' && previousOwner && !history.includes(previousOwner)) history.push(previousOwner);
  const title = meaningfulTitle(options.title) || resolveShortProjectTitle(current, path.basename(root));
  const planned = positiveInt(current.planned_sections || ((current.narrative || {}).planned_sections));
  const state = {
    ...current,
    schema_version: '2.0.0',
    project_id: String(current.project_id || options.projectId || crypto.randomUUID()),
    project_title: title,
    active_write_workflow_id: workflowId,
    workflow_history: history,
    plan_revision: nonNegativeInt(current.plan_revision),
    planned_sections: planned,
    current_section_index: positiveInt(current.current_section_index) || 1,
    accepted_sections: Array.isArray(current.accepted_sections) ? current.accepted_sections : [],
    status: String(current.status || options.status || 'planning'),
    selected_material: options.selectedMaterial || current.selected_material || null,
    source_incubator: options.sourceIncubator || current.source_incubator || null,
    created_at: String(current.created_at || now),
    updated_at: now,
    narrative: {
      ...(current.narrative && typeof current.narrative === 'object' ? current.narrative : {}),
      planned_sections: planned,
    },
  };
  atomicWriteJson(shortStateFile(root, 'project-state.json', { forWrite: true }), state);
  return state;
}

function advanceShortPlanRevision(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const workflowId = String(options.workflowId || '').trim();
  const state = ensureShortProjectState(root, { workflowId, title: options.title });
  const outlinePath = String(options.outlinePath || '小节大纲.md');
  const outlineFile = safeProjectFile(root, outlinePath);
  if (!outlineFile || !fs.existsSync(outlineFile) || !fs.statSync(outlineFile).isFile()) {
    throw projectError('SHORT_PROJECT_OUTLINE_MISSING', `short outline is unavailable: ${outlinePath}`);
  }
  const outline = fs.readFileSync(outlineFile, 'utf8');
  const digest = String(options.outlineHash || sha256(outline));
  const planned = positiveInt(options.plannedSections) || outlineSectionCount(outline);
  if (!planned) throw projectError('SHORT_PROJECT_PLAN_EMPTY', 'short outline does not contain a planned section sequence');
  const changed = String(state.plan_digest || '') !== digest;
  const next = {
    ...state,
    plan_revision: changed ? nonNegativeInt(state.plan_revision) + 1 : nonNegativeInt(state.plan_revision),
    plan_digest: digest,
    plan_path: normalizeRelative(outlinePath),
    planned_sections: planned,
    narrative: { ...(state.narrative || {}), planned_sections: planned },
    updated_at: new Date().toISOString(),
  };
  atomicWriteJson(shortStateFile(root, 'project-state.json', { forWrite: true }), next);
  return next;
}

function outlineSectionCount(text) {
  const source = String(text || '');
  const explicit = source.match(/总小节数\s*[：:]\s*(\d+)\s*节?/u);
  if (explicit) return positiveInt(explicit[1]);
  const values = [
    ...source.matchAll(/^#{1,6}\s*第\s*([0-9０-９一二三四五六七八九十百千两〇零]+)\s*节(?:\s*[：:｜]|\s|$)/gmu),
    ...source.matchAll(/^#{1,6}\s*节\s*0*(\d+)(?:\s*[：:｜]|\s|$)/gmu),
  ].map((match) => parseShortSectionOrdinal(match[1])).filter(Boolean);
  if (/^#{1,6}\s*逐节(?:蓝图|大纲|细纲)/mu.test(source)) {
    values.push(...[...source.matchAll(/^#{2,6}\s*0*(\d+)\s*[.、]\s*\S/gmu)]
      .map((match) => positiveInt(match[1])).filter(Boolean));
  }
  return values.length ? Math.max(...values) : 0;
}

function parseShortSectionOrdinal(value) {
  const raw = String(value || '').trim();
  if (!raw) return 0;
  const normalizedDigits = raw.replace(/[０-９]/gu, (char) => String(char.codePointAt(0) - '０'.codePointAt(0)));
  if (/^\d+$/u.test(normalizedDigits)) return positiveInt(normalizedDigits);
  const digits = new Map([
    ['零', 0], ['〇', 0], ['一', 1], ['二', 2], ['两', 2], ['三', 3], ['四', 4],
    ['五', 5], ['六', 6], ['七', 7], ['八', 8], ['九', 9],
  ]);
  const units = new Map([['十', 10], ['百', 100], ['千', 1000]]);
  let total = 0;
  let current = 0;
  for (const char of normalizedDigits) {
    if (digits.has(char)) {
      current = digits.get(char);
      continue;
    }
    const unit = units.get(char);
    if (!unit) return 0;
    total += (current || 1) * unit;
    current = 0;
  }
  return positiveInt(total + current);
}

function isUnfinished(task) {
  const status = String((task || {}).status || ((task || {}).lifecycle || {}).status || 'running').toLowerCase();
  return !FINISHED.has(status);
}

function meaningfulTitle(value) {
  const title = String(value || '').trim();
  if (!title
    || /^(新短篇|短篇|未命名(?:新书|短篇)?|new-book)$/iu.test(title)
    || /^第\s*0*\d+\s*[章节](?:\s*(?:现稿|草稿|正文))?$/u.test(title)) return '';
  return title;
}

function resolveShortProjectTitle(state = {}, fallback = '') {
  const source = state && typeof state === 'object' ? state : {};
  for (const candidate of [
    source.working_title,
    source.book_title,
    source.title,
    source.project_title,
    fallback,
  ]) {
    const title = meaningfulTitle(candidate);
    if (title) return title;
  }
  return '';
}

function safeProjectFile(root, relativePath) {
  const raw = String(relativePath || '').trim();
  if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/).includes('..')) return '';
  const file = path.resolve(root, raw);
  return file.startsWith(`${root}${path.sep}`) ? file : '';
}
function normalizeRelative(value) { return String(value || '').replace(/\\/g, '/').replace(/^\.\//, ''); }
function normalizeStateLeaf(value) {
  const leaf = normalizeRelative(value).replace(/^\/+/, '');
  if (!leaf || path.isAbsolute(leaf) || leaf.split('/').includes('..')) {
    throw projectError('SHORT_STATE_PATH_INVALID', `invalid short state path: ${value}`);
  }
  return leaf;
}
function isPublicShortStateAsset(name) {
  return name === 'project-state.json'
    || name === 'section-title-lock.json'
    || name === 'briefs'
    || /^section-\d{3}-anchor\.json$/u.test(name);
}
function positiveInt(value) { const number = Number(value); return Number.isInteger(number) && number > 0 ? number : 0; }
function nonNegativeInt(value) { const number = Number(value); return Number.isInteger(number) && number >= 0 ? number : 0; }
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function projectError(code, message) { const error = new Error(message); error.code = code; error.status = code.toLowerCase(); return error; }

module.exports = {
  CANONICAL_STATE_ROOT_REL,
  LEGACY_STATE_REL,
  LEGACY_STATE_ROOT_REL,
  STATE_REL,
  advanceShortPlanRevision,
  assertShortProjectOwnership,
  ensureShortProjectState,
  migrateShortStateStorage,
  outlineSectionCount,
  parseShortSectionOrdinal,
  readShortProjectState,
  resolveShortProjectTitle,
  resolveShortStateRelative,
  shortStateFile,
};
