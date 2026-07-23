#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STATE="$REPO/scripts/workflow-state-machine.js"
    INBOX="$REPO/scripts/workflow-task-inbox.js"
    BUNDLE="$REPO/skills/novel-assistant"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "public short workflow owns a complete production lifecycle without private registry" {
    node "$STATE" templates --no-private-registry --json > "$TMP_DIR/templates.json"

    node - "$TMP_DIR/templates.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (Number(data.privateRegistryCount || 0) !== 0) throw new Error('private registry leaked into public templates');
const flow = data.templates.find((item) => item.workflow_type === 'short_write');
if (!flow) throw new Error('missing public short_write workflow');
if (flow.private_overlay) throw new Error('public workflow must not depend on a private overlay');
const stages = new Map(flow.stages.map((stage) => [stage.stage_id, stage]));
for (const id of [
  'material_card', 'short_setting', 'rhythm_pattern_selection', 'section_outline',
  'section_plan_lock', 'hook_value_gate', 'section_brief', 'draft_section',
  'section_machine_gate', 'story_value_gate', 'section_accept_anchor',
  'next_section_brief', 'full_story_assembly', 'full_story_review', 'deslop', 'final_check',
]) {
  if (!stages.has(id)) throw new Error(`missing public production stage: ${id}`);
}
for (const stage of stages.values()) {
  if (String(stage.owner_module || '').includes('private')) throw new Error(`private owner leaked: ${stage.stage_id}`);
}
if (stages.get('hook_value_gate').requires_user_confirm) throw new Error('read-only hook gate must auto-run after plan confirmation');
NODE
}

@test "public short task keeps workflow authority and portable project identity" {
    node "$STATE" create --workflow-type short_write --project-root "$BOOK" --user-goal "新开公开短篇" --no-private-registry --json > "$TMP_DIR/create.json"

    node - "$TMP_DIR/create.json" "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const root = process.argv[3];
const task = data.task;
if (task.workflow_profile !== 'public') throw new Error(JSON.stringify(task.workflow_profile));
if (task.workflow_owner !== 'story-short-write') throw new Error(JSON.stringify(task.workflow_owner));
if (task.production_kernel !== 'short-section-production-v2') throw new Error(JSON.stringify(task.production_kernel));
if (task.book_root !== '.') throw new Error(`book root must stay portable: ${task.book_root}`);
if (!task.workflow_id || !task.runtime_guard || !task.pending_action) throw new Error('missing durable workflow authority');
const durable = path.join(root, task.task_dir, 'task.json');
if (!fs.existsSync(durable)) throw new Error(`missing durable task: ${durable}`);
NODE
}

@test "public short startup resumes through the task inbox instead of private cards" {
    node "$STATE" create --workflow-type short_write --project-root "$BOOK" --user-goal "继续公开短篇" --no-private-registry --json >/dev/null
    node "$INBOX" --project-root "$BOOK" --json > "$TMP_DIR/inbox.json"

    node - "$TMP_DIR/inbox.json" <<'NODE'
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const raw = JSON.stringify(data);
if (!raw.includes('short_write')) throw new Error('public short task is missing from inbox');
if (raw.includes('private-short-extension') || raw.includes('private-short')) throw new Error('private short card leaked into public inbox');
NODE
}

@test "public bundle contains short writing workflow memory and transaction kernel" {
    test -f "$BUNDLE/references/internal-skills/story-short-write/SKILL.md"
    test -f "$BUNDLE/references/internal-skills/story-workflow/SKILL.md"
    test -f "$BUNDLE/references/internal-skills/story-memory/SKILL.md"
    test -x "$BUNDLE/scripts/workflow-state-machine.js"
    test -x "$BUNDLE/scripts/short-section-accept-finalize.js"
    test -x "$BUNDLE/scripts/short-story-review-finalize.js"
    test -f "$BUNDLE/scripts/lib/short-memory-snapshot.js"
    test -f "$BUNDLE/references/internal-skills/story-review/references/short-full-story-editor-contract.md"
    if [ ! -d "$REPO/src/private-internal-skills" ]; then
        test ! -d "$BUNDLE/references/private-internal-skills"
    fi
    grep -q 'memory_read_receipt' "$BUNDLE/references/internal-skills/story-short-write/SKILL.md"
    grep -q 'memory_read_receipt' "$BUNDLE/references/internal-skills/story-workflow/SKILL.md"
}
