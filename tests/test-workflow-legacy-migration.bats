#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MIGRATE="$REPO/scripts/workflow-legacy-migrate.js"
    INBOX="$REPO/scripts/workflow-task-inbox.js"
    STATE_MACHINE="$REPO/scripts/workflow-state-machine.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_trusted_chapters() {
    node - "$PROJECT" <<'NODE'
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
for (let chapter=1; chapter<=8; chapter+=1) {
  const file=path.join(root,'正文',`chapter${String(chapter).padStart(3,'0')}.md`);
  fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file,`# 第${chapter}章\n\n可信的叙事正文 ${chapter}。\n`);
}
NODE
}

write_legacy_fixed_review() {
    local stage="${1:-evidence_scan}"
    local risk="${2:-medium}"
    node - "$PROJECT" "$stage" "$risk" <<'NODE'
const fs=require('fs');
const path=require('path');
const [root,stage,risk]=process.argv.slice(2);
const workflowId='wf-20260710133214-review_repair';
const taskDir=`追踪/workflow/tasks/${workflowId}`;
const task={
  workflow_id:workflowId,
  workflow_type:'review_repair',
  migration_source:'worldwonderer/oh-story-claudecode',
  result_contract_version:1,
  task_dir:taskDir,
  scope:'1-8',
  user_goal:'修复本书 1-8 章的连贯性与钩子',
  status:'running',
  risk_level:risk,
  current_stage:stage,
  current_step:stage,
  review_batches:{
    batch_size:50,
    agent_count:4,
    agents:['plot','character','canon','prose'],
    batches:[{id:'legacy-001',range:'1-8',status:'pending'}]
  }
};
fs.mkdirSync(path.join(root,taskDir),{recursive:true});
fs.writeFileSync(path.join(root,taskDir,'task.json'),JSON.stringify(task,null,2)+'\n');
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify({
  workflow_id:workflowId,
  task_dir:taskDir
},null,2)+'\n');
fs.writeFileSync(path.join(root,'.story-deployed'),JSON.stringify({
  source_repository:'worldwonderer/oh-story-claudecode'
},null,2)+'\n');
NODE
}

task_digest() {
    shasum -a 256 "$PROJECT/追踪/workflow/current-task.json" "$PROJECT/追踪/workflow/tasks/wf-20260710133214-review_repair/task.json"
}

