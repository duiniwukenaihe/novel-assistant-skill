'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { acquireBookWriteLease, atomicWriteJson, atomicWriteText } = require('./workflow-state-store');
const { resolveTaskAuthority } = require('./workflow-task-authority');
const { validateMemoryEvidence } = require('./memory-evidence');

const FIXED_SOURCES = [
  { relative: '追踪/角色状态.md', type: 'character_state', priority: 95 },
  { relative: '追踪/角色身份对照表.md', type: 'character_state', priority: 92 },
  { relative: '追踪/伏笔.md', type: 'hook_ledger', priority: 95 },
  { relative: '追踪/上下文.md', type: 'story_context', priority: 90 },
];

const ACTIVE_CAST_SOURCE = { relative: '追踪/memory/active-cast.json', type: 'active_cast', priority: 88, format: 'json' };
const ACCEPTED_SUGGESTIONS_SOURCE = { relative: '追踪/memory/memory-suggestions.jsonl', type: 'accepted_memory_suggestions', priority: 86, format: 'accepted_suggestions' };
const LEGACY_MIGRATION_AUTHORITY = Symbol('legacy-memory-migration-authority');

function projectSources(projectRoot, requestedSources = [], options = {}) {
  if (options.write === false || options.leaseHeld === true) return projectSourcesUnlocked(projectRoot, requestedSources, options);
  let release;
  try {
    release = acquireBookWriteLease(path.resolve(projectRoot), options.owner || 'memory-projection');
  } catch (error) {
    if (error && error.code === 'BOOK_WRITE_LOCKED') error.status = 'blocked_book_write_locked';
    throw error;
  }
  try {
    return projectSourcesUnlocked(projectRoot, requestedSources, options);
  } finally {
    release();
  }
}

function migrateLegacySources(projectRoot, requestedSources = [], options = {}) {
  return projectSources(projectRoot, requestedSources, {
    ...options,
    sourceKind: 'legacy',
    [LEGACY_MIGRATION_AUTHORITY]: true,
  });
}

function projectAcceptedFacts(projectRoot, packet, options = {}) {
  const value = packet && typeof packet === 'object' && !Array.isArray(packet) ? packet : {};
  const accepted = [value.status, value.acceptance_status].some(status => String(status || '') === 'accepted');
  if (!accepted) throw projectionFailure('blocked_unaccepted_projection', 'canonical facts require an explicitly accepted result or commit packet');
  const commit = readAcceptedCommit(projectRoot, String(value.commit_id || value.accepted_commit_id || value.result_id || ''));
  return appendAcceptedFactsForCommit(projectRoot, commit, options);
}

function appendAcceptedFactsForCommit(projectRoot, commit, options = {}) {
  if (normalizeFacts(commit.facts).length === 0) {
    return { factIds: [], eventFile: path.join(path.resolve(projectRoot), '追踪', 'memory', 'facts.jsonl') };
  }
  const provenance = commit.provenance && typeof commit.provenance === 'object' ? commit.provenance : {};
  const resolved = resolveTaskAuthority(projectRoot, String(commit.workflow_id || provenance.workflow_id || ''));
  if (resolved.status !== 'ok') throw projectionFailure(resolved.status, resolved.message || 'durable task snapshot is unavailable');
  assertProjectionTaskProvenance(resolved.task, provenance);
  return appendAcceptedFactsFromAcceptedPacket(projectRoot, {
    commitId: commit.commit_id,
    workflowId: String(commit.workflow_id || ''),
    taskFamilyId: String(((commit.provenance || {}).task_family_id) || ''),
    acceptanceStatus: 'accepted',
    facts: normalizeFacts(commit.facts),
    leaseHeld: options.leaseHeld === true,
  });
}

function appendAcceptedFactsFromAcceptedPacket(projectRoot, payload = {}) {
  const root = path.resolve(projectRoot);
  const facts = Array.isArray(payload.facts) ? payload.facts : [];
  if (facts.length === 0) {
    return { factIds: [], eventFile: path.join(root, '追踪', 'memory', 'facts.jsonl') };
  }
  assertAcceptedPayload(payload);
  if (payload.leaseHeld === true) return appendAcceptedFactsUnlocked(root, payload, facts);
  const release = acquireBookWriteLease(root, 'memory-projection-facts');
  try {
    return appendAcceptedFactsUnlocked(root, payload, facts);
  } finally {
    release();
  }
}

