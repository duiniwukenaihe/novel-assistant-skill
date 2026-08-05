#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "V3 author choice cannot render before committed pending action" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const result={kind:'needs_author_choice',code:'choose_plan',stage_id:'planning',question:'选择方案',options:[
  {action_id:'accept',label:'采用方案'},
  {action_id:'chat',label:'进入 Chat 修改'}
]};
const prepared=api.prepareInteraction({workflow_id:'wf-v3',state_version:1},result);
if (!prepared.pending_action || prepared.visible_response) process.exit(1);
const committed={workflow_id:'wf-v3',state_version:2,pending_action:prepared.pending_action};
const visible=api.renderCommittedInteraction(committed);
if (!visible || !visible.text.includes('1. 采用方案')) process.exit(2);
const consumed=api.consumeBinding(committed,'1');
if (consumed.action_id!=='accept') process.exit(3);
try {
  api.consumeBinding({ ...committed, pending_action:{ ...committed.pending_action, status:'resolved' } },'1');
  process.exit(4);
} catch (error) {
  if (!/pending_action_not_pending/.test(error.message)) process.exit(5);
}
NODE
  [ "$status" -eq 0 ]
}

@test "V3 arbiter assigns stable numbers 1..N only inside the arbiter" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const contracts=require(process.argv[2].replace(/interaction-arbiter\.js$/, 'contracts.js'));
const raw={
  kind:'needs_author_choice',code:'choose_three',stage_id:'planning',question:'选哪个',
  options:[
    {action_id:'a',label:'甲'},
    {action_id:'b',label:'乙'},
    {action_id:'c',label:'丙'},
  ],
};
// The validated stage result must NOT carry numbers (Task 1 contract).
const validated=contracts.validateStageResult(raw);
if (validated.options.some((o)=>'number' in o)) process.exit(1);
const prepared=api.prepareInteraction({workflow_id:'wf-num',state_version:4},validated);
const numbers=prepared.pending_action.options.map((o)=>o.number);
const stable=numbers.map((o,i)=>o===i+1).every(Boolean);
if (!stable) process.exit(2);
if (prepared.pending_action.options.some((o)=>!Object.isFrozen(o))) process.exit(3);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 binding hashes workflow_id plus target committed state_version plus question plus options including number" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const crypto=require('crypto');
const api=require(process.argv[2]);
const raw=[
  {action_id:'accept',label:'采用方案'},
  {action_id:'chat',label:'进入 Chat 修改'},
];
const result={kind:'needs_author_choice',code:'choose_plan',stage_id:'planning',question:'选择方案',options:raw};
// Target committed version is Number(task.state_version)+1 == 8.
// The canonical option representation carries the arbiter-assigned number.
const prepared=api.prepareInteraction({workflow_id:'wf-hash',state_version:7},result);
const options=prepared.pending_action.options.map((o)=>({action_id:o.action_id,label:o.label,number:o.number}));
const binding={workflow_id:'wf-hash',state_version:8,question:'选择方案',options};
const expected=crypto.createHash('sha256').update(JSON.stringify(binding)).digest('hex');
if (prepared.pending_action.state_version!==8) process.exit(1);
if (prepared.pending_action.visible_choice_hash!==expected) process.exit(2);
// A different question or option set must produce a different hash.
const other=api.prepareInteraction({workflow_id:'wf-hash',state_version:7},{...result,question:'换个问法'});
if (other.pending_action.visible_choice_hash===expected) process.exit(3);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 render and consume reject a pending action transplanted into another workflow_id" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const result={kind:'needs_author_choice',code:'choose_plan',stage_id:'planning',question:'选择方案',options:[
  {action_id:'accept',label:'采用方案'},
  {action_id:'chat',label:'进入 Chat 修改'},
]};
const prepared=api.prepareInteraction({workflow_id:'wf-origin',state_version:1},result);
// Transplant: same state_version, but the task now claims a foreign workflow_id.
const transplanted={workflow_id:'wf-foreign',state_version:2,pending_action:prepared.pending_action};
let threw=false;
try {
  api.renderCommittedInteraction(transplanted);
} catch (e) {
  threw=true;
  if (!/binding_workflow_mismatch/.test(e.message)) process.exit(1);
}
if (!threw) process.exit(2);
threw=false;
try {
  api.consumeBinding(transplanted,'1');
} catch (e) {
  threw=true;
  if (!/binding_workflow_mismatch/.test(e.message)) process.exit(3);
}
if (!threw) process.exit(4);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 render and consume reject tampering of a persisted option.number" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const result={kind:'needs_author_choice',code:'choose_plan',stage_id:'planning',question:'选择方案',options:[
  {action_id:'accept',label:'采用方案'},
  {action_id:'chat',label:'进入 Chat 修改'},
]};
const prepared=api.prepareInteraction({workflow_id:'wf-num',state_version:1},result);
const committed={workflow_id:'wf-num',state_version:2,pending_action:prepared.pending_action};
// Swap the two options' numbers but keep visible_choice_hash unchanged,
// so input '1' would otherwise resolve to action_id 'chat'.
const tamperedOptions=committed.pending_action.options.map((option,index)=>({
  ...option,
  number: index===0?2:1,
}));
const tampered={
  ...committed,
  pending_action:{...committed.pending_action,options:tamperedOptions},
};
let threw=false;
try {
  api.renderCommittedInteraction(tampered);
} catch (e) {
  threw=true;
  if (!/binding_hash_mismatch/.test(e.message)) process.exit(1);
}
if (!threw) process.exit(2);
threw=false;
try {
  api.consumeBinding(tampered,'1');
} catch (e) {
  threw=true;
  if (!/binding_hash_mismatch/.test(e.message)) process.exit(3);
}
if (!threw) process.exit(4);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 consume rejects tampered visible_choice_hash and tampered state_version" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const result={kind:'needs_author_choice',code:'choose_plan',stage_id:'planning',question:'选择方案',options:[
  {action_id:'accept',label:'采用方案'},
  {action_id:'chat',label:'进入 Chat 修改'},
]};
const prepared=api.prepareInteraction({workflow_id:'wf-tamper',state_version:1},result);
const committed={workflow_id:'wf-tamper',state_version:2,pending_action:prepared.pending_action};
// Tamper the hash: should be rejected on consume and on render.
let threw=false;
try {
  api.consumeBinding({...committed,pending_action:{...committed.pending_action,visible_choice_hash:'deadbeef'}},'1');
} catch (e) {
  threw=true;
  if (!/binding_hash_mismatch/.test(e.message)) process.exit(1);
}
if (!threw) process.exit(2);
// Render must also reject a tampered hash.
threw=false;
try {
  api.renderCommittedInteraction({...committed,pending_action:{...committed.pending_action,visible_choice_hash:'deadbeef'}});
} catch (e) {
  threw=true;
  if (!/binding_hash_mismatch/.test(e.message)) process.exit(3);
}
if (!threw) process.exit(4);
// Tamper the committed state_version to diverge from the stored version.
threw=false;
try {
  api.consumeBinding({...committed,state_version:99},'1');
} catch (e) {
  threw=true;
  if (!/binding_version_mismatch/.test(e.message)) process.exit(5);
}
if (!threw) process.exit(6);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 consume rejects replay of an already resolved action" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const result={kind:'needs_author_choice',code:'choose_plan',stage_id:'planning',question:'选择方案',options:[
  {action_id:'accept',label:'采用方案'},
  {action_id:'chat',label:'进入 Chat 修改'},
]};
const prepared=api.prepareInteraction({workflow_id:'wf-replay',state_version:1},result);
const committed={workflow_id:'wf-replay',state_version:2,pending_action:prepared.pending_action};
const resolved={...committed,pending_action:{...committed.pending_action,status:'resolved'}};
let threw=false;
try {
  api.consumeBinding(resolved,'1');
} catch (e) {
  threw=true;
  if (!/pending_action_not_pending/.test(e.message)) process.exit(1);
}
if (!threw) process.exit(2);
// Render must also refuse a resolved action.
threw=false;
try {
  api.renderCommittedInteraction(resolved);
} catch (e) {
  threw=true;
  if (!/pending_action_not_pending/.test(e.message)) process.exit(3);
}
if (!threw) process.exit(4);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 prepareInteraction returns null pending_action for non-author-choice results" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const completed=api.prepareInteraction({workflow_id:'wf',state_version:1},{kind:'completed',code:'done',stage_id:'planning'});
if (completed.pending_action!==null || completed.visible_response) process.exit(1);
NODE
  [ "$status" -eq 0 ]
}

