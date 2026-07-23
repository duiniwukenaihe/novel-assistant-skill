#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MIGRATE="$REPO/scripts/memory-migrate.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/交接包" "$PROJECT/设定/作者风格"
    cat > "$PROJECT/追踪/角色状态.md" <<'MD'
# 角色状态
- 林昭：第一人称主角，已经拒绝母亲安排的相亲。
- 吴淑芬：好面子、刻薄，但不能突然慈爱。
MD
    cat > "$PROJECT/追踪/伏笔.md" <<'MD'
# 伏笔
- F001：小黑板上的电话来自吴淑芬，第二节必须解释转接渠道。
MD
    cat > "$PROJECT/追踪/上下文.md" <<'MD'
# 当前上下文
- 已采用第一节，下一步生成第二节 Brief。
MD
    cat > "$PROJECT/追踪/交接包/第001节_to_第002节.md" <<'MD'
# 交接
- 林昭离开相亲角，电话来源尚未解释。
MD
    cat > "$PROJECT/设定/作者风格/禁用表达.md" <<'MD'
# 禁用表达
- 避免高频“不是 X，是 Y”。
MD
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "memory migration previews legacy assets without writing" {
    node "$MIGRATE" --project-root "$PROJECT" --json > "$TMP_DIR/out.json"
    grep -q '"status": "migration_preview"' "$TMP_DIR/out.json"
    grep -q '追踪/角色状态.md' "$TMP_DIR/out.json"
    grep -q '追踪/伏笔.md' "$TMP_DIR/out.json"
    [ ! -f "$PROJECT/追踪/memory/lorebook.jsonl" ]
}

@test "memory migration writes source hashed entries and is idempotent" {
    node "$MIGRATE" --project-root "$PROJECT" --write --json > "$TMP_DIR/first.json"
    node "$MIGRATE" --project-root "$PROJECT" --write --json > "$TMP_DIR/second.json"

    node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const first=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const second=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const lines=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
if(first.status!=='migrated' || first.created < 4) throw new Error(JSON.stringify(first));
if(second.status!=='current' || second.created!==0) throw new Error(JSON.stringify(second));
if(new Set(lines.map(x=>x.id)).size!==lines.length) throw new Error('duplicate ids');
if(!lines.every(x=>x.sourceRefs[0].hash.startsWith('sha256:'))) throw new Error('missing source hash');
if(!lines.some(x=>x.type==='hook_ledger')) throw new Error('missing hook memory');
if(!lines.some(x=>x.type==='character_state')) throw new Error('missing character memory');
NODE
}

@test "memory migration refreshes one changed source as a new active version" {
    node "$MIGRATE" --project-root "$PROJECT" --write --json > "$TMP_DIR/first.json"
    printf '# 伏笔\n- F001：电话由吴淑芬主动转接，第二节已解释。\n' > "$PROJECT/追踪/伏笔.md"

    node "$MIGRATE" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json > "$TMP_DIR/refresh.json"
    node "$MIGRATE" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json > "$TMP_DIR/again.json"

    node - "$TMP_DIR/refresh.json" "$TMP_DIR/again.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const refresh=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const again=JSON.parse(fs.readFileSync(process.argv[3],'utf8'));
const rows=fs.readFileSync(process.argv[4],'utf8').trim().split(/\n/).map(JSON.parse);
const hooks=rows.filter(x=>x.type==='hook_ledger');
if(refresh.status!=='migrated' || refresh.created!==1 || refresh.superseded!==1) throw new Error(JSON.stringify(refresh));
if(again.status!=='current' || again.created!==0) throw new Error(JSON.stringify(again));
if(hooks.length!==3) throw new Error(`expected original, superseded event, active v2; got ${hooks.length}`);
if(hooks.at(-2).status!=='superseded') throw new Error(JSON.stringify(hooks));
if(hooks.at(-1).status!=='active' || hooks.at(-1).version!==2) throw new Error(JSON.stringify(hooks));
if(!hooks.at(-1).content.includes('主动转接')) throw new Error(hooks.at(-1).content);
NODE
}

@test "memory migration respects the book write lease" {
    lock="$PROJECT/追踪/story-system/.write.lock"
    mkdir -p "$lock"
    printf '{"owner":"another-session","token":"held","acquired_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/owner.json"

    run node "$MIGRATE" --project-root "$PROJECT" --write --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'blocked_book_write_locked'* ]]
    [ ! -f "$PROJECT/追踪/memory/lorebook.jsonl" ]
}
