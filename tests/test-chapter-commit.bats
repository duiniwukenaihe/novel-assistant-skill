#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/chapter-commit.js"
    POLICY="$REPO/scripts/canonical-write-policy.js"
    STORE="$REPO/scripts/lib/workflow-state-store.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/staging" "$PROJECT/正文/第1卷" "$PROJECT/追踪"
    printf '# 旧正文\n' > "$PROJECT/正文/第1卷/第001章_起点.md"
    printf '# 旧伏笔\n' > "$PROJECT/追踪/伏笔.md"
    printf '# 新正文\n人物行动推进。\n' > "$PROJECT/追踪/staging/正文.md"
    printf '# 新伏笔\n- F001 已铺设。\n' > "$PROJECT/追踪/staging/伏笔.md"
    cat > "$PROJECT/追踪/staging/manifest.json" <<'JSON'
{
  "schemaVersion": "1.0.0",
  "workflow_id": "wf-write-001",
  "source_kind": "canonical",
  "volume": "第1卷",
  "chapter": 1,
  "artifacts": [
    {"role":"chapter_prose","staged":"追踪/staging/正文.md","target":"正文/第1卷/第001章_起点.md","required":true},
    {"role":"hook_ledger","staged":"追踪/staging/伏笔.md","target":"追踪/伏笔.md","required":true}
  ],
  "gates": {"output_health":"pass","prose_quality":"pass","story_drift":"pass"}
}
JSON
    write_canonical_task
}

teardown() {
    rm -rf "$TMP_DIR"
}

prepare_transaction() {
    node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json > "$TMP_DIR/prepare.json"
    node -e 'const x=require(process.argv[1]); process.stdout.write(x.transaction_id)' "$TMP_DIR/prepare.json"
}

write_canonical_task() {
    local stage_attempt_id="${1:-sa-prose-001}"
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-write-001" "$PROJECT/追踪/workflow/families/tf-write"
    cat > "$PROJECT/追踪/workflow/tasks/wf-write-001/task.json" <<JSON
{"workflow_id":"wf-write-001","workflow_type":"long_write","task_family_id":"tf-write","branch_id":"wf-write-001","task_dir":"追踪/workflow/tasks/wf-write-001","state_version":4,"current_stage":"chapter_commit","stage_execution":{"stage_id":"chapter_commit","status":"running","stage_attempt_id":"$stage_attempt_id"}}
JSON
    cat > "$PROJECT/追踪/workflow/families/tf-write/family.json" <<'JSON'
{"task_family_id":"tf-write","head_workflow_id":"wf-write-001","branches":[{"workflow_id":"wf-write-001","status":"active","is_head":true}]}
JSON
}

make_manifest_canonical() {
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');const file=process.argv[2];const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
delete manifest.migration;
manifest.source_kind='canonical';
fs.writeFileSync(file,JSON.stringify(manifest));
NODE
}

@test "canonical manifest provenance requires a matching durable task" {
    make_manifest_canonical
    rm -rf "$PROJECT/追踪/workflow/tasks/wf-write-001" "$PROJECT/追踪/workflow/families/tf-write"
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');const file=process.argv[2];const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
manifest.source_kind='canonical';
manifest.provenance={task_family_id:'tf-forged',workflow_id:'wf-write-001',branch_id:'wf-write-001',stage_attempt_id:'sa-forged',acceptance_status:'accepted'};
fs.writeFileSync(file,JSON.stringify(manifest));
NODE

    run node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_task_authority_missing'* ]]
}

@test "canonical manifest provenance rejects a stale stage attempt" {
    write_canonical_task sa-current
    make_manifest_canonical
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');const file=process.argv[2];const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
manifest.source_kind='canonical';
manifest.provenance={task_family_id:'tf-write',workflow_id:'wf-write-001',branch_id:'wf-write-001',stage_attempt_id:'sa-stale',acceptance_status:'accepted'};
fs.writeFileSync(file,JSON.stringify(manifest));
NODE

    run node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_task_provenance_mismatch'* ]]
    [[ "$output" == *'stage_attempt_id'* ]]
}

