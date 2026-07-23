#!/bin/bash
# session-start.sh — 显示项目状态和写作上下文摘要
# 设计原则：无可用信息时完全静默，不输出任何内容，避免污染 context
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT=""
HAS_CONTENT=false

# 先做最小 preflight，再 source；否则 lib 缺失时无法输出可修复提示。
if [ ! -f "$HOOK_DIR/lib/common.sh" ] || [ ! -f "$HOOK_DIR/lib/sentinel.sh" ]; then
  printf '%b' "[WARN] 写作协作环境不完整：hook 函数库缺失。运行 /novel-assistant 更新写作协作环境，恢复 .claude/hooks/lib/。\n"
  exit 0
fi

# 加载公共函数库
source "$HOOK_DIR/lib/common.sh"
source "$HOOK_DIR/lib/sentinel.sh"
source "$HOOK_DIR/lib/book-state.sh"

# 字节稳定区域：本 hook 经 discover_active_book 处理中文书名/路径。Windows 中文系统若导出
# GBK 区域设置，locale 敏感操作会按多字节错解 UTF-8。强制 C 区域走字节处理才稳（issue #164
# 同类）。本 hook 无内嵌 python，可直接 export。
export LC_ALL=C

ROOT=$(project_root)

# 记录协作模式会话心跳。该心跳只用于跨会话任务租约判断：
# - 不输出可见文本，避免污染上下文。
# - 不声明流式早停/进程托管/精确计费能力；这些只属于 workflow-runner 托管模式。
if [ -f "$ROOT/scripts/workflow-session-heartbeat.js" ]; then
  SESSION_ID="claude:${PPID:-unknown}"
  HOST_NAME="$(hostname 2>/dev/null || echo unknown)"
  node "$ROOT/scripts/workflow-session-heartbeat.js" record \
    --project-root "$ROOT" \
    --session-id "$SESSION_ID" \
    --host "$HOST_NAME" \
    --host-execution-mode cooperative_interactive >/dev/null 2>&1 || true
fi

# 写作协作环境更新后的一次性重启确认。custom agents 只在会话启动时被注册成
# subagent_type；更新完成后会留下 .claude/.agents-pending-restart 标记。
# 走到这里说明已是新会话、agents 已随会话重新加载——确认并清除标记（一次性）。
if [ -f "$ROOT/.claude/.agents-pending-restart" ]; then
  OUTPUT+="[INFO] 写作协作环境已更新，本会话已重新加载 custom agent，现已注册可用。\n"
  OUTPUT+="  如果仍提示 agent 不可用，请重新打开一个 Claude Code 会话后再继续写作。\n\n"
  HAS_CONTENT=true
  rm -f "$ROOT/.claude/.agents-pending-restart" 2>/dev/null || true
fi

