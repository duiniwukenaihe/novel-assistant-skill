'use strict';

const fs = require('fs');
const path = require('path');

const SHORT_WORKFLOWS = new Set(['short_write', 'short_startup', 'private_short_startup']);

function initializeShortFeedbackRevisionQueue(task = {}, result = {}, policy = {}) {
  if (SHORT_WORKFLOWS.has(String(task.workflow_type || ''))
    && String(result.stage_id || '') === 'short_structure_impact_audit'
    && String(result.step_status || '') === 'completed') {
    return mergeStructureImpactIntoRevisionQueue(task, result);
  }
  if (!SHORT_WORKFLOWS.has(String(task.workflow_type || ''))
    || String(result.stage_id || '') !== 'feedback_apply_patch'
    || String(result.step_status || '') !== 'completed'
    || !['current_brief', 'planning', 'structure'].includes(String(policy.impact_level || ''))) {
    return { status: 'not_applicable', queue: null };
  }
  const affectedSections = sectionList(policy.affected_sections).length
    ? sectionList(policy.affected_sections)
    : sectionList(result.affected_sections);
  if (!affectedSections.length) {
    return {
      status: 'blocked_feedback_revision_scope_missing',
      queue: null,
      message: '反馈已使 Brief 或正文失效，但没有明确受影响小节，不能安全进入改稿。',
    };
  }
  const downstream = result.downstream_impact && typeof result.downstream_impact === 'object'
    ? result.downstream_impact
    : {};
  const invalidatedBriefs = new Set(sectionList(
    downstream.invalidate_briefs || downstream.invalidated_briefs || downstream.rebuild_briefs || affectedSections,
  ));
  const recheckProse = new Set(sectionList(
    downstream.recheck_prose || downstream.recheck_sections || downstream.prose_recheck || affectedSections,
  ));
  const now = new Date().toISOString();
  const feedbackId = String(((task || {}).pending_feedback || {}).feedback_id || result.feedback_id || '');
  const previous = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  const affectedSet = new Set(affectedSections);
  const previousItems = new Map((Array.isArray((previous || {}).items) ? previous.items : [])
    .map(item => [Number((item || {}).section_index || 0), item]));
  const queueSections = sectionList([
    ...previousItems.keys(),
    ...affectedSections,
  ]);
  const items = queueSections.map(sectionIndex => affectedSet.has(sectionIndex)
    ? {
      section_index: sectionIndex,
      status: 'pending',
      brief_status: invalidatedBriefs.has(sectionIndex) ? 'invalidated' : 'rebuild_required',
      prose_status: recheckProse.has(sectionIndex) ? 'pending_recheck' : 'pending_reacceptance',
      accepted_commit_id: '',
      completed_at: '',
    }
    : previousItems.get(sectionIndex));
  const current = items.find(item => String((item || {}).status || '') !== 'accepted');
  const queue = {
    ...(previous || {}),
    schema_version: '1.0.0',
    queue_id: String((previous || {}).queue_id || `revision.${feedbackId || String(Date.now())}`),
    feedback_id: feedbackId,
    source_stage: 'feedback_apply_patch',
    status: current ? 'running' : 'completed',
    impact_level: String(policy.impact_level || ''),
    affected_sections: queueSections,
    current_section_index: current ? Number(current.section_index) : null,
    completed_sections: sectionList(items.filter(item => String((item || {}).status || '') === 'accepted').map(item => item.section_index)),
    groups: buildRevisionGroups(
      queueSections,
      policy.revision_groups || result.revision_groups || (previous || {}).groups,
    ),
    items,
    checkpoints: [
      ...(Array.isArray((previous || {}).checkpoints) ? previous.checkpoints : []),
      {
        event: previous ? 'feedback_merged' : 'queue_created',
        feedback_id: feedbackId,
        section_index: current ? Number(current.section_index) : null,
        affected_sections: affectedSections,
        at: now,
      },
    ].slice(-50),
    created_at: String((previous || {}).created_at || now),
    updated_at: now,
    completed_at: current ? '' : now,
    revision_round: Number((previous || {}).revision_round || 0) + 1,
    interruption: null,
  };
  syncRevisionGroupProgress(queue);
  task.feedback_revision_queue = queue;
  if (queue.current_section_index) task.scope = `第${queue.current_section_index}节`;
  return { status: previous ? 'feedback_revision_queue_merged' : 'feedback_revision_queue_created', queue };
}

