#!/bin/bash
# chapter-stability-check.sh — validate one longform chapter stability loop.
set -euo pipefail

VOLUME="第1卷"

while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --volume)
      VOLUME="${2:-}"
      [ -n "$VOLUME" ] || {
        echo "FAIL: --volume requires a value" >&2
        exit 1
      }
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

BOOK_DIR="${1:-}"
CHAPTER_INPUT="${2:-001}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

trim_boundary_value() {
  sed 's/^[[:space:]]*-[[:space:]]*//; s/^[^：:]*[：:]//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

build_character_scan_file() {
  character_name="$1"
  source_file="$2"
  target_file="$3"

  awk -v character="$character_name" '
    function pov_name(line, normalized) {
      normalized = line
      sub(/^[[:space:]#>*-]*/, "", normalized)
      if (normalized ~ /^(POV|视角)[[:space:]]*[：:]/) {
        sub(/^(POV|视角)[[:space:]]*[：:][[:space:]]*/, "", normalized)
        sub(/[[:space:]#].*$/, "", normalized)
        return normalized
      }
      return ""
    }

    {
      name = pov_name($0)
      if (name != "") {
        current_pov = name
        next
      }

      if (current_pov == "" || current_pov == character) {
        print
      }
    }
  ' "$source_file" > "$target_file"
}

indexed_chapter_body() {
  index_file="$1"
  chapter="$2"
  if [ -f "$index_file" ]; then
    awk -F '\t' -v chapter="$chapter" 'NR > 1 && $1 == chapter { print $3; exit }' "$index_file"
  fi
}

first_existing_body() {
  dir="$1"
  chapter="$2"
  index_file="$dir/追踪/章节索引.tsv"
  indexed_rel="$(indexed_chapter_body "$index_file" "$chapter")"
  if [ -n "${indexed_rel:-}" ] && [ -f "$dir/$indexed_rel" ]; then
    printf '%s\n' "$dir/$indexed_rel"
    return 0
  fi

  for file in "$dir/正文/$VOLUME/第${chapter}章_"*.md "$dir/正文/$VOLUME/第${chapter}章.md" "$dir/正文/第${chapter}章_"*.md "$dir/正文/第${chapter}章.md"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

first_existing_artifact() {
  dir="$1"
  chapter="$2"
  for file in "$dir/$VOLUME/第${chapter}章.md" "$dir/第${chapter}章.md"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

normalize_chapter() {
  raw="$1"
  num="$((10#$raw))"
  printf '%03d' "$num"
}

[ -n "$BOOK_DIR" ] || fail "usage: $0 <book-dir> [chapter-number]"
[ -d "$BOOK_DIR" ] || fail "book dir missing: $BOOK_DIR"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

CHAPTER="$(normalize_chapter "$CHAPTER_INPUT")"

contract="$(first_existing_artifact "$BOOK_DIR/追踪/章节契约" "$CHAPTER")" || fail "required file missing: $BOOK_DIR/追踪/章节契约/$VOLUME/第${CHAPTER}章.md or $BOOK_DIR/追踪/章节契约/第${CHAPTER}章.md"
gate="$(first_existing_artifact "$BOOK_DIR/追踪/漂移门控" "$CHAPTER")" || fail "required file missing: $BOOK_DIR/追踪/漂移门控/$VOLUME/第${CHAPTER}章.md or $BOOK_DIR/追踪/漂移门控/第${CHAPTER}章.md"
context="$BOOK_DIR/追踪/上下文.md"
character_invariants_dir="$BOOK_DIR/设定/角色不变量"

for file in "$context"; do
  [ -f "$file" ] || fail "required file missing: $file"
done
[ -d "$character_invariants_dir" ] || fail "character invariants dir missing: $character_invariants_dir"

chapter_file="$(first_existing_body "$BOOK_DIR" "$CHAPTER")" || fail "chapter body missing for chapter $CHAPTER"

grep -q "Chapter Contract" "$contract" || fail "contract missing Chapter Contract heading"
grep -q "Gate: PASS" "$gate" || fail "plot drift gate is not PASS"
grep -q "State Delta" "$context" || fail "context missing State Delta"

beat_count=0
while IFS= read -r line; do
  beat_id="$(printf '%s\n' "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')"
  beat_text="$(printf '%s\n' "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $3}')"
  [ -n "$beat_id" ] || continue
  [ -n "$beat_text" ] || continue
  case "$beat_id" in
    B[0-9]*)
      beat_count=$((beat_count + 1))
      grep -qF "$beat_text" "$chapter_file" || fail "contract beat not found in body: $beat_id $beat_text"
      grep -qF "$beat_id" "$gate" || fail "plot drift gate missing beat id: $beat_id"
      ;;
  esac
done < "$contract"

[ "$beat_count" -gt 0 ] || fail "contract has no B# beats"

if ! find "$character_invariants_dir" -type f -name '*.md' -print -quit | grep -q .; then
  fail "no character invariant files found"
fi

while IFS= read -r invariant_file; do
  character_name="$(basename "$invariant_file" .md)"
  character_scan_file="$tmp_dir/${character_name}.chapter-scan.md"
  build_character_scan_file "$character_name" "$chapter_file" "$character_scan_file"
  section=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "## 行为红线"*)
        section="redline"
        continue
        ;;
      "## 认知边界"*)
        section="knowledge"
        continue
        ;;
      "## "*)
        section=""
        continue
        ;;
    esac

    case "$section:$line" in
      knowledge:*不能提前知道[：:]*)
        forbidden="$(printf '%s\n' "$line" | trim_boundary_value)"
        [ -n "$forbidden" ] || continue
        if grep -qF "$forbidden" "$character_scan_file"; then
          fail "Knowledge_Leak: $character_name 提前知道认知边界外信息: $forbidden"
        fi
        ;;
      redline:*不会[：:]*)
        forbidden="$(printf '%s\n' "$line" | trim_boundary_value)"
        [ -n "$forbidden" ] || continue
        if grep -qF "$forbidden" "$character_scan_file"; then
          fail "Motivation_Drift: $character_name 违反行为红线: $forbidden"
        fi
        ;;
    esac
  done < "$invariant_file"
done < <(find "$character_invariants_dir" -type f -name '*.md' | sort)

echo "Chapter Stability Check PASS: chapter $CHAPTER"
