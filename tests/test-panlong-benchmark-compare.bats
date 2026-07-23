#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/panlong-benchmark-compare.js"
}

@test "panlong benchmark compare passes when candidate is baseline" {
    node "$SCRIPT" --repo-root "$REPO" --candidate "$REPO/demo/拆文库-盘龙" --json | grep -q '"status": "pass"'
}

@test "panlong benchmark compare accepts new ability rules artifact name" {
    candidate="${TMPDIR:-/tmp}/novel-assistant-panlong-candidate-$$"
    rm -rf "$candidate"
    cp -R "$REPO/demo/拆文库-盘龙" "$candidate"
    mv "$candidate/设定/世界观/力量体系.md" "$candidate/设定/世界观/能力与规则.md"

    node "$SCRIPT" --repo-root "$REPO" --candidate "$candidate" --json | grep -q '"status": "pass"'
    rm -rf "$candidate"
}

@test "panlong benchmark compare flags missing emotionally critical role files" {
    candidate="${TMPDIR:-/tmp}/novel-assistant-panlong-missing-role-$$"
    rm -rf "$candidate"
    cp -R "$REPO/demo/拆文库-盘龙" "$candidate"
    rm "$candidate/角色/沃顿.md"

    set +e
    out="$(node "$SCRIPT" --repo-root "$REPO" --candidate "$candidate" --json 2>&1)"
    status="$?"
    set -e

    [ "$status" -eq 1 ]
    echo "$out" | grep -q "missing_critical_role_file"
    echo "$out" | grep -q "沃顿"
    rm -rf "$candidate"
}

@test "panlong benchmark compare fails missing candidate" {
    missing="${TMPDIR:-/tmp}/novel-assistant-missing-panlong-candidate-$$"
    rm -rf "$missing"
    set +e
    out="$(node "$SCRIPT" --repo-root "$REPO" --candidate "$missing" --json 2>&1)"
    status="$?"
    set -e
    [ "$status" -eq 1 ]
    echo "$out" | grep -q "candidate_missing"
}
