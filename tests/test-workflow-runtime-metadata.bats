#!/usr/bin/env bats
# tests/test-workflow-runtime-metadata.bats
# Project-neutral regression: runtime-owned entry-check metadata that an
# update/inbox check rewrites after a stage snapshot is captured must NOT be
# counted as unauthorized longform stage creative writes.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/workflow-state-machine.js"
    export WORKFLOW_TASK_FIXTURE="$REPO/tests/helpers/workflow-task-fixture.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

apply_long_write_v2_result() {
    node - "$SCRIPT" "$1" "${2:-}" "${3:-completed}" "${4-pass}" <<'NODE'
const fs=require('fs'), path=require('path'), cp=require('child_process');
const [script,root,declaredFile,stepStatus,verificationResult]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const lifecycleNode=(task.lifecycle_graph.nodes||[]).find(node=>node.id===task.current_stage);
if(!lifecycleNode) throw new Error(`missing lifecycle node ${task.current_stage}`);
const failedResult=['blocked','failed'].includes(String(stepStatus||'').toLowerCase())||/(?:fail|reject|block)/i.test(String(verificationResult||''));
const result={
  workflow_id:task.workflow_id,
  workflow_type:'long_write',
  stage_id:task.current_stage,
  step_id:task.current_step,
  owner_module:lifecycleNode.owner_module,
  lifecycle_node:lifecycleNode.id,
  asset_target:lifecycleNode.asset_target,
  review_requirement:lifecycleNode.review_requirement,
  step_status:stepStatus,
  outputs:[],
  changed_files:declaredFile?[declaredFile]:[],
  evidence:[],
  verification_result:verificationResult,
  checkpoint_state:{stage:task.current_stage},
  output_health_result:'pass',
  asset_revision:{status:'verified',asset_id:lifecycleNode.asset_target.id},
  review_decision:lifecycleNode.review_requirement.required?'accepted':'not_applicable',
  downstream_effects:[],
  lifecycle_transition_request:failedResult
    ? {action:'return',target:String((lifecycleNode.review_requirement||{}).failure_return||lifecycleNode.id)}
    : {action:'advance',target:lifecycleNode.id},
  result_write_set:declaredFile?[declaredFile]:[]
};
const packet=path.resolve(root,task.stage_execution.expected_result_packet);
fs.mkdirSync(path.dirname(packet),{recursive:true});
fs.writeFileSync(packet,JSON.stringify(result,null,2));
const out=cp.spawnSync(process.execPath,[script,'apply-result','--project-root',root,'--result',packet,'--json'],{encoding:'utf8'});
if(out.status) process.stderr.write(out.stdout||'');
process.stdout.write(out.stdout||''); process.stderr.write(out.stderr||''); process.exit(out.status||0);
NODE
}

@test "runtime-owned entry metadata rewritten after snapshot is not a stage write violation" {
    book="$TMP_DIR/runtime-metadata-not-creative"
    node "$SCRIPT" create --workflow-type long_write --project-root "$book" --user-goal "开一本新书" --json >/dev/null

    # Resolve the first pending action so a stage starts and its write snapshot
    # is captured.
    node - "$SCRIPT" "$book" <<'NODE'
const cp=require('child_process');
const [script,root]=process.argv.slice(2);
const task=require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(root);
const pending=task.pending_action||{};
const out=cp.spawnSync(process.execPath,[script,'resolve-action','--project-root',root,'--input','1','--pending-action-id',String(pending.id||''),'--visible-choice-hash',String(pending.visible_choice_hash||''),'--state-version',String(task.state_version),'--book-root',root,'--json'],{encoding:'utf8'});
if(out.status!==0) throw new Error(out.stdout||out.stderr);
NODE

    # Emulate a durable snapshot captured by an older runtime, before these
    # metadata paths were added to the fresh-snapshot exclusion list. The
    # compatibility classifier must still ignore them during apply-result.
    node - "$book" <<'NODE'
const fs = require('fs');
const root = process.argv[2];
const helper = require(process.env.WORKFLOW_TASK_FIXTURE);
const taskFile = helper.focusedTaskFile(root);
const task = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
const excluded = (((task.stage_execution || {}).write_snapshot || {}).excluded_paths || []);
task.stage_execution.write_snapshot.excluded_paths = excluded.filter((entry) => ![
  '追踪/workflow/task-index.json',
  '追踪/workflow/update-environment-choice.json',
].includes(entry));
fs.writeFileSync(taskFile, `${JSON.stringify(task, null, 2)}\n`);
NODE

    # Simulate the entry/update check rewriting runtime-owned metadata AFTER
    # the stage write snapshot was captured. These two files are owned by the
    # runtime (workflow-task-inbox.js and novel-assistant-update-check.js), not
    # by stage creative work, and must not appear in the stage's actual file
    # changes.
    mkdir -p "$book/追踪/workflow"
    printf '%s\n' '{"task_cards":[],"rewritten_at":"2026-08-05T00:00:00.000Z"}' > "$book/追踪/workflow/task-index.json"
    printf '%s\n' '{"confirmed_at":"2026-08-05T00:00:00.000Z"}' > "$book/追踪/workflow/update-environment-choice.json"

    # Produce the declared, authorized creative output as well. Without this
    # write the test would fail for declaration/actual mismatch before it ever
    # exercised the runtime-metadata exclusion under test.
    mkdir -p "$book/设定"
    printf '%s\n' '# Story bible' > "$book/设定/故事圣经.md"

    # Apply a legitimate first-stage result that declares exactly its one
    # authorized creative file. Before the fix this is blocked because the
    # runtime metadata files leak into actual_changed_files.
    run apply_long_write_v2_result "$book" "设定/故事圣经.md" completed pass
    [ "$status" -eq 0 ]
    [[ "$output" != *'blocked_result_write_set_violation'* ]]
}
