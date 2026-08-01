#!/bin/bash
# common.sh — 公共函数库，供各 hook 文件 source
# 注意：不加 set -euo pipefail，避免 source 时覆盖调用方的 shell options

# project_root — 稳定解析项目根目录
# 优先使用 Claude Code 注入的 CLAUDE_PROJECT_DIR；其次使用 git root；最后退回当前目录。
# 输出绝对路径，避免 hook 从嵌套 cwd 执行时误读/误写。
project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    (cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P) && return
  fi
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$git_root" ] && [ -d "$git_root" ]; then
    (cd "$git_root" 2>/dev/null && pwd -P) && return
  fi
  pwd -P
}

# resolve_project_path <path> — 将相对路径按项目根目录解析为绝对路径。
resolve_project_path() {
  local path="$1"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$(project_root)" "$path" ;;
  esac
}

# discover_active_book — 单本书查询（活跃书目）
# 优先 root/.active-book；其次 find 第一个 追踪/ (长篇) 或 正文/ / 正文.md (短篇) 目录。
# 使用场景：session-start / session-end / pre-compact / post-compact —— 一次会话只关心当前活跃的那本书。
discover_active_book() {
  local root
  root=$(project_root)

  if [ -f "$root/.active-book" ]; then
    local active resolved
    # LC_ALL=C：书名是中文 UTF-8。Windows 中文系统若导出 GBK 区域设置，trim 的
    # s/^[[:space:]]*// 会逼 sed 按 GBK 解码整行，短书名（如「让你管账号」「修仙传」）的
    # UTF-8 字节是非法 GBK 序列 → BSD sed 报 illegal byte sequence、active 被吞成空 →
    # .active-book 被忽略、误解析到 find 到的第一本书。强制 C 区域走字节处理才稳。
    # 本库被无 export 的 session-*/pre-compact/post-compact 复用，故在此 per-command 兜底，
    # 不在库里 export（避免给调用方留全局副作用，与文件头「不覆盖调用方 shell 选项」一致）。
    active=$(LC_ALL=C sed -n '1p' "$root/.active-book" | LC_ALL=C sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
    if [ -n "$active" ]; then
      resolved=$(resolve_project_path "$active")
      # .active-book 是项目内书目指针，不是任意路径入口。只接受存在、
      # 规范化后仍位于项目根目录下且不是根目录自身的目标；其他情况走正常发现。
      if [ -d "$resolved" ]; then
        resolved=$(cd "$resolved" 2>/dev/null && pwd -P || true)
        case "$resolved" in
          "$root"/*)
            printf '%s\n' "$resolved"
            return
            ;;
        esac
      fi
    fi
  fi

  # 长篇优先（追踪/ 目录存在）
  local first
  first=$(find "$root" -maxdepth 4 -type d -name "追踪" -print -quit 2>/dev/null || true)
  if [ -n "$first" ]; then
    dirname "$first"
    return
  fi

  # 短篇 fallback：查找 正文/ 目录或 正文.md（maxdepth 4 覆盖 推荐/短篇/书名/正文 结构）
  local story_path
  story_path=$(find "$root" -maxdepth 4 \( -type d -name "正文" -o -type f -name "正文.md" \) -print -quit 2>/dev/null || true)
  if [ -n "$story_path" ]; then
    dirname "$story_path"
  fi
}

# discover_all_books — 多本书查询（项目内所有书目）
# 输出：换行分隔的绝对目录路径列表（不含重复）。
# 使用场景：detect-story-gaps —— 需要遍历项目内所有书目做缺口检测。
discover_all_books() {
  local root
  root=$(project_root)
  # 用 awk 去重保持插入顺序（bash 3.2 兼容，不用关联数组）
  {
    # 长篇：追踪/ 父目录
    find "$root" -maxdepth 4 -type d -name "追踪" -print 2>/dev/null | while IFS= read -r d; do dirname "$d"; done
    # 短篇：正文/ 父目录 或 正文.md 父目录
    find "$root" -maxdepth 4 \( -type d -name "正文" -o -type f -name "正文.md" \) -print 2>/dev/null | while IFS= read -r d; do dirname "$d"; done
  } | awk 'NF && !seen[$0]++'
}

# 旧名 alias，仅供外部自定义 hook 引用；新代码用 discover_active_book / discover_all_books。
discover_book_dir() {
  discover_active_book "$@"
}

# is_progress_completed <progress_file> — 判断拆文 _progress.md 是否处于完成状态。
# 完成 = 「最终状态：」字段值精确为 completed 或 completed_with_errors（可带尾随注释，
# 如 "completed ✅（...）"）。其余一律按未完成：缺字段、空文件、无法读取、pending、
# paused_after_stage1、模板占位 {pending/paused_after_stage1/completed/completed_with_errors}。
#
# 实现：状态值本身是 ASCII（completed/completed_with_errors），但字段名「最终状态：」是
# 中文 UTF-8。Windows 中文系统若导出 GBK 区域，awk/grep 按多字节解码会让 UTF-8 字面量与
# UTF-8 内容字节不再相等、误判。本库被未 export LC_ALL=C 的 hook 复用，故 per-command
# 兜底 LC_ALL=C 走字节匹配（与 discover_active_book 同策略，issue #164 同类）。
# 不用含全角字符的方括号字符组（[：]）——在 C/GBK 区域会被拆字节、漏匹配（见
# scripts/check-hook-locale-safety.sh Check 2）。
#
# 返回：完成 exit 0；未完成 exit 1。不向 stdout 输出，调用方可安全做管道/赋值。
#
# 字节布局：每行先剥离 \r。最终状态：= 最(3)+终(3)+状(3)+态(3)+：(3) = 15 字节。
# 状态值取该前缀之后到行尾，去前导空白后判断是否以 completed / completed_with_errors
# 起头并紧跟词界（空格/制表/全角空格/行尾）。awk 的 substr 按字节偏移；index 按字节定位。
is_progress_completed() {
  local file="$1"
  [ -f "$file" ] || return 1
  # key_bytes：「最终状态：」的 UTF-8 字节序列。用 \x.. 转义写到 awk 里，避免本文件被
  # GBK 终端重编码时字面量损坏（脚本源文件本身仍是 UTF-8，转义序列是纯 ASCII，字节稳定）。
  # 用 done=1 标记命中，不在规则块里直接 exit——awk 的 END 块总会跑，END 里再 exit 决定
  # 最终退出码（避免规则块 exit 0 被 END 的 exit 1 覆盖）。
  LC_ALL=C awk '
    function prefix_bytes() {
      # 最终状态： (U+6700 U+7EC8 U+72B6 U+6001 U+FF1A) 的 UTF-8 字节
      return "\xe6\x9c\x80\xe7\xbb\x88\xe7\x8a\xb6\xe6\x80\x81\xef\xbc\x9a"
    }
    {
      sub(/\r$/, "")
      key = prefix_bytes()
      p = index($0, key)
      if (p == 0) next
      v = substr($0, p + length(key))
      sub(/^[ \t]+/, "", v)
      # 精确匹配：completed 或 completed_with_errors，后接词界（空格/制表/全角空格 U+3000/行尾）
      # 先判长的 completed_with_errors，否则会被 completed 分支抢先命中。
      if (v ~ /^completed_with_errors([ \t]|\xe3\x80\x80|$)/) { done=1; exit }
      if (v ~ /^completed([ \t]|\xe3\x80\x80|$)/) { done=1; exit }
      exit
    }
    END { exit (done ? 0 : 1) }
  ' "$file" 2>/dev/null
}
