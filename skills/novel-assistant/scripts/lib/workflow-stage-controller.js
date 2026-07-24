'use strict';

// workflow-stage-controller
//
// Single-command atomic stage advancer. This is the remediation for the
// "short sixth section runaway token" incident: the host used to chain
// inspect / apply-result / reconcile-runtime by hand, and when the linear
// stage router returned the wrong next stage the host entered a hundred-call
// debugging loop. advanceStage collapses "advance one stage" into ONE
// transactional call with a strict once-only recovery + circuit breaker.
//
// Contract:
//   - status='advanced': clean transition, recovery_count=0
//   - status='recovered_once': first attempt hit a recoverable failure
//     (stale state version or transition-layer transient block), the
//     authority task + registry were re-read, and the retry succeeded.
//   - status='paused_transition_failure': two consecutive same-failure
//     attempts. Task is parked at status='paused',
//     runtime_guard.max_retry_budget.retry_budget_result='exhausted',
//     last_trusted_artifact preserved, NO diagnostic commands run, NO
//     project runtime mutation beyond the task snapshot.
//   - status='blocked_*' (identity / packet / authority): non-recoverable.
//     Registry really unavailable etc. → do not retry, do not pause-and-loop.
//
// The controller composes existing library components only:
//   - workflow-template-registry.buildEffectiveTemplates / resolveTemplateForTask
//   - workflow-transition-service.createWorkflowTransitionService.resolveStageTransition
//   - workflow-task-authority.resolveTaskAuthority / mutateTaskAuthority
//   - workflow-state-store.appendJsonl (history.jsonl + per-task journal.jsonl)
// 并发保护由 mutateTaskAuthority 内部 acquireProjectLock 提供,controller
// 本身不直接持锁 —— 它把所有 task.json 写入都委托给 authority 层,锁在那一层复用。
// It never shells out to state-machine CLI commands.

const fs = require('fs');
const path = require('path');

const { buildEffectiveTemplates, resolveTemplateForTask } = require('./workflow-template-registry');
const { createWorkflowTransitionService } = require('./workflow-transition-service');
const authority = require('./workflow-task-authority');
const store = require('./workflow-state-store');
const { ensureTaskFamily } = require('./task-family-store');

