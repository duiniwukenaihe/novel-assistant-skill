#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$BATS_TEST_TMPDIR/book"
}

@test "model risk policy detects common writing model families without storing credentials" {
  run node - "$REPO/scripts/lib/model-risk-policy.js" <<'NODE'
const { resolveModelRiskPolicy } = require(process.argv[2]);
const rows = [
  resolveModelRiskPolicy({ provider: 'minimax', model: 'MiniMax-M3' }),
  resolveModelRiskPolicy({ provider: 'deepseek', model: 'DeepSeek-V4-Pro' }),
  resolveModelRiskPolicy({ provider: 'zcode', model: 'GLM-5.2' }),
  resolveModelRiskPolicy({ provider: 'openai', model: 'gpt-5.6' }),
];
console.log(JSON.stringify(rows));
NODE
  [ "$status" -eq 0 ]
  [[ "$output" == *'"family":"minimax"'* ]]
  [[ "$output" == *'"family":"deepseek"'* ]]
  [[ "$output" == *'"family":"glm"'* ]]
  [[ "$output" == *'"family":"openai"'* ]]
  [[ "$output" != *'api_key'* ]]
}

@test "unknown models use a conservative bounded profile" {
  run node - "$REPO/scripts/lib/model-risk-policy.js" <<'NODE'
const { resolveModelRiskPolicy } = require(process.argv[2]);
console.log(JSON.stringify(resolveModelRiskPolicy({ provider: 'custom', model: 'future-model' })));
NODE
  [ "$status" -eq 0 ]
  [[ "$output" == *'"family":"unknown"'* ]]
  [[ "$output" == *'"same_failure":1'* ]]
  [[ "$output" == *'"context_budget_multiplier":0.7'* ]]
}

@test "workflow runtime guard records the active model profile" {
  run env NOVEL_ASSISTANT_PROVIDER=minimax NOVEL_ASSISTANT_MODEL=MiniMax-M3 node "$REPO/scripts/workflow-state-machine.js" create \
    --workflow-type short_write \
    --project-root "$BATS_TEST_TMPDIR/book" \
    --scope "第1节" \
    --user-goal "写第1节" \
    --json
  [ "$status" -eq 0 ]
  workflow_id="$(printf '%s' "$output" | jq -r '.task.workflow_id')"
  run jq -r '.runtime_guard.model_profile.family' "$BATS_TEST_TMPDIR/book/追踪/workflow/tasks/$workflow_id/task.json"
  [ "$status" -eq 0 ]
  [ "$output" = "minimax" ]
}

@test "host takeover refreshes model controls without creating a second story memory" {
  run env NOVEL_ASSISTANT_PROVIDER=minimax NOVEL_ASSISTANT_MODEL=MiniMax-M3 node "$REPO/scripts/workflow-state-machine.js" create \
    --workflow-type short_write --project-root "$BATS_TEST_TMPDIR/book" --scope "第1节" --user-goal "写第1节" --json
  [ "$status" -eq 0 ]
  workflow_id="$(printf '%s' "$output" | jq -r '.task.workflow_id')"

  run node "$REPO/scripts/workflow-state-machine.js" reconcile-runtime \
    --project-root "$BATS_TEST_TMPDIR/book" --workflow-id "$workflow_id" --session-id claude:test \
    --provider anthropic --model claude-opus --json
  [ "$status" -eq 0 ]
  run jq -r '[.runtime_guard.model_profile.family, (.runtime_guard.model_profile_changed_at != null), (.runtime_guard.model_profile_previous_family // "")] | join("|")' "$BATS_TEST_TMPDIR/book/追踪/workflow/tasks/$workflow_id/task.json"
  [ "$status" -eq 0 ]
  [ "$output" = "claude|true|minimax" ]
  [ ! -e "$BATS_TEST_TMPDIR/book/追踪/memory/model-specific" ]
}
