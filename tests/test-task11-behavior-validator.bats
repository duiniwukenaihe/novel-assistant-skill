#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    VALIDATOR="$REPO/scripts/task11-behavior-validator.js"
    FIXTURE="$REPO/tests/fixtures/task11-behavior-contract.json"
}

run_fixture_case() {
    run node "$VALIDATOR" --fixture "$FIXTURE" --case "$1" --json
    [ "$status" -eq 0 ]
    RESULT="$output"
}

@test "bare long-write invocation docks before prose generation" {
    run_fixture_case bare_invocation_docks

    run node -e 'const x=JSON.parse(process.argv[1]); if (x.result.decision !== "dock_preconditions" || x.result.proseCandidates.length !== 0 || x.result.writerPackets.length !== 0) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "outline_underfilled produces no prose candidate" {
    run_fixture_case outline_underfilled_blocks

    run node -e 'const x=JSON.parse(process.argv[1]); if (x.result.blockingReason !== "outline_underfilled" || x.result.proseCandidates.length !== 0 || x.result.writerPackets.length !== 0) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "a four-chapter request never executes chapter four" {
    run_fixture_case fourth_chapter_is_deferred

    run node -e 'const x=JSON.parse(process.argv[1]); const r=x.result; if (JSON.stringify(r.scheduledChapters) !== "[1,2,3]" || JSON.stringify(r.deferredChapters) !== "[4]" || r.writerPackets.some(p => p.chapter === 4)) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "writer packet receives one sanitized genre card after Chapter Contract" {
    run_fixture_case single_genre_card_is_sanitized

    run node -e 'const x=JSON.parse(process.argv[1]); const p=x.result.writerPackets[0]; const raw=JSON.stringify(p); if (JSON.stringify(p.assemblyOrder) !== JSON.stringify(["chapter_contract","genre_prose_card"]) || p.genreProseCards.length !== 1 || /sourceSample|complianceSelfReview|metadata|must-not-enter/.test(raw)) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "advisory findings neither block nor trigger mechanical rewrites" {
    run_fixture_case advisory_does_not_rewrite

    run node -e 'const x=JSON.parse(process.argv[1]); const r=x.result; if (r.blocking || r.automaticRewriteActions.length !== 0 || r.rejectedActions.length !== 3) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "anti-pandering keeps facts and chapter structure unchanged" {
    run_fixture_case anti_pandering_preserves_story

    run node -e 'const x=JSON.parse(process.argv[1]); const r=x.result; if (JSON.stringify(r.facts) !== JSON.stringify(["主角已经交出钥匙","守门人亲眼见证"]) || JSON.stringify(r.structure) !== JSON.stringify(["对质","交出钥匙","守门人放行"]) || !r.rejectedReasons.includes("fact_change_rejected") || !r.rejectedReasons.includes("structure_change_rejected")) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "production smoke executes the Task 11 behavior contract" {
    run node "$REPO/scripts/production-smoke-matrix.js" --json
    RESULT="$output"

    run node -e 'const x=JSON.parse(process.argv[1]); const c=x.globalChecks.find(item => item.id === "task11_behavior_contract"); if (!c || c.status !== "pass") process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "repository contracts match the executable Task 11 decisions" {
    run node "$VALIDATOR" --audit-repo --repo-root "$REPO" --json
    [ "$status" -eq 0 ]
    RESULT="$output"

    run node -e 'const x=JSON.parse(process.argv[1]); if (x.status !== "pass" || x.checkCount < 8 || x.findings.length !== 0) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}

@test "upstream trace accounts for all 112 commits with one tri-state each" {
    run node "$VALIDATOR" \
        --audit-trace \
        --repo-root "$REPO" \
        --range "0d555cfa..bf70c26" \
        --report "reports/upstream/20260710-bf70c26-commercial-closure.md" \
        --json
    [ "$status" -eq 0 ]
    RESULT="$output"

    run node -e 'const x=JSON.parse(process.argv[1]); if (x.status !== "pass" || x.commitCount !== 112 || x.tracedCount !== 112 || x.counts.absorb !== 3 || x.counts["already-covered"] !== 101 || x.counts["skip-with-reason"] !== 8) process.exit(1);' "$RESULT"
    [ "$status" -eq 0 ]
}
