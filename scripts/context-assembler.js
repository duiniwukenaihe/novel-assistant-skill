#!/usr/bin/env node
'use strict';

const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { canAutoRefreshEntry } = require('./lib/memory-projection');
const { allocateContextBudget } = require('./lib/context-budget');
const { rankChineseMemory } = require('./lib/chinese-memory-retrieval');
const { detectMemoryConflicts } = require('./lib/memory-conflict');
const { readTaskFamily } = require('./lib/task-family-store');
const { readFocusedTask, resolveTaskContext } = require('./lib/workflow-task-authority');
const { validateMemoryEvidence } = require('./lib/memory-evidence');
const { loadOrBuildActiveMemoryIndex } = require('./lib/memory-active-index');
const MEMORY_LAYER_ORDER = ['book', 'volume', 'stage', 'chapter', 'task'];

const args = parseArgs(process.argv);
if (!args.projectRoot) die('--project-root is required');
if (!args.task && args.lifecycleNode) args.task = args.lifecycleNode;
if (!args.target && args.lifecycleNode) args.target = lifecycleTarget(args);
if (!args.task) die('--task is required');
if (!args.target) die('--target is required');

const projectRoot = path.resolve(args.projectRoot);
const budget = Number.isFinite(args.budget) ? args.budget : 3000;
const context = buildTaskContext(projectRoot, args.task, args.target, budget, args);
if (context.workflowTaskContext.authority_status) {
  printJson(structuredResult({
    status: context.workflowTaskContext.authority_status,
    context,
    error: context.workflowTaskContext.authority_message || 'durable task snapshot is unavailable',
  }));
  process.exit(0);
}
let memoryLoad = loadMemoryEntries(projectRoot);
let loadedEntries = memoryLoad.entries;
const revisionDebtFilter = quarantineControlledRevisionDebts(memoryLoad.debts, context.workflowTaskContext);
const controlledDebtIds = new Set(revisionDebtFilter.omitted.map(item => item.id));
context.initialOmitted.push(...memoryLoad.omitted.map(item => controlledDebtIds.has(item.id)
  ? { ...item, reason: 'pending_controlled_reacceptance' }
  : item));
const memoryDebts = classifyMemoryDebts(revisionDebtFilter.debts, context);
const blockingMemoryDebts = memoryDebts.filter(debt => debt.severity === 'blocking');
if (blockingMemoryDebts.length > 0) {
  printJson(structuredResult({
    status: 'blocked_memory_evidence_stale',
    context,
    memory_debts: memoryDebts,
    findings: blockingMemoryDebts.map(debt => ({ fact_id: debt.fact_id, code: `memory_evidence_${debt.status}`, impact: debt.impact })),
  }));
  process.exit(0);
}
const provenanceFilter = filterMemoryProvenance(loadedEntries, projectRoot);
loadedEntries = provenanceFilter.eligible;
context.initialOmitted.push(...provenanceFilter.omitted);
const lifecycleFilter = filterMemoryLifecycle(loadedEntries, context.lifecycleContext);
loadedEntries = lifecycleFilter.eligible;
context.initialOmitted.push(...lifecycleFilter.omitted);
let staleEntries = loadedEntries.filter(entry => memorySourceIsStale(entry, projectRoot));
let entries = loadedEntries.filter(entry => !memorySourceIsStale(entry, projectRoot));
let staleRelevant = relevantStaleEntries(staleEntries, context);
let memoryRefresh = { status: 'not_needed', refreshedEntryIds: [], sources: [] };
const sourceRefreshCandidates = staleRelevant.filter(item => canAutoRefreshEntry(item.entry));
if (staleRelevant.length > 0 && sourceRefreshCandidates.length === staleRelevant.length) {
  const sources = Array.from(new Set(sourceRefreshCandidates.flatMap(item => (item.entry.sourceRefs || []).map(ref => String(ref.path || '')).filter(Boolean))));
  memoryRefresh = {
    status: 'blocked_untrusted_legacy_migration',
    refreshedEntryIds: [],
    sources,
    message: 'stale legacy memory must be refreshed with scripts/memory-migrate.js',
  };
}
if (staleRelevant.length > 0) {
  printJson(structuredResult({
    status: 'blocked_memory_stale',
    context,
    stale: staleEntries.map(entry => staleRecord(entry, context)),
    omitted: context.initialOmitted,
    staleEntryIds: staleRelevant.map(item => item.entry.id),
    findings: staleRelevant.map(item => ({ id: item.entry.id, code: 'source_hash_changed' })),
    memoryRefresh,
    memory_debts: memoryDebts,
  }));
  process.exit(0);
}
const factRankings = rankChineseMemory(
  entries.filter(entry => entry.type === 'accepted_fact'),
  memoryRetrievalQuery(context),
  { index: memoryLoad.factIndex, aliases: context.activeCast.presentCharacters || [], limit: entries.length },
);
const factScores = new Map(factRankings.map(item => [item.entry.id || item.entry.fact_id, item]));
const scored = entries
  .map(entry => ({ entry, score: entry.type === 'accepted_fact' ? acceptedFactScore(entry, factScores) : scoreEntry(entry, context) }))
  .sort((a, b) => b.score.score - a.score.score || String(a.entry.id).localeCompare(String(b.entry.id)));
const relevant = scored.filter(item => item.score.score > 0 && item.score.hasQualifyingSupport);
const relevantIds = new Set(relevant.map(item => item.entry.id));
const quarantined = scored
  .map(item => ({ entry: item.entry, score: item.score, findings: detectPollution(item.entry) }))
  .filter(item => item.findings.length > 0)
  .map(item => ({
    id: item.entry.id,
    title: item.entry.title,
    relevant: relevantIds.has(item.entry.id),
    findings: item.findings,
  }));
const quarantinedIds = new Set(quarantined.map(item => item.id));
const omitted = [
  ...context.initialOmitted,
  ...staleEntries.map(entry => ({ id: entry.id, title: entry.title, reason: 'stale_irrelevant' })),
  ...quarantined.map(item => ({ id: item.id, title: item.title, reason: 'polluted' })),
];
for (const item of scored) {
  if (!relevantIds.has(item.entry.id) && !quarantinedIds.has(item.entry.id)) {
    omitted.push({ id: item.entry.id, title: item.entry.title, reason: 'not_relevant', score: 0 });
  }
}

const pollutedRelevant = quarantined.filter(item => item.relevant);
if (pollutedRelevant.length > 0) {
  printJson(structuredResult({
    status: 'blocked_output_pollution',
    context,
    omitted,
    stale: staleEntries.map(entry => staleRecord(entry, context)),
    quarantined,
    blockedEntryIds: pollutedRelevant.map(item => item.id),
    findings: pollutedRelevant.map(item => ({ id: item.id, findings: item.findings })),
    memoryRefresh,
    memory_debts: memoryDebts,
  }));
  process.exit(0);
}

const candidates = relevant
  .filter(item => !quarantinedIds.has(item.entry.id))
  .map(item => ({ ...item.entry, _score: item.score.score, _reasons: item.score.reasons }));
const conflicts = detectConflicts(candidates, context);
if (conflicts.length > 0) {
  printJson(structuredResult({
    status: 'blocked_memory_conflict',
    context,
    selected: candidates.map(selectionRecord),
    omitted,
    stale: staleEntries.map(entry => staleRecord(entry, context)),
    quarantined,
    conflicts,
    memoryRefresh,
    memory_debts: memoryDebts,
  }));
  process.exit(0);
}

