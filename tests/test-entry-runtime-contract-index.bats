#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    ENTRY="$REPO/skills/novel-assistant/SKILL.md"
    CONTRACT="$REPO/skills/novel-assistant/references/runtime-contract-index.md"
}

@test "novel-assistant entry points to a runtime contract index instead of growing without structure" {
    [ -f "$CONTRACT" ]
    grep -q "Runtime Contract Index" "$CONTRACT"
    grep -q "启动硬门禁" "$CONTRACT"
    grep -q "工作流大脑" "$CONTRACT"
    grep -q "输出健康门" "$CONTRACT"
    grep -q "发布隔离" "$CONTRACT"

    grep -q "runtime-contract-index.md" "$ENTRY"
}

@test "runtime contract index keeps heavy protocols in referenced files" {
    grep -q "story-workflow/references/workflow-contract.md" "$CONTRACT"
    grep -q "story-workflow/references/output-safety-contract.md" "$CONTRACT"
    grep -q "story-workflow/references/token-cost-governance.md" "$CONTRACT"
    grep -q "story-workflow/references/maintainability-kernel.md" "$CONTRACT"
}
