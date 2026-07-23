#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/novel-assistant-sync-runtime.js"
    SKILL_DIR="$REPO/skills/novel-assistant"
    TMP_DIR="$(mktemp -d)"
    TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/正文" "$PROJECT/大纲" "$PROJECT/设定" "$PROJECT/追踪" "$PROJECT/scripts"
    printf '正文原文\n' > "$PROJECT/正文/a.md"
    printf '大纲原文\n' > "$PROJECT/大纲/a.md"
    printf '设定原文\n' > "$PROJECT/设定/a.md"
    printf '追踪原文\n' > "$PROJECT/追踪/a.md"
    printf 'user custom\n' > "$PROJECT/scripts/custom-user.js"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "runtime sync uses one deterministic command and preserves creative assets" {
    cp "$PROJECT/正文/a.md" "$TMP_DIR/prose.before"
    cp "$PROJECT/大纲/a.md" "$TMP_DIR/outline.before"
    cp "$PROJECT/设定/a.md" "$TMP_DIR/setting.before"
    cp "$PROJECT/追踪/a.md" "$TMP_DIR/tracking.before"

    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/out.json"

    node -e "
      const fs = require('fs');
      const out = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      if (out.status !== 'synced') process.exit(1);
      if (out.root_resolution.status !== 'resolved' || out.root_resolution.root_kind !== 'book') process.exit(4);
      if (!out.runtime_safe_fs || out.runtime_safe_fs.status !== 'ready') process.exit(5);
      if (!out.copied.some(x => x.type === 'scripts')) process.exit(2);
      if (!out.protectedContent.includes('正文')) process.exit(3);
    " "$TMP_DIR/out.json"

    test -d "$PROJECT/.claude/hooks"
    test -d "$PROJECT/.claude/rules"
    test -d "$PROJECT/.claude/agents"
    test -d "$PROJECT/.claude/agent-references/novel-assistant"
    test -x "$PROJECT/scripts/novel-assistant-sync-runtime.js"
    test -x "$PROJECT/scripts/book-write-policy-migrate.js"
    test -x "$PROJECT/scripts/output-pollution-check.js"
    test -x "$PROJECT/.claude/hooks/ai-trace-detector.sh"
    test -f "$PROJECT/.claude/hooks/ai-trace-patterns.json"
    test -f "$PROJECT/scripts/custom-user.js"
    test -f "$PROJECT/.claude/.agents-pending-restart"
    grep -q "resolver_strategy: global-skill-with-project-agent-references" "$PROJECT/.story-deployed"
    grep -q "references_dir: .claude/agent-references/novel-assistant" "$PROJECT/.story-deployed"
    grep -q "migration_status: not_requested" "$PROJECT/.story-deployed"

    cmp "$TMP_DIR/prose.before" "$PROJECT/正文/a.md"
    cmp "$TMP_DIR/outline.before" "$PROJECT/大纲/a.md"
    cmp "$TMP_DIR/setting.before" "$PROJECT/设定/a.md"
    cmp "$TMP_DIR/tracking.before" "$PROJECT/追踪/a.md"
}

@test "runtime sync refreshes an existing deployment sentinel to the installed bundle" {
    printf '%s\n' 'novel_assistant_bundle_id: bundle-old' 'novel_assistant_source_commit: old' > "$PROJECT/.story-deployed"

    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/out.json"

    bundle_id="$(node -p 'require(process.argv[1]).bundleId' "$SKILL_DIR/novel-assistant-manifest.json")"
    source_commit="$(node -p 'require(process.argv[1]).sourceCommit' "$SKILL_DIR/novel-assistant-manifest.json")"
    grep -q "novel_assistant_bundle_id: $bundle_id" "$PROJECT/.story-deployed"
    grep -q "novel_assistant_source_commit: $source_commit" "$PROJECT/.story-deployed"
    ! grep -q 'bundle-old' "$PROJECT/.story-deployed"
}

