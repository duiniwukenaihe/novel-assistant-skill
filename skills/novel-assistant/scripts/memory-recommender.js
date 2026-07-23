#!/usr/bin/env node
'use strict';

const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { acquireBookWriteLease, atomicWriteText } = require('./lib/workflow-state-store');

const LOW_RISK_GUARD_PATTERNS = [
  {
    code: 'confirmed_canon_change',
    patterns: [
      /确认设定/,
      /已(?:经)?公开/,
      /真相/,
      /canon/i,
      /设定(?:改动|变更|调整)/,
    ],
  },
  {
    code: 'character_knowledge_boundary_change',
    patterns: [
      /(?:知道|知晓|发现|意识到|记得|想起).{0,12}(?:秘密|真相|读心|能力|身份|计划)/,
      /(?:认知|知识)边界/,
      /(?:公开|确认).{0,12}(?:知道|知晓|发现|意识到)/,
      /失忆/,
    ],
  },
  {
    code: 'hook_timing_or_payoff_move',
    patterns: [
      /伏笔/,
      /回收/,
      /提前到第\d+章/,
      /延后到第\d+章/,
      /第\d+章.{0,12}(揭晓|揭露|回收|兑现)/,
      /payoff/i,
    ],
  },
  {
    code: 'growth_business_power_rule_change',
    patterns: [
      /(?:成长|经营|商业|生意|力量|能力|战力|修为|升级|精神力).{0,12}(?:规则|上限|限制|调整|改为|提升|增长)/,
      /(?:规则|机制).{0,12}(?:调整|改为|变更)/,
      /每次升级/,
    ],
  },
  {
    code: 'chapter_numbering_change',
    patterns: [
      /章节编号/,
      /重编号/,
      /改为第\d+章/,
      /第\d+章.{0,12}(重命名|改名|更名)/,
    ],
  },
  {
    code: 'user_style_preference_change',
    patterns: [
      /(?:统一|以后|改成|改为).{0,12}(?:第一人称|第三人称|口吻|文风|风格|语气)/,
      /(?:第一人称|第三人称).{0,12}(?:口吻|文风|风格|语气)/,
      /冷幽默/,
      /style/i,
      /偏好/,
    ],
  },
];

const USAGE = `Usage:
  node scripts/memory-recommender.js --project-root <dir> --input <suggestions.json> --write --json
  node scripts/memory-recommender.js --project-root <dir> --apply-low-risk --json
  node scripts/memory-recommender.js --project-root <dir> --confirm <suggestion-id-or-entry-id> --decision apply|reject --json
  node scripts/memory-recommender.js --project-root <dir> --status --json`;

try {
  const args = parseArgs(process.argv);
  if (!args.projectRoot) throw failure('blocked_invalid_argument', '--project-root is required');
  const projectRoot = path.resolve(args.projectRoot);
  const memoryDir = path.join(projectRoot, '追踪', 'memory');
  let result;
  if (args.status) result = runStatus(memoryDir);
  else if (args.input && args.write) result = runRecordSuggestions(projectRoot, path.resolve(args.input));
  else if (args.applyLowRisk) result = runApplyLowRisk(projectRoot);
  else if (args.confirm) result = runConfirm(projectRoot, args.confirm, args.decision);
  else throw failure('blocked_invalid_argument', 'expected --input <file> --write, --apply-low-risk, --confirm, or --status');
  printJson(result);
} catch (error) {
  printJson({
    status: error && error.status ? error.status : 'error',
    message: String(error && error.message ? error.message : error),
  });
  process.exitCode = 2;
}

function parseArgs(argv) {
  const out = { projectRoot: '', input: '', write: false, applyLowRisk: false, status: false, confirm: '', decision: '', json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') out.projectRoot = argv[++i] || '';
    else if (arg === '--input') out.input = argv[++i] || '';
    else if (arg === '--write') out.write = true;
    else if (arg === '--apply-low-risk') out.applyLowRisk = true;
    else if (arg === '--confirm') out.confirm = argv[++i] || '';
    else if (arg === '--decision') out.decision = argv[++i] || '';
    else if (arg === '--status') out.status = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log(USAGE);
      process.exit(0);
    } else if (arg.startsWith('-')) {
      die(`unknown argument: ${arg}`);
    }
  }
  return out;
}

