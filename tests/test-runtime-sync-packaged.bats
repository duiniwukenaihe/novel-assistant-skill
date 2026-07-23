#!/usr/bin/env bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PACKAGED_SKILL="$REPO/skills/novel-assistant"
    PACKAGED_SCRIPT="$PACKAGED_SKILL/scripts/novel-assistant-sync-runtime.js"
    PACKAGED_NATIVE="$PACKAGED_SKILL/scripts/native/novel-assistant-safe-fs-posix.c"
    TMP_DIR="$(mktemp -d)"
    TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
    PROJECT="$TMP_DIR/book"
    mkdir -p "$PROJECT/正文" "$PROJECT/.claude/hooks"
    printf '正文原文\n' > "$PROJECT/正文/a.md"
    printf 'custom packaged hook\n' > "$PROJECT/.claude/hooks/custom-user-hook.sh"
    cp "$PROJECT/.claude/hooks/custom-user-hook.sh" "$TMP_DIR/custom-hook.before"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "packaged runtime sync preserves custom hooks and ships the native helper source" {
    node "$PACKAGED_SCRIPT" --project-root "$PROJECT" --skill-dir "$PACKAGED_SKILL" --json > "$TMP_DIR/out.json"

    node -e '
      const fs = require("fs");
      const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (result.status !== "synced") process.exit(1);
      if (!result.runtime_safe_fs || result.runtime_safe_fs.status !== "ready") process.exit(2);
    ' "$TMP_DIR/out.json"
    cmp "$TMP_DIR/custom-hook.before" "$PROJECT/.claude/hooks/custom-user-hook.sh"
    test -f "$PACKAGED_NATIVE"
    grep -q 'root-preflight' "$PACKAGED_NATIVE"
    grep -q 'root-preflight' "$PACKAGED_SKILL/scripts/lib/runtime-safe-fs.js"
}
