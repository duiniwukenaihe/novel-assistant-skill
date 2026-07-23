'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteText } = require('./workflow-state-store');

const OUTBOX_REL = '追踪/integration/outbox.jsonl';
const EVENT_TYPES = new Set([
  'material_accepted',
  'setting_accepted',
  'outline_accepted',
  'section_accepted',
  'user_feedback_accepted',
  'story_completed',
]);

function appendIntegrationEvent(projectRoot, input = {}) {
  const root = path.resolve(projectRoot);
  const eventType = String(input.event_type || '').trim();
  const workflowId = String(input.workflow_id || '').trim();
  const projectId = String(input.project_id || '').trim();
  const artifactPath = normalizeRelative(input.artifact_path);
  const artifactDigest = String(input.artifact_digest || '').trim();
  if (!EVENT_TYPES.has(eventType) || !workflowId || !projectId || !artifactPath || !artifactDigest) {
    const error = new Error('integration event requires supported event_type, workflow_id, project_id, artifact_path, and artifact_digest');
    error.code = 'INTEGRATION_EVENT_INVALID';
    throw error;
  }
  const evidenceHash = sha256(JSON.stringify({ eventType, workflowId, projectId, artifactPath, artifactDigest }));
  const eventId = sha256(`${workflowId}\0${eventType}\0${projectId}\0${artifactPath}\0${artifactDigest}`);
  const event = {
    schema_version: '1.0.0',
    event_id: eventId,
    event_type: eventType,
    workflow_id: workflowId,
    project_id: projectId,
    project_title: String(input.project_title || '').trim(),
    artifact_path: artifactPath,
    artifact_digest: artifactDigest,
    evidence_hash: evidenceHash,
    summary: String(input.summary || '').trim().slice(0, 1000),
    tags: stringArray(input.tags),
    occurred_at: String(input.occurred_at || new Date().toISOString()),
  };
  const file = path.join(root, OUTBOX_REL);
  const rows = readRows(file);
  const existing = rows.find((item) => String((item || {}).event_id || '') === eventId);
  if (existing) return { status: 'duplicate_ignored', path: OUTBOX_REL, event: existing };
  rows.push(event);
  atomicWriteText(file, `${rows.map((item) => JSON.stringify(item)).join('\n')}\n`);
  return { status: 'appended', path: OUTBOX_REL, event };
}

function readRows(file) {
  if (!fs.existsSync(file)) return [];
  const text = fs.readFileSync(file, 'utf8').trim();
  if (!text) return [];
  return text.split(/\r?\n/).filter(Boolean).map((line, index) => {
    try { return JSON.parse(line); }
    catch (error) { throw new Error(`invalid integration outbox row ${index + 1}: ${error.message}`); }
  });
}

function normalizeRelative(value) {
  const normalized = String(value || '').trim().replace(/\\/g, '/').replace(/^\.\//, '');
  if (!normalized || normalized.startsWith('/') || normalized.split('/').includes('..')) return '';
  return normalized;
}
function stringArray(value) { return [...new Set((Array.isArray(value) ? value : []).map((item) => String(item || '').trim()).filter(Boolean))]; }
function sha256(value) { return `sha256:${crypto.createHash('sha256').update(String(value || ''), 'utf8').digest('hex')}`; }

module.exports = { EVENT_TYPES, OUTBOX_REL, appendIntegrationEvent };
