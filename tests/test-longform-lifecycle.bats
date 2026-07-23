#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "longform lifecycle reviews every planning layer before prose" {
  run node - "$REPO/scripts/lib/longform-lifecycle.js" <<'NODE'
const lifecycle = require(process.argv[2]);
const ids = lifecycle.LIFECYCLE_NODES.map(node => node.id);
const required = ['positioning','story_bible','master_outline','master_outline_review','volume_outline','volume_outline_review','stage_detail_outline','detail_outline_review','chapter_brief','brief_review','prose','prose_acceptance','chapter_commit','milestone_review','volume_acceptance','book_acceptance'];
for (const id of required) if (!ids.includes(id)) throw new Error(id);
if (lifecycle.validateLifecycleTransition('master_outline', 'prose').allowed) throw new Error('outline skipped required reviews');
NODE
  [ "$status" -eq 0 ]
}

@test "detail outline review declares its quality result contract and failure return" {
  run node - "$REPO/scripts/lib/workflow-template-registry.js" <<'NODE'
const { BASE_TEMPLATES } = require(process.argv[2]);
const template = BASE_TEMPLATES.long_write;
const review = template.stages.find(x => x.stage_id === 'detail_outline_review');
if (review.result_contract !== 'detail_outline_quality_v1') throw new Error(JSON.stringify(review));
if (review.review_requirement.failure_return !== 'stage_detail_outline') throw new Error(JSON.stringify(review));
NODE
  [ "$status" -eq 0 ]
}

@test "normalizes missing assets and accepts nested asset state" {
  run node - "$REPO/scripts/lib/longform-lifecycle.js" <<'NODE'
const lifecycle = require(process.argv[2]);
const state = lifecycle.normalizeLifecycleState({ assets: {
  positioning: { status: 'accepted' },
  master_outline: 'draft',
  prose: { status: 'needs_review' },
  unknown: 'accepted'
} });
if (state.positioning !== 'accepted') throw new Error(JSON.stringify(state));
if (state.master_outline !== 'draft') throw new Error(JSON.stringify(state));
if (state.prose !== 'needs_review') throw new Error(JSON.stringify(state));
if (state.story_bible !== 'missing') throw new Error(JSON.stringify(state));
if (Object.prototype.hasOwnProperty.call(state, 'unknown')) throw new Error(JSON.stringify(state));
NODE
  [ "$status" -eq 0 ]
}

@test "derives the strictest maturity state" {
  run node - "$REPO/scripts/lib/longform-lifecycle.js" <<'NODE'
const lifecycle = require(process.argv[2]);
const state = lifecycle.normalizeLifecycleState({ positioning: 'accepted', story_bible: 'draft', master_outline: 'needs_review' });
if (lifecycle.deriveMaturity(state) !== 'needs_review') throw new Error(lifecycle.deriveMaturity(state));
const complete = Object.fromEntries(lifecycle.LIFECYCLE_NODES.map(node => [node.id, 'accepted']));
if (lifecycle.deriveMaturity(complete) !== 'accepted') throw new Error('accepted');
complete.story_bible = 'invalidated';
if (lifecycle.deriveMaturity(complete) !== 'invalidated') throw new Error('invalidated');
NODE
  [ "$status" -eq 0 ]
}

@test "returns only the next lifecycle actions" {
  run node - "$REPO/scripts/lib/longform-lifecycle.js" <<'NODE'
const lifecycle = require(process.argv[2]);
const first = lifecycle.nextLifecycleActions({});
if (JSON.stringify(first) !== JSON.stringify(['positioning'])) throw new Error(JSON.stringify(first));
const afterOutline = lifecycle.nextLifecycleActions({
  positioning: 'accepted', story_bible: 'accepted', master_outline: 'accepted'
});
if (JSON.stringify(afterOutline) !== JSON.stringify(['master_outline_review'])) throw new Error(JSON.stringify(afterOutline));
const afterCommit = lifecycle.nextLifecycleActions({
  positioning: 'accepted', story_bible: 'accepted', master_outline: 'accepted',
  master_outline_review: 'accepted', volume_outline: 'accepted', volume_outline_review: 'accepted',
  stage_detail_outline: 'accepted', detail_outline_review: 'accepted', chapter_brief: 'accepted',
  brief_review: 'accepted', prose: 'accepted', prose_acceptance: 'accepted', chapter_commit: 'accepted'
});
if (JSON.stringify(afterCommit) !== JSON.stringify(['milestone_review'])) throw new Error(JSON.stringify(afterCommit));
NODE
  [ "$status" -eq 0 ]
}

@test "reaches volume and book acceptance after milestone review" {
  run node - "$REPO/scripts/lib/longform-lifecycle.js" <<'NODE'
const lifecycle = require(process.argv[2]);
const throughMilestone = Object.fromEntries(lifecycle.LIFECYCLE_NODES.map(node => [node.id, 'accepted']));
throughMilestone.volume_acceptance = 'missing';
throughMilestone.book_acceptance = 'missing';
if (JSON.stringify(lifecycle.nextLifecycleActions(throughMilestone)) !== JSON.stringify(['volume_acceptance'])) throw new Error(JSON.stringify(lifecycle.nextLifecycleActions(throughMilestone)));
throughMilestone.volume_acceptance = 'accepted';
if (JSON.stringify(lifecycle.nextLifecycleActions(throughMilestone)) !== JSON.stringify(['book_acceptance'])) throw new Error(JSON.stringify(lifecycle.nextLifecycleActions(throughMilestone)));
NODE
  [ "$status" -eq 0 ]
}

@test "upstream invalidation takes precedence over post-chapter routing" {
  run node - "$REPO/scripts/lib/longform-lifecycle.js" <<'NODE'
const lifecycle = require(process.argv[2]);
for (const status of ['invalidated', 'needs_recheck']) {
  const state = Object.fromEntries(lifecycle.LIFECYCLE_NODES.map(node => [node.id, 'accepted']));
  state.master_outline_review = status;
  if (JSON.stringify(lifecycle.nextLifecycleActions(state)) !== JSON.stringify(['master_outline_review'])) throw new Error(`${status}: ${JSON.stringify(lifecycle.nextLifecycleActions(state))}`);
}
NODE
  [ "$status" -eq 0 ]
}
