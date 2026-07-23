#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    MIGRATE="$REPO/scripts/task-family-migrate.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    mkdir -p "$BOOK"
}

teardown() {
    rm -rf "$TMP_DIR"
}

write_legacy_project() {
    node - "$BOOK" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
fs.writeFileSync(path.join(root, '.story-deployed'), 'source=worldwonderer/oh-story-claudecode\n');
const files = {
  '正文/第1卷/第001章.md': '第一章正文。\n',
  '大纲/第1卷/细纲_第001章.md': '第一章细纲。\n',
  '设定/世界观.md': '世界观设定。\n',
  '追踪/伏笔.md': '伏笔记录。\n',
};
for (const [relative, content] of Object.entries(files)) {
  const file = path.join(root, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}
const workflowId = 'wf-legacy-review';
const taskDir = `追踪/workflow/tasks/${workflowId}`;
const task = {
  schemaVersion: '0.9.0',
  workflow_id: workflowId,
  workflow_type: 'review_repair',
  task_dir: taskDir,
  status: 'running',
  scope: '第1卷',
  user_goal: '审阅第一卷',
  current_stage: 'evidence_scan',
  state_version: 3
};
fs.mkdirSync(path.join(root, taskDir), { recursive: true });
fs.writeFileSync(path.join(root, '追踪/workflow/current-task.json'), JSON.stringify(task, null, 2) + '\n');
fs.writeFileSync(path.join(root, taskDir, 'task.json'), JSON.stringify(task, null, 2) + '\n');
NODE
}

creative_hashes() {
    find "$BOOK" \( -path "$BOOK/正文/*" -o -path "$BOOK/大纲/*" -o -path "$BOOK/设定/*" -o -path "$BOOK/追踪/伏笔.md" \) -type f -exec shasum -a 256 {} \; | sort
}

@test "authority migration writes metadata only and converts current task to focus pointer" {
    write_legacy_project
    before="$(creative_hashes)"

    node "$MIGRATE" --project-root "$BOOK" --source oh-story --json > "$TMP_DIR/preview.json"
    node - "$TMP_DIR/preview.json" <<'NODE'
const fs = require('fs');
const preview = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (preview.status !== 'task_family_migration_preview') throw new Error(JSON.stringify(preview));
if (preview.metadata_only !== true) throw new Error('preview must declare metadata_only');
if (preview.pending_task_count !== 1) throw new Error(JSON.stringify(preview));
if (!Array.isArray(preview.authority_metadata_changes) || preview.authority_metadata_changes.length !== 1) throw new Error(JSON.stringify(preview));
if (preview.creative_assets_assurance.indexOf('不会修改正文') < 0) throw new Error(preview.creative_assets_assurance);
NODE

    node "$MIGRATE" --project-root "$BOOK" --source oh-story --write --confirm --json > "$TMP_DIR/apply.json"
    [ "$before" = "$(creative_hashes)" ]

    node - "$BOOK" "$TMP_DIR/apply.json" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const applied = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (applied.status !== 'task_family_migration_applied' || applied.metadata_only !== true || applied.creative_assets_unchanged !== true) throw new Error(JSON.stringify(applied));
const current = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
if (current.user_goal || current.workflow_type || current.current_stage) throw new Error(`current-task must be pointer-only: ${JSON.stringify(current)}`);
if (current.workflow_id !== 'wf-legacy-review' || current.task_dir !== '追踪/workflow/tasks/wf-legacy-review') throw new Error(JSON.stringify(current));
const task = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/tasks/wf-legacy-review/task.json'), 'utf8'));
if (!task.task_family_id || task.branch_id !== task.workflow_id) throw new Error(JSON.stringify(task));
if (!task.authority_metadata || task.authority_metadata.task_source !== 'task_snapshot' || task.authority_metadata.focus_role !== 'ui_pointer') throw new Error(JSON.stringify(task.authority_metadata));
if (task.authority_metadata.migration_source !== 'oh-story') throw new Error(JSON.stringify(task.authority_metadata));
NODE
}
