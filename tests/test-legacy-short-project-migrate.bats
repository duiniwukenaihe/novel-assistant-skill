#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/legacy-short-project-migrate.js"
    V3="$REPO/scripts/workflow-v3.js"
    TMP_DIR="$(mktemp -d)"
    BOOK="$TMP_DIR/book"
    SHORT_STATE="$BOOK/追踪/story-system/short/project-state.json"
    mkdir -p "$BOOK/正文" "$BOOK/大纲" "$BOOK/追踪/private-short-extension/briefs"
    printf '# 素材卡\n' > "$BOOK/素材卡.md"
    printf '# 短篇设定\n' > "$BOOK/设定.md"
    printf '# 小节大纲\n## 第1节：开场\n## 第2节：收束\n' > "$BOOK/大纲/小节大纲.md"
    printf '# 完整短篇\n旧版正文保持不变。\n' > "$BOOK/正文/正文.md"
    printf '# 第1节\n旧版分节保持不变。\n' > "$BOOK/正文/第001节.md"
    printf '# 第1节 Brief\n' > "$BOOK/追踪/private-short-extension/briefs/写作Brief_第001节.md"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "legacy short migration preview is read-only and reports canonical mappings" {
    run node "$SCRIPT" --project-root "$BOOK" --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/preview.json"

    node - "$TMP_DIR/preview.json" <<'NODE'
const out = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'legacy_short_migration_preview' || out.requires_confirmation !== true) throw new Error(JSON.stringify(out));
if (out.asset_mapping.outline.source !== '大纲/小节大纲.md' || out.asset_mapping.outline.target !== '小节大纲.md') throw new Error(JSON.stringify(out.asset_mapping));
if (out.asset_mapping.prose.source !== '正文/正文.md' || out.asset_mapping.prose.target !== '正文.md') throw new Error(JSON.stringify(out.asset_mapping));
NODE
    test ! -e "$BOOK/正文.md"
    test ! -e "$BOOK/小节大纲.md"
    test ! -e "$BOOK/追踪/workflow/current-task.json"
}

@test "confirmed legacy short migration preserves originals and creates current short authority" {
    cp "$BOOK/正文/正文.md" "$TMP_DIR/original-prose.md"
    cp "$BOOK/大纲/小节大纲.md" "$TMP_DIR/original-outline.md"

    run node "$SCRIPT" --project-root "$BOOK" --write --confirm --json
    printf '%s\n' "$output" > "$TMP_DIR/result.json"
    [ "$status" -eq 0 ]

    node - "$TMP_DIR/result.json" "$BOOK" <<'NODE'
const fs = require('fs'); const path = require('path');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); const root = process.argv[3];
if (out.status !== 'legacy_short_migration_applied' || out.workflow_type !== 'short_write') throw new Error(JSON.stringify(out));
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
if (task.workflow_type !== 'short_write' || task.migration.source_kind !== 'legacy_short_project') throw new Error(JSON.stringify(task));
const state = JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/short/project-state.json'), 'utf8'));
if (state.active_write_workflow_id !== task.workflow_id || state.planned_sections !== 2) throw new Error(JSON.stringify(state));
if (!fs.existsSync(path.join(root, out.migration_record))) throw new Error(JSON.stringify(out));
NODE
    cmp "$BOOK/正文/正文.md" "$TMP_DIR/original-prose.md"
    cmp "$BOOK/大纲/小节大纲.md" "$TMP_DIR/original-outline.md"
    cmp "$BOOK/正文.md" "$BOOK/正文/正文.md"
    cmp "$BOOK/小节大纲.md" "$BOOK/大纲/小节大纲.md"
}

@test "confirmed migration accepts legacy section headings separated by a vertical bar" {
    printf '# 小节大纲\n## 第 1 节｜开场\n## 第 2 节｜收束\n' > "$BOOK/大纲/小节大纲.md"

    node "$SCRIPT" --project-root "$BOOK" --write --confirm --json > "$TMP_DIR/result.json"

    node - "$TMP_DIR/result.json" "$BOOK" <<'NODE'
const fs = require('fs'); const path = require('path');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); const root = process.argv[3];
if (out.status !== 'legacy_short_migration_applied') throw new Error(JSON.stringify(out));
const state = JSON.parse(fs.readFileSync(path.join(root, '追踪/story-system/short/project-state.json'), 'utf8'));
if (state.planned_sections !== 2) throw new Error(JSON.stringify(state));
NODE
}

@test "confirmed migration accepts legacy headings that start with section number" {
    printf '# 小节大纲\n## 节 1｜开场\n## 节 2｜收束\n' > "$BOOK/大纲/小节大纲.md"

    node "$SCRIPT" --project-root "$BOOK" --write --confirm --json > "$TMP_DIR/result.json"

    node - "$SHORT_STATE" <<'NODE'
const state = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (state.planned_sections !== 2) throw new Error(JSON.stringify(state));
NODE
}

