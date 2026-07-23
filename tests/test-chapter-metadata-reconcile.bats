#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO/scripts/chapter-metadata-reconcile.js"
  TMP_DIR="$(mktemp -d)"
  mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/追踪/schema"
  printf '# 正式稿\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章.md"
  printf '# 旧稿\n旧正文。\n' > "$TMP_DIR/正文/第1卷/第001章_原稿_20260622.md"
  printf '%s\n' '{"chapterId":"第001章","chapterNo":1,"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":1,"draftPath":"正文/第1卷/第001章.md"}' > "$TMP_DIR/追踪/schema/chapters.jsonl"
  printf '%s\n' '{"chapterId":"第001章","chapterNo":1,"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":1,"draftPath":"正文/第1卷/第001章_原稿_20260622.md"}' > "$TMP_DIR/追踪/章节资产.jsonl"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "preview reports an obvious backup pointer without changing metadata" {
  before="$(shasum -a 256 "$TMP_DIR/追踪/章节资产.jsonl")"

  node "$SCRIPT" --project-root "$TMP_DIR" --json > "$TMP_DIR/result.json"

  grep -q '"status": "repairable"' "$TMP_DIR/result.json"
  grep -q '"repairableCount": 1' "$TMP_DIR/result.json"
  [ "$before" = "$(shasum -a 256 "$TMP_DIR/追踪/章节资产.jsonl")" ]
}

@test "write snapshots metadata and repoints only the asset ledger to current prose" {
  prose_before="$(find "$TMP_DIR/正文" -type f -print0 | sort -z | xargs -0 shasum -a 256)"

  node "$SCRIPT" --project-root "$TMP_DIR" --write --json > "$TMP_DIR/result.json"

  grep -q '"status": "reconciled"' "$TMP_DIR/result.json"
  grep -q '"changed": true' "$TMP_DIR/result.json"
  grep -q '"draftPath":"正文/第1卷/第001章.md"' "$TMP_DIR/追踪/章节资产.jsonl"
  snapshot="$(find "$TMP_DIR/追踪/workflow/metadata-snapshots" -type f -name '*.json' | head -1)"
  [ -n "$snapshot" ]
  grep -q '第001章_原稿_20260622.md' "$snapshot"
  [ "$prose_before" = "$(find "$TMP_DIR/正文" -type f -print0 | sort -z | xargs -0 shasum -a 256)" ]

  node "$SCRIPT" --project-root "$TMP_DIR" --write --json > "$TMP_DIR/second.json"
  grep -q '"status": "current"' "$TMP_DIR/second.json"
  grep -q '"changed": false' "$TMP_DIR/second.json"
}

@test "write refuses to choose between two live-looking chapter paths" {
  printf '# 另一正式稿\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_修订版.md"
  printf '%s\n' '{"chapterId":"第001章","chapterNo":1,"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":1,"draftPath":"正文/第1卷/第001章_修订版.md"}' > "$TMP_DIR/追踪/章节资产.jsonl"
  before="$(shasum -a 256 "$TMP_DIR/追踪/章节资产.jsonl")"

  run node "$SCRIPT" --project-root "$TMP_DIR" --write --json

  [ "$status" -ne 0 ]
  [[ "$output" == *'"status": "blocked_ambiguous_live_paths"'* ]]
  [ "$before" = "$(shasum -a 256 "$TMP_DIR/追踪/章节资产.jsonl")" ]
  [ ! -d "$TMP_DIR/追踪/workflow/metadata-snapshots" ]
}
