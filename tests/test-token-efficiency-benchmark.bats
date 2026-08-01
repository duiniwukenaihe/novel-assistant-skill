#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/token-efficiency"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "token efficiency benchmark verifies routing compaction reuse and gate coverage" {
    node "$REPO/scripts/token-efficiency-benchmark.js" --fixture-dir "$FIXTURES" --json > "$TMP_DIR/report.json"

    node - "$TMP_DIR/report.json" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(report.status, 'pass');
assert.equal(report.task_results['short-section'].recommended_agent_count, 1);
assert.equal(report.task_results['long-review'].recommended_agent_count, 3);
assert(report.tool_output.compression_ratio >= 0.6);
assert.equal(report.sources.raw_source_reads, 2);
assert.equal(report.sources.artifact_reuses, 1);
assert.deepEqual(report.quality_gates, ['machine_gate', 'story_gate', 'continuity_gate']);
NODE
}