# 部署自检：.story-deployed 存在但 hooks 文件被误删时发出警告
if sentinel_exists "$ROOT/.story-deployed"; then
  MISSING_HOOKS=""
  for hook in session-start.sh session-end.sh detect-story-gaps.sh pre-compact.sh post-compact.sh validate-story-commit.sh guard-outline-before-prose.sh lib/common.sh lib/sentinel.sh; do
    if [ ! -f "$ROOT/.claude/hooks/$hook" ]; then
      MISSING_HOOKS+="$hook "
    fi
  done
  if [ -n "$MISSING_HOOKS" ]; then
    OUTPUT+="[WARN] 写作协作环境不完整：缺少 hook：$MISSING_HOOKS\n"
    OUTPUT+="  修复：运行 /novel-assistant 更新写作协作环境，恢复缺失文件。\n\n"
    HAS_CONTENT=true
  fi

  AGENTS_VERSION=$(read_sentinel_field agents_version "$ROOT/.story-deployed")
  case "$AGENTS_VERSION" in
    ''|*[!0-9]*)
      OUTPUT+="[WARN] 写作协作环境版本信息不完整。运行 /novel-assistant 更新写作协作环境。\n\n"
      HAS_CONTENT=true
      ;;
    *)
      if [ "$AGENTS_VERSION" -lt 18 ]; then
        OUTPUT+="[WARN] 写作协作环境版本偏旧（agents v${AGENTS_VERSION}，低于 v18）。运行 /novel-assistant 更新写作协作环境。\n\n"
        HAS_CONTENT=true
      fi
      ;;
  esac

  for field in setup_skill_version novel_assistant_bundle_id novel_assistant_source_commit target_cli resolver_strategy references_dir; do
    if [ -z "$(read_sentinel_field "$field" "$ROOT/.story-deployed")" ]; then
      OUTPUT+="[WARN] 写作协作环境元信息不完整：缺少 $field。运行 /novel-assistant 更新写作协作环境。\n\n"
      HAS_CONTENT=true
    fi
  done

  REFERENCES_DIR=$(read_sentinel_field references_dir "$ROOT/.story-deployed")
  if [ -n "$REFERENCES_DIR" ]; then
    REFERENCES_PATH=$(resolve_project_path "$REFERENCES_DIR")
    if [ ! -d "$REFERENCES_PATH" ] || ! find "$REFERENCES_PATH" -maxdepth 1 -type f -name "*.md" -print -quit 2>/dev/null | grep -q .; then
      OUTPUT+="[WARN] 写作协作环境参考资料包缺失或为空：${REFERENCES_DIR}。运行 /novel-assistant 更新写作协作环境。\n\n"
      HAS_CONTENT=true
    fi
  fi
else
  OUTPUT+="[WARN] 写作协作环境未部署。运行 /novel-assistant 更新写作协作环境。\n\n"
  HAS_CONTENT=true
fi

# 显示分支和最近 commit（仅在有 git 历史时）
BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null || echo "")
if [ -n "$BRANCH" ]; then
  OUTPUT+="=== 写作进度 ===\n"
  OUTPUT+="分支：$BRANCH\n"
  RECENT=$(git -C "$ROOT" log --oneline -5 2>/dev/null || true)
  if [ -n "$RECENT" ]; then
    OUTPUT+="$RECENT\n"
  fi
  OUTPUT+="\n"
  HAS_CONTENT=true
fi

# 上下文.md 摘要（只看当前位置部分，前 10 行）
BOOK_DIR=$(discover_active_book)
if [ -n "$BOOK_DIR" ] && [ -f "$BOOK_DIR/追踪/上下文.md" ]; then
  OUTPUT+="--- 当前位置 ---\n"
  SNAPSHOT=$(head -10 "$BOOK_DIR/追踪/上下文.md")
  OUTPUT+="${SNAPSHOT}\n---\n\n"
  HAS_CONTENT=true
fi

# 状态机检查：检测未完成项目
if book_state_exists "$ROOT"; then
    book_title=$(book_state_get_field "$ROOT" bookTitle)
    cur_ch=$(book_state_get_field "$ROOT" currentChapter)
    cur_status=$(book_state_get_status "$ROOT")
    if [ "$cur_status" = "in_progress" ]; then
        OUTPUT+="[INFO] 续写检测：${book_title} 第 ${cur_ch} 章未完成（输入 /novel-assistant 继续写第 ${cur_ch} 章）\n\n"
        HAS_CONTENT=true
    fi
fi

# 未完成拆文（阈值 > 0 才报告）
if [ -d "$ROOT/拆文库" ]; then
  PROGRESS_COUNT=$(find "$ROOT/拆文库" -name "_progress.md" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$PROGRESS_COUNT" -gt 0 ]; then
    OUTPUT+="[INFO] 拆文库/ 中有 $PROGRESS_COUNT 个未完成拆文。运行 /novel-assistant 继续拆文。\n"
    HAS_CONTENT=true
  fi
fi

# 仅在有实际内容时输出，否则完全静默
if [ "$HAS_CONTENT" = true ]; then
  printf '%b' "$OUTPUT"
fi
