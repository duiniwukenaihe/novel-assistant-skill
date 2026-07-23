#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/na-dev.js"
}

@test "na-dev facade exists and documents common commands" {
    test -f "$SCRIPT"
    output="$(node "$SCRIPT" --help)"
    echo "$output" | grep -q "Maintainer command facade"
    echo "$output" | grep -q "verify"
    echo "$output" | grep -q "smoke"
    echo "$output" | grep -q "audit"
    echo "$output" | grep -q "bundle"
    echo "$output" | grep -q "install-local-private"
    echo "$output" | grep -q "upstream"
    echo "$output" | grep -q "short-write-sync"
    echo "$output" | grep -q "host-discovery"
}

@test "na-dev local private install command forces private bundle and verifies overlay" {
    grep -q "install-local-private" "$SCRIPT"
    grep -q "NOVEL_ASSISTANT_INCLUDE_PRIVATE: '1'" "$SCRIPT"
    grep -q ".zcode" "$SCRIPT"
    grep -q "privateInternalSkillCount" "$SCRIPT"
    grep -q "private_short_startup" "$SCRIPT"
    grep -q "workflow-state-machine.js" "$SCRIPT"
    grep -q "cwd: target" "$SCRIPT"
    grep -q "maxBuffer" "$SCRIPT"
}

@test "na-dev exposes short-write public and private sync command" {
    grep -q "sync-private-short-write-absorption.js" "$SCRIPT"
    node "$SCRIPT" short-write-sync --repo-root "$REPO" --check --json | grep -q '"mode":"public_and_private_short_write_sync"'
}

@test "na-dev rejects unknown commands" {
    set +e
    out="$("$SCRIPT" nope 2>&1)"
    status="$?"
    set -e
    [ "$status" -eq 2 ]
    echo "$out" | grep -q "Unknown command"
}

@test "script docs mention na-dev as maintainer facade" {
    grep -q "na-dev.js" "$REPO/scripts/README.md"
    grep -q "维护者统一入口" "$REPO/scripts/README.md"
}
