#!/usr/bin/env bash
set -euo pipefail

PUBLIC_REPO_URL="https://github.com/duiniwukenaihe/novel-assistant-skill.git"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_REF="main"
TARGET_BRANCH="github/public-release"
REMOTE="github"
WORKTREE_DIR=""
SOURCE_WORKTREE_DIR=""
KEEP_WORKTREE=0
COMMIT_CHANGES=0
PUSH_BRANCH=0
ALLOW_DIRTY_SOURCE=0
SKIP_RUNTIME_VERIFY=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/publish-github-public-branch.sh [options]

Create or refresh the sanitized GitHub public release branch in an isolated
git worktree. The script keeps main untouched, removes private skill assets and
private workflow overlays, rebuilds the public bundle, audits, and optionally
commits/pushes the result.

Options:
  --source-ref <ref>       Source ref to publish from (default: main)
  --branch <name>          Public branch name (default: github/public-release)
  --remote <name>          Remote to push to (default: github)
  --worktree-dir <dir>     Keep/use a specific worktree directory
  --keep-worktree          Do not remove the temporary worktree at the end
  --commit                 Commit sanitized changes on the public branch
  --push                   Push HEAD to <remote>/<branch> (requires --commit)
  --allow-dirty-source     Allow dirty source checkout; only committed ref is used
  --skip-runtime-verify    Skip public runtime smoke checks (not recommended)
  -h, --help               Show this help

Typical:
  node scripts/na-dev.js publish-public --source-ref main --commit --push
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-ref)
      SOURCE_REF="${2:?missing --source-ref value}"
      shift 2
      ;;
    --branch)
      TARGET_BRANCH="${2:?missing --branch value}"
      shift 2
      ;;
    --remote)
      REMOTE="${2:?missing --remote value}"
      shift 2
      ;;
    --worktree-dir)
      WORKTREE_DIR="$(cd "$(dirname "${2:?missing --worktree-dir value}")" && pwd)/$(basename "$2")"
      shift 2
      ;;
    --keep-worktree)
      KEEP_WORKTREE=1
      shift
      ;;
    --commit)
      COMMIT_CHANGES=1
      shift
      ;;
    --push)
      PUSH_BRANCH=1
      shift
      ;;
    --allow-dirty-source)
      ALLOW_DIRTY_SOURCE=1
      shift
      ;;
    --skip-runtime-verify)
      SKIP_RUNTIME_VERIFY=1
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

if [ "$PUSH_BRANCH" -eq 1 ] && [ "$COMMIT_CHANGES" -ne 1 ]; then
  echo "Refusing --push without --commit; uncommitted worktree changes cannot be pushed." >&2
  exit 2
fi

