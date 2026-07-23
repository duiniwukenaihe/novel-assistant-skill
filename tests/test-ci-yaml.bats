#!/usr/bin/env bats

@test "cross-platform.yml exists" {
    [ -f "$BATS_TEST_DIRNAME/../.github/workflows/cross-platform.yml" ]
}

@test "cross-platform.yml has concurrency group" {
    grep -q "concurrency:" "$BATS_TEST_DIRNAME/../.github/workflows/cross-platform.yml"
}

@test "cross-platform.yml disables npm cache when the repository has no lockfile" {
    repo="$BATS_TEST_DIRNAME/.."
    workflow="$repo/.github/workflows/cross-platform.yml"
    ! test -f "$repo/package-lock.json"
    ! test -f "$repo/npm-shrinkwrap.json"
    ! test -f "$repo/yarn.lock"
    ! test -f "$repo/pnpm-lock.yaml"
    ! grep -Eq "^[[:space:]]*cache:[[:space:]]*['\"]?npm['\"]?[[:space:]]*$" "$workflow"
}

@test "cross-platform.yml has matrix for Node 20 and 22" {
    grep -q "matrix:" "$BATS_TEST_DIRNAME/../.github/workflows/cross-platform.yml"
    grep -q "20" "$BATS_TEST_DIRNAME/../.github/workflows/cross-platform.yml"
    grep -q "22" "$BATS_TEST_DIRNAME/../.github/workflows/cross-platform.yml"
}
