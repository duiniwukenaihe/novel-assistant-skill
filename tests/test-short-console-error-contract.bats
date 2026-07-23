#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$(mktemp -d)/book"
  mkdir -p "$BOOK/追踪/workflow" "$BOOK/追踪/private-short-extension"
  node "$REPO/scripts/workflow-state-machine.js" create --workflow-type short_write --project-root "$BOOK" --scope "测试短篇" --user-goal "测试控制台契约" --json >/dev/null
  WORKFLOW_ID="$(node -e 'const fs=require("fs"),path=require("path");const x=JSON.parse(fs.readFileSync(path.join(process.argv[1],"追踪/workflow/current-task.json"),"utf8"));process.stdout.write(x.workflow_id)' "$BOOK")"
}

teardown() {
  rm -rf "$(dirname "$BOOK")"
}

@test "all managed short section scripts expose help without Exit code 2" {
  for script in \
    short-section-accept-finalize.js \
    short-section-machine-gate.js \
    short-section-quality-gate.js \
    short-section-draft-finalize.js \
    short-section-brief-finalize.js \
    short-section-repair-finalize.js \
    short-section-title-lock.js; do
    run node "$REPO/scripts/$script" --help
    [ "$status" -eq 0 ]
    [[ "$output" == Usage:* ]]
  done
}

@test "stale short stage commands return handled business states without console errors" {
  for script in \
    short-section-accept-finalize.js \
    short-section-machine-gate.js \
    short-section-quality-gate.js \
    short-section-draft-finalize.js \
    short-section-brief-finalize.js \
    short-section-repair-finalize.js; do
    run node "$REPO/scripts/$script" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ]
    [[ "$output" != *'Exit code'* ]]
  done
}

@test "missing short title inputs are recoverable business states" {
  run node "$REPO/scripts/short-section-title-lock.js" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"short_outline_missing"'* ]]
}

@test "workflow inbox accepts cwd defaults aliases and numeric selection without usage errors" {
  run bash -c 'cd "$1" && node "$2/scripts/workflow-task-inbox.js" --action show_current_run --selection 1 --json' -- "$BOOK" "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Unknown argument"* ]]
  [[ "$output" != *"missing --project-root"* ]]
}

@test "workflow state machine defaults to current candidates when command name is omitted" {
  run node "$REPO/scripts/workflow-state-machine.js" --project-root "$BOOK" --json
  [ "$status" -eq 0 ]
  [[ "$output" != *"missing or invalid command"* ]]
}
