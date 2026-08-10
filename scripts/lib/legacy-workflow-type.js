'use strict';

// Legacy pointers have no schema authority of their own. We may only create a
// successor when their declared type is an exact member of this compatibility
// table. In particular, creative files, a free-form task label, and an old
// stage name are not evidence from which a workflow type can be inferred.
const LEGACY_TYPE_MAP = Object.freeze({
  short_write: 'short_write',
  private_short_startup: 'short_write',
  long_write: 'long_write',
  long_startup: 'long_write',
  long_daily_write: 'long_write',
  review_repair: 'review_repair',
  outline_backfill: 'long_write',
  'legacy continuity repair': 'long_write',
});

const TYPE_FIELDS = Object.freeze(['workflow_type', 'task_type', 'type']);

function classifyLegacyWorkflow(task = {}) {
  if (!task || typeof task !== 'object' || Array.isArray(task)) {
    return unsupported('legacy_task_not_object');
  }
  const declared = TYPE_FIELDS
    .map((field) => ({ field, value: normalizeType(task[field]) }))
    .filter((item) => item.value);
  if (!declared.length) return unsupported('legacy_type_missing');

  const mapped = declared.map((item) => ({ ...item, workflow_type: LEGACY_TYPE_MAP[item.value] || '' }));
  if (mapped.some((item) => !item.workflow_type)) return unsupported('legacy_type_unrecognized');
  const types = [...new Set(mapped.map((item) => item.workflow_type))];
  if (types.length !== 1) return unsupported('legacy_type_conflict');
  return {
    status: 'supported',
    workflow_type: types[0],
    reason: 'exact_legacy_type',
  };
}

function normalizeType(value) {
  return String(value || '').trim().toLowerCase();
}

function unsupported(reason) {
  return { status: 'unsupported', workflow_type: '', reason };
}

module.exports = {
  LEGACY_TYPE_MAP,
  TYPE_FIELDS,
  classifyLegacyWorkflow,
};
