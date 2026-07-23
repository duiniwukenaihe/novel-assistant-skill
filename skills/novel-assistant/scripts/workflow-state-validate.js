#!/usr/bin/env node
'use strict';

const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { validateTaskState } = require('./lib/workflow-state-store');
const { readFocusedTask } = require('./lib/workflow-task-authority');
const { isMigrationSuppressed, scanWorkflowMigrations } = require('./lib/workflow-legacy-migration');
const { validateResultPacketUnitBinding } = require('./lib/workflow-result-packet-identity');

const TERMINAL_STATUSES = new Set(['completed', 'completed_verified', 'done', 'pass', 'closed', 'cancelled', 'canceled', 'superseded']);
const PAUSED_STATUSES = new Set(['paused', 'paused_after_batch', 'paused_after_step']);

function resolveAuthoritativeStatus(projectRoot, options = {}) {
  const root = path.resolve(projectRoot);
  const currentFile = path.join(root, '追踪', 'workflow', 'current-task.json');
  const focused = options.task ? null : readFocusedTask(root);
  const task = options.task || (focused && focused.authority.status === 'ok' ? focused.authority.task : null);
  const now = options.now || new Date().toISOString();
  if (!task && focused && focused.pointer) return status('blocked', 'repair_task_state', {
    project_root: root, current_task_path: currentFile, reason_code: 'task_authority_missing', findings: [{ code: 'blocked_task_authority_missing', message: focused.authority.message || 'durable task snapshot is unavailable' }],
  });
  if (!task) return status('idle', 'idle', { project_root: root, current_task_path: currentFile, findings: [] });
  if (task.__error) {
    return status('blocked', 'repair_runtime_guard', {
      project_root: root,
      current_task_path: currentFile,
      reason_code: 'invalid_current_task',
      findings: [{ code: 'invalid_json', message: task.__error }],
    });
  }

  const findings = validateTaskState(task, root);
  const pointerFindings = focused && Array.isArray(focused.pointer_findings) ? focused.pointer_findings : [];

  const runtimeGuard = task.runtime_guard || {};
  const checkpoint = runtimeGuard.checkpoint_policy || {};
  const trustedArtifact = String(((runtimeGuard.heartbeat || {}).latest_trusted_artifact) || '');
  const base = {
    project_root: root,
    current_task_path: currentFile,
    workflow_id: String(task.workflow_id || ''),
    workflow_type: String(task.workflow_type || ''),
    current_stage: String(task.current_stage || ''),
    current_step: String(task.current_step || ''),
    checkpoint_path: String(checkpoint.checkpoint_path || ''),
    resume_from: String(checkpoint.resume_from || ''),
    focus_pointer_status: focused ? (focused.pointer_status || 'current') : 'none',
    focus_pointer_findings: pointerFindings,
    findings,
  };
  if (findings.length) return status('blocked', 'repair_task_state', { ...base, reason_code: 'state_invariant' });
  if (!task.runtime_guard || task.runtime_guard === 'none') {
    return status('blocked', 'repair_runtime_guard', { ...base, reason_code: 'runtime_guard_missing' });
  }
  const migration = findActiveMigration(root, task.workflow_id);
  if (migration) {
    return status('migration_pending', 'migrate_legacy_review_and_continue', {
      ...base,
      migration: {
        classification: migration.classification,
        reason: migration.reason,
        rollback_snapshot: migration.rollback_snapshot || '',
      },
    });
  }

  const taskStatus = String(task.status || '').toLowerCase();
  const lease = runtimeGuard.runner_lease || {};
  if (hasLiveRunnerLease(lease, task, now)) {
    return status('running', 'continue', {
      ...base,
      process_heartbeat_at: lease.process_heartbeat_at,
      checkpoint_updated_at: runtimeGuard.checkpoint_updated_at || '',
      runner_run_id: String(lease.run_id || ''),
    });
  }

  const feedbackBlock = unreconciledShortFeedback(task);
  if (feedbackBlock) {
    return status('blocked', 'repair_task_state', {
      ...base,
      reason_code: 'pending_feedback_unreconciled',
      findings: [feedbackBlock],
    });
  }
  if (awaitsUser(task)) return status('awaiting_user', 'await_user_choice', base);
  if (taskStatus.startsWith('blocked')) return status('blocked', 'repair_runtime_guard', { ...base, reason_code: taskStatus || 'blocked' });
  if (PAUSED_STATUSES.has(taskStatus) || String((task.stage_execution || {}).status || '').toLowerCase() === 'paused') {
    return status('paused', 'resume_from_checkpoint', { ...base, reason_code: taskStatus || 'paused' });
  }

  if (trustedArtifact && !existsInsideProject(root, trustedArtifact)) {
    return status('blocked', 'recover_missing_result_packet', {
      ...base,
      reason_code: 'trusted_artifact_missing',
      trusted_artifact: trustedArtifact,
      trusted_artifact_status: 'missing',
    });
  }

  const expectedPacketRel = String(((task.stage_execution || {}).expected_result_packet)
    || (((runtimeGuard.checkpoint_policy || {}).expected_result_packet) || ''));
  const expectedPacket = expectedPacketRel ? readJsonInsideProject(root, expectedPacketRel) : null;
  if (expectedPacket && !expectedPacket.__missing && !expectedPacket.__unsafe && !expectedPacket.__error) {
    const unitBinding = validateResultPacketUnitBinding(task, expectedPacket);
    if (unitBinding) {
      return status('blocked', 'regenerate_current_result_packet', {
        ...base,
        reason_code: 'stale_result_packet_scope',
        expected_result_packet: expectedPacketRel,
        findings: [{
          code: unitBinding.status,
          ...(unitBinding.findings || [])[0],
        }],
      });
    }
  }
  const lifecycleStatus = String((task.lifecycle || {}).status || '').toLowerCase();
  if (TERMINAL_STATUSES.has(taskStatus) || TERMINAL_STATUSES.has(lifecycleStatus)) {
    return status('completed', 'idle', { ...base, reason_code: 'terminal_task' });
  }

  if (hasResumableCheckpoint(runtimeGuard)) return status('paused', 'resume_from_checkpoint', { ...base, reason_code: 'resumable_checkpoint' });
  return status('idle', 'idle', base);
}