@test "deployed project can refresh with one placeholder-free local command" {
    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json >/dev/null

    cd "$PROJECT"
    run env NOVEL_ASSISTANT_SKILL_DIR="$SKILL_DIR" node scripts/novel-assistant-sync-runtime.js --project-root . --dry-run --json
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$TMP_DIR/local-refresh.json"
    node - "$TMP_DIR/local-refresh.json" "$PROJECT" "$SKILL_DIR" <<'NODE'
const fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
if(out.status!=='synced'||out.dryRun!==true) throw new Error(JSON.stringify(out));
if(path.resolve(out.projectRoot)!==path.resolve(process.argv[3])) throw new Error(JSON.stringify(out));
if(path.resolve(out.skillDir)!==path.resolve(process.argv[4])) throw new Error(JSON.stringify(out));
NODE
}

@test "runtime sync fails closed before mutation when safe filesystem capability is unavailable" {
    run env NOVEL_ASSISTANT_SAFE_FS_DISABLE=1 node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json

    [ "$status" -ne 0 ]
    node -e '
      const result = JSON.parse(process.argv[1]);
      if (result.status !== "blocked_runtime_safe_fs_unavailable") process.exit(1);
      if (!result.runtime_safe_fs || result.runtime_safe_fs.status !== "blocked_runtime_safe_fs_unavailable") process.exit(2);
    ' "$output"
    test ! -e "$PROJECT/.story-runtime-managed.json"
    test ! -e "$PROJECT/.story-deployed"
    test ! -e "$PROJECT/.claude/.agents-pending-restart"
}

@test "runtime sync preserves unrelated custom hook rule and agent files" {
    mkdir -p "$PROJECT/.claude/hooks" "$PROJECT/.claude/rules" "$PROJECT/.claude/agents"
    printf 'custom hook\n' > "$PROJECT/.claude/hooks/custom-user-hook.sh"
    printf 'custom rule\n' > "$PROJECT/.claude/rules/custom-user-rule.md"
    printf 'custom agent\n' > "$PROJECT/.claude/agents/custom-user-agent.md"
    cp "$PROJECT/.claude/hooks/custom-user-hook.sh" "$TMP_DIR/custom-hook.before"
    cp "$PROJECT/.claude/rules/custom-user-rule.md" "$TMP_DIR/custom-rule.before"
    cp "$PROJECT/.claude/agents/custom-user-agent.md" "$TMP_DIR/custom-agent.before"

    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/out.json"

    cmp "$TMP_DIR/custom-hook.before" "$PROJECT/.claude/hooks/custom-user-hook.sh"
    cmp "$TMP_DIR/custom-rule.before" "$PROJECT/.claude/rules/custom-user-rule.md"
    cmp "$TMP_DIR/custom-agent.before" "$PROJECT/.claude/agents/custom-user-agent.md"
}

@test "runtime sync rejects parent replacement during settings metadata write" {
    local outside="$TMP_DIR/outside-settings"
    mkdir -p "$PROJECT/.claude" "$outside"
    printf 'outside settings remain\n' > "$outside/settings.local.json"

    run node - "$SCRIPT" "$PROJECT" "$SKILL_DIR" "$outside" <<'NODE'
const childProcess = require('child_process');
const fs = require('fs');
const path = require('path');
const script = process.argv[2];
const projectRoot = process.argv[3];
const skillDir = process.argv[4];
const outside = process.argv[5];
const metadataParent = path.join(projectRoot, '.claude');
const displacedParent = path.join(projectRoot, '.claude-before-metadata-race');
const outsideSettings = path.join(outside, 'settings.local.json');
let attacked = false;

const originalSpawnSync = childProcess.spawnSync;
childProcess.spawnSync = function(command, args, options) {
  if (!attacked && Array.isArray(args) && args[0] === 'external-copy' && args[2] === '.claude/settings.local.json') {
    attacked = true;
    fs.renameSync(metadataParent, displacedParent);
    fs.symlinkSync(outside, metadataParent);
  }
  return originalSpawnSync.call(this, command, args, options);
};

process.argv = [process.execPath, script, '--project-root', projectRoot, '--skill-dir', skillDir, '--json'];
let rejected = false;
try {
  require(script);
} catch (error) {
  rejected = error.code === 'runtime_safe_fs_operation_failed';
}
if (!attacked) process.exit(1);
if (!rejected) process.exit(2);
if (fs.readFileSync(outsideSettings, 'utf8') !== 'outside settings remain\n') process.exit(3);
NODE

    [ "$status" -eq 0 ]
}

