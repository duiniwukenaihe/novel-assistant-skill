#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "partial agent failure retains healthy evidence and schedules only one missing-dimension retry" {
    node - "$REPO" <<'NODE'
const path=require('path');
const { acceptReviewResults }=require(path.join(process.argv[2],'scripts/lib/review-role-policy.js'));
const { buildReviewBatchState, completeReviewBatch }=require(path.join(process.argv[2],'scripts/lib/review-batch-state.js'));
const dispatchPlan={
  mode:'agent_dispatch',
  roles:[
    {subagent_type:'story-explorer',dimensions:['plot']},
    {subagent_type:'narrative-writer',dimensions:['prose']},
    {subagent_type:'consistency-checker',dimensions:['canon']},
  ],
  deferredDimensions:[], retryPolicy:'missing_dimension_once',
};
const result={role_results:[
  {subagent_type:'story-explorer',status:'accepted',chapter_keys:['c001'],dimensions:['plot'],evidence_paths:['evidence/explorer.json'],output_health:'healthy'},
  {subagent_type:'narrative-writer',status:'failed'},
  {subagent_type:'consistency-checker',status:'accepted',chapter_keys:['c001'],dimensions:['canon'],evidence_paths:['evidence/canon.json'],output_health:'healthy'},
]};
const accepted=acceptReviewResults({dispatchPlan,primaryChapterKeys:['c001'],result});
if (accepted.status!=='partial_evidence') throw new Error(JSON.stringify(accepted));
if (JSON.stringify(accepted.acceptedDimensions)!==JSON.stringify(['canon','plot'])) throw new Error(JSON.stringify(accepted));
if (JSON.stringify(accepted.unresolvedDimensions)!==JSON.stringify(['prose'])) throw new Error(JSON.stringify(accepted));
if (JSON.stringify(accepted.retryRoles)!==JSON.stringify(['narrative-writer'])) throw new Error(JSON.stringify(accepted));

const state=buildReviewBatchState('wf-1','1-1','追踪/workflow/tasks/wf-1',{parent_scope:'1-1',batches:[{id:'batch-001',range:'1-1'}]});
const transition=completeReviewBatch(state,'001','追踪/workflow/tasks/wf-1/result-packets/evidence_scan.batch-001.partial.json',accepted);
if (transition.status!=='partial_evidence_retry') throw new Error(JSON.stringify(transition));
const batch=state.batches[0];
if (batch.status==='completed' || state.aggregate_status==='completed') throw new Error(JSON.stringify(state));
if (batch.accepted_result_packet.indexOf('.partial.json')===-1) throw new Error(JSON.stringify(batch));
if (JSON.stringify(batch.unresolved_dimensions)!==JSON.stringify(['prose'])) throw new Error(JSON.stringify(batch));

const exhausted=completeReviewBatch(state,'001','retry.json',accepted);
if (exhausted.status!=='blocked_review_batch_retry_exhausted') throw new Error(JSON.stringify(exhausted));
NODE
}

@test "result acceptance rejects unhealthy or uncovered claimed dimensions" {
    node - "$REPO" <<'NODE'
const path=require('path');
const { acceptReviewResults }=require(path.join(process.argv[2],'scripts/lib/review-role-policy.js'));
const dispatchPlan={mode:'agent_dispatch',roles:[{subagent_type:'consistency-checker',dimensions:['canon']}],deferredDimensions:[],retryPolicy:'missing_dimension_once'};
for (const result of [
  {role_results:[{subagent_type:'consistency-checker',status:'accepted',chapter_keys:[],dimensions:['canon'],evidence_paths:['evidence/canon.json'],output_health:'healthy'}]},
  {role_results:[{subagent_type:'consistency-checker',status:'accepted',chapter_keys:['c001'],dimensions:['canon'],evidence_paths:['evidence/canon.json'],output_health:'failed'}]},
]) {
  const accepted=acceptReviewResults({dispatchPlan,primaryChapterKeys:['c001'],result});
  if (accepted.status!=='partial_evidence' || !accepted.unresolvedDimensions.includes('canon')) throw new Error(JSON.stringify(accepted));
}
NODE
}