// The transition service needs the same lifecycle helpers the state machine
// wires up. We provide minimal implementations sufficient for stage routing:
// findStage scans the template; currentUnitRole/validateLifecycleTransition
// return permissive defaults (short_write does not use the longform lifecycle
// gate that consumes them, and resolveStageTransition only consults them on
// the long_write / explicit-next paths).
function buildTransitionService() {
  return createWorkflowTransitionService({
    findStage: (tpl, stageId) => (tpl && Array.isArray(tpl.stages)
      ? tpl.stages.find((stage) => stage && stage.stage_id === stageId) || null
      : null),
    currentUnitRole: (contract, stageId) => {
      const roles = (contract && contract.stage_roles) || {};
      return roles[stageId] || '';
    },
    unitLifecycle: () => ({ stage_roles: {}, required_sequence: [] }),
    validateLifecycleTransition: () => ({ allowed: true }),
  });
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

// Strip the internal `kind` discriminator before returning to an external
// caller (CLI --json). attemptAdvance uses `kind` internally to distinguish
// advanced / non_recoverable / recoverable control flow; it must NOT leak into
// the public API contract. Internal callers that still need the discriminator
// read `kind` before calling toExternal.
function toExternal(result) {
  if (!result || typeof result !== 'object') return result;
  const { kind, ...external } = result;
  return external;
}

function isInsideProject(root, file) {
  const resolved = path.resolve(file);
  const rootResolved = path.resolve(root);
  return resolved === rootResolved || resolved.startsWith(`${rootResolved}${path.sep}`);
}

function trustedArtifactFromResult(result) {
  if (!result) return '';
  const explicit = String(result.result_packet_path || '');
  if (explicit) return explicit;
  const changed = Array.isArray(result.changed_files) ? result.changed_files : [];
  const firstProse = changed.find((candidate) => /\.md$/i.test(String(candidate)) && !/Brief| brief /i.test(String(candidate)));
  return firstProse || '';
}

function workflowDir(root) {
  return path.join(root, '追踪', 'workflow');
}

function taskDir(root, workflowId) {
  return path.join(workflowDir(root), 'tasks', workflowId || 'unknown-workflow');
}

function journalFile(root, workflowId) {
  return path.join(taskDir(root, workflowId), 'journal.jsonl');
}

function historyFile(root) {
  return path.join(workflowDir(root), 'history.jsonl');
}

function appendTaskEvent(root, workflowId, event, payload) {
  if (!workflowId) return;
  fs.mkdirSync(path.dirname(journalFile(root, workflowId)), { recursive: true });
  store.appendJsonl(journalFile(root, workflowId), {
    at: new Date().toISOString(),
    event,
    workflow_id: workflowId,
    workflow_type: payload.workflow_type || '',
    stage_id: payload.stage_id || payload.current_stage || '',
    step_id: payload.step_id || payload.current_step || '',
  });
}

function appendHistory(root, event, payload) {
  fs.mkdirSync(workflowDir(root), { recursive: true });
  store.appendJsonl(historyFile(root), {
    at: new Date().toISOString(),
    event,
    workflow_id: payload.workflow_id || '',
    workflow_type: payload.workflow_type || '',
    stage_id: payload.stage_id || payload.current_stage || '',
    step_id: payload.step_id || payload.current_step || '',
  });
}

// Apply a successful transition to a task draft. This mirrors only the fields
// the controller contract exposes (current_stage, machine, runtime_guard
// heartbeat, pending_action). It deliberately does not replicate every
// enrichment in state-machine advanceTask (lifecycle_graph, unit_lifecycle,
// recommended_next rendering) — those remain the state machine's job when the
// host needs the full advance flow. The controller's scope is: route, persist,
// journal once. Tests assert next_stage / recovery_count / heartbeat, not the
// enriched fields.
function lifecycleRole(tpl, stageId) {
  return String(((((tpl || {}).unit_lifecycle_contract || {}).stage_roles || {})[stageId]) || '');
}

function applyTransitionToTask(task, tpl, transition, result, now) {
  const stageId = String(result.stage_id || task.current_stage || '');
  const nextStageId = String(transition.next_stage_id || '');
  const machine = task.machine || { completed_stages: [], remaining_stages: [] };
  const completedStages = Array.isArray(machine.completed_stages) ? machine.completed_stages.slice() : [];
  if (transition.complete_current_stage && stageId && !completedStages.includes(stageId)) {
    completedStages.push(stageId);
  }
  const remainingStages = Array.isArray(transition.remaining_stages)
    ? transition.remaining_stages.slice()
    : (nextStageId ? [nextStageId] : []);

  task.current_stage = nextStageId || stageId;
  task.current_step = nextStageId || stageId;
  task.status = nextStageId ? 'running' : 'completed';
  task.lifecycle = {
    ...(task.lifecycle || {}),
    status: nextStageId ? 'active' : 'completed',
    updated_at: now,
    completed_at: nextStageId ? '' : now,
  };
  const unit = task.unit_lifecycle && typeof task.unit_lifecycle === 'object'
    ? task.unit_lifecycle
    : {};
  const completedRoles = Array.isArray(unit.completed_roles) ? unit.completed_roles.slice() : [];
  const completedRole = lifecycleRole(tpl, stageId);
  if (transition.complete_current_stage && completedRole && !completedRoles.includes(completedRole)) {
    completedRoles.push(completedRole);
  }
  task.unit_lifecycle = {
    ...unit,
    unit_type: String(unit.unit_type || (((tpl || {}).unit_lifecycle_contract || {}).unit_type) || 'workflow_batch'),
    status: nextStageId ? 'active' : 'completed',
    updated_at: now,
    current_scope: String(unit.current_scope || task.scope || ''),
    current_stage: nextStageId || stageId,
    current_role: nextStageId ? lifecycleRole(tpl, nextStageId) : 'handoff_and_next',
    stage_roles: unit.stage_roles || (((tpl || {}).unit_lifecycle_contract || {}).stage_roles) || {},
    required_sequence: unit.required_sequence || (((tpl || {}).unit_lifecycle_contract || {}).required_sequence) || [],
    completed_roles: completedRoles,
    last_trusted_artifact: transition.complete_current_stage
      ? (trustedArtifactFromResult(result) || String(unit.last_trusted_artifact || ''))
      : String(unit.last_trusted_artifact || ''),
  };
  task.machine = {
    ...machine,
    completed_stages: completedStages,
    remaining_stages: remainingStages,
    last_transition: transition.reason || (nextStageId ? 'stage_completed' : 'workflow_completed'),
    last_result_packet: String(result.result_packet_path || ''),
    next_stop_reason: nextStageId ? 'ready_next_stage' : 'completed',
    allowed_actions: nextStageId ? ['continue_next_stage', 'pause'] : [],
    last_execution_event: 'stage_completed',
  };
  task.stage_execution = {
    ...(task.stage_execution || {}),
    status: 'completed',
    stage_id: stageId,
    step_id: String(result.step_id || stageId),
    owner_module: String(result.owner_module || ((task.stage_execution || {}).owner_module) || ''),
    completed_at: now,
    result_packet: String(result.result_packet_path || ''),
    expected_result_packet: '',
  };
  task.runtime_guard = task.runtime_guard || {};
  const previousTrusted = String(((task.runtime_guard.heartbeat || {}).latest_trusted_artifact) || '');
  const trusted = trustedArtifactFromResult(result) || previousTrusted;
  task.runtime_guard.heartbeat = {
    ...((task.runtime_guard.heartbeat) || {}),
    updated_at: now,
    latest_trusted_artifact: trusted,
    current_batch: nextStageId || stageId,
    workflow_id: task.workflow_id || '',
  };
  task.runtime_guard.checkpoint_policy = {
    ...((task.runtime_guard.checkpoint_policy) || {}),
    resume_from: nextStageId || stageId,
    expected_result_packet: '',
  };
  if (!nextStageId) task.pending_action = null;
  return task;
}

// The single attempt. Reads authority + registry, computes the transition,
// persists atomically (state-version-checked), appends exactly one journal
// transition. Throws a tagged error for recoverable conditions so the outer
// retry loop can distinguish them.
function attemptAdvance(options) {
  const { root, workflowId, result, expectedStateVersion } = options;
  const resolved = authority.resolveTaskAuthority(root, workflowId);
  if (resolved.status !== 'ok') {
    const error = new Error(resolved.status);
    error.tag = 'non_recoverable';
    error.status = resolved.status;
    return { kind: 'non_recoverable', status: resolved.status, message: resolved.message || 'durable task snapshot is unavailable' };
  }
  const task = resolved.task;

  const registryCheck = resolveTemplateForTask(task, { templates: options.templates, registries: options.registries });
  if (registryCheck.status !== 'ok') {
    // Identity failure (private registry unavailable / owner mismatch) is NOT
    // a recoverable transition failure: retrying without fixing the registry
    // cannot help. Do not enter the recovery path; surface blocked directly.
    return {
      kind: 'non_recoverable',
      status: registryCheck.status,
      message: '私有工作流 registry 不可用,且任务权威快照要求私有 overlay;不得降级到公开模板。',
    };
  }
  const tpl = registryCheck.template;

  const stageId = String(result.stage_id || task.current_stage || '');
  const stageDef = (tpl.stages || []).find((item) => String((item || {}).stage_id || '') === stageId) || {};
  const expectedOwner = String(((task.stage_execution || {}).owner_module) || stageDef.owner_module || task.workflow_owner || '');
  const actualOwner = String(result.owner_module || '');
  const privateWorkflow = String(task.workflow_profile || '') === 'private'
    || String(((task.workflow_registry || {}).profile) || '') === 'private';
  if ((expectedOwner && actualOwner && expectedOwner !== actualOwner)
    || (privateWorkflow && expectedOwner && !actualOwner)) {
    return {
      kind: 'non_recoverable',
      status: 'blocked_result_packet_owner_mismatch',
      message: `result packet owner mismatch: expected ${expectedOwner}, actual ${actualOwner || '(missing)'}`,
    };
  }
  const machine = {
    completed_stages: ((task.machine || {}).completed_stages || []).slice(),
    remaining_stages: ((task.machine || {}).remaining_stages || []).slice(),
  };
  const transition = options.transitionService.resolveStageTransition(tpl, machine, stageId, result, task, root);

  // Transition-layer block (machine gate / repair loop / explicit_next invalid /
  // detail_outline review failure etc.). This is a recoverable transition
  // failure: the recovery path re-reads the authority task + recomputes, and if
  // the same block persists on retry, we park at the circuit breaker. We do NOT
  // persist or journal here — persisting a blocked transition would corrupt the
  // task and lose the "single journal transition per advance" guarantee.
  if (transition.blocked) {
    return {
      kind: 'recoverable',
      status: 'recoverable_transition_failure',
      reason: transition.reason || 'transition_blocked',
      detail: { transition },
    };
  }

  const now = new Date().toISOString();
  const next = authority.mutateTaskAuthority(root, workflowId, expectedStateVersion, (draft) => {
    applyTransitionToTask(draft, tpl, transition, result, now);
    return draft;
  }, { owner: 'workflow-stage-controller' });

  // task.json 是任务真相源；阶段提交后立即刷新任务族投影，避免任务已完成但
  // family / inbox 仍显示 active。这里在 authority 事务完成后单独持项目锁，
  // 不与 mutateTaskAuthority 的锁嵌套。
  if (next.task_family_id) ensureTaskFamily(root, next, { write: true });

  // Append exactly one journal transition + one history line for this advance.
  // This is the "single journal transition per advance" guarantee.
  const eventPayload = {
    workflow_id: workflowId,
    workflow_type: task.workflow_type || '',
    stage_id: stageId,
    current_stage: next.current_stage,
    current_step: next.current_step,
  };
  appendHistory(root, 'advanced', eventPayload);
  appendTaskEvent(root, workflowId, 'advanced', eventPayload);

  const trustedArtifact = ((next.runtime_guard || {}).heartbeat || {}).latest_trusted_artifact || '';
  return {
    kind: 'advanced',
    status: 'advanced',
    workflow_id: workflowId,
    completed_stage: stageId,
    next_stage: String(transition.next_stage_id || ''),
    next_action: transition.next_stage_id ? `continue_${transition.next_stage_id}` : 'workflow_completed',
    next_command: transition.next_stage_id
      ? 'node scripts/workflow-state-machine.js next-candidates --project-root . --json'
      : '',
    recovery_count: 0,
    last_trusted_artifact: trustedArtifact,
    reason: transition.reason || '',
    state_version: next.state_version,
  };
}

// advanceStage({ projectRoot, workflowId, resultPath, sessionId,
//   privateRegistryRoot, noPrivateRegistry, expectedStateVersion,
//   templates, registries })
//
// Either pass { templates, registries } (pre-built, used by tests / hosts that
// already loaded the registry) or { privateRegistryRoot, noPrivateRegistry }
// and the controller will build them itself (same flags as state-machine).
function advanceStage(input) {
  const root = path.resolve(input.projectRoot || '');
  const workflowId = String(input.workflowId || '');

  // Load templates once. The recovery path re-reads the AUTHORITY TASK and
  // recomputes the transition from scratch, but the registry itself is a
  // code-shipped artifact; it does not change between attempts inside the
  // same process. (If the registry is genuinely unavailable, resolveTemplateForTask
  // below returns blocked_private_workflow_registry_unavailable, which is
  // non-recoverable.)
  let templates = input.templates;
  let registries = input.registries;
  if (!templates) {
    const built = buildEffectiveTemplates(input.privateRegistryRoot || '', Boolean(input.noPrivateRegistry));
    templates = built.templates;
    registries = built.registries;
  }
  const transitionService = buildTransitionService();

  // Read + validate the result packet up front. Bad packet → non-recoverable.
  const resultPath = input.resultPath ? path.resolve(input.resultPath) : '';
  if (!resultPath || !isInsideProject(root, resultPath)) {
    return { status: 'blocked_result_packet_path_unsafe', workflow_id: workflowId, recovery_count: 0 };
  }
  const result = readJson(resultPath);
  if (!result || result.__error) {
    return { status: 'blocked_invalid_result_packet', workflow_id: workflowId, recovery_count: 0, message: result ? result.__error : 'missing result packet' };
  }
  if (String(result.workflow_id || '') !== workflowId) {
    return { status: 'blocked_result_task_scope_conflict', workflow_id: workflowId, recovery_count: 0 };
  }

  // First attempt. We pass the caller's expectedStateVersion if given
  // (host read the task snapshot just before). Otherwise read the authority
  // version ourselves.
  const baseOptions = {
    root,
    workflowId,
    result,
    templates,
    registries,
    transitionService,
  };

  let firstExpected;
  let firstTask;
  const firstAuthority = authority.resolveTaskAuthority(root, workflowId);
  if (firstAuthority.status === 'ok') {
    firstTask = firstAuthority.task;
    firstExpected = Number.isInteger(input.expectedStateVersion) ? input.expectedStateVersion : Number(firstTask.state_version || 0);
  } else {
    // Authority missing is non-recoverable.
    return { status: firstAuthority.status, workflow_id: workflowId, recovery_count: 0, message: firstAuthority.message || 'durable task snapshot is unavailable' };
  }

  let firstResult;
  try {
    firstResult = attemptAdvance({ ...baseOptions, expectedStateVersion: firstExpected });
  } catch (error) {
    // State-version conflict = stale snapshot = recoverable.
    if (error && (error.code === 'WORKFLOW_TASK_CONFLICT' || error.code === 'WORKFLOW_TASK_AUTHORITY_MISSING')) {
      firstResult = { kind: 'recoverable', status: 'recoverable_transition_failure', reason: 'state_version_conflict', detail: { code: error.code, message: error.message } };
    } else {
      throw error;
    }
  }

  // Clean advance — done. Strip the internal `kind` discriminator before
  // returning to the external caller (CLI --json contract).
  if (firstResult.kind === 'advanced') return toExternal(firstResult);
  // Non-recoverable (identity / authority / packet) — surface, do not retry.
  if (firstResult.kind === 'non_recoverable') {
    return { status: firstResult.status, workflow_id: workflowId, recovery_count: 0, message: firstResult.message || '' };
  }

  // Recoverable transition failure. Circuit-breaker policy: ONE retry only.
  // Re-read the authority task + recompute the transition. We do NOT re-run
  // diagnostics or touch the project runtime. We do NOT mutate last_trusted_artifact.
  const secondAuthority = authority.resolveTaskAuthority(root, workflowId);
  if (secondAuthority.status !== 'ok') {
    return { status: secondAuthority.status, workflow_id: workflowId, recovery_count: 1, message: secondAuthority.message || 'durable task snapshot is unavailable on retry' };
  }
  const secondExpected = Number(secondAuthority.task.state_version || 0);

  // Also recompute the transition with the freshly-read task to see if it is
  // still blocked at the transition layer. If the transition itself is
  // permanently blocked (e.g. the result packet signals blocking), the retry
  // will fail the same way → we pause immediately without mutating runtime.
  const secondTask = secondAuthority.task;
  const registryCheck = resolveTemplateForTask(secondTask, { templates, registries });
  if (registryCheck.status !== 'ok') {
    return { status: registryCheck.status, workflow_id: workflowId, recovery_count: 1, message: '私有工作流 registry 不可用,且任务权威快照要求私有 overlay;不得降级到公开模板。' };
  }
  const stageId = String(result.stage_id || secondTask.current_stage || '');
  const machine = {
    completed_stages: ((secondTask.machine || {}).completed_stages || []).slice(),
    remaining_stages: ((secondTask.machine || {}).remaining_stages || []).slice(),
  };
  const recheckedTransition = transitionService.resolveStageTransition(registryCheck.template, machine, stageId, result, secondTask, root);

  // If the transition is still blocked on the same kind of failure, the retry
  // cannot help → park the task at the circuit breaker. Preserve the last
  // trusted artifact; only flip status + retry budget.
  if (recheckedTransition.blocked) {
    return pauseAtTrustedCheckpoint({
      root,
      workflowId,
      expectedStateVersion: secondExpected,
      task: secondTask,
      stageId,
      result,
      blockedReason: recheckedTransition.reason || 'transition_blocked',
    });
  }

  // Transition is now clear (stale version was the only issue). Retry the
  // atomic mutate with the fresh expected version.
  let secondResult;
  try {
    secondResult = attemptAdvance({ ...baseOptions, expectedStateVersion: secondExpected });
  } catch (error) {
    if (error && (error.code === 'WORKFLOW_TASK_CONFLICT' || error.code === 'WORKFLOW_TASK_AUTHORITY_MISSING')) {
      // Even the retry hit a version conflict → two consecutive same-failures → pause.
      return pauseAtTrustedCheckpoint({
        root,
        workflowId,
        expectedStateVersion: secondExpected,
        task: secondAuthority.task,
        stageId,
        result,
        blockedReason: 'state_version_conflict_persisted',
      });
    }
    throw error;
  }

  if (secondResult.kind === 'advanced') {
    // Strip the internal `kind` discriminator, then mark recovered_once.
    return { ...toExternal(secondResult), status: 'recovered_once', recovery_count: 1 };
  }
  if (secondResult.kind === 'non_recoverable') {
    return { status: secondResult.status, workflow_id: workflowId, recovery_count: 1, message: secondResult.message || '' };
  }
  // Two consecutive same transition failures → pause.
  return pauseAtTrustedCheckpoint({
    root,
    workflowId,
    expectedStateVersion: secondExpected,
    task: secondAuthority.task,
    stageId,
    result,
    blockedReason: 'transition_failure_persisted',
  });
}

function pauseAtTrustedCheckpoint(options) {
  const { root, workflowId, expectedStateVersion, task, stageId, result, blockedReason } = options;
  const previousTrusted = String((((task || {}).runtime_guard || {}).heartbeat || {}).latest_trusted_artifact) || '';

  // Single atomic mutation: flip status to paused, mark retry budget
  // exhausted, preserve last_trusted_artifact unchanged. No diagnostic
  // commands, no project runtime mutation, no recovery probing.
  let parked;
  try {
    parked = authority.mutateTaskAuthority(root, workflowId, expectedStateVersion, (draft) => {
      draft.status = 'paused';
      draft.runtime_guard = draft.runtime_guard || {};
      draft.runtime_guard.max_retry_budget = {
        ...((draft.runtime_guard.max_retry_budget) || { same_failure: 1, on_exhausted: 'pause_at_checkpoint' }),
        retry_budget_result: 'exhausted',
        last_failure_reason: blockedReason,
      };
      // Preserve last_trusted_artifact. Do NOT overwrite with the current
      // (failing) result packet — that would corrupt the trusted checkpoint.
      draft.runtime_guard.heartbeat = {
        ...((draft.runtime_guard.heartbeat) || {}),
        latest_trusted_artifact: previousTrusted,
      };
      draft.machine = draft.machine || {};
      draft.machine.next_stop_reason = 'paused_transition_failure';
      return draft;
    }, { owner: 'workflow-stage-controller' });
  } catch (error) {
    // If the version moved again we cannot even park safely. Surface as
    // blocked rather than spinning; the operator must inspect manually.
    return {
      status: 'blocked_pause_mutation_conflict',
      workflow_id: workflowId,
      recovery_count: 1,
      message: error && error.message ? error.message : 'pause mutation conflicted',
    };
  }

  const pausePayload = {
    workflow_id: workflowId,
    workflow_type: (task || {}).workflow_type || '',
    stage_id: stageId,
    step_id: stageId,
  };
  appendHistory(root, 'paused_transition_failure', pausePayload);
  // Align with the success path: also record the pause in the per-task journal
  // so operators querying journal.jsonl by workflow_id can observe pause events
  // (not only the global history.jsonl).
  appendTaskEvent(root, workflowId, 'paused_transition_failure', pausePayload);

  return {
    status: 'paused_transition_failure',
    workflow_id: workflowId,
    completed_stage: stageId,
    next_stage: '',
    next_action: 'paused_transition_failure',
    recovery_count: 1,
    last_trusted_artifact: previousTrusted,
    reason: blockedReason,
    state_version: parked.state_version,
  };
}

module.exports = {
  advanceStage,
  buildTransitionService,
  applyTransitionToTask,
};
