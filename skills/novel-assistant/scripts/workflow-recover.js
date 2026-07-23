#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const { mutateTask } = require('./lib/workflow-state-store');
const { readFocusedTask } = require('./lib/workflow-task-authority');
const {
  currentReviewBatch,
  normalizeReviewBatchState,
  rebuildReviewBatchStateFromPlan,
  validateReviewBatchPlanMapping,
} = require('./lib/review-batch-state');
const { readReviewPlan, legacyReadOnlyBlock } = require('./lib/review-plan-contract');

const args = parseArgs(process.argv);
if (!args.projectRoot) fail('missing --project-root');

const root = path.resolve(args.projectRoot);
const currentFile = path.join(root, '追踪', 'workflow', 'current-task.json');
const focused = readFocusedTask(root);
const task = focused.authority.status === 'ok' ? focused.authority.task : null;
if (!task && focused.pointer) finish({ status: focused.authority.status, error: focused.authority.message || 'durable task snapshot is unavailable' }, 2);
if (!task) finish({ status: 'no_active_task', project_root: root });
const reviewPlanValidation = validateRecoveryReviewPlan(root, task);
if (reviewPlanValidation) finish(reviewPlanValidation, 2);

const stageId = String(task.current_stage || task.current_step || '');
const stageExecution = task.stage_execution || {};
if (needsTrustedCheckpointRepair(root, task)) {
  finish(repairTrustedCheckpoint(root, currentFile, task, args.write));
}
if (!stageId || (stageExecution.stage_id && stageExecution.stage_id !== stageId)) {
  finish({ status: 'no_recovery_needed', project_root: root, current_stage: stageId });
}

const expectedRel = String(stageExecution.expected_result_packet
  || (((task.runtime_guard || {}).checkpoint_policy || {}).expected_result_packet)
  || defaultPacketPath(task, stageId));
const expectedAbs = resolveInsideProject(root, expectedRel);
if (!expectedAbs) finish({ status: 'blocked_unsafe_result_packet_path', result_packet_path: expectedRel }, 2);

if (fs.existsSync(expectedAbs)) {
  if (!args.write) finish({ status: 'result_packet_ready', result_packet_path: expectedAbs, recovered_stage: stageId });
  finish(applyPacket(root, expectedAbs, stageId));
}

const stagePayload = task[stageId];
if (needsPersistedReviewBatchRecovery(task, stageId)) {
  finish(rebuildReviewBatchesFromPlan(root, task, stagePayload, args.write));
}

if (!isCompletedPayload(stagePayload)) {
  finish({
    status: 'stage_not_recoverable',
    project_root: root,
    recovered_stage: stageId,
    reason: '没有找到可证明当前阶段已完成的内嵌阶段摘要；应从当前阶段重新执行。',
  });
}

function durableTaskSnapshotPath(task) {
  const taskDir = String((task || {}).task_dir || `追踪/workflow/tasks/${(task || {}).workflow_id || 'unknown-workflow'}`)
    .replace(/\\\\/g, '/')
    .replace(/\/$/, '');
  return `${taskDir}/task.json`;
}

function needsTrustedCheckpointRepair(projectRoot, task) {
  const heartbeat = ((task.runtime_guard || {}).heartbeat || {});
  const trusted = String(heartbeat.latest_trusted_artifact || '');
  const trustedAbs = trusted ? resolveInsideProject(projectRoot, trusted) : '';
  const checkpoint = path.join(projectRoot, durableTaskSnapshotPath(task));
  return fs.existsSync(checkpoint) && (!trustedAbs || !fs.existsSync(trustedAbs));
}

function repairTrustedCheckpoint(projectRoot, currentPath, task, write) {
  if (write) {
    try {
      mutateTask({
        projectRoot,
        workflowId: task.workflow_id || '',
        expectedStateVersion: Number(task.state_version || 0),
        mutation: (current) => {
          current.runtime_guard = current.runtime_guard || {};
          current.runtime_guard.heartbeat = {
            ...(current.runtime_guard.heartbeat || {}),
            updated_at: new Date().toISOString(),
            latest_trusted_artifact: durableTaskSnapshotPath(current),
            workflow_id: current.workflow_id || '',
          };
          return current;
        },
      });
    } catch (error) {
      if (error && error.code === 'WORKFLOW_TASK_CONFLICT') {
        return { status: 'recovery_task_replaced', applied: false, workflow_id: task.workflow_id || '' };
      }
      throw error;
    }
  }
  return {
    status: 'trusted_checkpoint_repaired',
    applied: Boolean(write),
    workflow_id: task.workflow_id || '',
    latest_trusted_artifact: durableTaskSnapshotPath(task),
  };
}

function needsPersistedReviewBatchRecovery(task, stageId) {
  return task.workflow_type === 'review_repair'
    && stageId === 'evidence_scan'
    && Boolean(task.review_plan_path || task.review_plan_digest)
    && !task.review_batches;
}

