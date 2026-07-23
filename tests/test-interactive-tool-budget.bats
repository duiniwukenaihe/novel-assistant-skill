#!/usr/bin/env bats
# tests/test-interactive-tool-budget.bats
#
# Task 4: 交互式 Claude Code 写作模式的动态工具预算熔断 + PreToolUse hook。
#
# 验收底线：
#   1. 写作模式下创建 debug-*/scan-*/find-*/inspect-* 脚本 -> deny(blocked_writing_mode_platform_debug)
#   2. 写作模式下修改受管 scripts/*.js -> deny(blocked_writing_mode_platform_debug)
#   3. 连续平台源码读取超阈值 -> deny(blocked_interactive_tool_budget_exhausted)
#   4. 正常写作动作(读 Brief/写候选稿/调 controller) -> allow
#   5. 非写作项目(无任务/普通项目) -> fail-open，不阻断
#
# 职责划分：转换失败恢复熔断(recovery_count/exhausted)由 workflow-stage-controller 负责，
# hook 不重复实现；hook 只管"平台诊断 + 受管源码保护 + 源码读取节流"。

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SYNC="$REPO/scripts/novel-assistant-sync-runtime.js"
    BUDGET_CLI="$REPO/scripts/interactive-tool-budget.js"
    BUNDLE="$REPO/skills/novel-assistant"
    GUARD_HOOK="$REPO/src/internal-skills/story-setup/references/templates/hooks/workflow-tool-budget-guard.js"
    TMP_DIR="$(mktemp -d)"
    TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK/正文" "$BOOK/大纲" "$BOOK/设定" "$BOOK/追踪" "$BOOK/scripts"
}

teardown() {
    rm -rf "$TMP_DIR"
}

# 同步部署：把 hook + budget lib + CLI 都部署到 BOOK，hook 真实可用。
deploy_book() {
    node "$SYNC" --project-root "$BOOK" --skill-dir "$BUNDLE" --json >/dev/null
}

# 构造一本停在 draft_next_section(draft 类正文生成阶段) 的写作项目。
# 参照 test-workflow-stage-controller.bats 的 materialize_fixture。
materialize_writing_task() {
    local book="$1"
    local stage="${2:-draft_next_section}"
    mkdir -p "$book/追踪/workflow/tasks/wf-budget-test/result-packets"
    mkdir -p "$book/追踪/private-short-extension"
    local task='{
      "schemaVersion": "1.0.0",
      "state_version": 1,
      "workflow_id": "wf-budget-test",
      "workflow_type": "short_write",
      "workflow_profile": "private",
      "workflow_owner": "private-short-extension",
      "status": "running",
      "scope": "第6节",
      "task_dir": "追踪/workflow/tasks/wf-budget-test",
      "book_root": ".",
      "current_stage": "'"$stage"'",
      "current_step": "'"$stage"'",
      "machine": {"completed_stages": [], "remaining_stages": ["'"$stage"'"]},
      "runtime_guard": {
        "heartbeat": {"latest_trusted_artifact": ""},
        "checkpoint_policy": {},
        "max_retry_budget": {"same_failure": 1, "on_exhausted": "pause_at_checkpoint"}
      },
      "pending_action": {"id": "pa-advance", "status": "pending", "options": [{"number": 1, "target_stage": "section_machine_gate"}]}
    }'
    printf '%s\n' "$task" > "$book/追踪/workflow/tasks/wf-budget-test/task.json"
    printf '%s\n' '{"schemaVersion":"1.0.0","state_version":1,"workflow_id":"wf-budget-test","task_dir":"追踪/workflow/tasks/wf-budget-test"}' \
        > "$book/追踪/workflow/current-task.json"
}

# 通过 stdin payload 跑已部署的 hook，参照 test-canonical-write-deployment.bats:22 的 run_guard。
run_guard() {
    local root="$1"
    local payload="$2"
    run bash -c 'printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" node "$2/.claude/hooks/workflow-tool-budget-guard.js"' -- "$payload" "$root"
}

