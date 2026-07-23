#!/usr/bin/env bats
# tests/test-normalize-punctuation.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/src/internal-skills/story-deslop/scripts/normalize-punctuation.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "normalize-punctuation rewrites controlled Chinese em dashes" {
    FILE="$TMP_DIR/body.md"
    printf '他终于明白——真相就在账本里。\n她停了一下--还是推开门。\n---\n' > "$FILE"

    node "$SCRIPT" "$FILE"

    grep -q '他终于明白：真相就在账本里。' "$FILE"
    grep -q '她停了一下，还是推开门。' "$FILE"
    ! grep -q '——\|—\|--' "$FILE"
    ! grep -q '^---$' "$FILE"
}

@test "normalize-punctuation rewrites numeric ranges and interrupted dialogue" {
    FILE="$TMP_DIR/body.md"
    printf '价格从100——200之间浮动。\n「别过来——」\n' > "$FILE"

    node "$SCRIPT" "$FILE"

    grep -q '价格从100到200之间浮动。' "$FILE"
    grep -q '「别过来。」' "$FILE"
    ! grep -q '——\|—\|--' "$FILE"
}

@test "normalize-punctuation rejects per-character dash corruption for rewrite" {
    FILE="$TMP_DIR/body.md"
    printf '最——后——一——件——事——情——记——得——是——刹——车——声——。\n系——统：「本——系——统——记——录——宿——主——觉——醒」\n陈洛——听——到——这——个——声——音——他——愣——住——了——。\n' > "$FILE"

    if node "$SCRIPT" "$FILE" > "$TMP_DIR/output.txt" 2>&1; then
        echo "expected normalize-punctuation to reject corrupted prose"
        cat "$TMP_DIR/output.txt"
        return 1
    fi

    grep -q '逐字破折号化' "$TMP_DIR/output.txt"
    grep -q '必须回炉重写' "$TMP_DIR/output.txt"
    grep -q '最——后——一——件——事' "$FILE"
    grep -q '本——系——统' "$FILE"
}

@test "normalize-punctuation rejects dash density overuse without erasing prose" {
    FILE="$TMP_DIR/body.md"
    printf '他停住——门外有人。\n她抬头——灯灭了。\n风一吹——血腥味更重。\n黑狗崽龇牙——没退。\n陈洛笑了——掌心却在疼。\n下一秒——铃声响了。\n' > "$FILE"

    if node "$SCRIPT" "$FILE" > "$TMP_DIR/output.txt" 2>&1; then
        echo "expected normalize-punctuation to reject dash density overuse"
        cat "$TMP_DIR/output.txt"
        return 1
    fi

    grep -q '破折号密度失控' "$TMP_DIR/output.txt"
    grep -q '必须回炉重写或人工改写' "$TMP_DIR/output.txt"
    grep -q '他停住——门外有人。' "$FILE"
}

@test "normalize-punctuation shared script copies stay byte-identical" {
    cmp -s "$REPO/src/internal-skills/story-deslop/scripts/normalize-punctuation.js" "$REPO/src/internal-skills/story-review/scripts/normalize-punctuation.js"
    cmp -s "$REPO/src/internal-skills/story-deslop/scripts/normalize-punctuation.js" "$REPO/src/internal-skills/story-long-write/scripts/normalize-punctuation.js"
    cmp -s "$REPO/src/internal-skills/story-deslop/scripts/normalize-punctuation.js" "$REPO/src/internal-skills/story-short-write/scripts/normalize-punctuation.js"
}

@test "write skills reference normalize-punctuation workflow" {
    grep -q "normalize-punctuation.js" "$REPO/src/internal-skills/story-long-write/SKILL.md"
    grep -q "确定性标点收尾" "$REPO/src/internal-skills/story-long-write/SKILL.md"
    grep -q "normalize-punctuation.js" "$REPO/src/internal-skills/story-short-write/SKILL.md"
    grep -q "确定性标点收尾" "$REPO/src/internal-skills/story-short-write/SKILL.md"
}