function appendAcceptedFactsUnlocked(root, payload, facts) {
  const commitId = requiredString(payload.commitId, 'commitId');
  requiredString(payload.workflowId, 'workflowId');
  const eventFile = path.join(root, '追踪', 'memory', 'facts.jsonl');
  const existing = readJsonl(eventFile);
  const latest = latestByFactId(existing);
  const active = Array.from(latest.values()).filter(isActiveFact);
  const now = new Date().toISOString();
  const events = [];
  const factIds = [];

  for (const input of facts) {
    const fact = normalizeFact(root, input, payload, commitId, now);
    const sameKey = active.filter(item => factKey(item) === factKey(fact));
    const unchanged = sameKey.find(item => stableFactValue(item) === stableFactValue(fact));
    if (unchanged) {
      factIds.push(unchanged.fact_id);
      continue;
    }
    for (const predecessor of sameKey) {
      events.push({
        ...predecessor,
        status: 'superseded',
        valid_to: commitId,
        superseded_at: now,
        superseded_by: fact.fact_id,
      });
      const index = active.indexOf(predecessor);
      if (index >= 0) active.splice(index, 1);
    }
    events.push(fact);
    active.push(fact);
    factIds.push(fact.fact_id);
  }

  if (events.length > 0) {
    fs.mkdirSync(path.dirname(eventFile), { recursive: true });
    atomicWriteText(eventFile, renderJsonl([...existing, ...events]));
  }
  return { factIds, eventFile };
}

function normalizeFact(root, input, payload, commitId, now) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw projectionFailure('blocked_invalid_fact', 'fact must be an object');
  const subject = requiredString(input.subject, 'subject');
  const predicate = requiredString(input.predicate, 'predicate');
  const object = requiredString(input.object, 'object');
  const provenance = input.provenance && typeof input.provenance === 'object' && !Array.isArray(input.provenance) ? input.provenance : {};
  const evidence = normalizeEvidence(root, input.evidence, {
    commitId,
    workflowId: String(payload.workflowId || provenance.workflow_id || ''),
    taskFamilyId: String(payload.taskFamilyId || provenance.task_family_id || ''),
  });
  if (evidence.length === 0) throw projectionFailure('blocked_fact_evidence_required', 'accepted fact requires evidence');
  const scope = input.scope && typeof input.scope === 'object' && !Array.isArray(input.scope) ? { ...input.scope } : { book: 'current' };
  const identity = stableJson({ subject, predicate, object, scope });
  const factId = String(input.fact_id || `fact.${crypto.createHash('sha256').update(identity).digest('hex').slice(0, 16)}`);
  return {
    fact_id: factId,
    subject,
    predicate,
    object,
    aliases: normalizeStrings(input.aliases),
    dependencies: normalizeStrings(input.dependencies),
    scope,
    valid_from: String(input.valid_from || commitId),
    valid_to: null,
    evidence,
    provenance: {
      ...provenance,
      commit_id: commitId,
      workflow_id: String(payload.workflowId || provenance.workflow_id || ''),
      task_family_id: String(payload.taskFamilyId || provenance.task_family_id || ''),
      acceptance_status: 'accepted',
    },
    confidence: normalizeConfidence(input.confidence),
    status: 'active',
    recorded_at: now,
  };
}

function normalizeEvidence(root, value, metadata = {}) {
  const validation = validateMemoryEvidence(root, value, metadata);
  if (validation.status === 'valid') return validation.evidence;
  const values = Array.isArray(value) ? value : value ? [value] : [];
  const status = validation.status === 'symlink_escape' ? 'symlink'
    : validation.status === 'missing' && values.length === 0 ? 'required'
      : validation.status;
  const finding = validation.findings[0] || {};
  throw projectionFailure(`blocked_fact_evidence_${status}`, finding.message || `fact evidence is ${validation.status}`);
}

function normalizeStrings(value) {
  return Array.from(new Set((Array.isArray(value) ? value : value ? [value] : []).map(item => String(item || '').trim()).filter(Boolean)));
}

function normalizeConfidence(value) {
  const number = Number(value === undefined ? 1 : value);
  if (!Number.isFinite(number)) return 1;
  return Math.max(0, Math.min(1, number));
}