if [ "$ALLOW_DIRTY_SOURCE" -ne 1 ] && [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  echo "Source checkout is dirty. Commit/stash first, or pass --allow-dirty-source knowing only $SOURCE_REF is published." >&2
  exit 2
fi

if [ -z "$WORKTREE_DIR" ]; then
  WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/novel-assistant-public.XXXXXX")"
  rm -rf "$WORKTREE_DIR"
fi

SOURCE_WORKTREE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/novel-assistant-public-source.XXXXXX")"
rm -rf "$SOURCE_WORKTREE_DIR"

cleanup() {
  if [ -e "$SOURCE_WORKTREE_DIR/.git" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$SOURCE_WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
  if [ "$KEEP_WORKTREE" -ne 1 ] && [ -e "$WORKTREE_DIR/.git" ]; then
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ -e "$WORKTREE_DIR" ]; then
  echo "Worktree dir already exists: $WORKTREE_DIR" >&2
  echo "Remove it or choose another --worktree-dir." >&2
  exit 2
fi

if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/$REMOTE/$TARGET_BRANCH"; then
    git -C "$REPO_ROOT" branch "$TARGET_BRANCH" "$REMOTE/$TARGET_BRANCH"
  else
    echo "Public history baseline not found: $TARGET_BRANCH or $REMOTE/$TARGET_BRANCH" >&2
    echo "Create the initial sanitized public branch explicitly before publishing." >&2
    exit 2
  fi
fi

# Build the candidate from the private source ref in an isolated detached
# worktree. The public worktree starts from the existing public branch so its
# ancestry never inherits private development commits.
git -C "$REPO_ROOT" worktree add --detach "$SOURCE_WORKTREE_DIR" "$SOURCE_REF"
git -C "$REPO_ROOT" worktree add "$WORKTREE_DIR" "$TARGET_BRANCH"

node "$SOURCE_WORKTREE_DIR/scripts/sanitize-github-public-tree.js" --repo-root "$SOURCE_WORKTREE_DIR" --write --json

NOVEL_ASSISTANT_UPDATE_SOURCE_URL="$PUBLIC_REPO_URL" \
NOVEL_ASSISTANT_UPDATE_BRANCH="main" \
NOVEL_ASSISTANT_INCLUDE_PRIVATE=0 \
  bash "$SOURCE_WORKTREE_DIR/scripts/build-oh-story-bundle.sh"

node "$SOURCE_WORKTREE_DIR/scripts/public-release-audit.js" --repo-root "$SOURCE_WORKTREE_DIR" --json
node "$SOURCE_WORKTREE_DIR/scripts/sync-sanitized-release-tree.js" \
  --source-root "$SOURCE_WORKTREE_DIR" \
  --target-root "$WORKTREE_DIR" \
  --write \
  --json

node "$WORKTREE_DIR/scripts/public-release-audit.js" --repo-root "$WORKTREE_DIR" --json
git -C "$WORKTREE_DIR" diff --check

if [ "$SKIP_RUNTIME_VERIFY" -ne 1 ]; then
  node "$WORKTREE_DIR/scripts/production-smoke-matrix.js" --repo-root "$WORKTREE_DIR" --json
  node "$WORKTREE_DIR/scripts/workflow-state-machine.js" templates --json > "$WORKTREE_DIR/.public-workflow-templates.json"
  node - "$WORKTREE_DIR" "$WORKTREE_DIR/.public-workflow-templates.json" <<'NODE'
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
const templates = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const manifestPath = path.join(root, 'skills/novel-assistant/novel-assistant-manifest.json');
assert(fs.existsSync(manifestPath), 'missing novel-assistant manifest');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
assert(manifest.updateSourceUrl === 'https://github.com/duiniwukenaihe/novel-assistant-skill.git', 'manifest updateSourceUrl is not GitHub public URL');
assert(Number(manifest.privateInternalSkillCount || 0) === 0, 'public bundle still contains private internal skills');

assert(!fs.existsSync(path.join(root, 'src/private-internal-skills')), 'src/private-internal-skills still exists');
assert(!fs.existsSync(path.join(root, 'skills/novel-assistant/references/private-internal-skills')), 'bundled private-internal-skills still exists');
assert(fs.existsSync(path.join(root, 'skills/novel-assistant/SKILL.md')), 'missing public entry SKILL.md');
assert(fs.existsSync(path.join(root, 'skills/novel-assistant/references/internal-skills/story/SKILL.md')), 'missing bundled story router');
assert(fs.existsSync(path.join(root, 'skills/novel-assistant/references/internal-skills/story-workflow/SKILL.md')), 'missing bundled story-workflow');
assert(fs.existsSync(path.join(root, 'skills/novel-assistant/references/internal-skills/story-short-write/SKILL.md')), 'missing bundled public story-short-write');

assert(Number(templates.privateRegistryCount || 0) === 0, 'workflow-state-machine loaded private registries');
const shortWrite = (templates.templates || []).find((item) => item.workflow_type === 'short_write');
assert(shortWrite, 'missing short_write workflow template');
assert((shortWrite.stages || []).length > 0, 'short_write workflow has no stages');
const publicOwners = new Set(['story-workflow', 'story-short-write', 'story-review']);
for (const stage of shortWrite.stages) {
  assert(publicOwners.has(stage.owner_module), `short_write stage ${stage.stage_id} has non-public owner ${stage.owner_module}`);
}
const domainStages = (shortWrite.stages || []).filter((stage) => ![
  'project_type_lock',
  'feedback_impact_sync',
  'full_story_review'
].includes(stage.stage_id));
assert(domainStages.length > 0, 'short_write workflow has no domain stages');
assert(domainStages.every((stage) => stage.owner_module === 'story-short-write'), 'short_write domain stage is not owned by story-short-write');
const fullStoryReview = (shortWrite.stages || []).find((stage) => stage.stage_id === 'full_story_review');
assert(fullStoryReview?.owner_module === 'story-review', 'short_write full_story_review is not owned by story-review');
assert(!(templates.templates || []).some((item) => item.workflow_type === 'private_short_startup'), 'private short startup workflow leaked into public build');

console.log(JSON.stringify({
  status: 'pass',
  check: 'public_runtime_verify',
  privateRegistryCount: templates.privateRegistryCount,
  shortWriteOwners: [...publicOwners],
  shortWriteDomainOwner: 'story-short-write',
  shortWriteReviewOwner: 'story-review',
  privateInternalSkillCount: manifest.privateInternalSkillCount
}, null, 2));
NODE
  rm -f "$WORKTREE_DIR/.public-workflow-templates.json"
fi

if [ "$COMMIT_CHANGES" -eq 1 ]; then
  git -C "$WORKTREE_DIR" add -A
  if git -C "$WORKTREE_DIR" diff --cached --quiet; then
    echo "No public release changes to commit."
  else
    git -C "$WORKTREE_DIR" commit -m "chore(release): prepare GitHub public branch"
  fi
fi

if [ "$PUSH_BRANCH" -eq 1 ]; then
  git -C "$WORKTREE_DIR" push "$REMOTE" "HEAD:$TARGET_BRANCH"
fi

git -C "$WORKTREE_DIR" status --short --branch
echo "Prepared sanitized GitHub branch: $TARGET_BRANCH"
echo "Worktree: $WORKTREE_DIR"
