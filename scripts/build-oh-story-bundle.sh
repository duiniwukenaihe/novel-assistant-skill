#!/bin/bash
# build-oh-story-bundle.sh — rebuild the single-directory novel-assistant skill bundle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "Error: not in a git repository" >&2
  exit 1
fi

SOURCE_SKILLS_DIR="${SOURCE_SKILLS_DIR:-$REPO_ROOT/src/internal-skills}"
PRIVATE_SOURCE_SKILLS_DIR="${PRIVATE_SOURCE_SKILLS_DIR:-$REPO_ROOT/src/private-internal-skills}"
INCLUDE_PRIVATE_INTERNAL_SKILLS="${NOVEL_ASSISTANT_INCLUDE_PRIVATE:-1}"
BUNDLE_NAMES=(${BUNDLE_NAMES:-novel-assistant})
BUILD_MANIFEST="$REPO_ROOT/config/novel-assistant-bundle-files.json"
# Runtime script manifest is config-driven. Required managed runtime anchors:
# workflow-runner.js, workflow-supervisor.js, workflow-session-heartbeat.js,
# token-cost-ledger.js.

if [ ! -f "$BUILD_MANIFEST" ]; then
  echo "Error: missing bundle file manifest: $BUILD_MANIFEST" >&2
  exit 1
fi

manifest_list() {
  node - "$REPO_ROOT/scripts/lib/bundle-version.js" "$REPO_ROOT" "$1" <<'NODE'
const version = require(process.argv[2]);
const manifest = version.loadBundleFileManifest(process.argv[3]);
process.stdout.write(`${manifest[process.argv[4]].join('\n')}\n`);
NODE
}

SKILL_NAMES=()
while IFS= read -r skill_name; do
  [ -n "$skill_name" ] && SKILL_NAMES+=("$skill_name")
done < <(manifest_list internalSkills)

SCRIPT_NAMES=()
while IFS= read -r script_name; do
  [ -n "$script_name" ] && SCRIPT_NAMES+=("$script_name")
done < <(manifest_list scriptFiles)

PRIVATE_SKILL_NAMES=()
if [ "$INCLUDE_PRIVATE_INTERNAL_SKILLS" != "0" ] && [ -d "$PRIVATE_SOURCE_SKILLS_DIR" ]; then
  while IFS= read -r private_skill_name; do
    PRIVATE_SKILL_NAMES+=("$private_skill_name")
  done < <(
    find "$PRIVATE_SOURCE_SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d |
      while IFS= read -r dir; do
        if [ -f "$dir/SKILL.md" ]; then basename "$dir"; fi
      done |
      LC_ALL=C sort
  )
fi

if [ ! -f "$REPO_ROOT/scripts/lib/oh-story-artifacts.js" ]; then
  echo "Error: missing shared script library: $REPO_ROOT/scripts/lib/oh-story-artifacts.js" >&2
  exit 1
fi

# Capture provenance before this script mutates the generated bundle.
BUILD_START_SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_START_SOURCE_BRANCH="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo unknown)"