function factKey(fact) {
  return stableJson({ subject: fact.subject, predicate: fact.predicate, scope: fact.scope || {} });
}

function stableFactValue(fact) {
  return stableJson({ object: fact.object, aliases: normalizeStrings(fact.aliases).sort(), dependencies: normalizeStrings(fact.dependencies).sort() });
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

function latestByFactId(rows) {
  const latest = new Map();
  for (const row of rows) if (row && row.fact_id) latest.set(row.fact_id, row);
  return latest;
}

function isActiveFact(fact) {
  return String(fact.status || 'active') === 'active' && (fact.valid_to === undefined || fact.valid_to === null || fact.valid_to === '');
}

function normalizeRelativePath(value) {
  return String(value || '').replace(/\\/g, '/').replace(/^\.\//, '').trim();
}

function requiredString(value, field) {
  const normalized = String(value || '').trim();
  if (!normalized) throw projectionFailure('blocked_invalid_fact', `${field} is required`);
  return normalized;
}

function assertAcceptedPayload(payload) {
  const accepted = String(payload.acceptanceStatus || payload.acceptance_status || '') === 'accepted';
  if (!accepted) throw projectionFailure('blocked_unaccepted_projection', 'accepted facts require an accepted result or commit packet');
  requiredString(payload.commitId, 'commitId');
  requiredString(payload.workflowId, 'workflowId');
}

function hashEvidenceFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function projectSourcesUnlocked(projectRoot, requestedSources = [], options = {}) {
  const root = path.resolve(projectRoot);
  const authority = assertProjectionAuthority(root, options);
  options = { ...options, sourceKind: authority.sourceKind, provenance: authority.provenance };
  const write = options.write !== false;
  const memoryDir = path.join(root, '追踪', 'memory');
  const lorebookFile = path.join(memoryDir, 'lorebook.jsonl');
  const migrationFile = path.join(memoryDir, 'migration-state.json');
  const filters = normalizeSources(requestedSources);
  const discovered = discoverCandidates(root);
  const selected = filters.length ? discovered.filter(item => filters.includes(item.relative)) : discovered;

  if (filters.length) {
    const found = new Set(selected.map(item => item.relative));
    const missing = filters.filter(item => !found.has(item));
    if (missing.length) throw projectionFailure('blocked_memory_source_unavailable', `memory source is missing or unsupported: ${missing.join(', ')}`);
  }

  const candidates = selected.map(item => buildCandidate(root, item, options)).filter(Boolean);
  const existingRows = readJsonl(lorebookFile);
  const latest = latestById(existingRows);
  const events = [];
  let created = 0;
  let superseded = 0;
  const now = new Date().toISOString();
  const lifecycle = resolveLifecycleProjection(root, options);

  for (const candidate of candidates) {
    if (options.commitId || options.projectionId) candidate.scope = lifecycleScope(candidate.memoryLayer, lifecycle);
    const old = latest.get(candidate.id);
    const acceptedLegacyPredecessors = options.commitId
      ? Array.from(latest.values()).filter(entry => isAcceptedLegacyPredecessor(entry, candidate))
      : [];
    const unchangedOld = old && sourceHash(old) === sourceHash(candidate) && old.status === 'active';
    if (unchangedOld && acceptedLegacyPredecessors.length === 0) continue;
    if (detectPollution(candidate.content)) throw projectionFailure('blocked_output_pollution', `memory source produced polluted content: ${candidate.sourceRefs[0].path}`);
    const predecessorVersions = acceptedLegacyPredecessors.map(entry => Math.max(1, Number(entry.version) || 1));
    const nextVersion = Math.max(old ? Math.max(1, Number(old.version) || 1) : 0, ...predecessorVersions) + 1;
    for (const predecessor of acceptedLegacyPredecessors) {
      events.push({
        ...predecessor,
        status: 'superseded',
        supersededAt: now,
        supersededByVersion: nextVersion,
        supersededBy: candidate.id,
        valid_to: String(options.commitId),
      });
      superseded += 1;
    }
    if (old && !unchangedOld) {
      events.push({
        ...old,
        status: 'superseded',
        supersededAt: now,
        supersededByVersion: nextVersion,
        ...(options.commitId ? { valid_to: String(options.commitId) } : {}),
      });
      superseded += 1;
    }
    candidate.version = nextVersion;
    if (unchangedOld) continue;
    candidate.updatedAt = now;
    if (options.commitId || options.projectionId) {
      const authorityId = String(options.commitId || options.projectionId);
      if (options.commitId) {
        candidate.projectedFromCommit = authorityId;
        candidate.chapter_commit_id = authorityId;
        candidate.accepted_artifact_id = authorityId;
        candidate.acceptedCommitId = authorityId;
      }
      candidate.valid_from = authorityId;
      candidate.valid_to = null;
      Object.assign(candidate, lifecycle);
    }
    events.push(candidate);
    created += 1;
  }

  if (write) {
    fs.mkdirSync(memoryDir, { recursive: true });
    if (events.length) atomicWriteText(lorebookFile, renderJsonl([...existingRows, ...events]));
    const previousState = readJson(migrationFile) || { schemaVersion: '1.0.0', sources: [] };
    const sourceState = new Map((previousState.sources || []).map(item => [item.path, item]));
    for (const candidate of candidates) {
      sourceState.set(candidate.sourceRefs[0].path, {
        id: candidate.id,
        path: candidate.sourceRefs[0].path,
        hash: candidate.sourceRefs[0].hash,
        version: candidate.version,
      });
    }
    atomicWriteJson(migrationFile, {
      schemaVersion: '1.0.0',
      status: 'current',
      migrated_at: now,
      last_commit_id: options.commitId || previousState.last_commit_id || '',
      sources: Array.from(sourceState.values()).sort((a, b) => a.path.localeCompare(b.path)),
    });
  }

  return {
    status: created ? 'migrated' : 'current',
    project_root: root,
    discovered: candidates.length,
    created,
    superseded,
    refreshed_entry_ids: events.filter(item => item.status === 'active').map(item => item.id),
    sources: candidates.map(entry => entry.sourceRefs[0].path),
    lorebook_file: lorebookFile,
    migration_state: migrationFile,
    write,
  };
}

function discoverCandidates(projectRoot) {
  const files = [...FIXED_SOURCES];
  const handoffDir = path.join(projectRoot, '追踪', '交接包');
  for (const relative of findRelativeFiles(projectRoot, handoffDir, '.md').slice(0, 12)) files.push({ relative, type: 'handoff', priority: 85 });
  const volumeHandoffDir = path.join(projectRoot, '追踪', '卷交接');
  for (const relative of findRelativeFiles(projectRoot, volumeHandoffDir, '.md').slice(0, 12)) files.push({ relative, type: 'volume_handoff', priority: 88 });
  files.push(ACTIVE_CAST_SOURCE, ACCEPTED_SUGGESTIONS_SOURCE);
  const styleDir = path.join(projectRoot, '设定', '作者风格');
  if (fs.existsSync(styleDir)) {
    for (const name of fs.readdirSync(styleDir).filter(name => name.endsWith('.md')).sort()) {
      files.push({ relative: path.posix.join('设定', '作者风格', name), type: 'style', priority: 90 });
    }
  }
  return files.map(item => ({ ...item, relative: normalizeSource(item.relative) })).filter(item => {
    const file = path.join(projectRoot, item.relative);
    return fs.existsSync(file) && fs.statSync(file).isFile() && fs.statSync(file).size > 0;
  });
}

function buildCandidate(projectRoot, item, options = {}) {
  const file = path.join(projectRoot, item.relative);
  const raw = fs.readFileSync(file, 'utf8');
  const hash = `sha256:${crypto.createHash('sha256').update(raw).digest('hex')}`;
  const content = compactSource(raw, item.format);
  if (!content) return null;
  const sourceKind = String(options.sourceKind || '');
  const memoryId = `${sourceKind}.${item.type}.${crypto.createHash('sha256').update(item.relative).digest('hex').slice(0, 12)}`;
  const candidate = {
    id: memoryId,
    memory_id: memoryId,
    source_kind: sourceKind,
    type: item.type,
    title: path.basename(item.relative).replace(/\.(?:md|json|jsonl)$/i, ''),
    aliases: [],
    triggers: extractTriggers(content),
    scope: { book: 'current' },
    priority: item.priority,
    tokenBudget: Math.min(480, Math.max(120, Math.ceil(content.length / 2))),
    content,
    constraints: [],
    sourceRefs: [{ path: item.relative, hash, note: 'projected from authoritative project asset' }],
    status: 'active',
    version: 1,
    memoryLayer: projectedMemoryLayer(item, options),
    ...(sourceKind === 'legacy' ? { migrated: true } : {}),
  };
  if (options.provenance && options.provenance.task_family_id) {
    candidate.provenance = { ...options.provenance, acceptance_status: 'accepted' };
  }
  return candidate;
}

function assertProjectionAuthority(projectRoot, options) {
  const explicitKind = String(options.sourceKind || '');
  const sourceKind = explicitKind || (options.commitId ? 'canonical' : '');
  if (sourceKind === 'legacy') {
    if (options[LEGACY_MIGRATION_AUTHORITY] !== true || options.commitId || options.projectionId || options.provenance) {
      throw projectionFailure('blocked_untrusted_legacy_migration', 'legacy memory projection is restricted to the explicit memory migration command');
    }
    return { sourceKind, provenance: null };
  }
  if (!['canonical', 'user_confirmed'].includes(sourceKind)) {
    throw projectionFailure('blocked_memory_projection_authority_missing', 'memory projection requires canonical/user-confirmed authority or explicit legacy migration');
  }
  const provenance = options.provenance && typeof options.provenance === 'object' ? options.provenance : {};
  const workflowId = String(provenance.workflow_id || '');
  const resolved = resolveTaskAuthority(projectRoot, workflowId);
  if (resolved.status !== 'ok') throw projectionFailure(resolved.status, resolved.message || 'durable task snapshot is unavailable');
  assertProjectionTaskProvenance(resolved.task, provenance);
  if (String(provenance.acceptance_status || '') !== 'accepted') {
    throw projectionFailure('blocked_unaccepted_projection', 'accepted memory projection requires accepted provenance');
  }
  if (sourceKind === 'canonical') {
    if (!options.commitId) throw projectionFailure('blocked_commit_missing', 'canonical memory projection requires an accepted commit');
    const commit = readAcceptedCommit(projectRoot, options.commitId);
    assertProjectionTaskProvenance(resolved.task, commit.provenance || {});
    if (String(commit.workflow_id || '') !== workflowId) throw projectionFailure('blocked_task_provenance_mismatch', 'commit workflow_id does not match durable task');
  } else if (!String(options.projectionId || '')) {
    throw projectionFailure('blocked_memory_projection_authority_missing', 'user-confirmed memory projection requires a persisted confirmation id');
  }
  return { sourceKind, provenance };
}

function assertProjectionTaskProvenance(task, provenance) {
  const expected = {
    workflow_id: String((task || {}).workflow_id || ''),
    task_family_id: String((task || {}).task_family_id || ''),
    branch_id: String((task || {}).branch_id || (task || {}).workflow_id || ''),
    stage_attempt_id: String((((task || {}).stage_execution || {}).stage_attempt_id) || ''),
  };
  const actual = {
    workflow_id: String((provenance || {}).workflow_id || ''),
    task_family_id: String((provenance || {}).task_family_id || ''),
    branch_id: String((provenance || {}).branch_id || ''),
    stage_attempt_id: String((provenance || {}).stage_attempt_id || ''),
  };
  const mismatches = Object.keys(expected).filter(field => !expected[field] || expected[field] !== actual[field]);
  if (mismatches.length) throw projectionFailure('blocked_task_provenance_mismatch', `memory provenance does not match durable task stage execution: ${mismatches.join(', ')}`);
}

function resolveLifecycleProjection(projectRoot, options) {
  const provenance = options.provenance && typeof options.provenance === 'object' ? options.provenance : {};
  const resolved = provenance.workflow_id ? resolveTaskAuthority(projectRoot, provenance.workflow_id) : null;
  if (provenance.workflow_id && (!resolved || resolved.status !== 'ok')) {
    throw projectionFailure((resolved && resolved.status) || 'blocked_task_authority_missing', (resolved && resolved.message) || 'durable task snapshot is unavailable');
  }
  const stored = resolved && resolved.status === 'ok' && resolved.task.lifecycle_context && typeof resolved.task.lifecycle_context === 'object'
    ? resolved.task.lifecycle_context : {};
  return {
    lifecycleNode: String(stored.node || stored.lifecycle_node || 'chapter_commit'),
    bookId: String(stored.book_id || discoverBookId(projectRoot)),
    volumeId: String(stored.volume_id || ''),
    stageId: String(stored.stage_id || ''),
    chapterId: String(stored.chapter_id || ''),
    taskFamilyId: String(stored.task_family_id || provenance.task_family_id || ''),
    workflowId: String(stored.workflow_id || provenance.workflow_id || ''),
  };
}

function discoverBookId(projectRoot) {
  const state = readJson(path.join(projectRoot, '.book-state.json')) || {};
  return String(state.book_id || state.bookId || state.id || 'current');
}

function readAcceptedCommit(projectRoot, commitId) {
  const normalized = String(commitId || '').replace(/\.json$/, '');
  if (!/^[A-Za-z0-9._-]+$/.test(normalized)) throw projectionFailure('blocked_invalid_commit', 'accepted fact projection requires a valid commit id');
  const file = path.join(projectRoot, '追踪', 'story-system', 'commits', `${normalized}.json`);
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) throw projectionFailure('blocked_commit_missing', `accepted commit not found: ${normalized}`);
  let commit;
  try {
    commit = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw projectionFailure('blocked_invalid_commit', `accepted commit is not valid JSON: ${normalized}`);
  }
  return validateAcceptedCommitObject({ commit_id: normalized }, commit);
}

function validateAcceptedCommitObject(packet, commit) {
  const commitId = String(commit.commit_id || '');
  const expected = String(packet.commit_id || packet.accepted_commit_id || packet.result_id || commitId);
  if (!commitId || commitId !== expected) throw projectionFailure('blocked_commit_mismatch', 'accepted fact packet does not match commit id');
  if (String(commit.status || '') !== 'accepted' || String(commit.acceptance_status || 'accepted') !== 'accepted') {
    throw projectionFailure('blocked_unaccepted_projection', 'accepted facts require an accepted commit record');
  }
  return { ...commit, facts: normalizeFacts(commit.facts) };
}

function normalizeFacts(value) {
  return Array.isArray(value) ? value.filter(item => item && typeof item === 'object' && !Array.isArray(item)) : [];
}

function projectedMemoryLayer(item, options) {
  if (item.type === 'volume_handoff') return 'volume';
  if (item.type === 'accepted_memory_suggestions') return 'task';
  if (item.type === 'style') return 'book';
  return options.commitId ? 'chapter' : 'book';
}

function lifecycleScope(layer, lifecycle) {
  const scope = { book: lifecycle.bookId || 'current' };
  if (['volume', 'stage', 'chapter', 'task'].includes(layer) && lifecycle.volumeId) scope.volume = lifecycle.volumeId;
  if (['stage', 'chapter', 'task'].includes(layer) && lifecycle.stageId) scope.stage_id = lifecycle.stageId;
  if (['chapter', 'task'].includes(layer) && lifecycle.chapterId) scope.chapter_id = lifecycle.chapterId;
  if (layer === 'task') {
    if (lifecycle.taskFamilyId) scope.task_family_id = lifecycle.taskFamilyId;
    else if (lifecycle.workflowId) scope.workflow_id = lifecycle.workflowId;
  }
  return scope;
}

function findRelativeFiles(projectRoot, rootDir, extension) {
  if (!fs.existsSync(rootDir)) return [];
  const found = [];
  const visit = dir => {
    for (const name of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, name);
      const stat = fs.statSync(file);
      if (stat.isDirectory()) visit(file);
      else if (stat.isFile() && stat.size > 0 && name.endsWith(extension)) found.push({ file, stat });
    }
  };
  visit(rootDir);
  return found.sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs || a.file.localeCompare(b.file)).map(item => normalizeSource(path.relative(projectRoot, item.file)));
}