function runStatus(memoryDir) {
  const suggestionsFile = path.join(memoryDir, 'memory-suggestions.jsonl');
  const lorebookFile = path.join(memoryDir, 'lorebook.jsonl');
  const auditFile = path.join(memoryDir, 'memory-audit.jsonl');
  const lorebook = latestBy(readJsonl(lorebookFile), item => item.id);
  const suggestions = latestBy(readJsonl(suggestionsFile), suggestionKey).filter(item => item.status === 'pending');
  const audit = readJsonl(auditFile);
  const existingIds = new Set(lorebook.map(entry => entry.id).filter(Boolean));

  let autoApplicable = 0;
  const pendingConfirmations = [];
  const polluted = [];
  const effects = [];

  for (const suggestion of suggestions) {
    if (detectPollution(suggestion && suggestion.proposedContent)) {
      polluted.push(suggestion.entryId);
      continue;
    }

    const lowRiskScreen = classifyLowRiskSuggestion(suggestion);
    const canApply = lowRiskScreen.ok
      && suggestion.risk === 'low'
      && suggestion.action === 'create'
      && suggestion.entryId
      && !existingIds.has(suggestion.entryId);

    if (canApply) {
      autoApplicable += 1;
    } else {
      pendingConfirmations.push({
        entryId: suggestion.entryId || '',
        action: suggestion.action || '',
        risk: suggestion.risk || '',
        reason: lowRiskScreen.reason || suggestion.reason || '',
        affects: Array.isArray(suggestion.affects) ? suggestion.affects : [],
      });
    }

    if (Array.isArray(suggestion.affects)) effects.push(...suggestion.affects);
  }

  for (const entry of lorebook) {
    if (Array.isArray(entry.affects)) effects.push(...entry.affects);
  }

  const recentLearned = lorebook
    .filter(entry => entry && entry.status !== 'archived')
    .slice(-5)
    .reverse()
    .map(entry => ({
      id: entry.id || '',
      type: entry.type || '',
      title: entry.title || entry.id || '',
      summary: shorten(entry.content || '', 80),
      updatedAt: entry.updatedAt || '',
    }));

  return {
    status: 'memory_status',
    lorebookCount: lorebook.length,
    activeEntries: lorebook.filter(entry => entry && entry.status !== 'archived').length,
    pendingSuggestions: suggestions.length,
    autoApplicable,
    confirmationRequired: pendingConfirmations.length,
    blockedPollution: unique(polluted).length,
    recentLearned,
    pendingConfirmations,
    nextEffects: unique(effects).filter(Boolean).sort(),
    files: {
      lorebookFile,
      suggestionsFile,
      auditFile,
    },
    auditEvents: audit.length,
  };
}

function runRecordSuggestions(projectRoot, inputPath) {
  const raw = fs.readFileSync(inputPath, 'utf8');
  const suggestions = JSON.parse(raw);
  if (!Array.isArray(suggestions)) throw failure('blocked_invalid_memory_suggestions', 'suggestions input must be a JSON array');

  const polluted = suggestions.filter(item => detectPollution(item && item.proposedContent)).map(item => item.entryId).filter(Boolean);
  if (polluted.length > 0) {
    return { status: 'blocked_output_pollution', blockedEntryIds: unique(polluted) };
  }

  return mutateMemory(projectRoot, 'memory-recommender:record', state => {
    const now = new Date().toISOString();
    const existing = new Set(latestBy(state.suggestions, suggestionKey).map(suggestionKey));
    const normalized = suggestions.map(suggestion => {
      assertSuggestionSourceShape(suggestion);
      return {
        ...suggestion,
        suggestionId: suggestion.suggestionId || buildSuggestionId(suggestion),
        status: 'pending',
        createdAt: now,
      };
    }).filter(suggestion => !existing.has(suggestionKey(suggestion)));
    state.suggestions.push(...normalized);
    return {
      result: {
        status: normalized.length ? 'suggestions_recorded' : 'current',
        recorded: normalized.length,
        skippedDuplicates: suggestions.length - normalized.length,
        file: state.files.suggestionsFile,
      },
      write: { suggestions: normalized.length > 0 },
    };
  });
}

