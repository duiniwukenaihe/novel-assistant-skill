#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SETUP="$REPO/src/internal-skills/story-setup/SKILL.md"
    CHECK="$REPO/scripts/check-story-setup-deployment.sh"
    BUILD_MANIFEST="$REPO/config/novel-assistant-bundle-files.json"
    ENTRY="$REPO/skills/novel-assistant/SKILL.md"
    BUNDLE="$REPO/skills/novel-assistant"
}

@test "workflow entry guard is deployed by story-setup runtime script refresh" {
    grep -q "workflow-entry-guard.js" "$SETUP"
    grep -q "workflow-entry-guard.js" "$BUILD_MANIFEST"
    grep -q "workflow-entry-guard.js" "$ENTRY"
    test -x "$BUNDLE/scripts/workflow-entry-guard.js"
    grep -q "workflow-state-machine.js" "$SETUP"
    grep -q "workflow-state-machine.js" "$BUILD_MANIFEST"
    test -x "$BUNDLE/scripts/workflow-state-machine.js"
    grep -q "novel-assistant-sync-runtime.js" "$SETUP"
    grep -q "novel-assistant-sync-runtime.js" "$BUILD_MANIFEST"
    test -x "$BUNDLE/scripts/novel-assistant-sync-runtime.js"
    grep -q "review-escalation-policy.js" "$BUILD_MANIFEST"
    test -x "$BUNDLE/scripts/review-escalation-policy.js"
    node -e 'const m=require(process.argv[1]); if(Number(m.scriptCount||0)<69) process.exit(1)' "$BUNDLE/novel-assistant-manifest.json"
}

@test "story-setup deployment regression check passes with workflow entry guard" {
    bash "$CHECK"
}

@test "story memory context scripts are deployed and bundled" {
    grep -q "context-assembler.js" "$SETUP"
    grep -q "memory-recommender.js" "$SETUP"
    grep -q "memory-migrate.js" "$SETUP"
    grep -q "context-assembler.js" "$BUILD_MANIFEST"
    grep -q "memory-recommender.js" "$BUILD_MANIFEST"
    test -x "$BUNDLE/scripts/context-assembler.js"
    test -x "$BUNDLE/scripts/memory-recommender.js"
    test -x "$BUNDLE/scripts/memory-migrate.js"
    test -f "$BUNDLE/references/internal-skills/story-workflow/references/story-memory-context.md"
}
