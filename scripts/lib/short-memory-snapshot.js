'use strict';

const fs = require('fs');
const path = require('path');
const { rankChineseMemory } = require('./chinese-memory-retrieval');
const { StoryMemoryRepository } = require('./story-memory-repository');
const {
  createMemoryContract,
  createMemoryReadReceipt,
  normalizeMemoryQuery,
} = require('./memory-query-contract');
const {
  buildMemoryRevision,
  deriveMemoryTokenBudget,
  selectWithinTokenBudget,
} = require('./memory-snapshot-engine');

function buildShortMemorySnapshot(projectRoot, options = {}) {
  const root = path.resolve(projectRoot || '');
  const task = options.task && typeof options.task === 'object' ? options.task : {};
  const sectionIndex = positiveInt(options.sectionIndex);
  if (!root || !fs.existsSync(root) || !sectionIndex) {
    return { status: 'not_applicable', reason: !sectionIndex ? 'section_identity_missing' : 'project_root_missing' };
  }

  const repository = options.repository || new StoryMemoryRepository(root, { backend: options.backend });
  const projectState = repository.projectState();
  if (!String(projectState.project_id || '').trim()) {
    return { status: 'not_applicable', reason: 'short_project_identity_missing' };
  }
  const workflowId = String(task.workflow_id || 'project-memory');
  const stageId = String(options.stageId || task.current_stage || '');
  const sourceDigests = repository.sourceRevisions();
  const queryText = buildQuery(repository, sectionIndex, { stageId });
  const memoryQuery = normalizeMemoryQuery({
    project_id: String(projectState.project_id || ''),
    project_instance_id: String((repository.projectIdentity() || {}).project_instance_id || ''),
    workflow_id: workflowId,
    workflow_type: String(task.workflow_type || 'short_write'),
    stage_id: stageId || 'short_memory_snapshot',
    owner_module: String(task.workflow_owner || 'story-short-write'),
    scope: { section_index: sectionIndex },
    needs: ['accepted_facts', 'active_cast', 'active_promises', 'confirmed_style_rules', 'confirmed_quality_rules', 'planning_constraints', 'continuity_obligations', 'canon_constraints'],
    query_text: queryText,
  });
  const memoryTokenBudget = deriveMemoryTokenBudget({ task, query: queryText, stageId });
  const factSelection = selectFacts(
    repository.acceptedFacts(),
    queryText,
    sectionIndex,
    memoryTokenBudget,
  );
  const facts = factSelection.rows;
  const styleRules = selectRules(repository.styleRules(), queryText);
  const preferences = selectWritingPreferences(repository.preferences(), queryText);
  const qualityRules = selectQualityRules(repository.pollutionRules(), queryText);
  const promises = selectPromises(repository.promises(), sectionIndex);
  const planningConstraints = selectPlanningConstraints(repository, sectionIndex, task);
  const activeCast = compactActiveCast(repository.activeCast(), facts, queryText);
  const continuityObligations = buildContinuityObligations(facts, promises, planningConstraints, sectionIndex);
  const selectedEntryIds = unique([
    ...facts.map(item => item.fact_id),
    ...styleRules.map(item => item.id),
    ...preferences.map(item => item.id),
    ...qualityRules.map(item => item.id),
    ...promises.map(item => item.id),
    ...planningConstraints.map(item => item.id),
  ]);
  const selectedMemory = {
    accepted_facts: facts.map(compactFact),
    active_cast: activeCast,
    active_promises: promises,
    confirmed_style_rules: [...styleRules, ...preferences].map(compactRule),
    confirmed_quality_rules: qualityRules.map(compactRule),
    continuity_obligations: continuityObligations,
    canon_constraints: planningConstraints,
  };
  const memoryRevision = buildMemoryRevision({
    project_id: String(projectState.project_id || ''),
    scope: { section_index: sectionIndex },
    selected_memory: selectedMemory,
  });
  const payload = {
    schema_version: '1.0.0',
    title: '当前作品记忆快照',
    project_id: String(projectState.project_id || ''),
    project_title: String(projectState.project_title || projectState.working_title || projectState.title || ''),
    section_index: sectionIndex,
    memory_revision: memoryRevision,
    ...selectedMemory,
    selection_budget: {
      token_budget: factSelection.token_budget,
      used_tokens: factSelection.used_tokens,
      omitted_count: factSelection.omitted_count,
      priority_overflow: factSelection.priority_overflow,
    },
    boundary: '只包含当前作品已接受事实、已确认规划约束与已确认规则；待处理聊天、候选稿、热点素材原文和其他短篇均未注入。',
  };
  const contract = createMemoryContract({
    query: memoryQuery,
    provider: 'story-memory',
    memoryRevision,
    packetDigest: memoryRevision,
    tokenBudget: factSelection.token_budget,
    usedTokens: factSelection.used_tokens,
    selectedEntryIds,
    omittedCount: factSelection.omitted_count,
  });
  const receipt = {
    ...createMemoryReadReceipt(contract),
    workflow_profile: String(task.workflow_profile || 'public'),
    section_index: sectionIndex,
    source_digests: sourceDigests,
    generated_at: new Date().toISOString(),
  };
  // The contract keeps the full retrieval query for audit, but prose stages
  // already receive the compacted Brief separately. Keep contract metadata in
  // the packet JSON and do not duplicate the query inside the model-facing
  // memory snapshot.
  return { status: 'assembled', payload, contract, receipt };
}

