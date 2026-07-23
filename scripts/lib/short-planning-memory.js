'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { appendJsonl, atomicWriteJson } = require('./workflow-state-store');

const SHORT_WORKFLOWS = new Set(['short_write', 'short_startup', 'private_short_startup']);
const PLANNING_ASSET = /(^|\/)(素材卡|设定|小节大纲)\.md$/u;

function acceptShortPlanningDecision(projectRoot, task = {}, selection = {}) {
  if (!SHORT_WORKFLOWS.has(String(task.workflow_type || ''))) return { status: 'not_applicable', accepted_plan: null };
  const pending = task.pending_feedback && typeof task.pending_feedback === 'object' ? task.pending_feedback : {};
  const impact = task.short_feedback_impact && typeof task.short_feedback_impact === 'object' ? task.short_feedback_impact : {};
  if (!String(pending.feedback_id || '') || !['planning', 'structure'].includes(String(impact.impact_level || pending.impact_level_hint || ''))) {
    return { status: 'not_applicable', accepted_plan: null };
  }

  const root = path.resolve(projectRoot);
  const now = String(selection.accepted_at || new Date().toISOString());
  const items = normalizeItems(pending);
  const downstream = impact.downstream_impact && typeof impact.downstream_impact === 'object' ? impact.downstream_impact : {};
  const proposal = task.proposed_plan && String(task.proposed_plan.feedback_id || '') === String(pending.feedback_id || '')
    ? task.proposed_plan
    : null;
  const affectedSections = sectionList(impact.affected_sections).length
    ? sectionList(impact.affected_sections)
    : unique(items.flatMap(item => extractSections(item.text))).map(Number).sort((a, b) => a - b);
  const planningAssets = unique([
    ...(Array.isArray(impact.affected_assets) ? impact.affected_assets : []),
    ...(Array.isArray(pending.affected_assets_hint) ? pending.affected_assets_hint : []),
    ...extractPlanningAssets(downstream.replan),
  ].map(normalizeRelative).filter(item => PLANNING_ASSET.test(item)));
  const planId = `accepted-plan.${String(pending.feedback_id || digest(pending.text).slice(0, 16))}`;
  const artifactPath = `${String(task.task_dir || `追踪/workflow/tasks/${task.workflow_id || 'unknown-workflow'}`).replace(/\\/g, '/')}/artifacts/accepted-plan.json`;
  const acceptedPlan = {
    schema_version: '1.0.0',
    plan_id: planId,
    status: 'accepted_pending_projection',
    source_kind: 'assistant_proposal_confirmed_by_user',
    workflow_id: String(task.workflow_id || ''),
    feedback_id: String(pending.feedback_id || ''),
    proposal_id: String((proposal || {}).proposal_id || ''),
    summary: String((proposal || {}).summary || pending.text || '').trim(),
    execution_summary: String((proposal || {}).execution_summary || ''),
    requirements: Array.isArray((proposal || {}).requirements) && proposal.requirements.length
      ? proposal.requirements
      : items.map(item => ({
      requirement_id: String(item.feedback_id || ''),
      text: String(item.text || '').trim(),
      impact_level: String(item.impact_level_hint || ''),
      })),
    impact_level: String(impact.impact_level || pending.impact_level_hint || ''),
    affected_sections: affectedSections,
    projection_plan: {
      planning_assets: planningAssets,
      invalidate_briefs: normalizePaths(downstream.invalidate_briefs || downstream.invalidated_briefs || downstream.rebuild_briefs),
      recheck_prose: normalizePaths(downstream.recheck_prose || downstream.recheck_sections || downstream.prose_recheck),
      order: ['planning_assets', 'briefs', 'prose_recheck', 'memory_projection'],
    },
    acceptance: {
      kind: 'explicit_user_confirmation',
      selected_number: Number(selection.selected_number || 0) || null,
      selected_action_id: String(selection.action_id || ''),
      confirmation_input: String(selection.confirmation_input || selection.input || ''),
      confirmed_proposal_id: String((proposal || {}).proposal_id || ''),
      confirmed_summary: String((proposal || {}).summary || pending.text || '').trim(),
      accepted_at: now,
    },
    projection_status: 'pending',
    accepted_at: now,
    projected_at: '',
  };
  task.accepted_plan = acceptedPlan;
  if (proposal) task.proposed_plan = { ...proposal, status: 'accepted', accepted_plan_id: planId, accepted_at: now };
  task.accepted_plan_path = artifactPath;
  atomicWriteJson(path.join(root, artifactPath), acceptedPlan);
  appendJsonl(path.join(root, String(task.task_dir || ''), 'decision-journal.jsonl'), {
    event_type: 'short_plan_accepted',
    ...acceptedPlan,
  });
  return { status: 'short_plan_accepted', accepted_plan: acceptedPlan, accepted_plan_path: artifactPath };
}

