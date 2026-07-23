#!/bin/bash
# check-upstream.sh — semi-automatic upstream history/tag comparison report.
#
# It fetches the upstream branch into refs/remotes/upstream-check/<branch>
# and compares commit history plus tags. It never merges, cherry-picks, or
# creates local tags.

set -euo pipefail

DEFAULT_REPO="https://github.com/worldwonderer/oh-story-claudecode.git"
DEFAULT_BRANCH="main"

UPSTREAM_REPO="$DEFAULT_REPO"
BRANCH="$DEFAULT_BRANCH"
WRITE_REPORT=false
REPORT_DIR="reports/upstream"
MAX_COMMITS=80

usage() {
  cat <<'USAGE'
Usage: bash scripts/check-upstream.sh [options]

Options:
  --repo <url>         Upstream git URL. Default: https://github.com/worldwonderer/oh-story-claudecode.git
  --branch <name>      Upstream branch. Default: main
  --write              Write markdown report to reports/upstream/
  --report-dir <dir>   Report directory when --write is used. Default: reports/upstream
  --max-commits <n>    Max commits to print per side. Default: 80
  -h, --help           Show this help

What it does:
  1. Fetches upstream branch into refs/remotes/upstream-check/<branch>
  2. Lists upstream-only commits and local-only commits
  3. Compares upstream tags against local tags
  4. Prints a markdown report, optionally saved with --write

It does not merge, cherry-pick, push, or create tags.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      UPSTREAM_REPO="${2:-}"
      [ -n "$UPSTREAM_REPO" ] || { echo "Error: --repo requires a value" >&2; exit 2; }
      shift 2
      ;;
    --branch)
      BRANCH="${2:-}"
      [ -n "$BRANCH" ] || { echo "Error: --branch requires a value" >&2; exit 2; }
      shift 2
      ;;
    --write)
      WRITE_REPORT=true
      shift
      ;;
    --report-dir)
      REPORT_DIR="${2:-}"
      [ -n "$REPORT_DIR" ] || { echo "Error: --report-dir requires a value" >&2; exit 2; }
      shift 2
      ;;
    --max-commits)
      MAX_COMMITS="${2:-}"
      case "$MAX_COMMITS" in
        ''|*[!0-9]*) echo "Error: --max-commits must be a positive integer" >&2; exit 2 ;;
      esac
      [ "$MAX_COMMITS" -gt 0 ] || { echo "Error: --max-commits must be > 0" >&2; exit 2; }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "Error: not in a git repository" >&2
  exit 1
fi

cd "$REPO_ROOT"

SAFE_BRANCH="$(printf '%s' "$BRANCH" | tr '/[:space:]' '--')"
UPSTREAM_REF="refs/remotes/upstream-check/$SAFE_BRANCH"
NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
REPORT_STAMP="$(date -u +"%Y%m%d-%H%M%S")"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

fetch_upstream_branch() {
  git fetch --quiet --no-tags "$UPSTREAM_REPO" "+refs/heads/$BRANCH:$UPSTREAM_REF"
}

write_local_tags() {
  git for-each-ref --format='%(refname:strip=2)' refs/tags | sort | while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    sha="$(git rev-parse "$tag^{}" 2>/dev/null || true)"
    [ -n "$sha" ] && printf '%s %s\n' "$tag" "$sha"
  done
}