@test "forged legacy migration marker is blocked even when durable authority exists" {
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');const file=process.argv[2];const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
manifest.migration={source_kind:'legacy'};
fs.writeFileSync(file,JSON.stringify(manifest));
NODE

    run node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_untrusted_legacy_migration'* ]]
}

@test "book write lease is exclusive, releasable and can recover a stale owner" {
    node - "$STORE" "$PROJECT" <<'NODE'
const fs = require('fs');
const path = require('path');
const store = require(process.argv[2]);
const root = process.argv[3];
const release = store.acquireBookWriteLease(root, 'writer-a', 1000);
let blocked = false;
try { store.acquireBookWriteLease(root, 'writer-b', 1000); } catch (error) { blocked = error.code === 'BOOK_WRITE_LOCKED'; }
if (!blocked) process.exit(1);
release();
store.acquireBookWriteLease(root, 'writer-b', 1000)();
const lockDir = path.join(root, '追踪', 'story-system', '.write.lock');
fs.mkdirSync(lockDir, { recursive: true });
fs.writeFileSync(path.join(lockDir, 'owner.json'), JSON.stringify({ owner: 'dead', acquired_at: '2000-01-01T00:00:00Z' }));
store.acquireBookWriteLease(root, 'writer-c', 10)();
NODE
}

@test "chapter commit honors a strict canonical policy and releases its chapter lease" {
    mkdir -p "$PROJECT/追踪/story-system"
    cat > "$PROJECT/追踪/story-system/write-policy.json" <<'JSON'
{"schemaVersion":"1.0.0","mode":"strict"}
JSON
    tx="$(prepare_transaction)"

    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/accept.json"

    grep -q '"status": "accepted"' "$TMP_DIR/accept.json"
    [ ! -e "$PROJECT/追踪/story-system/leases/第1卷-1.json" ]
}

@test "chapter commit refuses a chapter already leased by another writer" {
    tx="$(prepare_transaction)"
    node "$POLICY" lease --project-root "$PROJECT" --volume 第1卷 --chapter 1 --owner another-writer --json > "$TMP_DIR/lease.json"
    token="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.lease.token)' "$TMP_DIR/lease.json")"

    run node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_chapter_lease_conflict'* ]]

    node "$POLICY" release --project-root "$PROJECT" --volume 第1卷 --chapter 1 --token "$token" --json
}

@test "prepare rejects targets outside the book root" {
    node -e '
      const fs=require("fs"); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p,"utf8"));
      x.artifacts[0].target="../outside.md"; fs.writeFileSync(p,JSON.stringify(x));
    ' "$PROJECT/追踪/staging/manifest.json"

    run node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_unsafe_path"* ]]
}

@test "prepare rejects a target whose parent symlink escapes the book root" {
    mkdir -p "$TMP_DIR/outside"
    ln -s "$TMP_DIR/outside" "$PROJECT/正文/escape"
    node -e '
      const fs=require("fs"); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p,"utf8"));
      x.artifacts[0].target="正文/escape/escaped.md"; fs.writeFileSync(p,JSON.stringify(x));
    ' "$PROJECT/追踪/staging/manifest.json"

    run node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_unsafe_path"* ]]
    [ ! -e "$TMP_DIR/outside/escaped.md" ]
}

@test "chapter commit CLI returns structured errors for invalid arguments" {
    run node "$SCRIPT" prepare --project-root "$PROJECT" --unknown value --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'"status": "blocked_invalid_argument"'* ]]
    [[ "$output" != *'at parseArgs'* ]]
}

@test "prepare rejects an empty required artifact and a failed required gate" {
    : > "$PROJECT/追踪/staging/正文.md"
    run node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_empty_artifact"* ]]

    printf '# 新正文\n' > "$PROJECT/追踪/staging/正文.md"
    node -e '
      const fs=require("fs"); const p=process.argv[1]; const x=JSON.parse(fs.readFileSync(p,"utf8"));
      x.gates.prose_quality="blocking"; fs.writeFileSync(p,JSON.stringify(x));
    ' "$PROJECT/追踪/staging/manifest.json"
    run node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_gate_failed"* ]]
}