function validateShortStageMemoryReceipt(projectRoot, task, execution, options = {}) {
  const packetRel = String((((execution || {}).stage_context_packet || {}).packet_json) || '');
  if (!packetRel) return { status: 'not_recorded', reason: 'stage_context_packet_missing' };
  const root = path.resolve(projectRoot || '');
  const packetFile = safeProjectFile(root, packetRel);
  if (!packetFile || !fs.existsSync(packetFile)) return { status: 'missing', stale_sources: ['stage_context_packet'] };
  const packet = readJson(packetFile);
  if (!packet) return { status: 'missing', stale_sources: ['stage_context_packet'] };
  const sectionIndex = positiveInt(options.sectionIndex || packet.section_index);
  return validateShortMemoryReceipt(root, packet.memory_read_receipt, {
    task,
    sectionIndex,
    stageId: String(options.stageId || packet.stage_id || (execution || {}).stage_id || ''),
  });
}

function validateShortMemoryReceipt(projectRoot, receipt, options = {}) {
  if (!receipt || typeof receipt !== 'object' || !String(receipt.memory_revision || '')) {
    return { status: 'missing', stale_sources: ['memory_read_receipt'] };
  }
  const current = buildShortMemorySnapshot(projectRoot, options);
  if (current.status !== 'assembled') return { status: current.status, stale_sources: [] };
  if (String(receipt.workflow_id || '') !== String(current.receipt.workflow_id || '')
      || Number(receipt.section_index || 0) !== Number(current.receipt.section_index || 0)) {
    return { status: 'scope_mismatch', stale_sources: ['workflow_or_section_identity'], current_receipt: current.receipt };
  }
  if (String(receipt.memory_revision || '') === String(current.receipt.memory_revision || '')) {
    return { status: 'current', current_receipt: current.receipt };
  }
  const staleSources = unique(Object.keys({ ...(receipt.source_digests || {}), ...(current.receipt.source_digests || {}) })
    .filter(key => String((receipt.source_digests || {})[key] || '') !== String((current.receipt.source_digests || {})[key] || '')));
  return { status: 'stale', stale_sources: staleSources, current_receipt: current.receipt };
}

function buildQuery(repository, sectionIndex, options = {}) {
  const pad = String(sectionIndex).padStart(3, '0');
  const stageId = String(options.stageId || '');
  const includeCurrentBrief = !/^(?:first_section_brief|section_brief|next_section_brief)$/u.test(stageId);
  return [
    includeCurrentBrief ? repository.readText(`写作Brief_第${pad}节.md`) : '',
    extractOutlineSection(repository.readText('小节大纲.md'), sectionIndex),
    sectionIndex > 1 ? repository.readText(`追踪/private-short-extension/section-${String(sectionIndex - 1).padStart(3, '0')}-anchor.json`) : '',
  ].filter(Boolean).join('\n');
}

