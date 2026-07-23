#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/check-host-skill-discovery.js"
    BUNDLE="$REPO/skills/novel-assistant"
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

@test "static discovery validates every declared host without invoking a model" {
    for host in claude codex zcode opencode openclaw; do
        node "$SCRIPT" --bundle "$BUNDLE" --host "$host" --json > "$TMP/$host.json"
        node - "$TMP/$host.json" "$host" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (result.status !== 'pass') process.exit(1);
if (result.host !== process.argv[3]) process.exit(1);
if (result.discovery_mode !== 'static_read_only') process.exit(1);
if (!Array.isArray(result.checks) || !result.checks.every(item => item.status === 'pass')) process.exit(1);
if (!Array.isArray(result.mutations) || result.mutations.length !== 0) process.exit(1);
if (!result.expected_discovery_paths.length) process.exit(1);
NODE
    done
}

@test "static discovery leaves an isolated host home byte-identical" {
    export HOME="$TMP/isolated-home"
    mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.zcode"
    printf 'sentinel\n' > "$HOME/.claude/config-sentinel"
    before="$(node -e 'const fs=require("fs"),c=require("crypto"); process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.claude/config-sentinel")"

    node "$SCRIPT" --bundle "$BUNDLE" --host openclaw --json > "$TMP/out.json"

    after="$(node -e 'const fs=require("fs"),c=require("crypto"); process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$HOME/.claude/config-sentinel")"
    [ "$before" = "$after" ]
    [ "$(find "$HOME" -type f | wc -l | tr -d ' ')" -eq 1 ]
    grep -q '"mutations": \[\]' "$TMP/out.json"
}

@test "unsupported hosts fail with a stable error" {
    run node "$SCRIPT" --bundle "$BUNDLE" --host imaginary --json
    [ "$status" -eq 2 ]
    [[ "$output" == *"unsupported_host"* ]]
}

@test "required bundle files cannot escape through symlinks" {
    cp -R "$BUNDLE" "$TMP/bundle"
    rm "$TMP/bundle/SKILL.md"
    printf '%s\n' 'outside' > "$TMP/outside.md"
    ln -s "$TMP/outside.md" "$TMP/bundle/SKILL.md"

    run node "$SCRIPT" --bundle "$TMP/bundle" --host codex --json
    [ "$status" -eq 1 ]
    [[ "$output" == *"symlink_not_allowed"* ]]
}

@test "na-dev exposes the host discovery facade" {
    node "$REPO/scripts/na-dev.js" --help | grep -q 'host-discovery'
    node "$REPO/scripts/na-dev.js" host-discovery --bundle "$BUNDLE" --host codex --json |
        grep -q '"status": "pass"'
}
