#!/usr/bin/env bash

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
}

@test "workflow contract defines single-writer multi-agent merge policy" {
  file="$REPO_ROOT/src/internal-skills/story-workflow/references/workflow-contract.md"
  grep -q "agent_write_policy" "$file"
  grep -q "single_writer_merge" "$file"
  grep -q "blocked_parallel_write_conflict" "$file"
}

@test "output safety contract forbids parallel agents from editing the same production file" {
  file="$REPO_ROOT/src/internal-skills/story-workflow/references/output-safety-contract.md"
  grep -q "不得让多个 agent 同时 Write/Edit 同一个正文、大纲、细纲、设定、报告文件" "$file"
  grep -q "agent 只能写独立中间产物" "$file"
  grep -q "主流程或 merge step" "$file"
}

@test "workflow includes provider and model profile contract" {
  file="$REPO_ROOT/src/internal-skills/story-workflow/references/model-provider-profiles.md"
  test -f "$file"
  grep -q "OpenAI-compatible endpoint" "$file"
  grep -q "Qwen" "$file"
  grep -q "Minimax" "$file"
  grep -q "custom endpoint" "$file"
  grep -q "model_class" "$file"
  grep -q "context_window_hint" "$file"
  grep -q "宿主工具负责 provider 配置" "$file"
  grep -q "skill 不保存 API key" "$file"
  grep -q "Claude Code / Codex / OpenCode" "$file"
}

@test "workflow skill links provider profiles and upstream issue hardening semantics" {
  file="$REPO_ROOT/src/internal-skills/story-workflow/SKILL.md"
  grep -q "model-provider-profiles.md" "$file"
  grep -q "outline_to_draft_gate" "$file"
  grep -q "review_gap_reconciliation" "$file"
  grep -q "full_auto_deconstruction" "$file"
  grep -q "只执行本项" "$file"
  grep -q "继续后续阶段" "$file"
  grep -q "完成整个流程" "$file"
}

@test "installation docs explain provider profiles and custom endpoint setup boundary" {
  file="$REPO_ROOT/docs/installation-and-update.md"
  grep -q "provider profile" "$file"
  grep -q "OpenAI-compatible" "$file"
  grep -q "Qwen" "$file"
  grep -q "Minimax" "$file"
  grep -q "custom endpoint" "$file"
  grep -q "不是让 skill 管理 API key" "$file"
  grep -q "Claude Code / Codex / OpenCode" "$file"
}

@test "workflow docs explain outline review deconstruction completion semantics" {
  file="$REPO_ROOT/docs/workflow.md"
  grep -q "outline_to_draft_gate" "$file"
  grep -q "review_gap_reconciliation" "$file"
  grep -q "full_auto_deconstruction" "$file"
  grep -q "只执行本项" "$file"
  grep -q "继续后续阶段" "$file"
  grep -q "完成整个流程" "$file"
  grep -q "remaining_stages" "$file"
}

@test "readmes explain provider boundary and multi-agent single-writer hardening" {
  zh="$REPO_ROOT/README.md"
  en="$REPO_ROOT/README_EN.md"
  grep -q "skill 不管理 API key" "$zh"
  grep -q "Claude Code / Codex / OpenCode" "$zh"
  grep -q "single_writer_merge" "$zh"
  grep -q "多 agent" "$zh"
  grep -q "skill does not manage API keys" "$en"
  grep -q "Claude Code / Codex / OpenCode" "$en"
  grep -q "single_writer_merge" "$en"
  grep -q "Multi-agent" "$en"
}
