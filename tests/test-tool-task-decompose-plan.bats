#!/usr/bin/env bats
# tests/test-tool-task-decompose-plan.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/tool-task-decompose-plan.js"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "tool task decomposition plans high-risk inline scripts instead of refusing task" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
python3 -c "
import json
print(json.dumps({'review': '1-722'}))
"
EOF

    node "$SCRIPT" --kind bash --payload-file "$TMP_DIR/payload.sh" --intent "审查 1-722 章" --json > "$TMP_DIR/out.json"
    grep -q '"status": "planned"' "$TMP_DIR/out.json"
    grep -q '"workflowStatus": "needs_tool_task_decomposition"' "$TMP_DIR/out.json"
    grep -q '"taskContinues": true' "$TMP_DIR/out.json"
    grep -q '"id": "read"' "$TMP_DIR/out.json"
    grep -q '"id": "plan"' "$TMP_DIR/out.json"
    grep -q '"id": "script"' "$TMP_DIR/out.json"
    grep -q '"id": "execute"' "$TMP_DIR/out.json"
    grep -q '"id": "verify"' "$TMP_DIR/out.json"
}

@test "tool task decomposition can write plan into project workflow directory" {
    mkdir -p "$TMP_DIR/book"
    cat > "$TMP_DIR/payload.sh" <<'EOF'
for f in $(find 正文 -name '*.md'); do
  python3 -c "print('$f')"
done
EOF

    node "$SCRIPT" --kind bash --payload-file "$TMP_DIR/payload.sh" --project-root "$TMP_DIR/book" --write --json > "$TMP_DIR/out.json"
    grep -q '"written"' "$TMP_DIR/out.json"
    find "$TMP_DIR/book/追踪/workflow/tool-task-plan" -name '*.json' | grep -q .
    find "$TMP_DIR/book/追踪/workflow/tool-task-plan" -name '*.md' | grep -q .
}

@test "tool task decomposition maps brittle prose stats snippets to chapter text stats" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
node -e "const s=require('fs').readFileSync('/book/正文/第12卷/第003章.md','utf8'); const body=s.split(/\n## 第七百二十三章/)[1].split('（本章完）')[0]; console.log(body.length)"
EOF

    node "$SCRIPT" --kind bash --payload-file "$TMP_DIR/payload.sh" --intent "统计第723章字数" --json > "$TMP_DIR/out.json"
    grep -q '"recognizedTask": "prose_text_stats"' "$TMP_DIR/out.json"
    grep -q '"taskShape": "prose_stats"' "$TMP_DIR/out.json"
    grep -q 'chapter-text-stats.js' "$TMP_DIR/out.json"
    grep -q "/book/正文/第12卷/第003章.md" "$TMP_DIR/out.json"
    grep -q '"status": "planned"' "$TMP_DIR/out.json"
}

@test "tool task decomposition maps stage2 grep loops to quality check script" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
cd "/book/拆文库/读书无用/章节/" && for n in 81 82 83 84 85 86; do
  f="第${n}章_摘要.md"
  pc=$(grep -cE '^P[0-9]+ ' "$f")
  jd=$(grep -cE '基调：' "$f")
  zt=$(grep -cE '主题标签' "$f")
  echo "$n $pc $jd $zt"
done
EOF

    node "$SCRIPT" --kind bash --payload-file "$TMP_DIR/payload.sh" --intent "硬质量检查：情节点/基调/主题" --json > "$TMP_DIR/out.json"
    grep -q '"recognizedTask": "stage2_summary_quality"' "$TMP_DIR/out.json"
    grep -q '"taskShape": "deconstruction_summary_quality"' "$TMP_DIR/out.json"
    grep -q 'stage2-summary-quality-check.js' "$TMP_DIR/out.json"
    grep -q -- "--chapters '81-86'" "$TMP_DIR/out.json"
    grep -q '"status": "planned"' "$TMP_DIR/out.json"
}

@test "tool task decomposition maps brittle cd grep head search to safe text search" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
cd <local-user-path>/data/work/novel-book-workspace/仙窟丐神/正文 && grep -l "仙窟封印" 第11卷/*.md 2>/dev/null | head -20
EOF

    node "$SCRIPT" --kind bash --payload-file "$TMP_DIR/payload.sh" --intent "在第11卷搜索仙窟封印" --json > "$TMP_DIR/out.json"
    grep -q '"recognizedTask": "safe_text_search"' "$TMP_DIR/out.json"
    grep -q '"taskShape": "text_search"' "$TMP_DIR/out.json"
    grep -q 'safe-text-search.js' "$TMP_DIR/out.json"
    grep -q "<local-user-path>/data/work/novel-book-workspace/仙窟丐神/正文/第11卷" "$TMP_DIR/out.json"
    grep -Fq -- "--glob '*.md'" "$TMP_DIR/out.json"
    grep -q -- "--query '仙窟封印'" "$TMP_DIR/out.json"
    grep -q -- "--limit 20" "$TMP_DIR/out.json"
    grep -q '"status": "planned"' "$TMP_DIR/out.json"
}

@test "tool task decomposition maps brittle volume count loops to chapter volume count" {
    cat > "$TMP_DIR/payload.sh" <<'EOF'
cd <local-user-path>/data/work/novel-book-workspace/仙窟丐神 && for v in 第1卷 第2卷 第3卷 第4卷 第5卷 第6卷 第7卷 第8卷; do
  cnt=$(ls 正文/$v/第*.md 2>/dev/null | grep -v "_原稿_" | wc -l | tr -d ' ')
  echo "$v: $cnt 章节"
done
EOF

    node "$SCRIPT" --kind bash --payload-file "$TMP_DIR/payload.sh" --intent "统计第1-8卷章节数量，排除原稿备份" --json > "$TMP_DIR/out.json"
    grep -q '"recognizedTask": "chapter_volume_count"' "$TMP_DIR/out.json"
    grep -q '"taskShape": "chapter_volume_count"' "$TMP_DIR/out.json"
    grep -q 'chapter-volume-count.js' "$TMP_DIR/out.json"
    grep -q "<local-user-path>/data/work/novel-book-workspace/仙窟丐神" "$TMP_DIR/out.json"
    grep -q -- "--volumes '第1卷,第2卷,第3卷,第4卷,第5卷,第6卷,第7卷,第8卷'" "$TMP_DIR/out.json"
    grep -q -- "--exclude '_原稿_'" "$TMP_DIR/out.json"
    grep -q '"status": "planned"' "$TMP_DIR/out.json"
}
