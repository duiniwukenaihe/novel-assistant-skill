#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BOOK="$BATS_TEST_TMPDIR/book"
  WF="wf-impact"
  TASK_DIR="追踪/workflow/tasks/$WF"
  mkdir -p "$BOOK/$TASK_DIR/result-packets" "$BOOK/追踪/private-short-extension"
  cat > "$BOOK/$TASK_DIR/task.json" <<JSON
{"workflow_id":"$WF","workflow_type":"short_write","task_dir":"$TASK_DIR","current_stage":"short_structure_impact_audit","accepted_plan":{"affected_sections":[1],"projection_plan":{"planning_assets":["小节大纲.md"]}},"feedback_revision_queue":{"affected_sections":[1]},"stage_execution":{"status":"running","expected_result_packet":"$TASK_DIR/result-packets/short_structure_impact_audit.result.json"}}
JSON
  cat > "$BOOK/追踪/private-short-extension/section-title-lock.json" <<'JSON'
{"status":"confirmed","planned_sections":3,"sections":[{"section_index":1,"title":"旧标题"},{"section_index":2,"title":"新的第二节标题"},{"section_index":3,"title":"第三节"}]}
JSON
  cat > "$BOOK/追踪/private-short-extension/project-state.json" <<'JSON'
{"accepted_sections":[{"section_index":1,"title":"旧标题"},{"section_index":2,"title":"原第二节标题"},{"section_index":3,"title":"第三节"}]}
JSON
  printf '# 素材卡\n' > "$BOOK/素材卡.md"
  printf '# 设定\n' > "$BOOK/设定.md"
  printf '# 小节大纲\n' > "$BOOK/小节大纲.md"
}

@test "title changes automatically join the structure recheck scope" {
  run node "$REPO/scripts/short-structure-impact-finalize.js" --project-root "$BOOK" --workflow-id "$WF" --json
  [ "$status" -eq 0 ]
  report="$BOOK/$TASK_DIR/artifacts/short-structure-impact-audit.json"
  [ "$(jq -r '.affected_sections|join(",")' "$report")" = "1,2" ]
  [ "$(jq -r '.title_changed_sections|join(",")' "$report")" = "2" ]
  packet="$BOOK/$TASK_DIR/result-packets/short_structure_impact_audit.result.json"
  [ "$(jq -r '.affected_sections|join(",")' "$packet")" = "1,2" ]
}
