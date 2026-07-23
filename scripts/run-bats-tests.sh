#!/bin/bash
# run-bats-tests.sh — run repo .bats tests with bats-core when available,
# falling back to the repo-local lightweight runner for simple local smoke tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -eq 0 ]; then
  set -- "$REPO_ROOT"/tests/*.bats
fi

if command -v bats >/dev/null 2>&1; then
  exec bats "$@"
fi

echo "bats not found; using scripts/run-bats-lite.sh fallback" >&2
exec bash "$SCRIPT_DIR/run-bats-lite.sh" "$@"
