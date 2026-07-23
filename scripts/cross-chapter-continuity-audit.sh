#!/bin/bash
# cross-chapter-continuity-audit.sh — verify that a chapter inherits the prior handoff.
set -u

usage() {
  echo "Usage: $0 [--volume 第1卷] <book-dir> <previous-chapter-id> [next-chapter-id]" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

add_unique_line() {
  value="$1"
  file="$2"
  if [ -n "$value" ] && ! grep -qxF "$value" "$file" 2>/dev/null; then
    printf '%s\n' "$value" >> "$file"
  fi
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
  file_name="$3"
  for file in "$dir/$volume/$file_name" "$dir/$file_name"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

relpath() {
  file="$1"
  base="$2"
  printf '%s\n' "${file#$base/}"
}

collect_section_first_cells() {
  heading="$1"
  file="$2"
  awk -v heading="$heading" '
    $0 == heading { in_section = 1; next }
    /^### / { in_section = 0 }
    in_section && /^\|/ && $0 !~ /\|---/ {
      split($0, fields, "|")
      cell = fields[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
      if (cell != "" && cell !~ /角色|伏笔/) print cell
    }
  ' "$file"
}

collect_terms() {
  : > "$terms_file"

  if [ -d "$book_dir/设定/角色不变量" ]; then
    for invariant in "$book_dir/设定/角色不变量/"*.md; do
      [ -f "$invariant" ] || continue
      name="$(basename "$invariant" .md)"
      if grep -qF "$name" "$handoff_file"; then
        add_unique_line "$name" "$terms_file"
      fi
    done
  fi

  collect_section_first_cells "### 最近 State Delta" "$handoff_file" | while IFS= read -r term; do
    add_unique_line "$term" "$terms_file"
  done

  collect_section_first_cells "### 活跃伏笔" "$handoff_file" | while IFS= read -r term; do
    add_unique_line "$term" "$terms_file"
  done

  grep -o '追查[^。；，、[:space:]|]*' "$handoff_file" 2>/dev/null | while IFS= read -r phrase; do
    term="$(printf '%s\n' "$phrase" | sed 's/^追查//; s/\.md$//; s/_.*$//' | trim)"
    add_unique_line "$term" "$terms_file"
  done

  sort -u "$terms_file" -o "$terms_file"
}

volume="第1卷"
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
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

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  usage
  exit 2
fi

[ -d "$1" ] || fail "book dir not found: $1"
book_dir="$(cd "$1" && pwd)"
prev_input="$2"
prev_num="$((10#$prev_input))"
prev_chapter="$(printf '%03d' "$prev_num")"

if [ "$#" -eq 3 ]; then
  next_num="$((10#$3))"
else
  next_num="$((prev_num + 1))"
fi
next_chapter="$(printf '%03d' "$next_num")"

handoff_file="$(first_existing_artifact "$book_dir/追踪/交接包" "$volume" "第${prev_chapter}章_to_第${next_chapter}章.md")" || fail "handoff pack not found: 追踪/交接包/${volume}/第${prev_chapter}章_to_第${next_chapter}章.md or 追踪/交接包/第${prev_chapter}章_to_第${next_chapter}章.md"
contract_file="$(first_existing_artifact "$book_dir/追踪/章节契约" "$volume" "第${next_chapter}章.md")" || fail "chapter contract not found: 追踪/章节契约/${volume}/第${next_chapter}章.md or 追踪/章节契约/第${next_chapter}章.md"
body_file="$(first_existing_body "$book_dir" "$next_chapter" "$volume")" || fail "body not found for chapter $next_chapter"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

terms_file="$tmp_dir/terms"
collect_terms

[ -s "$terms_file" ] || fail "no continuity terms found in handoff pack"

missing=0

echo "## Cross Chapter Continuity Audit：第 ${prev_chapter} 章 -> 第 ${next_chapter} 章"
echo
echo "### 来源"
echo "- 交接包：$(relpath "$handoff_file" "$book_dir")"
echo "- 下一章契约：$(relpath "$contract_file" "$book_dir")"
echo "- 下一章正文：$(relpath "$body_file" "$book_dir")"
echo
echo "### 继承关键词"
echo "| keyword | contract | body | result |"
echo "|---|---|---|---|"

while IFS= read -r term; do
  [ -n "$term" ] || continue
  contract_hit="MISS"
  body_hit="MISS"
  result="Continuity_Missing"
  if grep -qF "$term" "$contract_file"; then
    contract_hit="OK"
  fi
  if grep -qF "$term" "$body_file"; then
    body_hit="OK"
  fi
  if [ "$contract_hit" = "OK" ] && [ "$body_hit" = "OK" ]; then
    result="OK"
  else
    missing=$((missing + 1))
  fi
  echo "| $term | $contract_hit | $body_hit | $result |"
done < "$terms_file"

echo
echo "### 结论"
if [ "$missing" -eq 0 ]; then
  echo "- Audit: PASS"
  exit 0
fi

echo "- Audit: FAIL"
echo "- code: Continuity_Missing"
exit 1