function selectFacts(rows, query, sectionIndex, tokenBudget) {
  const eligible = deduplicateContinuityFacts(
    rows.filter(row => isActive(row) && factSection(row) < sectionIndex)
  );
  const mandatory = eligible.filter(row => {
    const section = factSection(row);
    return section === 0 || section === sectionIndex - 1;
  });
  const ranked = rankChineseMemory(eligible, query, { limit: eligible.length }).map(item => item.entry);
  const selected = selectWithinTokenBudget({
    priority: mandatory,
    ranked,
    tokenBudget,
    serialize: row => JSON.stringify(compactFact(row)),
  });
  return {
    ...selected,
    rows: selected.entries.sort((left, right) => factSection(left) - factSection(right) || String(left.fact_id || '').localeCompare(String(right.fact_id || ''))),
  };
}

function deduplicateContinuityFacts(rows) {
  const selected = new Map();
  for (const row of rows) {
    const key = continuityFactKey(row);
    const current = selected.get(key);
    if (!current || continuityFactScore(row) > continuityFactScore(current)) selected.set(key, row);
  }
  return [...selected.values()];
}

function continuityFactKey(row) {
  const section = factSection(row);
  const subject = String((row || {}).subject || '').trim();
  const predicate = String((row || {}).predicate || '').trim();
  if (/本节发生/u.test(predicate) || subject === 'summary') return `${section}:section_summary`;
  if (/钩子|待续|承诺/u.test(predicate)) return `${section}:open_hook`;
  if (/揭示/u.test(predicate)) return `${section}:revealed_information`;
  // Different accepted facts may legitimately share a character and predicate
  // (for example, two independent state changes in the same section). Only the
  // known generated summary/hook/reveal projections are semantic duplicates.
  return `${section}:${subject}:${predicate}:${String((row || {}).fact_id || '')}`;
}

function continuityFactScore(row) {
  const predicate = String((row || {}).predicate || '');
  const object = String((row || {}).object || '').trim();
  let score = 0;
  if (/钩子|待续|承诺/u.test(predicate) && /下一(?:节|步)|必须|承接/u.test(object)) score += 1000;
  if (object.length >= 24 && object.length <= 180) score += 500;
  score -= Math.abs(object.length - 90);
  return score;
}

function buildContinuityObligations(facts, promises, planningConstraints, sectionIndex) {
  const obligations = [];
  for (const fact of facts) {
    if (factSection(fact) !== sectionIndex - 1) continue;
    const predicate = String(fact.predicate || '');
    let requirement = 'do_not_contradict';
    let kind = 'accepted_fact';
    if (/钩子|待续|承诺/u.test(predicate)) {
      requirement = 'progress_or_hold_explicitly';
      kind = 'open_hook';
    } else if (/状态|身份|关系|认知|选择/u.test(predicate)) {
      requirement = 'preserve_or_explain_change';
      kind = 'character_or_relation_state';
    }
    obligations.push({
      source_id: String(fact.fact_id || ''),
      kind,
      requirement,
    });
  }
  for (const promise of promises) {
    if (positiveInt(promise.target_section) !== sectionIndex) continue;
    obligations.push({
      source_id: String(promise.id || ''),
      kind: 'due_promise',
      requirement: 'must_progress_now',
    });
  }
  for (const constraint of planningConstraints) {
    obligations.push({
      source_id: String(constraint.id || ''),
      kind: 'accepted_planning_constraint',
      requirement: 'must_obey_or_explicitly_replan',
    });
  }
  return obligations;
}