function validateRecoveryReviewPlan(projectRoot, task) {
  if (task.workflow_type !== 'review_repair') return null;
  if (task.review_batches) normalizeReviewBatchState(task.review_batches);
  if (!task.review_plan_path && !task.review_plan_digest) return null;
  try {
    const loaded = readReviewPlan(projectRoot, task);
    if (loaded.plan_read_mode === 'legacy_read_only') return legacyReadOnlyBlock(task);
    if (loaded.plan.workflow_id !== task.workflow_id
      || loaded.plan.parent_scope !== ((task.review_batches || {}).parent_scope || task.scope)) {
      return blockedReviewPlan('blocked_review_plan_stale', 'review plan does not match the active review task.');
    }
    if (task.review_batches) validateReviewBatchPlanMapping(task.review_batches, loaded.plan);
    return null;
  } catch (error) {
    if (error && error.code === 'REVIEW_PLAN_STALE') return blockedReviewPlan('blocked_review_plan_stale', error.message);
    return blockedReviewPlan('blocked_review_plan_missing', (error && error.message) || 'review plan reference is missing.');
  }
}

function blockedReviewPlan(status, reason) {
  return { status, workflow_id: task.workflow_id || '', reason };
}

function rebuildReviewBatchesFromPlan(projectRoot, task, payload, write) {
  const loaded = readReviewPlan(projectRoot, task);
  if (loaded.plan_read_mode === 'legacy_read_only') return legacyReadOnlyBlock(task);
  const reviewBatches = rebuildReviewBatchStateFromPlan(task, loaded.plan);
  if (!reviewBatches) {
    return {
      status: 'blocked_invalid_review_scope',
      workflow_id: task.workflow_id || '',
      scope: task.scope || '',
      reason: '旧审阅任务缺少可解析的章节范围，无法安全迁移为分批审阅。',
    };
  }

  if (payload && typeof payload === 'object') {
    reviewBatches.legacy_evidence_snapshot = {
      status: String(payload.status || payload.batch_status || ''),
      batch_no: String(payload.batch_no || ''),
      batch_range: String(payload.batch_range || ''),
      summary: String(payload.summary || ''),
      evidence_artifacts: Array.isArray(payload.evidence_artifacts) ? payload.evidence_artifacts : [],
      migration_reason: '旧阶段摘要没有逐章覆盖证明，仅作为历史抽样证据保留。',
    };
  }

  const nextBatch = currentReviewBatch(reviewBatches);
  const expectedPacket = nextBatch ? nextBatch.result_packet : '';
  task.review_batches = reviewBatches;
  task.status = 'paused_after_step';
  task.current_stage = 'evidence_scan';
  task.current_step = 'evidence_scan';
  task.stage_execution = {
    stage_id: 'evidence_scan',
    status: 'paused',
    batch_id: nextBatch ? nextBatch.id : '',
    batch_scope: nextBatch ? nextBatch.range : '',
    expected_result_packet: expectedPacket,
    resume_hint: nextBatch ? `从审阅批次 ${nextBatch.id}（${nextBatch.range} 章）开始。` : '',
  };
  task.machine = task.machine || {};
  task.machine.completed_stages = Array.isArray(task.machine.completed_stages)
    ? task.machine.completed_stages.filter(item => item !== 'evidence_scan')
    : [];
  const remaining = Array.isArray(task.machine.remaining_stages) ? task.machine.remaining_stages : [];
  task.machine.remaining_stages = ['evidence_scan', ...remaining.filter(item => item !== 'evidence_scan')];
  task.machine.last_transition = 'review_batches_rebuilt_from_plan';
  task.machine.next_stop_reason = 'ready_next_review_batch';
  task.runtime_guard = task.runtime_guard || {};
  task.runtime_guard.heartbeat = {
    ...(task.runtime_guard.heartbeat || {}),
    updated_at: new Date().toISOString(),
    latest_trusted_artifact: durableTaskSnapshotPath(task),
    workflow_id: task.workflow_id || '',
  };
  task.runtime_guard.checkpoint_policy = {
    ...(task.runtime_guard.checkpoint_policy || {}),
    checkpoint_path: durableTaskSnapshotPath(task),
    resume_from: nextBatch ? `evidence_scan.batch-${nextBatch.id}` : 'evidence_scan',
    expected_result_packet: expectedPacket,
  };
  if (write) {
    try {
      mutateTask({
        projectRoot,
        workflowId: task.workflow_id || '',
        expectedStateVersion: Number(task.state_version || 0),
        mutation: () => task,
      });
    } catch (error) {
      if (error && error.code === 'WORKFLOW_TASK_CONFLICT') {
        return { status: 'recovery_task_replaced', applied: false, workflow_id: task.workflow_id || '' };
      }
      throw error;
    }
  }

  return {
    status: 'review_batches_initialized',
    applied: Boolean(write),
    workflow_id: task.workflow_id || '',
    total_batches: reviewBatches.total_count,
    completed_batches: 0,
    next_batch_id: nextBatch ? nextBatch.id : '',
    next_batch_range: nextBatch ? nextBatch.range : '',
    preserved_legacy_evidence: Boolean(reviewBatches.legacy_evidence_snapshot),
    reason: '旧摘要缺少完整覆盖证明；批次状态已严格按持久化审阅计划重建，未将抽样结果冒充为已完成审阅。',
  };
}

