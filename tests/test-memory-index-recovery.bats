#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/追踪/memory"
    cat > "$PROJECT/追踪/memory/facts.jsonl" <<'JSONL'
{"fact_id":"fact.a","subject":"绿珠","predicate":"身份","object":"圣女","aliases":["绿珠"],"dependencies":["血脉觉醒"],"evidence":[{"path":"追踪/伏笔.md"}],"status":"active"}
{"fact_id":"fact.b","subject":"血脉觉醒","predicate":"触发","object":"圣女印记","aliases":[],"dependencies":[],"evidence":[{"path":"追踪/时间线.md"}],"status":"active"}
JSONL
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "memory index rebuild is deterministic and recovers from a corrupt snapshot" {
    node "$REPO/scripts/memory-index-rebuild.js" --project-root "$PROJECT" --json > "$TMP_DIR/first.json"
    index="$PROJECT/追踪/memory/facts.active-index.json"
    digest_one="$(node -e 'process.stdout.write(require(process.argv[1]).sourceDigest)' "$index")"
    printf '{bad json\n' > "$index"
    node "$REPO/scripts/memory-index-rebuild.js" --project-root "$PROJECT" --json > "$TMP_DIR/second.json"
    node - "$index" "$digest_one" <<'NODE'
const fs=require('fs'); const index=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(index.sourceDigest!==process.argv[3]) throw new Error(JSON.stringify(index));
if(index.statistics.active_documents!==2) throw new Error(JSON.stringify(index.statistics));
if(!index.aliases['绿珠'] || !index.dependencies['血脉觉醒']) throw new Error(JSON.stringify(index));
NODE
}

@test "memory index scale check detects non-linear growth with a relative baseline" {
    run node "$REPO/scripts/memory-index-scale-check.js" --json
    [ "$status" -eq 0 ]
    node - "$output" <<'NODE'
const result = JSON.parse(process.argv[2]);
if (result.status !== 'pass') throw new Error(JSON.stringify(result));
if (result.baseline.fact_count !== 500 || result.candidate.fact_count !== 1000) throw new Error(JSON.stringify(result));
if (!(result.growth.elapsed_ratio > 0) || !(result.growth.heap_ratio >= 0)) throw new Error(JSON.stringify(result));
if (!result.retrieval.top_fact_id) throw new Error(JSON.stringify(result));
NODE
}
