#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SYNC="$REPO/scripts/novel-assistant-sync-runtime.js"
    BUNDLE="$REPO/skills/novel-assistant"
    TMP_DIR="$(mktemp -d)"
    NEW_BOOK="$TMP_DIR/new-book"
    LEGACY_BOOK="$TMP_DIR/legacy-book"
    mkdir -p "$NEW_BOOK" "$LEGACY_BOOK/正文/第1卷"
    printf '# 已有章节\n' > "$LEGACY_BOOK/正文/第1卷/第001章.md"
}

teardown() {
    rm -rf "$TMP_DIR"
}

sync_book() {
    node "$SYNC" --project-root "$1" --skill-dir "$BUNDLE" --json
}

run_guard() {
    local root="$1"
    local payload="$2"
    run bash -c 'printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" node "$2/.claude/hooks/canonical-write-guard.js"' -- "$payload" "$root"
}

@test "new setup deploys the canonical guard and initializes strict policy" {
    run sync_book "$NEW_BOOK"

    [ "$status" -eq 0 ]
    [ -f "$NEW_BOOK/.claude/hooks/canonical-write-guard.js" ]
    [ -f "$NEW_BOOK/追踪/story-system/write-policy.json" ]
    grep -q 'canonical-write-guard.js' "$NEW_BOOK/.claude/settings.local.json"
    run node -e 'const p=require(process.argv[1]); if(p.mode!=="strict") process.exit(1)' "$NEW_BOOK/追踪/story-system/write-policy.json"
    [ "$status" -eq 0 ]
}

@test "refreshing an existing project creates but does not force legacy policy" {
    run sync_book "$LEGACY_BOOK"

    [ "$status" -eq 0 ]
    [ -f "$LEGACY_BOOK/追踪/story-system/write-policy.json" ]
    run node -e 'const p=require(process.argv[1]); if(p.mode!=="legacy") process.exit(1)' "$LEGACY_BOOK/追踪/story-system/write-policy.json"
    [ "$status" -eq 0 ]
    [ "$(cat "$LEGACY_BOOK/正文/第1卷/第001章.md")" = '# 已有章节' ]
}

@test "refresh preserves an existing strict policy" {
    mkdir -p "$LEGACY_BOOK/追踪/story-system"
    printf '{"schemaVersion":"1.0.0","mode":"strict"}\n' > "$LEGACY_BOOK/追踪/story-system/write-policy.json"

    run sync_book "$LEGACY_BOOK"

    [ "$status" -eq 0 ]
    sync_output="$output"
    run node -e 'const p=require(process.argv[1]); if(p.mode!=="strict") process.exit(1)' "$LEGACY_BOOK/追踪/story-system/write-policy.json"
    [ "$status" -eq 0 ]
    [[ "$sync_output" == *'"writePolicy": "strict"'* ]]
}

@test "an empty story scaffold is initialized as strict" {
    mkdir -p "$NEW_BOOK/正文" "$NEW_BOOK/大纲" "$NEW_BOOK/设定" "$NEW_BOOK/追踪"

    run sync_book "$NEW_BOOK"

    [ "$status" -eq 0 ]
    run node -e 'const p=require(process.argv[1]); if(p.mode!=="strict") process.exit(1)' "$NEW_BOOK/追踪/story-system/write-policy.json"
    [ "$status" -eq 0 ]
}

@test "runtime sync merges hook registration without dropping user settings" {
    mkdir -p "$NEW_BOOK/.claude"
    printf '%s\n' '{"permissions":{"allow":["Bash(git status)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}' > "$NEW_BOOK/.claude/settings.local.json"

    run sync_book "$NEW_BOOK"

    [ "$status" -eq 0 ]
    run node -e 'const s=require(process.argv[1]); if(s.permissions.allow[0]!=="Bash(git status)"||s.hooks.SessionStart[0].hooks[0].command!=="echo user-hook") process.exit(1)' "$NEW_BOOK/.claude/settings.local.json"
    [ "$status" -eq 0 ]
    grep -q 'canonical-write-guard.js' "$NEW_BOOK/.claude/settings.local.json"
}

@test "runtime sync replaces stale canonical guard registration and remains idempotent" {
    mkdir -p "$NEW_BOOK/.claude"
    printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"node \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/canonical-write-guard.js","if":"Bash(git commit*)"},{"type":"command","command":"echo user-hook"}]}]}}' > "$NEW_BOOK/.claude/settings.local.json"

    sync_book "$NEW_BOOK" > "$TMP_DIR/first-sync.json"
    cp "$NEW_BOOK/.claude/settings.local.json" "$TMP_DIR/after-first.json"
    run sync_book "$NEW_BOOK"

    [ "$status" -eq 0 ]
    cmp "$TMP_DIR/after-first.json" "$NEW_BOOK/.claude/settings.local.json"
    run node -e 'const s=require(process.argv[1]); const groups=s.hooks.PreToolUse; const hooks=groups.flatMap(g=>(g.hooks||[]).map(h=>({g,h}))); const guards=hooks.filter(x=>x.h.command.includes("canonical-write-guard.js")); if(guards.length!==1||guards[0].g.matcher!=="Write|Edit|MultiEdit"||Object.hasOwn(guards[0].h,"if")||!hooks.some(x=>x.h.command==="echo user-hook"))process.exit(1)' "$NEW_BOOK/.claude/settings.local.json"
    [ "$status" -eq 0 ]
}

