'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { appendIntegrationEvent } = require('./integration-outbox');
const { readShortProjectState } = require('./short-project-state');

const SHORT_WORKFLOWS = new Set(['short_write', 'short_startup', 'private_short_startup']);

function recordAcceptedShortFeedback(projectRoot, task = {}, result = {}) {
  const stageId = String(result.stage_id || '');
  const feedback = task.pending_feedback || {};
  const expressionRepair = stageId === 'section_repair_loop'
    && String(((task.short_feedback_impact || {}).impact_level) || '') === 'expression_only';
  const planningPatch = stageId === 'feedback_apply_patch';
  if (!SHORT_WORKFLOWS.has(String(task.workflow_type || ''))
    || String(result.step_status || '') !== 'completed'
    || (!expressionRepair && !planningPatch)
    || !String(feedback.text || '').trim()) {
    return { status: 'not_applicable' };
  }

  const root = path.resolve(projectRoot);
  const project = readShortProjectState(root) || {};
  const artifactPath = firstExistingArtifact(root, result);
  if (!String(project.project_id || '') || !artifactPath) {
    return {
      status: 'deferred',
      reason: !String(project.project_id || '') ? 'short_project_identity_missing' : 'feedback_artifact_missing',
    };
  }

  try {
    return appendIntegrationEvent(root, {
      event_type: 'user_feedback_accepted',
      workflow_id: String(task.workflow_id || ''),
      project_id: String(project.project_id || ''),
      project_title: String(project.project_title || ''),
      artifact_path: artifactPath,
      artifact_digest: hashFile(path.join(root, artifactPath)),
      summary: `已执行反馈：${String(feedback.text || '').trim()}`,
      tags: [
        'short_write',
        'user_feedback',
        String(feedback.feedback_id || ''),
        String(((task.short_feedback_impact || {}).impact_level) || ''),
        stageId,
      ],
    });
  } catch (error) {
    return { status: 'deferred', reason: 'integration_event_write_failed', message: String(error.message || error) };
  }
}

function firstExistingArtifact(root, result) {
  const candidates = [
    ...(Array.isArray(result.changed_files) ? result.changed_files : []),
    ...(Array.isArray(result.outputs) ? result.outputs : []),
    ...(Array.isArray(result.changed_assets) ? result.changed_assets : []),
    result.result_packet_path,
  ];
  for (const candidate of candidates) {
    const relative = normalizeRelative(candidate);
    if (!relative || relative === '追踪/integration/outbox.jsonl') continue;
    const file = path.resolve(root, relative);
    if (!file.startsWith(`${root}${path.sep}`) || !fs.existsSync(file) || !fs.statSync(file).isFile()) continue;
    return relative;
  }
  return '';
}

function normalizeRelative(value) {
  const normalized = String(value || '').trim().replace(/\\/g, '/').replace(/^\.\//, '');
  if (!normalized || normalized.startsWith('/') || normalized.split('/').includes('..')) return '';
  return normalized;
}

function hashFile(file) {
  return `sha256:${crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')}`;
}

module.exports = { recordAcceptedShortFeedback };
