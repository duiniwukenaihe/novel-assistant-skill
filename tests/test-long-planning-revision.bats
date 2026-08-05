#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "volume review selects only the completed producer attempt for the current volume work unit" {
  node - "$REPO/scripts/lib/long-planning-revision.js" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const workflowId = 'wf-two-volumes';
const taskDir = '追踪/workflow/tasks/wf-two-volumes';

function workUnit(stageId, scope) {
  return `wu-${crypto.createHash('sha256').update([workflowId, stageId, scope].join('|')).digest('hex').slice(0, 16)}`;
}

function addAttempt(scope, volume, attemptId) {
  const target = `大纲/${volume}/卷纲.md`;
  const result = `${taskDir}/result-history/${attemptId}.json`;
  const workUnitId = workUnit('volume_outline', scope);
  fs.mkdirSync(path.join(root, path.dirname(target)), { recursive: true });
  fs.writeFileSync(path.join(root, target), `# ${volume}\n`);
  fs.mkdirSync(path.join(root, path.dirname(result)), { recursive: true });
  fs.writeFileSync(path.join(root, result), JSON.stringify({
    workflow_id: workflowId,
    stage_id: 'volume_outline',
    stage_attempt_id: attemptId,
    work_unit_id: workUnitId,
    step_status: 'completed',
    verification_result: 'pass',
    result_write_set: [target],
  }));
  return { stage_id: 'volume_outline', status: 'completed', stage_attempt_id: attemptId, work_unit_id: workUnitId, accepted_result_packet: result };
}

const current = addAttempt('第2卷', '第2卷', 'sa-volume-2');
const other = addAttempt('第1卷', '第1卷', 'sa-volume-1');
const task = {
  workflow_id: workflowId,
  current_stage: 'volume_outline_review',
  stage_execution: { stage_id: 'volume_outline_review', work_unit_scope: '第2卷' },
  stage_attempt_history: [other, current],
  result_history: { stage_id: 'volume_outline', path: other.accepted_result_packet },
};
const authority = api.authoritativePlanningTargets(root, task, 'volume_outline');
assert.equal(authority.status, 'ready');
assert.deepEqual(authority.targets, ['大纲/第2卷/卷纲.md']);
assert.equal(authority.source, 'accepted_predecessor_result');
NODE
}

@test "volume review rejects a packet whose immutable attempt identity does not match history" {
  node - "$REPO/scripts/lib/long-planning-revision.js" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const workflowId = 'wf-packet-mismatch';
const scope = '第2卷';
const workUnitId = `wu-${crypto.createHash('sha256').update([workflowId, 'volume_outline', scope].join('|')).digest('hex').slice(0, 16)}`;
const target = '大纲/第2卷/卷纲.md';
const result = '追踪/workflow/tasks/wf-packet-mismatch/result-history/volume.json';
fs.mkdirSync(path.join(root, '大纲/第2卷'), { recursive: true });
fs.writeFileSync(path.join(root, target), '# 第2卷\n');
fs.mkdirSync(path.join(root, path.dirname(result)), { recursive: true });
fs.writeFileSync(path.join(root, result), JSON.stringify({
  workflow_id: workflowId,
  stage_id: 'volume_outline',
  stage_attempt_id: 'sa-tampered',
  work_unit_id: workUnitId,
  step_status: 'completed',
  verification_result: 'pass',
  result_write_set: [target],
}));
const task = {
  workflow_id: workflowId,
  current_stage: 'volume_outline_review',
  stage_execution: { stage_id: 'volume_outline_review', work_unit_scope: scope },
  stage_attempt_history: [{
    stage_id: 'volume_outline', status: 'completed', stage_attempt_id: 'sa-authoritative', work_unit_id: workUnitId, accepted_result_packet: result,
  }],
};
assert.equal(api.authoritativePlanningTargets(root, task, 'volume_outline').status, 'blocked_long_planning_target_recovery_source_missing');
NODE
}

@test "confirmed volume producer prefers the digest-bound safe plan target over unrelated history" {
  node - "$REPO/scripts/lib/long-planning-revision.js" "$TMP_DIR" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const api = require(process.argv[2]);
const root = process.argv[3];
const target = '大纲/第2卷/卷纲.md';
fs.mkdirSync(path.join(root, '大纲/第2卷'), { recursive: true });
fs.writeFileSync(path.join(root, target), '# 第2卷\n');
const plan = {
  version: 'planning_revision_plan_v1',
  review_stage: 'volume_outline_review',
  producer_stage: 'volume_outline',
  summary: '修正第2卷阶段边界。',
  requirements: ['保留已确认主线。'],
  targets: [target],
};
const digest = api.planDigest(plan);
const task = {
  workflow_id: 'wf-confirmed-volume',
  current_stage: 'volume_outline',
  stage_execution: { stage_id: 'volume_outline', work_unit_scope: '第2卷' },
  planning_revision: {
    status: 'accepted_for_execution',
    plan,
    plan_digest: digest,
    accepted_plan_digest: digest,
  },
  stage_attempt_history: [],
};
const authority = api.authoritativePlanningTargets(root, task, 'volume_outline');
assert.equal(authority.status, 'ready');
assert.deepEqual(authority.targets, [target]);
assert.equal(authority.source, 'accepted_planning_revision');

task.planning_revision.accepted_plan_digest = 'sha256:' + '0'.repeat(64);
assert.equal(api.authoritativePlanningTargets(root, task, 'volume_outline').status, 'blocked_long_planning_target_recovery_source_missing');
NODE
}
