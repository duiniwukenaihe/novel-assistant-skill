'use strict';

// Task 3 internal store: the only writer to a V3 durable task.json.
//
// This module wraps the existing project-wide locking and atomic task
// authority (scripts/lib/workflow-task-authority.js) so the V3 engine can
// commit a single mutation under the project lock and then reread the
// committed snapshot. It is deliberately NOT exported from the public CLI;
// only scripts/lib/workflow-v3/engine.js imports it.

const path = require('path');

const authority = require('../workflow-task-authority');
const stateStore = require('../workflow-state-store');
const { SHORT_ENTRY_STAGE } = require('./short-graph');

const ENGINE_VERSION = 3;
const TASK_SCHEMA_VERSION = 3;
const WORKFLOW_CONTRACT_VERSION = 3;
const OWNER = 'workflow-v3-engine';

// Single assertion that a durable snapshot was produced by the V3 engine.
// Both readTaskRecord and commitTask funnel through here so a tampered version
// cannot be rendered from or committed over. Throws before any write.
function assertV3Snapshot(task) {
  if (Number(task.engine_version) !== ENGINE_VERSION
    || Number(task.task_schema_version) !== TASK_SCHEMA_VERSION
    || Number(task.workflow_contract_version) !== WORKFLOW_CONTRACT_VERSION) {
    throw new Error('v3_engine_required');
  }
}

// The Engine owns stage_execution.stage_attempt_id. It stamps a fresh,
// unforgeable id at create and rotates it whenever a completed result advances
// to a different graph node. The format mirrors the V2 convention
// (sa-<workflow_id>-<stage_id>-<rand>) so chapter-commit provenance stays
// stable across the V2/V3 boundary, but this is a local, dependency-free helper:
// the V3 engine must not import the V2 state machine.
const crypto = require('crypto');
function createStageAttemptId(workflowId, stageId) {
  return `sa-${String(workflowId || 'workflow')}-${String(stageId || 'stage')}-${crypto.randomBytes(4).toString('hex')}`;
}

// Create the first durable snapshot for a V3 task. The three contract
// versions are stamped here so the durable task.json is the single source of
// truth for the engine identity that produced it. Creation honors the project
// workflow lock: if another writer already holds it, creation surfaces
// WORKFLOW_LOCKED without writing a task.json, and always releases on exit.
//
// Inside the SAME project lock, the create flow runs a side-effect-free creation
// preflight (the same validation createTaskAuthority will apply) BEFORE the
// durable task family is persisted, then registers the family, then writes
// task.json. The preflight-before-family order is what prevents a rejected
// create (e.g. a duplicate workflow id whose durable task.json already exists)
// from promoting an orphan family: family persistence never runs for a task
// that cannot be created. The family is what the chapter-commit transaction
// path requires (it derives task_family_id, branch_id, head branch, and
// stage_attempt_id provenance from the durable task when accepting a planning
// commit), so registering here — under the create lock and BEFORE task.json is
// written — means a freshly created V3 task can commit through the REAL
// chapter-commit transaction with no extra startup step, exactly like the V2
// create path.
//
// The Engine OWNS stage_execution.stage_attempt_id: any caller-supplied
// stage_execution is discarded, and a fresh Engine-stamped attempt id for the
// entry node lands on the first durable snapshot. The engine rotates it on
// graph hops; create only stamps the entry value.
//
// A family-registration failure fails CLOSED: it propagates out of create, so
// no durable task.json or success response is produced. Catching and swallowing
// it would let a task exist without the commit provenance chapter-commit
// requires, or leave a half-registered family. The single project lock and the
// single task authority are unchanged.
function createTaskRecord(projectRoot, input) {
  const root = path.resolve(projectRoot || '');
  const release = stateStore.acquireProjectLock(root, OWNER);
  try {
    const resumeMatchingFamily = input.resume_matching_family === true;
    const recordInput = { ...input };
    delete recordInput.resume_matching_family;
    // Creation preflight: reject a duplicate/invalid workflow id BEFORE any
    // family persistence, so a rejected create cannot leave an orphan family.
    // This reuses the same side-effect-free validation createTaskAuthority
    // applies (workflow id format + existing-file check); it writes nothing.
    authority.preflightCreateTaskAuthority(root, recordInput);

    const resumed = resumeMatchingFamily ? reusableFamilyHead(root, recordInput) : null;
    if (resumed) return resumed;

    const registered = registerFamilyProvenance(root, recordInput);
    // The Engine owns stage_execution: discard any caller-supplied value and
    // stamp a fresh entry-node attempt id. chapter-commit provenance requires a
    // non-empty stage_attempt_id, and the value must be Engine authority.
    const stageId = String(input.current_stage || SHORT_ENTRY_STAGE);
    const record = {
      ...recordInput,
      stage_execution: {
        status: 'running',
        stage_id: stageId,
        stage_attempt_id: createStageAttemptId(String(recordInput.workflow_id || ''), stageId),
      },
      ...(registered || {}),
      engine_version: ENGINE_VERSION,
      task_schema_version: TASK_SCHEMA_VERSION,
      workflow_contract_version: WORKFLOW_CONTRACT_VERSION,
    };
    return authority.createTaskAuthority(root, record, { owner: OWNER, focus: true });
  } finally {
    release();
  }
}