function mergeStructureImpactIntoRevisionQueue(task, result) {
  const affectedSections = sectionList(result.affected_sections);
  if (!affectedSections.length) return { status: 'not_applicable', queue: task.feedback_revision_queue || null };
  const previous = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  const previousItems = new Map((Array.isArray((previous || {}).items) ? previous.items : [])
    .map(item => [Number((item || {}).section_index || 0), item]));
  const allSections = sectionList([...(previous ? previous.affected_sections || [] : []), ...affectedSections]);
  const now = new Date().toISOString();
  const items = allSections.map(sectionIndex => previousItems.get(sectionIndex) || {
    section_index: sectionIndex,
    status: 'pending',
    brief_status: 'invalidated',
    prose_status: 'pending_recheck',
    accepted_commit_id: '',
    completed_at: '',
  });
  const current = items.find(item => String(item.status || '') !== 'accepted');
  const queue = {
    ...(previous || {}),
    schema_version: '1.0.0',
    queue_id: String((previous || {}).queue_id || `revision.structure-impact.${Date.now()}`),
    source_stage: String((previous || {}).source_stage || 'short_structure_impact_audit'),
    updated_by_stage: 'short_structure_impact_audit',
    status: current ? 'running' : 'completed',
    affected_sections: allSections,
    current_section_index: current ? Number(current.section_index) : null,
    completed_sections: sectionList(items.filter(item => String(item.status || '') === 'accepted').map(item => item.section_index)),
    groups: buildRevisionGroups(
      allSections,
      result.revision_groups || (previous || {}).groups,
    ),
    items,
    created_at: String((previous || {}).created_at || now),
    updated_at: now,
    completed_at: current ? '' : String((previous || {}).completed_at || now),
    checkpoints: [
      ...(Array.isArray((previous || {}).checkpoints) ? previous.checkpoints : []),
      {
        event: previous ? 'structure_impact_merged' : 'queue_created',
        section_index: current ? Number(current.section_index) : null,
        affected_sections: affectedSections,
        at: now,
      },
    ].slice(-50),
  };
  task.feedback_revision_queue = queue;
  syncRevisionGroupProgress(queue);
  if (current) task.scope = `第${current.section_index}节`;
  return { status: previous ? 'feedback_revision_queue_expanded' : 'feedback_revision_queue_created', queue };
}

function reconcileShortRevisionQueueWithTitleLock(projectRoot, task = {}) {
  if (!SHORT_WORKFLOWS.has(String(task.workflow_type || ''))) return { status: 'not_applicable', queue: null };
  const root = path.resolve(projectRoot || '');
  const titleLock = readJson(path.join(root, '追踪/private-short-extension/section-title-lock.json')) || {};
  const projectState = readJson(path.join(root, '追踪/private-short-extension/project-state.json')) || {};
  if (String(titleLock.status || '') !== 'confirmed') return { status: 'not_applicable', queue: task.feedback_revision_queue || null };
  const acceptedTitles = new Map((Array.isArray(projectState.accepted_sections) ? projectState.accepted_sections : [])
    .map(item => [Number((item || {}).section_index || 0), normalizeTitle((item || {}).title)]));
  const affectedSections = (Array.isArray(titleLock.sections) ? titleLock.sections : [])
    .filter(item => {
      const index = Number((item || {}).section_index || 0);
      return Number.isInteger(index) && index > 0 && acceptedTitles.has(index)
        && normalizeTitle((item || {}).title) !== acceptedTitles.get(index);
    })
    .map(item => Number(item.section_index));
  if (!affectedSections.length) return { status: 'title_lock_revision_queue_current', queue: task.feedback_revision_queue || null };
  return mergeStructureImpactIntoRevisionQueue(task, {
    stage_id: 'short_structure_impact_audit',
    step_status: 'completed',
    affected_sections: affectedSections,
  });
}

function activeShortFeedbackRevision(task = {}) {
  const queue = task.feedback_revision_queue && typeof task.feedback_revision_queue === 'object'
    ? task.feedback_revision_queue
    : null;
  if (!queue || String(queue.status || '') !== 'running') return null;
  const current = Number(queue.current_section_index || 0);
  return Number.isInteger(current) && current > 0 ? queue : null;
}

function currentShortFeedbackRevisionSection(task = {}) {
  const queue = activeShortFeedbackRevision(task);
  return queue ? Number(queue.current_section_index) : 0;
}

