#!/usr/bin/env bats

@test "short-analyze-quick-mode reference exists" {
    [ -f "$BATS_TEST_DIRNAME/../src/internal-skills/story-short-analyze/references/short-analyze-quick-mode.md" ]
}

@test "short-analyze SKILL.md mentions quick mode" {
    grep -q -i "quick" "$BATS_TEST_DIRNAME/../src/internal-skills/story-short-analyze/SKILL.md"
}

@test "under-3k fixture is < 3000 chars" {
    chars=$(wc -m < "$BATS_TEST_DIRNAME/fixtures/short-analyze-quick/under-3k.txt" | tr -d ' ')
    [ "$chars" -lt 3000 ]
}

@test "under-3k fixture is > 500 chars" {
    chars=$(wc -m < "$BATS_TEST_DIRNAME/fixtures/short-analyze-quick/under-3k.txt" | tr -d ' ')
    [ "$chars" -gt 500 ]
}
