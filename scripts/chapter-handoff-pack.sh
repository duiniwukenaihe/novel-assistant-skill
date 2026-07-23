#!/bin/bash
# chapter-handoff-pack.sh — summarize continuity constraints before the next chapter.
set -u

usage() {
  echo "Usage: $0 [--write] [--volume 第1卷] <book-dir> <chapter-id>" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

first_existing_body() {
  dir="$1"
  chapter="$2"
  volume="$3"
  for file in "$dir/正文/$volume/第${chapter}章_"*.md "$dir/正文/$volume/第${chapter}章.md" "$dir/正文/第${chapter}章_"*.md "$dir/正文/第${chapter}章.md"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

first_existing_artifact() {
  dir="$1"
  volume="$2"
  chapter="$3"
  for file in "$dir/$volume/第${chapter}章.md" "$dir/第${chapter}章.md"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

is_volume_local() {
  file="$1"
  case "$(relpath "$file" "$book_dir")" in
    正文/"$volume"/*|追踪/章节契约/"$volume"/*|追踪/漂移门控/"$volume"/*|追踪/交接包/"$volume"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

relpath() {
  file="$1"
  base="$2"
  printf '%s\n' "${file#$base/}"
}

extract_after_label() {
  label="$1"
  file="$2"
  grep -m 1 "$label" "$file" 2>/dev/null | sed "s/^.*$label[：:][[:space:]]*//"
}

print_matching_rows() {
  file="$1"
  pattern="$2"
  fallback="$3"
  if [ -f "$file" ]; then
    rows="$(grep "$pattern" "$file" 2>/dev/null || true)"
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows"
      return 0
    fi
  fi
  printf '%s\n' "$fallback"
}

print_current_state_delta() {
  file="$1"
  pattern="$2"
  fallback="$3"
  if [ -f "$file" ]; then
    rows="$(awk -v chapter_num="$chapter_num" '
      /^## / {
        heading = $0
        in_section = (heading ~ ("第[[:space:]]*0*" chapter_num "[[:space:]]*章[[:space:]]*State Delta"))
        next
      }
      in_section { print }
    ' "$file" | grep "$pattern" 2>/dev/null || true)"
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows"
      return 0
    fi
  fi
  printf '%s\n' "$fallback"
}

generate_pack() {
  body_rel="$(relpath "$body_file" "$book_dir")"
  contract_rel="$(relpath "$contract_file" "$book_dir")"
  gate_rel="$(relpath "$gate_file" "$book_dir")"

  title="$(grep -m 1 '^## ' "$body_file" 2>/dev/null | sed 's/^##[[:space:]]*//')"
  expectation="$(extract_after_label "下一章读者期待" "$contract_file")"
  hook="$(extract_after_label "章尾钩子" "$contract_file")"
  gate_line="$(grep -m 1 'Gate:' "$gate_file" 2>/dev/null | sed 's/^[[:space:]-]*//')"

  [ -n "$title" ] || title="第 ${chapter_num} 章"
  [ -n "$expectation" ] || expectation="未填写"
  [ -n "$hook" ] || hook="未填写"
  [ -n "$gate_line" ] || gate_line="Gate: UNKNOWN"

  echo "## Chapter Handoff Pack：第 ${chapter} 章 -> 第 ${next_chapter} 章"
  echo
  echo "### 来源"
  echo "- 源正文：$body_rel"
  echo "- 章节标题：$title"
  echo "- 章节契约：$contract_rel"
  echo "- 漂移门控：$gate_rel"
  echo "- $gate_line"
  echo
  echo "### 下一章继承"
  echo "- 章尾钩子：$hook"
  echo "- 下一章读者期待：$expectation"
  if is_volume_local "$body_file" || is_volume_local "$contract_file"; then
    echo "- 下一章细纲：大纲/${volume}/细纲_第${next_chapter}章.md"
    echo "- 下一章契约：追踪/章节契约/${volume}/第${next_chapter}章.md"
  else
    echo "- 下一章细纲：大纲/细纲_第${next_chapter}章.md"
    echo "- 下一章契约：追踪/章节契约/第${next_chapter}章.md"
  fi
  echo
  echo "### 最近 State Delta"
  print_current_state_delta "$context_file" "江临\\|异常水印\\|旧账号" "- 未找到可摘录的本章 State Delta，请回读 追踪/上下文.md。"
  echo
  echo "### 活跃伏笔"
  print_matching_rows "$foreshadow_file" "异常水印\\|旧账号\\|已埋\\|推进\\|半兑现" "- 未找到活跃伏笔表；如本章新增线索，必须先同步 追踪/伏笔.md。"
  echo
  echo "### 角色连续性"
  print_matching_rows "$invariant_dir/江临.md" "底层欲望\\|当前阶段目标\\|行为红线\\|认知边界\\|^- " "- 未找到角色不变量；下一章写作前必须读取相关角色档案并写明推断来源。"
  echo
  echo "### 下一章必读文件"
  if is_volume_local "$body_file" || is_volume_local "$contract_file"; then
    echo "- 大纲/${volume}/细纲_第${next_chapter}章.md"
    echo "- 正文/${volume}/第${chapter}章_*.md"
  else
    echo "- 大纲/细纲_第${next_chapter}章.md"
    echo "- 正文/第${chapter}章_*.md"
  fi
  echo "- 追踪/上下文.md"
  echo "- 追踪/伏笔.md"
  echo "- 追踪/时间线.md"
  echo "- 设定/角色不变量/{核心角色}.md"
  if is_volume_local "$body_file" || is_volume_local "$contract_file"; then
    echo "- 追踪/章节契约/${volume}/第${next_chapter}章.md"
  else
    echo "- 追踪/章节契约/第${next_chapter}章.md"
  fi
  echo
  echo "### 交接规则"
  echo "- 先读本交接包，再生成第 ${next_chapter} 章 Chapter Contract。"
  echo "- 不得在下一章回退本章 State Delta。"
  echo "- 如要删除或改写本章线索，先运行 Revision Impact Analysis。"
  echo "- 第 ${next_chapter} 章写完后必须重新生成新的 Chapter Handoff Pack。"
}

write_mode=0
volume="第1卷"
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --write)
      write_mode=1
      shift
      ;;
    --volume)
      volume="${2:-}"
      [ -n "$volume" ] || fail "--volume requires a value"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

