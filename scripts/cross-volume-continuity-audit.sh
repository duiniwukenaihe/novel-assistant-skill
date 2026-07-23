#!/bin/bash
# cross-volume-continuity-audit.sh — verify that the next volume inherits prior-volume hooks and foreshadows.
set -u

usage() {
  echo "Usage: $0 --from-volume 第1卷 --to-volume 第2卷 <book-dir> <from-chapter-id> [to-chapter-id]" >&2
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

add_unique_line() {
  value="$1"
  file="$2"
  [ -n "$value" ] || return 0
  if ! grep -qxF "$value" "$file" 2>/dev/null; then
    printf '%s\n' "$value" >> "$file"
  fi
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

collect_keywords() {
  : > "$terms_file"
  awk '
    /^### 跨卷继承关键词/ { in_section = 1; next }
    /^### / { in_section = 0 }
    in_section && /^\|/ && $0 !~ /\|---/ && $0 !~ /keyword/ {
      split($0, fields, "|")
      keyword = fields[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", keyword)
      if (keyword != "" && keyword !~ /^\[/) print keyword
    }
  ' "$handoff_file" | while IFS= read -r term; do
    add_unique_line "$term" "$terms_file"
  done
}

hit() {
  term="$1"
  file="$2"
  if [ -f "$file" ] && grep -qF "$term" "$file"; then
    printf 'OK'
  else
    printf 'MISS'
  fi
}

from_volume=""
to_volume=""
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
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

handoff_file="$book_dir/追踪/卷交接/${from_volume}_to_${to_volume}.md"
[ -f "$handoff_file" ] || fail "cross-volume handoff not found: 追踪/卷交接/${from_volume}_to_${to_volume}.md"

to_volume_outline="$book_dir/大纲/$to_volume/卷纲.md"
to_detail_outline="$book_dir/大纲/$to_volume/细纲_第${to_chapter}章.md"
to_contract="$book_dir/追踪/章节契约/$to_volume/第${to_chapter}章.md"
to_body="$(first_existing_body "$book_dir" "$to_volume" "$to_chapter")" || fail "next volume body not found: 正文/${to_volume}/第${to_chapter}章*.md"

[ -f "$to_volume_outline" ] || fail "next volume outline not found: 大纲/${to_volume}/卷纲.md"
[ -f "$to_contract" ] || fail "next volume contract not found: 追踪/章节契约/${to_volume}/第${to_chapter}章.md"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
terms_file="$tmp_dir/terms"
collect_keywords

[ -s "$terms_file" ] || fail "no cross-volume keywords found in handoff pack"

missing=0

echo "## Cross Volume Continuity Audit：${from_volume} 第 ${from_chapter} 章 -> ${to_volume} 第 ${to_chapter} 章"
echo
echo "### 来源"
echo "- 跨卷交接包：$(relpath "$handoff_file" "$book_dir")"
echo "- 下一卷卷纲：$(relpath "$to_volume_outline" "$book_dir")"
if [ -f "$to_detail_outline" ]; then
  echo "- 下一卷首章细纲：$(relpath "$to_detail_outline" "$book_dir")"
else
  echo "- 下一卷首章细纲：大纲/${to_volume}/细纲_第${to_chapter}章.md（未找到）"
fi
echo "- 下一卷首章契约：$(relpath "$to_contract" "$book_dir")"
echo "- 下一卷首章正文：$(relpath "$to_body" "$book_dir")"
echo
echo "### 跨卷继承关键词"
echo "| keyword | volume_outline | detail_outline | contract | body | result |"
echo "|---|---|---|---|---|---|"

while IFS= read -r term; do
  [ -n "$term" ] || continue
  volume_hit="$(hit "$term" "$to_volume_outline")"
  detail_hit="$(hit "$term" "$to_detail_outline")"
  contract_hit="$(hit "$term" "$to_contract")"
  body_hit="$(hit "$term" "$to_body")"
  result="OK"
  if [ "$contract_hit" != "OK" ] || [ "$body_hit" != "OK" ]; then
    result="CrossVolume_Continuity_Missing"
    missing=$((missing + 1))
  fi
  echo "| $term | $volume_hit | $detail_hit | $contract_hit | $body_hit | $result |"
done < "$terms_file"

echo
echo "### 结论"
if [ "$missing" -eq 0 ]; then
  echo "- Audit: PASS"
  exit 0
fi

echo "- Audit: FAIL"
echo "- code: CrossVolume_Continuity_Missing"
echo "- recovery: 先修 ${to_volume} 第 ${to_chapter} 章契约和正文，再重跑本审计；如果选择延迟回收，必须在契约中写明回收窗口。"
exit 1
