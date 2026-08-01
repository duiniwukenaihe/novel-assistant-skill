#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$REPO/tests/fixtures/write-short-v2-result.js"
  STATE="$REPO/scripts/workflow-state-machine.js"
  TMP_DIR="$(mktemp -d)"
  BOOK="$TMP_DIR/book"
  mkdir -p "$BOOK"
}

teardown() {
  rm -rf "$TMP_DIR"
}

@test "public short lifecycle advances a running stage through a V2 result packet" {
  run node "$STATE" create --workflow-type short_write --project-root "$BOOK" --user-goal "真实 V2 回执 E2E" --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  WORKFLOW_ID="$(node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
process.stdout.write(task.workflow_id);
NODE
)"

  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q '"status":"stage_applied"'
}

@test "public material card is committed by the production planning finalizer" {
  run node "$STATE" create --workflow-type short_write --project-root "$BOOK" --user-goal "真实 V2 规划 E2E" --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  for stage in project_type_lock material_source_choice; do
    run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    WORKFLOW_ID="$(node - "$BOOK" <<'NODE'
const fs = require('fs'); const path = require('path'); const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
process.stdout.write(JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8')).workflow_id);
NODE
)"
    run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    echo "$output" | grep -q '"status":"stage_applied"'
  done

  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q '"status":"stage_applied"'
  test -s "$BOOK/素材卡.md"
  node - "$BOOK" <<'NODE'
const fs = require('fs'); const path = require('path'); const root = process.argv[2];
const commits = path.join(root, '追踪/story-system/commits');
const found = fs.readdirSync(commits).map(name => JSON.parse(fs.readFileSync(path.join(commits, name), 'utf8')))
  .find(commit => commit.status === 'accepted' && commit.artifacts.some(item => item.target === '素材卡.md'));
if (!found) throw new Error('material card has no accepted transaction');
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
if (task.current_stage !== 'short_setting') throw new Error(`expected short_setting, got ${task.current_stage}`);
NODE
}

@test "public two-section workflow uses production gates, anchors, and assembly" {
  mkdir -p "$BOOK/追踪/story-system"
  printf '%s\n' '{"schemaVersion":"1.0.0","mode":"strict"}' > "$BOOK/追踪/story-system/write-policy.json"
  run node "$STATE" create --workflow-type short_write --project-root "$BOOK" --user-goal "真实 V2 两节规划 E2E" --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  WORKFLOW_ID="$(node - "$BOOK" <<'NODE'
const fs = require('fs'); const path = require('path'); const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
process.stdout.write(JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8')).workflow_id);
NODE
)"

  for stage in project_type_lock material_source_choice; do
    run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    echo "$output" | grep -q '"status":"stage_applied"'
  done
  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q '"status":"stage_ready_for_confirmation"'
  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q '"status":"stage_applied"'

  for stage in platform_genre_lock rhythm_pattern_selection section_outline; do
    run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ] || { echo "$stage: $output"; false; }
    echo "$output" | grep -q '"status":"stage_applied"'
  done

  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run node "$REPO/scripts/short-section-title-lock.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  TITLE_DIGEST="$(echo "$output" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).digest||""))')"
  [ -n "$TITLE_DIGEST" ]
  run node "$REPO/scripts/short-section-title-lock.js" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --digest "$TITLE_DIGEST" --confirm --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo "$output" | grep -q '"status":"section_plan_locked"'
  for stage in short_structure_impact_audit hook_value_gate section_brief; do
    run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ] || { echo "$stage: $output"; false; }
    echo "$output" | grep -q '"status":"stage_applied"'
  done
  node - "$BOOK" <<'NODE'
const fs = require('fs'); const path = require('path'); const root = process.argv[2];
const lock = JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/short/section-title-lock.json'), 'utf8'));
if (lock.status !== 'confirmed' || lock.planned_sections !== 2 || !lock.sections.every(item => item.confirmed)) throw new Error(JSON.stringify(lock));
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
if (task.current_stage !== 'draft_section') throw new Error(`expected draft_section, got ${task.current_stage}`);
if (!fs.existsSync(path.join(root, '写作Brief_第001节.md'))) throw new Error('production brief missing');
NODE

  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for stage in draft_section section_machine_gate quality_gate; do
    run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ] || { echo "$stage: $output"; false; }
    echo "$output" | grep -q '"status":"stage_applied"'
  done

  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "section_accept_anchor: $output"; false; }
  echo "$output" | grep -q '"status":"stage_applied"'
  test -s "$BOOK/追踪/story-system/short/section-001-anchor.json"

  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "next_section_brief: $output"; false; }
  echo "$output" | grep -q '"status":"stage_applied"'
  test -s "$BOOK/写作Brief_第002节.md"

  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for stage in draft_next_section section_machine_gate story_value_gate; do
    run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
    [ "$status" -eq 0 ] || { echo "$stage: $output"; false; }
    echo "$output" | grep -q '"status":"stage_applied"'
  done

  run node "$STATE" resolve-action --project-root "$BOOK" --input 1 --bind-current --no-private-registry --json
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "section_002_accept_anchor: $output"; false; }
  echo "$output" | grep -q '"status":"stage_applied"'
  test -s "$BOOK/追踪/story-system/short/section-002-anchor.json"

  run node "$FIXTURE" --project-root "$BOOK" --workflow-id "$WORKFLOW_ID" --json
  [ "$status" -eq 0 ] || { echo "full_story_assembly: $output"; false; }
  echo "$output" | grep -q '"status":"stage_applied"'
  test -s "$BOOK/正文.md"
  node - "$BOOK" <<'NODE'
const fs = require('fs'); const path = require('path'); const root = process.argv[2];
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
if (task.current_stage !== 'full_story_review') throw new Error('expected full_story_review, got ' + task.current_stage);
const commits = fs.readdirSync(path.join(root, '追踪/story-system/commits'))
  .map((name) => JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/commits', name), 'utf8')));
if (!commits.some((commit) => commit.status === 'accepted' && (commit.artifacts || []).some((item) => item.target === '正文.md'))) {
  throw new Error('full story has no accepted canonical transaction');
}
const packet = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'result-packets/full_story_assembly.result.json'), 'utf8'));
if (!packet.chapter_commit || packet.chapter_commit.mode !== 'transactional' || !packet.chapter_commit.accepted_commit_id) {
  throw new Error('assembly result packet has no transactional chapter_commit');
}
NODE
}
