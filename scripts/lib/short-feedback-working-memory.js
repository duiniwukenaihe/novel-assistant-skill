'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { appendJsonl } = require('./workflow-state-store');

function enqueueShortFeedback(projectRoot, task, input, options = {}) {
  const root = path.resolve(projectRoot);
  const text = String(input || '').trim();
  if (!text) return { status: 'ignored_empty_feedback', pending_feedback: task.pending_feedback || null };

  const now = String(options.receivedAt || new Date().toISOString());
  const previous = normalizePendingItems(task.pending_feedback);
  const contentHash = digest(text);
  let items = previous.items;
  const duplicate = items.find(item => item.content_hash === contentHash);
  if (!duplicate) {
    const impact = inferFeedbackImpact(text, options.classification);
    const item = {
      feedback_id: `feedback-${contentHash.slice(0, 16)}`,
      content_hash: contentHash,
      text,
      classification: String(options.classification || 'current_artifact_feedback'),
      impact_level_hint: impact.impact_level,
      affected_assets_hint: impact.affected_assets,
      section_index: positiveInteger(options.sectionIndex),
      scope_snapshot: String(options.scopeSnapshot || task.scope || ''),
      source_kind: String(options.sourceKind || 'user_message'),
      status: 'pending',
      received_at: now,
    };
    items = [...items, item];
    appendJsonl(feedbackInboxFile(root, task), {
      event_type: 'feedback_received',
      workflow_id: String(task.workflow_id || ''),
      ...item,
    });
  }

  const pending = buildPendingFeedback(task, items, previous, options);
  task.pending_feedback = pending;
  return { status: duplicate ? 'duplicate_feedback_retained' : 'feedback_queued', pending_feedback: pending };
}

function discardShortFeedbackItem(projectRoot, task, feedbackId, options = {}) {
  const root = path.resolve(projectRoot);
  const targetId = String(feedbackId || '').trim();
  const previous = normalizePendingItems(task.pending_feedback);
  const discarded = previous.items.find(item => String(item.feedback_id || '') === targetId);
  if (!discarded) return { status: 'feedback_item_not_found', pending_feedback: task.pending_feedback || null };

  const now = String(options.discardedAt || new Date().toISOString());
  const items = previous.items.filter(item => String(item.feedback_id || '') !== targetId);
  appendJsonl(feedbackInboxFile(root, task), {
    event_type: 'feedback_discarded',
    workflow_id: String(task.workflow_id || ''),
    feedback_id: targetId,
    content_hash: String(discarded.content_hash || ''),
    reason: String(options.reason || 'host_continuation_misclassified_as_feedback'),
    discarded_at: now,
  });

  task.pending_feedback = items.length > 0
    ? buildPendingFeedback(task, items, previous, {
      scopeSnapshot: String((task.pending_feedback || {}).scope_snapshot || task.scope || ''),
      previousStage: previous.previous_stage,
    })
    : null;
  return {
    status: 'feedback_item_discarded',
    discarded_feedback_id: targetId,
    pending_feedback: task.pending_feedback,
  };
}

function recordShortFeedbackReclassification(projectRoot, task, feedbackId, options = {}) {
  const root = path.resolve(projectRoot);
  const targetId = String(feedbackId || '').trim();
  if (!targetId) return { status: 'feedback_item_not_found' };
  const inboxFile = feedbackInboxFile(root, task);
  const preservedByPlanId = String(options.preservedByPlanId || '');
  const rows = readJsonl(inboxFile);
  const sourceExists = rows.some(row => row
    && String(row.feedback_id || '') === targetId
    && ['feedback_received', 'feedback_discarded', 'feedback_resolved'].includes(String(row.event_type || '')));
  if (!sourceExists) return { status: 'feedback_item_not_found' };
  const existing = rows.find(row => row
    && row.event_type === 'feedback_reclassified'
    && String(row.feedback_id || '') === targetId
    && String(row.preserved_by_plan_id || '') === preservedByPlanId);
  if (existing) return { status: 'feedback_item_reclassification_current', audit_event: existing };
  const now = String(options.recordedAt || new Date().toISOString());
  const row = {
    event_type: 'feedback_reclassified',
    workflow_id: String(task.workflow_id || ''),
    feedback_id: targetId,
    classification: String(options.classification || 'accepted_plan_execution_command'),
    preserved_by_plan_id: preservedByPlanId,
    note: String(options.note || '该文本是对已确认助手方案的采纳/执行指令，不是新的作品反馈。'),
    recorded_at: now,
  };
  appendJsonl(inboxFile, row);
  return { status: 'feedback_item_reclassified', audit_event: row };
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .flatMap(line => {
      try { return [JSON.parse(line)]; } catch (_) { return []; }
    });
}

function buildPendingFeedback(task, items, previous, options = {}) {
  const scopeSnapshot = wholeStoryFeedback(items) ? '全篇' : String(options.scopeSnapshot || task.scope || '');
  const batchHash = digest(items.map(item => `${item.feedback_id}:${item.content_hash}`).join('\n'));
  return {
    feedback_id: `feedback-batch-${batchHash.slice(0, 16)}`,
    batch_id: `feedback-batch-${batchHash.slice(0, 16)}`,
    text: items.map((item, index) => `[意见 ${index + 1}] ${item.text}`).join('\n\n'),
    items,
    item_count: items.length,
    classification: strongestClassification(items),
    impact_hint: strongestClassification(items) === 'scope_change' ? 'structure' : 'analyze',
    impact_level_hint: strongestImpact(items),
    affected_assets_hint: unique(items.flatMap(item => item.affected_assets_hint || [])),
    previous_stage: previous.previous_stage || String(options.previousStage || task.current_stage || ''),
    section_index: scopeSnapshot === '全篇' ? null : positiveInteger(options.sectionIndex) || previous.section_index || null,
    scope_snapshot: scopeSnapshot,
    feedback_inbox_path: relativeInboxPath(task),
    first_received_at: previous.first_received_at || items[0].received_at,
    received_at: items[items.length - 1].received_at,
    status: 'pending',
  };
}

