#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/task-family-migrate.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/追踪/workflow/tasks/wf-old-a" "$BOOK/追踪/workflow/tasks/wf-old-b" "$BOOK/追踪/workflow/tasks/wf-review" "$BOOK/追踪/workflow/tasks/wf-rewrite" "$BOOK/正文/第1卷"
    printf '可信正文，不应被任务迁移改动。\n' > "$BOOK/正文/第1卷/第001章.md"
    cat > "$BOOK/.story-deployed" <<'JSON'
{"bundleName":"novel-assistant","novel_assistant_bundle_id":"bundle-test"}
JSON
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_lineage_tasks() {
    cat > "$BOOK/追踪/workflow/tasks/wf-old-a/task.json" <<'JSON'
{"workflow_id":"wf-old-a","workflow_type":"review_repair","status":"paused","scope":"1-200章","user_goal":"审阅 1-200 章","task_dir":"追踪/workflow/tasks/wf-old-a","lifecycle":{"status":"paused","focus_switched_to":"wf-old-b"}}
JSON
    cat > "$BOOK/追踪/workflow/tasks/wf-old-b/task.json" <<'JSON'
{"workflow_id":"wf-old-b","workflow_type":"review_repair","status":"running","scope":"1-200章","user_goal":"审阅 1-200 章","task_dir":"追踪/workflow/tasks/wf-old-b","lifecycle":{"status":"active","focus_switched_from":"wf-old-a"}}
JSON
    cp "$BOOK/追踪/workflow/tasks/wf-old-b/task.json" "$BOOK/追踪/workflow/current-task.json"
}

@test "migration groups explicit focus lineage into one family without changing prose" {
    write_lineage_tasks
    before="$(shasum -a 256 "$BOOK/正文/第1卷/第001章.md" | awk '{print $1}')"

    run node "$SCRIPT" --project-root "$BOOK" --source novel-assistant --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "task_family_migration_preview"'* ]]

    node "$SCRIPT" --project-root "$BOOK" --source novel-assistant --write --confirm --json > "$TMP_DIR/applied.json"
    after="$(shasum -a 256 "$BOOK/正文/第1卷/第001章.md" | awk '{print $1}')"
    [ "$before" = "$after" ]

    node - "$TMP_DIR/applied.json" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const [outFile,root]=process.argv.slice(2);const out=JSON.parse(fs.readFileSync(outFile,'utf8'));
if(out.status!=='task_family_migration_applied'||out.migrated_task_count!==2) throw new Error(JSON.stringify(out));
const index=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/task-family-index.json'),'utf8'));
if(index.family_ids.length!==1) throw new Error(JSON.stringify(index));
const family=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/families',index.family_ids[0],'family.json'),'utf8'));
if(family.branches.length!==2||family.head_workflow_id!=='wf-old-b') throw new Error(JSON.stringify(family));
NODE
}

@test "migration keeps overlapping tasks with different operations separate and reports the overlap" {
    cat > "$BOOK/追踪/workflow/tasks/wf-review/task.json" <<'JSON'
{"workflow_id":"wf-review","workflow_type":"review_repair","status":"running","scope":"1-200章","user_goal":"审阅人物与钩子","task_dir":"追踪/workflow/tasks/wf-review","lifecycle":{"status":"active"}}
JSON
    cat > "$BOOK/追踪/workflow/tasks/wf-rewrite/task.json" <<'JSON'
{"workflow_id":"wf-rewrite","workflow_type":"review_repair","status":"paused","scope":"1-200章","user_goal":"回炉重写第1-200章","task_dir":"追踪/workflow/tasks/wf-rewrite","lifecycle":{"status":"paused"}}
JSON
    cp "$BOOK/追踪/workflow/tasks/wf-review/task.json" "$BOOK/追踪/workflow/current-task.json"

    node "$SCRIPT" --project-root "$BOOK" --source novel-assistant --write --confirm --json > "$TMP_DIR/applied.json"
    node - "$TMP_DIR/applied.json" "$BOOK" <<'NODE'
const fs=require('fs'),path=require('path');const [outFile,root]=process.argv.slice(2);const out=JSON.parse(fs.readFileSync(outFile,'utf8'));
const index=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/task-family-index.json'),'utf8'));
if(out.ambiguous_overlap_count!==1||index.family_ids.length!==2) throw new Error(JSON.stringify({out,index}));
NODE
}