@test "strict guard blocks canonical writes without a transaction context" {
    sync_book "$NEW_BOOK"

    run_guard "$NEW_BOOK" '{"tool_name":"Write","tool_input":{"file_path":"正文/第1卷/第001章.md","content":"draft"}}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_canonical_transaction_required'* ]]
}

@test "strict guard blocks short-form root assets but not similarly named non-book files" {
    sync_book "$NEW_BOOK"

    local target
    for target in "正文.md" "设定.md" "小节大纲.md"; do
        run_guard "$NEW_BOOK" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$target\",\"content\":\"draft\"}}"
        [ "$status" -eq 0 ]
        [[ "$output" == *'blocked_canonical_transaction_required'* ]]
    done

    run_guard "$NEW_BOOK" '{"tool_name":"Write","tool_input":{"file_path":"notes/正文.md","content":"draft"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"allowed"'* ]]
}

@test "canonical guard blocks model-authored workflow receipts and short runtime projections" {
    sync_book "$NEW_BOOK"

    local target
    for target in \
        "追踪/workflow/tasks/wf-short/result-packets/next_section_brief.result.json" \
        "追踪/workflow/tasks/wf-short/artifacts/section-007-acceptance.json" \
        "追踪/private-short-extension/briefs/section-007.json" \
        "追踪/private-short-extension/section-007-anchor.json" \
        "追踪/private-short-extension/project-state.json" \
        "追踪/private-short-extension/section-title-lock.json"; do
        run_guard "$NEW_BOOK" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$target\",\"content\":\"{}\"}}"
        [ "$status" -eq 0 ]
        [[ "$output" == *'blocked_direct_workflow_state_edit'* ]]
    done
}

@test "strict guard accepts only an existing prepared transaction for its exact target" {
    sync_book "$NEW_BOOK"
    node "$REPO/scripts/workflow-state-machine.js" create --workflow-type long_write --project-root "$NEW_BOOK" --user-goal "事务守卫测试" --scope "第1章" --json > "$TMP_DIR/task.json"
    workflow_id="$(node -e 'const x=require(process.argv[1]);process.stdout.write(x.task.workflow_id)' "$TMP_DIR/task.json")"
    node - "$REPO/scripts/workflow-state-machine.js" "$NEW_BOOK" "$workflow_id" <<'NODE'
const fs=require('fs'),path=require('path'),{spawnSync}=require('child_process');
const state=process.argv[2],root=process.argv[3],workflowId=process.argv[4];
const file=path.join(root,'追踪/workflow/tasks',workflowId,'task.json');
const task=JSON.parse(fs.readFileSync(file,'utf8')); const p=task.pending_action;
const run=spawnSync(process.execPath,[state,'resolve-action','--project-root',root,'--input','1','--pending-action-id',p.pending_action_id||p.id,'--visible-choice-hash',p.visible_choice_hash,'--state-version',String(p.state_version),'--book-root',p.book_root||'.','--json'],{encoding:'utf8'});
if(run.status!==0) throw new Error(run.stdout||run.stderr);
NODE
    mkdir -p "$NEW_BOOK/追踪/staging"
    printf 'draft\n' > "$NEW_BOOK/追踪/staging/setting.md"
    printf '%s\n' "{\"workflow_id\":\"$workflow_id\",\"volume\":\"short\",\"chapter\":1,\"gates\":{\"output_health\":\"pass\",\"prose_quality\":\"pass\",\"story_drift\":\"pass\"},\"artifacts\":[{\"role\":\"setting\",\"staged\":\"追踪/staging/setting.md\",\"target\":\"设定.md\"}]}" > "$NEW_BOOK/追踪/staging/manifest.json"
    node "$NEW_BOOK/scripts/chapter-commit.js" prepare --project-root "$NEW_BOOK" --manifest "$NEW_BOOK/追踪/staging/manifest.json" --json > "$TMP_DIR/prepare.json"
    tx="$(node -e 'const x=require(process.argv[1]); process.stdout.write(x.transaction_id)' "$TMP_DIR/prepare.json")"

    run_guard "$NEW_BOOK" '{"tool_name":"Write","tool_input":{"file_path":"设定.md","transaction_id":"tx-forged"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_canonical_transaction_invalid'* ]]

    run_guard "$NEW_BOOK" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"正文.md\",\"transaction_id\":\"$tx\"}}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_canonical_transaction_target_mismatch'* ]]

    run_guard "$NEW_BOOK" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"设定.md\",\"transaction_id\":\"$tx\"}}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"transaction_id":"'* ]]

    node -e 'const fs=require("fs");const p=process.argv[1];const t=JSON.parse(fs.readFileSync(p,"utf8"));t.status="accepted";fs.writeFileSync(p,JSON.stringify(t))' "$NEW_BOOK/追踪/story-system/transactions/$tx/transaction.json"
    run_guard "$NEW_BOOK" "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"设定.md\",\"transaction_id\":\"$tx\"}}"
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_canonical_transaction_not_prepared'* ]]
}

