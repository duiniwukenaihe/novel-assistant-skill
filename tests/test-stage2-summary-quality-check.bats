#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/stage2-summary-quality-check.js"
}

@test "stage2 summary quality check validates a chapter range without shell expansion loops" {
    tmp="$(mktemp -d)"
    chapters="$tmp/章节"
    mkdir -p "$chapters"
    for n in 81 82; do
        cat > "$chapters/第${n}章_摘要.md" <<'MD'
## 第81章 示例

P1 **事件一**：类型行动 | 涉及陆承安 | 地点百楼 | 物品 | 时间

陆承安走进百楼。

主题标签权力 | 基调：紧张

P2 **事件二**：类型信息揭示 | 涉及陆承安 | 地点百楼 | 物品 | 时间

陆承安看见帖子。

主题标签悬念 | 基调：轻松
MD
    done

    node "$SCRIPT" "$chapters" --chapters 81-82 --json > "$tmp/out.json"
    grep -q '"status":"pass"' "$tmp/out.json"
    grep -q '"checked":2' "$tmp/out.json"

    rm -rf "$tmp"
}

@test "stage2 summary quality check rejects missing tone and invalid topic" {
    tmp="$(mktemp -d)"
    chapters="$tmp/章节"
    mkdir -p "$chapters"
    cat > "$chapters/第81章_摘要.md" <<'MD'
## 第81章 示例

P1 **事件一**：类型行动 | 涉及陆承安 | 地点百楼 | 物品 | 时间

陆承安走进百楼。

主题标签紧张 | 基调：紧张

P2 **事件二**：类型信息揭示 | 涉及陆承安 | 地点百楼 | 物品 | 时间

陆承安看见帖子。

主题标签悬念
MD

    if node "$SCRIPT" "$chapters" --chapters 81 --json > "$tmp/out.json" 2>"$tmp/err.txt"; then
        echo "expected summary quality check to fail" >&2
        return 1
    fi
    grep -q '"status":"fail"' "$tmp/out.json"
    grep -q "tone_count_mismatch" "$tmp/out.json"
    grep -q "invalid_topic" "$tmp/out.json"

    rm -rf "$tmp"
}