[ -d "$1" ] || fail "book dir not found: $1"
book_dir="$(cd "$1" && pwd)"
chapter_input="$2"
chapter_num="$((10#$chapter_input))"
chapter="$(printf '%03d' "$chapter_num")"
next_chapter="$(printf '%03d' "$((chapter_num + 1))")"

body_file="$(first_existing_body "$book_dir" "$chapter" "$volume")" || fail "body not found for chapter $chapter"
contract_file="$(first_existing_artifact "$book_dir/追踪/章节契约" "$volume" "$chapter")" || fail "chapter contract not found: 追踪/章节契约/${volume}/第${chapter}章.md or 追踪/章节契约/第${chapter}章.md"
gate_file="$(first_existing_artifact "$book_dir/追踪/漂移门控" "$volume" "$chapter")" || fail "plot drift gate not found: 追踪/漂移门控/${volume}/第${chapter}章.md or 追踪/漂移门控/第${chapter}章.md"
context_file="$book_dir/追踪/上下文.md"
foreshadow_file="$book_dir/追踪/伏笔.md"
invariant_dir="$book_dir/设定/角色不变量"

[ -f "$context_file" ] || fail "context not found: 追踪/上下文.md"

grep -q 'Gate:[[:space:]]*PASS' "$gate_file" || fail "Plot Drift Gate must be PASS before handoff"

tmp_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

generate_pack > "$tmp_file"

if [ "$write_mode" -eq 1 ]; then
  if is_volume_local "$body_file" || is_volume_local "$contract_file" || is_volume_local "$gate_file"; then
    out_dir="$book_dir/追踪/交接包/$volume"
    out_rel="追踪/交接包/${volume}/第${chapter}章_to_第${next_chapter}章.md"
  else
    out_dir="$book_dir/追踪/交接包"
    out_rel="追踪/交接包/第${chapter}章_to_第${next_chapter}章.md"
  fi
  mkdir -p "$out_dir"
  out_file="$out_dir/第${chapter}章_to_第${next_chapter}章.md"
  cp "$tmp_file" "$out_file"
  echo "WROTE: $out_rel"
else
  cat "$tmp_file"
fi
