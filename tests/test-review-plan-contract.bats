#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "review plan contract validates, writes atomically, and rejects a digest mismatch" {
    node - "$REPO" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const repo = process.argv[2];
const project = process.argv[3];
const contract = require(path.join(repo, 'scripts/lib/review-plan-contract.js'));
const task = { workflow_id: 'wf-review-contract', task_dir: '追踪/workflow/tasks/wf-review-contract' };
const plan = {
  schemaVersion: '2.0.0',
  workflow_id: task.workflow_id,
  parent_scope: '1-200',
  required_dimensions: ['plot', 'hooks', 'character', 'canon', 'prose'],
  source_identity: {},
  budget_policy: {},
  batches: [{
    id: 'batch-001',
    range: '1-3',
    primary_chapter_keys: ['v01-c001', 'v01-c002', 'v01-c003'],
    source_chars: 9000,
    weighted_source_chars: 9000,
    source_budget_chars: 12000,
    risk_density: 0,
    boundary_reason: 'volume_boundary',
    boundary_context: { before: [], after: ['v02-c004'] },
    expected_dimensions: ['plot', 'hooks', 'character', 'canon', 'prose'],
  }],
  coverage_policy: { require_all_chapters: true, allow_unexplained_deferred: false },
};
contract.validateReviewPlan(plan);
const written = contract.writeReviewPlan(project, task, plan);
if (!written.path || !written.digest) throw new Error('review plan write did not return path and digest');
task.review_plan_path = written.path;
task.review_plan_digest = written.digest;
const loaded = contract.readReviewPlan(project, task);
if (loaded.digest !== written.digest || loaded.plan.batches[0].id !== 'batch-001') throw new Error('review plan read mismatch');
fs.writeFileSync(path.join(project, task.review_plan_path), JSON.stringify({ ...plan, budget_policy: { changed: true } }) + '\n');
try {
  contract.readReviewPlan(project, task);
  throw new Error('digest mismatch was accepted');
} catch (error) {
  if (error.code !== 'REVIEW_PLAN_STALE') throw error;
}

NODE
}

@test "review plan contract rejects batch entries without persisted narrative evidence" {
    node - "$REPO" <<'NODE'
const path = require('path');
const contract = require(path.join(process.argv[2], 'scripts/lib/review-plan-contract.js'));
const plan = {
  schemaVersion: '2.0.0', workflow_id: 'wf-contract-shape', parent_scope: '1-1',
  required_dimensions: ['plot'], source_identity: {}, budget_policy: {},
  batches: [{ id: 'batch-001', range: '1-1' }],
  coverage_policy: { require_all_chapters: true, allow_unexplained_deferred: false },
};
try {
  contract.validateReviewPlan(plan);
  throw new Error('plan without narrative batch evidence was accepted');
} catch (error) {
  if (error.code !== 'REVIEW_PLAN_INVALID') throw error;
}
NODE
}
