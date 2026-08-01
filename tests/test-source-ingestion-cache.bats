#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/素材" "$BOOK/追踪/workflow/tasks/wf-source"
    printf '第一版来源内容\n' > "$BOOK/素材/source.txt"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "source ingestion stores one immutable copy and reuses it by digest" {
    node "$REPO/scripts/source-ingest.js" --project-root "$BOOK" --task-dir 追踪/workflow/tasks/wf-source --source 素材/source.txt --json > "$TMP_DIR/first.json"
    node "$REPO/scripts/source-ingest.js" --project-root "$BOOK" --task-dir 追踪/workflow/tasks/wf-source --source 素材/source.txt --json > "$TMP_DIR/second.json"

    node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" "$BOOK" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const first = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const second = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const root = process.argv[4];
assert.equal(first.cache_status, 'stored');
assert.equal(second.cache_status, 'hit');
assert.equal(first.artifact_path, second.artifact_path);
assert.equal(first.source_digest, second.source_digest);
assert(fs.existsSync(path.join(root, first.artifact_path)));
NODE
}

@test "source ingestion creates a new immutable artifact when content changes" {
    node "$REPO/scripts/source-ingest.js" --project-root "$BOOK" --task-dir 追踪/workflow/tasks/wf-source --source 素材/source.txt --json > "$TMP_DIR/first.json"
    printf '第二版来源内容\n' > "$BOOK/素材/source.txt"
    node "$REPO/scripts/source-ingest.js" --project-root "$BOOK" --task-dir 追踪/workflow/tasks/wf-source --source 素材/source.txt --json > "$TMP_DIR/second.json"

    node - "$TMP_DIR/first.json" "$TMP_DIR/second.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const first = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const second = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
assert.notEqual(first.source_digest, second.source_digest);
assert.notEqual(first.artifact_path, second.artifact_path);
assert.equal(first.source_id, second.source_id);
assert.equal(second.cache_status, 'refreshed');
NODE
}

@test "collection skills ingest raw sources once and reuse task artifacts" {
    for skill in \
        src/internal-skills/story-long-analyze/SKILL.md \
        src/internal-skills/story-long-scan/SKILL.md \
        src/internal-skills/story-short-scan/SKILL.md
    do
        run grep -F "source-ingest.js" "$REPO/$skill"
        [ "$status" -eq 0 ]
        run grep -F 'source_id' "$REPO/$skill"
        [ "$status" -eq 0 ]
        run grep -F 'source_digest' "$REPO/$skill"
        [ "$status" -eq 0 ]
        run grep -F 'artifact_path' "$REPO/$skill"
        [ "$status" -eq 0 ]
    done
}