function acceptShortFeedbackRevisionSection(task = {}, sectionIndex, metadata = {}) {
  const queue = activeShortFeedbackRevision(task);
  if (!queue) return { status: 'not_applicable', queue: null };
  const section = Number(sectionIndex || 0);
  if (section !== Number(queue.current_section_index || 0)) {
    return {
      status: 'blocked_feedback_revision_section_mismatch',
      queue,
      expected_section: Number(queue.current_section_index || 0),
      actual_section: section,
    };
  }
  const now = new Date().toISOString();
  queue.items = (Array.isArray(queue.items) ? queue.items : []).map(item => Number(item.section_index) === section
    ? {
      ...item,
      status: 'accepted',
      brief_status: 'rebuilt_and_used',
      prose_status: 'rechecked_and_accepted',
      accepted_commit_id: String(metadata.section_commit_id || ''),
      completed_at: now,
    }
    : item);
  queue.completed_sections = sectionList([
    ...(Array.isArray(queue.completed_sections) ? queue.completed_sections : []),
    section,
  ]);
  const next = queue.items.find(item => String(item.status || '') !== 'accepted');
  queue.current_section_index = next ? Number(next.section_index) : null;
  queue.status = next ? 'running' : 'completed';
  queue.updated_at = now;
  queue.completed_at = next ? '' : now;
  queue.interruption = null;
  queue.checkpoints = [
    ...(Array.isArray(queue.checkpoints) ? queue.checkpoints : []),
    {
      event: 'section_accepted',
      section_index: section,
      section_commit_id: String(metadata.section_commit_id || ''),
      next_section_index: next ? Number(next.section_index) : null,
      at: now,
    },
  ].slice(-50);
  syncRevisionGroupProgress(queue);
  task.feedback_revision_queue = queue;
  if (next) task.scope = `第${next.section_index}节`;
  return {
    status: next ? 'feedback_revision_section_accepted' : 'feedback_revision_queue_completed',
    queue,
    accepted_section: section,
    next_section: next ? Number(next.section_index) : null,
  };
}

function buildRevisionGroups(affectedSections, requestedGroups) {
  const affected = sectionList(affectedSections);
  const requested = Array.isArray(requestedGroups) ? requestedGroups : [];
  const normalized = requested.map((group, index) => {
    const sections = sectionList((group || {}).section_indices || (group || {}).sections || (group || {}).scope);
    return {
      group_id: String((group || {}).group_id || `phase-${String(index + 1).padStart(2, '0')}`),
      order: index + 1,
      section_indices: sections,
      goal: String((group || {}).goal || (group || {}).description || '').trim(),
      completion_rule: String((group || {}).completion_rule || '组内小节逐节完成 Brief 重建、正文复检并采用').trim(),
      status: 'pending',
      completed_sections: [],
      current_section_index: sections[0] || null,
    };
  }).filter(group => group.section_indices.length > 0);
  const covered = sectionList(normalized.flatMap(group => group.section_indices));
  if (normalized.length && covered.length === affected.length && covered.every((value, index) => value === affected[index])) {
    return normalized;
  }
  return contiguousSectionGroups(affected).map((sections, index) => ({
    group_id: `phase-${String(index + 1).padStart(2, '0')}`,
    order: index + 1,
    section_indices: sections,
    goal: '',
    completion_rule: '组内小节逐节完成 Brief 重建、正文复检并采用',
    status: 'pending',
    completed_sections: [],
    current_section_index: sections[0] || null,
  }));
}

function contiguousSectionGroups(sections) {
  return sectionList(sections).reduce((groups, sectionIndex) => {
    const current = groups[groups.length - 1];
    if (!current || sectionIndex !== current[current.length - 1] + 1) groups.push([sectionIndex]);
    else current.push(sectionIndex);
    return groups;
  }, []);
}

function syncRevisionGroupProgress(queue) {
  const items = Array.isArray((queue || {}).items) ? queue.items : [];
  const itemStatus = new Map(items.map(item => [Number((item || {}).section_index || 0), String((item || {}).status || 'pending')]));
  const currentSection = Number((queue || {}).current_section_index || 0);
  queue.groups = buildRevisionGroups(
    sectionList(items.map(item => item.section_index)),
    (queue || {}).groups,
  ).map(group => {
    const completed = group.section_indices.filter(sectionIndex => itemStatus.get(sectionIndex) === 'accepted');
    const pending = group.section_indices.filter(sectionIndex => itemStatus.get(sectionIndex) !== 'accepted');
    return {
      ...group,
      completed_sections: completed,
      current_section_index: group.section_indices.includes(currentSection) ? currentSection : (pending[0] || null),
      status: pending.length === 0 ? 'completed' : group.section_indices.includes(currentSection) ? 'running' : 'pending',
    };
  });
  return queue;
}

function sectionList(value) {
  return Array.isArray(value)
    ? [...new Set(value.map(sectionNumber).filter(item => Number.isInteger(item) && item > 0))].sort((a, b) => a - b)
    : [];
}

function sectionNumber(value) {
  const direct = Number(value);
  if (Number.isInteger(direct) && direct > 0) return direct;
  const text = String(value || '');
  const chinese = /第\s*0*(\d+)\s*节/u.exec(text);
  if (chinese) return Number(chinese[1]);
  const slug = /section[-_]?0*(\d+)/iu.exec(text);
  return slug ? Number(slug[1]) : 0;
}

function normalizeTitle(value) {
  return String(value || '').trim().replace(/[“”]/gu, '"').replace(/\s+/gu, ' ');
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}

module.exports = {
  initializeShortFeedbackRevisionQueue,
  activeShortFeedbackRevision,
  currentShortFeedbackRevisionSection,
  acceptShortFeedbackRevisionSection,
  reconcileShortRevisionQueueWithTitleLock,
  buildRevisionGroups,
  syncRevisionGroupProgress,
};
