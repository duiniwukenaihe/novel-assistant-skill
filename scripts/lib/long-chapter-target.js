'use strict';

// long-chapter-target — longform V2 chapter target identity.
//
// A long chapter target is the immutable binding between the current
// longform stage and one chapter, carrying both the global book identity
// (chapter_no) and the volume-local file identity (volume_chapter_no).
// The same target must flow through every long chapter stage and be echoed
// back in the result packet; any difference blocks the stage.
//
// Authority order for resolving the target:
//   1. frozen stage_execution.chapter_target (validated as-is; never rebuilt
//      from path/hash; this is what the host already accepted and committed
//      to in the previous stage)
//   2. task.active_chapter_target (validated as-is; this is the durable
//      task pointer that the runner echoes)
//   3. accepted exact-coverage V2 detail-outline review targets — enriched
//      through an exact unique outlinePath join to 追踪/schema/chapters.jsonl
//   4. legacy detail-outline targets accepted before V2 schema was added,
//      projected from path only when schema authority is explicitly opted in
//
// The schema row is the only source of truth for the volume-local title
// (draftPath). The runner and stage context must never re-derive the
// titled path from volume_chapter_no because that would silently
// overwrite the schema row's title.
//
// candidate_draft_path is derived from the real workflow_id and a digest
// of target_id (never placeholder strings) so concurrent longform
// workflows and different chapters do not collide on disk.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const SCHEMA_VERSION = 'long_chapter_target_v2';
const SCHEMA_REL = '追踪/schema/chapters.jsonl';
const LONG_CHAPTER_STAGES = new Set([
  'chapter_brief',
  'brief_review',
  'prose',
  'prose_acceptance',
  'chapter_commit',
]);

function isLongChapterStage(stageId) {
  return LONG_CHAPTER_STAGES.has(String(stageId || ''));
}

function stableHash(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest('hex');
}

// Stable identity fields used to compute target_id.
// Once a target_id is computed from these fields, any later change to any
// of them must produce a different target_id (so tampering is detectable
// by equality check).
const STABLE_TARGET_FIELDS = [
  'schema_version',
  'outline_path',
  'outline_sha256',
  'volume',
  'global_chapter_no',
  'volume_chapter_no',
  'contract_path',
  'draft_path',
];

function buildTargetId(fields) {
  const stable = STABLE_TARGET_FIELDS.map((key) => {
    const value = fields[key];
    return String(value != null ? value : '');
  }).join('\x00');
  return `sha256:${stableHash(stable)}`;
}

// Build the candidate draft path. The path is unique per workflow_id and
// per target_id (using a 16-hex digest of target_id). No placeholder
// strings — if workflow_id or target_id is missing, this returns ''.
function buildCandidateDraftPath(workflowId, targetId) {
  const safeWorkflow = String(workflowId || '').trim();
  const safeTarget = String(targetId || '').replace(/^sha256:/, '').toLowerCase();
  if (!/^[A-Za-z0-9._-]+$/.test(safeWorkflow) || !/^[0-9a-f]{64}$/.test(safeTarget)) return '';
  const digest = safeTarget.slice(0, 16);
  return `追踪/workflow/tasks/${safeWorkflow}/artifacts/${digest}/正文.md`;
}

function readSchemaRows(projectRoot) {
  const root = path.resolve(projectRoot || '');
  if (!root || !fs.existsSync(root)) return { status: 'missing_schema_authority', rows: [] };
  const file = path.join(root, SCHEMA_REL);
  if (!fs.existsSync(file)) return { status: 'missing_schema_authority', rows: [] };
  const text = fs.readFileSync(file, 'utf8');
  const rows = [];
  let lineNumber = 0;
  for (const line of text.split(/\r?\n/)) {
    lineNumber += 1;
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      rows.push(JSON.parse(trimmed));
    } catch (_) {
      return { status: 'invalid_schema_authority', rows: [], line: lineNumber };
    }
  }
  return { status: 'ok', rows };
}

