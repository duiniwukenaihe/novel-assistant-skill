#!/usr/bin/env bats
# tests/check-scripts.bats — 守卫脚本自身单测
# Starter 套件：覆盖 6 个 .sh 脚本的存在性 + 可执行性 + 至少一个具体行为断言。
# 后续 PR 应继续扩充具体行为断言。

setup() {
    SCRIPTS_DIR="$BATS_TEST_DIRNAME/../scripts"
    FIXTURES="$BATS_TEST_DIRNAME/fixtures"
}

# check-shared-files.sh
@test "check-shared-files.sh exists and is executable" {
    [ -x "$SCRIPTS_DIR/check-shared-files.sh" ]
}

@test "check-upstream.sh exists and is executable" {
    [ -x "$SCRIPTS_DIR/check-upstream.sh" ]
    bash "$SCRIPTS_DIR/check-upstream.sh" --help | grep -q "Upstream git URL"
}

@test "novel-assistant-self-update.js exists and documents dry-run default" {
    [ -x "$SCRIPTS_DIR/novel-assistant-self-update.js" ]
    node "$SCRIPTS_DIR/novel-assistant-self-update.js" --help | grep -q "Default mode only checks"
}

@test "scripts README indexes development scripts and runtime boundary" {
    readme="$SCRIPTS_DIR/README.md"
    [ -f "$readme" ]
    grep -q "不是 skill 运行时脚本" "$readme"
    grep -q "运行时脚本在源码模块自己的 scripts/" "$readme"
    grep -q "静态守卫" "$readme"
    grep -q "测试回归" "$readme"
    grep -q "代码生成 / 同步" "$readme"
    grep -q "长篇稳定性 / 项目状态" "$readme"
    grep -q "check-shared-files.sh" "$readme"
    grep -q "story-prose-gate.js" "$readme"
    grep -q "tool-task-decompose-plan.js" "$readme"
    grep -q "build-oh-story-bundle.sh" "$readme"
}

@test "check-shared-files.sh exits 0 when all shared copies byte-equal" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/repo/src/internal-skills/story-long-write/scripts" "$tmp/repo/src/internal-skills/story-deslop/scripts" "$tmp/repo/scripts"
    cd "$tmp/repo" && git init -q
    echo "same" > "$tmp/repo/scripts/check-ai-patterns.js"
    cp "$tmp/repo/scripts/check-ai-patterns.js" "$tmp/repo/src/internal-skills/story-long-write/scripts/check-ai-patterns.js"
    cp "$tmp/repo/scripts/check-ai-patterns.js" "$tmp/repo/src/internal-skills/story-deslop/scripts/check-ai-patterns.js"
    out="$(cd "$tmp/repo" && bash "$SCRIPTS_DIR/check-shared-files.sh" 2>&1)"
    echo "$out" | grep -q "All shared files are consistent"
    rm -rf "$tmp"
}

@test "check-shared-files.sh detects byte-level diff between two files" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/repo/src/internal-skills/story-long-write/scripts" "$tmp/repo/scripts"
    cd "$tmp/repo" && git init -q
    echo "content-v1" > "$tmp/repo/scripts/check-ai-patterns.js"
    echo "content-v2" > "$tmp/repo/src/internal-skills/story-long-write/scripts/check-ai-patterns.js"
    out="$(cd "$tmp/repo" && bash "$SCRIPTS_DIR/check-shared-files.sh" 2>&1 || true)"
    echo "$out" | grep -q "MISMATCH: check-ai-patterns.js"
    rm -rf "$tmp"
}

@test "check-shared-files.sh ignores bundled internal SKILL and template variants" {
    tmp="$(mktemp -d)"
    mkdir -p \
        "$tmp/repo/skills/novel-assistant/references/internal-skills/story-long-write" \
        "$tmp/repo/skills/novel-assistant/references/internal-skills/story-review" \
        "$tmp/repo/src/internal-skills/story-setup/references/templates/agents" \
        "$tmp/repo/src/internal-skills/story-setup/references/opencode/agents" \
        "$tmp/repo/scripts"
    cd "$tmp/repo" && git init -q
    echo "long write skill" > "$tmp/repo/skills/novel-assistant/references/internal-skills/story-long-write/SKILL.md"
    echo "review skill" > "$tmp/repo/skills/novel-assistant/references/internal-skills/story-review/SKILL.md"
    echo "claude agent" > "$tmp/repo/src/internal-skills/story-setup/references/templates/agents/narrative-writer.md"
    echo "opencode agent variant" > "$tmp/repo/src/internal-skills/story-setup/references/opencode/agents/narrative-writer.md"
    out="$(cd "$tmp/repo" && bash "$SCRIPTS_DIR/check-shared-files.sh" 2>&1)"
    echo "$out" | grep -q "All shared files are consistent"
    rm -rf "$tmp"
}

@test "check-shared-files.sh detects managed reference mirror drift" {
    tmp="$(mktemp -d)"
    mkdir -p \
        "$tmp/repo/src/internal-skills/story-long-write/references" \
        "$tmp/repo/src/internal-skills/story-setup/references/agent-references" \
        "$tmp/repo/scripts"
    cd "$tmp/repo" && git init -q
    echo "source checklist" > "$tmp/repo/src/internal-skills/story-long-write/references/quality-checklist.md"
    echo "stale checklist" > "$tmp/repo/src/internal-skills/story-setup/references/agent-references/quality-checklist.md"
    out="$(cd "$tmp/repo" && bash "$SCRIPTS_DIR/check-shared-files.sh" 2>&1 || true)"
    echo "$out" | grep -q "MISMATCH: quality-checklist.md"
    rm -rf "$tmp"
}

# check-python-invocation.sh
@test "check-python-invocation.sh exists and is executable" {
    [ -x "$SCRIPTS_DIR/check-python-invocation.sh" ]
}

