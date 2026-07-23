#!/bin/bash
# cross-volume-handoff-pack.sh — carry prior-volume hooks and foreshadows into the next volume.
set -u

usage() {
  echo "Usage: $0 [--write] --from-volume 第1卷 --to-volume 第2卷 <book-dir> <from-chapter-id> [to-chapter-id]" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

relpath() {
  file="$1"
  base="$2"
  printf '%s\n' "${file#$base/}"
}

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

first_existing_body() {
  dir="$1"
  volume="$2"
  chapter="$3"
  for file in "$dir/正文/$volume/第${chapter}章_"*.md "$dir/正文/$volume/第${chapter}章.md"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

first_existing_file() {
  for file in "$@"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

extract_after_label() {
  label="$1"
  file="$2"
  grep -m 1 "$label" "$file" 2>/dev/null | sed "s/^.*$label[：:][[:space:]]*//" | trim
}

add_unique() {
  value="$(printf '%s\n' "$1" | trim)"
  file="$2"
  [ -n "$value" ] || return 0
  if ! grep -qxF "$value" "$file" 2>/dev/null; then
    printf '%s\n' "$value" >> "$file"
  fi
}

extract_pipe_field() {
  line="$1"
  field="$2"
  printf '%s\n' "$line" | awk -F'|' -v idx="$field" '{
    value = $idx
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    print value
  }'
}

collect_keywords() {
  : > "$keywords_file"

  if [ -f "$foreshadow_file" ]; then
    grep -E "${from_volume}|${to_volume}|第${from_chapter}章|下一卷|跨卷|卷首|卷末|已埋|推进|半兑现" "$foreshadow_file" 2>/dev/null \
      | grep -v '^|---' \
      | while IFS= read -r line; do
          if printf '%s\n' "$line" | grep -q '|'; then
            keyword="$(extract_pipe_field "$line" 5)"
            [ -n "$keyword" ] || keyword="$(extract_pipe_field "$line" 4)"
            add_unique "$keyword" "$keywords_file"
          fi
        done
  fi

  [ -s "$keywords_file" ] && {
    sort -u "$keywords_file" -o "$keywords_file"
    return 0
  }

  for label in "章尾钩子" "下一章读者期待"; do
    text="$(extract_after_label "$label" "$contract_file")"
    [ -n "$text" ] || continue
    printf '%s\n' "$text" \
      | sed 's/[，。；、]/\n/g' \
      | sed 's/必须.*$//; s/继续.*$//; s/发热.*$//; s/进入.*$//; s/指向.*$//' \
      | trim \
      | while IFS= read -r fragment; do
          case "$fragment" in
            ""|沈七|绿珠|下一章读者期待) ;;
            *)
              if [ "${#fragment}" -ge 4 ]; then
                add_unique "$fragment" "$keywords_file"
              fi
              ;;
          esac
        done
  done

  sort -u "$keywords_file" -o "$keywords_file"
}

print_matching_source_lines() {
  title="$1"
  file="$2"
  pattern="$3"
  fallback="$4"
  echo "### $title"
  if [ -f "$file" ]; then
    rows="$(grep -E "$pattern" "$file" 2>/dev/null || true)"
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows" | sed 's/^/- /'
      echo
      return 0
    fi
  fi
  echo "- $fallback"
  echo
}