# ===================================================================
# CLI 单元测试：buildStageToolBudget + evaluateToolCall 纯函数
# ===================================================================

@test "cli evaluate: writing-mode Read of Brief is allowed" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Read \
        --tool-input '{"file_path":"追踪/private-short-extension/section-006-brief.md"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
}

@test "cli evaluate: writing-mode Write of declared candidate draft is allowed" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"正文.md","content":"第六节草稿"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
}

@test "cli evaluate: writing-mode controller invocation is allowed - transition budget enforced by controller" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"node scripts/workflow-stage-controller.js advance --json"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
}

@test "cli evaluate: writing-mode Write of scripts/debug-reconcile.js is paused (blocked_writing_mode_platform_debug)" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/debug-reconcile.js","content":"console.log(1)"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "cli evaluate: writing-mode Write of scripts/scan-fingerprint.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/scan-fingerprint.js","content":"x"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "cli evaluate: writing-mode Edit of managed scripts/workflow-state-machine.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Edit \
        --tool-input '{"file_path":"scripts/workflow-state-machine.js","old_string":"a","new_string":"b"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "cli evaluate: writing-mode Edit of managed scripts/lib/interactive-tool-budget.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Edit \
        --tool-input '{"file_path":"scripts/lib/interactive-tool-budget.js","old_string":"a","new_string":"b"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "cli evaluate: allowlisted scan-json-validate / scan-download-hints scripts are NOT paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/scan-json-validate.js","content":"x"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
}

@test "cli evaluate: platform source reads are paused after the zero-budget policy is exhausted" {
    materialize_writing_task "$BOOK"
    # 历史会话可能已有源码读取记录；当前写作阶段仍必须立即暂停。
    local ledger="$BOOK/追踪/workflow/tasks/wf-budget-test/tool-events.jsonl"
    {
        printf '%s\n' '{"ts":"2026-07-17T00:00:00Z","tool_name":"Bash","decision":"allow","code":"ok","reason":"platform_source_read","command":"find scripts/"}'
        printf '%s\n' '{"ts":"2026-07-17T00:00:01Z","tool_name":"Bash","decision":"allow","code":"ok","reason":"platform_source_read","command":"grep -rn x scripts/"}'
        printf '%s\n' '{"ts":"2026-07-17T00:00:02Z","tool_name":"Bash","decision":"allow","code":"ok","reason":"platform_source_read","command":"cat scripts/workflow-state-machine.js"}'
    } > "$ledger"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"grep -rn transition scripts/"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_interactive_tool_budget_exhausted'* ]]
    [[ "$output" == *'最后可信断点'* ]]
}

@test "cli evaluate: the first platform source read is paused in writing mode" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"grep -rn transition scripts/"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_interactive_tool_budget_exhausted'* ]]
}

# ===================================================================
# fail-open：非写作项目 / 缺失任务 -> 不阻断
# ===================================================================

@test "cli evaluate: empty project (no task) is fail-open allowed without writing ledger" {
    deploy_book
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id nonexistent \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/debug-x.js","content":"x"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
    [[ "$output" == *'"fail_open"'* ]] || [[ "$output" == *'"reason":"no_focused_task"'* ]]
    # 没有任务目录时不应写账本
    [ ! -f "$BOOK/追踪/workflow/tasks/nonexistent/tool-events.jsonl" ]
}

