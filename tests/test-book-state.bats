#!/usr/bin/env bats
# tests/test-book-state.bats

setup() {
    TEST_TMP="$(mktemp -d)"
    export BOOK_STATE_LIB="$BATS_TEST_DIRNAME/../src/internal-skills/story-setup/references/templates/hooks/lib/book-state.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "book_state_exists returns false when file missing" {
    source "$BOOK_STATE_LIB"
    ! book_state_exists "$TEST_TMP/nonexistent"
}

@test "book_state_get_field reads currentChapter" {
    cp "$BATS_TEST_DIRNAME/fixtures/book-state/sample-active.json" "$TEST_TMP/.book-state.json"
    source "$BOOK_STATE_LIB"
    [ "$(book_state_get_field "$TEST_TMP" currentChapter)" = "21" ]
}

@test "book_state_get_status returns in_progress" {
    cp "$BATS_TEST_DIRNAME/fixtures/book-state/sample-active.json" "$TEST_TMP/.book-state.json"
    source "$BOOK_STATE_LIB"
    [ "$(book_state_get_status "$TEST_TMP")" = "in_progress" ]
}

@test "book_state_set_status writes atomically" {
    cp "$BATS_TEST_DIRNAME/fixtures/book-state/sample-active.json" "$TEST_TMP/.book-state.json"
    source "$BOOK_STATE_LIB"
    book_state_set_status "$TEST_TMP" "completed"
    [ "$(book_state_get_status "$TEST_TMP")" = "completed" ]
}

@test "book-state template declares layout compatibility fields" {
    tmpl="$BATS_TEST_DIRNAME/../src/internal-skills/story-setup/references/templates/.book-state.json.tmpl"

    grep -q '"chapterLayout"' "$tmpl"
    grep -q '"preferredVolume"' "$tmpl"
    grep -q '"allowLegacyFlat"' "$tmpl"
}
