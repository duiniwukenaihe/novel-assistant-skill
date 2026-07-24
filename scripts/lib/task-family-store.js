'use strict';

const crypto = require('crypto');
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const {
  acquireProjectLock,
  atomicWriteJson,
  appendJsonl,
} = require('./workflow-state-store');
const {
  heartbeatLiveness,
  recordSessionHeartbeat,
} = require('../workflow-session-heartbeat');

const SCHEMA_VERSION = '1.0.0';
const TERMINAL = new Set(['completed', 'completed_verified', 'done', 'pass', 'closed', 'cancelled', 'canceled', 'archived', 'superseded']);

function workflowRoot(projectRoot) {
  return path.join(path.resolve(projectRoot), '追踪', 'workflow');
}

function familiesRoot(projectRoot) {
  return path.join(workflowRoot(projectRoot), 'families');
}

function indexPath(projectRoot) {
  return path.join(workflowRoot(projectRoot), 'task-family-index.json');
}

function familyPath(projectRoot, familyId) {
  return path.join(familiesRoot(projectRoot), String(familyId), 'family.json');
}

function branchIndexPath(projectRoot, familyId) {
  return path.join(familiesRoot(projectRoot), String(familyId), 'branch-index.json');
}

function sessionRegistryPath(projectRoot) {
  return path.join(workflowRoot(projectRoot), 'session-registry.json');
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function stableHash(value, length = 16) {
  return crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex').slice(0, length);
}

function bookId(projectRoot) {
  const root = path.resolve(projectRoot);
  return `book-${stableHash({ root }, 20)}`;
}

function workflowClass(task) {
  const type = String((task || {}).workflow_type || '').trim();
  if (type === 'private_short_startup') return 'short_write';
  if (/^long_(write|daily_write|revision|expansion)/.test(type)) return 'long_write';
  if (/^short_(write|revision|deslop|startup)/.test(type)) return 'short_write';
  if (/review|anti_ai/.test(type)) return 'review_repair';
  if (/analyze|deconstruction/.test(type)) return 'deconstruction_learning';
  if (/scan/.test(type)) return 'market_scan';
  return type || 'workflow_task';
}

function normalizeScope(value) {
  const raw = String(value || '').replace(/\s+/g, '').trim();
  const range = raw.match(/(\d+)[-到至~](\d+)/);
  if (range) return `global:${Number(range[1])}-${Number(range[2])}`;
  const chapter = raw.match(/第(\d+)章/);
  if (chapter) {
    const volume = raw.match(/第(\d+)卷/);
    return `chapter:${volume ? volume[1] : 'unknown'}-${chapter[1]}`;
  }
  return raw.toLowerCase() || 'unspecified';
}

function objectiveKind(task) {
  const text = `${(task || {}).user_goal || ''} ${(task || {}).scope || ''}`;
  if (/去\s*AI|AI味|AI句式|破折号|标点/.test(text)) return 'prose_ai_repair';
  if (/钩子|人物|情节|剧情|设定|一致性|审阅|审查/.test(text)) return 'review_story';
  if (/回炉|重写|修订|修改/.test(text)) return 'revision';
  if (/续写|写第|正文|章节/.test(text)) return 'prose_write';
  if (/拆文|拆书|分析/.test(text)) return 'deconstruction';
  if (/扫榜|趋势|市场/.test(text)) return 'market_scan';
  return 'general';
}

function goalSignature(task) {
  return String((task || {}).user_goal || '')
    .replace(/\s+/g, '')
    .replace(/[，。！？、；：“”"'`]/g, '')
    .slice(0, 120)
    .toLowerCase();
}

function identityForTask(projectRoot, task) {
  const operation = objectiveKind(task);
  const normalizedScope = normalizeScope((task || {}).scope);
  const identity = {
    book_id: bookId(projectRoot),
    workflow_class: workflowClass(task),
    operation,
    target_kind: normalizedScope.startsWith('chapter:') ? 'chapter' : normalizedScope.startsWith('global:') ? 'chapter_range' : 'project',
    normalized_scope: normalizedScope,
    objective_kind: operation,
    goal_signature: goalSignature(task),
  };
  return { ...identity, key: `tf-${stableHash(identity, 20)}` };
}

function listTaskFamilies(projectRoot) {
  const root = path.resolve(projectRoot);
  const index = readJson(indexPath(root));
  const ids = Array.isArray(index && index.family_ids) ? index.family_ids : [];
  const families = ids.map((id) => readJson(familyPath(root, id))).filter((item) => item && !item.__error);
  const unfinished = families.filter(isUnfinishedFamily);
  return {
    schemaVersion: SCHEMA_VERSION,
    book_id: bookId(root),
    families,
    unfinished_family_count: unfinished.length,
    active_family_count: unfinished.filter((family) => family.status === 'active').length,
  };
}

function readTaskFamily(projectRoot, familyId) {
  const family = readJson(familyPath(projectRoot, familyId));
  return family && !family.__error ? family : null;
}

function resolveTaskRelationship(projectRoot, task) {
  const workflowId = String((task || {}).workflow_id || '');
  const lifecycle = (task || {}).lifecycle || {};
  const explicitIds = new Set([
    String((task || {}).task_family_id || ''),
    String((task || {}).parent_workflow_id || ''),
    String(lifecycle.previous_workflow_id || ''),
    String(lifecycle.focus_switched_from || ''),
    String(lifecycle.focus_switched_to || ''),
  ].filter(Boolean));
  const identity = identityForTask(projectRoot, task);
  const inventory = listTaskFamilies(projectRoot);
  for (const family of inventory.families) {
    const familyIdentity = effectiveFamilyIdentity(family);
    const branchIds = new Set((family.branches || []).map((branch) => String(branch.workflow_id || '')));
    const directFamily = String(family.task_family_id || '') === String((task || {}).task_family_id || '');
    const compatibleLineage = sameWorkflowBoundary(familyIdentity, identity) && [...explicitIds].some((id) => branchIds.has(id));
    if (directFamily || compatibleLineage) {
      return { kind: 'same_family', family, identity, reason: 'explicit_lineage' };
    }
  }
  const exact = inventory.families.find((family) => sameStructuredIdentity(effectiveFamilyIdentity(family), identity));
  if (exact) return { kind: 'same_family', family: exact, identity, reason: 'structured_identity' };
  const potential = inventory.families.filter((family) => {
    const other = effectiveFamilyIdentity(family);
    return sameWorkflowBoundary(other, identity) && !sameStructuredIdentity(other, identity);
  });
  if (potential.length) return { kind: 'potential_duplicate', family: null, candidates: potential, identity, reason: 'overlapping_scope' };
  return { kind: 'independent', family: null, identity, reason: workflowId ? 'new_workflow' : 'new_objective' };
}

function effectiveFamilyIdentity(family) {
  const identity = { ...((family || {}).identity || {}) };
  if (identity.workflow_class === 'private_short_startup') identity.workflow_class = 'short_write';
  if (!identity.goal_signature) {
    const head = ((family || {}).branches || []).find((branch) => String(branch.workflow_id) === String((family || {}).head_workflow_id)) || ((family || {}).branches || [])[0];
    identity.goal_signature = goalSignature({ user_goal: (head || {}).user_goal || '' });
  }
  return identity;
}

function sameWorkflowBoundary(left, right) {
  return String(left.workflow_class || '') === String(right.workflow_class || '')
    && String(left.normalized_scope || '') === String(right.normalized_scope || '');
}

function sameStructuredIdentity(left, right) {
  return sameWorkflowBoundary(left, right)
    && String(left.objective_kind || '') === String(right.objective_kind || '')
    && String(left.goal_signature || '') === String(right.goal_signature || '');
}

function ensureTaskFamily(projectRoot, task, options = {}) {
  const root = path.resolve(projectRoot);
  if (!task || !task.workflow_id) throw new Error('task family requires workflow_id');
  const write = options.write === true;
  const release = write && !options.projectLockHeld ? acquireProjectLock(root, 'task-family-store') : null;
  try {
    const relationship = resolveTaskRelationship(root, task);
    const now = new Date().toISOString();
    const identity = relationship.identity;
    const familyId = relationship.family ? relationship.family.task_family_id : identity.key;
    const family = relationship.family ? clone(relationship.family) : {
      schemaVersion: SCHEMA_VERSION,
      task_family_id: familyId,
      book_id: identity.book_id,
      identity,
      status: 'active',
      head_workflow_id: '',
      branches: [],
      sessions: [],
      writer_lease: null,
      created_at: now,
      updated_at: now,
    };
    family.identity = effectiveFamilyIdentity(family);
    const existingBranchIndex = family.branches.findIndex((branch) => String(branch.workflow_id) === String(task.workflow_id));
    if (existingBranchIndex < 0) {
      family.branches.push(branchFromTask(task, now));
    } else {
      const previous = family.branches[existingBranchIndex];
      family.branches[existingBranchIndex] = {
        ...previous,
        ...branchFromTask(task, now),
        is_head: Boolean(previous.is_head),
      };
    }
    const shouldPromote = !family.head_workflow_id
      || String(((task || {}).lifecycle || {}).previous_workflow_id || '')
      || String(((task || {}).lifecycle || {}).focus_switched_from || '')
      || !['running', 'active'].includes(String(family.status || '').toLowerCase());
    if (shouldPromote) promoteHead(family, task.workflow_id);
    // promoteHead only changes which branch is focused. The task snapshot remains
    // authoritative for whether that branch is active, paused, or completed.
    const projectedBranch = family.branches.find((item) => String(item.workflow_id) === String(task.workflow_id));
    if (projectedBranch) projectedBranch.status = branchStatus(task);
    family.status = familyStatus(family);
    family.updated_at = now;
    const branch = family.branches.find((item) => String(item.workflow_id) === String(task.workflow_id));
    if (write) persistFamily(root, family);
    return { schemaVersion: SCHEMA_VERSION, family, branch, created: !relationship.family, relationship };
  } finally {
    if (release) release();
  }
}

function claimFamilyWriter(projectRoot, familyId, session, options = {}) {
  const root = path.resolve(projectRoot);
  const normalizedSession = normalizeSession(session);
  if (!normalizedSession.session_id) throw new Error('task family writer claim requires session_id');
  const write = options.write === true;
  const release = write && !options.projectLockHeld ? acquireProjectLock(root, 'task-family-session') : null;
  try {
    const current = readTaskFamily(root, familyId);
    if (!current) {
      const missing = new Error(`task family not found: ${familyId}`);
      missing.code = 'TASK_FAMILY_NOT_FOUND';
      throw missing;
    }
    const family = clone(current);
    const now = options.now ? new Date(options.now) : new Date();
    const timestamp = now.toISOString();
    family.sessions = Array.isArray(family.sessions) ? family.sessions : [];
    family.writer_lease = family.writer_lease && typeof family.writer_lease === 'object' ? family.writer_lease : null;

    const existing = family.writer_lease;
    const holderId = String((existing || {}).holder_session_id || '');
    const expired = !existing || isLeaseExpired(existing, now);
    const livenessInfo = existing ? resolveHostLiveness(root, holderId, options.hostLiveness, now) : { status: 'missing' };
    const liveness = livenessInfo.status;
    let status;
    let role = 'observer';

    if (!existing || ['missing', 'suspended'].includes(liveness)) {
      status = existing ? 'reclaimed_stale' : 'claimed';
      role = 'writer';
      if (existing && holderId && holderId !== normalizedSession.session_id) {
        upsertSession(family, { session_id: holderId, host: String(existing.host || ''), role: 'observer', reason: liveness === 'suspended' ? 'writer_suspended' : 'writer_stale' }, timestamp);
      }
      family.writer_lease = newWriterLease(normalizedSession, timestamp, existing, status);
    } else if (holderId === normalizedSession.session_id) {
      status = 'claimed';
      role = 'writer';
      family.writer_lease = refreshWriterLease(existing, normalizedSession, timestamp);
    } else if (options.takeover === true && options.confirmed === true) {
      status = 'taken_over';
      role = 'writer';
      upsertSession(family, { session_id: holderId, host: String(existing.host || ''), role: 'observer', reason: 'confirmed_takeover' }, timestamp);
      family.writer_lease = newWriterLease(normalizedSession, timestamp, existing, status);
    } else if (liveness === 'running') {
      status = 'takeover_required';
      role = 'observer';
      family.writer_lease = { ...existing, state: 'active', liveness, checked_at: timestamp };
    } else if (expired || liveness === 'expired_heartbeat' || liveness === 'unknown') {
      status = 'awaiting_claim';
      role = 'observer';
      family.writer_lease = markWriterLeaseAwaitingClaim(existing, normalizedSession, timestamp, liveness);
    } else {
      status = 'takeover_required';
      role = 'observer';
      family.writer_lease = { ...existing, state: 'active', liveness, checked_at: timestamp };
    }

    upsertSession(family, { ...normalizedSession, role, reason: status }, timestamp);
    family.updated_at = timestamp;
    family.session_summary = {
      writer_session_id: family.writer_lease && family.writer_lease.holder_session_id,
      observer_count: family.sessions.filter((item) => item.role === 'observer' && !item.detached_at).length,
      updated_at: timestamp,
    };
    if (write) {
      persistFamily(root, family);
      persistSessionRegistry(root, family, normalizedSession, role, status, timestamp);
      recordSessionHeartbeat(root, {
        taskFamilyId: family.task_family_id,
        sessionId: normalizedSession.session_id,
        host: normalizedSession.host,
        observedAt: timestamp,
        expiresAt: new Date(now.getTime() + 10 * 60 * 1000).toISOString(),
        capability: normalizedSession.capability,
      });
    }
    return {
      schemaVersion: SCHEMA_VERSION,
      status,
      role,
      family,
      writer_lease: family.writer_lease,
      liveness,
      liveness_detail: livenessInfo.heartbeat ? { heartbeat_observed_at: livenessInfo.heartbeat.observed_at, heartbeat_expires_at: livenessInfo.heartbeat.expires_at } : null,
      takeover_required: status === 'takeover_required' || status === 'awaiting_claim',
      awaiting_claim: status === 'awaiting_claim',
    };
  } finally {
    if (release) release();
  }
}

function normalizeSession(session) {
  const value = session && typeof session === 'object' ? session : {};
  const sessionId = String(value.session_id || '').trim();
  return {
    session_id: sessionId,
    host: String(value.host || sessionId.split(':')[0] || 'unknown'),
    source: String(value.source || ''),
    ancestor_pid: Number(value.ancestor_pid || 0),
    capability: value.capability && typeof value.capability === 'object' ? value.capability : {},
  };
}

function resolveHostLiveness(projectRoot, sessionId, injected, now) {
  if (typeof injected === 'function') {
    const result = String(injected(sessionId) || '').toLowerCase();
    return { status: ['running', 'suspended', 'missing', 'unknown'].includes(result) ? result : 'unknown' };
  }
  const heartbeat = heartbeatLiveness(projectRoot, sessionId, now);
  if (heartbeat.status === 'running') return heartbeat;
  const match = String(sessionId || '').match(/^(claude|codex|zcode):(\d+)$/);
  if (!match) return heartbeat.status === 'expired_heartbeat' ? heartbeat : { status: 'unknown' };
  const probe = spawnSync('/bin/ps', ['-p', match[2], '-o', 'stat='], { encoding: 'utf8' });
  if (probe.status !== 0 || !String(probe.stdout || '').trim()) return { status: 'missing' };
  return {
    status: String(probe.stdout).trim().startsWith('T') ? 'suspended' : 'running',
    heartbeat: heartbeat.heartbeat || null,
    fallback: heartbeat.status === 'expired_heartbeat' ? 'local_process_probe' : '',
  };
}

function isLeaseExpired(lease, now) {
  const expiresAt = new Date((lease || {}).expires_at || '').getTime();
  return !Number.isFinite(expiresAt) || expiresAt <= now.getTime();
}

function newWriterLease(session, timestamp, priorLease, reason) {
  const now = new Date(timestamp);
  const history = Array.isArray((priorLease || {}).takeover_history) ? clone(priorLease.takeover_history) : [];
  if (priorLease && priorLease.holder_session_id && priorLease.holder_session_id !== session.session_id) {
    history.push({ at: timestamp, from_session_id: priorLease.holder_session_id, to_session_id: session.session_id, reason });
  }
  return {
    holder_session_id: session.session_id,
    host: session.host,
    state: 'active',
    acquired_at: timestamp,
    heartbeat_at: timestamp,
    expires_at: new Date(now.getTime() + 15 * 60 * 1000).toISOString(),
    takeover_history: history.slice(-20),
  };
}

function refreshWriterLease(lease, session, timestamp) {
  const now = new Date(timestamp);
  return {
    ...lease,
    holder_session_id: session.session_id,
    host: session.host,
    state: 'active',
    heartbeat_at: timestamp,
    expires_at: new Date(now.getTime() + 15 * 60 * 1000).toISOString(),
  };
}

function markWriterLeaseAwaitingClaim(lease, claimantSession, timestamp, reason) {
  return {
    ...lease,
    state: 'awaiting_claim',
    awaiting_claim_since: lease.awaiting_claim_since || timestamp,
    awaiting_claim_reason: reason,
    last_claim_attempt: {
      at: timestamp,
      session_id: claimantSession.session_id,
      host: claimantSession.host,
    },
  };
}

function upsertSession(family, session, timestamp) {
  const index = family.sessions.findIndex((item) => String(item.session_id) === String(session.session_id));
  const current = index >= 0 ? family.sessions[index] : {};
  const next = {
    ...current,
    ...session,
    attached_at: current.attached_at || timestamp,
    last_seen_at: timestamp,
  };
  if (next.role === 'writer') delete next.detached_at;
  if (index >= 0) family.sessions[index] = next;
  else family.sessions.push(next);
}

function persistSessionRegistry(projectRoot, family, session, role, status, timestamp) {
  const file = sessionRegistryPath(projectRoot);
  const current = readJson(file);
  const sessions = current && Array.isArray(current.sessions) ? current.sessions : [];
  const index = sessions.findIndex((item) => String(item.session_id) === session.session_id && String(item.task_family_id) === family.task_family_id);
  const next = {
    task_family_id: family.task_family_id,
    session_id: session.session_id,
    host: session.host,
    role,
    status,
    last_seen_at: timestamp,
  };
  if (index >= 0) sessions[index] = { ...sessions[index], ...next };
  else sessions.push(next);
  atomicWriteJson(file, {
    schemaVersion: SCHEMA_VERSION,
    book_id: family.book_id,
    sessions: sessions.slice(-200),
    updated_at: timestamp,
  });
}

function branchFromTask(task, now) {
  const lifecycle = task.lifecycle || {};
  return {
    workflow_id: String(task.workflow_id),
    parent_workflow_id: String(task.parent_workflow_id || lifecycle.focus_switched_from || ''),
    status: branchStatus(task),
    created_at: task.created_at || lifecycle.started_at || now,
    updated_at: task.updated_at || lifecycle.updated_at || now,
    user_goal: String(task.user_goal || lifecycle.user_goal || ''),
    scope: String(task.scope || lifecycle.scope || ''),
    trusted_artifact: String((((task.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact || '')),
  };
}

function branchStatus(task) {
  const lifecycle = String((((task || {}).lifecycle || {}).status) || '').toLowerCase();
  const status = String((task || {}).status || '').toLowerCase();
  if (lifecycle === 'superseded') return 'superseded';
  if (TERMINAL.has(status) || TERMINAL.has(lifecycle)) return 'completed';
  if (lifecycle === 'paused' || /^paused/.test(status)) return 'paused';
  if (/invalidated|untrusted/.test(String((((task || {}).machine || {}).last_transition) || ''))) return 'invalidated';
  return 'active';
}

function promoteHead(family, workflowId) {
  const priorHead = String(family.head_workflow_id || '');
  family.head_workflow_id = String(workflowId);
  family.branches = family.branches.map((branch) => ({
    ...branch,
    is_head: String(branch.workflow_id) === String(workflowId),
    status: String(branch.workflow_id) === String(workflowId)
      ? (branch.status === 'paused' ? 'active' : branch.status)
      : (String(branch.workflow_id) === priorHead && branch.status === 'active' ? 'paused' : branch.status),
  }));
}

function familyStatus(family) {
  const head = (family.branches || []).find((branch) => String(branch.workflow_id) === String(family.head_workflow_id));
  if (!head) return 'active';
  if (head.status === 'completed') return 'completed';
  if (head.status === 'paused') return 'paused';
  if (head.status === 'invalidated') return 'blocked';
  return 'active';
}

function isUnfinishedFamily(family) {
  return !['completed', 'cancelled', 'archived', 'superseded'].includes(String((family || {}).status || '').toLowerCase());
}

function persistFamily(projectRoot, family) {
  const root = path.resolve(projectRoot);
  const dir = path.dirname(familyPath(root, family.task_family_id));
  fs.mkdirSync(dir, { recursive: true });
  atomicWriteJson(familyPath(root, family.task_family_id), family);
  atomicWriteJson(branchIndexPath(root, family.task_family_id), {
    schemaVersion: SCHEMA_VERSION,
    task_family_id: family.task_family_id,
    head_workflow_id: family.head_workflow_id,
    branch_ids: family.branches.map((branch) => branch.workflow_id),
    updated_at: family.updated_at,
  });
  const current = readJson(indexPath(root));
  const ids = new Set(Array.isArray(current && current.family_ids) ? current.family_ids : []);
  ids.add(family.task_family_id);
  const index = {
    schemaVersion: SCHEMA_VERSION,
    book_id: family.book_id,
    family_ids: [...ids].sort(),
    updated_at: family.updated_at,
  };
  atomicWriteJson(indexPath(root), index);
  appendJsonl(path.join(dir, 'journal.jsonl'), {
    at: family.updated_at,
    event: 'family_persisted',
    task_family_id: family.task_family_id,
    head_workflow_id: family.head_workflow_id,
  });
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

module.exports = {
  bookId,
  identityForTask,
  resolveTaskRelationship,
  ensureTaskFamily,
  readTaskFamily,
  claimFamilyWriter,
  listTaskFamilies,
  isUnfinishedFamily,
  workflowRoot,
  familyPath,
  sessionRegistryPath,
};
