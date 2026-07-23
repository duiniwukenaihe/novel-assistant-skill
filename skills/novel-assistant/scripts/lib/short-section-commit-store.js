'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { acceptTransaction, inspectChapter, prepareTransaction } = require('./chapter-commit-store');
const { atomicWriteJson, atomicWriteText } = require('./workflow-state-store');

const SHORT_VOLUME = '短篇正文';

function commitAcceptedSection(projectRoot, options) {
  const root = path.resolve(projectRoot);
  const task = options.task || {};
  const sectionIndex = positiveInt(options.sectionIndex);
  if (!sectionIndex) throw failure('blocked_invalid_section', 'sectionIndex must be a positive integer');
  if (!String(task.workflow_id || '').trim() || !String(task.task_dir || '').trim()) {
    throw failure('blocked_task_snapshot_missing', 'durable task snapshot is required for section commit');
  }

  const canonicalRel = canonicalSectionPath(sectionIndex);
  const canonicalText = buildCanonicalSectionText({
    sectionIndex,
    title: options.title,
    text: options.text,
  });
  const contentHash = hashText(canonicalText);
  const existing = matchingAcceptedCommit(root, task.workflow_id, sectionIndex, canonicalRel, contentHash);
  if (existing) {
    return {
      status: 'accepted',
      already_accepted: true,
      commit_id: existing.commit_id,
      canonical_path: canonicalRel,
      canonical_sha256: contentHash,
      projection_status: 'projection_current',
    };
  }

  const pad = String(sectionIndex).padStart(3, '0');
  const artifactDirRel = `${task.task_dir}/artifacts/section-${pad}-commit`;
  const stagedRel = `${artifactDirRel}/canonical.md`;
  const manifestRel = `${artifactDirRel}/manifest.json`;
  atomicWriteText(resolveInside(root, stagedRel), canonicalText);
  atomicWriteJson(resolveInside(root, manifestRel), {
    schemaVersion: '1.0.0',
    workflow_id: String(task.workflow_id),
    volume: SHORT_VOLUME,
    chapter: sectionIndex,
    gates: {
      output_health: 'pass',
      prose_quality: 'pass',
      story_drift: 'pass',
    },
    artifacts: [{
      role: 'short_section_body',
      required: true,
      staged: stagedRel,
      target: canonicalRel,
    }],
    facts: buildSectionFacts({
      sectionIndex,
      canonicalPath: canonicalRel,
      title: options.title,
      projectTitle: options.projectTitle,
      metadata: options.metadata,
    }),
    promise_deltas: arrayValue((options.metadata || {}).promise_deltas),
  });

  const prepared = prepareTransaction(root, manifestRel);
  const accepted = acceptTransaction(root, prepared.transaction_id);
  return {
    ...accepted,
    canonical_path: canonicalRel,
    canonical_sha256: contentHash,
  };
}

function buildCanonicalSectionText({ sectionIndex, title, text }) {
  const body = stripLeadingSectionHeading(String(text || '')).trim();
  if (!body) throw failure('blocked_empty_section', 'accepted section body is empty');
  const cleanTitle = String(title || '').trim().replace(/^第\s*\d+\s*节[：:·.、\s-]*/u, '');
  const heading = `## 第${String(sectionIndex).padStart(3, '0')}节${cleanTitle ? ` ${cleanTitle}` : ''}`;
  return `${heading}\n\n${body}\n`;
}

