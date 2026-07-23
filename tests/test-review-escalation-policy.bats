#!/usr/bin/env bats
# tests/test-review-escalation-policy.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/review-escalation-policy.js"
    BUNDLE="$REPO/skills/novel-assistant"
    WORKFLOW="$REPO/src/internal-skills/story-workflow"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write/SKILL.md"
    SHORT_WRITE="$REPO/src/internal-skills/story-short-write/SKILL.md"
    REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
    SCRIPTS_README="$REPO/scripts/README.md"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "normal passed chapter does not trigger multi-role review" {
    node "$SCRIPT" --json --chapter 3 --machine-gate pass --story-value pass > "$TMP_DIR/out.json"

    grep -q '"status": "ok"' "$TMP_DIR/out.json"
    grep -q '"escalation": "none"' "$TMP_DIR/out.json"
    grep -q '"next_action": "continue_handoff"' "$TMP_DIR/out.json"
    grep -q '"cost_class": "low"' "$TMP_DIR/out.json"
}

@test "periodic chapters trigger light dual-role review only" {
    node "$SCRIPT" --json --chapter 10 --batch-size 5 --machine-gate pass --story-value pass > "$TMP_DIR/out.json"

    grep -q '"escalation": "light_dual_role"' "$TMP_DIR/out.json"
    grep -q '"reader_value"' "$TMP_DIR/out.json"
    grep -q '"continuity"' "$TMP_DIR/out.json"
    ! grep -q '"character_motivation"' "$TMP_DIR/out.json"
    grep -q '"next_action": "run_light_review"' "$TMP_DIR/out.json"
}

@test "key chapters and user quality complaints trigger full multi-role review" {
    node "$SCRIPT" --json --chapter 11 --chapter-type climax --machine-gate pass --story-value pass > "$TMP_DIR/key.json"
    node "$SCRIPT" --json --chapter 12 --machine-gate pass --story-value pass --user-feedback "人物不像人，剧情不合理，没爽点" > "$TMP_DIR/feedback.json"

    for file in "$TMP_DIR/key.json" "$TMP_DIR/feedback.json"; do
        grep -q '"escalation": "full_multi_role"' "$file"
        grep -q '"reader_value"' "$file"
        grep -q '"continuity"' "$file"
        grep -q '"character_motivation"' "$file"
        grep -q '"commercial_hook"' "$file"
        grep -q '"next_action": "run_full_review"' "$file"
        grep -q '"cost_class": "high"' "$file"
    done
}

@test "machine blocking repairs current unit before any multi-role review" {
    node "$SCRIPT" --json --chapter 5 --machine-gate blocking --story-value pass > "$TMP_DIR/out.json"

    grep -q '"escalation": "none"' "$TMP_DIR/out.json"
    grep -q '"reason_codes": \[' "$TMP_DIR/out.json"
    grep -q '"machine_blocking_repair_first"' "$TMP_DIR/out.json"
    grep -q '"next_action": "repair_current_unit"' "$TMP_DIR/out.json"
    ! grep -q '"run_light_review"' "$TMP_DIR/out.json"
    ! grep -q '"run_full_review"' "$TMP_DIR/out.json"
}

@test "review escalation policy is documented and bundled" {
    test -f "$WORKFLOW/references/review-escalation-policy.md"
    grep -q "review-escalation-policy.js" "$WORKFLOW/SKILL.md"
    grep -q "review-escalation-policy.md" "$WORKFLOW/SKILL.md"
    grep -q "review_escalation_result" "$WORKFLOW/references/workflow-contract.md"
    grep -q "review-escalation-policy.js" "$LONG_WRITE"
    grep -q "review-escalation-policy.js" "$SHORT_WRITE"
    grep -q "review_escalation_policy" "$REVIEW"
    grep -q "review-escalation-policy.js" "$SCRIPTS_README"
    test -x "$SCRIPT"
    test -x "$BUNDLE/scripts/review-escalation-policy.js"
}
