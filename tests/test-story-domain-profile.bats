#!/usr/bin/env bats
# tests/test-story-domain-profile.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    PROFILE_SCRIPT="$REPO/scripts/story-domain-profile.js"
    PROGRESS_SCRIPT="$REPO/scripts/story-progress-status.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "domain profile does not leak xiuzhen wording into martial food business project" {
    book="$TMP_DIR/book"
    mkdir -p "$book/设定/世界观" "$book/正文/第2卷"
    cat > "$book/.book-state.json" <<'JSON'
{"chapterLayout":"volume","bookTitle":"异世厨师经营小酒楼","targetGenre":"美食经营、门派武侠"}
JSON
    cat > "$book/设定/世界观/背景设定.md" <<'EOF'
主角在门派后厨用炒饭破局。密使苏禾被婚约束缚，顾远执掌门派。
能力来自基础心法、感知术、厨艺和经营博弈。当前阶段是内门、试炼、中央厨房。
EOF
    cat > "$book/正文/第2卷/第001章_试炼第一日.md" <<'EOF'
# 试炼第一日
陆川端着炒饭走进禁闭室，苏禾的感知术第一次失效。
EOF

    node "$PROFILE_SCRIPT" "$book" --json > "$TMP_DIR/profile.json"

    grep -q '"primaryDomain": "martial_food_business"' "$TMP_DIR/profile.json"
    grep -q '"growthAxisLabel": "修炼/武学与经营规则一致性"' "$TMP_DIR/profile.json"
    grep -q '"settingFileName": "修炼与能力规则.md"' "$TMP_DIR/profile.json"
    ! grep -q '修真进度一致性' "$TMP_DIR/profile.json"
    ! grep -q '力量体系.md' "$TMP_DIR/profile.json"
}

@test "domain profile allows xiuzhen wording only with explicit xiuzhen evidence" {
    book="$TMP_DIR/xianxia"
    mkdir -p "$book/设定/世界观" "$book/正文/第1卷"
    cat > "$book/.book-state.json" <<'JSON'
{"chapterLayout":"volume","bookTitle":"仙窟丐神","targetGenre":"修真仙侠"}
JSON
    cat > "$book/设定/世界观/核心规则.md" <<'EOF'
世界分为凡间、修真界、仙界。境界包括炼气、筑基、金丹、元婴、化神。
EOF
    cat > "$book/正文/第1卷/第001章_破庙.md" <<'EOF'
# 破庙
柳春帆在破庙中第一次感知灵气。
EOF

    node "$PROFILE_SCRIPT" "$book" --json > "$TMP_DIR/profile.json"

    grep -q '"primaryDomain": "xiuzhen_xianxia"' "$TMP_DIR/profile.json"
    grep -q '"growthAxisLabel": "修真进度一致性"' "$TMP_DIR/profile.json"
    grep -q '"settingFileName": "修真境界与规则.md"' "$TMP_DIR/profile.json"
}

@test "progress status includes domain profile for candidate wording" {
    book="$TMP_DIR/progress"
    mkdir -p "$book/设定/世界观" "$book/正文/第2卷"
    cat > "$book/.book-state.json" <<'JSON'
{"chapterLayout":"volume","bookTitle":"异世厨师经营小酒楼","targetGenre":"美食经营、门派武侠"}
JSON
    cat > "$book/设定/世界观/背景设定.md" <<'EOF'
门派使者、炒饭、基础心法、内门、后厨经营。
EOF
    cat > "$book/正文/第2卷/第001章_试炼第一日.md" <<'EOF'
# 试炼第一日
正文。
EOF

    node "$PROGRESS_SCRIPT" "$book" --json > "$TMP_DIR/progress.json"

    grep -q '"domainProfile"' "$TMP_DIR/progress.json"
    grep -q '"growthAxisLabel": "修炼/武学与经营规则一致性"' "$TMP_DIR/progress.json"
    ! grep -q '修真进度一致性' "$TMP_DIR/progress.json"
}

@test "domain profile ignores polluted tracking reports when genre facts disagree" {
    book="$TMP_DIR/polluted"
    mkdir -p "$book/设定/世界观" "$book/正文/第1卷" "$book/追踪/审查报告"
    cat > "$book/.book-state.json" <<'JSON'
{"chapterLayout":"volume","bookTitle":"异世厨师经营小酒楼","targetGenre":"美食经营、门派武侠"}
JSON
    cat > "$book/设定/世界观/背景设定.md" <<'EOF'
门派使者、炒饭、基础心法、内门、后厨经营。
EOF
    cat > "$book/正文/第1卷/第001章_灶台初醒.md" <<'EOF'
# 灶台初醒
陆川在门派后厨醒来。
EOF
    python3 - <<PY
from pathlib import Path
p = Path("$book/追踪/审查报告/污染报告.md")
p.write_text("修真进度阈值" * 200 + "\\n", encoding="utf-8")
PY

    node "$PROFILE_SCRIPT" "$book" --json > "$TMP_DIR/profile.json"

    grep -q '"primaryDomain": "martial_food_business"' "$TMP_DIR/profile.json"
    grep -q '"growthAxisLabel": "修炼/武学与经营规则一致性"' "$TMP_DIR/profile.json"
    ! grep -q '修真进度一致性' "$TMP_DIR/profile.json"
}