for bundle_name in "${BUNDLE_NAMES[@]}"; do
  BUNDLE_DIR="$REPO_ROOT/skills/$bundle_name"
  INTERNAL_DIR="$BUNDLE_DIR/references/internal-skills"
  PRIVATE_INTERNAL_DIR="$BUNDLE_DIR/references/private-internal-skills"
  BUNDLE_SCRIPTS_DIR="$BUNDLE_DIR/scripts"
  SOURCE_STATE="$(node -e 'const version=require(process.argv[1]); process.stdout.write(version.releaseSourceState(process.argv[2], process.argv[3], process.argv[4] !== "0"))' "$REPO_ROOT/scripts/lib/bundle-version.js" "$REPO_ROOT" "$bundle_name" "$INCLUDE_PRIVATE_INTERNAL_SKILLS")"

  if [ ! -f "$BUNDLE_DIR/SKILL.md" ]; then
    echo "Error: missing bundle entry skill: $BUNDLE_DIR/SKILL.md" >&2
    exit 1
  fi

  mkdir -p "$INTERNAL_DIR" "$BUNDLE_SCRIPTS_DIR" "$BUNDLE_DIR/config"

  find "$INTERNAL_DIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  rm -rf "$PRIVATE_INTERNAL_DIR"
  for skill_name in "${SKILL_NAMES[@]}"; do
    src="$SOURCE_SKILLS_DIR/$skill_name"
    if [ ! -f "$src/SKILL.md" ]; then
      echo "Error: missing skill source: $src/SKILL.md" >&2
      exit 1
    fi
    cp -R "$src" "$INTERNAL_DIR/$skill_name"
  done

  if [ "${#PRIVATE_SKILL_NAMES[@]}" -gt 0 ]; then
    mkdir -p "$PRIVATE_INTERNAL_DIR"
    for skill_name in "${PRIVATE_SKILL_NAMES[@]}"; do
      src="$PRIVATE_SOURCE_SKILLS_DIR/$skill_name"
      if [ ! -f "$src/SKILL.md" ]; then
        echo "Error: missing private skill source: $src/SKILL.md" >&2
        exit 1
      fi
      cp -R "$src" "$PRIVATE_INTERNAL_DIR/$skill_name"
    done
  fi

  find "$BUNDLE_SCRIPTS_DIR" -mindepth 1 -maxdepth 1 -type f -exec rm -f {} +
  rm -rf "$BUNDLE_SCRIPTS_DIR/lib" "$BUNDLE_SCRIPTS_DIR/native"
  for script_name in "${SCRIPT_NAMES[@]}"; do
    src="$REPO_ROOT/scripts/$script_name"
    if [ ! -f "$src" ]; then
      echo "Error: missing script source: $src" >&2
      exit 1
    fi
    cp "$src" "$BUNDLE_SCRIPTS_DIR/$script_name"
  done
  cp -R "$REPO_ROOT/scripts/lib" "$BUNDLE_SCRIPTS_DIR/lib"
  cp -R "$REPO_ROOT/scripts/native" "$BUNDLE_SCRIPTS_DIR/native"
  cp "$BUILD_MANIFEST" "$BUNDLE_DIR/config/novel-assistant-bundle-files.json"
  chmod +x "$BUNDLE_SCRIPTS_DIR"/*

  SOURCE_COMMIT="$BUILD_START_SOURCE_COMMIT"
  SOURCE_BRANCH="$BUILD_START_SOURCE_BRANCH"
  DEFAULT_UPDATE_SOURCE_URL="https://github.com/duiniwukenaihe/novel-assistant-skill.git"
  REMOTE_UPDATE_SOURCE_URL="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || echo "")"
  UPDATE_SOURCE_URL="${NOVEL_ASSISTANT_UPDATE_SOURCE_URL:-$REMOTE_UPDATE_SOURCE_URL}"
  if [ -z "$UPDATE_SOURCE_URL" ] || [[ "$UPDATE_SOURCE_URL" == *"oh-story-claudecode"* ]]; then
    UPDATE_SOURCE_URL="$DEFAULT_UPDATE_SOURCE_URL"
  fi
  UPDATE_SOURCE_BRANCH="${NOVEL_ASSISTANT_UPDATE_BRANCH:-main}"
  SETUP_SKILL_VERSION="$(awk '/^version: / { print $2; exit }' "$SOURCE_SKILLS_DIR/story-setup/SKILL.md")"
  AGENTS_VERSION="$(awk -F': *' '/agents_version: [0-9]+/ { print $2; exit }' "$SOURCE_SKILLS_DIR/story-setup/SKILL.md")"
  VERSION_JSON="$(node "$REPO_ROOT/scripts/lib/bundle-version.js" \
    --repo-root "$REPO_ROOT" \
    --bundle-dir "$BUNDLE_DIR" \
    --bundle-name "$bundle_name" \
    --include-private "$INCLUDE_PRIVATE_INTERNAL_SKILLS" \
    --source-skills-dir "$SOURCE_SKILLS_DIR" \
    --private-source-skills-dir "$PRIVATE_SOURCE_SKILLS_DIR")"
  BUNDLE_ID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).bundleId)' "$VERSION_JSON")"
  SOURCE_TREE_ID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).sourceTreeId)' "$VERSION_JSON")"
  SOURCE_INPUT_DIGEST="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).sourceInputDigest)' "$VERSION_JSON")"
  SOURCE_LAYOUT="$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(process.argv[1]).sourceLayout))' "$VERSION_JSON")"
  cat > "$BUNDLE_DIR/novel-assistant-manifest.json" <<JSON
{
  "bundleName": "$bundle_name",
  "bundleId": "$BUNDLE_ID",
  "sourceTreeId": "$SOURCE_TREE_ID",
  "sourceInputDigest": "$SOURCE_INPUT_DIGEST",
  "sourceLayout": $SOURCE_LAYOUT,
  "sourceCommit": "$SOURCE_COMMIT",
  "sourceCommitRole": "build_start_git_baseline",
  "sourceState": "$SOURCE_STATE",
  "sourceBranch": "$SOURCE_BRANCH",
  "updateSourceUrl": "$UPDATE_SOURCE_URL",
  "updateSourceBranch": "$UPDATE_SOURCE_BRANCH",
  "updateMode": "self-managed",
  "agentsVersion": $AGENTS_VERSION,
  "setupSkillVersion": "$SETUP_SKILL_VERSION",
  "internalSkillCount": ${#SKILL_NAMES[@]},
  "privateInternalSkillCount": ${#PRIVATE_SKILL_NAMES[@]},
  "scriptCount": ${#SCRIPT_NAMES[@]}
}
JSON

  echo "Built $BUNDLE_DIR"
done

echo "Internal skills: ${#SKILL_NAMES[@]}"
echo "Private internal skills: ${#PRIVATE_SKILL_NAMES[@]}"
echo "Bundled scripts: ${#SCRIPT_NAMES[@]}"