generate_pack() {
  echo "# Cross Volume Handoff：${from_volume} -> ${to_volume}"
  echo
  echo "### 来源"
  echo "- 上一卷末章正文：$(relpath "$from_body" "$book_dir")"
  echo "- 上一卷末章契约：$(relpath "$contract_file" "$book_dir")"
  echo "- 上一卷末章漂移门控：$(relpath "$gate_file" "$book_dir")"
  echo "- 上一卷卷纲：$(relpath "$from_outline" "$book_dir")"
  echo "- 下一卷卷纲：$(relpath "$to_outline" "$book_dir")"
  if [ -f "$to_detail_outline" ]; then
    echo "- 下一卷首章细纲：$(relpath "$to_detail_outline" "$book_dir")"
  else
    echo "- 下一卷首章细纲：大纲/${to_volume}/细纲_第${to_chapter}章.md（未找到）"
  fi
  echo "- 下一卷首章契约：追踪/章节契约/${to_volume}/第${to_chapter}章.md"
  echo "- 下一卷首章正文：正文/${to_volume}/第${to_chapter}章_*.md"
  echo
  echo "### 上一卷预留钩子"
  echo "- 章尾钩子：$(extract_after_label "章尾钩子" "$contract_file")"
  echo "- 下一章读者期待：$(extract_after_label "下一章读者期待" "$contract_file")"
  echo
  print_matching_source_lines "上一卷未回收伏笔" "$foreshadow_file" "${from_volume}|${to_volume}|第${from_chapter}章|下一卷|跨卷|卷首|卷末|已埋|推进|半兑现" "未找到显式跨卷伏笔；请在 追踪/伏笔.md 补充。"
  print_matching_source_lines "上一卷卷末预留" "$from_outline" "下一卷|预留|卷末|悬念|伏笔|钩子|卷首" "上一卷卷纲未写明下一卷预留。"
  print_matching_source_lines "下一卷承接设计" "$to_outline" "承接|上一卷|卷首|开篇|预留|伏笔|钩子|余波" "下一卷卷纲未写明如何承接上一卷。"
  echo "### 跨卷继承关键词"
  echo "| keyword | source | next-volume duty |"
  echo "|---|---|---|"
  if [ -s "$keywords_file" ]; then
    while IFS= read -r keyword; do
      [ -n "$keyword" ] || continue
      echo "| $keyword | 上一卷钩子/伏笔 | 下一卷卷纲、首章契约和首章正文必须承接 |"
    done < "$keywords_file"
  else
    echo "| [待补充] | 未从伏笔/契约抽取到关键词 | 下一卷开写前补齐 |"
  fi
  echo
  echo "### 交接规则"
  echo "- 写 ${to_volume} 第 ${to_chapter} 章前，先读取本交接包、${to_volume} 卷纲、首章细纲和上一卷末章正文。"
  echo "- 上一卷预留的钩子/伏笔不能在下一卷开篇消失；若延迟回收，必须在首章契约写明延迟原因和回收窗口。"
  echo "- 下一卷第 ${to_chapter} 章写完后运行 cross-volume-continuity-audit.sh。"
  echo "- 跨卷交接包不替代 追踪/伏笔.md、追踪/时间线.md、追踪/角色状态.md；发现不一致时先修追踪文件再重建交接包。"
}

write_mode=0
from_volume=""
to_volume=""
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --write)
      write_mode=1
      shift
      ;;
    --from-volume)
      from_volume="${2:-}"
      [ -n "$from_volume" ] || fail "--from-volume requires a value"
      shift 2
      ;;
    --to-volume)
      to_volume="${2:-}"
      [ -n "$to_volume" ] || fail "--to-volume requires a value"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "$from_volume" ] || [ -z "$to_volume" ] || [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
  exit 2
fi

[ -d "$1" ] || fail "book dir not found: $1"
book_dir="$(cd "$1" && pwd)"
from_input="$2"
from_num="$((10#$from_input))"
from_chapter="$(printf '%03d' "$from_num")"
if [ "$#" -eq 3 ]; then
  to_num="$((10#$3))"
else
  to_num=1
fi
to_chapter="$(printf '%03d' "$to_num")"

from_body="$(first_existing_body "$book_dir" "$from_volume" "$from_chapter")" || fail "previous volume body not found: 正文/${from_volume}/第${from_chapter}章*.md"
contract_file="$(first_existing_file "$book_dir/追踪/章节契约/$from_volume/第${from_chapter}章.md")" || fail "previous volume contract not found: 追踪/章节契约/${from_volume}/第${from_chapter}章.md"
gate_file="$(first_existing_file "$book_dir/追踪/漂移门控/$from_volume/第${from_chapter}章.md")" || fail "previous volume gate not found: 追踪/漂移门控/${from_volume}/第${from_chapter}章.md"
from_outline="$(first_existing_file "$book_dir/大纲/$from_volume/卷纲.md")" || fail "from volume outline not found: 大纲/${from_volume}/卷纲.md"
to_outline="$(first_existing_file "$book_dir/大纲/$to_volume/卷纲.md")" || fail "to volume outline not found: 大纲/${to_volume}/卷纲.md"
to_detail_outline="$book_dir/大纲/$to_volume/细纲_第${to_chapter}章.md"
foreshadow_file="$book_dir/追踪/伏笔.md"

grep -q 'Gate:[[:space:]]*PASS' "$gate_file" || fail "previous volume Plot Drift Gate must be PASS before cross-volume handoff"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
keywords_file="$tmp_dir/keywords"
tmp_file="$tmp_dir/cross-volume-handoff.md"

collect_keywords
generate_pack > "$tmp_file"

if [ "$write_mode" -eq 1 ]; then
  out_dir="$book_dir/追踪/卷交接"
  mkdir -p "$out_dir"
  out_file="$out_dir/${from_volume}_to_${to_volume}.md"
  cp "$tmp_file" "$out_file"
  echo "WROTE: 追踪/卷交接/${from_volume}_to_${to_volume}.md"
else
  cat "$tmp_file"
fi