function status(value, action, extra = {}) {
  return {
    schemaVersion: '1.0.0',
    status: value,
    recommended_action: action,
    next_action: action,
    ...extra,
  };
}

function findActiveMigration(projectRoot, workflowId) {
  const migration = scanWorkflowMigrations(projectRoot);
  return migration.inventory.items.find((item) => item.active
    && String(item.workflow_id || '') === String(workflowId || '')
    && isMigrationSuppressed(item));
}

function hasLiveRunnerLease(lease, task, now) {
  if (!lease || typeof lease !== 'object') return false;
  if (!lease.run_id || !lease.process_heartbeat_at || !lease.expires_at) return false;
  if (String(lease.workflow_id || '') !== String(task.workflow_id || '')) return false;
  if (String(lease.stage_id || '') !== String(task.current_stage || task.current_step || '')) return false;
  const heartbeatAt = new Date(lease.process_heartbeat_at).getTime();
  const expiresAt = new Date(lease.expires_at).getTime();
  const nowAt = new Date(now).getTime();
  return Number.isFinite(heartbeatAt) && Number.isFinite(expiresAt) && Number.isFinite(nowAt)
    && heartbeatAt <= nowAt && expiresAt > nowAt;
}

function awaitsUser(task) {
  const taskStatus = String(task.status || '').toLowerCase();
  if (['awaiting_user', 'awaiting_user_confirmation', 'needs_confirmation'].includes(taskStatus)) return true;
  const pending = task.pending_action || {};
  return Array.isArray(pending.options)
    && pending.options.length > 0
    && String(pending.status || '').toLowerCase() !== 'resolved'
    && String((task.stage_execution || {}).status || '').toLowerCase() !== 'running';
}

function hasResumableCheckpoint(runtimeGuard) {
  const checkpoint = (runtimeGuard || {}).checkpoint_policy || {};
  return Boolean(checkpoint.checkpoint_path || checkpoint.resume_from);
}

function existsInsideProject(root, filePath) {
  const resolved = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(root, filePath);
  if (!(resolved === root || resolved.startsWith(`${root}${path.sep}`))) return false;
  return fs.existsSync(resolved);
}

function unreconciledShortFeedback(task) {
  const workflowType = String(task.workflow_type || '');
  const unitType = String((task.unit_lifecycle || {}).unit_type || '');
  if (!['short_write', 'private_short_startup'].includes(workflowType) && unitType !== 'section') return null;
  const pending = task.pending_feedback || {};
  if (!pending || typeof pending !== 'object' || !String(pending.text || '').trim()) return null;
  const currentStage = String(task.current_stage || '');
  if (['feedback_impact_sync', 'feedback_apply_patch', 'section_repair_loop'].includes(currentStage)) return null;
  const impact = task.short_feedback_impact || {};
  const expectedFeedbackId = String(pending.feedback_id || `feedback-${crypto.createHash('sha256').update(`${String(pending.received_at || '')}\n${String(pending.text || '').trim()}`, 'utf8').digest('hex').slice(0, 16)}`);
  return {
    code: 'blocked_short_feedback_unreconciled',
    field: 'pending_feedback',
    message: '短篇反馈虽然可能已经完成影响分析，但尚未完成修订、复检与重新采用；必须先回到反馈处理链，不得启动下一节。',
    received_at: String(pending.received_at || ''),
    feedback_id: expectedFeedbackId,
    impact_applied_at: String(impact.applied_at || ''),
    current_stage: currentStage,
  };
}

function readJson(file) {
  try {
    if (!fs.existsSync(file)) return null;
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return { __error: error.message };
  }
}

function readJsonInsideProject(root, filePath) {
  const resolved = path.isAbsolute(filePath) ? path.resolve(filePath) : path.resolve(root, filePath);
  if (!(resolved === root || resolved.startsWith(`${root}${path.sep}`))) return { __unsafe: true };
  if (!fs.existsSync(resolved)) return { __missing: true };
  return readJson(resolved);
}

function parseArgs(argv) {
  const out = { projectRoot: '', json: false, now: '' };
  for (let i = 2; i < argv.length; i += 1) {
    if (argv[i] === '--project-root') out.projectRoot = argv[++i] || '';
    else if (argv[i] === '--now') out.now = argv[++i] || '';
    else if (argv[i] === '--json') out.json = true;
    else if (argv[i] === '-h' || argv[i] === '--help') {
      console.log('Usage: node workflow-state-validate.js --project-root <book-dir> [--now ISO_TIME] [--json]');
      process.exit(0);
    } else fail(`unknown argument: ${argv[i]}`);
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.projectRoot) fail('missing --project-root');
  const result = resolveAuthoritativeStatus(args.projectRoot, { now: args.now });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  process.exit(result.status === 'blocked' ? 2 : 0);
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

if (require.main === module) main();

module.exports = {
  resolveAuthoritativeStatus,
};
