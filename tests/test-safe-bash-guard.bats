#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GUARD="$REPO/src/internal-skills/story-setup/references/templates/hooks/safe-bash-guard.js"
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$TMP_DIR/scripts"
  cp "$REPO/scripts/tool-call-degradation-check.js" "$TMP_DIR/scripts/"
}

teardown() {
  rm -rf "$TMP_DIR"
}

run_guard() {
  local command="$1"
  local payload
  payload="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$command")"
  run bash -c 'printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" node "$3"' -- "$payload" "$TMP_DIR" "$GUARD"
}

@test "compound chapter review command is denied with a one-command replacement" {
  run_guard 'cd "/tmp/book/正文/第1卷" && for f in 第0{01..49}章.md 第050章.md; do wc -m "$f"; done 2>&1 | head -55'

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      const h=x.hookSpecificOutput||{};
      if(h.permissionDecision!=="deny") process.exit(1);
      if(!/review-batch-evidence-scan\.js/.test(h.permissionDecisionReason||"")) process.exit(2);
    });'
}

@test "known deterministic review scanner is explicitly allowed" {
  run_guard 'node "/tmp/book/scripts/review-batch-evidence-scan.js" --project-root "/tmp/book" --range 1-50 --json'

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      if((x.hookSpecificOutput||{}).permissionDecision!=="allow") process.exit(1);
    });'
}

@test "legacy cd wrapper around one managed update check is allowed without a console error" {
  run_guard 'cd "/tmp/book" && node "/tmp/skill/scripts/novel-assistant-update-check.js" "/tmp/book" "/tmp/skill/novel-assistant-manifest.json" --json'

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      const h=x.hookSpecificOutput||{};
      if(h.permissionDecision!=="allow") process.exit(1);
      if(!/兼容/.test(h.permissionDecisionReason||"")) process.exit(2);
    });'
}

@test "known safe script help pipeline is allowed as a bounded read-only command" {
  run_guard 'node "/tmp/book/scripts/review-evidence-map.js" --help 2>&1 | head'

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      const h=x.hookSpecificOutput||{};
      if(h.permissionDecision!=="allow") process.exit(1);
      if(!/受管脚本|帮助命令.*安全只读/.test(h.permissionDecisionReason||"")) process.exit(2);
    });'
}

@test "pure help for a known safe script is explicitly allowed" {
  run_guard 'node "/tmp/book/scripts/review-evidence-map.js" --help'

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      if((x.hookSpecificOutput||{}).permissionDecision!=="allow") process.exit(1);
    });'
}

@test "chapter metadata reconcile preflight is explicitly allowed" {
  run_guard 'node "/tmp/book/scripts/chapter-metadata-reconcile.js" --project-root "/tmp/book" --range 51-100 --json'

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      if((x.hookSpecificOutput||{}).permissionDecision!=="allow") process.exit(1);
    });'
}

@test "chapter metadata reconcile write with lock and snapshot is explicitly allowed" {
  run_guard 'node "/tmp/book/scripts/chapter-metadata-reconcile.js" --project-root "/tmp/book" --range 51-100 --write --json'

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      if((x.hookSpecificOutput||{}).permissionDecision!=="allow") process.exit(1);
    });'
}

@test "manual workflow state copying is denied in favor of the state machine" {
  run_guard 'cp 追踪/workflow/current-task.json 追踪/workflow/tasks/wf-1/task.json && echo synced'

  [ "$status" -eq 0 ]
  [[ "$output" == *"workflow-state-machine.js"* ]]
}

@test "generated repair mutator is denied in favor of the staged transaction chain" {
  run_guard 'node scripts/apply-B2-meta-leak.js'

  [ "$status" -eq 0 ]
  [[ "$output" == *"不得运行临时修复脚本"* ]]
  [[ "$output" == *"chapter-commit.js"* ]]
}

@test "ordinary clean command remains under the host permission policy" {
  run_guard 'git status --short'

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "global skill bundle enumeration is denied before Claude asks for approval" {
  run_guard 'ls /Users/test/.claude/skills/novel-assistant/'

  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"已由宿主加载"* ]]
  [[ "$output" == *"workflow-entry-guard"* ]]
}