function buildSectionFacts({ sectionIndex, canonicalPath, title, projectTitle, metadata }) {
  const value = metadata && typeof metadata === 'object' ? metadata : {};
  const evidence = [{ path: canonicalPath }];
  const scope = { book: 'current', section: sectionIndex };
  const facts = [];
  const subject = String(projectTitle || title || `第${sectionIndex}节`).trim();
  const summary = String(value.section_summary || '').trim();
  if (summary) facts.push(fact(subject, '本节发生', summary, evidence, scope));
  for (const name of stringArray(value.present_characters)) {
    facts.push(fact(name, `第${sectionIndex}节出场`, '已出场', evidence, scope));
  }
  for (const item of stringArray(value.revealed_information)) {
    facts.push(fact(subject, `第${sectionIndex}节揭示`, item, evidence, scope));
  }
  for (const [name, state] of Object.entries(objectValue(value.character_state))) {
    const serialized = typeof state === 'string' ? state.trim() : stableString(state);
    if (serialized) facts.push(fact(String(name), `第${sectionIndex}节状态`, serialized, evidence, scope));
  }
  for (const [relation, state] of Object.entries(objectValue(value.relationship_state))) {
    const serialized = typeof state === 'string' ? state.trim() : stableString(state);
    if (serialized) facts.push(fact(String(relation), `第${sectionIndex}节关系状态`, serialized, evidence, scope));
  }
  for (const [name, state] of Object.entries(objectValue(value.knowledge_state))) {
    const serialized = typeof state === 'string' ? state.trim() : stableString(state);
    if (serialized) facts.push(fact(String(name), `第${sectionIndex}节认知边界`, serialized, evidence, scope));
  }
  for (const [name, state] of Object.entries(objectValue(value.world_state))) {
    const serialized = typeof state === 'string' ? state.trim() : stableString(state);
    if (serialized) facts.push(fact(String(name), `第${sectionIndex}节世界状态`, serialized, evidence, scope));
  }
  for (const decision of stringArray(value.decisions)) {
    facts.push(fact(String(value.protagonist || subject), `第${sectionIndex}节做出选择`, decision, evidence, scope));
  }
  for (const link of arrayValue(value.causal_links)) {
    const cause = typeof link === 'string' ? '' : String((link || {}).cause || '').trim();
    const effect = typeof link === 'string' ? String(link).trim() : String((link || {}).effect || '').trim();
    if (effect) facts.push(fact(subject, cause ? `因${cause}` : `第${sectionIndex}节因果推进`, effect, evidence, scope));
  }
  const openHook = String(value.open_hook || '').trim();
  if (openHook) facts.push(fact(subject, '留下待续钩子', openHook, evidence, scope));
  return facts;
}

function fact(subject, predicate, object, evidence, scope) {
  return {
    subject,
    predicate,
    object,
    aliases: [],
    dependencies: [],
    evidence,
    scope,
    confidence: 1,
  };
}

function matchingAcceptedCommit(root, workflowId, sectionIndex, canonicalRel, contentHash) {
  const inspected = inspectChapter(root, SHORT_VOLUME, sectionIndex);
  const commit = inspected.latest_commit;
  if (!commit || String(commit.workflow_id || '') !== String(workflowId || '')) return null;
  const artifact = (commit.artifacts || []).find((item) => String(item.target || '') === canonicalRel);
  if (!artifact || normalizeHash(artifact.after_hash || artifact.content_hash) !== contentHash) return null;
  const canonicalFile = resolveInside(root, canonicalRel);
  if (!fs.existsSync(canonicalFile) || hashFile(canonicalFile) !== contentHash) return null;
  return commit;
}

function canonicalSectionPath(sectionIndex) {
  return `正文/第${String(sectionIndex).padStart(3, '0')}节.md`;
}

function stripLeadingSectionHeading(text) {
  return String(text || '').replace(/^\s*#{1,6}\s+第?\s*[0-9一二三四五六七八九十百零〇]+\s*[章节][^\n]*\n+/u, '');
}

function resolveInside(root, rel) {
  const file = path.resolve(root, String(rel || ''));
  if (file !== root && !file.startsWith(`${root}${path.sep}`)) throw failure('blocked_path_escape', `path escapes project root: ${rel}`);
  return file;
}

function hashText(text) {
  return crypto.createHash('sha256').update(String(text || ''), 'utf8').digest('hex');
}

function hashFile(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function normalizeHash(value) {
  return String(value || '').replace(/^sha256:/, '');
}

function positiveInt(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

function stringArray(value) {
  return Array.isArray(value) ? value.map(String).map(item => item.trim()).filter(Boolean).slice(0, 24) : [];
}

function objectValue(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function arrayValue(value) {
  return Array.isArray(value) ? value.slice(0, 24) : [];
}

function stableString(value) {
  if (!value || typeof value !== 'object') return String(value || '');
  return JSON.stringify(sortRecursively(value));
}

function sortRecursively(value) {
  if (Array.isArray(value)) return value.map(sortRecursively);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortRecursively(value[key])]));
}

function failure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

module.exports = {
  SHORT_VOLUME,
  buildCanonicalSectionText,
  buildSectionFacts,
  canonicalSectionPath,
  commitAcceptedSection,
};