@test "explicit oh-story migration previews, confirms, archives, and records its upstream source" {
    write_trusted_chapters
    write_legacy_fixed_review

    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const task=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
if (pointer.workflow_type || pointer.user_goal || pointer.workflow_id!==task.workflow_id || pointer.task_dir!==task.task_dir) throw new Error(JSON.stringify({pointer,task}));
NODE

    before="$(task_digest)"
    creative_before="$(find "$PROJECT/正文" -type f -exec shasum -a 256 {} \; | sort)"
    status=0
    node "$MIGRATE" --project-root "$PROJECT" --json > "$TMP_DIR/no-source.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_migration_source_required"' "$TMP_DIR/no-source.json"

    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --json > "$TMP_DIR/preview.json"
    grep -q '"status": "migration_preview"' "$TMP_DIR/preview.json"
    grep -q '"classification": "auto-safe"' "$TMP_DIR/preview.json"
    grep -q 'legacy_fixed_review_batches' "$TMP_DIR/preview.json"
    [ "$before" = "$(task_digest)" ]
    [ ! -e "$PROJECT/追踪/workflow/migration-inventory.json" ]

    node "$INBOX" --project-root "$PROJECT" --json > "$TMP_DIR/pre-migration-inbox.json"
    grep -q '"candidateCount": 1' "$TMP_DIR/pre-migration-inbox.json"
    grep -q '"migration_task_count": 1' "$TMP_DIR/pre-migration-inbox.json"
    ! grep -q '"id": "wf-20260710133214-review_repair"' "$TMP_DIR/pre-migration-inbox.json"

    status=0
    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --json > "$TMP_DIR/unconfirmed.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_migration_confirmation_required"' "$TMP_DIR/unconfirmed.json"
    [ "$before" = "$(task_digest)" ]

    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --workflow-id wf-20260710133214-review_repair --json > "$TMP_DIR/applied.json"
    grep -q '"status": "migration_applied"' "$TMP_DIR/applied.json"
    grep -q 'legacy_fixed_review_batches' "$TMP_DIR/applied.json"
    [ -f "$PROJECT/追踪/workflow/archived/wf-20260710133214-review_repair.legacy-snapshot.json" ]
    [ "$creative_before" = "$(find "$PROJECT/正文" -type f -exec shasum -a 256 {} \; | sort)" ]

    node - "$PROJECT" <<'NODE'
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const oldId='wf-20260710133214-review_repair';
const pointer=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
const current=JSON.parse(fs.readFileSync(path.join(root,pointer.task_dir,'task.json'),'utf8'));
const archived=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/archived',`${oldId}.json`),'utf8'));
if (pointer.workflow_type || pointer.user_goal || pointer.workflow_id!==current.workflow_id || pointer.task_dir!==current.task_dir) throw new Error('current task must remain a pointer to the successor');
if (current.workflow_id===oldId || current.workflow_type!=='review_repair') throw new Error('successor task was not activated');
if (current.user_goal!=='修复本书 1-8 章的连贯性与钩子' || current.scope!=='1-8') throw new Error('goal or scope was not retained');
if (current.lifecycle.previous_workflow_id!==oldId || current.migration.reason!=='legacy_fixed_review_batches' || current.migration.source!=='worldwonderer/oh-story-claudecode') throw new Error('migration lineage is incomplete');
if (!current.review_plan_path || !current.review_plan_digest) throw new Error('successor did not persist a review plan reference');
const plan=JSON.parse(fs.readFileSync(path.join(root,current.review_plan_path),'utf8'));
if (!plan.source_identity.digest || plan.batches.some((batch)=>!Array.isArray(batch.primary_chapter_keys) || !batch.source_budget_chars)) throw new Error('successor does not use evidence-backed adaptive batches');
if (plan.budget_policy.batch_size===50 || (plan.budget_policy.runtime_guard_token_estimate || {}).agent_count===4) throw new Error('legacy fixed batch settings leaked into successor');
if (archived.lifecycle.status!=='superseded' || archived.lifecycle.superseded_by!==current.workflow_id) throw new Error('predecessor was not archived with lineage');
NODE

    node "$INBOX" --project-root "$PROJECT" --write --json > "$TMP_DIR/inbox.json"
    grep -q "${PROJECT##*/}" "$TMP_DIR/inbox.json"
    ! grep -q '"id": "wf-20260710133214-review_repair"' "$TMP_DIR/inbox.json"
    grep -q '"workflow_type": "review_repair"' "$TMP_DIR/inbox.json"
}

@test "source-bound migration ignores non-oh-story runtime records without writes" {
    node - "$PROJECT" <<'NODE'
const fs=require('fs');
const path=require('path');
const root=process.argv[2];
const tasks=[
  {workflow_id:'wf-legacy-write',workflow_type:'long_write',task_dir:'追踪/workflow/tasks/wf-legacy-write',status:'running',current_stage:'prose',scope:'第1章',user_goal:'续写第一章'},
  {workflow_id:'wf-legacy-analyze',workflow_type:'long_analyze',task_dir:'追踪/workflow/tasks/wf-legacy-analyze',status:'running',current_stage:'stage_2',scope:'全书',user_goal:'继续拆文'}
];
for (const task of tasks) {
  fs.mkdirSync(path.join(root,task.task_dir),{recursive:true});
  fs.writeFileSync(path.join(root,task.task_dir,'task.json'),JSON.stringify(task,null,2)+'\n');
}
fs.mkdirSync(path.join(root,'追踪/workflow'),{recursive:true});
fs.writeFileSync(path.join(root,'追踪/workflow/current-task.json'),JSON.stringify(tasks[0],null,2)+'\n');
fs.writeFileSync(path.join(root,'追踪/review-state.json'),JSON.stringify({status:'running',scope:'1-8'},null,2)+'\n');
NODE
    before="$(find "$PROJECT/追踪" -type f -exec shasum -a 256 {} \; | sort)"

    status=0
    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --json > "$TMP_DIR/non-review.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_migration_confirmation_required"' "$TMP_DIR/non-review.json"
    grep -q '"items": \[\]' "$TMP_DIR/non-review.json"
    grep -q '"migrated_count": 0' "$TMP_DIR/non-review.json"
    [ "$before" = "$(find "$PROJECT/追踪" -type f ! -name migration-inventory.json -exec shasum -a 256 {} \; | sort)" ]
    [ ! -d "$PROJECT/追踪/workflow/archived" ]
}

