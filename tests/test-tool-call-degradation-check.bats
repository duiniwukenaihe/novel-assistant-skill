#!/usr/bin/env bats
# tests/test-tool-call-degradation-check.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/tool-call-degradation-check.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "tool call degradation check allows clean bash payloads" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
echo "=== 12 卷章节总数 ==="
total=0
for v in 第1卷 第2卷 第3卷; do
  c=$(find "/tmp/book/正文/$v" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + c))
done
echo "总数: $total"
EOF

    node "$SCRIPT" --kind bash --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "ok"' "$TMP_DIR/out.json"
}

@test "strict tool call guard allows one-line script commands" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
node scripts/story-schema-validate.js /tmp/book --json
EOF

    node "$SCRIPT" --kind bash --strict --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "ok"' "$TMP_DIR/out.json"
}

@test "strict tool call guard blocks inline python and multiline bash" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
python3 -c "
import json
print(json.dumps({'ok': True}))
"
EOF

    ! node "$SCRIPT" --kind bash --strict --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "needs_tool_task_decomposition"' "$TMP_DIR/out.json"
    grep -q '"action": "decompose_and_execute_scripted_steps"' "$TMP_DIR/out.json"
    grep -q '"decompositionRequired": true' "$TMP_DIR/out.json"
    grep -q 'high-risk-inline-script' "$TMP_DIR/out.json"
}

@test "strict tool call guard blocks heredoc scripts" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
python3 <<'PY'
print("ok")
PY
EOF

    ! node "$SCRIPT" --kind bash --strict --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "needs_tool_task_decomposition"' "$TMP_DIR/out.json"
    grep -q '"action": "decompose_and_execute_scripted_steps"' "$TMP_DIR/out.json"
    grep -q 'high-risk-heredoc' "$TMP_DIR/out.json"
}

@test "strict tool call guard treats high risk as decomposition not task refusal" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
for f in $(find book -name '*.md'); do
  python3 -c "print('$f')"
done
EOF

    ! node "$SCRIPT" --kind bash --strict --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "needs_tool_task_decomposition"' "$TMP_DIR/out.json"
    grep -q '"action": "decompose_and_execute_scripted_steps"' "$TMP_DIR/out.json"
    grep -q '"taskContinues": true' "$TMP_DIR/out.json"
    grep -q '"createOrReuseScript"' "$TMP_DIR/out.json"
    grep -q '"runOneLineScriptCommand"' "$TMP_DIR/out.json"
}

@test "strict tool call guard decomposes cd grep redirection pipeline that triggers authorization prompts" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
cd <local-user-path>/data/work/novel-book-workspace/仙窟丐神/正文 && grep -l "仙窟封印" 第11卷/*.md 2>/dev/null | head -20
EOF

    ! node "$SCRIPT" --kind bash --strict --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "needs_tool_task_decomposition"' "$TMP_DIR/out.json"
    grep -q 'high-risk-path-resolution-bypass' "$TMP_DIR/out.json"
    grep -q 'safe-text-search.js' "$TMP_DIR/out.json"
    grep -q '不要使用 cd + grep + 重定向/管道' "$TMP_DIR/out.json"
}

@test "tool call degradation check blocks diff hunk copied into bash" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
echo "=== 12 卷章节总数（应=762）==="
total=0; for v in 第1卷 第2卷 第3卷; do
  c=$(ls /book/正文/$v 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + c))
done
echo "总数: $total"
      1 +deployed_at: 2026-06-27T00:00:00Z
      2  agents_version: 17
      13 -migration_status: pending_user_decision
      13 +migration_status: migrated
EOF

    ! node "$SCRIPT" --kind bash --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "blocked_tool_command_contaminated"' "$TMP_DIR/out.json"
    grep -q 'bash-transcript-contamination' "$TMP_DIR/out.json"
    grep -q '"action": "discard_and_rebuild_bash"' "$TMP_DIR/out.json"
    grep -q '"retryLimit": 1' "$TMP_DIR/out.json"
    grep -q 'sanitizedPayload' "$TMP_DIR/out.json"
}

@test "tool call degradation check blocks numbered patch line copied into bash" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
echo "最终验证"
      1 +deployed_at: 2026-06-27T00:00:00Z
EOF

    ! node "$SCRIPT" --kind bash --json --file "$TMP_DIR/payload.sh" > "$TMP_DIR/out.json"
    grep -q '"status": "blocked_tool_command_contaminated"' "$TMP_DIR/out.json"
    grep -q 'patch-added-yaml' "$TMP_DIR/out.json"
}

@test "tool call degradation check blocks Claude transcript markers in agent prompts" {
    cat > "$TMP_DIR/payload.txt" <<'EOF'
请继续审阅 400-500 章。
⎿  Error writing file
Thought for 14s
EOF

    ! node "$SCRIPT" --kind agent --json --file "$TMP_DIR/payload.txt" > "$TMP_DIR/out.json"
    grep -q '"status": "blocked_tool_command_contaminated"' "$TMP_DIR/out.json"
    grep -q 'claude-tool-output' "$TMP_DIR/out.json"
    grep -q 'thinking-log' "$TMP_DIR/out.json"
    grep -q '"action": "discard_and_rebuild_agent"' "$TMP_DIR/out.json"
}

@test "story-workflow references executable tool call guard" {
    grep -q "tool-call-degradation-check.js" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "可疑 Bash/Agent/Write/Edit 前" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q -- "--strict" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "工具调用自愈协议" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "追踪/工具调用恢复" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "重建 payload 再跑" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "同一工具、同一动作、同一污染类型只允许自愈重试一次" "$REPO/src/internal-skills/story-workflow/SKILL.md"
    grep -q "不是拒绝任务" "$REPO/src/internal-skills/story-workflow/SKILL.md"
}
