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

    node - "$TMP_DIR/out.json" "$PROJECT" <<'NODE'
const fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const root=process.argv[3];
if(out.writePolicy!=='migration_required') throw new Error(JSON.stringify(out));
if(fs.existsSync(path.join(root,'追踪/story-system/write-policy.json'))) throw new Error('existing story project must not be silently pinned to legacy');
if(!String(out.writePolicyMigrationCommand||'').includes('book-write-policy-migrate.js preview')) throw new Error(JSON.stringify(out));
NODE
}

@test "runtime sync initializes an empty new project with strict canonical writes" {
    local empty="$TMP_DIR/empty-book"
    mkdir -p "$empty"

    node "$SCRIPT" --project-root "$empty" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/empty.json"

    node - "$TMP_DIR/empty.json" "$empty" <<'NODE'
const fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const policy=JSON.parse(fs.readFileSync(path.join(process.argv[3],'追踪/story-system/write-policy.json'),'utf8'));
if(out.writePolicy!=='strict'||policy.mode!=='strict') throw new Error(JSON.stringify({out,policy}));
NODE
}

@test "runtime sync repairs a managed short project that predates write-policy initialization" {
    local short_book="$TMP_DIR/managed-short"
    mkdir -p "$short_book/追踪/story-system/short"
    printf '%s\n' '{"workflow_id":"wf-short","selected_material":{"card_id":"card-1"}}' > "$short_book/追踪/story-system/short/material-snapshot.json"
    printf '%s\n' '{"project_id":"short-1","active_write_workflow_id":"wf-short"}' > "$short_book/追踪/story-system/short/project-state.json"
    printf '%s\n' '# 旧版已生成设定' > "$short_book/设定.md"
    printf '%s\n' 'novel_assistant_bundle_id: bundle-old' > "$short_book/.story-deployed"

    node "$SCRIPT" --project-root "$short_book" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/managed-short.json"

    node - "$TMP_DIR/managed-short.json" "$short_book" <<'NODE'
const fs=require('fs'),path=require('path');
const out=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const policy=JSON.parse(fs.readFileSync(path.join(process.argv[3],'追踪/story-system/write-policy.json'),'utf8'));
if(out.writePolicy!=='strict'||policy.mode!=='strict') throw new Error(JSON.stringify({out,policy}));
NODE
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

@test "runtime sync merges a Codex project route that survives plain continue and numeric replies" {
    printf '%s\n' '# 用户项目说明' '' '保留这段自定义内容。' > "$PROJECT/AGENTS.md"

    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/out.json"
    node "$SCRIPT" --project-root "$PROJECT" --skill-dir "$SKILL_DIR" --json > "$TMP_DIR/out-second.json"

    grep -q '^# 用户项目说明$' "$PROJECT/AGENTS.md"
    grep -q '^保留这段自定义内容。$' "$PROJECT/AGENTS.md"
    grep -q '<!-- novel-assistant:codex-route:start -->' "$PROJECT/AGENTS.md"
    grep -q '继续.*下一步.*纯数字' "$PROJECT/AGENTS.md"
    grep -q '每一轮都必须先调用.*novel-assistant' "$PROJECT/AGENTS.md"
    count="$(grep -c '<!-- novel-assistant:codex-route:start -->' "$PROJECT/AGENTS.md")"
    [ "$count" -eq 1 ]
    node -e '
      const fs = require("fs");
      const out = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (!out.copied.some(item => item.type === "codex-route" && item.target === "AGENTS.md")) process.exit(1);
    ' "$TMP_DIR/out-second.json"
}

@test "runtime sync blocks malformed or duplicate Codex route markers without touching user content" {
    local cases=(orphan-start orphan-end reverse duplicate)
    for case_name in "${cases[@]}"; do
        local book="$TMP_DIR/$case_name"
        mkdir -p "$book/正文" "$book/追踪"
        printf '%s\n' '正文' > "$book/正文/a.md"
        case "$case_name" in
            orphan-start)
                printf '%s\n' '# 用户规则' '<!-- novel-assistant:codex-route:start -->' '必须保留。' > "$book/AGENTS.md"
                ;;
            orphan-end)
                printf '%s\n' '# 用户规则' '<!-- novel-assistant:codex-route:end -->' '必须保留。' > "$book/AGENTS.md"
                ;;
            reverse)
                printf '%s\n' '# 用户规则' '<!-- novel-assistant:codex-route:end -->' '必须保留。' '<!-- novel-assistant:codex-route:start -->' > "$book/AGENTS.md"
                ;;
            duplicate)
                printf '%s\n' '# 用户规则' '<!-- novel-assistant:codex-route:start -->' '旧块一' '<!-- novel-assistant:codex-route:end -->' '必须保留。' '<!-- novel-assistant:codex-route:start -->' '旧块二' '<!-- novel-assistant:codex-route:end -->' > "$book/AGENTS.md"
                ;;
        esac
        cp "$book/AGENTS.md" "$TMP_DIR/$case_name.before"

        run node "$SCRIPT" --project-root "$book" --skill-dir "$SKILL_DIR" --json

        [ "$status" -ne 0 ]
        node -e '
          const result = JSON.parse(process.argv[1]);
          if (result.status !== "blocked_invalid_codex_route_markers") process.exit(1);
          if (!result.conflicts.some(item => item.path === "AGENTS.md" && item.reason === "invalid_novel_assistant_codex_route_markers")) process.exit(2);
        ' "$output"
        cmp "$TMP_DIR/$case_name.before" "$book/AGENTS.md"
        test ! -e "$book/.story-deployed"
    done

    run node "$SCRIPT" --project-root "$TMP_DIR/orphan-start" --skill-dir "$SKILL_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *'runtime blocked'* ]]
    [[ "$output" != *'runtime synced'* ]]
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
      if (result.confirmation_command !== "node scripts/novel-assistant-sync-runtime.js --project-root . --json --confirm-conflicts") process.exit(3);
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
