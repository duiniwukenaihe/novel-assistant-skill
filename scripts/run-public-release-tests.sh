#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
  tests/test-ai-native-absorption.bats
  tests/test-entry-runtime-contract-index.bats
  tests/test-maintainability-kernel.bats
  tests/test-memory-index-recovery.bats
  tests/test-memory-snapshot-engine.bats
  tests/test-public-short-workflow-production.bats
  tests/test-runtime-guard-validate.bats
  tests/test-runtime-managed-files.bats
  tests/test-runtime-safe-fs.bats
  tests/test-runtime-sync-packaged.bats
  tests/test-runtime-sync.bats
  tests/test-short-brief-freshness.bats
  tests/test-short-console-error-contract.bats
  tests/test-short-feedback-impact-policy.bats
  tests/test-short-memory-workflow.bats
  tests/test-short-plan-contract.bats
  tests/test-short-review-entry.bats
  tests/test-short-section-acceptance-policy.bats
  tests/test-short-section-brief-finalize.bats
  tests/test-short-section-draft-finalize.bats
  tests/test-short-section-length-policy.bats
  tests/test-short-section-repair-finalize.bats
  tests/test-short-section-title-lock.bats
  tests/test-short-section-transaction.bats
  tests/test-short-workflow-state.bats
  tests/test-short-writing-profile.bats
  tests/test-skill-entry-progressive-disclosure.bats
  tests/test-storage-memory-contract.bats
  tests/test-story-memory-concurrency.bats
  tests/test-story-memory-context-assembler.bats
  tests/test-story-memory-cross-volume.bats
  tests/test-story-memory-facts.bats
  tests/test-story-memory-internal-skill.bats
  tests/test-story-memory-migration.bats
  tests/test-story-memory-recommender.bats
  tests/test-story-memory-task-authority.bats
  tests/test-story-startup-workflow.bats
  tests/test-workflow-control-plane-migration.bats
  tests/test-workflow-entry-guard-setup.bats
  tests/test-workflow-entry-guard.bats
  tests/test-workflow-execution-boundary.bats
  tests/test-workflow-legacy-migration.bats
  tests/test-workflow-recovery.bats
  tests/test-workflow-review-batches.bats
  tests/test-workflow-session-lease.bats
  tests/test-workflow-state-concurrency.bats
  tests/test-workflow-state-invariants.bats
  tests/test-workflow-status-authority.bats
  tests/test-workflow-stream-health.bats
  tests/test-workflow-supervisor.bats
  tests/test-workflow-task-authority.bats
  tests/test-workflow-task-inbox.bats
)

for test_file in "${tests[@]}"; do
  if [[ ! -f "$ROOT_DIR/$test_file" ]]; then
    echo "public release test is missing: $test_file" >&2
    exit 2
  fi
done

cd "$ROOT_DIR"
node scripts/public-release-audit.js --json
node scripts/maintainability-audit.js --repo-root . --json
node scripts/production-smoke-matrix.js --json
bash scripts/run-bats-tests.sh "${tests[@]}"
node --test tests/short-section-outline-contract.test.mjs
