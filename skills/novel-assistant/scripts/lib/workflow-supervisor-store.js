'use strict';

const fs = require('fs');
const path = require('path');
const { acquireNamedProjectLock, appendJsonl, atomicWriteJson } = require('./workflow-state-store');

const STATE_RELATIVE_PATH = path.join('追踪', 'workflow', 'supervisor-state.json');
const EVENTS_RELATIVE_PATH = path.join('追踪', 'workflow', 'supervisor-events.jsonl');

function supervisorPaths(projectRoot) {
  const root = path.resolve(projectRoot);
  return {
    root,
    state: path.join(root, STATE_RELATIVE_PATH),
    events: path.join(root, EVENTS_RELATIVE_PATH),
  };
}

function readSupervisorState(projectRoot) {
  try {
    return JSON.parse(fs.readFileSync(supervisorPaths(projectRoot).state, 'utf8'));
  } catch {
    return null;
  }
}

function writeSupervisorState(projectRoot, state) {
  const paths = supervisorPaths(projectRoot);
  atomicWriteJson(paths.state, state);
  return paths.state;
}

function appendSupervisorEvent(projectRoot, event) {
  const paths = supervisorPaths(projectRoot);
  appendJsonl(paths.events, { at: new Date().toISOString(), ...event });
  return paths.events;
}

function acquireSupervisorLease(projectRoot, owner, ttlMs) {
  const releaseLock = acquireNamedProjectLock(projectRoot, {
    relativeDir: path.join('追踪', 'workflow'),
    lockName: '.supervisor.lock',
    owner: owner || 'workflow-supervisor',
    ttlMs: Number(ttlMs) || 10 * 60 * 1000,
    errorCode: 'SUPERVISOR_LOCKED',
    errorLabel: 'workflow supervisor lease',
  });
  let released = false;
  return () => {
    if (released) return false;
    released = true;
    releaseLock();
    return true;
  };
}

module.exports = {
  EVENTS_RELATIVE_PATH,
  STATE_RELATIVE_PATH,
  acquireSupervisorLease,
  appendSupervisorEvent,
  readSupervisorState,
  supervisorPaths,
  writeSupervisorState,
};