@test "short accept stage allows a bounded read-only diagnostic without a console error" {
  mkdir -p "$TMP_DIR/追踪/workflow/tasks/wf-short-accept"
  printf '%s\n' '{"workflow_id":"wf-short-accept"}' > "$TMP_DIR/追踪/workflow/current-task.json"
  printf '%s\n' '{"workflow_id":"wf-short-accept","current_stage":"section_accept_anchor"}' > "$TMP_DIR/追踪/workflow/tasks/wf-short-accept/task.json"

  run_guard 'node -e "const fs=require(\"fs\"); console.log(fs.readFileSync(\"草稿_第006节_候选.md\",\"utf8\").length)"'

  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"allow"'* ]]
  [[ "$output" == *"安全"* ]]
}

@test "short draft and repair finalizers are safe single commands" {
  run_guard 'node "/tmp/book/scripts/short-section-draft-finalize.js" --project-root "/tmp/book" --workflow-id "wf-short" --apply --json'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"allow"'* ]]

  run_guard 'node "/tmp/book/scripts/short-section-repair-finalize.js" --project-root "/tmp/book" --workflow-id "wf-short" --apply --json'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"allow"'* ]]
}

@test "repair stage lets a managed stale command return a structured recovery state" {
  mkdir -p "$TMP_DIR/追踪/workflow/tasks/wf-short-repair"
  printf '%s\n' '{"workflow_id":"wf-short-repair"}' > "$TMP_DIR/追踪/workflow/current-task.json"
  printf '%s\n' '{"workflow_id":"wf-short-repair","current_stage":"section_repair_loop"}' > "$TMP_DIR/追踪/workflow/tasks/wf-short-repair/task.json"

  run_guard 'node scripts/short-section-machine-gate.js --project-root "/tmp/book" --workflow-id "wf-short-repair" --apply --json'

  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"allow"'* ]]
  [[ "$output" == *"受管脚本"* ]]
}

@test "bounded ls find wc and pipeline diagnostics do not surface as guard errors" {
  for command in \
    'ls -la /tmp/book/草稿_第007节_候选.md 2>&1 || echo NOT_EXISTS' \
    'find /tmp/book -name "*第007节*" -type f 2>/dev/null' \
    'ls /tmp/book/result-packets/ 2>&1 | head -20' \
    'wc -m /tmp/book/草稿_第007节_候选.md'; do
    run_guard "$command"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"allow"'* ]]
  done
}

@test "managed workflow commands remain allowed when Claude truncates output with head or tail" {
  for command in \
    'node scripts/short-section-repair-finalize.js --project-root "/tmp/book" --workflow-id "wf-short" --apply --json 2>&1 | tail -50' \
    'node scripts/short-section-machine-gate.js --project-root "/tmp/book" --workflow-id "wf-short" --write --json 2>&1 | head -60' \
    'node scripts/workflow-entry-guard.js --project-root "/tmp/book" --user-intent "1" --write --compact --json 2>&1 | tail -30' \
    'node scripts/workflow-task-inbox.js --project-root "/tmp/book" --action show_current_run --json 2>&1 | tail -30' \
    'node scripts/short-section-machine-gate.js --help 2>&1'; do
    run_guard "$command"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"allow"'* ]]
  done
}

@test "short final check inline diagnostics point back to the stage command instead of the chapter review scanner" {
  mkdir -p "$TMP_DIR/追踪/workflow/tasks/wf-short-final"
  printf '%s\n' '{"workflow_id":"wf-short-final"}' > "$TMP_DIR/追踪/workflow/current-task.json"
  printf '%s\n' '{"workflow_id":"wf-short-final","current_stage":"final_check"}' > "$TMP_DIR/追踪/workflow/tasks/wf-short-final/task.json"

  run_guard 'node -e "const fs=require(\"fs\"); const text=fs.readFileSync(\"正文.md\",\"utf8\"); console.log(text.length)"'

  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"short-story-final-check.js"* ]]
  [[ "$output" != *"review-batch-evidence-scan.js"* ]]
}

@test "setup template registers the Bash guard before tool execution" {
  node -e '
    const x=require(process.argv[1]);
    const hooks=(x.hooks.PreToolUse||[]).flatMap(g=>(g.hooks||[]).map(h=>({matcher:g.matcher,command:h.command})));
    if(!hooks.some(h=>h.matcher==="Bash" && /safe-bash-guard\.js/.test(h.command))) process.exit(1);
  ' "$REPO/src/internal-skills/story-setup/references/templates/settings-hooks.json"
}