@test "accept atomically publishes all staged artifacts and records an immutable commit" {
    tx="$(prepare_transaction)"
    rm "$PROJECT/追踪/staging/正文.md" "$PROJECT/追踪/staging/伏笔.md"

    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/accept.json"

    grep -q '人物行动推进' "$PROJECT/正文/第1卷/第001章_起点.md"
    grep -q 'F001 已铺设' "$PROJECT/追踪/伏笔.md"
    node - "$TMP_DIR/accept.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if (!['accepted','accepted_with_projection_debt'].includes(out.status)) process.exit(1);
if (!out.commit_file || !fs.existsSync(out.commit_file)) process.exit(2);
const commit=JSON.parse(fs.readFileSync(out.commit_file,'utf8'));
if (commit.status !== out.status) process.exit(3);
if (commit.artifacts.length !== 2) process.exit(4);
NODE
}

@test "accepted chapter commit preserves task family and stage attempt provenance" {
    write_canonical_task
    make_manifest_canonical
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');const file=process.argv[2];const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
manifest.provenance={task_family_id:'tf-write',workflow_id:'wf-write-001',branch_id:'wf-write-001',stage_attempt_id:'sa-prose-001',acceptance_status:'accepted'};
fs.writeFileSync(file,JSON.stringify(manifest));
NODE
    tx="$(prepare_transaction)"
    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/accept.json"
    node - "$TMP_DIR/accept.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const commit=JSON.parse(fs.readFileSync(out.commit_file,'utf8'));
if(commit.provenance.task_family_id!=='tf-write'||commit.provenance.stage_attempt_id!=='sa-prose-001'||commit.acceptance_status!=='accepted') throw new Error(JSON.stringify(commit));
NODE
}

@test "chapter commit rejects provenance from a non-head task branch before writing" {
    mkdir -p "$PROJECT/追踪/workflow/families/tf-write" "$PROJECT/追踪/workflow/tasks/wf-old"
    cat > "$PROJECT/追踪/workflow/tasks/wf-old/task.json" <<'JSON'
{"workflow_id":"wf-old","workflow_type":"long_write","task_family_id":"tf-write","branch_id":"wf-old","task_dir":"追踪/workflow/tasks/wf-old","state_version":4,"current_stage":"chapter_commit","stage_execution":{"stage_id":"chapter_commit","status":"running","stage_attempt_id":"sa-old"}}
JSON
    cat > "$PROJECT/追踪/workflow/families/tf-write/family.json" <<'JSON'
{"task_family_id":"tf-write","head_workflow_id":"wf-head","branches":[{"workflow_id":"wf-old","status":"paused"},{"workflow_id":"wf-head","status":"active","is_head":true}]}
JSON
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');const file=process.argv[2];const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
delete manifest.migration;manifest.source_kind='canonical';manifest.workflow_id='wf-old';
manifest.provenance={task_family_id:'tf-write',workflow_id:'wf-old',branch_id:'wf-old',stage_attempt_id:'sa-old',acceptance_status:'accepted'};
fs.writeFileSync(file,JSON.stringify(manifest));
NODE
    tx="$(prepare_transaction)"
    run node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_non_head_branch_projection'* ]]
    grep -q '旧正文' "$PROJECT/正文/第1卷/第001章_起点.md"
}