const allocation = allocateContextBudget({
  budget,
  workflowLayer: workflowMemoryLayer(context.lifecycleContext.node),
  sources: buildBudgetSources(context, candidates),
});
if (allocation.blocked_required.length > 0) {
  printJson(structuredResult({
    status: 'blocked_required_context_budget',
    context,
    required_context: allocation.blocked_required,
    omitted: [...context.initialOmitted, ...allocation.omitted],
    memory_debts: memoryDebts,
  }));
  process.exit(0);
}
const selectedSourceIds = new Set(allocation.selected.map(item => item.id));
const selected = candidates.filter(entry => selectedSourceIds.has(`lore:${entry.id}`));
for (const entry of candidates) {
  if (!selectedSourceIds.has(`lore:${entry.id}`)) {
    omitted.push({ id: entry.id, title: entry.title, reason: 'budget_exceeded', score: entry._score });
  }
}
omitted.push(...allocation.omitted);
const memorySources = buildLayeredMemorySources(selected, context.lifecycleContext);
const packet = buildPacket(context, selected, omitted, allocation, {
  stale: staleEntries.map(entry => staleRecord(entry, context)),
  quarantined,
  conflicts,
  memorySources,
  memoryDebts,
});
const packetFindings = detectPacketPollution(packet);
if (packetFindings.length > 0) {
  printJson(structuredResult({
    status: 'blocked_output_pollution',
    context,
    selected: selected.map(selectionRecord),
    omitted,
    stale: packet.stale,
    quarantined,
    conflicts,
    findings: packetFindings,
    memoryRefresh,
    memory_debts: memoryDebts,
  }));
  process.exit(0);
}
const paths = writePacket(projectRoot, packet, context, args);

const result = structuredResult({
  status: 'ok',
  context,
  estimated_total_tokens: packet.estimated_total_tokens,
  packetJson: paths.packetJson,
  packetMd: paths.packetMd,
  packetDigest: paths.packetDigest || '',
  packetMode: paths.packetMode || 'interactive_compat',
  taskContext: packet.task_context
    ? {
        workflow_id: packet.task_context.workflow_id,
        loadedPaths: packet.task_context.loadedPaths || [],
        warnings: packet.task_context.warnings || [],
      }
    : { workflow_id: '', loadedPaths: [], warnings: [] },
  selectedEntries: selected.map(selectionRecord),
  omittedEntries: omitted,
  selected: packet.selected,
  omitted,
  stale: packet.stale,
  quarantined,
  conflicts,
  memoryRefresh,
  memory_debts: memoryDebts,
  lifecycle_context: context.lifecycleContext,
  memory_sources: memorySources,
  memory_index: memoryLoad.factIndex ? { source: memoryLoad.factIndexSource, source_digest: memoryLoad.factIndex.sourceDigest } : null,
});

if (args.json) printJson(result);
else {
  console.log(`status: ${result.status}`);
  console.log(`packetJson: ${result.packetJson}`);
  console.log(`packetMd: ${result.packetMd}`);
}

function selectionRecord(entry) {
  return {
    id: entry.id,
    type: entry.type,
    title: entry.title,
    score: entry._score,
    evidence: entry.evidence || [],
  };
}

function loadMemoryEntries(root) {
  const facts = loadAcceptedFactEntries(root);
  return {
    entries: [...loadLoreEntries(root), ...facts.entries],
    omitted: facts.omitted,
    debts: facts.debts,
    factIndex: facts.index,
    factIndexSource: facts.indexSource,
  };
}

function staleRecord(entry, context) {
  const score = scoreEntry(entry, context);
  return {
    id: entry.id,
    title: entry.title,
    relevant: score.score > 0 && score.hasQualifyingSupport,
    reason: 'source_hash_changed',
  };
}

function structuredResult({ status, context, selected = [], omitted = [], stale = [], quarantined = [], conflicts = [], ...extra }) {
  return {
    status,
    projectRoot,
    task: args.task,
    target: args.target,
    workflowId: context.workflowId,
    estimated_total_tokens: 0,
    selected,
    omitted,
    stale,
    quarantined,
    conflicts,
    ...extra,
  };
}

function parseArgs(argv) {
  const out = {
    projectRoot: '', task: '', target: '', budget: 3000, json: false,
    workflowId: '', taskDir: '', runId: '', lifecycleNode: '', bookId: '', volumeId: '', stageId: '', chapterId: '', taskFamilyId: '',
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') out.projectRoot = argv[++i] || '';
    else if (arg === '--task') out.task = argv[++i] || '';
    else if (arg === '--target') out.target = argv[++i] || '';
    else if (arg === '--workflow-id') out.workflowId = argv[++i] || '';
    else if (arg === '--task-dir') out.taskDir = argv[++i] || '';
    else if (arg === '--run-id') out.runId = argv[++i] || '';
    else if (arg === '--lifecycle-node') out.lifecycleNode = argv[++i] || '';
    else if (arg === '--book-id') out.bookId = argv[++i] || '';
    else if (arg === '--volume') out.volumeId = argv[++i] || '';
    else if (arg === '--stage') out.stageId = argv[++i] || '';
    else if (arg === '--chapter') out.chapterId = argv[++i] || '';
    else if (arg === '--task-family-id') out.taskFamilyId = argv[++i] || '';
    else if (arg === '--budget') out.budget = Number(argv[++i] || 3000);
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') {
      console.log('Usage: node context-assembler.js --project-root <dir> (--task <task> --target <target> | --lifecycle-node <node> [--volume <id>] [--stage <id>] [--chapter <id>]) [--workflow-id <id> --task-dir <durable-task-dir> --run-id <attempt-id>] [--book-id <id>] [--task-family-id <id>] [--budget <n>] [--json]');
      process.exit(0);
    } else {
      die(`unknown argument: ${arg}`);
    }
  }
  return out;
}

function lifecycleTarget(options) {
  return [options.volumeId, options.stageId, options.chapterId].filter(Boolean).join('/') || options.bookId || 'current-book';
}

function buildTaskContext(root, task, target, tokenBudget, options = {}) {
  const contractArtifacts = readBestArtifact(root, [
    path.join('追踪', '章节契约', `${target}.md`),
    path.join('追踪', '章节契约', normalizeTargetPath(target) + '.md'),
  ], true);
  const targetParts = parseTarget(target);
  const handoffArtifacts = readRelevantHandoffArtifacts(root, targetParts);
  const activeCastPath = path.join(root, '追踪', 'memory', 'active-cast.json');
  const activeCastResult = loadActiveCast(root, activeCastPath);
  const workflowTaskContext = loadWorkflowTaskContext(root, options);
  const lifecycleContext = resolveLifecycleContext(options, workflowTaskContext, targetParts);
  const workflowTaskMatchesTarget = taskContextMatchesTarget(workflowTaskContext, target);
  const initialOmitted = [];
  if (activeCastResult.malformed) initialOmitted.push({ id: 'context.active_cast', title: 'active cast', reason: 'malformed_active_cast' });
  if (workflowTaskContext.workflow_id && !workflowTaskMatchesTarget) {
    initialOmitted.push({ id: 'context.workflow_task', title: 'workflow task context', reason: 'task_target_mismatch' });
  }
  const packetWorkflowTaskContext = workflowTaskMatchesTarget ? workflowTaskContext : emptyWorkflowTaskContext(workflowTaskContext.workflow_id);
  const workflowTaskArtifacts = workflowTaskContext.loadedPaths.map(relPath => {
    const item = workflowTaskContext.artifacts.find(artifact => artifact.path === relPath);
    return {
      path: relPath,
      text: item ? item.text : '',
      requiredComplete: Boolean(item && item.requiredComplete),
      targetScoped: true,
    };
  });

  return {
    projectRoot: root,
    task,
    target,
    tokenBudget,
    targetText: normalize(target),
    targetParts,
    activeCast: activeCastResult.value,
    contractText: contractArtifacts.map(item => item.text).join('\n'),
    handoffText: compactText(handoffArtifacts.map(item => item.text).join('\n'), 16000),
    authorVoiceText: readDirectoryText(path.join(root, '设定', '作者风格'), 8000),
    workflowTaskContext: packetWorkflowTaskContext,
    workflowId: lifecycleContext.workflow_id || workflowTaskContext.workflow_id || '',
    lifecycleContext,
    initialOmitted,
    loadedArtifacts: [
      ...contractArtifacts,
      ...handoffArtifacts,
      ...activeCastResult.artifacts,
      ...(workflowTaskMatchesTarget ? workflowTaskArtifacts : []),
    ],
  };
}

function emptyWorkflowTaskContext(workflowId = '') {
  return {
    workflow_id: workflowId,
    workflow_type: '',
    user_goal: '',
    scope: '',
    rpd: '',
    entries: [],
    warnings: [],
    loadedPaths: [],
    artifacts: [],
    lifecycle_context: {},
  };
}

