#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    HANDOFF_SCRIPT="$REPO/scripts/cross-volume-handoff-pack.sh"
    AUDIT_SCRIPT="$REPO/scripts/cross-volume-continuity-audit.sh"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"

    mkdir -p \
        "$BOOK/正文/第1卷" \
        "$BOOK/正文/第2卷" \
        "$BOOK/大纲/第1卷" \
        "$BOOK/大纲/第2卷" \
        "$BOOK/追踪/章节契约/第1卷" \
        "$BOOK/追踪/章节契约/第2卷" \
        "$BOOK/追踪/漂移门控/第1卷" \
        "$BOOK/追踪/伏笔" \
        "$BOOK/设定/角色不变量"

    cat > "$BOOK/正文/第1卷/第002章_卷末试炼.md" <<'EOF'
# 第002章 卷末试炼

陆川握住铜纹令，令牌背面的苍岚门残印在夜里亮了一下。
苏禾站在门外，感知术第一次碰到一片空白。
EOF

    cat > "$BOOK/正文/第2卷/第001章_内门第一夜.md" <<'EOF'
# 第001章 内门第一夜

陆川进内门的第一夜，铜纹令残印又热了一次。
苏禾感知空白这件事，也在他掌心那点热意里重新浮出来。
EOF

    cat > "$BOOK/大纲/第1卷/卷纲.md" <<'EOF'
# 第1卷 卷纲

- 卷末悬念：铜纹令残印指向苍岚门。
- 下一卷预留：苏禾感知空白必须在第2卷开篇继续推进。
EOF

    cat > "$BOOK/大纲/第2卷/卷纲.md" <<'EOF'
# 第2卷 卷纲

- 卷首承接：铜纹令残印引入内门势力。
- 卷首情绪：苏禾感知空白变成关系推进压力。
EOF

    cat > "$BOOK/大纲/第2卷/细纲_第001章.md" <<'EOF'
# 第001章 内门第一夜

- 必须承接铜纹令残印。
- 必须继续苏禾感知空白。
EOF

    cat > "$BOOK/追踪/章节契约/第1卷/第002章.md" <<'EOF'
# 第002章契约

- 章尾钩子：铜纹令残印发热，指向苍岚门。
- 下一章读者期待：陆川带着铜纹令残印进入内门，苏禾感知空白继续发酵。
EOF

    cat > "$BOOK/追踪/章节契约/第2卷/第001章.md" <<'EOF'
# 第001章契约

- 跨卷承接：铜纹令残印必须推进。
- 角色连续性：苏禾感知空白不能消失。
EOF

    cat > "$BOOK/追踪/漂移门控/第1卷/第002章.md" <<'EOF'
Gate: PASS
EOF

    cat > "$BOOK/追踪/上下文.md" <<'EOF'
## 第002章 State Delta

- 陆川获得铜纹令残印线索。
- 苏禾感知空白成为下一卷关系压力。
EOF

    cat > "$BOOK/追踪/伏笔.md" <<'EOF'
| id | 状态 | 位置 | 内容 | 下一步 |
|---|---|---|---|---|
| F001 | 已埋 | 第1卷第002章 | 铜纹令残印 | 下一卷第001章必须推进 |
| F002 | 已埋 | 第1卷第002章 | 苏禾感知空白 | 下一卷前3章持续施压 |
EOF

    cat > "$BOOK/设定/角色不变量/陆川.md" <<'EOF'
# 陆川

- 当前阶段目标：查清铜纹令残印来源。
- 行为红线：不能抛下苏禾。
EOF
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "cross-volume handoff writes prior-volume hooks and foreshadows into next-volume bridge" {
    bash "$HANDOFF_SCRIPT" --write --from-volume 第1卷 --to-volume 第2卷 "$BOOK" 002 001

    [ -f "$BOOK/追踪/卷交接/第1卷_to_第2卷.md" ]
    grep -q "上一卷预留钩子" "$BOOK/追踪/卷交接/第1卷_to_第2卷.md"
    grep -q "铜纹令残印" "$BOOK/追踪/卷交接/第1卷_to_第2卷.md"
    grep -q "苏禾感知空白" "$BOOK/追踪/卷交接/第1卷_to_第2卷.md"
    grep -q "大纲/第2卷/细纲_第001章.md" "$BOOK/追踪/卷交接/第1卷_to_第2卷.md"
    grep -q "追踪/章节契约/第2卷/第001章.md" "$BOOK/追踪/卷交接/第1卷_to_第2卷.md"
}

@test "cross-volume continuity audit passes when next volume contract and body inherit bridge terms" {
    bash "$HANDOFF_SCRIPT" --write --from-volume 第1卷 --to-volume 第2卷 "$BOOK" 002 001 >/dev/null

    status=0
    output="$(bash "$AUDIT_SCRIPT" --from-volume 第1卷 --to-volume 第2卷 "$BOOK" 002 001 2>&1)" || status=$?

    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Audit: PASS"
    echo "$output" | grep -q "铜纹令残印"
    echo "$output" | grep -q "苏禾感知空白"
}

@test "cross-volume continuity audit fails when next volume body drops prior-volume foreshadow" {
    bash "$HANDOFF_SCRIPT" --write --from-volume 第1卷 --to-volume 第2卷 "$BOOK" 002 001 >/dev/null
    cat > "$BOOK/正文/第2卷/第001章_内门第一夜.md" <<'EOF'
# 第001章 内门第一夜

陆川进了内门，天色很暗。
EOF

    status=0
    output="$(bash "$AUDIT_SCRIPT" --from-volume 第1卷 --to-volume 第2卷 "$BOOK" 002 001 2>&1)" || status=$?

    [ "$status" -eq 1 ]
    echo "$output" | grep -q "Audit: FAIL"
    echo "$output" | grep -q "CrossVolume_Continuity_Missing"
    echo "$output" | grep -q "body"
}
