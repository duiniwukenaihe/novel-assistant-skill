#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    BUILD="$REPO/scripts/build-oh-story-bundle.sh"
    SYNC="$REPO/scripts/novel-assistant-sync-runtime.js"
    CHECK="$REPO/scripts/check-story-setup-deployment.sh"
    SMOKE="$REPO/scripts/production-smoke-matrix.js"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    CONTRACT="$REPO/src/internal-skills/story-workflow/references/workflow-contract.md"
    README="$REPO/README.md"
    README_EN="$REPO/README_EN.md"
    SCRIPTS_README="$REPO/scripts/README.md"
    BUNDLE="$REPO/skills/novel-assistant"
}

@test "workflow runner is part of build setup and runtime synchronization" {
    grep -q 'workflow-runner.js' "$BUILD"
    grep -q 'workflow-session-heartbeat.js' "$BUILD"
    grep -q 'workflow-runner.js' "$SYNC"
    grep -q 'workflow-session-heartbeat.js' "$SYNC"
    grep -q 'workflow-runner.js' "$CHECK"
    grep -q 'workflow-session-heartbeat.js' "$CHECK"
    grep -q 'workflow-runner.js' "$SMOKE"
    grep -q 'workflow-supervisor.js' "$BUILD"
    grep -q 'workflow-supervisor.js' "$SYNC"
    grep -q 'workflow-supervisor.js' "$CHECK"
    grep -q 'workflow-supervisor.js' "$SMOKE"
}

@test "workflow runner contract is documented for users and internal modules" {
    grep -q '工作流运行器' "$README"
    grep -qi 'workflow runner' "$README_EN"
    grep -q 'workflow-runner.js' "$SCRIPTS_README"
    grep -q 'workflow-runner.js' "$WORKFLOW"
    grep -q 'workflow-runner.js' "$CONTRACT"
    grep -q 'workflow-supervisor.js' "$SCRIPTS_README"
    grep -q 'workflow-supervisor.js' "$CONTRACT"
}

@test "workflow runner and host libraries are present in the single-directory bundle" {
    test -x "$BUNDLE/scripts/workflow-runner.js"
    test -x "$BUNDLE/scripts/workflow-session-heartbeat.js"
    test -x "$BUNDLE/scripts/workflow-supervisor.js"
    test -f "$BUNDLE/scripts/lib/workflow-host-adapters.js"
    test -f "$BUNDLE/scripts/lib/workflow-supervisor-store.js"
    test -f "$BUNDLE/scripts/lib/workflow-stream-health.js"
}
