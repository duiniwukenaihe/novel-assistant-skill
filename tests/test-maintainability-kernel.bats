#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    KERNEL="$REPO/src/internal-skills/story-workflow/references/maintainability-kernel.md"
    WORKFLOW_CONTRACT="$REPO/src/internal-skills/story-workflow/references/workflow-contract.md"
    OUTPUT_CONTRACT="$REPO/src/internal-skills/story-workflow/references/output-safety-contract.md"
    AUDIT="$REPO/scripts/maintainability-audit.js"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
}

@test "maintainability kernel reference files exist with required anchors" {
    [ -f "$KERNEL" ]
    [ -f "$WORKFLOW_CONTRACT" ]
    [ -f "$OUTPUT_CONTRACT" ]

    grep -q "single_entry" "$KERNEL"
    grep -q "l2_l3_boundary" "$KERNEL"
    grep -q "upstream_absorption_gate" "$KERNEL"

    grep -q "workflow packet" "$WORKFLOW_CONTRACT"
    grep -q "result packet" "$WORKFLOW_CONTRACT"
    grep -q "runtime_guard" "$WORKFLOW_CONTRACT"
    grep -q "pending_action" "$WORKFLOW_CONTRACT"

    grep -q "blocked_model_degradation" "$OUTPUT_CONTRACT"
    grep -q "blocked_tool_command_contaminated" "$OUTPUT_CONTRACT"
    grep -q "blocked_write_failure" "$OUTPUT_CONTRACT"
}

@test "story-workflow references all maintainability kernel contracts" {
    grep -q "maintainability-kernel.md" "$WORKFLOW"
    grep -q "workflow-contract.md" "$WORKFLOW"
    grep -q "output-safety-contract.md" "$WORKFLOW"
}

@test "high risk L3 modules reference workflow and output safety contracts" {
    for module in story-long-write story-review story-long-analyze story-deslop story-short-write story-setup; do
        grep -q "workflow-contract.md" "$REPO/src/internal-skills/$module/SKILL.md"
    done

    for module in story-long-write story-review story-long-analyze story-deslop story-short-write; do
        grep -q "output-safety-contract.md" "$REPO/src/internal-skills/$module/SKILL.md"
    done
}

@test "maintainability audit script passes on repository" {
    [ -x "$AUDIT" ]
    output="$(node "$AUDIT" --repo-root "$REPO" --json)"
    echo "$output" | grep -q '"status":"pass"'
}

@test "maintainability audit is documented and part of production smoke" {
    grep -q "maintainability-audit.js" "$REPO/scripts/README.md"
    grep -q "maintainability-audit.js" "$REPO/docs/production-readiness.md"
    grep -q "maintainability-audit.js" "$REPO/scripts/production-smoke-matrix.js"
}

@test "single directory bundles include maintainability kernel references" {
    for bundle in novel-assistant; do
        base="$REPO/skills/$bundle/references/internal-skills/story-workflow/references"
        [ -f "$base/maintainability-kernel.md" ]
        [ -f "$base/workflow-contract.md" ]
        [ -f "$base/output-safety-contract.md" ]
    done
}
