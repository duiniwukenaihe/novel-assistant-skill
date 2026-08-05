#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/zcode-test-triage.js"
    FAKE="$REPO/tests/fixtures/fake-zcode-triage.js"
    FIXTURE="$(mktemp -d)"
    ARGV_LOG="$FIXTURE/argv.json"
    OUTPUT="$FIXTURE/glm.json"
    cat > "$FIXTURE/bats.json" <<'JSON'
{"schemaVersion":"1.0.0","runId":"triage-fixture","runner":"bats","total":2,"failed":0,"failures":[],"stdoutSha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","stdout":"1..2\nok 1 first\nok 2 second\n"}
JSON
    cat > "$FIXTURE/lite.json" <<'JSON'
{"schemaVersion":"1.0.0","runId":"triage-fixture","runner":"lite","total":2,"failed":1,"failures":[{"number":1,"name":"fixture failure"}],"stdoutSha256":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","stdout":"not ok 1 - fixture failure\nok 2 - second\n1..2\n"}
JSON
}

teardown() {
    rm -rf "$FIXTURE"
}

run_triage() {
    env \
      ZCODE_TRIAGE_ARGV_LOG="$ARGV_LOG" \
      FAKE_ZCODE_TRIAGE_MODE="${FAKE_ZCODE_TRIAGE_MODE:-valid}" \
      node "$SCRIPT" \
        --evidence "$FIXTURE/bats.json" \
        --evidence "$FIXTURE/lite.json" \
        --output "$OUTPUT" \
        --zcode "$FAKE" \
        "${@}"
}

@test "zcode triage is headless tool-denied and hash-bound" {
    run run_triage

    [ "$status" -eq 0 ]
    [ -f "$OUTPUT" ]
    node - "$ARGV_LOG" "$OUTPUT" <<'NODE'
const fs = require('fs');
const args = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const result = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const value = name => args[args.indexOf(name) + 1];
if (value('--mode') !== 'build' || value('--max-turns') !== '2') throw new Error(args.join(' '));
const denied = value('--disallowed-tools');
for (const tool of ['Bash', 'Edit', 'Write', 'NotebookEdit', 'WebFetch', 'WebSearch', 'Read', 'Glob', 'Grep', 'Agent', 'AskUserQuestion', 'EnterPlanMode', 'ExitPlanMode', 'Skill', 'TaskStop', 'TodoRead', 'TodoWrite', 'SendMessage', 'ReadSessionContext']) {
  if (!denied.includes(tool)) throw new Error(denied);
}
if (args.filter(arg => arg === '--attach').length !== 1) throw new Error(args.join(' '));
const projectionPath = value('--attach');
if (projectionPath !== `${process.argv[3]}.input.json`) throw new Error(projectionPath);
const projection = JSON.parse(fs.readFileSync(projectionPath, 'utf8'));
if (projection.runId !== 'triage-fixture' || projection.evidenceFiles.length !== 2) throw new Error(JSON.stringify(projection));
const names = projection.failureGroups.flatMap(group => group.failures.map(failure => failure.name));
if (!names.includes('fixture failure')) throw new Error(JSON.stringify(projection));
if (Object.hasOwn(projection.runners[0], 'stdout')) throw new Error('projection leaked full stdout');
if (args.includes('yolo') || args.includes('--allow-main-worktree-yolo')) throw new Error(args.join(' '));
if (result.runId !== 'triage-fixture' || result.model !== 'glm-test') throw new Error(JSON.stringify(result));
if (!/^sha256:[0-9a-f]{64}$/.test(result.evidenceSha256)) throw new Error(JSON.stringify(result));
NODE
}

@test "zcode triage accepts one fenced JSON response" {
    FAKE_ZCODE_TRIAGE_MODE=wrapped run run_triage

    [ "$status" -eq 0 ]
    [ -f "$OUTPUT" ]
}

@test "zcode triage retries without max-turns for packaged CLI help drift" {
    FAKE_ZCODE_TRIAGE_MODE=unsupported-max-turns run run_triage

    [ "$status" -eq 0 ]
    [ -f "$OUTPUT" ]
    node - "$ARGV_LOG" <<'NODE'
const fs = require('fs');
const args = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (args.includes('--max-turns')) throw new Error(args.join(' '));
if (args[args.indexOf('--mode') + 1] !== 'build') throw new Error(args.join(' '));
if (!args.includes('--disallowed-tools')) throw new Error(args.join(' '));
NODE
}

@test "zcode triage rejects mismatched evidence hash and malformed response" {
    FAKE_ZCODE_TRIAGE_MODE=mismatch run run_triage
    [ "$status" -eq 2 ]
    [[ "$output" == *"evidence hash mismatch"* ]]
    [ ! -e "$OUTPUT" ]

    FAKE_ZCODE_TRIAGE_MODE=invalid run run_triage
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not parse GLM JSON response"* ]]
    [ ! -e "$OUTPUT" ]

    FAKE_ZCODE_TRIAGE_MODE=unknown-name run run_triage
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown failure name"* ]]
}

@test "zcode triage rejects host failure and timeout" {
    FAKE_ZCODE_TRIAGE_MODE=nonzero run run_triage
    [ "$status" -eq 2 ]
    [[ "$output" == *"ZCode triage failed"* ]]

    FAKE_ZCODE_TRIAGE_MODE=timeout run run_triage --timeout-ms 100
    [ "$status" -eq 2 ]
    [[ "$output" == *"ZCode triage timed out"* ]]
}