@test "high-risk legacy review is confirm-required and never auto-writes" {
    write_trusted_chapters
    write_legacy_fixed_review execute_repair high
    before="$(task_digest)"

    status=0
    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --json > "$TMP_DIR/high-risk.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_migration_confirmation_required"' "$TMP_DIR/high-risk.json"
    grep -q '"classification": "confirm-required"' "$TMP_DIR/high-risk.json"
    grep -q '"migrated_count": 0' "$TMP_DIR/high-risk.json"
    [ "$before" = "$(task_digest)" ]
    [ ! -e "$PROJECT/追踪/workflow/archived/wf-20260710133214-review_repair.legacy-snapshot.json" ]
}

@test "legacy fixed review fails closed when chapter evidence is untrusted" {
    write_legacy_fixed_review
    mkdir -p "$PROJECT/正文"
    printf '# 迁移来源存在，但章节证据不可用。\n' > "$PROJECT/正文/README.md"
    mkdir -p "$PROJECT/追踪/schema"
    printf '%s\n' '{"chapterNo":1,"globalDraftOrder":1,"draftPath":"正文/chapter001.md"}' > "$PROJECT/追踪/schema/chapters.jsonl"
    before="$(task_digest)"

    status=0
    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --workflow-id wf-20260710133214-review_repair --json > "$TMP_DIR/untrusted.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_review_plan_evidence_incomplete"' "$TMP_DIR/untrusted.json"
    [ "$before" = "$(task_digest)" ]
    [ ! -d "$PROJECT/追踪/workflow/archived" ]
    [ ! -d "$PROJECT/evidence" ]
}

