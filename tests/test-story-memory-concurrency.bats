#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    RECOMMENDER="$REPO/scripts/memory-recommender.js"
    MIGRATE="$REPO/scripts/memory-migrate.js"
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/正文/第1卷" "$PROJECT/追踪/story-system/commits"
    cat > "$PROJECT/正文/第1卷/第001章_开场.md" <<'MD'
# 第001章
绿珠记住了铁锅缺口。
MD
    CHAPTER_HASH="sha256:$(shasum -a 256 "$PROJECT/正文/第1卷/第001章_开场.md" | awk '{print $1}')"
    COMMIT_ID="chapter-vtest-001-concurrency"
    cat > "$PROJECT/追踪/story-system/commits/$COMMIT_ID.json" <<JSON
{"commit_id":"$COMMIT_ID","status":"accepted","artifacts":[{"target":"正文/第1卷/第001章_开场.md","after_hash":"$CHAPTER_HASH"}]}
JSON
    mkdir -p "$PROJECT/追踪"
    printf '# 伏笔\n- 铁锅缺口必须在第三章解释。\n' > "$PROJECT/追踪/伏笔.md"
    node "$MIGRATE" --project-root "$PROJECT" --write --json >/dev/null
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "concurrent recommender and chapter projection retain every accepted memory entry" {
    node - "$PROJECT/追踪/memory/memory-suggestions.jsonl" "$CHAPTER_HASH" <<'NODE'
const fs=require('fs');
const file=process.argv[2];
const hash=process.argv[3];
const rows=[];
for(let index=0; index<800; index+=1) rows.push(JSON.stringify({
  suggestionId:`sg-concurrent-${index}`,
  action:'create', entryId:`hook.concurrent.${index}`, type:'hook', risk:'low',
  proposedContent:`铁锅缺口线索 ${index} 需要在后续章节兑现。`,
  sourceRefs:[{path:'正文/第1卷/第001章_开场.md',hash}], status:'pending',
}));
fs.writeFileSync(file,`${rows.join('\n')}\n`);
NODE

    node "$RECOMMENDER" --project-root "$PROJECT" --apply-low-risk --json > "$TMP_DIR/recommender.json" &
    recommender_pid=$!
    for _ in $(seq 1 200); do
        grep -q 'hook.concurrent.0' "$PROJECT/追踪/memory/lorebook.jsonl" 2>/dev/null && break
        sleep 0.01
    done
    printf '# 伏笔\n- 铁锅缺口已在第二章确认，第三章仍需解释来源。\n' > "$PROJECT/追踪/伏笔.md"
    node "$MIGRATE" --project-root "$PROJECT" --source '追踪/伏笔.md' --write --json > "$TMP_DIR/projection.json"
    wait "$recommender_pid"

    node - "$TMP_DIR/recommender.json" "$PROJECT/追踪/memory/lorebook.jsonl" <<'NODE'
const fs=require('fs');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const rows=fs.readFileSync(process.argv[3],'utf8').trim().split(/\n/).map(JSON.parse);
const latest=new Map(); for(const row of rows) latest.set(row.id,row);
const accepted=[...latest.values()].filter(row=>row.id.startsWith('hook.concurrent.') && row.status==='active');
if(out.applied!==800) throw new Error(JSON.stringify(out));
if(accepted.length!==800) throw new Error(`lost accepted memory: ${accepted.length}/800`);
if(!accepted.every(row=>row.chapter_commit_id==='chapter-vtest-001-concurrency' && row.provenance_status==='verified')) throw new Error('missing verified commit provenance');
NODE
}
