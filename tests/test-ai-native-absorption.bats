#!/usr/bin/env bats
# tests/test-ai-native-absorption.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    CONTRACT="$REPO/src/internal-skills/story-workflow/references/workflow-contract.md"
    RUNTIME_INDEX="$REPO/skills/novel-assistant/references/runtime-contract-index.md"
    BUNDLE="$REPO/skills/novel-assistant"
    SMOKE="$REPO/scripts/production-smoke-matrix.js"
}

@test "workflow absorbs AI-native quality debt without blocking the full chain" {
    grep -q "quality-debt-policy.md" "$WORKFLOW"
    grep -q "质量债务" "$WORKFLOW"
    grep -q "continue_with_warning" "$REPO/src/internal-skills/story-workflow/references/quality-debt-policy.md"
    grep -q "stop_for_replan" "$REPO/src/internal-skills/story-workflow/references/quality-debt-policy.md"
    grep -q "quality_debt" "$CONTRACT"
    grep -q "chapter_quality_debt.jsonl" "$CONTRACT"
    test -f "$REPO/src/internal-skills/story-workflow/references/quality-debt-policy.md"
    grep -q "局部质量债务不是全局失败" "$REPO/src/internal-skills/story-workflow/references/quality-debt-policy.md"
}

@test "router documents structured intent packets instead of keyword pileups" {
    grep -q "structured-intent-routing.md" "$WORKFLOW"
    grep -q "AI-first structured intent" "$ROUTER"
    grep -q "intent_schema" "$ROUTER"
    grep -q "route_confidence" "$ROUTER"
    grep -q "fallback_question" "$ROUTER"
    test -f "$REPO/src/internal-skills/story-workflow/references/structured-intent-routing.md"
    grep -q "intent_schema" "$REPO/src/internal-skills/story-workflow/references/structured-intent-routing.md"
}

@test "story asset ledger separates confirmed facts from pending proposals" {
    grep -q "story-assets-ledger.md" "$WORKFLOW"
    grep -q "角色资源账本" "$REPO/src/internal-skills/story-workflow/references/story-assets-ledger.md"
    grep -q "pending_cast_candidates" "$CONTRACT"
    grep -q "confirmed_facts" "$CONTRACT"
    grep -q "chapter_participants_context" "$CONTRACT"
    test -f "$REPO/src/internal-skills/story-workflow/references/story-assets-ledger.md"
    grep -q "待确认提案不得写成既成事实" "$REPO/src/internal-skills/story-workflow/references/story-assets-ledger.md"
}

@test "style asset engine turns author voice into reusable writing assets" {
    grep -q "style-asset-engine.md" "$WORKFLOW"
    grep -q "写法资产" "$WORKFLOW"
    grep -q "style_feature_pool" "$CONTRACT"
    grep -q "style_binding" "$CONTRACT"
    grep -q "style_compile_report" "$CONTRACT"
    test -f "$REPO/src/internal-skills/story-workflow/references/style-asset-engine.md"
    grep -q "不是通用 humanizer" "$REPO/src/internal-skills/story-workflow/references/style-asset-engine.md"
}

@test "AI-native absorption is documented, bundled, and smoke covered" {
    grep -q "AI-Novel-Writing-Assistant" "$REPO/docs/reference-project-watch-sop.md"
    grep -q "质量债务" "$REPO/docs/reference-project-watch-sop.md"
    grep -q "角色资源账本" "$REPO/docs/reference-project-watch-sop.md"
    grep -q "写法资产" "$REPO/docs/reference-project-watch-sop.md"
    grep -q "AI_native_absorption" "$SMOKE"
    grep -q "quality-debt-policy.md" "$SMOKE"
    test -f "$BUNDLE/references/internal-skills/story-workflow/references/quality-debt-policy.md"
    test -f "$BUNDLE/references/internal-skills/story-workflow/references/structured-intent-routing.md"
    test -f "$BUNDLE/references/internal-skills/story-workflow/references/story-assets-ledger.md"
    test -f "$BUNDLE/references/internal-skills/story-workflow/references/style-asset-engine.md"
    grep -q "AI Native 小说生产吸收契约" "$RUNTIME_INDEX"
}
