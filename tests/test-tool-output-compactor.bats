#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "tool output compactor preserves failures and test totals while removing repetition" {
    cat > "$TMP_DIR/raw.log" <<'LOG'
PASS tests/a.test.js
PASS tests/b.test.js
noise loading module
noise loading module
noise loading module
Tests: 2 passed, 2 total
Error: expected true but received false
    at tests/c.test.js:12:3
LOG

    node "$REPO/scripts/tool-output-compact.js" --input "$TMP_DIR/raw.log" --kind test --output "$TMP_DIR/summary.json" --json > "$TMP_DIR/result.json"

    node - "$TMP_DIR/summary.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(summary.kind, 'test');
assert(summary.raw_chars > summary.compacted_chars);
assert(summary.compression_ratio > 0);
assert(summary.errors.some((line) => line.includes('expected true')));
assert(summary.test_summary.some((line) => line.includes('2 passed')));
assert.equal(summary.repeated_lines_removed, 2);
NODE
}

@test "tool output compactor extracts changed files and keeps bounded context" {
    cat > "$TMP_DIR/raw.log" <<'LOG'
 M scripts/a.js
?? tests/a.test.js
scripts/a.js:18: Error: invalid state
scripts/a.js:19: useful context
scripts/a.js:20: useful context
LOG

    node "$REPO/scripts/tool-output-compact.js" --input "$TMP_DIR/raw.log" --kind generic --output "$TMP_DIR/summary.json" --json > /dev/null

    node - "$TMP_DIR/summary.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.deepEqual(summary.changed_files, ['scripts/a.js', 'tests/a.test.js']);
assert(summary.errors.some((line) => line.includes('invalid state')));
assert(summary.key_lines.length <= 24);
NODE
}
