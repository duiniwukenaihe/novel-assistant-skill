#!/usr/bin/env bats

# Dedicated audit test for scripts/public-release-audit.js.
#
# Covers the public-release S1 surface that this hardening task targeted:
#   - private internal-skill asset paths
#   - private module-name leaks (private-short-extension / private-download-extension / private short-form extension)
#   - absolute personal paths (<local-user-path>, <local-user-path>, <server-workspace-path>)
#   - clean repo passes (exit 0, no S1)
#
# Each case builds a throwaway git repo with a valid public manifest so the
# manifest gate does not interfere, then asserts the audit's exit code and the
# emitted finding id (or lack thereof).

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    AUDIT="$REPO/scripts/public-release-audit.js"
}

# Helper: create a clean tmp git repo with a public manifest + UPGRADING guide,
# so the only finding is the one each test deliberately injects. Prints tmp path
# on stdout.
make_clean_repo() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/config" "$tmp/skills/novel-assistant" "$tmp/src/internal-skills/story-setup"
    cat > "$tmp/config/github-public-release-files.json" <<'JSON'
{
  "schemaVersion": 1,
  "releaseVersion": "0.1.0",
  "additionalFiles": [],
  "removedFiles": []
}
JSON
    cat > "$tmp/skills/novel-assistant/novel-assistant-manifest.json" <<'JSON'
{
  "releaseVersion": "0.1.0",
  "updateSourceUrl": "https://github.com/duiniwukenaihe/novel-assistant-skill.git"
}
JSON
    printf '> 公开版本：v0.1.0\n' > "$tmp/README.md"
    printf '# Changelog\n\n## v0.1.0 - fixture\n' > "$tmp/CHANGELOG.md"
    # Satisfy auditUpgradeGuide topics so the upgrade-guide gate stays quiet.
    cat > "$tmp/src/internal-skills/story-setup/UPGRADING.md" <<'MD'
## 升级策略
x
## 文件分类
x
## 版本检测
x
## 版本变更
x
MD
    git -C "$tmp" init -q
    git -C "$tmp" config user.email release-audit@example.invalid
    git -C "$tmp" config user.name release-audit
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m init
    printf '%s' "$tmp"
}

@test "audit rejects private internal-skill asset path with S1" {
    tmp="$(make_clean_repo)"
    mkdir -p "$tmp/src/private-internal-skills/leaked-addon"
    printf 'private skill body\n' > "$tmp/src/private-internal-skills/leaked-addon/SKILL.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m leak >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q '"status": "fail"'
    echo "$output" | grep -q 'private_internal_skill_asset'
}

@test "audit rejects private module name leak (private-short-extension) with S1" {
    tmp="$(make_clean_repo)"
    private_name="$(printf '%s-%s-%s' story trend forge)"
    printf 'this public doc must not reference %s\n' "$private_name" > "$tmp/README.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m leak >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'private_feature_name_leak'
}

@test "audit rejects private project name leak (private short-form extension) with S1" {
    tmp="$(make_clean_repo)"
    private_project="$(printf '%s %s' private short-form extension)"
    printf 'powered by %s internally\n' "$private_project" > "$tmp/README.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m leak >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'private_feature_project_leak'
}

@test "audit rejects absolute personal path <local-user-path> with S1" {
    tmp="$(make_clean_repo)"
    local_user_path="$(printf '/Users/%s' zhangpeng)"
    printf 'built locally at %s/data/book\n' "$local_user_path" > "$tmp/build-notes.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m leak >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'local_user_path'
}

@test "audit rejects any macOS user home path with S1" {
    tmp="$(make_clean_repo)"
    local_user_path="$(printf '/Users/%s' alice)"
    printf 'built locally at %s/data/book\n' "$local_user_path" > "$tmp/build-notes.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m leak >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'local_user_path'
}

@test "audit rejects a quoted bare macOS user home with S1" {
    tmp="$(make_clean_repo)"
    local_user_home="$(printf '/Users/%s' alice)"
    printf 'local home is "%s"\n' "$local_user_home" > "$tmp/build-notes.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m leak >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'local_user_path'
}

@test "audit rejects absolute personal path <local-user-path> with S1" {
    tmp="$(make_clean_repo)"
    printf 'deployed from <local-user-path>/project on the linux box\n' > "$tmp/ops-notes.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m leak >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'local_user_path'
}

@test "audit rejects inconsistent README changelog and manifest versions" {
    tmp="$(make_clean_repo)"
    printf '> 公开版本：v0.2.0\n' > "$tmp/README.md"
    printf '# Changelog\n\n## v0.3.0 - fixture\n' > "$tmp/CHANGELOG.md"
    node -e "const fs=require('fs'); const file='$tmp/skills/novel-assistant/novel-assistant-manifest.json'; const value=JSON.parse(fs.readFileSync(file)); value.releaseVersion='0.4.0'; fs.writeFileSync(file, JSON.stringify(value));"

    run node "$AUDIT" --repo-root "$tmp" --json

    [ "$status" -eq 1 ]
    echo "$output" | grep -q 'public_release_version_mismatch'
    echo "$output" | grep -q 'README.md'
    echo "$output" | grep -q 'CHANGELOG.md'
    echo "$output" | grep -q 'skills/novel-assistant/novel-assistant-manifest.json'
}

@test "clean public repo passes audit with exit 0" {
    tmp="$(make_clean_repo)"
    printf '> 公开版本：v0.1.0\n\nfully public content with no private references\n' > "$tmp/README.md"
    git -C "$tmp" add .
    git -C "$tmp" commit -q -m public >/dev/null

    run node "$AUDIT" --repo-root "$tmp" --json
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"status": "pass"'
    ! echo "$output" | grep -q '"severity": "S1"'
}