@test "task-family workflow automatically binds chapter transaction provenance" {
    make_manifest_canonical
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-write-001" "$PROJECT/追踪/workflow/families/tf-write"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"workflow_id":"wf-write-001","workflow_type":"long_write","task_family_id":"tf-write","branch_id":"wf-write-001","task_dir":"追踪/workflow/tasks/wf-write-001","stage_execution":{"stage_attempt_id":"sa-prose-001"}}
JSON
    cp "$PROJECT/追踪/workflow/current-task.json" "$PROJECT/追踪/workflow/tasks/wf-write-001/task.json"
    cat > "$PROJECT/追踪/workflow/families/tf-write/family.json" <<'JSON'
{"task_family_id":"tf-write","head_workflow_id":"wf-write-001","branches":[{"workflow_id":"wf-write-001","status":"active","is_head":true}]}
JSON
    node "$SCRIPT" prepare --project-root "$PROJECT" --manifest "$PROJECT/追踪/staging/manifest.json" --json > "$TMP_DIR/family-prepare.json"
    node - "$TMP_DIR/family-prepare.json" <<'NODE'
const fs=require('fs');const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));const tx=JSON.parse(fs.readFileSync(out.transaction_file,'utf8'));
if(tx.provenance.task_family_id!=='tf-write'||tx.provenance.stage_attempt_id!=='sa-prose-001') throw new Error(JSON.stringify(tx));
NODE
}

@test "accepted chapter projection refreshes only its modern memory inputs" {
    write_canonical_task
    make_manifest_canonical
    mkdir -p "$PROJECT/追踪/staging/交接包" "$PROJECT/追踪/staging/卷交接" "$PROJECT/追踪/staging/memory"
    printf '# 卷内交接\n- 下一章必须回应铁锅缺口。\n' > "$PROJECT/追踪/staging/交接包/第001章_to_第002章.md"
    printf '# 跨卷交接\n- 绿珠的读心空白带入下一卷。\n' > "$PROJECT/追踪/staging/卷交接/第1卷_to_第2卷.md"
    printf '{"active_cast":[{"name":"绿珠","state":"读心异常"}]}' > "$PROJECT/追踪/staging/memory/active-cast.json"
    printf '{"suggestionId":"sg-accepted","entryId":"hook.iron-wok","status":"applied","proposedContent":"铁锅缺口需要兑现。"}\n' > "$PROJECT/追踪/staging/memory/memory-suggestions.jsonl"
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
manifest.artifacts.push(
  {role:'handoff',staged:'追踪/staging/交接包/第001章_to_第002章.md',target:'追踪/交接包/第1卷/第001章_to_第002章.md',required:true},
  {role:'volume_handoff',staged:'追踪/staging/卷交接/第1卷_to_第2卷.md',target:'追踪/卷交接/第1卷_to_第2卷.md',required:true},
  {role:'active_cast_delta',staged:'追踪/staging/memory/active-cast.json',target:'追踪/memory/active-cast.json',required:true},
  {role:'accepted_memory_suggestions',staged:'追踪/staging/memory/memory-suggestions.jsonl',target:'追踪/memory/memory-suggestions.jsonl',required:true},
);
fs.writeFileSync(file,JSON.stringify(manifest));
NODE
    tx="$(prepare_transaction)"

    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/accept.json"

    node - "$TMP_DIR/accept.json" "$PROJECT/追踪/story-system/projection-log.jsonl" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const projection=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse).at(-1);
const rows=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
const expected=['追踪/交接包/第1卷/第001章_to_第002章.md','追踪/卷交接/第1卷_to_第2卷.md','追踪/memory/active-cast.json','追踪/memory/memory-suggestions.jsonl'];
if(out.status!=='accepted' || projection.status!=='projection_current') throw new Error(JSON.stringify({out,projection}));
if(!expected.every(source=>projection.sources.includes(source))) throw new Error(JSON.stringify(projection.sources));
if(!expected.every(source=>rows.some(row=>row.sourceRefs.some(ref=>ref.path===source)))) throw new Error(JSON.stringify(rows));
NODE
}

