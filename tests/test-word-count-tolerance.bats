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

@test "word count gate repairs overage beyond twenty percent" {
    run node "$SCRIPT" --actual 4550 --target 3400 --unit section --json

    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"status":"blocking"'
    echo "$output" | grep -q '"verdict":"over_target_repair_required"'
    echo "$output" | grep -q '"blocking":true'
    echo "$output" | grep -q '"recommended_action":"remove_repetition_or_split_overloaded_section"'
}

@test "word count gate automatically repairs section deficits beyond ten percent" {
    run node "$SCRIPT" --actual 2699 --target 3000 --unit section --json

    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"status":"blocking"'
    echo "$output" | grep -q '"verdict":"under_target_repair_required"'
    echo "$output" | grep -q '"blocking":true'
    echo "$output" | grep -q '"hard_floor":2700'
    echo "$output" | grep -q '"recommended_action":"add_story_events_or_redesign_section"'
}

@test "word count gate accepts chapter shortfall within ten percent without padding loop" {
    run node "$SCRIPT" --actual 2700 --target 3000 --unit chapter --json

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status":"warning"'
    echo "$output" | grep -q '"verdict":"under_target_within_tolerance"'
    echo "$output" | grep -q '"blocking":false'
    echo "$output" | grep -q '"lower_tolerance":300'
    echo "$output" | grep -q '"hard_floor":2700'
}

@test "word count gate accepts chapter overage within twenty percent without compression loop" {
    run node "$SCRIPT" --actual 3600 --target 3000 --unit chapter --json

    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status":"pass"'
    echo "$output" | grep -q '"verdict":"within_target_band"'
    echo "$output" | grep -q '"blocking":false'
    echo "$output" | grep -q '"upper_tolerance":600'
    echo "$output" | grep -q '"hard_ceiling":3600'
}

@test "word count gate automatically repairs chapter deficits beyond ten percent" {
    run node "$SCRIPT" --actual 2699 --target 3000 --unit chapter --json

    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"status":"blocking"'
    echo "$output" | grep -q '"verdict":"under_target_repair_required"'
    echo "$output" | grep -q '"blocking":true'
    echo "$output" | grep -q '"hard_floor":2700'
}

@test "word count gate automatically repairs chapter overage beyond twenty percent" {
    run node "$SCRIPT" --actual 3601 --target 3000 --unit chapter --json

    [ "$status" -eq 2 ]
    echo "$output" | grep -q '"status":"blocking"'
    echo "$output" | grep -q '"verdict":"over_target_repair_required"'
    echo "$output" | grep -q '"blocking":true'
    echo "$output" | grep -q '"hard_ceiling":3600'
}