function projectAcceptedShortPlanningFeedback(projectRoot, task = {}, result = {}) {
  if (!SHORT_WORKFLOWS.has(String(task.workflow_type || ''))
    || String(result.stage_id || '') !== 'feedback_apply_patch'
    || String(result.step_status || '') !== 'completed') {
    return { status: 'not_applicable', projected: 0 };
  }

  const pending = task.pending_feedback && typeof task.pending_feedback === 'object'
    ? task.pending_feedback
    : {};
  const impactLevel = String(result.impact_level || result.feedback_impact_level || ((task.short_feedback_impact || {}).impact_level) || '');
  if (!['planning', 'structure'].includes(impactLevel) || !String(pending.feedback_id || '')) {
    return { status: 'not_applicable', projected: 0 };
  }

  const root = path.resolve(projectRoot);
  const changed = unique([
    ...(Array.isArray(result.changed_assets) ? result.changed_assets : []),
    ...(Array.isArray(result.changed_files) ? result.changed_files : []),
  ].map(normalizeRelative).filter(item => PLANNING_ASSET.test(item)));
  const sourceRefs = changed.map(relative => sourceRef(root, relative)).filter(Boolean);
  if (!sourceRefs.length) {
    return {
      status: 'blocked_planning_memory_evidence_missing',
      projected: 0,
      message: '规划反馈已声明完成，但没有可核验的设定或小节大纲变更。',
    };
  }

  const acceptedPlan = task.accepted_plan
    && String(task.accepted_plan.feedback_id || '') === String(pending.feedback_id || '')
    ? task.accepted_plan
    : null;
  const items = acceptedPlanningItems(acceptedPlan, pending);
  const affectedSections = sectionList(result.affected_sections).length
    ? sectionList(result.affected_sections)
    : unique(items.flatMap(item => extractSections(item.text))).map(Number).sort((a, b) => a - b);
  const wholeStory = /(?:全篇|整篇|全文|通篇|结局|终局)/u.test(`${String(pending.scope_snapshot || '')}\n${String((acceptedPlan || {}).summary || '')}\n${String(pending.text || '')}`);
  const memoryFile = path.join(root, '追踪', 'memory', 'planning-constraints.jsonl');
  const existing = latestBy(readJsonl(memoryFile), row => row.constraint_id);
  const now = new Date().toISOString();
  let projected = 0;

  for (const item of items) {
    const itemId = String(item.requirement_id || item.feedback_id || digest(item.text).slice(0, 16));
    const constraintId = `constraint.${itemId}`;
    const row = {
      schema_version: '1.0.0',
      constraint_id: constraintId,
      type: 'planning_constraint',
      content: String(item.text || '').trim(),
      status: 'active',
      source_kind: acceptedPlan ? 'user_confirmed_plan' : 'legacy_user_feedback',
      scope: wholeStory
        ? { book: 'current', whole_story: true }
        : affectedSections.length ? { book: 'current', sections: affectedSections } : { book: 'current' },
      affected_sections: affectedSections,
      affected_assets: changed,
      source_refs: sourceRefs,
      valid_from: now,
      valid_to: null,
      provenance: {
        workflow_id: String(task.workflow_id || ''),
        task_family_id: String(task.task_family_id || ''),
        branch_id: String(task.branch_id || task.workflow_id || ''),
        stage_id: 'feedback_apply_patch',
        stage_attempt_id: String((((task || {}).stage_execution || {}).stage_attempt_id) || ''),
        feedback_id: String(pending.feedback_id || ''),
        proposal_id: String((acceptedPlan || {}).proposal_id || ''),
        plan_id: String((acceptedPlan || {}).plan_id || ''),
        result_packet_path: String(result.result_packet_path || ''),
        acceptance_status: 'accepted',
      },
      created_at: now,
    };
    const previous = existing.get(constraintId);
    if (previous && digest(stableComparable(previous)) === digest(stableComparable(row))) continue;
    appendJsonl(memoryFile, row);
    existing.set(constraintId, row);
    projected += 1;
  }

  if (acceptedPlan) {
    task.accepted_plan = {
      ...task.accepted_plan,
      status: 'projected_to_canonical_memory',
      projection_status: 'completed',
      projected_assets: changed,
      source_refs: sourceRefs,
      projected_at: now,
    };
    if (String(task.accepted_plan_path || '')) atomicWriteJson(path.join(root, task.accepted_plan_path), task.accepted_plan);
    appendJsonl(path.join(root, String(task.task_dir || ''), 'decision-journal.jsonl'), {
      event_type: 'short_plan_projected',
      plan_id: String(task.accepted_plan.plan_id || ''),
      feedback_id: String(pending.feedback_id || ''),
      projected_assets: changed,
      source_refs: sourceRefs,
      projected_at: now,
    });
  }

  return {
    status: projected ? 'planning_constraints_projected' : 'current',
    projected,
    constraint_ids: items.map(item => `constraint.${String(item.requirement_id || item.feedback_id || digest(item.text).slice(0, 16))}`),
    memory_file: '追踪/memory/planning-constraints.jsonl',
  };
}

