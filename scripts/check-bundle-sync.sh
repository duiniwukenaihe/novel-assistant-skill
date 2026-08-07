#!/bin/bash
# check-bundle-sync.sh — 校验源布局与打包 bundle 是否一致
#
# novel-assistant 的安装包 skills/novel-assistant/ 是构建产物，必须由源
# (scripts/ + src/internal-skills/ + config/) 生成。任何"只改源不重建"或
# "直接改 bundle"都会导致安装的 skill 与源不一致。本守卫把这种漂移变成
# 构建失败，而不是靠人肉纪律。
#
# 检查四项：
#   1. mirror-sync audit：scripts/ 与 skills/novel-assistant/scripts/ 按 manifest 镜像一致
#   2. src/internal-skills/ 与 skills/novel-assistant/references/internal-skills/ 递归一致
#   3. src/private-internal-skills/ 与 skills/novel-assistant/references/private-internal-skills/ 递归一致
#   4. config/novel-assistant-bundle-files.json 与 skills/novel-assistant/config/ 一致
# 兼容 bash 3+（macOS）
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "Error: not in a git repository"
  exit 1
fi

ROOT_SCRIPTS_DIR="$REPO_ROOT/scripts"
BUNDLE_DIR="$REPO_ROOT/skills/novel-assistant"
MANIFEST="$REPO_ROOT/config/novel-assistant-bundle-files.json"
SOURCE_SKILLS_DIR="$REPO_ROOT/src/internal-skills"
PRIVATE_SOURCE_SKILLS_DIR="$REPO_ROOT/src/private-internal-skills"

failures=0

echo "Bundle Sync Check"
echo "================="

if [ ! -d "$BUNDLE_DIR" ]; then
  echo "Error: bundle not found at $BUNDLE_DIR"
  exit 1
fi

# 1. mirror-sync audit
if [ -f "$ROOT_SCRIPTS_DIR/lib/mirror-sync.js" ] && [ -f "$MANIFEST" ]; then
  echo "[1/4] mirror-sync audit (scripts -> bundle scripts)"
  set +e
  AUDIT_OUTPUT="$(node "$ROOT_SCRIPTS_DIR/lib/mirror-sync.js" audit \
    "$ROOT_SCRIPTS_DIR" "$BUNDLE_DIR/scripts" "$MANIFEST" 2>&1)"
  AUDIT_STATUS=$?
  set -e
  if [ "$AUDIT_STATUS" -ne 0 ]; then
    echo "MISMATCH: mirror-sync audit failed (drift between scripts/ and skills/novel-assistant/scripts/)"
    echo "$AUDIT_OUTPUT"
    failures=$((failures + 1))
  else
    echo "  OK"
  fi
else
  echo "  skipped (missing mirror-sync.js or manifest)"
fi

# 2. src/internal-skills vs bundle references/internal-skills
if [ -d "$SOURCE_SKILLS_DIR" ] && [ -d "$BUNDLE_DIR/references/internal-skills" ]; then
  echo "[2/4] internal-skills diff (src -> bundle references)"
  set +e
  DIFF_OUTPUT="$(diff -rq "$SOURCE_SKILLS_DIR" "$BUNDLE_DIR/references/internal-skills" 2>&1)"
  DIFF_STATUS=$?
  set -e
  # Keep only real differences; ignore .DS_Store noise.
  DIFF_OUTPUT="$(printf '%s\n' "$DIFF_OUTPUT" | grep -v '\.DS_Store' || true)"
  if [ "$DIFF_STATUS" -ne 0 ] && [ -n "$DIFF_OUTPUT" ]; then
    echo "MISMATCH: src/internal-skills/ differs from skills/novel-assistant/references/internal-skills/"
    echo "$DIFF_OUTPUT"
    failures=$((failures + 1))
  else
    echo "  OK"
  fi
else
  echo "  skipped (missing internal-skills dirs)"
fi

# 3. src/private-internal-skills vs bundle references/private-internal-skills
if [ -d "$PRIVATE_SOURCE_SKILLS_DIR" ] && [ -d "$BUNDLE_DIR/references/private-internal-skills" ]; then
  echo "[3/4] private-internal-skills diff (src -> bundle references)"
  set +e
  PRIV_DIFF_OUTPUT="$(diff -rq "$PRIVATE_SOURCE_SKILLS_DIR" "$BUNDLE_DIR/references/private-internal-skills" 2>&1)"
  PRIV_DIFF_STATUS=$?
  set -e
  PRIV_DIFF_OUTPUT="$(printf '%s\n' "$PRIV_DIFF_OUTPUT" | grep -v '\.DS_Store' || true)"
  if [ "$PRIV_DIFF_STATUS" -ne 0 ] && [ -n "$PRIV_DIFF_OUTPUT" ]; then
    echo "MISMATCH: src/private-internal-skills/ differs from skills/novel-assistant/references/private-internal-skills/"
    echo "$PRIV_DIFF_OUTPUT"
    failures=$((failures + 1))
  else
    echo "  OK"
  fi
elif [ -d "$PRIVATE_SOURCE_SKILLS_DIR" ] || [ -d "$BUNDLE_DIR/references/private-internal-skills" ]; then
  echo "[3/4] private-internal-skills diff"
  echo "MISMATCH: one side exists but not the other"
  echo "  src: $PRIVATE_SOURCE_SKILLS_DIR"
  echo "  bundle: $BUNDLE_DIR/references/private-internal-skills"
  failures=$((failures + 1))
else
  echo "[3/4] private-internal-skills diff skipped (neither side exists)"
fi

# 4. config manifest vs bundle config
if [ -f "$MANIFEST" ] && [ -d "$BUNDLE_DIR/config" ]; then
  echo "[4/4] bundle config manifest"
  set +e
  if ! diff -q "$MANIFEST" "$BUNDLE_DIR/config/novel-assistant-bundle-files.json" >/dev/null 2>&1; then
    set -e
    echo "MISMATCH: config/novel-assistant-bundle-files.json differs from bundle config copy"
    failures=$((failures + 1))
  else
    set -e
    echo "  OK"
  fi
else
  echo "  skipped (missing config files)"
fi

echo ""
echo "=============================="
if [ "$failures" -gt 0 ]; then
  echo "Bundle sync check FAILED ($failures issue(s))."
  echo "Run: bash scripts/build-oh-story-bundle.sh   # rebuild skills/novel-assistant/ from source"
  exit 1
fi
echo "Bundle is in sync with source."
