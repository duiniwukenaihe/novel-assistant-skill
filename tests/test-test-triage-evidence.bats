#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/test-triage-evidence.js"
    FIXTURE="$(mktemp -d)"
}

teardown() {
    rm -rf "$FIXTURE"
}

@test "triage evidence parser records TAP totals failures and digest" {
    run node - "$SCRIPT" <<'NODE'
const script = require(process.argv[2]);
const tap = `1..3
ok 1 first behavior
not ok 2 second behavior
ok 3 third behavior
`;
const parsed = script.parseTap(tap);
const digest = script.sha256(tap);
if (parsed.total !== 3 || parsed.failed !== 1) throw new Error(JSON.stringify(parsed));
if (parsed.failures[0]?.name !== 'second behavior') throw new Error(JSON.stringify(parsed));
if (!/^sha256:[0-9a-f]{64}$/.test(digest)) throw new Error(digest);
console.log(JSON.stringify({ parsed, digest }));
NODE

    [ "$status" -eq 0 ]
    [[ "$output" == *'"failed":1'* ]]
}

@test "triage evidence rejects unsafe runner output and test arguments" {
    run node "$SCRIPT" --run-id unsafe --runner shell --output "$FIXTURE/out.json" -- tests/test-public-release-whitelist.bats
    [ "$status" -eq 2 ]
    [[ "$output" == *"runner must be bats or lite"* ]]

    run node "$SCRIPT" --run-id unsafe --runner bats --output relative.json -- tests/test-public-release-whitelist.bats
    [ "$status" -eq 2 ]
    [[ "$output" == *"output must be absolute"* ]]

    run node "$SCRIPT" --run-id unsafe --runner bats --output "$FIXTURE/out.json" -- README.md
    [ "$status" -eq 2 ]
    [[ "$output" == *"test file must stay under tests"* ]]
}

@test "triage evidence captures a real bats suite as structured JSON" {
    evidence_file="$FIXTURE/evidence.json"

    run node "$SCRIPT" \
      --run-id evidence-fixture \
      --runner bats \
      --output "$evidence_file" \
      -- tests/test-public-release-whitelist.bats

    [ "$status" -eq 0 ]
    [ -f "$evidence_file" ]
    node - "$evidence_file" <<'NODE'
const fs = require('fs');
const evidence = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (evidence.schemaVersion !== '1.0.0') throw new Error(JSON.stringify(evidence));
if (evidence.runId !== 'evidence-fixture' || evidence.runner !== 'bats') throw new Error(JSON.stringify(evidence));
if (evidence.exitCode !== 0 || evidence.total < 1 || evidence.failed !== 0) throw new Error(JSON.stringify(evidence));
if (!/^sha256:[0-9a-f]{64}$/.test(evidence.stdoutSha256)) throw new Error(JSON.stringify(evidence));
if (!Array.isArray(evidence.command) || !evidence.command.includes('tests/test-public-release-whitelist.bats')) throw new Error(JSON.stringify(evidence));
NODE
}