function acceptedPlanningItems(acceptedPlan, pending) {
  if (acceptedPlan && Array.isArray(acceptedPlan.requirements) && acceptedPlan.requirements.length) {
    return acceptedPlan.requirements
      .map((item, index) => ({
        requirement_id: String((item || {}).requirement_id || `${acceptedPlan.plan_id || 'accepted-plan'}.requirement-${index + 1}`),
        text: String((item || {}).text || (item || {}).content || '').trim(),
        impact_level_hint: String((item || {}).impact_level || acceptedPlan.impact_level || ''),
      }))
      .filter(item => item.text);
  }
  if (acceptedPlan && String(acceptedPlan.summary || '').trim()) {
    return [{
      requirement_id: `${String(acceptedPlan.plan_id || 'accepted-plan')}.summary`,
      text: String(acceptedPlan.summary || '').trim(),
      impact_level_hint: String(acceptedPlan.impact_level || ''),
    }];
  }
  return normalizeItems(pending);
}

function normalizeItems(pending) {
  if (Array.isArray(pending.items) && pending.items.length) return pending.items;
  return String(pending.text || '').trim()
    ? [{ feedback_id: String(pending.feedback_id || ''), text: String(pending.text || '').trim() }]
    : [];
}

function sourceRef(root, relative) {
  const file = path.resolve(root, relative);
  if (!file.startsWith(`${root}${path.sep}`) || !fs.existsSync(file) || !fs.statSync(file).isFile()) return null;
  return { path: relative, hash: `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}` };
}

function extractSections(text) {
  return [...String(text || '').matchAll(/第\s*0*(\d+)\s*节/gu)].map(match => Number(match[1])).filter(Number.isInteger);
}

function sectionList(value) {
  return unique((Array.isArray(value) ? value : []).map(Number).filter(item => Number.isInteger(item) && item > 0));
}

function normalizeRelative(value) {
  const normalized = String(value || '').trim().replace(/\\/g, '/').replace(/^\.\//, '');
  if (!normalized || normalized.startsWith('/') || normalized.split('/').includes('..')) return '';
  return normalized;
}

function extractPlanningAssets(value) {
  return (Array.isArray(value) ? value : []).flatMap(item => {
    const text = String(item || '');
    return [...text.matchAll(/(?:^|[\s，,；;])((?:素材卡|设定|小节大纲)\.md)/gu)].map(match => match[1]);
  });
}

function normalizePaths(value) {
  return unique((Array.isArray(value) ? value : []).map(item => String(item || '').trim()).filter(Boolean));
}

function readJsonl(file) {
  try {
    return fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
  } catch (_) {
    return [];
  }
}

function latestBy(rows, keyFn) {
  const latest = new Map();
  for (const row of rows) {
    const key = String(keyFn(row) || '');
    if (key) latest.set(key, row);
  }
  return latest;
}

function stableComparable(row) {
  return JSON.stringify({
    constraint_id: row.constraint_id,
    content: row.content,
    scope: row.scope,
    affected_sections: row.affected_sections,
    affected_assets: row.affected_assets,
    source_refs: row.source_refs,
    feedback_id: ((row.provenance || {}).feedback_id || ''),
    proposal_id: ((row.provenance || {}).proposal_id || ''),
    plan_id: ((row.provenance || {}).plan_id || ''),
  });
}

function digest(value) {
  return crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex');
}

function unique(values) {
  return [...new Set(values)];
}

module.exports = { acceptShortPlanningDecision, projectAcceptedShortPlanningFeedback };