function runApplyLowRisk(projectRoot) {
  return mutateMemory(projectRoot, 'memory-recommender:apply-low-risk', state => {
    const suggestions = latestBy(state.suggestions, suggestionKey).filter(item => item.status === 'pending');
    const lorebook = latestBy(state.lorebook, item => item.id);
    const existingIds = new Set(lorebook.map(entry => entry.id).filter(Boolean));
    const now = new Date().toISOString();
    const polluted = suggestions.filter(suggestion => detectPollution(suggestion && suggestion.proposedContent)).map(suggestion => suggestion.entryId).filter(Boolean);
    if (polluted.length > 0) {
      return {
        result: { status: 'blocked_output_pollution', blockedEntryIds: unique(polluted), applied: 0, confirmationRequired: 0, lorebookFile: state.files.lorebookFile, auditFile: state.files.auditFile },
        write: {},
      };
    }

    let applied = 0;
    let confirmationRequired = 0;
    for (const suggestion of suggestions) {
      const lowRiskScreen = classifyLowRiskSuggestion(suggestion);
      const canApply = lowRiskScreen.ok && suggestion.risk === 'low' && suggestion.action === 'create' && suggestion.entryId && !existingIds.has(suggestion.entryId);
      if (canApply) {
        const provenance = verifySuggestionProvenance(projectRoot, suggestion);
        const entry = buildLorebookEntry(suggestion, now, null, provenance);
        state.lorebook.push(entry);
        state.audit.push({ action: 'applied', entryId: suggestion.entryId, suggestionAction: suggestion.action, risk: suggestion.risk, chapter_commit_id: provenance.chapter_commit_id || '', at: now });
        state.suggestions.push(suggestionStatus(suggestion, 'applied', now));
        existingIds.add(suggestion.entryId);
        applied += 1;
      } else {
        state.audit.push({ action: 'requires_confirmation', entryId: suggestion.entryId, suggestionAction: suggestion.action, risk: suggestion.risk, lowRiskGuard: lowRiskScreen.reason || null, at: now });
        confirmationRequired += 1;
      }
    }
    const status = applied > 0 || confirmationRequired === 0 ? 'applied_low_risk' : 'blocked_confirmation_required';
    return {
      result: { status, applied, confirmationRequired, lorebookFile: state.files.lorebookFile, auditFile: state.files.auditFile },
      write: { suggestions: applied > 0, lorebook: applied > 0, audit: applied > 0 || confirmationRequired > 0 },
    };
  });
}

function runConfirm(projectRoot, identifier, decision) {
  if (!['apply', 'reject'].includes(decision)) throw failure('blocked_invalid_argument', '--decision must be apply or reject');
  return mutateMemory(projectRoot, 'memory-recommender:confirm', state => {
    const suggestions = latestBy(state.suggestions, suggestionKey);
    const suggestion = suggestions.find(item => item.status === 'pending' && (item.suggestionId === identifier || item.entryId === identifier));
    if (!suggestion) return { result: { status: 'suggestion_not_found', identifier }, write: {} };
    const now = new Date().toISOString();
    if (decision === 'reject') {
      state.suggestions.push(suggestionStatus(suggestion, 'rejected', now));
      state.audit.push({ action: 'rejected', entryId: suggestion.entryId, suggestionId: suggestionKey(suggestion), at: now });
      return { result: { status: 'confirmed_rejected', entryId: suggestion.entryId, suggestionId: suggestionKey(suggestion) }, write: { suggestions: true, audit: true } };
    }
    const lorebook = latestBy(state.lorebook, item => item.id);
    const previous = lorebook.find(item => item.id === suggestion.entryId) || null;
    const provenance = verifySuggestionProvenance(projectRoot, suggestion);
    let entry;
    if (suggestion.action === 'archive') {
      if (!previous) throw failure('blocked_memory_entry_missing', `cannot archive missing memory entry: ${suggestion.entryId}`);
      entry = { ...previous, ...provenance, status: 'archived', version: Number(previous.version || 1) + 1, updatedAt: now };
    } else {
      entry = buildLorebookEntry(suggestion, now, previous, provenance);
    }
    state.lorebook.push(entry);
    state.suggestions.push(suggestionStatus(suggestion, 'applied', now));
    state.audit.push({ action: 'confirmed_applied', entryId: suggestion.entryId, suggestionId: suggestionKey(suggestion), suggestionAction: suggestion.action, risk: suggestion.risk, version: entry.version, chapter_commit_id: provenance.chapter_commit_id || '', at: now });
    return {
      result: { status: 'confirmed_applied', entryId: suggestion.entryId, suggestionId: suggestionKey(suggestion), version: entry.version, chapter_commit_id: provenance.chapter_commit_id || '', lorebookFile: state.files.lorebookFile },
      write: { suggestions: true, lorebook: true, audit: true },
    };
  });
}

