#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE="$REPO/scripts/workflow-state-machine.js"
    FINALIZER="$REPO/scripts/long-planning-stage-finalize.js"
    export WORKFLOW_TASK_FIXTURE="$REPO/tests/helpers/workflow-task-fixture.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

prepare_running_detail_revision() {
    local book="$1"
    node "$STATE" create --workflow-type long_write --project-root "$book" --user-goal "修订阶段细纲" --json >/dev/null
    node - "$book" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
const canonical='大纲/第1卷/细纲_第001章.md',staged='追踪/workflow/staging/security/001-细纲_第001章.md';
for(const [rel,content] of [[canonical,'# 旧细纲\n'],[staged,'# 修订细纲\n']]){
  const file=path.join(root,rel);fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,content);
}
task.current_stage='stage_detail_outline';task.current_step='stage_detail_outline';task.status='running';
task.detail_outline_review_failure={failed_targets:[canonical]};
task.stage_execution={
  status:'running',stage_id:'stage_detail_outline',step_id:'stage_detail_outline',stage_attempt_id:'sa-current',planning_stage_attempt_id:'sa-current',work_unit_id:'wu-current',
  expected_result_packet:`${task.task_dir}/result-packets/stage_detail_outline.result.json`,planning_targets:[{canonical,staged}],canonical_write_set:[canonical],write_set:[staged],revision_targets:[canonical],
};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
}

bind_runner_fixture() {
    local book="$1"
    local last_attempt="$2"
    local packet_attempt="$3"
    local packet_work_unit="$4"
    node - "$book" "$last_attempt" "$packet_attempt" "$packet_work_unit" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2],lastAttempt=process.argv[3],packetAttempt=process.argv[4],packetWorkUnit=process.argv[5],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root),execution=task.stage_execution;
const runnerRel=`${task.task_dir}/runner-packets/stage_detail_outline.security.run.json`,runnerFile=path.join(root,runnerRel);
fs.mkdirSync(path.dirname(runnerFile),{recursive:true});
fs.writeFileSync(runnerFile,JSON.stringify({workflow_id:task.workflow_id,stage_id:execution.stage_id,stage_attempt_id:packetAttempt,work_unit_id:packetWorkUnit,run_id:'run-security-current',expected_result_packet:execution.expected_result_packet},null,2)+'\n');
task.runtime_guard=task.runtime_guard||{};
task.runtime_guard.last_runner_attempt={workflow_id:task.workflow_id,stage_id:execution.stage_id,stage_attempt_id:lastAttempt,work_unit_id:execution.work_unit_id,run_id:'run-security-current',runner_packet_path:runnerRel,expected_result_packet:execution.expected_result_packet};
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
}

prepare_accepted_master_result() {
    local book="$1"
    node "$STATE" create --workflow-type long_write --project-root "$book" --user-goal "复核总纲" --json >/dev/null
    node - "$book" <<'NODE'
const crypto=require('crypto'),fs=require('fs'),path=require('path');
const root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
const target='大纲/总纲.md',targetFile=path.join(root,target);fs.mkdirSync(path.dirname(targetFile),{recursive:true});fs.writeFileSync(targetFile,'# 已接受总纲\n');
const hash=`sha256:${crypto.createHash('sha256').update(fs.readFileSync(targetFile)).digest('hex')}`,attempt='sa-master-accepted',commitId='planning-security-master';
const packetRel=`${task.task_dir}/result-packets/master_outline.result.json`,packetFile=path.join(root,packetRel);fs.mkdirSync(path.dirname(packetFile),{recursive:true});
fs.writeFileSync(packetFile,JSON.stringify({workflow_id:task.workflow_id,workflow_type:'long_write',stage_id:'master_outline',stage_attempt_id:attempt,step_status:'completed',verification_result:'pass',changed_files:[target],result_write_set:[target],outputs:[{path:target,sha256:hash}],chapter_commit:{accepted_commit_id:commitId}},null,2)+'\n');
const commitFile=path.join(root,'追踪/story-system/commits',`${commitId}.json`);fs.mkdirSync(path.dirname(commitFile),{recursive:true});
fs.writeFileSync(commitFile,JSON.stringify({commit_id:commitId,transaction_id:'tx-planning-security-master',status:'accepted',workflow_id:task.workflow_id,provenance:{stage_attempt_id:attempt},artifacts:[{target,after_hash:hash}]},null,2)+'\n');
task.current_stage='master_outline_review';task.current_step='master_outline_review';task.result_history={stage_id:'master_outline',path:packetRel};
task.stage_attempt_history=[{stage_id:'master_outline',stage_attempt_id:attempt,status:'completed',accepted_result_packet:packetRel,expected_result_packet:packetRel}];
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
}

