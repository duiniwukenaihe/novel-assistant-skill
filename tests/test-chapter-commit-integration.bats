#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    DAILY="$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    CONTRACT="$REPO/src/internal-skills/story-workflow/references/workflow-contract.md"
    SETUP="$REPO/src/internal-skills/story-setup/SKILL.md"
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    DEPLOY_CHECK="$REPO/scripts/check-story-setup-deployment.sh"
    BUNDLE_MANIFEST="$REPO/config/novel-assistant-bundle-files.json"
}

@test "long-form daily workflow accepts a chapter commit before advancing" {
    grep -q '章节提交事务' "$DAILY"
    grep -q 'chapter-commit.js prepare' "$DAILY"
    grep -q 'chapter-commit.js accept' "$DAILY"
    grep -q 'accepted_with_projection_debt' "$DAILY"
    grep -q 'legacy_nontransactional' "$DAILY"
    grep -q '不得进入下一章' "$DAILY"
}

@test "workflow contract treats accepted chapter commit as production completion proof" {
    grep -q 'chapter_commit' "$WORKFLOW"
    grep -q 'accepted_commit_id' "$WORKFLOW"
    grep -q 'accepted chapter commit' "$CONTRACT"
    grep -q 'staged_artifacts' "$CONTRACT"
    grep -q 'projection_debt' "$CONTRACT"
    grep -q 'legacy_nontransactional' "$CONTRACT"
}

@test "canonical protocol requires an accepted transaction for strict review repairs" {
    grep -q 'review_repair' "$REPO/src/internal-skills/story-workflow/references/canonical-write-protocol.md"
    grep -q 'accepted chapter commit' "$REPO/src/internal-skills/story-workflow/references/canonical-write-protocol.md"
    grep -q 'strict' "$REPO/src/internal-skills/story-workflow/references/canonical-write-protocol.md"
}

@test "chapter transaction runtime is included in bundle and project deployment" {
    node -e 'const m=require(process.argv[1]); if(!m.scriptFiles.includes("chapter-commit.js")) process.exit(1)' "$BUNDLE_MANIFEST"
    grep -q 'chapter-commit.js' "$SETUP"
    test -f "$REPO/skills/novel-assistant/scripts/chapter-commit.js"
    test -f "$REPO/scripts/lib/chapter-commit-store.js"
    test -f "$REPO/scripts/lib/memory-projection.js"
}

@test "prose gate inspects a staged draft outside the canonical prose directory" {
    project="$BATS_TEST_TMPDIR/book"
    staged="$project/追踪/story-system/work/wf-1/第1卷/第001章/正文.md"
    mkdir -p "$project/正文" "$(dirname "$staged")"
    printf '# 第一章\n他—停在门口。\n' > "$staged"

    run node "$REPO/scripts/story-prose-gate.js" "$staged" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *'"type": "invalid-dash"'* ]]
    [[ "$output" == *'追踪/story-system/work/wf-1/第1卷/第001章/正文.md'* ]]
}