function buildLorebookEntry(suggestion, now, previous = null, provenance = {}) {
  const content = String(suggestion.proposedContent || '');
  return {
    id: suggestion.entryId,
    type: suggestion.type || (previous && previous.type) || 'memory',
    title: suggestion.title || (previous && previous.title) || suggestion.entryId,
    aliases: Array.isArray(suggestion.aliases) ? suggestion.aliases : ((previous && previous.aliases) || []),
    triggers: extractTriggers(content),
    scope: suggestion.scope || (previous && previous.scope) || { book: 'current' },
    priority: Number(suggestion.priority || (previous && previous.priority) || 50),
    tokenBudget: Math.min(240, Math.max(80, Math.ceil(content.length / 2))),
    content,
    constraints: Array.isArray(suggestion.constraints) ? suggestion.constraints : ((previous && previous.constraints) || []),
    sourceRefs: mergeSourceRefs(previous && previous.sourceRefs, provenance.sourceRefs),
    status: 'active',
    version: previous ? Number(previous.version || 1) + 1 : 1,
    supersedes: previous ? `${previous.id}@v${Number(previous.version || 1)}` : '',
    chapter_commit_id: provenance.chapter_commit_id || '',
    accepted_artifact_id: provenance.accepted_artifact_id || '',
    sourceKind: provenance.sourceKind || '',
    workflowContext: suggestion.workflowContext || (previous && previous.workflowContext) || {},
    provenance_status: provenance.provenance_status || '',
    provenance_verified_at: provenance.provenance_verified_at || '',
    updatedAt: now,
  };
}

function suggestionStatus(suggestion, status, now) {
  return {
    ...suggestion,
    suggestionId: suggestionKey(suggestion),
    status,
    resolvedAt: now,
  };
}

function mutateMemory(projectRoot, owner, mutation) {
  const root = path.resolve(projectRoot);
  let release;
  try {
    release = acquireBookWriteLease(root, owner);
  } catch (error) {
    if (error && error.code === 'BOOK_WRITE_LOCKED') error.status = 'blocked_book_write_locked';
    throw error;
  }
  try {
    const files = memoryFiles(root);
    fs.mkdirSync(path.dirname(files.lorebookFile), { recursive: true });
    const state = {
      files,
      suggestions: readJsonl(files.suggestionsFile),
      lorebook: readJsonl(files.lorebookFile),
      audit: readJsonl(files.auditFile),
    };
    const outcome = mutation(state) || { result: {}, write: {} };
    persistMemoryMutation(state, outcome.write || {});
    return outcome.result;
  } finally {
    release();
  }
}

function memoryFiles(projectRoot) {
  const memoryDir = path.join(projectRoot, '追踪', 'memory');
  return {
    suggestionsFile: path.join(memoryDir, 'memory-suggestions.jsonl'),
    lorebookFile: path.join(memoryDir, 'lorebook.jsonl'),
    auditFile: path.join(memoryDir, 'memory-audit.jsonl'),
  };
}