@test "V3 renderCommittedInteraction returns frozen Arbiter-owned binding metadata" {
  run node - "$REPO/scripts/lib/workflow-v3/interaction-arbiter.js" <<'NODE'
const api=require(process.argv[2]);
const result={kind:'needs_author_choice',code:'choose_plan',stage_id:'planning',question:'选择方案',options:[
  {action_id:'accept',label:'采用方案'},
  {action_id:'chat',label:'进入 Chat 修改'},
]};
const prepared=api.prepareInteraction({workflow_id:'wf-bind',state_version:1},result);
const committed={workflow_id:'wf-bind',state_version:2,pending_action:prepared.pending_action};
const visible=api.renderCommittedInteraction(committed);
if (!visible || !visible.text) process.exit(1);
// binding must be present and frozen.
if (!visible.binding) process.exit(2);
if (!Object.isFrozen(visible.binding)) process.exit(3);
// binding must contain exactly the four Arbiter-owned fields, nothing else.
const keys=Object.keys(visible.binding).sort();
const expected=['pending_action_id','state_version','visible_choice_hash','workflow_id'];
if (JSON.stringify(keys)!==JSON.stringify(expected)) process.exit(4);
// the bound values must equal the committed pending action's own fields.
const b=visible.binding;
if (b.workflow_id!==committed.workflow_id) process.exit(5);
if (b.state_version!==committed.state_version) process.exit(6);
if (b.pending_action_id!==committed.pending_action.id) process.exit(7);
// the rendered hash must equal the committed pending action's hash.
if (b.visible_choice_hash!==committed.pending_action.visible_choice_hash) process.exit(8);
NODE
  [ "$status" -eq 0 ]
}
