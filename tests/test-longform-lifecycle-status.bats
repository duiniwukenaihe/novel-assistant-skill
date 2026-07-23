#!/usr/bin/env bats

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO/scripts/longform-lifecycle-status.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "lifecycle status guides a new book to its first planning layer" {
  mkdir -p "$BOOK"

  node "$SCRIPT" --project-root "$BOOK" --json > "$TMP_DIR/out.json"

  node - "$TMP_DIR/out.json" <<'NODE'
const out = require(process.argv[2]);
if (out.maturity !== 'missing') throw new Error(JSON.stringify(out));
if (out.recommended_actions[0].action_id !== 'define_positioning') throw new Error(JSON.stringify(out));
if (out.recommended_actions.some(item => item.action_id === 'write_next_chapter')) throw new Error('mechanical chapter recommendation leaked');
NODE
}

@test "lifecycle status recommends review before downstream generation" {
  mkdir -p "$BOOK/大纲" "$BOOK/追踪/workflow"
  printf '# 总纲\n' > "$BOOK/大纲/总纲.md"

  node "$SCRIPT" --project-root "$BOOK" --json > "$TMP_DIR/out.json"

  node - "$TMP_DIR/out.json" <<'NODE'
const out = require(process.argv[2]);
if (out.recommended_actions[0].action_id !== 'review_master_outline') throw new Error(JSON.stringify(out));
if (out.status !== 'action_required') throw new Error(JSON.stringify(out));
if (out.blocking_gaps.includes('master_outline')) throw new Error(JSON.stringify(out));
if (out.recommended_actions.some(item => item.action_id === 'write_next_chapter')) throw new Error('mechanical chapter recommendation leaked');
NODE
}

@test "lifecycle status follows accepted reviews through volume and detail planning" {
  mkdir -p "$BOOK/大纲/第1卷" "$BOOK/追踪/workflow"
  cat > "$BOOK/追踪/workflow/longform-lifecycle.json" <<'JSON'
{"assets":{"positioning":"accepted","story_bible":"accepted","master_outline":"accepted"}}
JSON
  cat > "$BOOK/追踪/workflow/longform-review-acceptances.json" <<'JSON'
{"accepted":["master_outline_review"]}
JSON
  printf '# 第一卷卷纲\n' > "$BOOK/大纲/第1卷/卷纲.md"

  node "$SCRIPT" --project-root "$BOOK" --json > "$TMP_DIR/out.json"

  node - "$TMP_DIR/out.json" <<'NODE'
const out = require(process.argv[2]);
if (out.recommended_actions[0].action_id !== 'review_volume_outline') throw new Error(JSON.stringify(out));
if (out.blocking_gaps.includes('chapter_brief')) throw new Error(JSON.stringify(out));
NODE
}

@test "lifecycle status routes a completed chapter stage to milestone review" {
  mkdir -p "$BOOK/追踪/workflow"
  node - "$BOOK/追踪/workflow/longform-lifecycle.json" <<'NODE'
const fs = require('fs');
const ids = require(process.cwd() + '/scripts/lib/longform-lifecycle').LIFECYCLE_NODES.map(node => node.id);
const assets = Object.fromEntries(ids.map(id => [id, 'accepted']));
assets.milestone_review = 'missing';
assets.volume_acceptance = 'missing';
assets.book_acceptance = 'missing';
fs.writeFileSync(process.argv[2], JSON.stringify({ assets }));
NODE

  node "$SCRIPT" --project-root "$BOOK" --json > "$TMP_DIR/out.json"

  node - "$TMP_DIR/out.json" <<'NODE'
const out = require(process.argv[2]);
if (out.recommended_actions[0].action_id !== 'review_milestone') throw new Error(JSON.stringify(out));
if (out.recommended_actions.some(item => item.action_id === 'write_next_chapter')) throw new Error(JSON.stringify(out));
NODE
}
