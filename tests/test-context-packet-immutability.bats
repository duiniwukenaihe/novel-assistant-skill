#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    ASSEMBLER="$REPO/scripts/context-assembler.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/memory" "$PROJECT/追踪/workflow/tasks/wf-immutable"
    cat > "$PROJECT/追踪/workflow/tasks/wf-immutable/task.json" <<'JSON'
{"workflow_id":"wf-immutable","workflow_type":"long_write","task_dir":"追踪/workflow/tasks/wf-immutable","state_version":2,"scope":"第1卷/第003章","context_paths":{"rpd":"追踪/workflow/tasks/wf-immutable/rpd.md","context_jsonl":"追踪/workflow/tasks/wf-immutable/context.jsonl"},"lifecycle_context":{"workflow_id":"wf-immutable","node":"chapter_brief","volume_id":"第1卷","chapter_id":"第003章"}}
JSON
    printf '# 第003章 Brief\n- 主角先拒绝，再以行动回应。\n' > "$PROJECT/追踪/workflow/tasks/wf-immutable/rpd.md"
    : > "$PROJECT/追踪/workflow/tasks/wf-immutable/context.jsonl"
}

teardown() {
    rm -rf "$TMP_DIR"
}

assemble() {
    local run_id="$1"
    local budget="${2:-4000}"
    node "$ASSEMBLER" --project-root "$PROJECT" --task long_write:chapter_brief --target "第1卷/第003章" --workflow-id wf-immutable --task-dir "追踪/workflow/tasks/wf-immutable" --stage chapter_brief --run-id "$run_id" --budget "$budget" --json
}

@test "task-scoped context packets are immutable across attempts and advance an accepted pointer" {
    assemble ctx-a > "$TMP_DIR/a.json"
    first_path="$(node -e 'process.stdout.write(require(process.argv[1]).packetJson)' "$TMP_DIR/a.json")"
    first_hash="$(shasum -a 256 "$first_path" | awk '{print $1}')"

    assemble ctx-b > "$TMP_DIR/b.json"
    second_path="$(node -e 'process.stdout.write(require(process.argv[1]).packetJson)' "$TMP_DIR/b.json")"
    second_hash="$(shasum -a 256 "$second_path" | awk '{print $1}')"

    [ "$first_path" != "$second_path" ]
    [[ "$first_path" == *"追踪/workflow/tasks/wf-immutable/context-packets/chapter_brief/ctx-a/assembled-context.json" ]]
    [[ "$second_path" == *"追踪/workflow/tasks/wf-immutable/context-packets/chapter_brief/ctx-b/assembled-context.json" ]]
    [ "$first_hash" = "$(shasum -a 256 "$first_path" | awk '{print $1}')" ]
    [ "$second_hash" = "$(node -e 'process.stdout.write(require(process.argv[1]).packetDigest)' "$TMP_DIR/b.json")" ]

    pointer="$PROJECT/追踪/workflow/tasks/wf-immutable/context-packets/chapter_brief/latest-accepted.json"
    node - "$pointer" "$second_path" <<'NODE'
const fs=require('fs');
const pointer=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(pointer.run_id!=='ctx-b'||pointer.packet_json!==process.argv[3]) throw new Error(JSON.stringify(pointer));
NODE
}

@test "required task context blocks instead of silently truncating below the semantic budget" {
    node - "$PROJECT/追踪/workflow/tasks/wf-immutable/rpd.md" <<'NODE'
const fs=require('fs'); fs.writeFileSync(process.argv[2], '# Brief\n' + '关键约束。'.repeat(1800));
NODE

    assemble ctx-small 10 > "$TMP_DIR/small.json"
    node - "$TMP_DIR/small.json" <<'NODE'
const fs=require('fs'); const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_required_context_budget') throw new Error(JSON.stringify(out));
if(!(out.required_context || []).some(item=>item.id==='context.workflow_rpd')) throw new Error(JSON.stringify(out));
NODE
}
