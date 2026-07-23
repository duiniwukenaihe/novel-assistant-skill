#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/v08-story/valid"
}

@test "story-schema-validate.js validates v0.8 story fixture" {
    node "$REPO/scripts/story-schema-validate.js" "$FIXTURE"
}

@test "story-schema-validate.js rejects missing health" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/追踪/schema"
    cp "$FIXTURE/追踪/schema/story-state.json" "$tmp/追踪/schema/"
    cp "$FIXTURE/追踪/schema/chapters.jsonl" "$tmp/追踪/schema/"
    cp "$FIXTURE/追踪/schema/promises.jsonl" "$tmp/追踪/schema/"
    set +e
    output="$(node "$REPO/scripts/story-schema-validate.js" "$tmp" 2>&1)"
    status="$?"
    set -e
    [ "$status" -ne 0 ]
    [[ "$output" == *"health.json"* ]]
}

@test "story schema protocol is referenced by long write skill" {
    grep -q "v0-8-story-schema.md" "$REPO/src/internal-skills/story-long-write/SKILL.md"
    [ -f "$REPO/src/internal-skills/story-long-write/references/v0-8-story-schema.md" ]
}
