'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteJson } = require('./workflow-state-store');

const STATE_REL = '追踪/private-short-extension/project-state.json';
const FINISHED = new Set(['completed', 'complete', 'closed', 'cancelled', 'canceled', 'superseded', 'archived']);

function readShortProjectState(projectRoot) {
  const file = path.join(path.resolve(projectRoot), STATE_REL);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
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
  const title = meaningfulTitle(options.title) || meaningfulTitle(current.project_title) || path.basename(root);
  const planned = positiveInt(current.planned_sections || ((current.narrative || {}).planned_sections));
  const state = {
    ...current,
    schema_version: '2.0.0',
    project_id: String(current.project_id || crypto.randomUUID()),
    project_title: title,
    active_write_workflow_id: workflowId,
    workflow_history: history,
    plan_revision: nonNegativeInt(current.plan_revision),
    planned_sections: planned,
    current_section_index: positiveInt(current.current_section_index) || 1,
    accepted_sections: Array.isArray(current.accepted_sections) ? current.accepted_sections : [],
    status: String(current.status || options.status || 'planning'),
    created_at: String(current.created_at || now),
    updated_at: now,
    narrative: {
      ...(current.narrative && typeof current.narrative === 'object' ? current.narrative : {}),
      planned_sections: planned,
    },
  };
  atomicWriteJson(path.join(root, STATE_REL), state);
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
  atomicWriteJson(path.join(root, STATE_REL), next);
  return next;
}

function outlineSectionCount(text) {
  const values = [...String(text || '').matchAll(/^#{1,6}\s*第\s*0*(\d+)\s*节(?:\s*[：:]|\s|$)/gmu)]
    .map((match) => positiveInt(match[1])).filter(Boolean);
  return values.length ? Math.max(...values) : 0;
}

function isUnfinished(task) {
  const status = String((task || {}).status || ((task || {}).lifecycle || {}).status || 'running').toLowerCase();
  return !FINISHED.has(status);
}

function meaningfulTitle(value) {
  const title = String(value || '').trim();
  if (!title || /^(新短篇|短篇|未命名(?:新书|短篇)?|new-book)$/iu.test(title)) return '';
  return title;
}

function safeProjectFile(root, relativePath) {
  const raw = String(relativePath || '').trim();
  if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/).includes('..')) return '';
  const file = path.resolve(root, raw);
  return file.startsWith(`${root}${path.sep}`) ? file : '';
}
function normalizeRelative(value) { return String(value || '').replace(/\\/g, '/').replace(/^\.\//, ''); }
function positiveInt(value) { const number = Number(value); return Number.isInteger(number) && number > 0 ? number : 0; }
function nonNegativeInt(value) { const number = Number(value); return Number.isInteger(number) && number >= 0 ? number : 0; }
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function projectError(code, message) { const error = new Error(message); error.code = code; error.status = code.toLowerCase(); return error; }

module.exports = {
  STATE_REL,
  advanceShortPlanRevision,
  assertShortProjectOwnership,
  ensureShortProjectState,
  outlineSectionCount,
  readShortProjectState,
};