@test "runtime sync previews same-name unmanaged conflicts without writing" {
    mkdir -p "$PROJECT/.claude/hooks"
    printf 'user-owned hook\n' > "$PROJECT/.claude/hooks/session-start.sh"
    cp "$PROJECT/.claude/hooks/session-start.sh" "$TMP_DIR/session-start.before"

    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --dry-run --json > "$TMP_DIR/conflict.json"

    node -e '
      const fs = require("fs");
      const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (result.status !== "confirmation_required") process.exit(1);
      if (!result.conflicts.some(conflict => conflict.path === ".claude/hooks/session-start.sh")) process.exit(2);
    ' "$TMP_DIR/conflict.json"
    cmp "$TMP_DIR/session-start.before" "$PROJECT/.claude/hooks/session-start.sh"
    test ! -e "$PROJECT/.story-runtime-managed.json"
}

@test "runtime sync rejects a symlinked project root before mutating the target" {
    mkdir -p "$TMP_DIR/outside-book"
    ln -s "$TMP_DIR/outside-book" "$TMP_DIR/escaped-book"

    run node "$SCRIPT" --project-root "$TMP_DIR/escaped-book" --skill-dir "$SKILL_DIR" --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"root_kind":"symlink_escape"'* ]]
    test ! -e "$TMP_DIR/outside-book/.story-deployed"
}

@test "runtime sync rejects a project root beneath a symlinked ancestor before mutating the target" {
    mkdir -p "$TMP_DIR/outside-host/book"
    ln -s "$TMP_DIR/outside-host" "$TMP_DIR/host-escape"

    run node "$SCRIPT" --project-root "$TMP_DIR/host-escape/book" --skill-dir "$SKILL_DIR" --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"root_kind":"symlink_escape"'* ]]
    test ! -e "$TMP_DIR/outside-host/book/.story-deployed"
}

@test "runtime sync dry-run reports plan without writing project files" {
    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --dry-run --json > "$TMP_DIR/out.json"

    node -e "
      const fs = require('fs');
      const out = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      if (out.status !== 'synced' || out.dryRun !== true) process.exit(1);
      if (!out.copied.some(x => x.type === 'hooks')) process.exit(2);
    " "$TMP_DIR/out.json"

    test ! -e "$PROJECT/.story-deployed"
    test ! -e "$PROJECT/.claude/.agents-pending-restart"
    test ! -e "$PROJECT/scripts/novel-assistant-sync-runtime.js"
}

@test "runtime sync deploys the workflow tool budget PreToolUse guard exactly once" {
    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/out.json"

    test -f "$PROJECT/.claude/hooks/workflow-tool-budget-guard.js"
    test -f "$PROJECT/scripts/lib/interactive-tool-budget.js"
    test -f "$PROJECT/scripts/interactive-tool-budget.js"
    # settings.local.json 中 workflow-tool-budget-guard.js 命令唯一出现(去重合并)
    count="$(grep -o 'workflow-tool-budget-guard.js' "$PROJECT/.claude/settings.local.json" | wc -l | tr -d ' ')"
    [ "$count" -eq 1 ]
    # 该 guard 的 PreToolUse group matcher 覆盖写作相关工具
    grep -q '"matcher": "Bash|Read|Write|Edit|MultiEdit"' "$PROJECT/.claude/settings.local.json"
}

@test "runtime sync re-running does not duplicate the workflow tool budget guard" {
    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > /dev/null
    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > /dev/null

    count="$(grep -o 'workflow-tool-budget-guard.js' "$PROJECT/.claude/settings.local.json" | wc -l | tr -d ' ')"
    [ "$count" -eq 1 ]
}