@test "accepted chapter commit projects explicit facts from manifest" {
    write_canonical_task
    make_manifest_canonical
    printf '# 事实证据\n绿珠身份为圣女。\n' > "$PROJECT/追踪/staging/伏笔.md"
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const manifest=JSON.parse(fs.readFileSync(file,'utf8'));
manifest.facts=[{
  subject:'绿珠',
  predicate:'身份',
  object:'圣女',
  aliases:['圣女'],
  dependencies:['血脉觉醒'],
  scope:{book:'current'},
  evidence:[{path:'追踪/伏笔.md'}],
  confidence:1
}];
fs.writeFileSync(file,JSON.stringify(manifest));
NODE
    tx="$(prepare_transaction)"

    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/facts-accept.json"

    node - "$TMP_DIR/facts-accept.json" "$PROJECT/追踪/story-system/projection-log.jsonl" "$PROJECT/追踪/memory/facts.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const projection=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse).at(-1);
const facts=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
if(out.status!=='accepted'||projection.status!=='projection_current') throw new Error(JSON.stringify({out,projection}));
if(!projection.fact_result||projection.fact_result.factIds.length!==1) throw new Error(JSON.stringify(projection));
if(facts.length!==1||facts[0].object!=='圣女'||facts[0].provenance.commit_id!==out.commit_id) throw new Error(JSON.stringify(facts));
NODE
}

@test "accepted chapter commit projects promise deltas idempotently" {
    make_manifest_canonical
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.promise_deltas = [{
  id: 'P-旧账号水印', action: 'open', type: 'foreshadowing',
  description: '异常水印暗示旧账号仍有人使用。', expectedPayoffRange: '第020-030章',
  plotUnitId: 'PU-V01-001'
}];
fs.writeFileSync(file, JSON.stringify(manifest));
NODE
    tx="$(prepare_transaction)"
    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/promise-accept.json"
    commit_id="$(node -e 'process.stdout.write(require(process.argv[1]).commit_id)' "$TMP_DIR/promise-accept.json")"
    node "$SCRIPT" replay --project-root "$PROJECT" --commit "$commit_id" --json > "$TMP_DIR/promise-replay.json"

    node - "$PROJECT/追踪/schema/promises.jsonl" "$PROJECT/追踪/story-system/promise-events.jsonl" <<'NODE'
const fs = require('fs');
const state = fs.readFileSync(process.argv[2], 'utf8').trim().split(/\n/).map(JSON.parse);
const events = fs.readFileSync(process.argv[3], 'utf8').trim().split(/\n/).map(JSON.parse);
if (state.length !== 1 || state[0].id !== 'P-旧账号水印' || state[0].status !== 'open' || state[0].plotUnitId !== 'PU-V01-001') throw new Error(JSON.stringify(state));
if (events.length !== 1 || events[0].action !== 'open') throw new Error(JSON.stringify(events));
NODE

    write_canonical_task sa-prose-002
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.promise_deltas = [{ id: 'P-旧账号水印', action: 'close', payoffIn: '第001章', description: '主角确认旧账号由幕后人接管。', plotUnitId: 'PU-V01-001' }];
fs.writeFileSync(file, JSON.stringify(manifest));
NODE
    tx2="$(prepare_transaction)"
    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx2" --json > "$TMP_DIR/promise-close.json"

    node - "$PROJECT/追踪/schema/promises.jsonl" "$PROJECT/追踪/story-system/promise-events.jsonl" <<'NODE'
const fs = require('fs');
const state = fs.readFileSync(process.argv[2], 'utf8').trim().split(/\n/).map(JSON.parse);
const events = fs.readFileSync(process.argv[3], 'utf8').trim().split(/\n/).map(JSON.parse);
if (state.length !== 1 || state[0].status !== 'paid_off' || state[0].payoffIn !== '第001章') throw new Error(JSON.stringify(state));
if (events.length !== 2 || events[1].action !== 'close') throw new Error(JSON.stringify(events));
NODE
}