@test "guard warns but allows missing file paths and legacy canonical writes" {
    sync_book "$NEW_BOOK"
    run_guard "$NEW_BOOK" '{"tool_name":"Write","tool_input":{"content":"draft"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'canonical_write_target_missing'* ]]

    sync_book "$LEGACY_BOOK"
    run_guard "$LEGACY_BOOK" '{"tool_name":"Edit","tool_input":{"file_path":"正文/第1卷/第001章.md","old_string":"旧","new_string":"新"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'legacy_canonical_write_unprotected'* ]]
}

@test "legacy guard blocks a generated mutator script that embeds canonical prose writes" {
    sync_book "$LEGACY_BOOK"

    run_guard "$LEGACY_BOOK" '{"tool_name":"Write","tool_input":{"file_path":"scripts/apply-B2-meta-leak.js","content":"const fs=require(\"fs\"); fs.writeFileSync(\"正文/第1卷/第001章.md\", \"改写\");"}}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_unmanaged_story_mutator'* ]]
}

@test "legacy guard blocks editing an existing generated mutator script" {
    sync_book "$LEGACY_BOOK"
    mkdir -p "$LEGACY_BOOK/scripts"
    printf 'old script\n' > "$LEGACY_BOOK/scripts/apply-B3-ellipsis.js"

    run_guard "$LEGACY_BOOK" '{"tool_name":"Edit","tool_input":{"file_path":"scripts/apply-B3-ellipsis.js","old_string":"old script","new_string":"const fs=require(\"fs\"); fs.writeFileSync(\"正文/第1卷/第001章.md\", \"改写\");"}}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_unmanaged_story_mutator'* ]]
}

@test "strict guard fails closed when its runtime is unavailable while legacy warns" {
    sync_book "$NEW_BOOK"
    rm "$NEW_BOOK/scripts/lib/canonical-write-policy.js"
    run_guard "$NEW_BOOK" '{"tool_name":"Write","tool_input":{"file_path":"正文/第1卷/第001章.md","content":"draft"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_canonical_write_guard_runtime_unavailable'* ]]

    sync_book "$LEGACY_BOOK"
    rm "$LEGACY_BOOK/scripts/lib/canonical-write-policy.js"
    run_guard "$LEGACY_BOOK" '{"tool_name":"Write","tool_input":{"file_path":"正文/第1卷/第001章.md","content":"draft"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'canonical_write_guard_runtime_missing'* ]]
}

@test "guard leaves strict noncanonical writes alone" {
    sync_book "$NEW_BOOK"

    run_guard "$NEW_BOOK" '{"tool_name":"Write","tool_input":{"file_path":"追踪/审查报告/批次_001.md","content":"report"}}'

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status":"allowed"'* ]]
}

@test "guard registration and professional acceptance routes use chapter commit" {
    grep -q 'canonical-write-guard.js' "$REPO/src/internal-skills/story-setup/references/templates/settings-hooks.json"
    grep -q 'canonical-write-guard.js' "$REPO/src/internal-skills/story-setup/SKILL.md"
    local skill
    for skill in story-long-write story-review; do
        grep -q '正式资产事务接受' "$REPO/src/internal-skills/$skill/SKILL.md"
        grep -q 'chapter-commit.js accept' "$REPO/src/internal-skills/$skill/SKILL.md"
    done
    grep -q '正式资产事务接受' "$REPO/src/internal-skills/story-short-write/SKILL.md"
    grep -q 'short-section-accept-finalize.js' "$REPO/src/internal-skills/story-short-write/SKILL.md"

    workflow="$REPO/src/internal-skills/story-workflow/SKILL.md"
    protocol="$REPO/src/internal-skills/story-workflow/references/canonical-write-protocol.md"
    grep -q 'canonical-write-protocol.md' "$workflow"
    grep -q '正式资产事务接受' "$protocol"
    grep -q 'chapter-commit.js accept' "$protocol"

    grep -q '不得用直接 Write/Edit 替代接受步骤' "$REPO/src/internal-skills/story-short-write/SKILL.md"
    grep -q '不得直接替换或追加 `正文.md`' "$protocol"
    grep -q '正式 `正文.md` 必须经 `chapter-commit.js prepare`' "$REPO/src/internal-skills/story-setup/references/templates/agents/narrative-writer.md"
}