@test "cli evaluate: non-writing workflow_type (scan) platform debug write is allowed" {
    # 扫榜/拆文等非写作 workflow_type 不属于写作模式，平台诊断放行。
    mkdir -p "$BOOK/追踪/workflow/tasks/wf-scan/result-packets"
    local task='{
      "schemaVersion":"1.0.0","state_version":1,"workflow_id":"wf-scan",
      "workflow_type":"scan","status":"running","current_stage":"scan_execute",
      "current_step":"scan_execute","task_dir":"追踪/workflow/tasks/wf-scan",
      "runtime_guard":{"max_retry_budget":{"same_failure":1}}
    }'
    printf '%s\n' "$task" > "$BOOK/追踪/workflow/tasks/wf-scan/task.json"
    printf '%s\n' '{"schemaVersion":"1.0.0","workflow_id":"wf-scan","task_dir":"追踪/workflow/tasks/wf-scan"}' \
        > "$BOOK/追踪/workflow/current-task.json"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-scan \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/debug-helper.js","content":"x"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
}

# ===================================================================
# Hook 部署 + 集成：通过 stdin payload 跑已部署的 hook
# ===================================================================

@test "hook deploys as executable PreToolUse guard via runtime sync" {
    deploy_book
    # .js hooks 通过显式 `node` 命令调用(见 settings-hooks.json),不依赖 +x 位,
    # 参照 canonical-write-guard.js / safe-bash-guard.js 部署惯例。只断言存在 + 已注册。
    test -f "$BOOK/.claude/hooks/workflow-tool-budget-guard.js"
    grep -q 'workflow-tool-budget-guard.js' "$BOOK/.claude/settings.local.json"
    # settings.local.json 中 workflow-tool-budget-guard 命令唯一出现（去重合并）
    local count
    count=$(grep -o 'workflow-tool-budget-guard.js' "$BOOK/.claude/settings.local.json" | wc -l | tr -d ' ')
    [ "$count" -eq 1 ]
    # 且 matcher 覆盖写作相关工具
    grep -q '"matcher": "Bash|Read|Write|Edit|MultiEdit"' "$BOOK/.claude/settings.local.json"
}

