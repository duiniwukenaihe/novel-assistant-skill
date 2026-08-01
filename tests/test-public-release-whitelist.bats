#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SYNC="$REPO/scripts/sync-sanitized-release-tree.js"
    SANITIZE="$REPO/scripts/sanitize-github-public-tree.js"
    FIXTURE="$(mktemp -d)"
    SOURCE="$FIXTURE/source"
    TARGET="$FIXTURE/target"
    mkdir -p "$SOURCE/config" "$SOURCE/docs" "$TARGET"
    git -C "$TARGET" init -q
}

teardown() {
    rm -rf "$FIXTURE"
}

@test "release sync defaults to target index and explicit additions" {
    printf 'updated public\n' > "$SOURCE/README.md"
    printf 'must stay private\n' > "$SOURCE/unapproved-private.txt"
    printf 'approved addition\n' > "$SOURCE/docs/new-public.md"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["docs/new-public.md"]
}
JSON
    printf 'old public\n' > "$TARGET/README.md"
    git -C "$TARGET" add README.md

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    grep -q 'updated public' "$TARGET/README.md"
    grep -q 'approved addition' "$TARGET/docs/new-public.md"
    [ -f "$TARGET/config/github-public-release-files.json" ]
    [ ! -e "$TARGET/unapproved-private.txt" ]
    [[ "$output" == *"target_git_index_plus_explicit_additions"* ]]
    [[ "$output" == *"unapproved-private.txt"* ]]
}

@test "release sync rejects unsafe explicit additions" {
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["../outside.txt"]
}
JSON

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"unsafe public release file"* ]]
}

@test "release sync rejects missing explicit additions" {
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": ["docs/missing-public.md"]
}
JSON

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 2 ]
    [[ "$output" == *"missing explicit public release file"* ]]
}

@test "release sync can revoke a baseline file while keeping it in source" {
    printf 'updated public\n' > "$SOURCE/README.md"
    printf 'still private on main\n' > "$SOURCE/revoked-public.txt"
    cat > "$SOURCE/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "additionalFiles": [],
  "removedFiles": ["revoked-public.txt"]
}
JSON
    printf 'old public\n' > "$TARGET/README.md"
    printf 'old public copy\n' > "$TARGET/revoked-public.txt"
    git -C "$TARGET" add README.md revoked-public.txt

    run node "$SYNC" --source-root "$SOURCE" --target-root "$TARGET" --write --json

    [ "$status" -eq 0 ]
    [ -f "$SOURCE/revoked-public.txt" ]
    [ ! -e "$TARGET/revoked-public.txt" ]
    [[ "$output" == *'"removedFiles": ['* ]]
    [[ "$output" == *"revoked-public.txt"* ]]
}

@test "public sanitizer removes generic local user paths" {
    printf '%s\n' \
        'documented placeholder: <local-user-path>/project' \
        'linux example: <local-user-path>/project' > "$SOURCE/README.md"

    run node "$SANITIZE" --repo-root "$SOURCE" --write --json

    [ "$status" -eq 0 ]
    readme="$(<"$SOURCE/README.md")"
    [[ "$readme" == *"<local-user-path>/project"* ]]
    [[ "$readme" != *"<local-user-path>"* ]]
    [[ "$readme" != *"<local-user-path>"* ]]
}