@test "planning finalizer trusts only exact current managed-runner attempt and work unit" {
    prepare_running_detail_revision "$TMP_DIR/base"

    cp -R "$TMP_DIR/base" "$TMP_DIR/packet-attempt"
    bind_runner_fixture "$TMP_DIR/packet-attempt" sa-current sa-stale wu-current
    run node "$FINALIZER" --project-root "$TMP_DIR/packet-attempt" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$TMP_DIR/packet-attempt")" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'long_planning_runner_binding_invalid'* ]]

    cp -R "$TMP_DIR/base" "$TMP_DIR/packet-work-unit"
    bind_runner_fixture "$TMP_DIR/packet-work-unit" sa-current sa-current wu-stale
    run node "$FINALIZER" --project-root "$TMP_DIR/packet-work-unit" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$TMP_DIR/packet-work-unit")" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'long_planning_runner_binding_invalid'* ]]

    cp -R "$TMP_DIR/base" "$TMP_DIR/empty-last-attempt"
    bind_runner_fixture "$TMP_DIR/empty-last-attempt" '' sa-current wu-current
    run node "$FINALIZER" --project-root "$TMP_DIR/empty-last-attempt" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$TMP_DIR/empty-last-attempt")" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'long_planning_runner_binding_invalid'* ]]

    cp -R "$TMP_DIR/base" "$TMP_DIR/exact"
    bind_runner_fixture "$TMP_DIR/exact" sa-current sa-current wu-current
    run node "$FINALIZER" --project-root "$TMP_DIR/exact" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$TMP_DIR/exact")" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'long_planning_commit_ready'* ]]

    cp -R "$TMP_DIR/base" "$TMP_DIR/active-lease"
    bind_runner_fixture "$TMP_DIR/active-lease" sa-current sa-current wu-current
    node - "$TMP_DIR/active-lease" <<'NODE'
const fs=require('fs'),root=process.argv[2],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
task.runtime_guard.runner_lease={...task.runtime_guard.last_runner_attempt,expires_at:new Date(Date.now()+60000).toISOString()};
delete task.runtime_guard.last_runner_attempt;
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
    run node "$FINALIZER" --project-root "$TMP_DIR/active-lease" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$TMP_DIR/active-lease")" --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"host_execution_mode":"managed_runner"'* ]]

    for mutation in lease-stage lease-result runner-run-id; do
        cp -R "$TMP_DIR/active-lease" "$TMP_DIR/$mutation"
        node - "$TMP_DIR/$mutation" "$mutation" <<'NODE'
const fs=require('fs'),path=require('path'),root=process.argv[2],mutation=process.argv[3],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root);
if(mutation==='lease-stage') task.runtime_guard.runner_lease.stage_id='volume_outline';
if(mutation==='lease-result') task.runtime_guard.runner_lease.expected_result_packet=`${task.task_dir}/result-packets/unrelated.result.json`;
if(mutation==='runner-run-id') {
  const runnerFile=path.join(root,task.runtime_guard.runner_lease.runner_packet_path),runner=JSON.parse(fs.readFileSync(runnerFile,'utf8'));
  runner.run_id='run-forged';fs.writeFileSync(runnerFile,JSON.stringify(runner,null,2)+'\n');
}
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');
NODE
        run node "$FINALIZER" --project-root "$TMP_DIR/$mutation" --workflow-id "$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$TMP_DIR/$mutation")" --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'long_planning_runner_binding_invalid'* ]]
    done
}

