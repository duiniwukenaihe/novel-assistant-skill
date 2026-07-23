#!/bin/bash
# check-longform-stability-fixture.sh — legacy wrapper for the generic chapter checker.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
book_dir="${1:-}"
chapter="${2:-001}"

bash "$script_dir/chapter-stability-check.sh" "$book_dir" "$chapter" >/dev/null
chapter_num="$((10#$chapter))"
printf 'Longform stability fixture PASS: chapter %03d\n' "$chapter_num"