function selectPlanningConstraints(repository, sectionIndex, task = {}) {
  const persisted = repository.planningConstraints().filter(isActive).filter(row => {
    const refs = Array.isArray(row.source_refs) ? row.source_refs : [];
    if (!refs.length || refs.some(ref => String(repository.sourceRevision(String((ref || {}).path || ''))) !== String((ref || {}).hash || ''))) return false;
    const scope = row.scope && typeof row.scope === 'object' ? row.scope : {};
    if (scope.whole_story === true) return true;
    const sections = Array.isArray(row.affected_sections) ? row.affected_sections.map(positiveInt).filter(Boolean) : [];
    return !sections.length || sections.includes(sectionIndex);
  }).map(row => ({
    id: String(row.constraint_id || ''),
    content: String(row.content || ''),
    scope: row.scope && typeof row.scope === 'object' ? row.scope : {},
    affected_sections: Array.isArray(row.affected_sections) ? row.affected_sections.map(positiveInt).filter(Boolean) : [],
    evidence: (Array.isArray(row.source_refs) ? row.source_refs : []).map(ref => ({ path: String((ref || {}).path || '') })).filter(ref => ref.path),
  })).filter(row => row.id && row.content);
  const selected = new Map(persisted.map(row => [row.id, row]));
  for (const row of taskAcceptedPlanningConstraints(task, sectionIndex)) selected.set(row.id, row);
  return [...selected.values()];
}

function taskAcceptedPlanningConstraints(task, sectionIndex) {
  const plan = task.accepted_plan && typeof task.accepted_plan === 'object' ? task.accepted_plan : null;
  const acceptedStatuses = new Set(['projected_to_canonical_memory', 'completed']);
  if (!plan
      || (!acceptedStatuses.has(String(plan.status || ''))
        && !acceptedStatuses.has(String(plan.projection_status || '')))) return [];
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  const affected = [...new Set([
    ...(Array.isArray(plan.affected_sections) ? plan.affected_sections : []),
    ...(queue && String(queue.status || '') === 'running' && Array.isArray(queue.affected_sections) ? queue.affected_sections : []),
  ].map(positiveInt).filter(Boolean))];
  if (affected.length && !affected.includes(sectionIndex)) return [];
  return (Array.isArray(plan.requirements) ? plan.requirements : [])
    .map((row, index) => {
      const id = String((row || {}).requirement_id || `${plan.plan_id || 'accepted-plan'}.requirement-${index + 1}`);
      const content = String((row || {}).text || (row || {}).content || '').trim();
      return {
        id: `constraint.${id}`,
        content,
        scope: { book: 'current', sections: affected },
        affected_sections: affected,
        evidence: (Array.isArray(plan.projected_assets) ? plan.projected_assets : []).map(path => ({ path: String(path) })),
        source_kind: 'task_scoped_accepted_plan',
      };
    })
    .filter(row => row.id && row.content);
}

function selectRules(rows, query) {
  return rows.filter(isAcceptedRule).filter(row => {
    const scope = String(row.scope || row.workflow_type || row.affects || '');
    if (scope && !/(short|短篇|write|prose|all|global)/i.test(scope)) return false;
    const triggers = Array.isArray(row.triggers) ? row.triggers : [];
    return !triggers.length || triggers.some(item => query.includes(String(item || '')));
  }).map(row => ({ ...row, id: String(row.rule_id || row.entryId || row.id || '') })).filter(row => row.id);
}

function selectWritingPreferences(rows, query) {
  return rows.filter(isAcceptedRule).filter(row => {
    const descriptor = `${String(row.category || row.type || '')} ${String(row.scope || row.workflow_type || row.affects || '')}`;
    if (/(interaction|menu|route|workflow|update|setup|交互|菜单|路由|更新|部署)/iu.test(descriptor)) return false;
    return /(style|voice|prose|dialogue|short|write|fiction|文风|声口|行文|对话|短篇|写作|正文)/iu.test(descriptor);
  }).filter(row => {
    const triggers = Array.isArray(row.triggers) ? row.triggers : [];
    return !triggers.length || triggers.some(item => query.includes(String(item || '')));
  }).map(row => ({ ...row, id: String(row.rule_id || row.entryId || row.id || '') })).filter(row => row.id);
}

function selectQualityRules(rows, query) {
  return rows.filter(isAcceptedRule).filter(row => {
    const content = String(row.content || row.proposedContent || row.rule || row.message || row.phrase || '');
    const triggers = Array.isArray(row.triggers) ? row.triggers : [];
    return Boolean(content) && (!triggers.length || triggers.some(item => query.includes(String(item || ''))));
  }).slice(0, 16).map(row => ({ ...row, id: String(row.rule_id || row.entryId || row.id || row.phrase || '') })).filter(row => row.id);
}