@test "confirmed migration accepts numbered headings inside a section blueprint" {
    printf '# 小节大纲\n## 逐节蓝图\n### 0. 开篇导语\n### 1. 开场\n### 2. 收束\n' > "$BOOK/大纲/小节大纲.md"

    node "$SCRIPT" --project-root "$BOOK" --write --confirm --json > "$TMP_DIR/result.json"

    node - "$SHORT_STATE" <<'NODE'
const state = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (state.planned_sections !== 2) throw new Error(JSON.stringify(state));
NODE
}

@test "confirmed migration preserves a legacy outline title as the project title" {
    printf '# 小节大纲.md｜旧项目标题\n## 第 1 节：开场\n## 第 2 节：收束\n' > "$BOOK/大纲/小节大纲.md"

    node "$SCRIPT" --project-root "$BOOK" --write --confirm --json > "$TMP_DIR/result.json"

    node - "$SHORT_STATE" <<'NODE'
const state = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (state.project_title !== '旧项目标题') throw new Error(JSON.stringify(state));
NODE
}

@test "legacy short migration refuses writes without explicit confirmation" {
    run node "$SCRIPT" --project-root "$BOOK" --write --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_legacy_short_migration_confirmation_required'* ]]
    test ! -e "$BOOK/正文.md"
    test ! -e "$BOOK/小节大纲.md"
    test ! -e "$BOOK/追踪/workflow/current-task.json"
}

@test "legacy short migration blocks conflicting canonical assets without overwriting" {
    printf '# 另一份根目录正文\n' > "$BOOK/正文.md"

    run node "$SCRIPT" --project-root "$BOOK" --write --confirm --json
    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_legacy_short_canonical_conflict'* ]]
    grep -q '另一份根目录正文' "$BOOK/正文.md"
    test ! -e "$BOOK/小节大纲.md"
    test ! -e "$BOOK/追踪/workflow/current-task.json"
}

@test "legacy migration rolls back copied assets and control state when V3 task creation fails" {
    mkdir -p "$BOOK/追踪/workflow"
    printf '%s\n' '{"workflow_type":"private_short_write","work_title":"旧任务","current_stage":"draft"}' \
      > "$BOOK/追踪/workflow/current-task.json"
    cp "$BOOK/追踪/workflow/current-task.json" "$TMP_DIR/legacy-before.json"

    run node - "$BOOK" "$REPO" <<'NODE'
const fs = require('fs');
const path = require('path');
const [root, repo] = process.argv.slice(2);
const engine = require(path.join(repo, 'scripts/lib/workflow-v3/engine'));
engine.createTaskWithInitialInteraction = () => { throw new Error('forced_task_create_failure'); };
const migration = require(path.join(repo, 'scripts/lib/workflow-v3/migrations/legacy-short-project'));
const out = migration.runLegacyShortProjectMigration(root, { write: true, confirm: true });
process.stdout.write(`${JSON.stringify(out)}\n`);
process.exitCode = out.exitCode;
NODE

    [ "$status" -eq 2 ]
    [[ "$output" == *'legacy_short_migration_failed'* ]]
    test ! -e "$BOOK/正文.md"
    test ! -e "$BOOK/小节大纲.md"
    test ! -e "$SHORT_STATE"
    cmp "$BOOK/追踪/workflow/current-task.json" "$TMP_DIR/legacy-before.json"
    [ "$(find "$BOOK/追踪/workflow/migrations" -type f 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
}

@test "confirmed legacy migration fails closed while another import owns the migration lock" {
    run node - "$BOOK" "$REPO" <<'NODE'
const path = require('path');
const [root, repo] = process.argv.slice(2);
const stateStore = require(path.join(repo, 'scripts/lib/workflow-state-store'));
const release = stateStore.acquireNamedProjectLock(root, {
  relativeDir: path.join('追踪', 'workflow'),
  lockName: '.legacy-short-migration.lock',
  owner: 'concurrency-test',
  ttlMs: 300000,
  errorCode: 'LEGACY_SHORT_MIGRATION_LOCKED',
  errorLabel: 'legacy short migration lock',
});
try {
  const migration = require(path.join(repo, 'scripts/lib/workflow-v3/migrations/legacy-short-project'));
  const out = migration.runLegacyShortProjectMigration(root, { write: true, confirm: true });
  process.stdout.write(`${JSON.stringify(out)}\n`);
  process.exitCode = out.exitCode;
} finally {
  release();
}
NODE

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_legacy_short_migration_locked'* ]]
    test ! -e "$BOOK/正文.md"
    test ! -e "$BOOK/小节大纲.md"
    test ! -e "$SHORT_STATE"
    test ! -e "$BOOK/追踪/workflow/current-task.json"
}

@test "invalid legacy outline fails before creating workflow or project state" {
    printf '# 小节大纲\n这份旧大纲没有可识别的小节标题。\n' > "$BOOK/大纲/小节大纲.md"

    run node "$SCRIPT" --project-root "$BOOK" --write --confirm --json

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_legacy_short_plan_unreadable'* ]]
    test ! -e "$BOOK/正文.md"
    test ! -e "$BOOK/小节大纲.md"
    test ! -e "$BOOK/追踪/workflow/current-task.json"
    test ! -e "$SHORT_STATE"
}

@test "managed short project is not offered legacy migration again" {
    mkdir -p "$BOOK/追踪/story-system/short"
    cat > "$SHORT_STATE" <<'JSON'
{"schema_version":"2.0.0","active_write_workflow_id":"wf-short-active","status":"writing"}
JSON

    run node "$SCRIPT" --project-root "$BOOK" --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'legacy_short_project_already_managed'* ]]
    [[ "$output" == *'"requires_confirmation": false'* ]]
    test ! -e "$BOOK/正文.md"
    test ! -e "$BOOK/小节大纲.md"
}

