'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { atomicWriteText } = require('./workflow-state-store');

const ACTION_STATUS = {
  open: 'open',
  advance: 'warming',
  warm: 'warming',
  close: 'paid_off',
  defer: 'deferred',
  drop: 'dropped',
};

function projectPromiseDeltas(projectRoot, commit) {
  const root = path.resolve(projectRoot);
  const deltas = normalizePromiseDeltas(commit && commit.promise_deltas);
  const stateFile = path.join(root, '追踪', 'schema', 'promises.jsonl');
  const eventFile = path.join(root, '追踪', 'story-system', 'promise-events.jsonl');
  if (!deltas.length) return { status: 'not_required', projected_count: 0, stateFile, eventFile };

  const states = readJsonl(stateFile);
  const events = readJsonl(eventFile);
  const stateById = new Map(states.map(item => [String(item.id || ''), item]));
  const knownEvents = new Map(events.map(item => [String(item.event_id || ''), item]));
  const createdEvents = [];

  deltas.forEach((delta, index) => {
    const eventId = eventIdentity(commit, delta, index);
    if (knownEvents.has(eventId)) {
      const recorded = knownEvents.get(eventId);
      if (recorded && recorded.state_after && typeof recorded.state_after === 'object') {
        stateById.set(delta.id, recorded.state_after);
      }
      return;
    }
    const previous = stateById.get(delta.id) || null;
    if (!previous && delta.action !== 'open') {
      throw projectionFailure('blocked_promise_transition_missing', `${delta.id} 尚未打开，不能执行 ${delta.action}`);
    }
    if (previous && previous.status === 'paid_off') {
      throw projectionFailure('blocked_promise_already_closed', `${delta.id} 已回收，不能重复执行 ${delta.action}`);
    }
    const next = applyDelta(previous, delta, commit);
    stateById.set(delta.id, next);
    createdEvents.push({
      schemaVersion: '1.0.0',
      event_id: eventId,
      promise_id: delta.id,
      action: delta.action,
      from_status: previous ? previous.status : null,
      to_status: next.status,
      chapter_commit_id: String(commit.commit_id || ''),
      workflow_id: String(commit.workflow_id || ''),
      volume: String(commit.volume || ''),
      chapter: Number(commit.chapter || 0),
      plot_unit_id: String(delta.plotUnitId || ''),
      state_after: next,
      recorded_at: String(commit.accepted_at || new Date().toISOString()),
    });
  });

  if (createdEvents.length || deltas.length) {
    fs.mkdirSync(path.dirname(stateFile), { recursive: true });
    fs.mkdirSync(path.dirname(eventFile), { recursive: true });
    // The immutable event ledger is the recovery authority. If the process stops
    // before the state write, replay reads state_after and repairs promises.jsonl.
    if (createdEvents.length) atomicWriteText(eventFile, renderJsonl([...events, ...createdEvents]));
    atomicWriteText(stateFile, renderJsonl([...stateById.values()].sort((a, b) => a.id.localeCompare(b.id))));
  }
  return {
    status: createdEvents.length ? 'projected' : 'current',
    projected_count: createdEvents.length,
    promise_ids: deltas.map(item => item.id),
    stateFile,
    eventFile,
  };
}

function normalizePromiseDeltas(value) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw projectionFailure('blocked_invalid_promise_delta', 'promise_deltas 必须是数组');
  const ids = new Set();
  return value.map((input) => {
    if (!input || typeof input !== 'object' || Array.isArray(input)) {
      throw projectionFailure('blocked_invalid_promise_delta', 'promise delta 必须是对象');
    }
    const id = String(input.id || '').trim();
    const action = String(input.action || '').trim().toLowerCase();
    if (!/^P-[A-Za-z0-9_\-一-鿿]+$/.test(id)) {
      throw projectionFailure('blocked_invalid_promise_delta', 'promise id 必须使用 P- 开头的稳定标识');
    }
    if (!ACTION_STATUS[action]) throw projectionFailure('blocked_invalid_promise_delta', `${id} 的 action 无效：${action}`);
    if (ids.has(id)) throw projectionFailure('blocked_invalid_promise_delta', `同一次提交不能重复声明 promise：${id}`);
    ids.add(id);
    const description = String(input.description || '').trim();
    if (action === 'open' && !description) throw projectionFailure('blocked_invalid_promise_delta', `${id} 打开时必须提供 description`);
    return {
      id,
      action,
      type: String(input.type || 'foreshadowing').trim(),
      description,
      expectedPayoffRange: String(input.expectedPayoffRange || '').trim(),
      payoffIn: String(input.payoffIn || '').trim(),
      owner: String(input.owner || 'story-architect').trim(),
      risk: String(input.risk || '').trim(),
      plotUnitId: String(input.plotUnitId || '').trim(),
    };
  });
}

function applyDelta(previous, delta, commit) {
  const unit = String(commit.volume || '') === '短篇正文' ? '节' : '章';
  const chapterLabel = `第${String(Number(commit.chapter || 0)).padStart(3, '0')}${unit}`;
  const next = {
    ...(previous || {}),
    id: delta.id,
    type: delta.type || (previous && previous.type) || 'foreshadowing',
    introducedIn: (previous && previous.introducedIn) || chapterLabel,
    status: ACTION_STATUS[delta.action],
    expectedPayoffRange: delta.expectedPayoffRange || (previous && previous.expectedPayoffRange) || '',
    owner: delta.owner || (previous && previous.owner) || 'story-architect',
    description: delta.description || (previous && previous.description) || delta.id,
    risk: delta.risk || (previous && previous.risk) || '',
    plotUnitId: delta.plotUnitId || (previous && previous.plotUnitId) || '',
    lastCommitId: String(commit.commit_id || ''),
    lastUpdatedIn: chapterLabel,
    updatedAt: String(commit.accepted_at || new Date().toISOString()),
  };
  if (delta.action === 'close') next.payoffIn = delta.payoffIn || chapterLabel;
  return next;
}

function eventIdentity(commit, delta, index) {
  const source = JSON.stringify({ commit_id: commit.commit_id, delta, index });
  return `promise-event.${crypto.createHash('sha256').update(source).digest('hex').slice(0, 20)}`;
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split(/\r?\n/).map(line => line.trim()).filter(Boolean).map((line, index) => {
    try {
      return JSON.parse(line);
    } catch (_) {
      throw projectionFailure('blocked_invalid_promise_ledger', `${file}:${index + 1} 不是有效 JSON`);
    }
  });
}

function renderJsonl(rows) {
  return rows.length ? `${rows.map(row => JSON.stringify(row)).join('\n')}\n` : '';
}

function projectionFailure(status, message) {
  const error = new Error(message);
  error.status = status;
  return error;
}

module.exports = { normalizePromiseDeltas, projectPromiseDeltas };