function reusableFamilyHead(root, input) {
  const familyStore = require('../task-family-store');
  const relationship = familyStore.resolveTaskRelationship(root, input);
  const family = relationship.kind === 'same_family' ? relationship.family : null;
  if (!family || !familyStore.isUnfinishedFamily(family)) return null;
  const headWorkflowId = String(family.head_workflow_id || '');
  if (!headWorkflowId) throw new Error('active_task_family_head_missing');
  const resolved = authority.resolveTaskAuthority(root, headWorkflowId);
  if (resolved.status !== 'ok') throw new Error(resolved.status || 'active_task_family_authority_missing');
  const task = resolved.task;
  if (Number(task.engine_version) !== ENGINE_VERSION
      || Number(task.task_schema_version) !== TASK_SCHEMA_VERSION
      || Number(task.workflow_contract_version) !== WORKFLOW_CONTRACT_VERSION) {
    throw new Error('active_short_requires_v3_migration');
  }
  if (String(task.workflow_type || '') !== String(input.workflow_type || '')) {
    throw new Error('active_task_family_workflow_mismatch');
  }
  return task;
}

// Resolve and persist the task family for a freshly created V3 task, returning
// the durable commit-provenance fields (task_family_id, branch_id, branch_status)
// that chapter-commit expects on the durable task. projectLockHeld is true so
// ensureTaskFamily reuses the create lock instead of reacquiring it. The family
// library is the same one the V2 state machine binds at create; this is not a
// new authority, only the V3 create-time call site the V2 path already has.
//
// A failure propagates: create fails closed and no task.json is written. There
// is intentionally NO broad catch — swallowing a family error would let a task
// exist without the commit provenance chapter-commit requires, or leave a
// half-registered family on disk.
function registerFamilyProvenance(root, input) {
  if (!input || !input.workflow_id) return null;
  const family = require('../task-family-store');
  const registration = family.ensureTaskFamily(root, input, { write: true, projectLockHeld: true });
  return {
    task_family_id: String((registration.family || {}).task_family_id || ''),
    branch_id: String(input.workflow_id),
    branch_status: String((registration.branch || {}).status || 'active'),
  };
}

// Commit exactly one mutation against the durable task.json under a project
// lock taken HERE, then reread the committed bytes back under the SAME lock
// before releasing. Holding the lock across both the mutation and the causal
// read guarantees the returned snapshot reflects exactly what was written: no
// concurrent writer can interpose between commit and reread. `mutator`
// receives a structured clone of the current committed task and must return
// the next task object (preserving workflow_id and task_dir). The snapshot
// read back under the lock is what the engine renders from.
function commitTask(projectRoot, workflowId, expectedVersion, mutator) {
  const root = path.resolve(projectRoot || '');
  const release = stateStore.acquireProjectLock(root, OWNER);
  try {
    authority.mutateTaskAuthority(
      root,
      workflowId,
      expectedVersion,
      (current) => {
        assertV3Snapshot(current);
        return mutator(structuredClone(current));
      },
      { owner: OWNER, projectLockHeld: true },
    );
    // Causal reread while still holding the lock taken for the mutation: the
    // engine renders off this snapshot, never the mutation's return value.
    return readTaskRecord(root, workflowId);
  } finally {
    release();
  }
}

function readTaskRecord(projectRoot, workflowId) {
  const resolved = authority.resolveTaskAuthority(projectRoot, workflowId);
  if (resolved.status !== 'ok') {
    const error = new Error(resolved.message || `durable task snapshot is unavailable: ${workflowId}`);
    error.code = 'WORKFLOW_TASK_AUTHORITY_MISSING';
    error.status = 'blocked_task_authority_missing';
    throw error;
  }
  assertV3Snapshot(resolved.task);
  return resolved.task;
}

module.exports = {
  createTaskRecord,
  commitTask,
  readTaskRecord,
  createStageAttemptId,
};
