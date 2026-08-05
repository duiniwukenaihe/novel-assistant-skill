#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    README="$REPO/README.md"
    README_EN="$REPO/README_EN.md"
    QUICKSTART="$REPO/docs/longform-stability-quickstart.md"
    RELEASE="$REPO/docs/release-checklist.md"
    UPSTREAM="$REPO/docs/upstream-backport-sop.md"
}

@test "compact README documents the single entry and resumable workflow" {
    grep -q "一个入口" "$README"
    grep -q "/novel-assistant" "$README"
    grep -q "Claude Code、Codex、ZCode" "$README"
    grep -q "继续上次未完成任务" "$README"
    grep -q "Workflow 保存任务、阶段、断点和下一步" "$README"
    grep -q "Memory 只召回当前步骤需要的事实" "$README"
}

@test "compact README keeps short and long production boundaries visible" {
    grep -q "当前专注短篇" "$README"
    grep -q "长篇持续打磨中" "$README"
    grep -q "审阅、拆文、扫榜、导入和去 AI 味等专业模块同样提供" "$README"
    grep -q "只写当前节" "$README"
    grep -q "双门验收" "$README"
    grep -q "章节 Brief" "$README"
    grep -q "跨卷交接" "$README"
    grep -q "不会用下游润色掩盖上游规划错误" "$README"
}

@test "English README mirrors the compact user-facing contract" {
    [ -f "$README_EN" ]
    grep -q "One entry point" "$README_EN"
    grep -q "/novel-assistant" "$README_EN"
    grep -q "Claude Code, Codex, or ZCode" "$README_EN"
    grep -q "Resume my unfinished task" "$README_EN"
    grep -q "Workflow persists tasks, stages, checkpoints, and next actions" "$README_EN"
}

@test "README links durable workflow and production documentation" {
    grep -q "docs/workflow.md" "$README"
    grep -q "docs/workflow-memory-subskill-contract.md" "$README"
    grep -q "docs/installation-and-update.md" "$README"
    grep -q "docs/production-readiness.md" "$README"
    grep -q "CHANGELOG.md" "$README"
}

@test "longform stability quickstart covers daily revision repair and index commands" {
    [ -f "$QUICKSTART" ]
    grep -q "bash scripts/chapter-index-build.sh --write" "$QUICKSTART"
    grep -q "bash scripts/longform-daily-stability-audit.sh --write" "$QUICKSTART"
    grep -q "bash scripts/revision-stability-recheck.sh --write" "$QUICKSTART"
    grep -q "bash scripts/stability-agent-dispatch-prompt.sh --json" "$QUICKSTART"
    grep -q "current_owner" "$QUICKSTART"
    grep -q "current_action" "$QUICKSTART"
}

@test "release checklist records final verification commands" {
    [ -f "$RELEASE" ]
    grep -q "bash scripts/run-bats-tests.sh" "$RELEASE"
    grep -q "bash scripts/check-story-setup-deployment.sh" "$RELEASE"
    grep -q "bash scripts/check-shared-files.sh" "$RELEASE"
    grep -q "bash scripts/static-check.sh" "$RELEASE"
    grep -q "git diff --check" "$RELEASE"
}

@test "upstream backport SOP preserves report-only intake" {
    [ -f "$UPSTREAM" ]
    grep -q "bash scripts/check-upstream.sh --write" "$UPSTREAM"
    grep -q "refs/remotes/upstream-check/main" "$UPSTREAM"
    grep -q "Tag Comparison" "$UPSTREAM"
    grep -q "already-covered" "$UPSTREAM"
    grep -q "absorb / already-covered / skip" "$UPSTREAM"
}
