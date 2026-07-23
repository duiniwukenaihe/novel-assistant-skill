#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/evidence"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "narrative batch planner respects boundaries, risk, budget, and primary coverage" {
    node - "$REPO" <<'NODE'
const path = require('path');
const { planReviewBatches, validateBatchCoverage } = require(path.join(process.argv[2], 'scripts/lib/review-batch-planner.js'));

const dimensions = ['plot', 'hooks', 'character', 'canon', 'prose'];
const chapter = (order, volume, chars, tags = [], boundaryTags = []) => ({
  chapterKey: `v${String(volume).padStart(2, '0')}-c${String(order).padStart(3, '0')}`,
  globalDraftOrder: order,
  volume: `第${volume}卷`,
  chars,
  staticRiskTags: tags,
  boundaryTags,
});

const boundaryPlan = planReviewBatches({
  chapters: [
    chapter(1, 1, 4000), chapter(2, 1, 4000), chapter(3, 1, 4000),
    chapter(4, 2, 4000, [], ['climax']), chapter(5, 2, 4000), chapter(6, 2, 4000),
  ],
  parentScope: '1-6',
  requiredDimensions: dimensions,
  budgetPolicy: { host_context_chars: 80000, max_source_context_ratio: 0.18, boundary_window_chapters: 1 },
});
if (boundaryPlan.batches[0].range !== '1-3') throw new Error(`volume boundary was not preferred: ${JSON.stringify(boundaryPlan.batches)}`);
if (boundaryPlan.batches[0].boundary_reason !== 'volume_boundary') throw new Error('expected volume boundary reason');
if (boundaryPlan.batches[0].boundary_context.after[0] !== 'v02-c004') throw new Error('missing forward boundary context');
if (boundaryPlan.batches[1].boundary_context.before[0] !== 'v01-c003') throw new Error('missing backward boundary context');
validateBatchCoverage({ batches: boundaryPlan.batches, chapterKeys: boundaryPlan.chapters.map((item) => item.chapterKey) });

const riskPlan = planReviewBatches({
  chapters: [chapter(1, 1, 9000, ['ai-pattern', 'degeneration']), chapter(2, 1, 9000, ['punctuation']), chapter(3, 1, 9000)],
  parentScope: '1-3',
  requiredDimensions: dimensions,
  budgetPolicy: { host_context_chars: 100000, max_source_context_ratio: 0.18 },
});
if (riskPlan.batches[0].range !== '1-1') throw new Error(`dense risk chapter was not isolated: ${JSON.stringify(riskPlan.batches)}`);

const sparsePlan = planReviewBatches({
  chapters: Array.from({ length: 10 }, (_, index) => chapter(index + 1, 1, 500)),
  parentScope: '1-10',
  requiredDimensions: dimensions,
  budgetPolicy: { host_context_chars: 80000, max_source_context_ratio: 0.18 },
});
if (sparsePlan.batches.length !== 1 || sparsePlan.batches[0].range !== '1-10') throw new Error('sparse chapters should form a larger batch');

const fallbackPlan = planReviewBatches({
  chapters: Array.from({ length: 8 }, (_, index) => chapter(index + 1, 1, 3000)),
  parentScope: '1-8',
  requiredDimensions: dimensions,
  budgetPolicy: {},
});
if (fallbackPlan.budget_policy.source_budget_origin !== 'conservative_fallback') throw new Error('unknown host budget did not use the conservative fallback');
if (fallbackPlan.batches.some((batch) => batch.primary_chapter_keys.length > 4)) throw new Error('conservative fallback exceeded its source budget');
validateBatchCoverage({ batches: fallbackPlan.batches, chapterKeys: fallbackPlan.chapters.map((item) => item.chapterKey) });

const smallVolumePlan = planReviewBatches({
  chapters: [chapter(1, 1, 500), chapter(2, 2, 500)],
  parentScope: '1-2',
  requiredDimensions: dimensions,
  budgetPolicy: { host_context_chars: 80000, max_source_context_ratio: 0.18 },
});
if (smallVolumePlan.batches.length !== 2 || smallVolumePlan.batches[0].boundary_reason !== 'volume_boundary') {
  throw new Error(`small volume boundary was crossed: ${JSON.stringify(smallVolumePlan.batches)}`);
}

for (const [label, oversized] of [
  ['raw', [chapter(1, 1, 19000)]],
  ['risk-weighted', [chapter(1, 1, 16000, ['ai-pattern', 'degeneration'])]],
]) {
  try {
    planReviewBatches({ chapters: oversized, parentScope: '1-1', requiredDimensions: dimensions, budgetPolicy: { host_context_chars: 100000, max_source_context_ratio: 0.18 } });
    throw new Error(`${label} oversized chapter was planned without disposition`);
  } catch (error) {
    if (error.code !== 'REVIEW_BATCH_PLAN_OVERSIZED') throw error;
  }
}
NODE
}

