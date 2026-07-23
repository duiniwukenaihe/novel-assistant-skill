#!/bin/bash
# longform-daily-stability-audit.sh — run chapter and cross-chapter stability gates for a batch.
set -u

usage() {
  echo "Usage: $0 [--write] [--json] [--volume 第1卷] <book-dir> <start-chapter-id> <end-chapter-id>" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
single_chapter_check="$script_dir/chapter-stability-check.sh"
continuity_check="$script_dir/cross-chapter-continuity-audit.sh"
chapter_index_build="$script_dir/chapter-index-build.sh"
diagnostics_file="$(mktemp)"
report_file="$(mktemp)"
checks_file="$(mktemp)"
cleanup() {
  rm -f "$diagnostics_file" "$report_file" "$checks_file"
}
trap cleanup EXIT

emit() {
  echo "$@" >> "$report_file"
}

emit_file() {
  cat "$1" >> "$report_file"
}

add_diagnostic() {
  scope="$1"
  output="$2"
  {
    echo "#### $scope"
    echo
    echo '```text'
    printf '%s\n' "$output"
    echo '```'
    echo
  } >> "$diagnostics_file"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

extract_error_codes() {
  printf '%s\n' "$1" | grep -Eo '\b[A-Z][A-Za-z0-9_]*_[A-Za-z0-9_]+\b' | sort -u | paste -sd, - 2>/dev/null || true
}

add_check_result() {
  scope="$1"
  check_name="$2"
  result="$3"
  error_codes="${4:-}"
  printf '%s\t%s\t%s\t%s\n' "$scope" "$check_name" "$result" "$error_codes" >> "$checks_file"
}

emit_error_codes_json() {
  error_codes="$1"
  printf '['
  if [ -n "$error_codes" ]; then
    old_ifs="$IFS"
    IFS=','
    first_code=1
    for code in $error_codes; do
      if [ "$first_code" -eq 0 ]; then
        printf ','
      fi
      first_code=0
      printf '"%s"' "$(json_escape "$code")"
    done
    IFS="$old_ifs"
  fi
  printf ']'
}

emit_json_report() {
  audit_status="$1"
  failure_count="$2"
  report_rel_path="$3"
  printf '{"status":"%s","failures":%s,"start_chapter":"%s","end_chapter":"%s",' \
    "$audit_status" "$failure_count" "$start_chapter" "$end_chapter"
  if [ -n "$report_rel_path" ]; then
    printf '"report_path":"%s",' "$(json_escape "$report_rel_path")"
  else
    printf '"report_path":null,'
  fi
  printf '"checks":['
  first_check=1
  tab="$(printf '\t')"
  while IFS="$tab" read -r scope check_name result error_codes; do
    [ -n "$scope" ] || continue
    if [ "$first_check" -eq 0 ]; then
      printf ','
    fi
    first_check=0
    printf '{"scope":"%s","check":"%s","result":"%s","error_codes":' \
      "$(json_escape "$scope")" "$(json_escape "$check_name")" "$(json_escape "$result")"
    emit_error_codes_json "$error_codes"
    printf '}'
  done < "$checks_file"
  printf ']}\n'
}

write_report_artifact() {
  if [ -n "$volume" ]; then
    out_dir="$book_dir/追踪/稳定性审计/$volume"
    out_rel="追踪/稳定性审计/${volume}/日更_第${start_chapter}章_to_第${end_chapter}章.md"
  else
    out_dir="$book_dir/追踪/稳定性审计"
    out_rel="追踪/稳定性审计/日更_第${start_chapter}章_to_第${end_chapter}章.md"
  fi
  mkdir -p "$out_dir"
  out_file="$out_dir/日更_第${start_chapter}章_to_第${end_chapter}章.md"
  cp "$report_file" "$out_file"
  printf '%s\n' "$out_rel"
}

write_mode=0
json_mode=0
volume=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --write)
      write_mode=1
      shift
      ;;
    --json)
      json_mode=1
      shift
      ;;
    --volume)
      volume="${2:-}"
      [ -n "$volume" ] || fail "--volume requires a value"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi

[ -d "$1" ] || fail "book dir not found: $1"
[ -x "$single_chapter_check" ] || fail "single chapter checker missing: $single_chapter_check"
[ -x "$continuity_check" ] || fail "continuity checker missing: $continuity_check"
[ -x "$chapter_index_build" ] || fail "chapter index builder missing: $chapter_index_build"