function persistMemoryMutation(state, write) {
  const writes = [
    ['suggestions', state.files.suggestionsFile, state.suggestions],
    ['lorebook', state.files.lorebookFile, state.lorebook],
    ['audit', state.files.auditFile, state.audit],
  ].filter(([key]) => write[key]);
  if (!writes.length) return;
  const snapshots = new Map(writes.map(([, file]) => [file, fs.existsSync(file) ? fs.readFileSync(file) : null]));
  let completed = 0;
  try {
    for (const [, file, rows] of writes) {
      atomicWriteText(file, renderJsonl(rows));
      completed += 1;
      const forcedFailure = Number(process.env.NOVEL_ASSISTANT_TEST_FAIL_MEMORY_TRANSACTION_AFTER_WRITES || 0);
      if (forcedFailure > 0 && completed >= forcedFailure) throw new Error('forced memory transaction failure');
    }
  } catch (error) {
    for (const [, file] of [...writes].reverse()) {
      const before = snapshots.get(file);
      if (before === null) fs.rmSync(file, { force: true });
      else atomicWriteText(file, before);
    }
    throw failure('blocked_memory_transaction_rolled_back', String(error && error.message ? error.message : error));
  }
}

function renderJsonl(rows) {
  return rows.length ? `${rows.map(row => JSON.stringify(row)).join('\n')}\n` : '';
}

function assertSuggestionSourceShape(suggestion) {
  if (String((suggestion || {}).sourceKind || '') === 'user_confirmed') return;
  const refs = Array.isArray((suggestion || {}).sourceRefs) ? suggestion.sourceRefs : [];
  if (!refs.length || refs.some(ref => !isRealSha256(ref && ref.hash))) {
    throw failure('blocked_invalid_memory_provenance', 'memory suggestion requires non-placeholder sha256 sourceRefs or sourceKind=user_confirmed');
  }
}

function verifySuggestionProvenance(projectRoot, suggestion) {
  assertSuggestionSourceShape(suggestion);
  const verifiedAt = new Date().toISOString();
  if (String(suggestion.sourceKind || '') === 'user_confirmed') {
    const acceptedArtifactId = String(suggestion.accepted_artifact_id || suggestion.acceptedArtifactId || `user-confirmed:${suggestionKey(suggestion)}`);
    return {
      sourceRefs: [],
      sourceKind: 'user_confirmed',
      accepted_artifact_id: acceptedArtifactId,
      chapter_commit_id: '',
      provenance_status: 'verified',
      provenance_verified_at: verifiedAt,
    };
  }

  const refs = suggestion.sourceRefs.map(ref => ({ ...ref, path: normalizeRelativePath(ref.path), hash: String(ref.hash).toLowerCase() }));
  for (const ref of refs) {
    const source = resolveInside(projectRoot, ref.path);
    if (!fs.existsSync(source) || !fs.statSync(source).isFile() || hashFile(source) !== ref.hash) {
      throw failure('blocked_invalid_memory_provenance', `source reference does not match current artifact: ${ref.path}`);
    }
  }
  const commit = findAcceptedCommit(projectRoot, refs, suggestion.chapter_commit_id || suggestion.chapterCommitId);
  if (!commit) throw failure('blocked_invalid_memory_provenance', 'sourceRefs are not bound to an accepted chapter artifact');
  return {
    sourceRefs: refs,
    sourceKind: '',
    accepted_artifact_id: commit.commit_id,
    chapter_commit_id: commit.commit_id,
    provenance_status: 'verified',
    provenance_verified_at: verifiedAt,
  };
}

function findAcceptedCommit(projectRoot, refs, requestedId) {
  const commitsDir = path.join(projectRoot, '追踪', 'story-system', 'commits');
  if (!fs.existsSync(commitsDir)) return null;
  const candidates = fs.readdirSync(commitsDir).filter(name => name.endsWith('.json')).sort().reverse().map(name => readJson(path.join(commitsDir, name))).filter(Boolean);
  return candidates.find(commit => {
    if (commit.status !== 'accepted') return false;
    if (requestedId && String(commit.commit_id || '') !== String(requestedId)) return false;
    const artifacts = Array.isArray(commit.artifacts) ? commit.artifacts : [];
    return refs.every(ref => artifacts.some(artifact => normalizeRelativePath(artifact.target) === ref.path && String(artifact.after_hash || artifact.content_hash || '').toLowerCase() === ref.hash));
  }) || null;
}

