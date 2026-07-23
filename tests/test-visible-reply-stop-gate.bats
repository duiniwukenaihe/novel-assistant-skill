#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  HOOK="$REPO/src/internal-skills/story-setup/references/templates/hooks/visible-reply-stop-gate.js"
  SETTINGS="$REPO/src/internal-skills/story-setup/references/templates/settings-hooks.json"
}

@test "stop gate makes Claude rewrite a final reply containing terminal escape residue" {
  run bash -c 'printf %s "$1" | node "$2"' _ '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"回复数字选择。```[e~["}' "$HOOK"

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const x=JSON.parse(s);if(x.decision!=="block"||!x.reason.includes("终端转义残片"))process.exit(1)})'
}

@test "stop gate allows a clean final reply" {
  run bash -c 'printf %s "$1" | node "$2"' _ '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"已完成 1-50 章扫描，正在继续下一批。"}' "$HOOK"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop gate does not loop when the rewrite turn is already active" {
  run bash -c 'printf %s "$1" | node "$2"' _ '{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"仍有[e~["}' "$HOOK"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "story setup registers the deterministic final reply stop gate" {
  grep -q '"Stop"' "$SETTINGS"
  grep -q 'visible-reply-stop-gate.js' "$SETTINGS"
}