@test "review batch planner CLI returns controlled errors and writes a plan" {
    printf '%s\n' '{"chapterKey":"v01-c001","globalDraftOrder":1,"volume":"第1卷","chars":800,"staticRiskTags":[],"boundaryTags":[]}' > "$PROJECT/evidence/chapter-evidence.jsonl"

    run node "$REPO/scripts/review-batch-plan.js" "$PROJECT" --scope 1-1 --budget-policy '{' --json
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid --budget-policy JSON"* ]]

    run node "$REPO/scripts/review-batch-plan.js" "$PROJECT" --scope 1-1 --budget-policy --json
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing value for --budget-policy"* ]]

    run node "$REPO/scripts/review-batch-plan.js" "$PROJECT" --scope 1-1 --write --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"batches"'* ]]
    [ -f "$PROJECT/evidence/review-batch-plan.json" ]
}

@test "review batch planner persists deterministic dispatch plans from evidence signals" {
    printf '%s\n' \
      '{"chapterKey":"v01-c001","globalDraftOrder":1,"volume":"第1卷","chars":800,"staticRiskTags":["character_drift"],"boundaryTags":[]}' \
      '{"chapterKey":"v01-c002","globalDraftOrder":2,"volume":"第1卷","chars":800,"staticRiskTags":["prose"],"boundaryTags":[]}' \
      > "$PROJECT/evidence/chapter-evidence.jsonl"

    node "$REPO/scripts/review-batch-plan.js" "$PROJECT" --scope 1-2 --dimensions plot,canon,character,prose --agents-available story-explorer,consistency-checker,narrative-writer --write --json > "$TMP_DIR/dispatch-plan.json"

    node - "$TMP_DIR/dispatch-plan.json" "$PROJECT/evidence/review-batch-plan.json" <<'NODE'
const fs=require('fs');
const [out,persisted]=process.argv.slice(2).map((file)=>JSON.parse(fs.readFileSync(file,'utf8')));
if (JSON.stringify(out)!==JSON.stringify(persisted)) throw new Error('written dispatch plan differs from output');
const batch=out.batches[0];
if (!Array.isArray(batch.evidence_signals) || !batch.evidence_signals.includes('character_drift') || !batch.evidence_signals.includes('prose')) throw new Error(JSON.stringify(batch));
if (!batch.dispatch_plan || batch.dispatch_plan.retryPolicy!=='missing_dimension_once') throw new Error(JSON.stringify(batch));
const roles=batch.dispatch_plan.roles.map((role)=>role.subagent_type);
for (const role of ['story-explorer','consistency-checker','narrative-writer']) if (!roles.includes(role)) throw new Error(JSON.stringify(batch.dispatch_plan));
if (roles.includes('character-designer')) throw new Error('missing optional role must be deferred instead of forcing solo fallback');
if (!batch.dispatch_plan.deferredDimensions.includes('character')) throw new Error(JSON.stringify(batch.dispatch_plan));
NODE
}

@test "review create passes host and runtime context budgets through to the persisted plan" {
    node - "$REPO" "$TMP_DIR" <<'NODE'
const fs=require('fs');const path=require('path');
const repo=process.argv[2];const root=process.argv[3];
for (const name of ['host','runtime','fallback']) {
  const project=path.join(root,name,'正文'); fs.mkdirSync(project,{recursive:true});
  for (let order=1; order<=8; order+=1) fs.writeFileSync(path.join(project,`chapter${String(order).padStart(3,'0')}.md`), 'x'.repeat(3000));
}
NODE

    node "$REPO/scripts/workflow-state-machine.js" create --workflow-type review_repair --project-root "$TMP_DIR/host" --scope 1-8 --host-context-chars 100000 --json > "$TMP_DIR/host.json"
    node "$REPO/scripts/workflow-state-machine.js" create --workflow-type review_repair --project-root "$TMP_DIR/runtime" --scope 1-8 --runtime-context-chars 50000 --json > "$TMP_DIR/runtime.json"
    node "$REPO/scripts/workflow-state-machine.js" create --workflow-type review_repair --project-root "$TMP_DIR/fallback" --scope 1-8 --json > "$TMP_DIR/fallback.json"

    node - "$TMP_DIR/host.json" "$TMP_DIR/runtime.json" "$TMP_DIR/fallback.json" <<'NODE'
const fs=require('fs');
const plans=process.argv.slice(2).map((file)=>{const created=JSON.parse(fs.readFileSync(file,'utf8'));return JSON.parse(fs.readFileSync(`${created.task.book_root}/${created.task.review_plan_path}`,'utf8'));});
const [host,runtime,fallback]=plans;
if(host.budget_policy.source_budget_origin!=='host_actual' || host.budget_policy.source_budget_chars!==18000) throw new Error(JSON.stringify(host.budget_policy));
if(runtime.budget_policy.source_budget_origin!=='runtime_estimate' || runtime.budget_policy.source_budget_chars!==9000) throw new Error(JSON.stringify(runtime.budget_policy));
if(fallback.budget_policy.source_budget_origin!=='conservative_fallback' || fallback.budget_policy.source_budget_chars!==160000 || fallback.budget_policy.conservative_max_primary_chapters!==50) throw new Error(JSON.stringify(fallback.budget_policy));
if(host.batches.length===runtime.batches.length) throw new Error('host and runtime budgets did not change the batch shape');
NODE
}
