#!/bin/bash
# prose-quality-gate.sh — PostToolUse(Write|Edit|MultiEdit) 正文质量门禁
# 从 Claude hook JSON 中解析目标文件；只检查正文文件。
set -euo pipefail

extract_target_path() {
  local raw="${CLAUDE_TOOL_INPUT:-}"
  if [ -z "$raw" ] && [ ! -t 0 ]; then
    raw="$(cat)"
  fi
  [ -n "$raw" ] || return 1

  local PYBIN=""
  for c in python3 python py; do
    if "$c" -c "" >/dev/null 2>&1; then PYBIN="$c"; break; fi
  done
  [ -n "$PYBIN" ] || return 1

  HOOK_INPUT="$raw" "$PYBIN" - <<'PY'
import json, os, sys

raw = os.environ.get("HOOK_INPUT", "")
try:
    obj = json.loads(raw)
except Exception:
    sys.exit(1)

def dig(value):
    if isinstance(value, dict):
        for key in ("file_path", "path", "filePath"):
            found = value.get(key)
            if isinstance(found, str) and found:
                return found
        for key in ("tool_input", "input", "parameters", "args"):
            found = dig(value.get(key))
            if found:
                return found
    return ""

path = dig(obj)
if not path:
    sys.exit(1)
sys.stdout.write(path)
PY
}

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  TARGET="$(extract_target_path 2>/dev/null || true)"
fi
[ -n "$TARGET" ] || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$TARGET" in
  /*) ABS="$TARGET" ;;
  *) ABS="$ROOT/$TARGET" ;;
esac

[ -f "$ABS" ] || exit 0

REL="${ABS#$ROOT/}"
BASE="$(basename "$ABS")"
case "$REL" in
  正文.md|*/正文.md|正文/第*章*.md|正文/第*卷/第*章*.md|*/正文/第*章*.md|*/正文/第*卷/第*章*.md) ;;
  *) exit 0 ;;
esac

case "$BASE" in
  正文.md|第*章*.md) ;;
  *) exit 0 ;;
esac

GATE="$ROOT/scripts/story-prose-gate.js"
if [ ! -f "$GATE" ]; then
  echo "[WARN] 写作协作环境不完整：正文质量门禁脚本缺失。运行 /novel-assistant 更新写作协作环境。" >&2
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "[WARN] 正文质量门禁需要 node，当前环境未找到。请手动运行 story-prose-gate.js 检查正文。" >&2
  exit 0
fi

OUT="$(node "$GATE" "$ABS" 2>&1)" || {
  printf '%s\n' "$OUT" >&2
  echo "⛔ 正文质量门禁未通过：检测到逐字破折号化、破折号密度失控、非标准破折号/省略号残留、正文工程词泄露或旧稿污染。" >&2
  echo "   处理方式：不要局部替换几个词；按当前章细纲和 Chapter Contract 回炉重写问题段，重跑 prose gate 通过后再继续。少量有功能的中文破折号可保留，但不能逐字化或反复堆砌；“本章/细纲/任务描述/该到下一章了”等工程词必须改成角色能感知的事件、动作或物件。" >&2
  exit 2
}

exit 0
