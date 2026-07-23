#!/bin/bash
# revision-stability-recheck.sh — run post-revision impact evidence and stability repair loop.
set -u

usage() {
  echo "Usage: $0 [--write] [--json] [--volume 第1卷] <book-dir> <request-file> <start-chapter-id> <end-chapter-id>" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

json_escape() {
  node -e 'const fs = require("fs"); process.stdout.write(JSON.stringify(fs.readFileSync(0, "utf8")));'
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
impact_script="$script_dir/revision-impact-scan.sh"
loop_script="$script_dir/stability-repair-loop.sh"
prompt_script="$script_dir/stability-agent-dispatch-prompt.sh"

write_report=0
json_mode=0
volume=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --write)
      write_report=1
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

if [ "$#" -ne 4 ]; then
  usage
  exit 2
fi

[ -d "$1" ] || fail "book dir not found: $1"
[ -f "$2" ] || fail "request file not found: $2"
[ -x "$impact_script" ] || fail "revision impact scanner missing: $impact_script"
[ -x "$loop_script" ] || fail "stability repair loop missing: $loop_script"
[ -x "$prompt_script" ] || fail "agent dispatch prompt missing: $prompt_script"
command -v node >/dev/null 2>&1 || fail "node is required to build json output"

book_dir="$(cd "$1" && pwd)"
request_file="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
start_chapter="$(printf '%03d' "$((10#$3))")"
end_chapter="$(printf '%03d' "$((10#$4))")"
if [ -n "$volume" ]; then
  report_rel="追踪/稳定性审计/${volume}/回炉复检_第${start_chapter}章_to_第${end_chapter}章.md"
else
  report_rel="追踪/稳定性审计/回炉复检_第${start_chapter}章_to_第${end_chapter}章.md"
fi
report_abs="$book_dir/$report_rel"
if [ -n "$volume" ]; then
  loop_report_rel="追踪/稳定性审计/${volume}/修复闭环_第${start_chapter}章_to_第${end_chapter}章.md"
else
  loop_report_rel="追踪/稳定性审计/修复闭环_第${start_chapter}章_to_第${end_chapter}章.md"
fi
loop_report_abs="$book_dir/$loop_report_rel"

impact_output="$(bash "$impact_script" "$book_dir" "$request_file")" || exit "$?"

set +e
if [ -n "$volume" ]; then
  loop_output="$(bash "$loop_script" --write --volume "$volume" "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
else
  loop_output="$(bash "$loop_script" --write "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
fi
loop_status="$?"
if [ -n "$volume" ]; then
  prompt_json="$(bash "$prompt_script" --json --volume "$volume" "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
else
  prompt_json="$(bash "$prompt_script" --json "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
fi
prompt_status="$?"
if [ -n "$volume" ]; then
  prompt_output="$(bash "$prompt_script" --volume "$volume" "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
else
  prompt_output="$(bash "$prompt_script" "$book_dir" "$start_chapter" "$end_chapter" 2>&1)"
fi
set -e

if [ -f "$loop_report_abs" ]; then
  loop_markdown="$(cat "$loop_report_abs")"
else
  loop_markdown="$loop_output"
fi

report_text="$(
  printf '## Revision Stability Recheck\n\n'
  printf '### Revision Impact Evidence\n\n'
  printf '%s\n\n' "$impact_output"
  printf '### Post-edit Stability Repair Loop\n\n'
  printf '%s\n\n' "$loop_markdown"
  printf '### Agent Dispatch\n\n'
  printf '%s\n' "$prompt_output"
)"

if [ "$write_report" -eq 1 ]; then
  mkdir -p "$(dirname "$report_abs")"
  printf '%s\n' "$report_text" > "$report_abs"
fi

if [ "$json_mode" -eq 1 ]; then
  status="$(printf '%s' "$prompt_json" | node -e '
const fs = require("fs");
try {
  const data = JSON.parse(fs.readFileSync(0, "utf8"));
  process.stdout.write(data.status || "UNKNOWN");
} catch {
  process.stdout.write("UNKNOWN");
}
')"
  current_owner="$(printf '%s' "$prompt_json" | node -e '
const fs = require("fs");
try {
  const data = JSON.parse(fs.readFileSync(0, "utf8"));
  process.stdout.write(data.current_owner || "");
} catch {
  process.stdout.write("");
}
')"
  current_action="$(printf '%s' "$prompt_json" | node -e '
const fs = require("fs");
try {
  const data = JSON.parse(fs.readFileSync(0, "utf8"));
  process.stdout.write(JSON.stringify(data.current_action || null));
} catch {
  process.stdout.write("null");
}
')"
  agent_call="$(printf '%s' "$prompt_json" | node -e '
const fs = require("fs");
try {
  const data = JSON.parse(fs.readFileSync(0, "utf8"));
  process.stdout.write(data.agent_call || "");
} catch {
  process.stdout.write("");
}
')"
  printf '{'
  printf '"status":%s,' "$(printf '%s' "$status" | json_escape)"
  if [ -n "$volume" ]; then
    printf '"volume":%s,' "$(printf '%s' "$volume" | json_escape)"
  else
    printf '"volume":null,'
  fi
  printf '"current_owner":%s,' "$(printf '%s' "$current_owner" | json_escape)"
  printf '"current_action":%s,' "$current_action"
  printf '"impact_report":%s,' "$(printf '%s' "$impact_output" | json_escape)"
  printf '"repair_loop_report":%s,' "$(printf '%s' "$loop_markdown" | json_escape)"
  printf '"agent_dispatch":%s,' "$prompt_json"
  printf '"agent_call":%s,' "$(printf '%s' "$agent_call" | json_escape)"
  if [ "$write_report" -eq 1 ]; then
    printf '"revision_report_path":%s' "$(printf '%s' "$report_rel" | json_escape)"
  else
    printf '"revision_report_path":null'
  fi
  printf '}\n'
else
  printf '%s\n' "$report_text"
  if [ "$write_report" -eq 1 ]; then
    printf 'WROTE: %s\n' "$report_rel"
  fi
fi

if [ "$prompt_status" -eq 0 ] && [ "$loop_status" -eq 0 ]; then
  exit 0
fi
exit 1