@test "hook: writing-mode deny of scripts/debug-reconcile.js emits deny decision" {
    deploy_book
    materialize_writing_task "$BOOK"
    run_guard "$BOOK" '{"tool_name":"Write","tool_input":{"file_path":"scripts/debug-reconcile.js","content":"x"}}'
    # deny 走 exit 2 + stderr 文本回给模型(参照 canonical-write-guard.js 的阻断约定)。
    [ "$status" -eq 2 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
    # 写了 paused 事件到账本
    [ -f "$BOOK/追踪/workflow/tasks/wf-budget-test/tool-events.jsonl" ]
    grep -q 'pause' "$BOOK/追踪/workflow/tasks/wf-budget-test/tool-events.jsonl"
}

@test "hook: writing-mode allow of Read Brief does not block" {
    deploy_book
    materialize_writing_task "$BOOK"
    run_guard "$BOOK" '{"tool_name":"Read","tool_input":{"file_path":"追踪/private-short-extension/section-006-brief.md"}}'
    [ "$status" -eq 0 ]
    ! [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook: fail-open when no focused task in project (exit 0, no deny)" {
    deploy_book
    # 不 materialize 任务，hook 必须放行(兼容非写作项目)
    run_guard "$BOOK" '{"tool_name":"Write","tool_input":{"file_path":"scripts/debug-anything.js","content":"x"}}'
    [ "$status" -eq 0 ]
    ! [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook: library load failure is fail-open (does not hard-block ordinary projects)" {
    deploy_book
    materialize_writing_task "$BOOK"
    # 把 deployed budget lib 改名模拟加载失败，hook 必须 fail-open
    mv "$BOOK/scripts/lib/interactive-tool-budget.js" "$BOOK/scripts/lib/interactive-tool-budget.js.bak"
    run_guard "$BOOK" '{"tool_name":"Write","tool_input":{"file_path":"scripts/debug-x.js","content":"x"}}'
    [ "$status" -eq 0 ]
    ! [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

# ===================================================================
# Fix round 1:绕过路径加固
# ===================================================================

# Fix 1: Bash 重定向写受管源码绕过
@test "fix1: writing-mode Bash redirect echo > scripts/workflow-state-machine.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"echo \"x\" > scripts/workflow-state-machine.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
    [[ "$output" == *'workflow-state-machine.js'* ]]
}

@test "fix1: writing-mode Bash append >> scripts/lib/workflow-state-machine.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"echo more >> scripts/lib/workflow-state-machine.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix1: writing-mode Bash tee scripts/debug-x.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"echo x | tee scripts/debug-x.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix1: writing-mode Bash node -e writeFileSync scripts/debug-x.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"node -e \"require(\\\"fs\\\").writeFileSync(\\\"scripts/debug-x.js\\\",\\\"x\\\")\""}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix1: writing-mode Bash sed -i on scripts/workflow-state-machine.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"sed -i s/a/b/g scripts/workflow-state-machine.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix1: writing-mode Bash cp into scripts/workflow-state-machine.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"cp /tmp/x scripts/workflow-state-machine.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix1: writing-mode Bash heredoc cat > scripts/lib/workflow-runner.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"cat > scripts/lib/workflow-runner.js <<EOF\nx\nEOF"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix1: writing-mode Bash redirect to non-protected path is allowed (no false positive)" {
    materialize_writing_task "$BOOK"
    # 写正文文件 /tmp 之类不应被检测为平台源码写入
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"echo x > 正文.md"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
}

@test "fix1: writing-mode Bash redirect to allowlisted scan-json-validate.js is allowed" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"echo x > scripts/scan-json-validate.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"allow"'* ]]
}

# Fix 2: .py/无扩展名调试脚本绕过
@test "fix2: writing-mode Write of scripts/debug-reconcile.py is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/debug-reconcile.py","content":"print(1)"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix2: writing-mode Write of scripts/debug-foo (no extension) is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/debug-foo","content":"x"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix2: writing-mode Write of scripts/find-leak.rb is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/find-leak.rb","content":"x"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

# Fix 3: MANAGED_SOURCE_FILES 不完整 -> 改用路径模式
@test "fix3: writing-mode Edit of previously-missing scripts/lib/workflow-recovery-service.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Edit \
        --tool-input '{"file_path":"scripts/lib/workflow-recovery-service.js","old_string":"a","new_string":"b"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix3: writing-mode Edit of scripts/lib/memory-recommender.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Edit \
        --tool-input '{"file_path":"scripts/lib/memory-recommender.js","old_string":"a","new_string":"b"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix3: writing-mode Edit of top-level scripts/workflow-runner-telemetry.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Edit \
        --tool-input '{"file_path":"scripts/workflow-runner-telemetry.js","old_string":"a","new_string":"b"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix3: writing-mode Edit of .claude/hooks/workflow-tool-budget-guard.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Edit \
        --tool-input '{"file_path":".claude/hooks/workflow-tool-budget-guard.js","old_string":"a","new_string":"b"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix3: writing-mode Bash cp into scripts/lib/workflow-recovery-service.js is paused" {
    materialize_writing_task "$BOOK"
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"cp /tmp/x scripts/lib/workflow-recovery-service.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

# Fix 4: current_section_draft 私有 stage
@test "fix4: writing-mode current_section_draft stage blocks Bash write to managed source" {
    materialize_writing_task "$BOOK" current_section_draft
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Bash \
        --tool-input '{"command":"echo x > scripts/workflow-state-machine.js"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}

@test "fix4: writing-mode current_section_draft stage blocks Write of debug script" {
    materialize_writing_task "$BOOK" current_section_draft
    run node "$BUDGET_CLI" evaluate \
        --project-root "$BOOK" \
        --workflow-id wf-budget-test \
        --tool-name Write \
        --tool-input '{"file_path":"scripts/debug-leak.js","content":"x"}' \
        --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"decision":"pause"'* ]]
    [[ "$output" == *'blocked_writing_mode_platform_debug'* ]]
}