@test "unreadable legacy asset returns a structured block without a stack trace" {
    chmod 000 "$BOOK/素材卡.md"

    run node "$SCRIPT" --project-root "$BOOK" --json
    chmod 600 "$BOOK/素材卡.md"

    [ "$status" -eq 2 ]
    [[ "$output" == *'blocked_legacy_short_asset_unreadable'* ]]
    [[ "$output" != *'at Object.'* ]]
    test ! -e "$BOOK/追踪/workflow/current-task.json"
}

@test "legacy short migration preserves old task feedback quality and breakpoint semantics" {
    mkdir -p "$BOOK/追踪/workflow"
    cat > "$BOOK/追踪/workflow/current-task.json" <<'JSON'
{
  "workflow_type": "private_short_write",
  "work_title": "旧短篇标题",
  "current_stage": "hook_retention_revision",
  "status": "needs_hook_revision",
  "updated_at": "2026-07-06T19:20:49+08:00",
  "completed": ["draft_section_1", "quality_gate_section_1"],
  "user_feedback": {
    "summary": "断亲过快，需要补婚后生活与人物动机。",
    "impact": ["先修改设定.md", "再修改小节大纲.md"]
  },
  "quality_gate": {
    "passed": false,
    "hook_retention_failed": true,
    "total_cjk_chars": 10927
  },
  "next_candidates": [
    {"number": 1, "action_id": "rebuild_hook_setting_outline", "label": "做卖点重构"}
  ]
}
JSON
    cp "$BOOK/追踪/workflow/current-task.json" "$TMP_DIR/legacy-current-task.json"

    run node "$SCRIPT" --project-root "$BOOK" --write --confirm --json
    printf '%s\n' "$output" > "$TMP_DIR/result.json"
    [ "$status" -eq 0 ]

    node - "$TMP_DIR/result.json" "$BOOK" "$TMP_DIR/legacy-current-task.json" <<'NODE'
const fs = require('fs'); const path = require('path');
const [resultFile, root, legacyFile] = process.argv.slice(2);
const out = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
const pointer = JSON.parse(fs.readFileSync(path.join(root, '追踪/workflow/current-task.json'), 'utf8'));
const task = JSON.parse(fs.readFileSync(path.join(root, pointer.task_dir, 'task.json'), 'utf8'));
const snapshot = JSON.parse(fs.readFileSync(path.join(root, task.migration.legacy_task_snapshot), 'utf8'));
const legacy = JSON.parse(fs.readFileSync(legacyFile, 'utf8'));
if (JSON.stringify(snapshot) !== JSON.stringify(legacy)) throw new Error('legacy task snapshot changed');
if (task.legacy_resume.source_stage !== 'hook_retention_revision' || task.legacy_resume.source_status !== 'needs_hook_revision') throw new Error(JSON.stringify(task.legacy_resume));
if (task.legacy_resume.user_feedback.summary !== legacy.user_feedback.summary) throw new Error('feedback lost');
if (task.legacy_resume.quality_gate.hook_retention_failed !== true) throw new Error('quality result lost');
if (task.legacy_resume.recommended_action.label !== '做卖点重构') throw new Error('next action lost');
if (task.current_stage !== 'creative_entry') throw new Error('legacy import must enter the V3 author recovery boundary');
if (![task.engine_version, task.task_schema_version, task.workflow_contract_version].every(value => value === 3)) throw new Error('legacy import did not create a V3 task');
if (!task.pending_action || task.pending_action.status !== 'pending' || task.pending_action.options.length !== 3) throw new Error('legacy recovery choice was not persisted');
if (task.state_version !== 1 || task.pending_action.state_version !== 1) throw new Error('initial task and recovery choice were not committed atomically');
if (!task.pending_action.options.some(option => option.action_id === 'inspect_legacy_checkpoint')) throw new Error('legacy evidence inspection choice missing');
if (!out.legacy_task_state_preserved) throw new Error(JSON.stringify(out));
NODE

    node "$V3" show --project-root "$BOOK" --workflow-id "$(jq -r .workflow_id "$TMP_DIR/result.json")" --json > "$TMP_DIR/v3-show.json"
    grep -q '旧短篇已经安全导入 V3' "$TMP_DIR/v3-show.json"
    grep -q '查看旧断点、反馈与质量依据' "$TMP_DIR/v3-show.json"
}
