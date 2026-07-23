#!/usr/bin/env bash
set -euo pipefail

PUBLIC_REPO_URL="https://github.com/duiniwukenaihe/novel-assistant-skill.git"
EXPECTED_BRANCH="github/public-release"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW_CURRENT_BRANCH=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/prepare-github-public-release.sh [--allow-current-branch]

Prepare the GitHub public release branch after the branch has been sanitized.

This script does not delete private assets by itself. It assumes the current
branch is the sanitized public branch, then:

1. Rebuilds skills/novel-assistant with the public GitHub update source.
2. Runs public-release-audit.js.
3. Runs git diff --check.

Default expected branch: github/public-release
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-current-branch)
      ALLOW_CURRENT_BRANCH=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

branch="$(git -C "$REPO_ROOT" branch --show-current)"
if [ "$ALLOW_CURRENT_BRANCH" -ne 1 ] && [ "$branch" != "$EXPECTED_BRANCH" ]; then
  echo "Refusing to prepare GitHub public release from branch: $branch" >&2
  echo "Switch to $EXPECTED_BRANCH, or pass --allow-current-branch for a dry local check." >&2
  exit 2
fi

if [ "$branch" = "$EXPECTED_BRANCH" ]; then
  node "$REPO_ROOT/scripts/sanitize-github-public-tree.js" --repo-root "$REPO_ROOT" --write --json
else
  echo "Skipping sanitizer on non-release branch: $branch" >&2
  echo "Use publish-github-public-branch.sh for isolated branch generation." >&2
fi

NOVEL_ASSISTANT_UPDATE_SOURCE_URL="$PUBLIC_REPO_URL" \
NOVEL_ASSISTANT_INCLUDE_PRIVATE=0 \
  bash "$REPO_ROOT/scripts/build-oh-story-bundle.sh"

node "$REPO_ROOT/scripts/public-release-audit.js" --repo-root "$REPO_ROOT" --json
git -C "$REPO_ROOT" diff --check

echo "GitHub public release checks passed for $branch"
