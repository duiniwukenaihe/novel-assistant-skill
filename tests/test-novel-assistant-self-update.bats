#!/usr/bin/env bats
# tests/test-novel-assistant-self-update.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/novel-assistant-self-update.js"
    TMP_DIR="$(mktemp -d)"
    export GIT_AUTHOR_NAME="Test"
    export GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test"
    export GIT_COMMITTER_EMAIL="test@example.com"
}

teardown() {
    rm -rf "$TMP_DIR"
}

make_commit() {
    file="$1"
    message="$2"
    printf '%s\n' "$message" >> "$file"
    git add "$file"
    git commit -q -m "$message"
}

init_source_pair() {
    upstream="$TMP_DIR/upstream"
    source="$TMP_DIR/source"

    mkdir "$upstream"
    cd "$upstream"
    git init -q -b main
    make_commit skill.txt "base"
    git tag v1.0.0

    git clone -q "$upstream" "$source"
}

@test "self update check recommends stable tag before development commit" {
    init_source_pair

    cd "$upstream"
    make_commit skill.txt "stable update"
    git tag v1.1.0
    make_commit skill.txt "development update"

    output="$(node "$SCRIPT" --source-dir "$source" --json)"

    echo "$output" | grep -q '"status": "stable_update_available"'
    echo "$output" | grep -q '"recommendedChannel": "stable"'
    echo "$output" | grep -q '"latestStableTag": "v1.1.0"'
    echo "$output" | grep -q '"latestDevelopmentCommit"'
    echo "$output" | grep -q '"requiresConfirmation": true'
    echo "$output" | grep -q '更新到最新稳定版'
    ! echo "$output" | grep -q '"applied": true'
}

@test "self update check warns when only development commits are available" {
    init_source_pair

    cd "$upstream"
    make_commit skill.txt "development only"

    output="$(node "$SCRIPT" --source-dir "$source" --json)"

    echo "$output" | grep -q '"status": "development_update_available"'
    echo "$output" | grep -q '"recommendedChannel": "development"'
    echo "$output" | grep -q '"latestStableTag": "v1.0.0"'
    echo "$output" | grep -q '"isStable": false'
    echo "$output" | grep -q '开发版'
    echo "$output" | grep -q '是否仍要更新'
}

@test "self update apply refuses dirty source repositories" {
    init_source_pair

    cd "$upstream"
    make_commit skill.txt "development only"

    cd "$source"
    printf '%s\n' "local dirty edit" >> skill.txt

    set +e
    output="$(node "$SCRIPT" --source-dir "$source" --apply --channel development --json 2>&1)"
    status="$?"
    set -e

    [ "$status" -ne 0 ]
    echo "$output" | grep -q '"status": "blocked_dirty_worktree"'
    echo "$output" | grep -q '本地仓库有未提交改动'
}

@test "self update apply runs production smoke matrix before installing" {
    upstream="$TMP_DIR/upstream"
    source="$TMP_DIR/source"
    install="$TMP_DIR/install-target"

    mkdir -p "$upstream/scripts" "$upstream/skills/novel-assistant"
    cd "$upstream"
    git init -q -b main
    cat > scripts/build-oh-story-bundle.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p skills/novel-assistant
cat > skills/novel-assistant/SKILL.md <<'SKILL'
---
name: novel-assistant
description: test skill
---
SKILL
cat > skills/novel-assistant/novel-assistant-manifest.json <<'JSON'
{
  "bundleName": "novel-assistant",
  "bundleId": "test-bundle",
  "sourceCommit": "test",
  "sourceBranch": "main",
  "agentsVersion": 1,
  "setupSkillVersion": "0.1.0"
}
JSON
EOF
    chmod +x scripts/build-oh-story-bundle.sh
    cat > scripts/production-smoke-matrix.js <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
fs.writeFileSync('production-smoke-ran.txt', 'yes\n');
process.stdout.write(JSON.stringify({ status: 'pass', caseCount: 7, findings: [] }, null, 2) + '\n');
EOF
    chmod +x scripts/production-smoke-matrix.js
    printf '%s\n' "base" > base.txt
    git add base.txt scripts skills
    git commit -q -m "base"

    git clone -q "$upstream" "$source"

    cd "$upstream"
    make_commit feature.txt "development update"

    output="$(node "$SCRIPT" --source-dir "$source" --apply --channel development --install-target "$install" --json)"

    echo "$output" | grep -q '"applied": true'
    echo "$output" | grep -q '"productionSmokeStatus": "pass"'
    echo "$output" | grep -q '"caseCount": 7'
    test -f "$source/production-smoke-ran.txt"
    test -f "$install/SKILL.md"
}