function selectPromises(rows, sectionIndex) {
  return rows.filter(row => isActive(row) && promiseSection(row) < sectionIndex).map(row => ({
    id: String(row.promise_id || row.id || ''),
    summary: String(row.summary || row.promise || row.content || row.title || ''),
    status: String(row.status || 'active'),
    target_section: positiveInt(row.target_section || row.payoff_section) || null,
  })).filter(row => row.id && row.summary);
}

function compactFact(row) {
  return {
    id: String(row.fact_id || ''),
    subject: String(row.subject || ''),
    predicate: String(row.predicate || ''),
    object: String(row.object || ''),
    scope: row.scope && typeof row.scope === 'object' ? row.scope : {},
    evidence: Array.isArray(row.evidence) ? row.evidence.map(item => ({ path: String((item || {}).path || '') })).filter(item => item.path) : [],
  };
}

function compactRule(row) {
  return {
    id: String(row.id || ''),
    content: String(row.content || row.proposedContent || row.rule || row.message || ''),
    category: String(row.category || row.type || ''),
  };
}

function compactActiveCast(value, facts, query) {
  const result = {};
  const source = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  const inferred = (Array.isArray(facts) ? facts : []).filter(row => /出场|状态|认知|关系状态/u.test(String(row.predicate || '')))
    .flatMap(row => String(row.subject || '').split(/[-—↔/]/u).map(item => item.trim()).filter(Boolean));
  const present = unique([...(Array.isArray(source.presentCharacters) ? source.presentCharacters : []), ...inferred]);
  if (present.length) result.present_characters = present;
  if (source.characters && typeof source.characters === 'object' && !Array.isArray(source.characters)) {
    const selected = Object.entries(source.characters).filter(([name]) => query.includes(name) || present.includes(name));
    if (selected.length) result.characters = Object.fromEntries(selected);
  }
  return result;
}

function isActive(row) {
  const status = String((row || {}).status || 'active').toLowerCase();
  return !['superseded', 'rejected', 'quarantined', 'closed', 'invalid'].includes(status)
    && !(row || {}).valid_to;
}

function isAcceptedRule(row) {
  const status = String((row || {}).status || 'active').toLowerCase();
  return ['active', 'accepted', 'applied', 'current', 'confirmed'].includes(status);
}

function factSection(row) {
  return positiveInt(((row || {}).scope || {}).section || ((row || {}).scope || {}).chapter || row.section_index || row.chapter) || 0;
}

function promiseSection(row) {
  return positiveInt(row.opened_section || row.source_section || ((row || {}).scope || {}).section) || 0;
}

function extractOutlineSection(text, sectionIndex) {
  const lines = String(text || '').split(/\r?\n/);
  const heading = new RegExp(`^#{1,6}\\s*第\\s*0*${sectionIndex}\\s*节(?:\\s*[：:·.、-].*)?$`);
  const start = lines.findIndex(line => heading.test(line.trim()));
  if (start < 0) return '';
  let end = lines.length;
  for (let index = start + 1; index < lines.length; index += 1) {
    if (/^#{1,6}\s*第\s*0*\d+\s*节/u.test(lines[index].trim())) { end = index; break; }
  }
  return lines.slice(start, end).join('\n');
}

function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } }
function safeProjectFile(root, relativePath) {
  const raw = String(relativePath || '');
  if (!raw || path.isAbsolute(raw) || raw.split(/[\\/]+/).includes('..')) return '';
  const file = path.resolve(root, raw);
  return file.startsWith(`${root}${path.sep}`) ? file : '';
}
function positiveInt(value) { const number = Number(value); return Number.isInteger(number) && number > 0 ? number : 0; }
function unique(values) { return [...new Set(values.map(item => String(item || '')).filter(Boolean))]; }

module.exports = {
  buildShortMemorySnapshot,
  validateShortMemoryReceipt,
  validateShortStageMemoryReceipt,
};
