#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/book"
  mkdir -p "$BOOK/追踪/workflow/tasks/wf-short"
}

@test "new short projects store public workflow state outside private trend forge" {
  run node - "$REPO/scripts/lib/short-project-state.js" "$BOOK" <<'NODE'
const state = require(process.argv[2]);
state.ensureShortProjectState(process.argv[3], { workflowId: 'wf-short', title: '测试短篇' });
console.log(state.resolveShortStateRelative(process.argv[3], 'project-state.json', { forWrite: true }));
NODE
  [ "$status" -eq 0 ]
  [ "$output" = "追踪/story-system/short/project-state.json" ]
  [ -f "$BOOK/追踪/story-system/short/project-state.json" ]
  [ ! -e "$BOOK/追踪/private-short-extension/project-state.json" ]
}

@test "legacy short projects keep one authoritative legacy state until explicit migration" {
  mkdir -p "$BOOK/追踪/private-short-extension"
  printf '%s\n' '{"project_id":"legacy-short","project_title":"旧短篇"}' > "$BOOK/追踪/private-short-extension/project-state.json"

  run node - "$REPO/scripts/lib/short-project-state.js" "$BOOK" <<'NODE'
const state = require(process.argv[2]);
const root = process.argv[3];
const current = state.ensureShortProjectState(root, { workflowId: 'wf-short' });
console.log(JSON.stringify({ id: current.project_id, rel: state.resolveShortStateRelative(root, 'project-state.json', { forWrite: true }) }));
NODE
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id":"legacy-short"'* ]]
  [[ "$output" == *'"rel":"追踪/private-short-extension/project-state.json"'* ]]
  [ ! -e "$BOOK/追踪/story-system/short/project-state.json" ]
}

@test "canonical short state wins after explicit storage migration" {
  mkdir -p "$BOOK/追踪/private-short-extension"
  printf '%s\n' '{"project_id":"legacy-short","project_title":"旧短篇"}' > "$BOOK/追踪/private-short-extension/project-state.json"

  run node - "$REPO/scripts/lib/short-project-state.js" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const state = require(process.argv[2]);
const root = process.argv[3];
const result = state.migrateShortStateStorage(root);
fs.writeFileSync(path.join(root, '追踪/private-short-extension/project-state.json'), '{"project_id":"poisoned-legacy"}\n');
console.log(JSON.stringify({ result, state: state.readShortProjectState(root) }));
NODE
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"migrated"'* ]]
  [[ "$output" == *'"project_id":"legacy-short"'* ]]
  [[ "$output" != *'poisoned-legacy'* ]]
}

@test "short state migration command is part of the installable runtime bundle" {
  run node - "$REPO/config/novel-assistant-bundle-files.json" <<'NODE'
const manifest = require(process.argv[2]);
if (!manifest.scriptFiles.includes('short-state-storage-migrate.js')) process.exit(1);
NODE
  [ "$status" -eq 0 ]
}