function resolveLifecycleContext(options, workflowTaskContext, targetParts) {
  const stored = workflowTaskContext.lifecycle_context && typeof workflowTaskContext.lifecycle_context === 'object'
    ? workflowTaskContext.lifecycle_context
    : {};
  return {
    node: String(options.lifecycleNode || stored.node || stored.lifecycle_node || ''),
    book_id: String(options.bookId || stored.book_id || ''),
    volume_id: String(options.volumeId || stored.volume_id || targetParts.volume || ''),
    stage_id: String(options.stageId || stored.stage_id || ''),
    chapter_id: String(options.chapterId || stored.chapter_id || (targetParts.chapter === null ? '' : chapterLabelFor(targetParts.chapter))),
    task_family_id: String(options.taskFamilyId || stored.task_family_id || workflowTaskContext.task_family_id || ''),
    workflow_id: String(options.workflowId || stored.workflow_id || workflowTaskContext.workflow_id || ''),
  };
}

function loadActiveCast(root, file) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return { value: {}, artifacts: [], malformed: false };
  const text = fs.readFileSync(file, 'utf8');
  const parsed = readJson(file);
  const valid = parsed && typeof parsed === 'object' && !Array.isArray(parsed)
    && ['presentCharacters', 'activeHooks', 'blockedReveals'].every(key => parsed[key] === undefined || Array.isArray(parsed[key]));
  if (!valid) return { value: {}, artifacts: [], malformed: true };
  return {
    value: parsed,
    artifacts: [{ path: path.relative(root, file), text, targetScoped: false }],
    malformed: false,
  };
}

function taskContextMatchesTarget(taskContext, target) {
  if (!taskContext || !taskContext.workflow_id || !taskContext.scope) return true;
  return normalize(taskContext.scope).includes(normalize(target)) || normalize(target).includes(normalize(taskContext.scope));
}

function normalizeTargetPath(target) {
  return String(target || '').replace(/[\\/]/g, path.sep);
}

function parseTarget(target) {
  const volumeMatch = String(target || '').match(/第([0-9一二三四五六七八九十百千万]+)卷/);
  const chapterMatch = String(target || '').match(/第([0-9]{1,4})章/);
  return {
    volume: volumeMatch ? `第${volumeMatch[1]}卷` : '',
    chapter: chapterMatch ? Number(chapterMatch[1]) : null,
  };
}

function loadLoreEntries(root) {
  const file = path.join(root, '追踪', 'memory', 'lorebook.jsonl');
  if (!fs.existsSync(file)) return [];
  const parsed = fs.readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        die(`invalid lorebook jsonl at line ${index + 1}: ${error.message}`);
      }
    });
  const latest = new Map();
  for (const entry of parsed) if (entry && entry.id) latest.set(entry.id, entry);
  return Array.from(latest.values()).filter(entry => !['deprecated', 'archived', 'stale', 'rejected', 'superseded'].includes(String(entry.status || 'active')));
}

function loadAcceptedFactEntries(root) {
  const file = path.join(root, '追踪', 'memory', 'facts.jsonl');
  if (!fs.existsSync(file)) return { entries: [], omitted: [], debts: [], index: null, indexSource: 'not_applicable' };
  const latest = new Map();
  const omitted = [];
  const debts = [];
  const rawEvents = [];
  fs.readFileSync(file, 'utf8').split(/\r?\n/).map(line => line.trim()).filter(Boolean).forEach((line, index) => {
    let fact;
    try {
      fact = JSON.parse(line);
    } catch (error) {
      die(`invalid facts jsonl at line ${index + 1}: ${error.message}`);
    }
    if (fact && fact.fact_id) {
      rawEvents.push(fact);
      latest.set(fact.fact_id, fact);
    }
  });
  const events = Array.from(latest.values());
  const indexState = loadOrBuildActiveMemoryIndex(root, rawEvents);
  const entries = events
    .filter(fact => String(fact.status || 'active') === 'active' && (fact.valid_to === undefined || fact.valid_to === null || fact.valid_to === ''))
    .map(fact => {
      const originalEvidence = Array.isArray(fact.evidence) ? fact.evidence : [];
      const validation = validateMemoryEvidence(root, originalEvidence);
      if (validation.status !== 'valid') {
        omitted.push({ id: fact.fact_id, title: `${fact.subject || ''}-${fact.predicate || ''}`, reason: 'memory_evidence_debt' });
        debts.push({
          fact_id: fact.fact_id,
          title: `${fact.subject || ''}-${fact.predicate || ''}`,
          status: validation.status,
          evidence_path: String(((validation.findings || [])[0] || {}).path || ''),
          findings: validation.findings || [],
          fact,
        });
        return null;
      }
      return {
      ...fact,
      id: fact.fact_id,
      memory_id: fact.fact_id,
      type: 'accepted_fact',
      title: `${fact.subject}-${fact.predicate}`,
      triggers: [fact.subject, fact.object, ...(fact.aliases || []), ...(fact.dependencies || [])].filter(Boolean),
      content: `${fact.subject} - ${fact.predicate}: ${fact.object}`,
      constraints: [],
      sourceRefs: validation.evidence,
      priority: Math.round(100 * Number(fact.confidence === undefined ? 1 : fact.confidence)),
      facts: [{ key: `${fact.subject}:${fact.predicate}`, value: fact.object }],
      };
    }).filter(Boolean);
  const obsoleteDebtIds = new Set(debts
    .filter(debt => obsoleteCanonicalRevisionDebt(root, debt))
    .map(debt => debt.fact_id));
  for (const item of omitted) {
    if (obsoleteDebtIds.has(item.id)) item.reason = 'superseded_canonical_revision';
  }
  return {
    entries,
    omitted,
    debts: debts.filter(debt => !obsoleteDebtIds.has(debt.fact_id)),
    index: indexState.index,
    indexSource: indexState.source,
  };
}

function obsoleteCanonicalRevisionDebt(root, debt) {
  if (!debt || debt.status !== 'hash_mismatch') return false;
  const state = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  const accepted = Array.isArray(state.accepted_sections) ? state.accepted_sections : [];
  const authority = new Map(accepted.map(item => [normalizePath((item || {}).canonical_path), item]));
  const evidence = Array.isArray(((debt || {}).fact || {}).evidence) ? debt.fact.evidence : [];
  const changed = (debt.findings || []).filter(item => item.status === 'hash_mismatch');
  if (!changed.length) return false;
  return changed.every(finding => {
    const relative = normalizePath(finding.path);
    const current = authority.get(relative);
    const source = evidence.find(item => normalizePath((item || {}).path) === relative) || {};
    if (!current || !relative || !String(source.source_commit_id || '') || !String(current.section_commit_id || '')) return false;
    if (String(source.source_commit_id) === String(current.section_commit_id)) return false;
    const file = path.join(root, relative);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return false;
    return normalizeDigest(current.sha256) === normalizeDigest(`sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`);
  });
}

function quarantineControlledRevisionDebts(debts, workflowTaskContext) {
  const queue = workflowTaskContext && workflowTaskContext.revision_queue;
  if (!queue || String(queue.status || '') !== 'running' || String(queue.source_stage || '') !== 'full_story_assembly') {
    return { debts: debts || [], omitted: [] };
  }
  const affected = new Set((Array.isArray(queue.affected_sections) ? queue.affected_sections : [])
    .map(Number).filter(value => Number.isInteger(value) && value > 0));
  const quarantined = [];
  const remaining = [];
  for (const debt of debts || []) {
    const paths = (debt.findings || []).map(item => normalizePath((item || {}).path));
    const controlled = paths.length > 0 && paths.every(relative => {
      const match = /(?:^|\/)第0*(\d+)节\.md$/u.exec(relative);
      return match && affected.has(Number(match[1]));
    });
    if (!controlled) {
      remaining.push(debt);
      continue;
    }
    quarantined.push({
      id: debt.fact_id,
      title: debt.title,
      reason: 'pending_controlled_reacceptance',
      evidence_path: debt.evidence_path,
    });
  }
  return { debts: remaining, omitted: quarantined };
}

