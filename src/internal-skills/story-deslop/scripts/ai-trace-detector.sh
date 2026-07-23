#!/usr/bin/env bash
# ai-trace-detector.sh — 检测正文中的 Agent 推理痕迹
# 用法: ai-trace-detector.sh <markdown-or-txt-file>
# Hook 用法: 从 CLAUDE_TOOL_INPUT 或 stdin JSON 自动提取 file_path/path/filePath
# 退出: 0 干净；1 命中 P0 痕迹（附 stderr 报告）

set -euo pipefail

extract_hook_path() {
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

FROM_HOOK=0
FILE="${1:-}"
if [ -z "$FILE" ]; then
    FILE="$(extract_hook_path 2>/dev/null || true)"
    [ -n "$FILE" ] && FROM_HOOK=1
fi

if [ -n "$FILE" ]; then
    case "$FILE" in
        /*) ;;
        *) FILE="${CLAUDE_PROJECT_DIR:-$PWD}/$FILE" ;;
    esac
fi

if [ -z "$FILE" ]; then
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        echo "[WARN] AI 痕迹检测跳过：hook 未提供可解析文件路径。" >&2
        exit 0
    fi
    echo "usage: $0 <file>" >&2
    exit 2
fi

if [ ! -f "$FILE" ]; then
    if [ "$FROM_HOOK" -eq 1 ]; then
        exit 0
    fi
    echo "usage: $0 <file>" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="$SCRIPT_DIR/ai-trace-patterns.json"

if [ ! -f "$PATTERNS_FILE" ]; then
    echo "patterns file not found: $PATTERNS_FILE" >&2
    exit 2
fi

HITS=0
REPORT=""

# 用 grep -E 跑每条正则（不依赖 jq）
# 解析 patterns JSON 简易办法：grep -oE '"id": "[^"]+"|"regex": "[^"]+"'
ids=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$PATTERNS_FILE" | sed -E 's/.*"([^"]+)"$/\1/')
regexes=$(grep -oE '"regex"[[:space:]]*:[[:space:]]*"[^"]+"' "$PATTERNS_FILE" | sed -E 's/.*"([^"]+)"$/\1/')

# 转为数组（兼容 macOS 默认 bash 3.2，不使用 mapfile）
ID_ARR=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    ID_ARR[${#ID_ARR[@]}]="$line"
done <<EOF
$ids
EOF

REGEX_ARR=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    REGEX_ARR[${#REGEX_ARR[@]}]="$line"
done <<EOF
$regexes
EOF

for i in "${!ID_ARR[@]}"; do
    id="${ID_ARR[$i]}"
    regex="${REGEX_ARR[$i]}"
    if grep -qE "$regex" "$FILE" 2>/dev/null; then
        # 找出命中的行
        hits=$(grep -nE "$regex" "$FILE" 2>/dev/null | head -3)
        REPORT="${REPORT}[P0] ${id}:\n${hits}\n\n"
        HITS=$((HITS + 1))
    fi
done

if [ "$HITS" -gt 0 ]; then
    echo -e "AI 痕迹检测：$HITS 类 P0 痕迹\n" >&2
    echo -e "$REPORT" >&2
    echo "请手动删除或改写上述痕迹后重跑。" >&2
    exit 1
fi

echo "AI 痕迹检测：通过（无 P0 痕迹）"
exit 0