@test "planning finalizer reuses only the accepted producer result at its exact review boundary" {
    prepare_accepted_master_result "$TMP_DIR/valid"
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$TMP_DIR/valid")"
    run node "$FINALIZER" --project-root "$TMP_DIR/valid" --workflow-id "$workflow_id" --apply --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'long_planning_already_applied'* ]]

    for mutation in later-stage packet-stage provenance artifact-target artifact-hash; do
        cp -R "$TMP_DIR/valid" "$TMP_DIR/$mutation"
        node - "$TMP_DIR/$mutation" "$mutation" <<'NODE'
const fs=require('fs'),path=require('path');
const root=process.argv[2],mutation=process.argv[3],fixture=require(process.env.WORKFLOW_TASK_FIXTURE),taskFile=fixture.focusedTaskFile(root),task=fixture.readFocusedTask(root),packetFile=path.join(root,task.result_history.path),packet=JSON.parse(fs.readFileSync(packetFile,'utf8')),commitFile=path.join(root,'追踪/story-system/commits',`${packet.chapter_commit.accepted_commit_id}.json`),commit=JSON.parse(fs.readFileSync(commitFile,'utf8'));
if(mutation==='later-stage') task.current_stage='volume_outline_review';
if(mutation==='packet-stage') packet.stage_id='volume_outline';
if(mutation==='provenance') commit.provenance.stage_attempt_id='sa-unrelated';
if(mutation==='artifact-target') commit.artifacts[0].target='大纲/第1卷/卷纲.md';
if(mutation==='artifact-hash') commit.artifacts[0].after_hash='sha256:'+'0'.repeat(64);
fs.writeFileSync(taskFile,JSON.stringify(task,null,2)+'\n');fs.writeFileSync(packetFile,JSON.stringify(packet,null,2)+'\n');fs.writeFileSync(commitFile,JSON.stringify(commit,null,2)+'\n');
NODE
        run node "$FINALIZER" --project-root "$TMP_DIR/$mutation" --workflow-id "$workflow_id" --apply --json
        [ "$status" -eq 2 ]
        [[ "$output" == *'stage_action_not_applicable'* ]]
        [[ "$output" != *'long_planning_already_applied'* ]]
    done
}

@test "planning finalizer rejects changed staging after the same attempt already has an accepted commit" {
    book="$TMP_DIR/accepted-attempt-conflict"
    prepare_running_detail_revision "$book"
    mkdir -p "$book/追踪/story-system"
    printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$book/追踪/story-system/write-policy.json"
    bind_runner_fixture "$book" sa-current sa-current wu-current
    workflow_id="$(node -e "process.stdout.write(require(process.env.WORKFLOW_TASK_FIXTURE).readFocusedTask(process.argv[1]).workflow_id)" "$book")"

    run node "$FINALIZER" --project-root "$book" --workflow-id "$workflow_id" --apply --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *'long_planning_result_ready'* ]]
    commit_count="$(find "$book/追踪/story-system/commits" -name '*.json' -type f | wc -l | tr -d ' ')"
    canonical_hash="$(shasum -a 256 "$book/大纲/第1卷/细纲_第001章.md" | awk '{print $1}')"

    printf '%s\n' '# 同一 attempt 的冲突修订' > "$book/追踪/workflow/staging/security/001-细纲_第001章.md"
    run node "$FINALIZER" --project-root "$book" --workflow-id "$workflow_id" --apply --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'long_planning_accepted_commit_conflict'* ]]
    [ "$commit_count" = "$(find "$book/追踪/story-system/commits" -name '*.json' -type f | wc -l | tr -d ' ')" ]
    [ "$canonical_hash" = "$(shasum -a 256 "$book/大纲/第1卷/细纲_第001章.md" | awk '{print $1}')" ]
}
