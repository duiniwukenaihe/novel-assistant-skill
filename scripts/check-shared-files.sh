#!/bin/bash
# check-shared-files.sh — 检查明确托管的共享文件内容一致性
#
# 不再按 basename 全目录猜测“同名即同源”。本项目存在单包内部 skill、
# story-setup 模板、OpenCode/Codex 适配文件，这些同名文件可以有意不同。
# 本守卫只检查两类真正危险的漂移：
#   1. scripts/ 根脚本与各 skill-local scripts/ 副本必须字节一致
#   2. story-setup/references/agent-references/ 中的镜像参考文件必须与源 reference 一致
# 兼容 bash 3+（macOS）
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
  echo "Error: not in a git repository"
  exit 1
fi

SKILLS_DIR="$REPO_ROOT/skills"
SOURCE_SKILLS_DIR="$REPO_ROOT/src/internal-skills"
ROOT_SCRIPTS_DIR="$REPO_ROOT/scripts"
if [ ! -d "$SOURCE_SKILLS_DIR" ]; then
  echo "Error: src/internal-skills not found at $SOURCE_SKILLS_DIR"
  exit 1
fi

mismatches=0
checked=0

echo "Shared File Consistency Check"
echo "=============================="

report_mismatch() {
  base="$1"
  reference="$2"
  actual="$3"
  echo ""
  echo "MISMATCH: $base"
  echo "  Reference: $reference"
  echo "  Differs in: $actual"
  mismatches=$((mismatches + 1))
}

collect_skill_script_paths() {
  base="$1"
  find "$SOURCE_SKILLS_DIR" -type f \
    -path "*/scripts/$base" \
    ! -name '.gitkeep' 2>/dev/null | sort
}

compare_paths_to_reference() {
  base="$1"
  ref_path="$2"
  ref_label="$3"
  shift 3
  paths=("$@")
  [ ${#paths[@]} -gt 0 ] || return 0
  checked=$((checked + 1))
  for p in ${paths[@]+"${paths[@]}"}; do
    [ "$p" = "$ref_path" ] && continue
    if ! diff -q "$ref_path" "$p" >/dev/null 2>&1; then
      report_mismatch "$base" "$ref_label" "${p#$REPO_ROOT/}"
    fi
  done
}

# 1. Managed runtime scripts: root scripts/ is the source of truth.
if [ -d "$ROOT_SCRIPTS_DIR" ]; then
  while IFS= read -r root_script; do
    [ -z "$root_script" ] && continue
    base="$(basename "$root_script")"
    paths=()
    while IFS= read -r fpath; do
      [ -z "$fpath" ] && continue
      paths+=("$fpath")
    done < <(collect_skill_script_paths "$base")
    compare_paths_to_reference "$base" "$root_script" "scripts/$base" ${paths[@]+"${paths[@]}"}
  done < <(find "$ROOT_SCRIPTS_DIR" -maxdepth 1 -type f | sort)
fi

# 1b. Skill-local scripts without a root copy are still managed if duplicated.
script_dup_names="$(find "$SOURCE_SKILLS_DIR" -type f \
  -path '*/scripts/*' \
  ! -name '.gitkeep' -exec basename {} \; 2>/dev/null | sort | uniq -d)"

for base in $script_dup_names; do
  [ -f "$ROOT_SCRIPTS_DIR/$base" ] && continue
  paths=()
  while IFS= read -r fpath; do
    [ -z "$fpath" ] && continue
    paths+=("$fpath")
  done < <(collect_skill_script_paths "$base")
  [ ${#paths[@]} -lt 2 ] && continue
  compare_paths_to_reference "$base" "${paths[0]}" "${paths[0]#$REPO_ROOT/}" ${paths[@]+"${paths[@]}"}
done

# 2. Agent reference mirrors: story-setup deploys these to projects, so each mirror
# must match its source reference. Source priority is explicit and stable.
MIRROR_DIR="$SOURCE_SKILLS_DIR/story-setup/references/agent-references"
SOURCE_REFERENCE_DIRS=(
  "$SOURCE_SKILLS_DIR/story-long-write/references"
  "$SOURCE_SKILLS_DIR/story-review/references"
  "$SOURCE_SKILLS_DIR/story-deslop/references"
  "$SOURCE_SKILLS_DIR/story-short-write/references"
  "$SOURCE_SKILLS_DIR/story-short-analyze/references"
  "$SOURCE_SKILLS_DIR/story-import/references"
)

if [ -d "$MIRROR_DIR" ]; then
  while IFS= read -r mirror; do
    [ -z "$mirror" ] && continue
    base="$(basename "$mirror")"
    source=""
    for dir in ${SOURCE_REFERENCE_DIRS[@]+"${SOURCE_REFERENCE_DIRS[@]}"}; do
      if [ -f "$dir/$base" ]; then
        source="$dir/$base"
        break
      fi
    done
    [ -z "$source" ] && continue
    compare_paths_to_reference "$base" "$source" "${source#$REPO_ROOT/}" "$mirror"
  done < <(find "$MIRROR_DIR" -maxdepth 1 -type f | sort)
fi

echo ""
echo "=============================="
echo "Files checked (shared): $checked | Mismatches: $mismatches"

if [ "$mismatches" -gt 0 ]; then
  echo ""
  echo "NOTE: Only managed script copies and explicit agent-reference mirrors are checked."
  echo "      SKILL.md, internal bundle skills, templates, and CLI-specific adapters are not compared by basename."
  exit 1
fi

echo "All shared files are consistent."