function migrateLegacyPlannedDraftPaths(projectRoot, targets = []) {
  const root = path.resolve(projectRoot || '');
  const schemaFile = path.join(root, SCHEMA_REL);
  const schema = readSchemaRows(root);
  if (schema.status !== 'ok') {
    return { status: schema.status, changed_count: 0, schema_path: SCHEMA_REL };
  }
  const scoped = new Set((Array.isArray(targets) ? targets : [])
    .map((item) => String((item || {}).outline_path || (item || {}).outlinePath || '').replace(/\\/g, '/').trim())
    .filter(Boolean));
  const rows = schema.rows.map((row) => ({ ...row }));
  const existingPaths = new Map();
  for (const row of rows) {
    const outlinePath = String(row.outlinePath || row.outline_path || '').replace(/\\/g, '/').trim();
    const draftPath = String(row.draftPath || row.draft_path || row.plannedDraftPath || row.planned_draft_path || '').replace(/\\/g, '/').trim();
    if (draftPath) existingPaths.set(draftPath, outlinePath);
  }
  const changes = [];
  for (const row of rows) {
    const outlinePath = String(row.outlinePath || row.outline_path || '').replace(/\\/g, '/').trim();
    if (!outlinePath || (scoped.size > 0 && !scoped.has(outlinePath))) continue;
    if (String(row.draftPath || row.draft_path || row.plannedDraftPath || row.planned_draft_path || '').trim()) continue;
    const volume = String(row.volume || '').trim();
    const local = positiveInt(row.volumeChapterNo != null ? row.volumeChapterNo : row.volume_chapter_no);
    if (!volume || !local) continue;
    const nested = outlinePath.split('/').includes(volume);
    const planned = nested
      ? `正文/${volume}/第${String(local).padStart(3, '0')}章.md`
      : `正文/第${String(local).padStart(3, '0')}章.md`;
    const owner = existingPaths.get(planned);
    if (owner && owner !== outlinePath) {
      return {
        status: 'blocked_planned_draft_path_collision',
        changed_count: 0,
        outline_path: outlinePath,
        planned_draft_path: planned,
        conflicting_outline_path: owner,
      };
    }
    row.plannedDraftPath = planned;
    existingPaths.set(planned, outlinePath);
    changes.push({ outline_path: outlinePath, planned_draft_path: planned });
  }
  if (changes.length === 0) return { status: 'noop', changed_count: 0, schema_path: SCHEMA_REL, changes: [] };
  const payload = `${rows.map((row) => JSON.stringify(row)).join('\n')}\n`;
  const tempFile = `${schemaFile}.planned-draft-${process.pid}-${crypto.randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(tempFile, payload, 'utf8');
  fs.renameSync(tempFile, schemaFile);
  return { status: 'migrated', changed_count: changes.length, schema_path: SCHEMA_REL, changes };
}

function normalizeSchemaRow(row) {
  if (!row || typeof row !== 'object') return null;
  const outlinePath = String(row.outlinePath || row.outline_path || '').replace(/\\/g, '/').trim();
  if (!outlinePath) return null;
  const volumeChapterNo = positiveInt(row.volumeChapterNo != null ? row.volumeChapterNo : row.volume_chapter_no);
  const globalChapterNo = positiveInt(row.globalDraftOrder != null ? row.globalDraftOrder : row.global_chapter_no);
  return {
    outline_path: outlinePath,
    outline_sha256: /^[0-9a-f]{64}$/.test(String(row.outline_sha256 || '')) ? String(row.outline_sha256) : '',
    volume: String(row.volume || ''),
    volume_chapter_no: volumeChapterNo,
    global_chapter_no: globalChapterNo,
    contract_path: String(row.contractPath || row.contract_path || '').replace(/\\/g, '/').trim(),
    draft_path: String(row.draftPath || row.draft_path || row.plannedDraftPath || row.planned_draft_path || '').replace(/\\/g, '/').trim(),
  };
}

function joinSchemaByOutlinePath(projectRoot, outlinePath) {
  const target = String(outlinePath || '').replace(/\\/g, '/');
  if (!target) return { status: 'missing_outline_path' };
  const schema = readSchemaRows(projectRoot);
  if (schema.status !== 'ok') return { status: schema.status, line: schema.line || 0, outline_path: target };
  const rows = schema.rows.map(normalizeSchemaRow).filter(Boolean);
  const matches = rows.filter((row) => row.outline_path === target);
  if (matches.length === 0) return { status: 'missing_schema_identity', outline_path: target };
  if (matches.length > 1) return { status: 'ambiguous_schema_identity', outline_path: target, match_count: matches.length };
  const selected = matches[0];
  const conflicts = rows.filter((row) => row.outline_path !== target).map((row) => {
    const fields = [];
    if (selected.global_chapter_no && row.global_chapter_no === selected.global_chapter_no) fields.push('global_chapter_no');
    if (selected.volume && selected.volume_chapter_no
        && row.volume === selected.volume && row.volume_chapter_no === selected.volume_chapter_no) fields.push('volume_chapter_no');
    if (selected.contract_path && row.contract_path === selected.contract_path) fields.push('contract_path');
    if (selected.draft_path && row.draft_path === selected.draft_path) fields.push('draft_path');
    return fields.length ? { outline_path: row.outline_path, fields } : null;
  }).filter(Boolean);
  if (conflicts.length > 0) {
    return {
      status: 'ambiguous_schema_identity',
      outline_path: target,
      match_count: conflicts.length + 1,
      conflicts,
    };
  }
  return { status: 'ok', row: selected };
}

// Build a target from outline_path + outline_sha256 by joining the schema.
// `workflowId` is required so candidate_draft_path is unique per workflow.
function buildLongChapterTargetV2({ projectRoot, outlinePath, outlineSha256, workflowId = '', schemaAuthorityRequired = true } = {}) {
  const join = joinSchemaByOutlinePath(projectRoot, outlinePath);
  if (join.status === 'missing_schema_identity') {
    return { status: 'missing_schema_identity', reason_code: 'missing_schema_identity', outline_path: outlinePath };
  }
  if (join.status === 'ambiguous_schema_identity') {
    return { status: 'ambiguous_schema_identity', reason_code: 'ambiguous_schema_identity', outline_path: outlinePath, match_count: join.match_count };
  }
  if (join.status !== 'ok') {
    return { status: 'incomplete_v2_target', reason_code: 'incomplete_v2_target', outline_path: outlinePath };
  }
  const row = join.row;
  const local = row.volume_chapter_no;
  const global = row.global_chapter_no;
  const volume = row.volume;
  const draftPath = row.draft_path;
  const contractPath = row.contract_path;
  if (!local || !global || !volume || !draftPath || !contractPath) {
    return { status: 'incomplete_v2_target', reason_code: 'incomplete_v2_target', outline_path: outlinePath };
  }
  const safeOutlineSha = String(outlineSha256 || row.outline_sha256 || '');
  const target = {
    schema_version: SCHEMA_VERSION,
    outline_path: String(outlinePath || '').replace(/\\/g, '/'),
    outline_sha256: safeOutlineSha,
    volume,
    global_chapter_no: global,
    volume_chapter_no: local,
    contract_path: contractPath,
    draft_path: draftPath,
    candidate_draft_path: '',
  };
  target.target_id = buildTargetId(target);
  target.candidate_draft_path = buildCandidateDraftPath(workflowId, target.target_id);
  if (!target.candidate_draft_path) {
    return { status: 'incomplete_v2_target', reason_code: 'invalid_workflow_id', outline_path: outlinePath };
  }
  return { status: 'ok', target };
}

// Resolve the V2 target for a task. Frozen execution target and active
// target are validated as-is — never rebuilt from path/hash, because that
// would silently erase tampered fields. Only accepted detail-outline
// targets go through the schema join (enrichment path).
function resolveLongChapterTargetV2(task, { projectRoot, schemaAuthorityRequired = true, workflowId = '' } = {}) {
  const safeTask = task || {};
  const expectedWorkflowId = workflowId || safeTask.workflow_id || '';
  const frozen = ((safeTask.stage_execution || {}).chapter_target) || null;
  if (frozen) {
    const validation = validateLongChapterTargetV2(frozen, { projectRoot, workflowId: expectedWorkflowId });
    if (!validation.ok) {
      return { status: 'blocked_chapter_target_echo_mismatch', reason_code: 'incomplete_v2_target', missing_fields: validation.missing_fields };
    }
    // Frozen target must equal active target exactly when both exist.
    const active = safeTask.active_chapter_target;
    if (active && typeof active === 'object') {
      const diff = diffTargets(frozen, active);
      if (diff.length) {
        return { status: 'blocked_chapter_target_echo_mismatch', reason_code: 'frozen_vs_active_mismatch', diff };
      }
    }
    return { status: 'ok', target: { ...frozen } };
  }
  const active = safeTask.active_chapter_target;
  if (active && typeof active === 'object') {
    const validation = validateLongChapterTargetV2(active, { projectRoot, workflowId: expectedWorkflowId });
    if (!validation.ok) {
      return { status: 'blocked_chapter_target_echo_mismatch', reason_code: 'incomplete_v2_target', missing_fields: validation.missing_fields };
    }
    return { status: 'ok', target: { ...active } };
  }
  const accepted = Array.isArray(safeTask.accepted_detail_outline_targets) ? safeTask.accepted_detail_outline_targets : [];
  let firstError = null;
  for (const candidate of accepted) {
    if (!candidate || !candidate.outline_path) continue;
    const result = buildLongChapterTargetV2({
      projectRoot,
      outlinePath: candidate.outline_path,
      outlineSha256: candidate.outline_sha256,
      workflowId: expectedWorkflowId,
      schemaAuthorityRequired,
    });
    if (result.status === 'ok') return { status: 'ok', target: result.target };
    if (!firstError) firstError = result;
  }
  if (firstError) return { status: firstError.status, reason_code: firstError.reason_code || firstError.status, outline_path: firstError.outline_path };
  return { status: 'incomplete_v2_target', reason_code: 'incomplete_v2_target' };
}

// Enrich a list of outline identities (path + sha) into full V2 targets.
// Used by the state machine after a V2 detail-outline review is accepted:
// every accepted identity must resolve through the schema uniquely.
function enrichAcceptedOutlineTargets(projectRoot, items, workflowId = '') {
  const safeItems = Array.isArray(items) ? items : [];
  const enriched = [];
  const errors = [];
  for (const item of safeItems) {
    if (!item || !item.outline_path || !/^[0-9a-f]{64}$/.test(String(item.outline_sha256 || ''))) {
      errors.push({ status: 'incomplete_v2_target', reason_code: 'incomplete_v2_target', outline_path: (item || {}).outline_path || '' });
      continue;
    }
    const result = buildLongChapterTargetV2({
      projectRoot,
      outlinePath: item.outline_path,
      outlineSha256: item.outline_sha256,
      workflowId,
    });
    if (result.status === 'ok') enriched.push(result.target);
    else errors.push(result);
  }
  return { targets: enriched, errors };
}

function validateLongChapterTargetV2(target, { projectRoot = '', workflowId = '' } = {}) {
  if (!target || typeof target !== 'object') {
    return { ok: false, reason_code: 'incomplete_v2_target', missing_fields: ['target'] };
  }
  const required = [
    'schema_version',
    'target_id',
    'outline_path',
    'outline_sha256',
    'volume',
    'global_chapter_no',
    'volume_chapter_no',
    'contract_path',
    'draft_path',
    'candidate_draft_path',
  ];
  const missingFields = required.filter((field) => {
    const value = target[field];
    if (field === 'global_chapter_no' || field === 'volume_chapter_no') return !positiveInt(value);
    return !String(value || '').trim();
  });
  if (target.schema_version !== SCHEMA_VERSION) missingFields.push('schema_version');
  if (!/^sha256:[a-f0-9]{64}$/.test(String(target.target_id || ''))) missingFields.push('target_id_format');
  if (!/^[0-9a-f]{64}$/.test(String(target.outline_sha256 || ''))) missingFields.push('outline_sha256_format');
  for (const field of ['outline_path', 'contract_path', 'draft_path', 'candidate_draft_path']) {
    const value = String(target[field] || '').replace(/\\/g, '/');
    if (!value || path.isAbsolute(value) || value.split('/').includes('..')) missingFields.push(`${field}_unsafe`);
  }
  if (missingFields.length === 0 && buildTargetId(target) !== String(target.target_id || '')) {
    missingFields.push('target_id_mismatch');
  }
  const candidateMatch = String(target.candidate_draft_path || '').match(/^追踪\/workflow\/tasks\/([^/]+)\/artifacts\/([0-9a-f]{16})\/正文\.md$/);
  const targetDigest = String(target.target_id || '').replace(/^sha256:/, '').slice(0, 16);
  if (!candidateMatch || candidateMatch[2] !== targetDigest) {
    missingFields.push('candidate_draft_path_mismatch');
  }
  if (workflowId && (!candidateMatch || candidateMatch[1] !== String(workflowId))) {
    missingFields.push('candidate_workflow_mismatch');
  }
  if (projectRoot && missingFields.length === 0) {
    const joined = joinSchemaByOutlinePath(projectRoot, target.outline_path);
    if (joined.status !== 'ok') missingFields.push(`schema_${joined.status}`);
    else {
      const expected = buildLongChapterTargetV2({
        projectRoot,
        outlinePath: target.outline_path,
        outlineSha256: target.outline_sha256,
        workflowId: candidateMatch[1],
      });
      if (expected.status !== 'ok' || diffTargets(expected.target, target).length > 0) missingFields.push('schema_target_mismatch');
    }
    const root = path.resolve(projectRoot);
    const outlineFile = path.resolve(root, String(target.outline_path || ''));
    const relativeOutline = path.relative(root, outlineFile);
    if (!relativeOutline || relativeOutline.startsWith('..') || path.isAbsolute(relativeOutline)
        || !fs.existsSync(outlineFile) || !fs.statSync(outlineFile).isFile()) {
      missingFields.push('outline_file_missing');
    } else {
      const actualOutlineHash = stableHash(fs.readFileSync(outlineFile));
      if (actualOutlineHash !== String(target.outline_sha256 || '')) missingFields.push('outline_sha256_mismatch');
    }
  }
  return { ok: missingFields.length === 0, missing_fields: Array.from(new Set(missingFields)), reason_code: missingFields.length ? 'incomplete_v2_target' : '' };
}

function assertTargetsEqual(stageTarget, resultTarget) {
  const diff = diffTargets(stageTarget, resultTarget);
  if (!diff.length) return { ok: true };
  const error = new Error(`long chapter target echo mismatch: ${diff.join(', ')}`);
  error.status = 'blocked_chapter_target_echo_mismatch';
  error.diff = diff;
  return { ok: false, error };
}

function diffTargets(a, b) {
  const fields = [
    'schema_version',
    'target_id',
    'outline_path',
    'outline_sha256',
    'volume',
    'global_chapter_no',
    'volume_chapter_no',
    'contract_path',
    'draft_path',
    'candidate_draft_path',
  ];
  const diff = [];
  for (const field of fields) {
    if (String((a || {})[field] || '') !== String((b || {})[field] || '')) diff.push(field);
  }
  return diff;
}

function formatLongChapterDisplay(target) {
  if (!target || typeof target !== 'object') return '';
  const global = positiveInt(target.global_chapter_no);
  const local = positiveInt(target.volume_chapter_no);
  if (!global || !local) return '';
  return `全书第${String(global).padStart(3, '0')}章 / ${String(target.volume || '')}第${String(local).padStart(3, '0')}章`;
}

function expectedLongChapterWriteSet(stageId, target) {
  const stage = String(stageId || '');
  if (!target || typeof target !== 'object') return null;
  if (stage === 'chapter_brief') return [String(target.contract_path || '')].filter(Boolean);
  if (stage === 'brief_review' || stage === 'prose_acceptance') return [];
  if (stage === 'prose') return [String(target.candidate_draft_path || '')].filter(Boolean);
  if (stage === 'chapter_commit') return [String(target.draft_path || '')].filter(Boolean);
  return null;
}

function volumeFromPath(p) {
  const match = String(p || '').replace(/\\/g, '/').match(/(?:^|\/)第\s*([0-9一二三四五六七八九十百]+)\s*卷(?=\/|$)/);
  return match ? `第${match[1]}卷` : '';
}

function chapterNumberFromPath(p) {
  const match = String(p || '').replace(/\\/g, '/').match(/第\s*0*(\d+)\s*章/);
  return match ? Number(match[1]) : 0;
}

function positiveInt(value) {
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : 0;
}

module.exports = {
  LONG_CHAPTER_STAGES,
  SCHEMA_REL,
  SCHEMA_VERSION,
  STABLE_TARGET_FIELDS,
  assertTargetsEqual,
  buildCandidateDraftPath,
  buildLongChapterTargetV2,
  buildTargetId,
  diffTargets,
  enrichAcceptedOutlineTargets,
  expectedLongChapterWriteSet,
  formatLongChapterDisplay,
  isLongChapterStage,
  joinSchemaByOutlinePath,
  migrateLegacyPlannedDraftPaths,
  resolveLongChapterTargetV2,
  validateLongChapterTargetV2,
};
