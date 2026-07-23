#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/context-assembler.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/memory" "$PROJECT/追踪/章节契约/第2卷" "$PROJECT/追踪/交接包/第2卷" "$PROJECT/追踪/卷交接" "$PROJECT/设定/作者风格"
    cat > "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"rule.book-canon","type":"rule","title":"全书铁律","aliases":[],"triggers":[],"scope":{"book":"current"},"priority":80,"tokenBudget":80,"content":"黑铁令不得凭空消失。","constraints":["黑铁令必须连续。"],"facts":{"rule:black-token:value":"持续存在"},"status":"active"}
{"id":"hook.volume-two","type":"hook","title":"第2卷承接","aliases":["黑铁令"],"triggers":["黑铁令"],"scope":{"book":"current","volume":"第2卷","chapterRange":"第001-003章"},"priority":80,"tokenBudget":80,"content":"第2卷卷首承接黑铁令余波。","constraints":[],"facts":[{"key":"hook:black-token:status","value":"active"}],"status":"active"}
{"id":"char.unrelated","type":"character","title":"第9卷路人","aliases":["路人甲"],"triggers":["路人甲"],"scope":{"book":"current","volume":"第9卷","chapterRange":"第001章"},"priority":99,"tokenBudget":80,"content":"不应召回。","constraints":[],"status":"active"}
JSONL
    cat > "$PROJECT/追踪/memory/active-cast.json" <<'JSON'
{"range":"第2卷/第001章","presentCharacters":["沈七"],"activeHooks":["black-token"],"blockedReveals":[]}
JSON
    cat > "$PROJECT/追踪/章节契约/第2卷/第001章.md" <<'MD'
# 第2卷首章
- 黑铁令余波进入内门。
MD
    cat > "$PROJECT/追踪/交接包/第2卷/第000章_to_第001章.md" <<'MD'
# 第2卷章节交接
- 沈七带着黑铁令进入内门。
MD
    cat > "$PROJECT/追踪/卷交接/第1卷_to_第2卷.md" <<'MD'
# 跨卷交接
- 黑铁令残印必须承接。
MD
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "context assembler recalls book canon and matching volume handoffs deterministically" {
    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第2卷/第001章" --budget 900 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(JSON.stringify(out));
const packet=JSON.parse(fs.readFileSync(out.packetJson,'utf8'));
const ids=packet.relevant_lore.map(x=>x.id);
if(!ids.includes('rule.book-canon') || !ids.includes('hook.volume-two')) throw new Error(JSON.stringify(ids));
if(ids.includes('char.unrelated')) throw new Error(JSON.stringify(ids));
if(!packet.must_inherit.includes('黑铁令残印必须承接') || !packet.must_inherit.includes('沈七带着黑铁令')) throw new Error(packet.must_inherit);
NODE
}

@test "context assembler reports structured fact conflicts only when they affect the target" {
    cat >> "$PROJECT/追踪/memory/lorebook.jsonl" <<'JSONL'
{"id":"rule.book-canon-conflict","type":"rule","title":"全书铁律冲突","aliases":[],"triggers":[],"scope":{"book":"current"},"priority":81,"tokenBudget":80,"content":"黑铁令可以消失。","constraints":[],"facts":{"rule:black-token:value":"可以消失"},"status":"active"}
{"id":"rule.future-conflict","type":"rule","title":"未来冲突","aliases":[],"triggers":[],"scope":{"book":"current","volume":"第9卷","chapterRange":"第001章"},"priority":99,"tokenBudget":80,"content":"不相关。","constraints":[],"facts":{"rule:black-token:value":"未知"},"status":"active"}
JSONL

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第2卷/第001章" --budget 900 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='blocked_memory_conflict') throw new Error(JSON.stringify(out));
if(!out.conflicts.some(x=>x.fact_key==='rule:black-token:value' && x.entry_ids.includes('rule.book-canon') && x.entry_ids.includes('rule.book-canon-conflict'))) throw new Error(JSON.stringify(out.conflicts));
if(out.conflicts.some(x=>x.entry_ids.includes('rule.future-conflict'))) throw new Error(JSON.stringify(out.conflicts));
NODE
}

@test "context assembler omits malformed active cast and mismatched workflow context" {
    printf '{not json\\n' > "$PROJECT/追踪/memory/active-cast.json"
    mkdir -p "$PROJECT/追踪/workflow/tasks/wf-other"
    cat > "$PROJECT/追踪/workflow/current-task.json" <<'JSON'
{"schemaVersion":"1.0.0","workflow_id":"wf-other","task_dir":"追踪/workflow/tasks/wf-other","focused_at":"2026-07-12T00:00:00.000Z","state_version":0}
JSON
    cat > "$PROJECT/追踪/workflow/tasks/wf-other/task.json" <<'JSON'
{"workflow_id":"wf-other","workflow_type":"long_write","scope":"第1卷/第001章","task_dir":"追踪/workflow/tasks/wf-other","state_version":0}
JSON
    cat > "$PROJECT/追踪/workflow/tasks/wf-other/rpd.md" <<'MD'
# 不匹配任务
- 不得注入此上下文。
MD

    node "$SCRIPT" --project-root "$PROJECT" --task write_chapter --target "第2卷/第001章" --budget 900 --json > "$TMP_DIR/out.json"

    node - "$TMP_DIR/out.json" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='ok') throw new Error(JSON.stringify(out));
const packet=JSON.parse(fs.readFileSync(out.packetJson,'utf8'));
if(Object.keys(packet.active_cast).length) throw new Error(JSON.stringify(packet.active_cast));
if(packet.task_context.rpd) throw new Error(packet.task_context.rpd);
if(!packet.omitted.some(x=>x.id==='context.active_cast' && x.reason==='malformed_active_cast')) throw new Error(JSON.stringify(packet.omitted));
if(!packet.omitted.some(x=>x.id==='context.workflow_task' && x.reason==='task_target_mismatch')) throw new Error(JSON.stringify(packet.omitted));
NODE
}
