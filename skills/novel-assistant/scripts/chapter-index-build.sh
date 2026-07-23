#!/bin/bash
# chapter-index-build.sh — build a stable chapter body index for longform projects.
set -u

usage() {
  echo "Usage: $0 [--write] <book-dir>" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_chapter_num() {
  basename "$1" | sed -n 's/^第\([0-9][0-9]*\)章.*\.md$/\1/p'
}

extract_title() {
  file="$1"
  base="$2"
  title="$(grep -m 1 '^##[[:space:]]*' "$file" 2>/dev/null | sed 's/^##[[:space:]]*//; s/[	]/ /g')"
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
    return 0
  fi
  printf '%s\n' "$base" | sed 's/\.md$//; s/_/ /g; s/[	]/ /g'
}

char_count() {
  wc -m < "$1" | tr -d '[:space:]'
}

write_mode=0
if [ "${1:-}" = "--write" ]; then
  write_mode=1
  shift
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

[ -d "$1" ] || fail "book dir not found: $1"
book_dir="$(cd "$1" && pwd)"
body_dir="$book_dir/正文"
[ -d "$body_dir" ] || fail "body dir not found: 正文"

tmp_file="$(mktemp)"
rows_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file" "$rows_file"
}
trap cleanup EXIT

printf 'chapter\ttitle\tpath\tchars\n' > "$tmp_file"
: > "$rows_file"

find "$body_dir" -type f -name '第*章*.md' | sort | while IFS= read -r file; do
  base="$(basename "$file")"
  raw_num="$(extract_chapter_num "$base")"
  [ -n "$raw_num" ] || continue
  chapter="$(printf '%03d' "$((10#$raw_num))")"
  rel="${file#$book_dir/}"
  title="$(extract_title "$file" "$base")"
  chars="$(char_count "$file")"
  printf '%s\t%s\t%s\t%s\n' "$chapter" "$title" "$rel" "$chars" >> "$rows_file"
done

sort -t "$(printf '\t')" -k1,1 "$rows_file" >> "$tmp_file"

if [ "$write_mode" -eq 1 ]; then
  mkdir -p "$book_dir/追踪"
  cp "$tmp_file" "$book_dir/追踪/章节索引.tsv"
  echo "WROTE: 追踪/章节索引.tsv"
else
  cat "$tmp_file"
fi
