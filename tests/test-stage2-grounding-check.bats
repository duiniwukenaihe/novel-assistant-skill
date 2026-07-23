#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/stage2-grounding-check.js"
}

@test "stage2 grounding check rejects hallucinated chapter summary entities" {
    tmp="$(mktemp -d)"
    source="$tmp/source.txt"
    summary="$tmp/summary.md"
    cat > "$source" <<'SRC'
陆承安替人代笔，带着百楼诗会的帖子进门。
三皇子派人送来重礼，抄录《论语》时，纸上忽然引发九州异象。
SRC
    cat > "$summary" <<'MD'
## 第37章 错章

**概要**：楚歌进入御书房，秦寒与沈婉清讨论江城特管局。

**出场人物**：

| 角色 | 本章重要性 | 别名 | 本章表现 |
|------|-----------|------|----------|
| 楚歌 | major |  | 进入御书房 |
| 秦寒 | supporting |  | 讨论江城特管局 |

P1 **楚歌进入御书房**：类型行动 | 涉及楚歌，秦寒 | 地点御书房 | 物品 | 时间

楚歌推门进入御书房，秦寒抬头看向他。

主题标签权力 | 基调：紧张
MD

    if node "$SCRIPT" "$source" "$summary" --json > "$tmp/out.json" 2>"$tmp/err.txt"; then
        echo "expected grounding check to fail" >&2
        return 1
    fi
    grep -q '"status":"fail"' "$tmp/out.json"
    grep -q "unknown_entities" "$tmp/out.json"
    grep -q "quote_not_in_source" "$tmp/out.json"

    rm -rf "$tmp"
}

@test "stage2 grounding check accepts source-grounded chapter summary" {
    tmp="$(mktemp -d)"
    source="$tmp/source.txt"
    summary="$tmp/summary.md"
    cat > "$source" <<'SRC'
陆承安替人代笔，带着百楼诗会的帖子进门。
三皇子派人送来重礼，抄录《论语》时，纸上忽然引发九州异象。
SRC
    cat > "$summary" <<'MD'
## 第37章 代笔

**概要**：陆承安替人代笔后进入百楼诗会，因为三皇子送来重礼，所以他抄录《论语》并引发九州异象。

**出场人物**：

| 角色 | 本章重要性 | 别名 | 本章表现 |
|------|-----------|------|----------|
| 陆承安 | major |  | 替人代笔并抄录论语 |
| 三皇子 | supporting |  | 派人送来重礼 |

P1 **陆承安代笔入局**：类型行动 | 涉及陆承安，三皇子 | 地点百楼诗会 | 物品《论语》 | 时间

陆承安替人代笔，带着百楼诗会的帖子进门。

主题标签权力 | 基调：紧张
MD

    node "$SCRIPT" "$source" "$summary" --json > "$tmp/out.json"
    grep -q '"status":"pass"' "$tmp/out.json"

    rm -rf "$tmp"
}

@test "stage2 grounding check validates chapter range from deconstruction directory" {
    tmp="$(mktemp -d)"
    source="$tmp/source.txt"
    out="$tmp/拆文库/测试书"
    cat > "$source" <<'SRC'
第081章 中秋祭月佳节
陆承安站在祭月台前，百楼诗会的帖子被他压在袖中。

第082章 言出法随
三皇子派人送来重礼，陆承安抄录《论语》时，纸上忽然引发九州异象。
SRC
    node "$REPO/scripts/long-analyze-plan.js" "$source" "$out" --write --json --batch-size 30 > "$tmp/plan.json"
    mkdir -p "$out/章节"
    cat > "$out/章节/第81章_摘要.md" <<'MD'
## 第81章 中秋祭月佳节

**概要**：陆承安站在祭月台前，因为百楼诗会帖子被他压在袖中，所以本章围绕祭月台前的入局展开。

**出场人物**：

| 角色 | 本章重要性 | 别名 | 本章表现 |
|------|-----------|------|----------|
| 陆承安 | major |  | 站在祭月台前并携带百楼诗会帖子 |

P1 **陆承安祭月台前入局**：类型行动 | 涉及陆承安 | 地点祭月台 | 物品百楼诗会的帖子 | 时间中秋

陆承安站在祭月台前，百楼诗会的帖子被他压在袖中。

主题标签权力 | 基调：紧张
MD
    cat > "$out/章节/第82章_摘要.md" <<'MD'
## 第82章 言出法随

**概要**：三皇子派人送来重礼，因为陆承安抄录《论语》，所以纸上引发九州异象。

**出场人物**：

| 角色 | 本章重要性 | 别名 | 本章表现 |
|------|-----------|------|----------|
| 三皇子 | supporting |  | 派人送来重礼 |
| 陆承安 | major |  | 抄录论语并引发九州异象 |

P1 **陆承安抄录引发异象**：类型信息揭示 | 涉及陆承安，三皇子 | 地点 | 物品《论语》 | 时间

三皇子派人送来重礼，陆承安抄录《论语》时，纸上忽然引发九州异象。

主题标签悬念 | 基调：热血
MD

    node "$SCRIPT" "$out" --chapters 81-82 --json > "$tmp/out.json"
    grep -q '"status":"pass"' "$tmp/out.json"
    grep -q '"checked":2' "$tmp/out.json"

    rm -rf "$tmp"
}

@test "stage2 grounding check supports legacy deconstruction dirs with root chapter source files" {
    tmp="$(mktemp -d)"
    out="$tmp/拆文库/旧书"
    mkdir -p "$out/章节"
    cat > "$out/第81章 中秋祭月佳节.md" <<'SRC'
陆承安站在祭月台前，百楼诗会的帖子被他压在袖中。
SRC
    cat > "$out/章节/第81章_摘要.md" <<'MD'
## 第81章 中秋祭月佳节

**概要**：陆承安站在祭月台前，因为百楼诗会帖子被他压在袖中，所以本章围绕祭月台前的入局展开。

**出场人物**：

| 角色 | 本章重要性 | 别名 | 本章表现 |
|------|-----------|------|----------|
| 陆承安 | major |  | 站在祭月台前并携带百楼诗会帖子 |

P1 **陆承安祭月台前入局**：类型行动 | 涉及陆承安 | 地点祭月台 | 物品百楼诗会的帖子 | 时间中秋

陆承安站在祭月台前，百楼诗会的帖子被他压在袖中。

主题标签权力 | 基调：紧张
MD

    node "$SCRIPT" "$out" --chapters 81 --json > "$tmp/out.json"
    grep -q '"status":"pass"' "$tmp/out.json"
    grep -q '"checked":1' "$tmp/out.json"

    rm -rf "$tmp"
}