@test "a superseding accepted chapter commit clears a relevant stale fact evidence debt" {
    write_canonical_task sa-fact-001
    make_manifest_canonical
    printf '# 事实证据\n绿珠身份为圣女。\n' > "$PROJECT/追踪/staging/伏笔.md"
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.facts = [{
  subject: '绿珠', predicate: '身份', object: '圣女', aliases: ['圣女'], dependencies: [],
  scope: { book: 'current' }, evidence: [{ path: '追踪/伏笔.md' }], confidence: 1,
}];
fs.writeFileSync(file, JSON.stringify(manifest));
NODE
    first_tx="$(prepare_transaction)"
    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$first_tx" --json > "$TMP_DIR/fact-first.json"

    printf '# 人工改动\n证据已偏离首次提交。\n' > "$PROJECT/追踪/伏笔.md"
    run node "$REPO/scripts/context-assembler.js" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "blocked_memory_evidence_stale"'* ]]
    [[ "$output" == *'"status": "hash_mismatch"'* ]]

    write_canonical_task sa-fact-002
    printf '# 新事实证据\n绿珠身份已确认是圣女。\n' > "$PROJECT/追踪/staging/伏笔.md"
    node - "$PROJECT/追踪/staging/manifest.json" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
manifest.facts[0].object = '圣女（已确认）';
manifest.facts[0].aliases = ['圣女', '身份已确认'];
fs.writeFileSync(file, JSON.stringify(manifest));
NODE
    second_tx="$(prepare_transaction)"
    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$second_tx" --json > "$TMP_DIR/fact-second.json"

    node "$REPO/scripts/context-assembler.js" --project-root "$PROJECT" --task write_chapter --target "第1卷/第003章" --budget 1200 --json > "$TMP_DIR/fact-current.json"
    node - "$PROJECT/追踪/memory/facts.jsonl" "$TMP_DIR/fact-current.json" <<'NODE'
const fs = require('fs');
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split(/\n/).map(JSON.parse);
const out = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.status !== 'ok') throw new Error(JSON.stringify(out));
if ((out.memory_debts || []).some(item => item.fact_id && item.status === 'hash_mismatch')) throw new Error(JSON.stringify(out.memory_debts));
const latest = new Map();
for (const row of rows) latest.set(row.fact_id, row);
const active = [...latest.values()].filter(item => item.status === 'active' && item.subject === '绿珠' && item.predicate === '身份');
if (active.length !== 1 || active[0].object !== '圣女（已确认）') throw new Error(JSON.stringify(rows));
const superseded = [...latest.values()].filter(item => item.status === 'superseded' && item.subject === '绿珠' && item.predicate === '身份');
if (!superseded.length || !superseded.some(item => item.valid_to === active[0].provenance.commit_id)) throw new Error(JSON.stringify(rows));
NODE
}

@test "accepted chapter projection records lifecycle identity and validity interval" {
    make_manifest_canonical
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-write-001" "$PROJECT/追踪/workflow/families/tf-write"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"workflow_id":"wf-write-001","workflow_type":"long_write","task_family_id":"tf-write","branch_id":"wf-write-001","task_dir":"追踪/workflow/tasks/wf-write-001","stage_execution":{"stage_attempt_id":"sa-prose-001"},"lifecycle_context":{"node":"chapter_commit","book_id":"book-001","volume_id":"第1卷","stage_id":"stage-01","chapter_id":"v01-c001","task_family_id":"tf-write","workflow_id":"wf-write-001"}}
JSON
    cp "$PROJECT/追踪/workflow/current-task.json" "$PROJECT/追踪/workflow/tasks/wf-write-001/task.json"
    cat > "$PROJECT/追踪/workflow/families/tf-write/family.json" <<'JSON'
{"task_family_id":"tf-write","head_workflow_id":"wf-write-001","branches":[{"workflow_id":"wf-write-001","status":"active","is_head":true}]}
JSON

    tx="$(prepare_transaction)"
    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/lifecycle-accept.json"

    node - "$TMP_DIR/lifecycle-accept.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='accepted') throw new Error(JSON.stringify(out));
const rows=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse);
const active=rows.filter(row=>row.status==='active');
if(active.length!==1) throw new Error(JSON.stringify(rows));
const entry=active[0];
const expected={lifecycleNode:'chapter_commit',bookId:'book-001',volumeId:'第1卷',stageId:'stage-01',chapterId:'v01-c001',taskFamilyId:'tf-write',workflowId:'wf-write-001',acceptedCommitId:out.commit_id};
for(const [key,value] of Object.entries(expected)) if(entry[key]!==value) throw new Error(`${key}: ${JSON.stringify(entry)}`);
if(entry.valid_from!==out.commit_id||entry.valid_to!==null) throw new Error(JSON.stringify(entry));
if(entry.provenance.acceptance_status!=='accepted') throw new Error(JSON.stringify(entry.provenance));
NODE
}

