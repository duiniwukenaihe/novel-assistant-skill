'use strict';

const { assertStorageBackend } = require('./storage-backend-contract');
const { LocalStorageBackend } = require('./local-storage-backend');

// Only content sources participate in a writing snapshot revision. Auxiliary
// ledgers are visible to the control plane, but changes there must not make an
// otherwise unrelated Brief or draft memory receipt stale.
const CONTENT_SOURCES = Object.freeze({
  project_state: '追踪/private-short-extension/project-state.json',
  lorebook: '追踪/memory/lorebook.jsonl',
  facts: '追踪/memory/facts.jsonl',
  active_cast: '追踪/memory/active-cast.json',
  promises: '追踪/schema/promises.jsonl',
  style_rules: '追踪/schema/user-style-rules.jsonl',
  pollution_rules: '追踪/schema/output-pollution-rules.jsonl',
  preferences: '追踪/workflow/preference-memory.jsonl',
  planning_constraints: '追踪/memory/planning-constraints.jsonl',
});

const AUXILIARY_SOURCES = Object.freeze({
  memory_suggestions: '追踪/memory/memory-suggestions.jsonl',
  memory_audit: '追踪/memory/memory-audit.jsonl',
  domain_learning: '追踪/private-short-extension/learning-ledger.jsonl',
});

const SOURCES = Object.freeze({ ...CONTENT_SOURCES, ...AUXILIARY_SOURCES });

class StoryMemoryRepository {
  constructor(projectRoot, options = {}) {
    this.backend = assertStorageBackend(options.backend || new LocalStorageBackend(projectRoot));
  }

  capabilities() { return this.backend.capabilities(); }
  projectIdentity() { return this.backend.projectIdentity(); }
  projectState() { return this.backend.readJson(SOURCES.project_state) || {}; }
  acceptedFacts() { return this.backend.readJsonlLatest(SOURCES.facts, 'fact_id'); }
  activeCast() { return this.backend.readJson(SOURCES.active_cast) || {}; }
  promises() { return this.backend.readJsonlLatest(SOURCES.promises, ['promise_id', 'id']); }
  styleRules() { return this.backend.readJsonlLatest(SOURCES.style_rules, ['rule_id', 'id', 'entryId']); }
  preferences() { return this.backend.readJsonlLatest(SOURCES.preferences, ['entryId', 'id', 'rule_id']); }
  planningConstraints() { return this.backend.readJsonlLatest(SOURCES.planning_constraints, 'constraint_id'); }
  pollutionRules() { return this.backend.readJsonlLatest(SOURCES.pollution_rules, ['rule_id', 'id', 'entryId', 'phrase']); }
  memorySuggestions() { return this.backend.readJsonlLatest(SOURCES.memory_suggestions, ['suggestionId', 'suggestion_id', 'entryId', 'id']); }
  memoryAudit() { return this.backend.readJsonlLatest(SOURCES.memory_audit, ['eventId', 'event_id', 'suggestionId', 'entryId', 'id']); }
  domainLearning() { return this.backend.readJsonlLatest(SOURCES.domain_learning, ['learning_id', 'entry_id', 'event_id', 'id', 'source_id']); }
  readText(relativePath) { return this.backend.readText(relativePath); }
  sourceRevision(relativePath) { return this.backend.sourceRevision(relativePath); }

  sourceRevisions() {
    return Object.fromEntries(Object.values(CONTENT_SOURCES).map(relative => [relative, this.backend.sourceRevision(relative)]));
  }

  allSourceRevisions() {
    return Object.fromEntries(Object.values(SOURCES).map(relative => [relative, this.backend.sourceRevision(relative)]));
  }

  summary() {
    const active = rows => rows.filter(row => isActive(row)).length;
    return {
      project: this.projectState(),
      identity: this.projectIdentity(),
      active_facts: active(this.acceptedFacts()),
      active_promises: active(this.promises()),
      confirmed_style_rules: this.styleRules().filter(isAcceptedRule).length,
      planning_constraints: active(this.planningConstraints()),
      quality_rules: active(this.pollutionRules()),
      pending_memory_suggestions: this.memorySuggestions().filter(row => ['pending', 'proposed', ''].includes(String((row || {}).status || '').toLowerCase())).length,
      domain_learning_records: active(this.domainLearning()),
      backend: this.capabilities().backend,
    };
  }
}

function isActive(row) {
  const status = String((row || {}).status || 'active').toLowerCase();
  return !['superseded', 'rejected', 'quarantined', 'closed', 'invalid'].includes(status) && !(row || {}).valid_to;
}

function isAcceptedRule(row) {
  return ['active', 'accepted', 'applied', 'current', 'confirmed'].includes(String((row || {}).status || 'active').toLowerCase());
}

module.exports = { AUXILIARY_SOURCES, CONTENT_SOURCES, SOURCES, StoryMemoryRepository };

if (require.main === module) {
  const repository = new StoryMemoryRepository(process.argv[2] || process.cwd());
  process.stdout.write(`${JSON.stringify(repository.summary(), null, 2)}\n`);
}