@test "migration inventories each active or durable legacy workflow once and upgrades a selected non-current task" {
    write_trusted_chapters
    write_legacy_fixed_review
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const workflowId='wf-durable-legacy-review';
const taskDir=`追踪/workflow/tasks/${workflowId}`;
const task={
  workflow_id:workflowId, workflow_type:'review_repair', result_contract_version:1,
  migration_source:'worldwonderer/oh-story-claudecode',
  task_dir:taskDir, scope:'1-8', user_goal:'迁移非当前审阅任务', status:'running',
  current_stage:'evidence_scan', current_step:'evidence_scan', risk_level:'medium',
  review_batches:{batch_size:50,agent_count:4,agents:['plot','character','canon','prose'],batches:[{id:'legacy-001',range:'1-8',status:'pending'}]}
};
fs.mkdirSync(path.join(root,taskDir),{recursive:true});
fs.writeFileSync(path.join(root,taskDir,'task.json'),JSON.stringify(task,null,2)+'\n');
NODE

    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --json > "$TMP_DIR/preview-all.json"
    node - "$TMP_DIR/preview-all.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const ids=out.migration_inventory.items.map(item=>item.workflow_id).filter(Boolean);
for (const id of ['wf-20260710133214-review_repair','wf-durable-legacy-review']) {
  if (ids.filter(candidate=>candidate===id).length!==1) throw new Error(`expected one inventory card for ${id}: ${JSON.stringify(ids)}`);
}
if (out.migration_inventory.items.some(item=>!item.classification)) throw new Error('every legacy inventory card needs a classification');
NODE

    node "$INBOX" --project-root "$PROJECT" --json > "$TMP_DIR/inbox-all.json"
    node - "$TMP_DIR/inbox-all.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const ids=out.candidates.map(item=>item.id);
for (const id of ['wf-20260710133214-review_repair','wf-durable-legacy-review']) {
  if (ids.filter(candidate=>candidate===id).length!==1) throw new Error(JSON.stringify(out));
}
if (out.migration_task_count!==2) throw new Error(JSON.stringify(out));
NODE

    status=0
    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --workflow-id wf-durable-legacy-review --json > "$TMP_DIR/durable-unconfirmed.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_migration_confirmation_required"' "$TMP_DIR/durable-unconfirmed.json"

    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --workflow-id wf-durable-legacy-review --confirm --json > "$TMP_DIR/migrate-durable.json"
    node - "$TMP_DIR/migrate-durable.json" "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const [outFile,root]=process.argv.slice(2);
const out=JSON.parse(fs.readFileSync(outFile,'utf8'));
if (out.status!=='migration_applied') throw new Error(out.status);
const migration=out.migrations[0];
const legacy='wf-durable-legacy-review';
const current=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
if (current.workflow_id!=='wf-20260710133214-review_repair') throw new Error('non-current migration replaced the active workflow');
const successor=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',migration.successor_workflow_id,'task.json'),'utf8'));
if (successor.migration.source_workflow_id!==legacy || successor.migration.source!=='worldwonderer/oh-story-claudecode' || !successor.migration.rollback) throw new Error('successor rollback metadata missing');
for (const name of [`${legacy}.current-task.json`,`${legacy}.task.json`]) {
  if (!fs.existsSync(path.join(root,'追踪/workflow/archived',name))) throw new Error(`missing archived copy ${name}`);
}
const old=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/tasks',legacy,'task.json'),'utf8'));
if (old.lifecycle.status!=='superseded') throw new Error('durable predecessor was not archived');
NODE
}

@test "explicit oh-story source binding migrates an upstream-shaped task without novel-assistant provenance" {
    write_trusted_chapters
    write_legacy_fixed_review
    printf '%s\n' '{"source_repository":"worldwonderer/oh-story-claudecode"}' > "$PROJECT/.story-deployed"
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
for (const file of ['追踪/workflow/current-task.json','追踪/workflow/tasks/wf-20260710133214-review_repair/task.json']) {
  const target=path.join(root,file);const task=JSON.parse(fs.readFileSync(target,'utf8'));delete task.migration_source;fs.writeFileSync(target,JSON.stringify(task,null,2)+'\n');
}
NODE
    before="$(task_digest)"

    status=0
    node "$MIGRATE" --project-root "$PROJECT" --source other --json > "$TMP_DIR/unsupported-source.json" || status=$?
    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_migration_source_invalid"' "$TMP_DIR/unsupported-source.json"

    node "$INBOX" --project-root "$PROJECT" --json > "$TMP_DIR/unmarked-inbox.json"
    grep -q '"candidateCount": 1' "$TMP_DIR/unmarked-inbox.json"

    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --json > "$TMP_DIR/unmarked-preview.json"
    grep -q '"workflow_id": "wf-20260710133214-review_repair"' "$TMP_DIR/unmarked-preview.json"
    grep -q '"migration_source": "worldwonderer/oh-story-claudecode"' "$TMP_DIR/unmarked-preview.json"
    [ "$before" = "$(task_digest)" ]

    node "$MIGRATE" --project-root "$PROJECT" --source oh-story --write --workflow-id wf-20260710133214-review_repair --confirm --json > "$TMP_DIR/unmarked-applied.json"
    grep -q '"status": "migration_applied"' "$TMP_DIR/unmarked-applied.json"
    node - "$PROJECT" <<'NODE'
const fs=require('fs');const path=require('path');const root=process.argv[2];
const task=JSON.parse(fs.readFileSync(path.join(root,'追踪/workflow/current-task.json'),'utf8'));
if (task.migration.source!=='worldwonderer/oh-story-claudecode') throw new Error(JSON.stringify(task.migration));
NODE
}