@test "accept blocks when a target changed after prepare" {
    tx="$(prepare_transaction)"
    printf '# 人工抢先修改\n' > "$PROJECT/正文/第1卷/第001章_起点.md"

    run node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"blocked_write_conflict"* ]]
    grep -q '人工抢先修改' "$PROJECT/正文/第1卷/第001章_起点.md"
    grep -q '旧伏笔' "$PROJECT/追踪/伏笔.md"
}

@test "accept rolls back earlier files when a later replacement fails" {
    tx="$(prepare_transaction)"

    run env NOVEL_ASSISTANT_TEST_FAIL_AFTER_WRITES=1 node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"rolled_back"* ]]
    grep -q '旧正文' "$PROJECT/正文/第1卷/第001章_起点.md"
    grep -q '旧伏笔' "$PROJECT/追踪/伏笔.md"
}

@test "accept removes a commit record when final transaction persistence fails" {
    tx="$(prepare_transaction)"

    run env NOVEL_ASSISTANT_TEST_FAIL_AFTER_COMMIT=1 node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"rolled_back"* ]]
    grep -q '旧正文' "$PROJECT/正文/第1卷/第001章_起点.md"
    grep -q '旧伏笔' "$PROJECT/追踪/伏笔.md"
    [ "$(find "$PROJECT/追踪/story-system/commits" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
}

@test "projection log failure leaves accepted assets and reports replayable debt" {
    tx="$(prepare_transaction)"

    env NOVEL_ASSISTANT_TEST_FAIL_PROJECTION_LOG=1 node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/accept.json"

    grep -q '人物行动推进' "$PROJECT/正文/第1卷/第001章_起点.md"
    grep -q 'F001 已铺设' "$PROJECT/追踪/伏笔.md"
    node - "$TMP_DIR/accept.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='accepted_with_projection_debt') throw new Error(JSON.stringify(out));
if(!fs.existsSync(out.commit_file)) throw new Error('accepted commit missing');
NODE
}

@test "inspect and replay are idempotent and never rewrite accepted prose" {
    tx="$(prepare_transaction)"
    node "$SCRIPT" accept --project-root "$PROJECT" --transaction "$tx" --json > "$TMP_DIR/accept.json"
    commit="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.commit_id)' "$TMP_DIR/accept.json")"
    before="$(shasum -a 256 "$PROJECT/正文/第1卷/第001章_起点.md" | awk '{print $1}')"

    node "$SCRIPT" inspect --project-root "$PROJECT" --volume 第1卷 --chapter 1 --json > "$TMP_DIR/inspect.json"
    node "$SCRIPT" replay --project-root "$PROJECT" --commit "$commit" --json > "$TMP_DIR/replay1.json"
    node "$SCRIPT" replay --project-root "$PROJECT" --commit "$commit" --json > "$TMP_DIR/replay2.json"
    after="$(shasum -a 256 "$PROJECT/正文/第1卷/第001章_起点.md" | awk '{print $1}')"

    [ "$before" = "$after" ]
    node -e 'const x=require(process.argv[1]); if(x.status!=="ok" || !x.latest_commit) process.exit(1)' "$TMP_DIR/inspect.json"
    node -e 'const x=require(process.argv[1]); if(!["projection_current","projection_repaired"].includes(x.status)) process.exit(1)' "$TMP_DIR/replay1.json"
    node -e 'const x=require(process.argv[1]); if(x.status!=="projection_current") process.exit(1)' "$TMP_DIR/replay2.json"
}