function resolveShortFeedback(projectRoot, task, result = {}) {
  const pending = task.pending_feedback || {};
  if (!String(pending.feedback_id || '')) return { status: 'not_applicable' };
  appendJsonl(feedbackInboxFile(path.resolve(projectRoot), task), {
    event_type: 'feedback_resolved',
    workflow_id: String(task.workflow_id || ''),
    feedback_id: String(pending.feedback_id || ''),
    item_ids: normalizePendingItems(pending).items.map(item => item.feedback_id),
    result_packet_path: String(result.result_packet_path || ''),
    stage_id: String(result.stage_id || ''),
    resolved_at: new Date().toISOString(),
  });
  return { status: 'feedback_resolved', feedback_id: String(pending.feedback_id || '') };
}

function inferFeedbackImpact(text, classification = '') {
  const value = String(text || '');
  if (/(增加|删除|合并|拆分|重排|扩容|缩容).{0,8}(节|小节)|节数|章节数量/u.test(value)) {
    return { impact_level: 'structure', affected_assets: ['设定.md', '小节大纲.md'] };
  }
  if (/(结局|终局|主题|核心承诺|主线|反转|人物关系|人物功能|动机|法律|召回|退款|停产|治理|全篇|整篇|全文|通篇|后半段|前因后果|逻辑)/u.test(value)
    || String(classification) === 'scope_change') {
    return { impact_level: 'planning', affected_assets: ['设定.md', '小节大纲.md'] };
  }
  if (/第\s*0*\d+\s*节/u.test(value)) {
    return { impact_level: 'current_brief', affected_assets: ['写作Brief', '正文'] };
  }
  return { impact_level: 'expression_only', affected_assets: ['正文'] };
}

function normalizePendingItems(pending) {
  if (!pending || typeof pending !== 'object') return { items: [], previous_stage: '', section_index: null, first_received_at: '' };
  const source = Array.isArray(pending.items) && pending.items.length
    ? pending.items
    : String(pending.text || '').trim()
      ? [{
        feedback_id: String(pending.feedback_id || `feedback-${digest(pending.text).slice(0, 16)}`),
        content_hash: digest(pending.text),
        text: String(pending.text || '').trim(),
        classification: String(pending.classification || 'current_artifact_feedback'),
        impact_level_hint: String(pending.impact_hint || inferFeedbackImpact(pending.text).impact_level),
        affected_assets_hint: Array.isArray(pending.affected_assets_hint) ? pending.affected_assets_hint : inferFeedbackImpact(pending.text).affected_assets,
        section_index: positiveInteger(pending.section_index),
        scope_snapshot: String(pending.scope_snapshot || ''),
        source_kind: 'user_message',
        status: 'pending',
        received_at: String(pending.received_at || new Date(0).toISOString()),
      }]
      : [];
  return {
    items: source.map(item => ({ ...item, content_hash: String(item.content_hash || digest(item.text)) })),
    previous_stage: String(pending.previous_stage || ''),
    section_index: positiveInteger(pending.section_index),
    first_received_at: String(pending.first_received_at || pending.received_at || ''),
  };
}

function strongestImpact(items) {
  const order = ['expression_only', 'current_brief', 'planning', 'structure'];
  return items.reduce((strongest, item) => order.indexOf(item.impact_level_hint) > order.indexOf(strongest) ? item.impact_level_hint : strongest, 'expression_only');
}

function strongestClassification(items) {
  return items.some(item => item.classification === 'scope_change') ? 'scope_change' : 'current_artifact_feedback';
}

function wholeStoryFeedback(items) {
  return items.some(item => /(?:全篇|整篇|全文|通篇|后半段|结局|终局)/u.test(`${item.scope_snapshot || ''}\n${item.text || ''}`));
}

function feedbackInboxFile(root, task) {
  const file = path.resolve(root, relativeInboxPath(task));
  if (file !== root && !file.startsWith(`${root}${path.sep}`)) throw new Error('feedback inbox escapes project root');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  return file;
}

function relativeInboxPath(task) {
  const taskDir = String(task.task_dir || `追踪/workflow/tasks/${task.workflow_id || 'unknown'}`).replace(/\\/g, '/').replace(/^\.\//, '');
  return `${taskDir}/feedback-inbox.jsonl`;
}

function positiveInteger(value) {
  const number = Number(value || 0);
  return Number.isInteger(number) && number > 0 ? number : null;
}

function digest(value) {
  return crypto.createHash('sha256').update(String(value || '').trim(), 'utf8').digest('hex');
}

function unique(values) {
  return [...new Set(values.map(String).filter(Boolean))];
}

module.exports = {
  discardShortFeedbackItem,
  enqueueShortFeedback,
  inferFeedbackImpact,
  recordShortFeedbackReclassification,
  resolveShortFeedback,
};
