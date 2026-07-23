#!/usr/bin/env bats
# tests/test-upstream-check.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/check-upstream.sh"
    TMP_DIR="$(mktemp -d)"
    export GIT_AUTHOR_NAME="Test"
    export GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test"
    export GIT_COMMITTER_EMAIL="test@example.com"
}

teardown() {
    rm -rf "$TMP_DIR"
}

make_commit() {
    file="$1"
    message="$2"
    printf '%s\n' "$message" >> "$file"
    git add "$file"
    git commit -q -m "$message"
}

@test "check-upstream reports upstream commits and missing tags" {
    upstream="$TMP_DIR/upstream"
    localrepo="$TMP_DIR/local"

    mkdir "$upstream"
    cd "$upstream"
    git init -q -b main
    make_commit story.txt "base commit"
    git tag v1.0.0

    git clone -q "$upstream" "$localrepo"

    cd "$upstream"
    make_commit story.txt "upstream feature"
    git tag v1.1.0

    cd "$localrepo"
    output="$(bash "$SCRIPT" --repo "$upstream" --branch main --max-commits 20)"

    echo "$output" | grep -q "# Upstream Check Report"
    echo "$output" | grep -q "Upstream-only commits"
    echo "$output" | grep -q "upstream feature"
    echo "$output" | grep -q "Missing Upstream Tags Locally"
    echo "$output" | grep -q "v1.1.0"
    ! git tag --list | grep -q '^v1.1.0$'
}

@test "check-upstream writes report when requested" {
    upstream="$TMP_DIR/upstream-write"
    localrepo="$TMP_DIR/local-write"

    mkdir "$upstream"
    cd "$upstream"
    git init -q -b main
    make_commit story.txt "base commit"
    git tag v1.0.0

    git clone -q "$upstream" "$localrepo"

    cd "$upstream"
    make_commit story.txt "upstream patch"

    cd "$localrepo"
    bash "$SCRIPT" --repo "$upstream" --branch main --write --report-dir "$TMP_DIR/reports" >/dev/null

    report_count="$(find "$TMP_DIR/reports" -type f -name '*-upstream-check.md' | wc -l | tr -d ' ')"
    [ "$report_count" -eq 1 ]
    grep -q "upstream patch" "$TMP_DIR"/reports/*-upstream-check.md
}

@test "check-upstream maps upstream story skill files to novel-assistant internal targets" {
    upstream="$TMP_DIR/upstream-map"
    localrepo="$TMP_DIR/local-map"

    mkdir -p "$upstream/src/internal-skills/story-long-write"
    cd "$upstream"
    git init -q -b main
    echo "base" > src/internal-skills/story-long-write/SKILL.md
    make_commit src/internal-skills/story-long-write/SKILL.md "base story skill"

    git clone -q "$upstream" "$localrepo"

    cd "$upstream"
    echo "upstream change" >> src/internal-skills/story-long-write/SKILL.md
    make_commit src/internal-skills/story-long-write/SKILL.md "upstream story-long-write change"

    cd "$localrepo"
    output="$(bash "$SCRIPT" --repo "$upstream" --branch main --max-commits 20)"

    echo "$output" | grep -q "Novel Assistant Backport Target Mapping"
    echo "$output" | grep -q "src/internal-skills/story-long-write/SKILL.md"
    echo "$output" | grep -q "skills/novel-assistant/references/internal-skills/story-long-write/SKILL.md"
    echo "$output" | grep -q "current-source-and-generated-bundle"
}

@test "README documents where upstream version records live" {
    README="$REPO/README.md"

    grep -q "reports/upstream/" "$README"
    grep -q "Upstream HEAD" "$README"
    grep -q "Tag Comparison" "$README"
    grep -q "Backport Triage Template" "$README"
}
