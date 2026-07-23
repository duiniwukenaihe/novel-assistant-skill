#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/evidence"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "persisted batch dispatch plan is the only authority for dispatch" {
    printf '%s\n' \
      '{"chapterKey":"v01-c001","globalDraftOrder":1,"volume":"第1卷","chars":800,"staticRiskTags":["prose"],"boundaryTags":[]}' \
      > "$PROJECT/evidence/chapter-evidence.jsonl"

    node "$REPO/scripts/review-batch-plan.js" "$PROJECT" --scope 1-1 --dimensions plot,canon,prose --agents-available story-explorer,consistency-checker,narrative-writer --write --json > "$TMP_DIR/plan.json"
    node - "$TMP_DIR/plan.json" "$TMP_DIR/dispatch-plan.json" <<'NODE'
const fs=require('fs');
const plan=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
fs.writeFileSync(process.argv[3], JSON.stringify(plan.batches[0].dispatch_plan));
NODE

    node "$REPO/scripts/review-agent-dispatch-plan.js" --scope 1-1 --batch 1-1 --agents-available story-explorer,consistency-checker,narrative-writer,character-designer --dispatch-plan "$TMP_DIR/dispatch-plan.json" --json > "$TMP_DIR/dispatched.json"

    node - "$TMP_DIR/plan.json" "$TMP_DIR/dispatched.json" <<'NODE'
const fs=require('fs');
const plan=JSON.parse(fs.readFileSync(process.argv[2],'utf8')).batches[0].dispatch_plan;
const dispatched=JSON.parse(fs.readFileSync(process.argv[3],'utf8')).execution_plan;
const planned=plan.roles.map((role)=>role.subagent_type).sort();
const actual=dispatched.agents.map((role)=>role.subagent_type).sort();
if (JSON.stringify(actual)!==JSON.stringify(planned)) throw new Error(JSON.stringify({planned,actual}));
NODE
}