@test "migration assigns a safe durable task_dir to a legacy full current task and points to it" {
    cat > "$BOOK/追踪/workflow/current-task.json" <<'JSON'
{"workflow_id":"wf-legacy-current","workflow_type":"review_repair","status":"running","scope":"第1章","user_goal":"审阅第1章","lifecycle":{"status":"active"}}
JSON

    run node "$SCRIPT" --project-root "$BOOK" --source novel-assistant --write --confirm --json
    [ "$status" -eq 0 ]

    node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const taskDir = '追踪/workflow/tasks/wf-legacy-current';
const task = JSON.parse(fs.readFileSync(path.join(root, taskDir, 'task.json'), 'utf8'));
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
if (task.task_dir !== taskDir) throw new Error(JSON.stringify(task));
if (pointer.workflow_id !== task.workflow_id || pointer.task_dir !== task.task_dir) throw new Error(JSON.stringify(pointer));
NODE
}

@test "migration resolves a pointer-only current task through its durable authority" {
    mkdir -p "$BOOK/追踪/workflow/tasks/wf-modern"
    cat > "$BOOK/追踪/workflow/tasks/wf-modern/task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-modern","workflow_type":"short_write","status":"running","task_dir":"追踪/workflow/tasks/wf-modern","state_version":47,"task_family_id":"tf-modern","branch_id":"wf-modern","authority_metadata":{"task_source":"task_snapshot","focus_role":"ui_pointer"}}
JSON
    cat > "$BOOK/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-modern","task_dir":"追踪/workflow/tasks/wf-modern","focused_at":"2026-07-17T00:00:00.000Z","state_version":47}
JSON

    run node "$SCRIPT" --project-root "$BOOK" --source novel-assistant --json
    [ "$status" -eq 0 ]

    node - "$output" <<'NODE'
const out = JSON.parse(process.argv[2]);
if (out.candidate_task_count !== 1) throw new Error(JSON.stringify(out));
if (out.already_bound_count !== 1 || out.pending_task_count !== 0) throw new Error(JSON.stringify(out));
if (out.state_conflicts.length !== 0 || out.authority_metadata_changes.length !== 0) throw new Error(JSON.stringify(out));
NODE
}

@test "migration blocks divergent workflow execution state before overwriting either copy" {
    cat > "$BOOK/追踪/workflow/tasks/wf-old-a/task.json" <<'JSON'
{"workflow_id":"wf-old-a","workflow_type":"review_repair","status":"running","scope":"1-200章","user_goal":"审阅 1-200 章","task_dir":"追踪/workflow/tasks/wf-old-a","current_stage":"evidence_scan","machine":{"completed_stages":["range_lock"]},"stage_execution":{"status":"running","batch_id":"002","expected_result_packet":"batch-002.json"},"review_batches":{"completed_count":1}}
JSON
    cp "$BOOK/追踪/workflow/tasks/wf-old-a/task.json" "$BOOK/追踪/workflow/current-task.json"
    node - "$BOOK/追踪/workflow/current-task.json" <<'NODE'
const fs=require('fs');const file=process.argv[2];const value=JSON.parse(fs.readFileSync(file,'utf8'));value.stage_execution.batch_id='003';value.stage_execution.expected_result_packet='batch-003.json';fs.writeFileSync(file,JSON.stringify(value));
NODE

    run node "$SCRIPT" --project-root "$BOOK" --source novel-assistant --write --confirm --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_task_family_migration_state_conflict'* ]]
    grep -q '"batch_id":"002"' "$BOOK/追踪/workflow/tasks/wf-old-a/task.json"
}
