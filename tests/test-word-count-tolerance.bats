#!/usr/bin/env bats
# tests/test-word-count-tolerance.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/word-count-tolerance.js"
}

@test "word count gate accepts small shortfall without padding loop" {
    run node "$SCRIPT" --actual 3330 --target 3400 --unit section --json

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status":"warning"'
    echo "$output" | grep -q '"verdict":"under_target_within_tolerance"'
    echo "$output" | grep -q '"blocking":false'
    echo "$output" | grep -q '"recommended_action":"accept_if_story_complete"'
    echo "$output" | grep -q '不要为了几十字或一两百字反复补水'
}

@test "word count gate accepts small overage without compression loop" {
    run node "$SCRIPT" --actual 3560 --target 3400 --unit section --json

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status":"pass"'
    echo "$output" | grep -q '"verdict":"within_target_band"'
    echo "$output" | grep -q '"blocking":false'
    echo "$output" | grep -q '"recommended_action":"keep_narrative_shape"'
}

@test "word count gate warns on large overage but does not compress by default" {
    run node "$SCRIPT" --actual 4550 --target 3400 --unit section --json

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status":"warning"'
    echo "$output" | grep -q '"verdict":"over_target_review_pacing"'
    echo "$output" | grep -q '"blocking":false'
    echo "$output" | grep -q '"recommended_action":"review_pacing_not_mechanical_compress"'
}

@test "word count gate blocks only clear underfloor drafts" {
    run node "$SCRIPT" --actual 480 --target 800 --unit section --json

    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"status":"blocking"'
    echo "$output" | grep -q '"verdict":"under_hard_floor"'
    echo "$output" | grep -q '"blocking":true'
    echo "$output" | grep -q '"recommended_action":"add_story_events_or_redesign_section"'
}
