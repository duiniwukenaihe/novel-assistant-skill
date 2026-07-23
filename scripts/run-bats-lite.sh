#!/bin/bash
# run-bats-lite.sh — minimal local fallback for simple .bats tests.
#
# This is not a full bats-core replacement. It supports the subset used by this
# repo: setup/teardown functions, @test "name" { ... }, BATS_TEST_DIRNAME, and
# ordinary shell assertions.
set -u

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 tests/file.bats [tests/other.bats ...]" >&2
  exit 2
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

total=0
failed=0

run() {
  set +e
  output="$("$@" 2>&1)"
  status="$?"
  set -e
  IFS=$'\n' read -r -d '' -a lines <<< "${output}"$'\0' || true
  return 0
}

for bats_file in "$@"; do
  if [ ! -f "$bats_file" ]; then
    echo "not ok - missing file: $bats_file"
    failed=$((failed + 1))
    continue
  fi

  export BATS_TEST_FILENAME="$bats_file"
  export BATS_TEST_DIRNAME
  BATS_TEST_DIRNAME="$(cd "$(dirname "$bats_file")" && pwd)"

  generated="$tmp_dir/$(basename "$bats_file").sh"
  awk '
    BEGIN {
      count = 0
      heredoc_end = ""
      print "__BATS_LITE_COUNT=0"
    }
    heredoc_end != "" {
      print
      if ($0 == heredoc_end) {
        heredoc_end = ""
      }
      next
    }
    /^@test[[:space:]]+"[^"]+"[[:space:]]*\{/ {
      line = $0
      sub(/^@test[[:space:]]+"/, "", line)
      sub(/"[[:space:]]*\{[[:space:]]*$/, "", line)
      count++
      printf("__BATS_LITE_COUNT=%d\n", count)
      printf("__BATS_LITE_NAMES[%d]=%s\n", count, shell_quote(line))
      printf("__bats_lite_test_%d() {\n", count)
      next
    }
    /^bats_test_function[[:space:]]+--description[[:space:]]+/ {
      line = $0
      desc = line
      sub(/^bats_test_function[[:space:]]+--description[[:space:]]+/, "", desc)
      sub(/[[:space:]]+--tags[[:space:]].*$/, "", desc)
      gsub(/\\ /, " ", desc)

      fn = line
      sub(/^.*[[:space:]]--[[:space:]]+/, "", fn)
      sub(/;.*/, "", fn)

      count++
      printf("__BATS_LITE_COUNT=%d\n", count)
      printf("__BATS_LITE_NAMES[%d]=%s\n", count, shell_quote(desc))
      printf("__bats_lite_test_%d() {\n  %s\n}\n", count, fn)

      def = line
      sub(/^.*;/, "", def)
      print def
      heredoc_end = detect_heredoc(def)
      next
    }
    {
      print
      heredoc_end = detect_heredoc($0)
    }
    function detect_heredoc(line, token) {
      if (match(line, /<<-?[[:space:]]*'\''[A-Za-z_][A-Za-z0-9_]*'\''/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*'\''/, "", token)
        sub(/'\''$/, "", token)
        return token
      }
      if (match(line, /<<-?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*/, "", token)
        return token
      }
      return ""
    }
    function shell_quote(s, out, i, c) {
      out = "'\''"
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "'\''") {
          out = out "'\''\\'\'''\''"
        } else {
          out = out c
        }
      }
      out = out "'\''"
      return out
    }
  ' "$bats_file" > "$generated"

  # shellcheck source=/dev/null
  if ! source "$generated"; then
    echo "not ok - could not load $bats_file"
    failed=$((failed + 1))
    continue
  fi

  i=1
  while [ "$i" -le "${__BATS_LITE_COUNT:-0}" ]; do
    total=$((total + 1))
    name="${__BATS_LITE_NAMES[$i]}"
    fn="__bats_lite_test_$i"
    test_tmp_dir="$tmp_dir/test-$total"
    mkdir -p "$test_tmp_dir"
    (
      set -e
      export BATS_TEST_TMPDIR="$test_tmp_dir"
      teardown_on_exit() {
        test_status="$?"
        teardown_status=0
        if declare -F teardown >/dev/null 2>&1; then
          set +e
          teardown
          teardown_status="$?"
          set -e
        fi
        if [ "$test_status" -ne 0 ]; then
          return "$test_status"
        fi
        return "$teardown_status"
      }
      trap teardown_on_exit EXIT
      if declare -F setup >/dev/null 2>&1; then
        setup
      fi
      "$fn"
    )
    status="$?"
    if [ "$status" -eq 0 ]; then
      echo "ok $total - $name"
    else
      echo "not ok $total - $name"
      failed=$((failed + 1))
    fi
    i=$((i + 1))
  done

  unset __BATS_LITE_COUNT
  unset __BATS_LITE_NAMES
  unset -f setup teardown 2>/dev/null || true
  i=1
  while declare -F "__bats_lite_test_$i" >/dev/null 2>&1; do
    unset -f "__bats_lite_test_$i"
    i=$((i + 1))
  done
done

echo "1..$total"
if [ "$failed" -gt 0 ]; then
  echo "Bats lite: $failed failed / $total total" >&2
  exit 1
fi
echo "Bats lite: $total passed"