@test "self update check reports project setup refresh after skill update" {
    init_source_pair

    project="$TMP_DIR/book"
    mkdir "$project"
    cat > "$project/.story-deployed" <<'EOF'
novel_assistant_bundle_id: old-bundle
novel_assistant_source_commit: old-commit
agents_version: 1
setup_skill_version: 0.1.0
EOF

    mkdir -p "$source/skills/novel-assistant"
    cat > "$source/skills/novel-assistant/novel-assistant-manifest.json" <<'EOF'
{
  "bundleName": "novel-assistant",
  "bundleId": "new-bundle",
  "sourceCommit": "new-commit",
  "agentsVersion": 2,
  "setupSkillVersion": "0.2.0"
}
EOF

    output="$(node "$SCRIPT" --source-dir "$source" --project-root "$project" --json)"

    echo "$output" | grep -q '"projectRuntimeStatus": "update_available"'
    echo "$output" | grep -q '"shouldRunProjectSetup": true'
    echo "$output" | grep -q '更新当前书籍项目的写作协作环境'
    ! echo "$output" | grep -q '刷新当前书目'
}

@test "self update check works from installed skill manifest without source repo" {
    init_source_pair

    cd "$upstream"
    make_commit skill.txt "stable update"
    git tag v1.1.0

    installed="$TMP_DIR/installed-skill"
    mkdir -p "$installed/scripts"
    cp "$SCRIPT" "$installed/scripts/novel-assistant-self-update.js"
    cat > "$installed/novel-assistant-manifest.json" <<EOF
{
  "bundleName": "novel-assistant",
  "bundleId": "old-bundle",
  "sourceCommit": "$(git -C "$source" rev-parse --short HEAD)",
  "sourceBranch": "main",
  "updateSourceUrl": "$upstream",
  "updateSourceBranch": "main",
  "updateMode": "self-managed",
  "agentsVersion": 1,
  "setupSkillVersion": "0.1.0"
}
EOF

    output="$(cd "$TMP_DIR" && node "$installed/scripts/novel-assistant-self-update.js" --skill-dir "$installed" --json)"

    echo "$output" | grep -q '"status": "stable_update_available"'
    echo "$output" | grep -q '"sourceMode": "installed_manifest"'
    echo "$output" | grep -q '"updateSourceUrl"'
    echo "$output" | grep -q '"latestStableTag": "v1.1.0"'
    echo "$output" | grep -q '通过 novel-assistant 自检更新'
}

@test "self update treats manifest-only remote commits with same bundle id as current" {
    init_source_pair

    cd "$upstream"
    mkdir -p skills/novel-assistant
    cat > skills/novel-assistant/novel-assistant-manifest.json <<'EOF'
{
  "bundleName": "novel-assistant",
  "bundleId": "same-bundle",
  "sourceCommit": "manifest-only",
  "sourceBranch": "main"
}
EOF
    git add skills/novel-assistant/novel-assistant-manifest.json
    git commit -q -m "manifest only refresh"

    installed="$TMP_DIR/installed-skill"
    mkdir -p "$installed/scripts"
    cp "$SCRIPT" "$installed/scripts/novel-assistant-self-update.js"
    cat > "$installed/novel-assistant-manifest.json" <<EOF
{
  "bundleName": "novel-assistant",
  "bundleId": "same-bundle",
  "sourceCommit": "$(git -C "$source" rev-parse --short HEAD)",
  "sourceBranch": "main",
  "updateSourceUrl": "$upstream",
  "updateSourceBranch": "main",
  "updateMode": "self-managed"
}
EOF

    output="$(cd "$TMP_DIR" && node "$installed/scripts/novel-assistant-self-update.js" --skill-dir "$installed" --json)"

    echo "$output" | grep -q '"status": "current"'
    echo "$output" | grep -q '"remoteBundleId": "same-bundle"'
    ! echo "$output" | grep -q '"status": "development_update_available"'
}

@test "README and entry skill forbid npx skills update as the normal update path" {
    README="$REPO/README.md"
    NOVEL="$REPO/skills/novel-assistant/SKILL.md"

    grep -q "不要使用 npx skills update 作为默认更新路径" "$README"
    grep -q "不要使用 npx skills update 作为默认更新路径" "$NOVEL"
    grep -q "进入 /novel-assistant 后由 skill 自己检查和更新" "$README"
    grep -q "进入 /novel-assistant 后由 skill 自己检查和更新" "$NOVEL"
}

@test "README documents GitLab branch and release policy separately from upstream" {
    README="$REPO/README.md"

    grep -q "GitLab 分支与发布策略" "$README"
    grep -q "上游不是发布分支" "$README"
    grep -q "main.*稳定发布线" "$README"
    grep -q "codex/.*功能开发" "$README"
    grep -q "upstream/.*上游反哺" "$README"
    grep -q "不要直接复用上游 tag 指向本地不同提交" "$README"
}

@test "README uses writing collaboration environment wording for project updates" {
    README="$REPO/README.md"

    grep -q "更新写作协作环境" "$README"
    grep -q "更新当前书籍项目的写作协作环境" "$README"
    ! grep -q "刷新当前书目" "$README"
    ! grep -q "书目刷新" "$README"
}