book_dir="$(cd "$1" && pwd)"
start_num="$((10#$2))"
end_num="$((10#$3))"

[ "$start_num" -le "$end_num" ] || fail "start chapter must be <= end chapter"

start_chapter="$(printf '%03d' "$start_num")"
end_chapter="$(printf '%03d' "$end_num")"
failures=0

if [ "$write_mode" -eq 1 ]; then
  bash "$chapter_index_build" --write "$book_dir" >/dev/null
fi

emit "## Longform Daily Stability Audit"
emit
if [ -n "$volume" ]; then
  emit "- 卷：$volume"
fi
emit "- 章节范围：第 ${start_chapter} 章 - 第 ${end_chapter} 章"
emit
emit "### Checks"
emit "| scope | check | result |"
emit "|---|---|---|"

chapter="$start_num"
while [ "$chapter" -le "$end_num" ]; do
  chapter_id="$(printf '%03d' "$chapter")"
  if [ -n "$volume" ]; then
    check_output="$(bash "$single_chapter_check" --volume "$volume" "$book_dir" "$chapter_id" 2>&1)"
  else
    check_output="$(bash "$single_chapter_check" "$book_dir" "$chapter_id" 2>&1)"
  fi
  check_status="$?"
  if [ "$check_status" -eq 0 ]; then
    emit "| 第 ${chapter_id} 章 | 单章稳定性 | PASS |"
    add_check_result "第 ${chapter_id} 章" "单章稳定性" "PASS" ""
  else
    emit "| 第 ${chapter_id} 章 | 单章稳定性 | FAIL |"
    add_diagnostic "第 ${chapter_id} 章 | 单章稳定性" "$check_output"
    add_check_result "第 ${chapter_id} 章" "单章稳定性" "FAIL" "$(extract_error_codes "$check_output")"
    failures=$((failures + 1))
  fi

  if [ "$chapter" -gt "$start_num" ]; then
    prev_id="$(printf '%03d' "$((chapter - 1))")"
    if [ -n "$volume" ]; then
      continuity_output="$(bash "$continuity_check" --volume "$volume" "$book_dir" "$prev_id" "$chapter_id" 2>&1)"
    else
      continuity_output="$(bash "$continuity_check" "$book_dir" "$prev_id" "$chapter_id" 2>&1)"
    fi
    continuity_status="$?"
    if [ "$continuity_status" -eq 0 ]; then
      emit "| 第 ${prev_id} 章 -> 第 ${chapter_id} 章 | 跨章连续性 | PASS |"
      add_check_result "第 ${prev_id} 章 -> 第 ${chapter_id} 章" "跨章连续性" "PASS" ""
    else
      emit "| 第 ${prev_id} 章 -> 第 ${chapter_id} 章 | 跨章连续性 | FAIL |"
      add_diagnostic "第 ${prev_id} 章 -> 第 ${chapter_id} 章 | 跨章连续性" "$continuity_output"
      add_check_result "第 ${prev_id} 章 -> 第 ${chapter_id} 章" "跨章连续性" "FAIL" "$(extract_error_codes "$continuity_output")"
      failures=$((failures + 1))
    fi
  fi

  chapter=$((chapter + 1))
done

emit
emit "### 结论"
if [ "$failures" -eq 0 ]; then
  emit "- Audit: PASS"
  report_rel_path=""
  if [ "$write_mode" -eq 1 ]; then
    report_rel_path="$(write_report_artifact)"
  fi
  if [ "$json_mode" -eq 1 ]; then
    emit_json_report "PASS" "$failures" "$report_rel_path"
  elif [ "$write_mode" -eq 1 ]; then
    echo "WROTE: $report_rel_path"
  else
    cat "$report_file"
  fi
  exit 0
fi

emit "- Audit: FAIL"
emit "- failures: $failures"
if [ -s "$diagnostics_file" ]; then
  emit
  emit "### Diagnostics"
  emit_file "$diagnostics_file"
fi
report_rel_path=""
if [ "$write_mode" -eq 1 ]; then
  report_rel_path="$(write_report_artifact)"
fi
if [ "$json_mode" -eq 1 ]; then
  emit_json_report "FAIL" "$failures" "$report_rel_path"
elif [ "$write_mode" -eq 1 ]; then
  echo "WROTE: $report_rel_path"
else
  cat "$report_file"
fi
exit 1
