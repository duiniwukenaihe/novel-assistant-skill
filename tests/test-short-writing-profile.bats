#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/short-writing-profile.js"
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

@test "selector returns one verified platform profile and one genre card" {
    node "$SCRIPT" --platform "番茄短篇" --genre "悬疑反转" --json > "$TMP/out.json"

    node - "$TMP/out.json" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (result.status !== 'ok') process.exit(1);
if (result.platform_profile.id !== 'fanqie-short') process.exit(1);
if (result.genre_card !== 'references/genre-styles/悬疑.md') process.exit(1);
if (result.confidence !== 'reviewed') process.exit(1);
if (!result.evidence || !result.evidence.source) process.exit(1);
NODE
}

@test "selector normalizes common platform and genre aliases" {
    node "$SCRIPT" --platform "盐言" --genre "民俗" --json > "$TMP/out.json"

    node - "$TMP/out.json" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (result.platform_profile.id !== 'zhihu-yanxuan') process.exit(1);
if (result.genre_card !== 'references/genre-styles/民俗怪谈.md') process.exit(1);
NODE
}

@test "unknown input falls back without pretending to be verified" {
    node "$SCRIPT" --platform "未知渠道" --genre "未知混合题材" --json > "$TMP/out.json"

    node - "$TMP/out.json" <<'NODE'
const fs = require('fs');
const result = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (result.status !== 'fallback') process.exit(1);
if (result.platform_profile.id !== 'generic') process.exit(1);
if (result.genre_card !== 'references/genre-writing-formulas.md') process.exit(1);
if (result.confidence !== 'unverified') process.exit(1);
NODE
}

@test "selector rejects missing values with a clear usage error" {
    run node "$SCRIPT" --platform "番茄短篇" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"--genre"* ]]
}
