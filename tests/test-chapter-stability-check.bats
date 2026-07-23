#!/usr/bin/env bats
# tests/test-chapter-stability-check.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/longform-stability-mini"
    SCRIPT="$REPO/scripts/chapter-stability-check.sh"
    LEGACY_SCRIPT="$REPO/scripts/check-longform-stability-fixture.sh"
    DAILY_AUDIT="$REPO/scripts/longform-daily-stability-audit.sh"
}

@test "chapter stability check validates individual chapters" {
    [ -x "$SCRIPT" ]

    output_001="$(bash "$SCRIPT" "$FIXTURE" "001")"
    output_002="$(bash "$SCRIPT" "$FIXTURE" "002")"

    echo "$output_001" | grep -q "Chapter Stability Check PASS: chapter 001"
    echo "$output_002" | grep -q "Chapter Stability Check PASS: chapter 002"
}

@test "chapter stability check supports volume-local chapter artifacts" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    mkdir -p "$tmp/book/正文/第1卷" "$tmp/book/追踪/章节契约/第1卷" "$tmp/book/追踪/漂移门控/第1卷"
    mv "$tmp/book/正文/第001章_拒绝错误任务.md" "$tmp/book/正文/第1卷/第001章_拒绝错误任务.md"
    mv "$tmp/book/追踪/章节契约/第001章.md" "$tmp/book/追踪/章节契约/第1卷/第001章.md"
    mv "$tmp/book/追踪/漂移门控/第001章.md" "$tmp/book/追踪/漂移门控/第1卷/第001章.md"

    output="$(bash "$SCRIPT" "$tmp/book" "001")"

    echo "$output" | grep -q "Chapter Stability Check PASS: chapter 001"

    rm -rf "$tmp"
}

@test "chapter stability check rejects missing contract beat" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    perl -0pi -e 's/江临追查旧账号/江临检查缓存/g' "$tmp/book/正文/第002章_追查旧账号.md"

    ! bash "$SCRIPT" "$tmp/book" "002" >/dev/null 2>&1

    rm -rf "$tmp"
}

@test "chapter stability check rejects character knowledge leak from invariants" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    printf '\n江临已经提前知道委托人的真实目的。\n' >> "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$SCRIPT" "$tmp/book" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Knowledge_Leak"
    echo "$output" | grep -q "委托人的真实目的"

    rm -rf "$tmp"
}

@test "chapter stability check rejects character motivation drift from invariants" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    printf '\n江临决定为热度伪造事实。\n' >> "$tmp/book/正文/第002章_追查旧账号.md"

    set +e
    output="$(bash "$SCRIPT" "$tmp/book" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Motivation_Drift"
    echo "$output" | grep -q "为热度伪造事实"

    rm -rf "$tmp"
}

@test "chapter stability check scopes invariant scan to explicit POV segment" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    cat > "$tmp/book/设定/角色不变量/沈岚.md" <<'EOF'
# 角色不变量：沈岚

## 行为红线

- 不会：私自删除证据。

## 认知边界

- 当前知道：江临拒绝了错误任务。
- 不能提前知道：旧账号主人。
EOF
    cat >> "$tmp/book/正文/第002章_追查旧账号.md" <<'EOF'

## POV：沈岚

沈岚在自己的备忘里写下：委托人的真实目的。
EOF

    output="$(bash "$SCRIPT" "$tmp/book" "002")"

    echo "$output" | grep -q "Chapter Stability Check PASS: chapter 002"

    rm -rf "$tmp"
}

@test "chapter stability check detects invariant leak in matching POV segment" {
    tmp="$(mktemp -d)"
    cp -R "$FIXTURE" "$tmp/book"
    cat > "$tmp/book/设定/角色不变量/沈岚.md" <<'EOF'
# 角色不变量：沈岚

## 行为红线

- 不会：私自删除证据。

## 认知边界

- 当前知道：江临拒绝了错误任务。
- 不能提前知道：旧账号主人。
EOF
    cat >> "$tmp/book/正文/第002章_追查旧账号.md" <<'EOF'

## POV：沈岚

沈岚已经提前知道旧账号主人。
EOF

    set +e
    output="$(bash "$SCRIPT" "$tmp/book" "002" 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q "Knowledge_Leak"
    echo "$output" | grep -q "沈岚"
    echo "$output" | grep -q "旧账号主人"

    rm -rf "$tmp"
}

@test "legacy fixture checker delegates to generic chapter stability check" {
    grep -q "chapter-stability-check.sh" "$LEGACY_SCRIPT"
    bash "$LEGACY_SCRIPT" "$FIXTURE" "001" | grep -q "Longform stability fixture PASS: chapter 001"
}

@test "daily stability audit uses generic chapter stability check" {
    grep -q "chapter-stability-check.sh" "$DAILY_AUDIT"
}