const packet = buildPacket(task, stageId, stagePayload, expectedRel);
if (!args.write) {
  finish({
    status: 'recoverable_preview',
    project_root: root,
    recovered_stage: stageId,
    result_packet_path: expectedAbs,
    packet,
  });
}

writeJsonAtomic(expectedAbs, packet);
finish(applyPacket(root, expectedAbs, stageId));

function parseArgs(argv) {
  const out = { projectRoot: '', write: false, json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--project-root') out.projectRoot = argv[++i] || '';
    else if (arg === '--write') out.write = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '-h' || arg === '--help') {
      console.log('Usage: node workflow-recover.js --project-root <book-dir> [--write] [--json]');
      process.exit(0);
    } else fail(`unknown argument: ${arg}`);
  }
  return out;
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function isCompletedPayload(payload) {
  if (!payload || typeof payload !== 'object') return false;
  const status = String(payload.status || payload.batch_status || payload.step_status || '').toLowerCase();
  return ['completed', 'complete', 'done', 'pass', 'passed'].includes(status)
    || (Boolean(payload.completed_at) && Boolean(payload.summary));
}

function buildPacket(task, stageId, payload, packetRel) {
  const evidence = Array.isArray(payload.evidence_artifacts)
    ? payload.evidence_artifacts
    : Array.isArray(payload.evidence) ? payload.evidence : [];
  return {
    workflow_id: task.workflow_id,
    workflow_type: task.workflow_type,
    stage_id: stageId,
    step_id: stageId,
    step_status: 'completed',
    outputs: [packetRel],
    changed_files: [],
    evidence,
    verification_result: 'pass',
    blocking_reason: '',
    next_recommendation: `继续 ${nextStage(task, stageId) || '下一阶段'}`,
    handoff_summary: String(payload.summary || `${stageId} 已从任务账本恢复。`),
    checkpoint_state: {
      recovered_from: 'embedded_stage_payload',
      completed_stage: stageId,
    },
    output_health_result: 'pass',
    result_packet_path: packetRel,
    recovered_at: new Date().toISOString(),
  };
}

function nextStage(task, stageId) {
  const remaining = (((task || {}).machine || {}).remaining_stages || []).filter(Boolean);
  return remaining.find(item => item !== stageId) || '';
}

function defaultPacketPath(task, stageId) {
  const base = task.context_paths && task.context_paths.result_packets_dir
    ? task.context_paths.result_packets_dir
    : `${task.task_dir || `追踪/workflow/tasks/${task.workflow_id}`}/result-packets`;
  return `${base}/${stageId}.result.json`;
}

function applyPacket(projectRoot, packetFile, recoveredStage) {
  const stateMachine = path.join(__dirname, 'workflow-state-machine.js');
  const run = cp.spawnSync(process.execPath, [stateMachine, 'apply-result', '--project-root', projectRoot, '--result', packetFile, '--json'], {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
  });
  if (run.error || run.status !== 0) {
    return {
      status: 'blocked_recovery_apply_failed',
      recovered_stage: recoveredStage,
      result_packet_path: packetFile,
      error: run.error ? run.error.message : String(run.stderr || run.stdout || '').trim(),
    };
  }
  const applied = JSON.parse(run.stdout);
  return {
    status: 'recovered_and_advanced',
    recovered_stage: recoveredStage,
    result_packet_path: packetFile,
    current_stage: applied.current_stage || '',
    remaining_stages: applied.remaining_stages || [],
    stage_execution: applied.stage_execution || null,
    pending_action: applied.pending_action || null,
    next_candidates: Array.isArray(applied.next_candidates) ? applied.next_candidates : [],
    visible_response: applied.visible_response || null,
    interaction_contract: String(applied.interaction_contract || ''),
  };
}

function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(temp, `${JSON.stringify(value, null, 2)}\n`);
  fs.renameSync(temp, file);
}

function resolveInsideProject(projectRoot, filePath) {
  const resolved = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(projectRoot, filePath);
  return resolved === projectRoot || resolved.startsWith(`${projectRoot}${path.sep}`) ? resolved : '';
}

function finish(value, code = 0) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  process.exit(code);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}