function compactSource(raw, format) {
  if (format === 'json') {
    try { return compactMarkdown(JSON.stringify(JSON.parse(raw), null, 2)); } catch (_) { return ''; }
  }
  if (format === 'accepted_suggestions') {
    const latest = new Map();
    for (const line of String(raw || '').split(/\r?\n/).filter(Boolean)) {
      try {
        const value = JSON.parse(line);
        const key = String(value.suggestionId || value.entryId || '');
        if (key) latest.set(key, value);
      } catch (_) {
        return '';
      }
    }
    const accepted = Array.from(latest.values()).filter(value => value.status === 'applied');
    return compactMarkdown(accepted.map(value => `${value.entryId || ''}: ${value.proposedContent || value.content || ''}`).join('\n'));
  }
  return compactMarkdown(raw);
}

function canAutoRefreshEntry(entry) {
  if (!entry || entry.migrated !== true || !/^legacy\./.test(String(entry.id || entry.memory_id || ''))) return false;
  const sourceKind = String(entry.source_kind || entry.sourceKind || '');
  if (sourceKind && sourceKind !== 'legacy') return false;
  return ![
    entry.acceptedCommitId,
    entry.accepted_commit_id,
    entry.accepted_artifact_id,
    entry.chapter_commit_id,
    entry.projectedFromCommit,
  ].some(Boolean);
}

