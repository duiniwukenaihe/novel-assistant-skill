#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/short-brief-freshness.js"
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$TMP_DIR/book/追踪/private-short-extension"
  printf '%s\n' '{"project_id":"short-brief-fixture","project_title":"果汁事件","plan_revision":1,"current_section_index":1,"accepted_sections":[]}' > "$TMP_DIR/book/追踪/private-short-extension/project-state.json"
  printf '# 素材卡\n果汁直播事件\n' > "$TMP_DIR/book/素材卡.md"
  printf '# 设定\n第一人称林照\n' > "$TMP_DIR/book/设定.md"
  printf '# 小节大纲\n第1节直播误切\n' > "$TMP_DIR/book/小节大纲.md"
  printf '# 写作 Brief：第001节\n直播误切空车间\n' > "$TMP_DIR/book/写作Brief_第001节.md"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "short brief snapshot remains current while dependencies are unchanged" {
  node "$SCRIPT" snapshot --project-root "$TMP_DIR/book" --brief 写作Brief_第001节.md --section-index 1 --write --json > "$TMP_DIR/snapshot.json"
  node "$SCRIPT" check --project-root "$TMP_DIR/book" --brief 写作Brief_第001节.md --section-index 1 --json > "$TMP_DIR/check.json"

  jq -e '.status == "snapshot_written" and .sidecar == "追踪/private-short-extension/briefs/section-001.json"' "$TMP_DIR/snapshot.json"
  jq -e '.status == "current" and .stale_dependencies == []' "$TMP_DIR/check.json"
}

@test "short brief becomes stale when the outline changes" {
  node "$SCRIPT" snapshot --project-root "$TMP_DIR/book" --brief 写作Brief_第001节.md --section-index 1 --write --json >/dev/null
  printf '# 小节大纲\n第1节改为热榜质疑后直播误切\n' > "$TMP_DIR/book/小节大纲.md"

  run node "$SCRIPT" check --project-root "$TMP_DIR/book" --brief 写作Brief_第001节.md --section-index 1 --json

  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.status == "stale" and (.stale_dependencies | index("小节大纲.md")) != null'
}

@test "short brief invalidation marker blocks prose even when digests match" {
  node "$SCRIPT" snapshot --project-root "$TMP_DIR/book" --brief 写作Brief_第001节.md --section-index 1 --write --json >/dev/null
  printf '# 写作 Brief：第001节（已失效）\n不得据此生成正文。\n' > "$TMP_DIR/book/写作Brief_第001节.md"

  run node "$SCRIPT" check --project-root "$TMP_DIR/book" --brief 写作Brief_第001节.md --section-index 1 --json

  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.status == "stale" and .invalidated_marker == true and (.stale_dependencies | index("写作Brief_第001节.md")) != null'
}