function normalizePath(value) {
  return String(value || '').replace(/\\/g, '/').replace(/^\.\//, '').trim();
}

function normalizeDigest(value) {
  const text = String(value || '').trim().toLowerCase();
  return text && !text.startsWith('sha256:') ? `sha256:${text}` : text;
}

function classifyMemoryDebts(debts, context) {
  return (debts || []).map(debt => {
    const fact = debt.fact || {};
    const entry = {
      id: debt.fact_id,
      title: debt.title,
      type: 'accepted_fact',
      scope: fact.scope || {},
      priority: Math.round(100 * Number(fact.confidence === undefined ? 1 : fact.confidence)),
      triggers: [fact.subject, fact.object, ...(fact.aliases || []), ...(fact.dependencies || [])].filter(Boolean),
      aliases: fact.aliases || [],
    };
    const score = scoreEntry(entry, context);
    const critical = fact.critical !== false && Number(fact.confidence === undefined ? 1 : fact.confidence) >= 0.8;
    const relevant = score.score > 0 && score.hasQualifyingSupport;
    return {
      fact_id: debt.fact_id,
      title: debt.title,
      status: debt.status,
      evidence_path: debt.evidence_path,
      severity: critical && relevant ? 'blocking' : 'advisory',
      impact: relevant ? '当前目标可能依赖该事实，继续会造成设定漂移。' : '当前目标不直接依赖该事实，已隔离为待修复债务。',
      recovery_action: '通过已接受的章节提交或事实提交补写/更新证据，然后重新装配上下文。',
      findings: debt.findings,
    };
  });
}

function filterMemoryProvenance(entries, root) {
  const eligible = [];
  const omitted = [];
  const familyCache = new Map();
  for (const entry of entries) {
    const provenance = entry && entry.provenance && typeof entry.provenance === 'object' ? entry.provenance : null;
    const acceptanceStatus = String(entry.acceptanceStatus || entry.acceptance_status || (provenance && provenance.acceptance_status) || '');
    if (acceptanceStatus && !['accepted', 'legacy_unbound'].includes(acceptanceStatus)) {
      omitted.push({ id: entry.id, title: entry.title, reason: 'unaccepted_source' });
      continue;
    }
    if (entry.valid_to !== undefined && entry.valid_to !== null && entry.valid_to !== '') {
      omitted.push({ id: entry.id, title: entry.title, reason: 'expired_source' });
      continue;
    }
    if (!provenance || !provenance.task_family_id) {
      eligible.push(entry);
      continue;
    }
    const familyId = String(provenance.task_family_id);
    if (!familyCache.has(familyId)) familyCache.set(familyId, readTaskFamily(root, familyId));
    const family = familyCache.get(familyId);
    const acceptedHead = family
      && String(family.head_workflow_id || '') === String(provenance.workflow_id || '')
      && String(provenance.acceptance_status || '') === 'accepted';
    if (acceptedHead) eligible.push(entry);
    else omitted.push({ id: entry.id, title: entry.title, reason: family ? 'non_head_branch' : 'missing_task_family_provenance' });
  }
  return { eligible, omitted };
}

function filterMemoryLifecycle(entries, lifecycleContext) {
  if (!lifecycleContext.node) return { eligible: entries, omitted: [] };
  const allowed = new Set(allowedMemoryLayers(lifecycleContext.node));
  const eligible = [];
  const omitted = [];
  for (const entry of entries) {
    const layer = memoryLayer(entry);
    entry._memoryLayer = layer;
    if (!allowed.has(layer)) {
      omitted.push({ id: entry.id, title: entry.title, reason: 'lifecycle_layer_excluded', layer });
      continue;
    }
    if (!memoryScopeMatches(entry, layer, lifecycleContext)) {
      omitted.push({ id: entry.id, title: entry.title, reason: 'lifecycle_scope_mismatch', layer });
      continue;
    }
    eligible.push(entry);
  }
  return { eligible, omitted };
}

function allowedMemoryLayers(node) {
  if (['positioning', 'story_bible', 'master_outline', 'master_outline_review', 'book_acceptance'].includes(node)) return ['book', 'task'];
  if (['volume_outline', 'volume_outline_review', 'volume_acceptance'].includes(node)) return ['book', 'volume', 'task'];
  if (['stage_detail_outline', 'detail_outline_review', 'milestone_review'].includes(node)) return ['book', 'volume', 'stage', 'task'];
  return MEMORY_LAYER_ORDER;
}

function memoryLayer(entry) {
  const explicit = String(entry.memoryLayer || entry.memory_layer || '').toLowerCase();
  if (MEMORY_LAYER_ORDER.includes(explicit)) return explicit;
  const scope = entry.scope && typeof entry.scope === 'object' ? entry.scope : {};
  const sourcePaths = (entry.sourceRefs || []).map(ref => String((ref || {}).path || '').replace(/\\/g, '/'));
  if (scope.task || scope.task_family_id || scope.workflow_id) return 'task';
  if (scope.chapter || scope.chapter_id || scope.chapterRange || sourcePaths.some(value => /(^|\/)正文\//.test(value))) return 'chapter';
  if (scope.stage || scope.stage_id) return 'stage';
  if (scope.volume || scope.volume_id) return 'volume';
  return 'book';
}

function memoryScopeMatches(entry, layer, lifecycle) {
  const scope = entry.scope && typeof entry.scope === 'object' ? entry.scope : {};
  const levels = layer === 'task' ? ['book', 'volume', 'stage', 'chapter', 'task'] : MEMORY_LAYER_ORDER.slice(0, MEMORY_LAYER_ORDER.indexOf(layer) + 1);
  return levels.every(level => {
    const expected = {
      book: lifecycle.book_id,
      volume: lifecycle.volume_id,
      stage: lifecycle.stage_id,
      chapter: lifecycle.chapter_id,
      task: lifecycle.task_family_id || lifecycle.workflow_id,
    }[level];
    const actual = {
      book: scope.book,
      volume: scope.volume || scope.volume_id,
      stage: scope.stage || scope.stage_id,
      chapter: scope.chapter || scope.chapter_id,
      task: scope.task || scope.task_family_id || scope.workflow_id,
    }[level];
    if (level === 'chapter' && scope.chapterRange) {
      const chapter = chapterNumber(expected);
      return chapter !== null && rangeContains(scope.chapterRange, chapter);
    }
    return !actual || actual === 'current' || !expected || String(actual) === String(expected);
  });
}

function buildLayeredMemorySources(entries, lifecycleContext) {
  const allowed = lifecycleContext.node ? allowedMemoryLayers(lifecycleContext.node) : MEMORY_LAYER_ORDER;
  return allowed.map(layer => ({
    layer,
    entries: entries.filter(entry => (entry._memoryLayer || memoryLayer(entry)) === layer).map(selectionRecord),
  }));
}

function memorySourceIsStale(entry, root) {
  const refs = Array.isArray(entry.sourceRefs) ? entry.sourceRefs : [];
  for (const ref of refs) {
    const expected = String((ref && ref.hash) || '');
    if (!/^sha256:[a-f0-9]{64}$/i.test(expected)) continue;
    const file = resolveProjectPath(root, String(ref.path || ''));
    if (!file || !fs.existsSync(file) || !fs.statSync(file).isFile()) return true;
    const actual = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
    if (actual !== expected.toLowerCase()) return true;
  }
  return false;
}

function relevantStaleEntries(stale, context) {
  return stale
    .map(entry => ({ entry, score: scoreEntry(entry, context) }))
    .filter(item => item.score.score > 0 && item.score.hasQualifyingSupport);
}

function scoreEntry(entry, context) {
  let score = 0;
  const reasons = [];
  let hasQualifyingSupport = false;
  const scope = entry.scope && typeof entry.scope === 'object' ? entry.scope : {};
  if (scope.volume && context.targetParts.volume !== scope.volume) {
    return { score, reasons: ['scope:volume_mismatch'], hasQualifyingSupport };
  }
  if (scope.chapterRange && (context.targetParts.chapter === null || !rangeContains(scope.chapterRange, context.targetParts.chapter))) {
    return { score, reasons: ['scope:chapter_range_mismatch'], hasQualifyingSupport };
  }
  const haystack = normalize([
    context.target,
    context.contractText,
    context.handoffText,
    JSON.stringify(context.activeCast),
  ].join('\n'));

  const triggers = [...(entry.triggers || []), ...(entry.aliases || []), entry.title].filter(Boolean);
  for (const trigger of triggers) {
    const normalizedTrigger = normalize(trigger);
    if (normalizedTrigger && haystack.includes(normalizedTrigger)) {
      score += 30;
      reasons.push(`match:trigger:${trigger}`);
      break;
    }
  }

  const volumeMatches = !scope.volume || context.targetParts.volume === scope.volume;
  const bookMatches = !scope.book || scope.book === 'current' || !context.lifecycleContext.book_id || scope.book === context.lifecycleContext.book_id;
  if (scope.book && bookMatches && !scope.volume && !scope.chapterRange) {
    score += 35;
    reasons.push('support:bookCanon');
    hasQualifyingSupport = true;
  }

  if (scope.volume && context.targetParts.volume === scope.volume) {
    score += 20;
    reasons.push('support:volume');
    hasQualifyingSupport = true;
  }

  if (volumeMatches && scope.chapterRange && context.targetParts.chapter !== null && rangeContains(scope.chapterRange, context.targetParts.chapter)) {
    score += 20;
    reasons.push('support:chapterRange');
    hasQualifyingSupport = true;
  }

  const scopedChapter = scope.chapter || scope.chapter_id;
  if (scopedChapter && context.lifecycleContext.chapter_id && String(scopedChapter) === context.lifecycleContext.chapter_id) {
    score += 20;
    reasons.push('support:chapter');
    hasQualifyingSupport = true;
  }

  const scopedStage = scope.stage || scope.stage_id;
  if (scopedStage && context.lifecycleContext.stage_id && String(scopedStage) === context.lifecycleContext.stage_id) {
    score += 20;
    reasons.push('support:stage');
    hasQualifyingSupport = true;
  }

  const scopedTask = scope.task || scope.task_family_id || scope.workflow_id;
  if (scopedTask && [context.lifecycleContext.task_family_id, context.lifecycleContext.workflow_id].includes(String(scopedTask))) {
    score += 20;
    reasons.push('support:task');
    hasQualifyingSupport = true;
  }

  if (context.activeCast.presentCharacters && intersects(context.activeCast.presentCharacters, triggers)) {
    score += 25;
    reasons.push('support:activeCast');
    hasQualifyingSupport = true;
  }

  if (context.activeCast.activeHooks && intersects(context.activeCast.activeHooks, [entry.id, entry.title, ...(entry.aliases || [])])) {
    score += 25;
    reasons.push('support:activeHook');
    hasQualifyingSupport = true;
  }

  const sourceSupport = hasSourceSupport(entry, context);
  if (sourceSupport) {
    score += 15;
    reasons.push(`support:sourceRef:${sourceSupport}`);
    hasQualifyingSupport = true;
  }

  const priority = Number(entry.priority || 0);
  if (score > 0 && Number.isFinite(priority) && priority > 0) {
    score += Math.min(20, Math.floor(priority / 5));
    reasons.push(`weight:priority:${Math.min(20, Math.floor(priority / 5))}`);
  }

  if ((entry.type || '') === 'negative_constraint') {
    score += 10;
    reasons.push('weight:negativeConstraint');
  }

  return { score: Math.round(score), reasons, hasQualifyingSupport };
}

function acceptedFactScore(entry, factScores) {
  const ranked = factScores.get(entry.id);
  if (!ranked) return { score: 0, reasons: ['not_relevant:chinese_retrieval'], hasQualifyingSupport: false };
  return {
    score: ranked.score,
    reasons: [`match:chinese:${ranked.score >= 300 ? 'alias' : ranked.score >= 200 ? 'dependency' : 'han_bigram'}`],
    hasQualifyingSupport: ranked.evidence.length > 0,
  };
}

function memoryRetrievalQuery(context) {
  return [
    context.target,
    context.contractText,
    context.handoffText,
    JSON.stringify(context.activeCast),
    context.workflowTaskContext.user_goal,
    context.workflowTaskContext.rpd,
  ].join('\n');
}

function detectConflicts(selected, context) {
  const conflicts = detectMemoryConflicts(selected);
  const blockedReveals = new Set((context.activeCast.blockedReveals || []).map(normalize));

  if (blockedReveals.size === 0) return conflicts;

  for (const entry of selected) {
    const content = normalize(`${entry.content || ''}\n${(entry.constraints || []).join('\n')}`);
    const includesBlockedReveal = [...blockedReveals].some(reveal => reveal && content.includes(reveal));
    if (!includesBlockedReveal) continue;

    const related = selected.find(other => {
      if (other.id === entry.id) return false;
      const otherText = normalize(`${other.content || ''}\n${(other.constraints || []).join('\n')}`);
      return otherText.includes('不得在第010章前直说') || otherText.includes('不能暴露系统真相') || otherText.includes('公开系统真相');
    });
    if (related) {
      conflicts.push({
        type: 'blocked_reveal_conflict',
        entryIds: [related.id, entry.id].sort(),
        message: 'active cast blocks a reveal that another selected entry requires',
      });
    }
  }

  return conflicts;
}

function detectPollution(entry) {
  const text = `${entry.title || ''}\n${entry.content || ''}\n${(entry.constraints || []).join('\n')}`;
  return detectPollutionText(text);
}

function detectPollutionText(text) {
  const findings = [];
  const repeatedTerm = text.match(/([\u4e00-\u9fff]{2,8})\1{8,}/);
  if (repeatedTerm) findings.push({ code: 'repeated_term_loop', term: repeatedTerm[1] });

  const repeatedLineCount = text.split(/\r?\n/).filter(Boolean).reduce((acc, line) => {
    acc[line] = (acc[line] || 0) + 1;
    return acc;
  }, {});
  if (Object.values(repeatedLineCount).some(count => count >= 4)) findings.push({ code: 'repeated_line_loop' });

  return findings;
}

function detectPacketPollution(packet) {
  const findings = [];
  const fields = [
    ['packet.hard_constraints', (packet.hard_constraints || []).join('\n')],
    ['packet.must_inherit', packet.must_inherit],
    ['packet.author_voice', packet.author_voice],
    ['packet.active_cast', JSON.stringify(packet.active_cast || {})],
    ['packet.task_context.rpd', packet.task_context && packet.task_context.rpd],
    ['packet.task_context.entries', packet.task_context && JSON.stringify(packet.task_context.entries || [])],
  ];

  for (const [fieldPath, value] of fields) {
    for (const finding of detectPollutionText(String(value || ''))) {
      findings.push({
        path: fieldPath,
        ...finding,
        message: `assembled packet field ${fieldPath} contains polluted content`,
      });
    }
  }

  return findings;
}

function buildBudgetSources(context, entries) {
  const sources = [];
  for (const entry of entries) {
    for (const [index, constraint] of (entry.constraints || []).entries()) {
      sources.push({
        id: `constraint:${entry.id}:${index}`,
        title: entry.title,
        kind: 'constraint',
        mandatory: true,
        requiredComplete: true,
        rank: entry._score || 0,
        text: constraint,
        entryId: entry.id,
      });
    }
  }
  sources.push(
    { id: 'context.contract', title: 'chapter contract', kind: 'contract', rank: 1000, requiredComplete: Boolean(context.contractText), text: context.contractText },
    {
      id: 'context.workflow_meta',
      title: 'workflow metadata',
      kind: 'workflow_meta',
      rank: 990,
      requiredComplete: true,
      text: JSON.stringify({
        workflow_type: context.workflowTaskContext.workflow_type,
        user_goal: context.workflowTaskContext.user_goal,
        scope: context.workflowTaskContext.scope,
      }),
    },
    { id: 'context.workflow_rpd', title: 'workflow RPD', kind: 'workflow_rpd', rank: 980, requiredComplete: Boolean(context.workflowTaskContext.rpd), text: context.workflowTaskContext.rpd },
    { id: 'context.handoff', title: 'handoff', kind: 'handoff', rank: 900, text: context.handoffText },
    { id: 'context.active_cast', title: 'active cast', kind: 'active_cast', rank: 850, text: JSON.stringify(context.activeCast || {}) },
    { id: 'context.author_voice', title: 'author voice', kind: 'author_voice', rank: 500, text: context.authorVoiceText },
  );
  for (const entry of context.workflowTaskContext.entries || []) {
    sources.push({
      id: `context.workflow_entry:${entry.path}`,
      title: entry.path,
      kind: 'workflow_entry',
      rank: 960,
      requiredComplete: Boolean(entry.requiredComplete),
      text: entry.content,
      entry,
    });
  }
  for (const entry of entries) {
    sources.push({
      id: `lore:${entry.id}`,
      title: entry.title,
      kind: 'lore',
      rank: entry._score || 0,
      text: entry.content || '',
      entryId: entry.id,
      layer: entry._memoryLayer || memoryLayer(entry),
      unresolvedDependencyCount: unresolvedDependencyCount(entry),
    });
  }
  return sources;
}

function unresolvedDependencyCount(entry) {
  const resolved = new Set((entry.resolved_dependencies || entry.resolvedDependencies || []).map(normalize));
  return (entry.dependencies || []).map(normalize).filter(dependency => dependency && !resolved.has(dependency)).length;
}

function workflowMemoryLayer(node) {
  const allowed = allowedMemoryLayers(node || '');
  return [...allowed].reverse().find(layer => layer !== 'task') || 'book';
}

function buildPacket(context, selected, omitted, allocation, diagnostics) {
  const selectedById = new Map(allocation.selected.map(item => [item.id, item]));
  const selectedConstraints = allocation.selected.filter(item => item.kind === 'constraint').map(item => item.text);
  const selectedTaskEntries = allocation.selected
    .filter(item => item.kind === 'workflow_entry')
    .map(item => ({ ...item.entry, content: item.text }));
  const activeCastSource = selectedById.get('context.active_cast');
  const activeCast = activeCastSource ? JSON.parse(activeCastSource.text) : {};
  const workflowMetaSource = selectedById.get('context.workflow_meta');
  const workflowMeta = workflowMetaSource ? JSON.parse(workflowMetaSource.text) : {};
  const selectedLore = selected.map(entry => ({
    id: entry.id,
    type: entry.type,
    title: entry.title,
    content: selectedById.get(`lore:${entry.id}`).text,
    constraints: [],
    sourceRefs: entry.sourceRefs || [],
    evidence: entry.evidence || entry.sourceRefs || [],
    reasons: entry._reasons || [],
  }));
  const workflowTaskContext = serializeTaskContext({
    ...context.workflowTaskContext,
    workflow_type: workflowMeta.workflow_type || '',
    user_goal: workflowMeta.user_goal || '',
    scope: workflowMeta.scope || '',
    rpd: selectedById.get('context.workflow_rpd') ? selectedById.get('context.workflow_rpd').text : '',
    entries: selectedTaskEntries,
    loadedPaths: [
      ...(selectedById.get('context.workflow_rpd') ? context.workflowTaskContext.loadedPaths.filter(item => item.endsWith('/rpd.md')) : []),
      ...selectedTaskEntries.map(item => item.path),
    ],
  });
  return {
    packetVersion: 1,
    workflow_id: context.workflowId,
    lifecycle_context: context.lifecycleContext,
    memory_sources: diagnostics.memorySources,
    task: context.task,
    target: context.target,
    generatedAt: new Date().toISOString(),
    estimated_total_tokens: allocation.used,
    budget: { requested: context.tokenBudget, used: allocation.used },
    selected: allocation.selected.map(item => ({ id: item.id, title: item.title, source: item.kind, estimated_tokens: item.estimated_tokens, truncated: item.truncated })),
    omitted,
    stale: diagnostics.stale,
    quarantined: diagnostics.quarantined,
    conflicts: diagnostics.conflicts,
    memory_debts: diagnostics.memoryDebts || [],
    hard_constraints: selectedConstraints,
    active_cast: activeCast,
    task_context: workflowTaskContext,
    must_inherit: [selectedById.get('context.contract'), selectedById.get('context.handoff')].filter(Boolean).map(item => item.text).join('\n'),
    relevant_lore: selectedLore,
    negative_constraints: selected.filter(entry => entry.type === 'negative_constraint').map(entry => selectedById.get(`lore:${entry.id}`).text),
    author_voice: selectedById.get('context.author_voice') ? selectedById.get('context.author_voice').text : '',
    omitted_due_to_budget: omitted.filter(entry => entry.reason === 'budget_exceeded'),
  };
}

function writePacket(root, packet, context, options = {}) {
  const taskDir = String(options.taskDir || '').trim();
  const runId = String(options.runId || '').trim();
  if (taskDir && runId && packet.workflow_id) {
    const taskRoot = resolveProjectPath(root, taskDir);
    const stageId = safePacketSegment(options.stageId || context.lifecycleContext.stage_id || 'context', 'stage');
    const safeRunId = safePacketSegment(runId, 'run id');
    if (!taskRoot) throw new Error('context packet task directory is unsafe');
    const stageDir = path.join(taskRoot, 'context-packets', stageId);
    const attemptDir = path.join(stageDir, safeRunId);
    const packetJson = path.join(attemptDir, 'assembled-context.json');
    const packetMd = path.join(attemptDir, 'assembled-context.md');
    const jsonText = `${JSON.stringify(packet, null, 2)}\n`;
    const packetDigest = crypto.createHash('sha256').update(jsonText).digest('hex');
    atomicWriteText(packetJson, jsonText);
    atomicWriteText(packetMd, renderMarkdown(packet));
    atomicWriteText(path.join(stageDir, 'latest-accepted.json'), `${JSON.stringify({
      schemaVersion: '1.0.0',
      workflow_id: packet.workflow_id,
      stage_id: stageId,
      run_id: safeRunId,
      packet_json: packetJson,
      packet_md: packetMd,
      packet_digest: packetDigest,
      accepted_at: new Date().toISOString(),
    }, null, 2)}\n`);
    return { packetJson, packetMd, packetDigest, packetMode: 'task_immutable' };
  }
  const dir = path.join(root, '追踪', 'context-pack');
  fs.mkdirSync(dir, { recursive: true });
  const packetKey = packet.workflow_id ? `${packet.workflow_id}-${packet.task}-${packet.target}` : `${packet.task}-${packet.target}`;
  const safe = packetKey.replace(/[\\/:*?"<>|\s]+/g, '-').replace(/-+/g, '-');
  const packetJson = path.join(dir, `${safe}.assembled-context.json`);
  const packetMd = path.join(dir, `${safe}.assembled-context.md`);
  const jsonText = `${JSON.stringify(packet, null, 2)}\n`;
  atomicWriteText(packetJson, jsonText);
  atomicWriteText(packetMd, renderMarkdown(packet));
  return {
    packetJson,
    packetMd,
    packetDigest: crypto.createHash('sha256').update(jsonText).digest('hex'),
    packetMode: 'interactive_compat',
  };
}

function safePacketSegment(value, label) {
  const normalized = String(value || '').trim();
  if (!/^[A-Za-z0-9._-]+$/.test(normalized)) throw new Error(`context packet ${label} is unsafe`);
  return normalized;
}

function atomicWriteText(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const descriptor = fs.openSync(temporary, 'w');
  try {
    fs.writeFileSync(descriptor, text, 'utf8');
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.renameSync(temporary, file);
}

function loadWorkflowTaskContext(root, options = {}) {
  const empty = {
    workflow_id: '',
    workflow_type: '',
    user_goal: '',
    scope: '',
    rpd: '',
    entries: [],
    warnings: [],
    loadedPaths: [],
    artifacts: [],
    lifecycle_context: {},
    task_family_id: '',
    authority_status: '',
    authority_message: '',
  };
  const explicitWorkflowId = String(options.workflowId || '').trim();
  const explicitTaskDir = String(options.taskDir || '').trim();
  if (explicitTaskDir && !explicitWorkflowId) {
    return {
      ...empty,
      authority_status: 'blocked_task_authority_mismatch',
      authority_message: 'an explicit task directory requires a workflow id',
    };
  }

  let currentTask = null;
  if (explicitWorkflowId) {
    const explicit = resolveTaskContext(root, explicitWorkflowId, explicitTaskDir);
    if (explicit.status === 'ok') {
      currentTask = explicit.task;
    } else if (explicitTaskDir || explicit.status !== 'blocked_task_authority_missing') {
      return {
        ...empty,
        authority_status: explicit.status,
        authority_message: explicit.message || 'durable task snapshot is unavailable',
      };
    }
  } else {
    const focused = readFocusedTask(root);
    if (focused.pointer && focused.authority.status !== 'ok') {
      return {
        ...empty,
        authority_status: focused.authority.status,
        authority_message: focused.authority.message || 'durable task snapshot is unavailable',
      };
    }
    currentTask = focused.authority.status === 'ok' ? focused.authority.task : null;
  }
  if (!currentTask || !currentTask.workflow_id) return empty;

  const taskDirRel = currentTask.task_dir || path.join('追踪', 'workflow', 'tasks', String(currentTask.workflow_id));
  const taskDir = resolveProjectPath(root, taskDirRel);
  if (!taskDir) {
    empty.workflow_id = currentTask.workflow_id;
    empty.warnings.push({ code: 'unsafe_task_dir', path: taskDirRel });
    return empty;
  }

  const contextPaths = currentTask.context_paths || {};
  const rpdRel = contextPaths.rpd || currentTask.rpd_path || path.join(taskDirRel, 'rpd.md');
  const contextJsonlRel = contextPaths.context_jsonl || path.join(taskDirRel, 'context.jsonl');
  const output = {
    workflow_id: currentTask.workflow_id,
    workflow_type: currentTask.workflow_type || '',
    user_goal: currentTask.user_goal || '',
    scope: currentTask.scope || '',
    rpd: '',
    entries: [],
    warnings: [],
    loadedPaths: [],
    artifacts: [],
    lifecycle_context: currentTask.lifecycle_context || {},
    task_family_id: currentTask.task_family_id || '',
    revision_queue: summarizeRevisionQueue(currentTask.feedback_revision_queue),
  };

  const rpdArtifact = readExplicitTaskArtifact(root, rpdRel, 'rpd', '任务需求与读者承诺', output.warnings);
  if (rpdArtifact) {
    output.rpd = rpdArtifact.text;
    output.loadedPaths.push(rpdArtifact.path);
    output.artifacts.push(rpdArtifact);
  }

  const jsonlFile = resolveProjectPath(root, contextJsonlRel);
  if (!jsonlFile) {
    output.warnings.push({ code: 'unsafe_path', path: contextJsonlRel });
    return output;
  }
  if (!fs.existsSync(jsonlFile) || !fs.statSync(jsonlFile).isFile()) {
    output.warnings.push({ code: 'missing_context_jsonl', path: path.relative(root, jsonlFile) || contextJsonlRel });
    return output;
  }

  const lines = fs.readFileSync(jsonlFile, 'utf8').split(/\r?\n/);
  lines.forEach((line, index) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let entry;
    try {
      entry = JSON.parse(trimmed);
    } catch (error) {
      output.warnings.push({ code: 'invalid_context_jsonl', path: path.relative(root, jsonlFile), line: index + 1, message: error.message });
      return;
    }

    const artifact = readExplicitTaskArtifact(
      root,
      entry.path,
      entry.kind || 'context',
      entry.reason || '',
      output.warnings,
    );
    if (!artifact) return;
    output.entries.push({
      kind: artifact.kind,
      path: artifact.path,
      reason: artifact.reason,
      content: artifact.text,
    });
    output.loadedPaths.push(artifact.path);
    output.artifacts.push(artifact);
  });

  output.loadedPaths = [...new Set(output.loadedPaths)];
  return output;
}

function summarizeRevisionQueue(queue) {
  if (!queue || typeof queue !== 'object') return null;
  return {
    queue_id: String(queue.queue_id || ''),
    source_stage: String(queue.source_stage || ''),
    status: String(queue.status || ''),
    affected_sections: Array.isArray(queue.affected_sections) ? queue.affected_sections.map(Number).filter(Number.isInteger) : [],
    current_section_index: Number(queue.current_section_index || 0) || null,
  };
}

function readExplicitTaskArtifact(root, relPath, kind, reason, warnings) {
  const requestedPath = String(relPath || '').trim();
  if (!requestedPath) {
    warnings.push({ code: 'missing_path', message: 'task context entry has no path' });
    return null;
  }

  const resolved = resolveProjectPath(root, requestedPath);
  if (!resolved) {
    warnings.push({ code: 'unsafe_path', path: requestedPath });
    return null;
  }
  const relativePath = path.relative(root, resolved);
  if (!fs.existsSync(resolved)) {
    warnings.push({ code: 'missing_file', path: relativePath });
    return null;
  }
  if (!fs.statSync(resolved).isFile()) {
    warnings.push({ code: 'not_file', path: relativePath });
    return null;
  }

  const requiredComplete = requiredTaskArtifact(kind);
  const text = fs.readFileSync(resolved, 'utf8');
  return {
    kind,
    path: relativePath,
    reason,
    requiredComplete,
    text: requiredComplete ? text : compactText(text, taskArtifactBudget(kind)),
  };
}

function requiredTaskArtifact(kind) {
  const normalized = String(kind || '').toLowerCase();
  return normalized === 'rpd' || normalized.includes('brief') || normalized.includes('contract');
}

function serializeTaskContext(context) {
  if (!context || !context.workflow_id) {
    return {
      workflow_id: '',
      workflow_type: '',
      user_goal: '',
      scope: '',
      rpd: '',
      entries: [],
      warnings: [],
      loadedPaths: [],
    };
  }
  return {
    workflow_id: context.workflow_id,
    workflow_type: context.workflow_type,
    user_goal: context.user_goal,
    scope: context.scope,
    rpd: context.rpd,
    entries: context.entries,
    warnings: context.warnings,
    loadedPaths: context.loadedPaths,
  };
}

function taskArtifactBudget(kind) {
  const normalizedKind = String(kind || '').toLowerCase();
  if (normalizedKind === 'rpd') return 5000;
  if (normalizedKind.includes('brief') || normalizedKind.includes('contract')) return 5000;
  if (normalizedKind.includes('material') || normalizedKind.includes('card')) return 4000;
  return 3000;
}

function renderMarkdown(packet) {
  const lines = [];
  lines.push(`# Assembled Context: ${packet.task} ${packet.target}`);
  lines.push('');
  lines.push('## hard_constraints');
  for (const item of packet.hard_constraints) lines.push(`- ${item}`);
  lines.push('');
  lines.push('## active_cast');
  lines.push('```json');
  lines.push(JSON.stringify(packet.active_cast || {}, null, 2));
  lines.push('```');
  lines.push('');
  lines.push('## task_context');
  if (packet.task_context && packet.task_context.workflow_id) {
    lines.push(`workflow_id: ${packet.task_context.workflow_id}`);
    if (packet.task_context.workflow_type) lines.push(`workflow_type: ${packet.task_context.workflow_type}`);
    if (packet.task_context.user_goal) lines.push(`user_goal: ${packet.task_context.user_goal}`);
    if (packet.task_context.scope) lines.push(`scope: ${packet.task_context.scope}`);
    lines.push('');
    lines.push('### RPD');
    lines.push(packet.task_context.rpd || 'None');
    lines.push('');
    lines.push('### explicit_context');
    for (const entry of packet.task_context.entries || []) {
      lines.push(`#### ${entry.kind || 'context'} ${entry.path || ''}`.trim());
      if (entry.reason) lines.push(`reason: ${entry.reason}`);
      lines.push(entry.content || '');
      lines.push('');
    }
    if ((packet.task_context.warnings || []).length > 0) {
      lines.push('### warnings');
      for (const warning of packet.task_context.warnings) {
        const visibleDetail = warning.code === 'unsafe_path' || warning.code === 'unsafe_task_dir'
          ? 'skipped unsafe project path'
          : (warning.path || warning.message || '');
        lines.push(`- ${warning.code}: ${visibleDetail}`);
      }
    }
  } else {
    lines.push('None');
  }
  lines.push('');
  lines.push('## must_inherit');
  lines.push(packet.must_inherit || 'None');
  lines.push('');
  lines.push('## relevant_lore');
  for (const entry of packet.relevant_lore) {
    lines.push(`### ${entry.id} ${entry.title || ''}`.trim());
    lines.push(entry.content || '');
    const evidence = Array.isArray(entry.evidence) && entry.evidence.length ? entry.evidence : entry.sourceRefs;
    for (const item of evidence || []) {
      const evidencePath = typeof item === 'string' ? item : (item && item.path);
      if (evidencePath) lines.push(`- evidence: ${evidencePath}`);
    }
    for (const constraint of entry.constraints || []) lines.push(`- constraint: ${constraint}`);
  }
  lines.push('');
  lines.push('## negative_constraints');
  for (const item of packet.negative_constraints) lines.push(`- ${item}`);
  lines.push('');
  lines.push('## author_voice');
  lines.push(packet.author_voice || 'None');
  lines.push('');
  lines.push('## omitted_due_to_budget');
  for (const item of packet.omitted_due_to_budget) lines.push(`- ${item.id}: ${item.reason}`);
  lines.push('');
  return `${lines.join('\n')}\n`;
}

function rangeContains(range, chapter) {
  const nums = String(range).match(/[0-9]{1,4}/g);
  if (!nums || nums.length === 0) return false;
  if (nums.length === 1) return Number(nums[0]) === chapter;
  return chapter >= Number(nums[0]) && chapter <= Number(nums[1]);
}

function chapterNumber(value) {
  const match = String(value || '').match(/[0-9]{1,4}/);
  return match ? Number(match[0]) : null;
}

function readBestText(root, candidates) {
  for (const rel of candidates) {
    const file = path.join(root, rel);
    if (fs.existsSync(file) && fs.statSync(file).isFile()) return fs.readFileSync(file, 'utf8');
  }
  return '';
}

function readBestArtifact(root, candidates, targetScoped) {
  for (const rel of candidates) {
    const file = path.join(root, rel);
    if (fs.existsSync(file) && fs.statSync(file).isFile()) {
      return [{
        path: path.relative(root, file),
        text: fs.readFileSync(file, 'utf8'),
        targetScoped: Boolean(targetScoped),
      }];
    }
  }
  return [];
}

function readDirectoryText(dir, maxChars) {
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return '';
  const chunks = [];
  for (const name of fs.readdirSync(dir).sort()) {
    const file = path.join(dir, name);
    if (fs.statSync(file).isFile() && name.endsWith('.md')) chunks.push(fs.readFileSync(file, 'utf8'));
    if (chunks.join('\n').length >= maxChars) break;
  }
  return compactText(chunks.join('\n'), maxChars);
}

function readDirectoryArtifacts(root, dir, maxChars, targetScoped) {
  if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return [];
  const artifacts = [];
  let usedChars = 0;

  for (const name of fs.readdirSync(dir).sort()) {
    const file = path.join(dir, name);
    if (!fs.statSync(file).isFile() || !name.endsWith('.md')) continue;

    const remaining = maxChars - usedChars;
    if (remaining <= 0) break;

    const text = fs.readFileSync(file, 'utf8');
    const boundedText = text.length <= remaining ? text : compactText(text, remaining);
    artifacts.push({
      path: path.relative(root, file),
      text: boundedText,
      targetScoped: Boolean(targetScoped),
    });
    usedChars += boundedText.length;
  }

  return artifacts;
}

function readRelevantHandoffArtifacts(root, targetParts) {
  const artifacts = [];
  const handoffRoot = path.join(root, '追踪', '交接包');
  const targetChapter = chapterLabelFor(targetParts.chapter);
  const visit = dir => {
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return;
    for (const name of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, name);
      if (!fs.statSync(file).isFile() || !name.endsWith('.md')) continue;
      const rel = path.relative(root, file);
      const inTargetVolume = targetParts.volume && normalizePath(rel).includes(normalizePath(`追踪/交接包/${targetParts.volume}/`));
      const targetsChapter = targetChapter && name.includes(`to_${targetChapter}`);
      if (!inTargetVolume && !targetsChapter) continue;
      artifacts.push({ path: rel, text: fs.readFileSync(file, 'utf8'), targetScoped: true });
    }
  };
  visit(handoffRoot);
  if (targetParts.volume) visit(path.join(handoffRoot, targetParts.volume));

  const volumeHandoffDir = path.join(root, '追踪', '卷交接');
  if (targetParts.volume && fs.existsSync(volumeHandoffDir) && fs.statSync(volumeHandoffDir).isDirectory()) {
    for (const name of fs.readdirSync(volumeHandoffDir).sort()) {
      const file = path.join(volumeHandoffDir, name);
      if (!fs.statSync(file).isFile() || !name.endsWith('.md') || !name.includes(`_to_${targetParts.volume}`)) continue;
      artifacts.push({ path: path.relative(root, file), text: fs.readFileSync(file, 'utf8'), targetScoped: true });
    }
  }
  return artifacts;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function hasSourceSupport(entry, context) {
  const sourceRefs = Array.isArray(entry.sourceRefs) ? entry.sourceRefs : [];
  const artifacts = Array.isArray(context.loadedArtifacts) ? context.loadedArtifacts : [];
  const relevantText = normalize(artifacts.map(item => `${item.path}\n${item.text}`).join('\n'));

  for (const ref of sourceRefs) {
    const refPath = String((ref && ref.path) || '').trim();
    if (!refPath) continue;

    if (relevantText.includes(normalize(refPath))) return 'path_mentioned';
    if (matchesTargetScopedArtifact(refPath, artifacts)) return 'target_scoped_path';

    const resolved = resolveProjectPath(context.projectRoot, refPath);
    if (!resolved || !fs.existsSync(resolved) || !fs.statSync(resolved).isFile()) continue;

    const contentSupport = sourceContentSupport(resolved, context);
    if (contentSupport) return contentSupport;
  }

  return '';
}

function resolveProjectPath(projectRoot, refPath) {
  const resolved = path.resolve(projectRoot, refPath);
  if (resolved === projectRoot || !resolved.startsWith(projectRoot + path.sep)) return '';
  return resolved;
}

function matchesTargetScopedArtifact(refPath, artifacts) {
  const normalizedRef = normalizePath(refPath);
  return artifacts.some(item => {
    if (!item || !item.targetScoped || !item.path) return false;
    const artifactPath = normalizePath(item.path);
    if (normalizedRef === artifactPath) return true;
    const artifactDir = normalizePath(path.dirname(item.path));
    return artifactDir && artifactDir !== '.' && normalizedRef.startsWith(`${artifactDir}/`);
  });
}

function sourceContentSupport(file, context) {
  const text = compactText(fs.readFileSync(file, 'utf8'), 8000);
  const normalizedText = normalize(text);
  if (!normalizedText) return '';

  if (context.target && normalizedText.includes(normalize(context.target))) return 'content_target';
  if (context.targetParts.volume && normalizedText.includes(normalize(context.targetParts.volume))) return 'content_volume';

  const chapterLabel = chapterLabelFor(context.targetParts.chapter);
  if (chapterLabel && normalizedText.includes(normalize(chapterLabel))) return 'content_chapter';

  const presentCharacters = Array.isArray(context.activeCast.presentCharacters) ? context.activeCast.presentCharacters : [];
  if (presentCharacters.some(name => name && normalizedText.includes(normalize(name)))) return 'content_active_cast';

  const activeHooks = Array.isArray(context.activeCast.activeHooks) ? context.activeCast.activeHooks : [];
  if (activeHooks.some(hook => hook && normalizedText.includes(normalize(hook)))) return 'content_active_hook';

  const ranges = text.match(/第[0-9]{1,4}(?:[-~至][0-9]{1,4})?章/g) || [];
  if (context.targetParts.chapter !== null && ranges.some(range => rangeContains(range, context.targetParts.chapter))) {
    return 'content_range';
  }

  return '';
}

function chapterLabelFor(chapter) {
  if (chapter === null || chapter === undefined) return '';
  return `第${String(chapter).padStart(3, '0')}章`;
}

function normalizePath(value) {
  return String(value || '').replace(/\\/g, '/').replace(/^\.\/+/, '').replace(/\/+/g, '/').toLowerCase();
}

function normalize(text) {
  return String(text || '').toLowerCase().replace(/\s+/g, '');
}

function intersects(a, b) {
  const bSet = new Set((b || []).map(normalize));
  return (a || []).some(item => bSet.has(normalize(item)));
}

function compactText(text, maxChars) {
  const value = String(text || '').trim();
  if (value.length <= maxChars) return value;
  return `${value.slice(0, maxChars)}\n[truncated:${value.length - maxChars}]`;
}

function printJson(value) {
  console.log(JSON.stringify(value, null, 2));
}

function die(message) {
  console.error(message);
  process.exit(2);
}