function mergeSourceRefs(previousRefs, nextRefs) {
  const merged = [];
  const seen = new Set();
  for (const ref of [...(Array.isArray(previousRefs) ? previousRefs : []), ...(Array.isArray(nextRefs) ? nextRefs : [])]) {
    if (!ref || !ref.path || !ref.hash) continue;
    const key = `${ref.path}\u0000${ref.hash}`;
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(ref);
  }
  return merged;
}

function isRealSha256(value) {
  return /^sha256:[a-f0-9]{64}$/i.test(String(value || '')) && !/^sha256:([0-9a-f])\1{63}$/i.test(String(value || ''));
}

function normalizeRelativePath(value) {
  const normalized = String(value || '').replace(/\\/g, '/').replace(/^\.\//, '');
  if (!normalized || normalized.startsWith('/') || normalized.split('/').includes('..')) throw failure('blocked_invalid_memory_provenance', `unsafe source reference: ${value}`);
  return normalized;
}

function resolveInside(root, relative) {
  const resolvedRoot = path.resolve(root);
  const file = path.resolve(resolvedRoot, relative);
  if (!file.startsWith(`${resolvedRoot}${path.sep}`)) throw failure('blocked_invalid_memory_provenance', `source reference escapes project root: ${relative}`);
  return file;
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

function suggestionKey(suggestion) {
  return String((suggestion && suggestion.suggestionId) || buildSuggestionId(suggestion || {}));
}

function buildSuggestionId(suggestion) {
  const stable = JSON.stringify({
    action: suggestion.action || '',
    entryId: suggestion.entryId || '',
    proposedContent: suggestion.proposedContent || '',
    sourceRefs: suggestion.sourceRefs || [],
  });
  return `sg-${crypto.createHash('sha256').update(stable).digest('hex').slice(0, 16)}`;
}

function latestBy(items, keyFn) {
  const map = new Map();
  for (const item of items) {
    const key = keyFn(item);
    if (key) map.set(key, item);
  }
  return Array.from(map.values());
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line);
      } catch (error) {
        die(`invalid JSONL at ${file}:${index + 1}: ${error.message}`);
      }
    });
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function appendLines(file, lines) {
  if (lines.length === 0) return;
  fs.appendFileSync(file, `${lines.join('\n')}\n`);
}

function extractTriggers(text) {
  const matches = String(text || '').match(/[\u4e00-\u9fff]{2,8}/g) || [];
  return unique(matches).slice(0, 6);
}

function detectPollution(text) {
  const input = String(text || '').trim();
  if (!input) return false;

  const loopMatch = input.match(/([\u4e00-\u9fffA-Za-z0-9]{2,12})\1{5,}/);
  if (loopMatch) return true;

  const compact = input.replace(/\s+/g, '');
  if (/([\u4e00-\u9fff]{2,8})\1{4,}/.test(compact)) return true;

  return false;
}

function classifyLowRiskSuggestion(suggestion) {
  if (!suggestion || typeof suggestion !== 'object') {
    return { ok: false, reason: 'invalid_suggestion' };
  }

  if (suggestion.action !== 'create') {
    return { ok: false, reason: 'action_not_create' };
  }

  if (suggestion.risk !== 'low') {
    return { ok: false, reason: 'risk_not_low' };
  }

  const text = [
    suggestion.entryId,
    suggestion.type,
    suggestion.reason,
    suggestion.proposedContent,
  ].filter(Boolean).join('\n');

  for (const guard of LOW_RISK_GUARD_PATTERNS) {
    if (guard.patterns.some(pattern => pattern.test(text))) {
      return { ok: false, reason: guard.code };
    }
  }

  return { ok: true, reason: null };
}

function unique(items) {
  return [...new Set(items)];
}

function shorten(text, limit) {
  const value = String(text || '').replace(/\s+/g, ' ').trim();
  if (value.length <= limit) return value;
  return `${value.slice(0, limit - 1)}…`;
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function failure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

function die(message) {
  console.error(message);
  console.error(USAGE);
  process.exit(2);
}
