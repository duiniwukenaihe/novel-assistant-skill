#!/usr/bin/env bats
# tests/test-review-state-ledger.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/review-state-ledger.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "review state ledger records dependency hashes and marks stale after dependency changes" {
    book="$TMP_DIR/book"
    mkdir -p "$book/追踪/审查报告" "$book/正文"
    echo "第1章正文" > "$book/正文/chapter001.md"
    echo "伏笔A：open" > "$book/追踪/伏笔.md"
    echo "# 批次报告" > "$book/追踪/审查报告/批次_1-100.md"

    node "$SCRIPT" record \
        --book-root "$book" \
        --range "1-100" \
        --report "追踪/审查报告/批次_1-100.md" \
        --scope-mode "continuous" \
        --dependency "追踪/伏笔.md" \
        --json > "$TMP_DIR/record.json"

    [ -f "$book/追踪/review-state.json" ]
    grep -q '"range": "1-100"' "$book/追踪/review-state.json"
    grep -q '"dependency_hashes"' "$book/追踪/review-state.json"
    grep -q '"status": "current"' "$book/追踪/review-state.json"

    echo "伏笔A：paid_off" > "$book/追踪/伏笔.md"

    node "$SCRIPT" check --book-root "$book" --write --json > "$TMP_DIR/check.json"

    node - "$TMP_DIR/check.json" "$book/追踪/review-state.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const state = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (out.staleReviews.length !== 1) throw new Error(`expected one stale review: ${JSON.stringify(out)}`);
const review = state.reviews[0];
if (review.status !== 'stale') throw new Error(`expected stale status: ${review.status}`);
if (!review.stale_reason.includes('dependency_hash_changed')) throw new Error(`missing stale reason: ${review.stale_reason}`);
if (!review.suggested_recheck_ranges.includes('1-100')) throw new Error(`missing suggested range: ${JSON.stringify(review)}`);
NODE
}

@test "review state contract is documented in story-review and bundled by setup" {
    grep -q "追踪/review-state.json" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "dependency_hashes" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "stale" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "suggested_recheck_ranges" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "review-state-ledger.js" "$REPO/src/internal-skills/story-review/SKILL.md"
    grep -q "review-state-ledger.js" "$REPO/scripts/build-oh-story-bundle.sh"
    grep -q "review-state-ledger.js" "$REPO/src/internal-skills/story-setup/SKILL.md"
}