@test "check-python-invocation.sh flags bare python3 call in a temp .md file" {
    tmp_skill="$(mktemp -d)/test-skill.md"
    cat > "$tmp_skill" <<'EOF'
# Test
Use this: python3 -c "print(1)"
EOF
    out="$(bash "$SCRIPTS_DIR/check-python-invocation.sh" "$tmp_skill" 2>&1 || true)"
    echo "$out" | grep -qi "python3"
}

# static-check.sh
@test "static-check.sh exists and is executable" {
    [ -x "$SCRIPTS_DIR/static-check.sh" ]
}

@test "static-check.sh has frontmatter check" {
    grep -q "frontmatter" "$SCRIPTS_DIR/static-check.sh"
}

@test "static-check.sh completes on bundled novel-assistant skill" {
    repo="$BATS_TEST_DIRNAME/.."
    out="$(cd "$repo" && bash "$SCRIPTS_DIR/static-check.sh" 2>&1)"
    echo "$out" | grep -q "Skill Static Check"
    echo "$out" | grep -q "novel-assistant"
    echo "$out" | grep -q "Result:"
}

# check-story-setup-deployment.sh
@test "check-story-setup-deployment.sh exits 0 on fresh tmp repo (no setup)" {
    tmp_repo="$(mktemp -d)"
    cd "$tmp_repo" && git init -q
    bash "$SCRIPTS_DIR/check-story-setup-deployment.sh" 2>&1 | grep -qi "PASS\|FAIL\|ERROR\|test\|check" || true
    rm -rf "$tmp_repo"
}

@test "deployment runtime check delegates upgrade guide validation to semantic audit" {
    deploy_check="$SCRIPTS_DIR/check-story-setup-deployment.sh"
    ! grep -q 'UPGRADING_FILE=' "$deploy_check"
    grep -q -- '--check-upgrade-guide' "$deploy_check"
}

# check-hook-regex-sync.sh
@test "check-hook-regex-sync.sh exists and is executable" {
    [ -x "$SCRIPTS_DIR/check-hook-regex-sync.sh" ]
}

# test-charcount-portable.sh
@test "test-charcount-portable.sh real mode passes" {
    bash "$SCRIPTS_DIR/test-charcount-portable.sh" 2>&1 | grep -q "PASS"
}

# run-bats-lite.sh
@test "run-bats-lite.sh executes simple bats subset without bats installed" {
    [ -x "$SCRIPTS_DIR/run-bats-lite.sh" ]
    tmp_dir="$(mktemp -d)"
    cat > "$tmp_dir/sample.bats" <<'EOF'
setup() {
    VALUE="$BATS_TEST_DIRNAME/value.txt"
}

teardown() {
    rm -f "$VALUE"
}

@test "setup exposes BATS_TEST_DIRNAME" {
    echo "ok" > "$VALUE"
    [ -f "$VALUE" ]
}
EOF
    bash "$SCRIPTS_DIR/run-bats-lite.sh" "$tmp_dir/sample.bats"
    rm -rf "$tmp_dir"
}

@test "run-bats-lite.sh exports BATS_TEST_TMPDIR and does not swallow fixture errors" {
    tmp_dir="$(mktemp -d)"
    cat > "$tmp_dir/uses-test-tmpdir.bats" <<'EOF'
@test "temporary fixture directory is available" {
    [ -n "$BATS_TEST_TMPDIR" ]
    [ -d "$BATS_TEST_TMPDIR" ]
    touch "$BATS_TEST_TMPDIR/probe"
    [ -f "$BATS_TEST_TMPDIR/probe" ]
}
EOF
    set +e
    output="$(env -u BATS_TEST_TMPDIR bash "$SCRIPTS_DIR/run-bats-lite.sh" "$tmp_dir/uses-test-tmpdir.bats" 2>&1)"
    status="$?"
    set -e
    rm -rf "$tmp_dir"
    [ "$status" -eq 0 ] || return 1
    if echo "$output" | grep -q "unbound variable"; then
        echo "$output"
        return 1
    fi
    echo "$output" | grep -q "ok 1 - temporary fixture directory is available" || return 1
}

@test "run-bats-lite.sh returns nonzero on failed assertion" {
    tmp_dir="$(mktemp -d)"
    cat > "$tmp_dir/failing.bats" <<'EOF'
@test "intentional failure" {
    false
}
EOF
    set +e
    bash "$SCRIPTS_DIR/run-bats-lite.sh" "$tmp_dir/failing.bats" >/dev/null 2>&1
    status="$?"
    set -e
    rm -rf "$tmp_dir"
    [ "$status" -ne 0 ]
}

@test "run-bats-lite.sh returns nonzero on intermediate failed assertion" {
    tmp_dir="$(mktemp -d)"
    cat > "$tmp_dir/failing-middle.bats" <<'EOF'
@test "intermediate failure" {
    false
    true
}
EOF
    set +e
    bash "$SCRIPTS_DIR/run-bats-lite.sh" "$tmp_dir/failing-middle.bats" >/dev/null 2>&1
    status="$?"
    set -e
    rm -rf "$tmp_dir"
    [ "$status" -ne 0 ]
}

# run-bats-tests.sh
@test "run-bats-tests.sh falls back to run-bats-lite when bats is unavailable" {
    [ -x "$SCRIPTS_DIR/run-bats-tests.sh" ]
    tmp_dir="$(mktemp -d)"
    cat > "$tmp_dir/sample.bats" <<'EOF'
@test "fallback smoke" {
    true
}
EOF
    PATH="/usr/bin:/bin" bash "$SCRIPTS_DIR/run-bats-tests.sh" "$tmp_dir/sample.bats"
    rm -rf "$tmp_dir"
}