write_upstream_tags() {
  git ls-remote --tags "$UPSTREAM_REPO" 'refs/tags/*' | awk '
    $2 ~ /\^\{\}$/ {
      name = $2
      sub(/^refs\/tags\//, "", name)
      sub(/\^\{\}$/, "", name)
      peeled[name] = $1
      next
    }
    {
      name = $2
      sub(/^refs\/tags\//, "", name)
      direct[name] = $1
    }
    END {
      for (name in direct) {
        if (name in peeled) {
          print name " " peeled[name]
        } else {
          print name " " direct[name]
        }
      }
    }
  ' | sort
}

section_commit_list() {
  local title="$1"
  local range="$2"
  local count="$3"
  local empty_text="$4"

  printf '## %s\n\n' "$title"
  printf 'Count: `%s`\n\n' "$count"
  if [ "$count" -eq 0 ]; then
    printf '%s\n\n' "$empty_text"
    return
  fi

  git log --date=short --pretty=format:'- `%h` %ad %s' -n "$MAX_COMMITS" "$range"
  printf '\n\n'
  if [ "$count" -gt "$MAX_COMMITS" ]; then
    printf '> Only first %s commits shown. Increase `--max-commits` for more.\n\n' "$MAX_COMMITS"
  fi
}

format_tag_table() {
  local file="$1"
  local empty_text="$2"

  if [ ! -s "$file" ]; then
    printf '%s\n\n' "$empty_text"
    return
  fi

  printf '| Tag | Local | Upstream |\n'
  printf '|---|---|---|\n'
  while IFS='|' read -r tag local_sha upstream_sha; do
    printf '| `%s` | `%s` | `%s` |\n' "$tag" "$local_sha" "$upstream_sha"
  done < "$file"
  printf '\n'
}

map_internal_bundle_target() {
  local file="$1"
  case "$file" in
    skills/novel-assistant/*)
      printf '%s' "$file"
      ;;
    skills/oh-story/*)
      printf 'skills/novel-assistant/%s' "${file#skills/oh-story/}"
      ;;
    skills/story/*|skills/story-*/*|skills/browser-cdp/*)
      printf 'skills/novel-assistant/references/internal-skills/%s' "${file#skills/}"
      ;;
    src/internal-skills/story/*|src/internal-skills/story-*/*|src/internal-skills/browser-cdp/*)
      printf 'skills/novel-assistant/references/internal-skills/%s' "${file#src/internal-skills/}"
      ;;
    scripts/*)
      printf 'skills/novel-assistant/%s' "$file"
      ;;
    *)
      printf 'manual-triage'
      ;;
  esac
}

map_source_target() {
  local file="$1"
  case "$file" in
    skills/novel-assistant/references/internal-skills/*)
      printf 'src/internal-skills/%s' "${file#skills/novel-assistant/references/internal-skills/}"
      ;;
    skills/novel-assistant/scripts/*)
      printf 'scripts/%s' "${file#skills/novel-assistant/scripts/}"
      ;;
    skills/oh-story/references/internal-skills/*)
      printf 'src/internal-skills/%s' "${file#skills/oh-story/references/internal-skills/}"
      ;;
    skills/oh-story/scripts/*)
      printf 'scripts/%s' "${file#skills/oh-story/scripts/}"
      ;;
    *)
      printf '%s' "$file"
      ;;
  esac
}

write_backport_target_mapping() {
  local range="$1"
  local count="$2"

  printf '## Novel Assistant Backport Target Mapping\n\n'
  printf 'This project exposes only `skills/novel-assistant` to users. Upstream `story-*` changes should be reviewed against the generated internal target under `skills/novel-assistant/references/internal-skills/`.\n\n'
  printf '> Current repository layout treats `src/internal-skills/story-*` as canonical source modules. Apply changes to the source target first, then run `bash scripts/build-oh-story-bundle.sh`. Direct edits to generated internal targets can be overwritten by the next bundle build.\n\n'

  if [ "$count" -eq 0 ]; then
    printf 'No upstream-only file changes to map.\n\n'
    return
  fi

  printf '| Status | Upstream file | Novel-assistant internal target | Current canonical source target | Mode |\n'
  printf '|---|---|---|---|---|\n'
  git diff --name-status "$range" | while IFS=$'\t' read -r status path1 path2 _rest; do
    file="$path1"
    case "$status" in
      R*|C*) file="$path2" ;;
    esac
    [ -n "$file" ] || continue
    internal_target="$(map_internal_bundle_target "$file")"
    source_target="$(map_source_target "$internal_target")"
    mode="manual-triage"
    if [ "$internal_target" != "manual-triage" ]; then
      mode="current-source-and-generated-bundle"
    fi
    printf '| `%s` | `%s` | `%s` | `%s` | `%s` |\n' "$status" "$file" "$internal_target" "$source_target" "$mode"
  done
  printf '\n'
}

fetch_upstream_branch

LOCAL_HEAD="$(git rev-parse HEAD)"
LOCAL_BRANCH="$(git branch --show-current 2>/dev/null || true)"
UPSTREAM_HEAD="$(git rev-parse "$UPSTREAM_REF")"
MERGE_BASE="$(git merge-base HEAD "$UPSTREAM_REF" 2>/dev/null || true)"

UPSTREAM_ONLY_COUNT="$(git rev-list --count "HEAD..$UPSTREAM_REF")"
LOCAL_ONLY_COUNT="$(git rev-list --count "$UPSTREAM_REF..HEAD")"

RELATION="diverged"
if git merge-base --is-ancestor "$UPSTREAM_REF" HEAD 2>/dev/null; then
  RELATION="local_contains_upstream"
elif git merge-base --is-ancestor HEAD "$UPSTREAM_REF" 2>/dev/null; then
  RELATION="local_behind_upstream"
fi

LOCAL_TAGS="$tmp_dir/local-tags.txt"
UPSTREAM_TAGS="$tmp_dir/upstream-tags.txt"
MISSING_TAGS="$tmp_dir/missing-tags.txt"
EXTRA_TAGS="$tmp_dir/extra-tags.txt"
DIVERGED_TAGS="$tmp_dir/diverged-tags.txt"

write_local_tags > "$LOCAL_TAGS"
write_upstream_tags > "$UPSTREAM_TAGS"

awk '
  NR == FNR { local[$1] = $2; next }
  !($1 in local) { print $1 "|missing|" $2 }
' "$LOCAL_TAGS" "$UPSTREAM_TAGS" > "$MISSING_TAGS"

awk '
  NR == FNR { upstream[$1] = $2; next }
  !($1 in upstream) { print $1 "|" $2 "|missing" }
' "$UPSTREAM_TAGS" "$LOCAL_TAGS" > "$EXTRA_TAGS"

awk '
  NR == FNR { local[$1] = $2; next }
  ($1 in local) && local[$1] != $2 { print $1 "|" local[$1] "|" $2 }
' "$LOCAL_TAGS" "$UPSTREAM_TAGS" > "$DIVERGED_TAGS"

MISSING_TAG_COUNT="$(wc -l < "$MISSING_TAGS" | tr -d ' ')"
EXTRA_TAG_COUNT="$(wc -l < "$EXTRA_TAGS" | tr -d ' ')"
DIVERGED_TAG_COUNT="$(wc -l < "$DIVERGED_TAGS" | tr -d ' ')"
LOCAL_TAG_COUNT="$(wc -l < "$LOCAL_TAGS" | tr -d ' ')"
UPSTREAM_TAG_COUNT="$(wc -l < "$UPSTREAM_TAGS" | tr -d ' ')"

REPORT_FILE="$tmp_dir/report.md"

{
  printf '# Upstream Check Report\n\n'
  printf '%s\n' "- Generated at: \`$NOW_UTC\`"
  printf '%s\n' "- Local branch: \`${LOCAL_BRANCH:-detached}\`"
  printf '%s\n' "- Local HEAD: \`$LOCAL_HEAD\`"
  printf '%s\n' "- Upstream repo: \`$UPSTREAM_REPO\`"
  printf '%s\n' "- Upstream branch: \`$BRANCH\`"
  printf '%s\n' "- Upstream HEAD: \`$UPSTREAM_HEAD\`"
  printf '%s\n' "- Merge base: \`${MERGE_BASE:-none}\`"
  printf '%s\n\n' "- Relation: \`$RELATION\`"

  printf '## Summary\n\n'
  printf '| Metric | Count |\n'
  printf '|---|---:|\n'
  printf '| Upstream-only commits | %s |\n' "$UPSTREAM_ONLY_COUNT"
  printf '| Local-only commits | %s |\n' "$LOCAL_ONLY_COUNT"
  printf '| Upstream tags | %s |\n' "$UPSTREAM_TAG_COUNT"
  printf '| Local tags | %s |\n' "$LOCAL_TAG_COUNT"
  printf '| Missing upstream tags locally | %s |\n' "$MISSING_TAG_COUNT"
  printf '| Extra local tags | %s |\n' "$EXTRA_TAG_COUNT"
  printf '| Diverged same-name tags | %s |\n\n' "$DIVERGED_TAG_COUNT"

  section_commit_list "Upstream-Only Commits" "HEAD..$UPSTREAM_REF" "$UPSTREAM_ONLY_COUNT" "No upstream-only commits. Local branch already contains upstream branch history."
  section_commit_list "Local-Only Commits" "$UPSTREAM_REF..HEAD" "$LOCAL_ONLY_COUNT" "No local-only commits."

  printf '## Upstream Changed Files Since Merge Base\n\n'
  if [ -n "$MERGE_BASE" ] && [ "$UPSTREAM_ONLY_COUNT" -gt 0 ]; then
    git diff --name-status "$MERGE_BASE..$UPSTREAM_REF" | sed 's/^/- `/' | sed 's/$/`/'
    printf '\n\n'
  else
    printf 'No upstream-only file changes to review.\n\n'
  fi

  if [ -n "$MERGE_BASE" ]; then
    write_backport_target_mapping "$MERGE_BASE..$UPSTREAM_REF" "$UPSTREAM_ONLY_COUNT"
  else
    printf '## Novel Assistant Backport Target Mapping\n\n'
    printf 'No merge base found; target mapping requires manual triage.\n\n'
  fi

  printf '## Tag Comparison\n\n'
  printf '### Missing Upstream Tags Locally\n\n'
  format_tag_table "$MISSING_TAGS" "No missing upstream tags."
  printf '### Extra Local Tags\n\n'
  format_tag_table "$EXTRA_TAGS" "No extra local tags."
  printf '### Diverged Tags\n\n'
  format_tag_table "$DIVERGED_TAGS" "No diverged same-name tags."

  printf '## Backport Triage Template\n\n'
  if [ "$UPSTREAM_ONLY_COUNT" -eq 0 ]; then
    printf 'No upstream-only commits require triage.\n\n'
  else
    printf '| Commit | Decision | Reason | Local action |\n'
    printf '|---|---|---|---|\n'
    git log --pretty=format:'| `%h` %s | TODO: absorb / skip / already-covered | TODO | TODO |' -n "$MAX_COMMITS" "HEAD..$UPSTREAM_REF"
    printf '\n\n'
  fi
} > "$REPORT_FILE"

if [ "$WRITE_REPORT" = true ]; then
  mkdir -p "$REPORT_DIR"
  out="$REPORT_DIR/${REPORT_STAMP}-upstream-check.md"
  cp "$REPORT_FILE" "$out"
  cat "$REPORT_FILE"
  printf '\nReport written: %s\n' "$out"
else
  cat "$REPORT_FILE"
fi
