#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP_DIR="$(mktemp -d)"
  cp -R "$REPO/tests/fixtures/review-evidence-map/flat/." "$TMP_DIR/"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "one command scans a review batch and returns compact evidence" {
  run node "$REPO/scripts/review-batch-evidence-scan.js" \
    --project-root "$TMP_DIR" --range 1-1 --query "开端" --json

  [ "$status" -eq 0 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      if(x.status!=="ok") process.exit(1);
      if(x.summary.mappedChapters!==1) process.exit(2);
      if(!x.chapterStats || x.chapterStats.totalChars<1) process.exit(3);
      if(!x.queries || x.queries[0].query!=="开端") process.exit(4);
      if(Object.hasOwn(x,"chapters")) process.exit(5);
      if(x.protocolVersion!=="2.0.0") process.exit(6);
      if(!/^[0-9a-f]{64}$/.test(x.sourceDigest||"")) process.exit(7);
      const coverage=x.fullRangeCoverage||{};
      if(coverage.start!==1||coverage.end!==1||coverage.coveredChapters!==1||coverage.complete!==true) process.exit(8);
    });'
}

@test "write mode stores one range-scoped evidence artifact" {
  run node "$REPO/scripts/review-batch-evidence-scan.js" \
    --project-root "$TMP_DIR" --range 1-1 --write --json

  [ "$status" -eq 0 ]
  [ -f "$TMP_DIR/evidence/batch-scan-001-001.json" ]
  node -e 'const x=require(process.argv[1]); if(x.range.start!==1||x.range.end!==1)process.exit(1)' \
    "$TMP_DIR/evidence/batch-scan-001-001.json"
}

@test "identity blockers remain visible in the compact batch result" {
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  cp -R "$REPO/tests/fixtures/review-evidence-map/volume-local/." "$TMP_DIR/"
  printf '%s\n' '{"chapterLayout":"volume"}' > "$TMP_DIR/.book-state.json"
  printf '%s\n' '{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":43,"draftPath":"正文/第1卷/第001章_另一路径.md"}' > "$TMP_DIR/追踪/章节资产.jsonl"
  cp "$TMP_DIR/正文/第1卷/第001章_开端.md" "$TMP_DIR/正文/第1卷/第001章_另一路径.md"

  run node "$REPO/scripts/review-batch-evidence-scan.js" --project-root "$TMP_DIR" --range 43-43 --json

  [ "$status" -eq 2 ]
  printf '%s' "$output" | node -e '
    let raw=""; process.stdin.on("data",c=>raw+=c); process.stdin.on("end",()=>{
      const x=JSON.parse(raw);
      if(x.status!=="blocked_chapter_identity_conflict") process.exit(1);
      if(!x.blockerCounts["chapter-identity-path-conflict"]) process.exit(2);
      if(x.summary.blockingSignals<1) process.exit(3);
    });'
}