function compactMarkdown(text, limit) {
  const lines = String(text || '').split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  const selected = [];
  let used = 0;
  for (const line of lines) {
    if (!/^(#|[-*+]\s|\d+[.、)]\s?|\|)/.test(line) && selected.length > 8) continue;
    const next = line.length > 240 ? `${line.slice(0, 239)}…` : line;
    if (Number.isFinite(limit) && used + next.length + 1 > limit) break;
    selected.push(next);
    used += next.length + 1;
  }
  return selected.join('\n');
}

function extractTriggers(text) {
  const values = String(text || '').match(/[\u4e00-\u9fff]{2,8}/g) || [];
  return Array.from(new Set(values)).slice(0, 12);
}

function detectPollution(text) {
  if (/([\u4e00-\u9fff]{2,8})\1{8,}/.test(String(text || ''))) return true;
  const counts = new Map();
  for (const line of String(text || '').split(/\r?\n/).map(item => item.trim()).filter(Boolean)) counts.set(line, (counts.get(line) || 0) + 1);
  return Array.from(counts.values()).some(count => count >= 4);
}

function normalizeSources(values) {
  const list = Array.isArray(values) ? values : [values];
  return Array.from(new Set(list.flatMap(value => String(value || '').split(',')).map(normalizeSource).filter(Boolean)));
}

function normalizeSource(value) {
  return String(value || '').replace(/\\/g, '/').replace(/^\.\//, '');
}

function latestById(rows) {
  const latest = new Map();
  for (const row of rows) if (row && row.id) latest.set(row.id, row);
  return latest;
}

function sourceHash(entry) {
  return String((((entry || {}).sourceRefs || [])[0] || {}).hash || '');
}

function stableSourceIdentity(entry) {
  const type = String((entry || {}).type || '');
  const sourcePath = normalizeSource(String(((((entry || {}).sourceRefs || [])[0]) || {}).path || ''));
  return type && sourcePath ? `${type}:${sourcePath}` : '';
}

function isAcceptedLegacyPredecessor(entry, candidate) {
  if (!entry || entry.id === candidate.id || String(entry.status || 'active') !== 'active') return false;
  const sourceKind = String(entry.source_kind || entry.sourceKind || '');
  const legacyIdentity = sourceKind === 'legacy' || /^legacy\./.test(String(entry.id || entry.memory_id || '')) || entry.migrated === true;
  if (!legacyIdentity) return false;
  if (entry.valid_to !== undefined && entry.valid_to !== null && entry.valid_to !== '') return false;
  const provenance = entry.provenance && typeof entry.provenance === 'object' ? entry.provenance : {};
  const accepted = String(entry.acceptanceStatus || entry.acceptance_status || provenance.acceptance_status || '') === 'accepted'
    || Boolean(entry.acceptedCommitId || entry.accepted_commit_id || entry.accepted_artifact_id || entry.chapter_commit_id || entry.projectedFromCommit);
  return accepted && stableSourceIdentity(entry) !== '' && stableSourceIdentity(entry) === stableSourceIdentity(candidate);
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(line => line.trim()).filter(Boolean).map(JSON.parse);
}

function readJson(file) {
  if (!fs.existsSync(file)) return null;
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

function renderJsonl(rows) {
  return rows.length ? `${rows.map(row => JSON.stringify(row)).join('\n')}\n` : '';
}

function projectionFailure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

module.exports = {
  canAutoRefreshEntry,
  discoverCandidates,
  migrateLegacySources,
  projectAcceptedFacts,
  projectSources,
  resolveLifecycleProjection,
};
