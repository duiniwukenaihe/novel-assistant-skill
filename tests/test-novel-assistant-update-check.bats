#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "installed update check discovers its adjacent manifest without changing directory" {
    tmp="$(mktemp -d)"
    project="$tmp/project"
    skill="$tmp/skill"
    mkdir -p "$project" "$skill/scripts"
    cp "$REPO/scripts/novel-assistant-update-check.js" "$skill/scripts/"
    cp -R "$REPO/scripts/lib" "$skill/scripts/"
    cp "$REPO/skills/novel-assistant/novel-assistant-manifest.json" "$skill/"

    node - "$skill/novel-assistant-manifest.json" "$project/.story-deployed" <<'NODE'
const fs = require('fs');
const manifest = require(process.argv[2]);
fs.writeFileSync(process.argv[3], [
  `agents_version: ${manifest.agentsVersion}`,
  `setup_skill_version: ${manifest.setupSkillVersion}`,
  `novel_assistant_bundle_id: ${manifest.bundleId}`,
].join('\n'));
NODE

    node "$skill/scripts/novel-assistant-update-check.js" "$project" --json > "$tmp/out.json"

    node - "$tmp/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'current') process.exit(1);
NODE

    rm -rf "$tmp"
}

@test "manifest carries source tree identity and source state" {
    run node -e 'const m=require("./skills/novel-assistant/novel-assistant-manifest.json"); if(!m.sourceTreeId||!m.sourceState||!m.sourceLayout||typeof m.sourceLayout.includePrivate!=="boolean"||!m.sourceLayout.sourceSkillsDir) process.exit(1)'
    [ "$status" -eq 0 ]
}

@test "novel assistant update check prompts on stale deployed bundle without running setup" {
    tmp="$(mktemp -d)"
    project="$tmp/project"
    manifest="$tmp/manifest.json"
    mkdir -p "$project"
    cat > "$manifest" <<'JSON'
{
  "bundleName": "novel-assistant",
  "bundleId": "new123",
  "sourceCommit": "abc1234",
  "agentsVersion": 17,
  "setupSkillVersion": "1.4.1"
}
JSON
    cat > "$project/.story-deployed" <<'SENTINEL'
deployed_at: 2026-06-22T00:00:00Z
agents_version: 15
setup_skill_version: 1.3.1
novel_assistant_bundle_id: old999
target_cli: claude-code
resolver_strategy: global-skill-with-project-agent-references
references_dir: .claude/agent-references/novel-assistant
SENTINEL

    node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest" --json > "$tmp/out.json"

    node - "$tmp/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'update_available') process.exit(1);
if (out.shouldPrompt !== true) process.exit(2);
if (out.shouldRunSetup !== false) process.exit(3);
    if (!out.recommendedPrompt.includes('是否现在更新写作协作环境')) process.exit(4);
    if (!out.recommendedPrompt.includes('不会修改正文、大纲、细纲')) process.exit(5);
    if (out.recommendedPrompt.includes('刷新当前书目')) process.exit(6);
    if (out.recommendedPrompt.includes('setup 刷新')) process.exit(7);
    if (!out.recommendedPrompt.includes('1. 现在更新写作协作环境')) process.exit(8);
    if (!out.recommendedPrompt.includes('2. 暂不更新，继续原意图')) process.exit(9);
    if (!out.recommendedPrompt.includes('确认/是/yes/y 等同于 1')) process.exit(10);
    if (!out.recommendedPrompt.includes('不/否/no/n/later 等同于 2')) process.exit(11);
NODE

    rm -rf "$tmp"
}

@test "novel assistant update check uses collaboration-environment wording for non-json output" {
    tmp="$(mktemp -d)"
    project="$tmp/project"
    manifest="$tmp/manifest.json"
    mkdir -p "$project"
    cat > "$manifest" <<'JSON'
{
  "bundleName": "novel-assistant",
  "bundleId": "new123",
  "sourceCommit": "abc1234",
  "agentsVersion": 17,
  "setupSkillVersion": "1.4.1"
}
JSON

    output="$(node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest")"
    [ "$output" = "novel-assistant writing collaboration environment is not deployed" ]

    rm -rf "$tmp"
}

@test "novel assistant update check stays quiet when deployed bundle is current" {
    tmp="$(mktemp -d)"
    project="$tmp/project"
    manifest="$tmp/manifest.json"
    mkdir -p "$project"
    cat > "$manifest" <<'JSON'
{
  "bundleName": "novel-assistant",
  "bundleId": "same123",
  "sourceCommit": "abc1234",
  "agentsVersion": 17,
  "setupSkillVersion": "1.4.1"
}
JSON
    cat > "$project/.story-deployed" <<'SENTINEL'
deployed_at: 2026-06-22T00:00:00Z
agents_version: 17
setup_skill_version: 1.4.1
novel_assistant_bundle_id: same123
target_cli: claude-code
resolver_strategy: global-skill-with-project-agent-references
references_dir: .claude/agent-references/novel-assistant
SENTINEL

    output="$(node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest")"
    [ "$output" = "novel-assistant writing collaboration environment is current" ]

    rm -rf "$tmp"
}

@test "source tree identity controls freshness while source commit lag remains audit-only" {
    tmp="$(mktemp -d)"
    repo="$tmp/repository"
    project="$tmp/project"
    manifest="$repo/skills/novel-assistant/novel-assistant-manifest.json"
    mkdir -p "$repo/skills/novel-assistant" "$repo/src" "$repo/config" "$project"
    cp -R "$REPO/src/internal-skills" "$repo/src/"
    cp "$REPO/config/novel-assistant-bundle-files.json" "$repo/config/"
    ln -s "$REPO/scripts" "$repo/scripts"
    cp "$REPO/skills/novel-assistant/SKILL.md" "$repo/skills/novel-assistant/SKILL.md"
    touch "$repo/.version-fixture"
    git -C "$repo" init -q
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name fixture
    git -C "$repo" add .version-fixture
    git -C "$repo" commit -qm fixture

    node - "$REPO/skills/novel-assistant/novel-assistant-manifest.json" "$REPO/scripts/lib/bundle-version.js" "$repo" "$manifest" <<'NODE'
const fs = require('fs');
const [source, versionPath, repo, target] = process.argv.slice(2);
const version = require(versionPath);
const manifest = JSON.parse(fs.readFileSync(source, 'utf8'));
const layout = version.buildSourceLayout(repo, { includePrivate: false });
manifest.sourceTreeId = version.computeSourceTreeId(repo, manifest.bundleName, layout);
manifest.sourceInputDigest = version.computeSourceInputDigest(repo, manifest.bundleName, layout);
manifest.sourceLayout = version.manifestSourceLayout(repo, layout);
manifest.sourceCommit = 'audit-only-lag';
fs.writeFileSync(target, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
    node - "$manifest" "$project/.story-deployed" <<'NODE'
const fs = require('fs');
const [manifestPath, sentinelPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
fs.writeFileSync(sentinelPath, [
  `agents_version: ${manifest.agentsVersion}`,
  `setup_skill_version: ${manifest.setupSkillVersion}`,
  `novel_assistant_bundle_id: ${manifest.bundleId}`,
].join('\n'));
NODE

    node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest" --json > "$tmp/current.json"
    node - "$tmp/current.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'current' || out.sourceTreeCurrent !== true || out.sourceCommitLag !== true) process.exit(1);
NODE

    node - "$manifest" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
manifest.sourceInputDigest = `sha256:${'0'.repeat(64)}`;
fs.writeFileSync(process.argv[2], `${JSON.stringify(manifest, null, 2)}\n`);
NODE
    node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest" --json > "$tmp/stale.json"
    node - "$tmp/stale.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'update_available' || out.sourceInputCurrent !== false) process.exit(1);
NODE

    rm -rf "$tmp"
}

@test "old repository manifest without source tree metadata falls back to matching bundle identity" {
    tmp="$(mktemp -d)"
    repo="$tmp/repository"
    project="$tmp/project"
    manifest="$repo/skills/novel-assistant/novel-assistant-manifest.json"
    mkdir -p "$repo/skills/novel-assistant" "$repo/src/private-internal-skills/private-fixture" "$repo/config" "$project"
    cp -R "$REPO/src/internal-skills" "$repo/src/"
    cp "$REPO/config/novel-assistant-bundle-files.json" "$repo/config/"
    printf 'private fixture\n' > "$repo/src/private-internal-skills/private-fixture/SKILL.md"
    ln -s "$REPO/scripts" "$repo/scripts"
    cp "$REPO/skills/novel-assistant/SKILL.md" "$repo/skills/novel-assistant/SKILL.md"
    touch "$repo/.version-fixture"
    git -C "$repo" init -q
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name fixture
    git -C "$repo" add .version-fixture
    git -C "$repo" commit -qm fixture

    cat > "$manifest" <<'JSON'
{
  "bundleName": "novel-assistant",
  "bundleId": "legacy-same",
  "sourceCommit": "legacy-audit",
  "agentsVersion": 17,
  "setupSkillVersion": "1.4.1"
}
JSON
    cat > "$project/.story-deployed" <<'SENTINEL'
agents_version: 17
setup_skill_version: 1.4.1
novel_assistant_bundle_id: legacy-same
SENTINEL

    node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest" --json > "$tmp/out.json"
    node - "$tmp/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'current' || out.contentCurrent !== true) process.exit(1);
if (out.sourceTreeCurrent !== null || out.computedSourceTreeId !== null) process.exit(2);
NODE

    rm -rf "$tmp"
}

@test "private-off source layout remains current when the checkout has private sources" {
    tmp="$(mktemp -d)"
    repo="$tmp/repository"
    project="$tmp/project"
    manifest="$repo/skills/novel-assistant/novel-assistant-manifest.json"
    mkdir -p "$repo/skills/novel-assistant" "$repo/src/private-internal-skills/private-fixture" "$repo/config" "$project"
    cp -R "$REPO/src/internal-skills" "$repo/src/"
    cp "$REPO/config/novel-assistant-bundle-files.json" "$repo/config/"
    printf 'private fixture\n' > "$repo/src/private-internal-skills/private-fixture/SKILL.md"
    ln -s "$REPO/scripts" "$repo/scripts"
    cp "$REPO/skills/novel-assistant/SKILL.md" "$repo/skills/novel-assistant/SKILL.md"
    touch "$repo/.version-fixture"
    git -C "$repo" init -q
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name fixture
    git -C "$repo" add .version-fixture
    git -C "$repo" commit -qm fixture

    node - "$REPO/scripts/lib/bundle-version.js" "$repo" "$manifest" <<'NODE'
const fs = require('fs');
const version = require(process.argv[2]);
const repo = process.argv[3];
const target = process.argv[4];
const layout = version.buildSourceLayout(repo, { includePrivate: false });
const manifest = {
  bundleName: 'novel-assistant',
  bundleId: 'public-same',
  sourceTreeId: version.computeSourceTreeId(repo, 'novel-assistant', layout),
  sourceInputDigest: version.computeSourceInputDigest(repo, 'novel-assistant', layout),
  sourceLayout: version.manifestSourceLayout(repo, layout),
  agentsVersion: 17,
  setupSkillVersion: '1.4.1'
};
fs.writeFileSync(target, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
    cat > "$project/.story-deployed" <<'SENTINEL'
agents_version: 17
setup_skill_version: 1.4.1
novel_assistant_bundle_id: public-same
SENTINEL

    node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest" --json > "$tmp/out.json"
    node - "$tmp/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'current' || out.sourceTreeCurrent !== true) process.exit(1);
if (out.sourceLayout.includePrivate !== false) process.exit(2);
NODE

    rm -rf "$tmp"
}

@test "invalid source directory metadata falls back to matching bundle identity" {
    tmp="$(mktemp -d)"
    repo="$tmp/repository"
    project="$tmp/project"
    manifest="$repo/skills/novel-assistant/novel-assistant-manifest.json"
    mkdir -p "$repo/skills/novel-assistant" "$project"
    cp "$REPO/skills/novel-assistant/SKILL.md" "$repo/skills/novel-assistant/SKILL.md"
    ln -s "$REPO/scripts" "$repo/scripts"
    printf 'not a directory\n' > "$repo/source-file"
    printf 'not a directory\n' > "$repo/private-source-file"

    cat > "$manifest" <<'JSON'
{
  "bundleName": "novel-assistant",
  "bundleId": "invalid-layout-same",
  "sourceTreeId": "tree-recorded",
  "sourceLayout": {
    "schemaVersion": 1,
    "includePrivate": true,
    "sourceSkillsDir": "source-file",
    "privateSourceSkillsDir": "private-source-file",
    "recomputable": true
  },
  "sourceCommit": "audit-only",
  "agentsVersion": 17,
  "setupSkillVersion": "1.4.1"
}
JSON
    cat > "$project/.story-deployed" <<'SENTINEL'
agents_version: 17
setup_skill_version: 1.4.1
novel_assistant_bundle_id: invalid-layout-same
SENTINEL

    node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest" --json > "$tmp/out.json"
    node - "$tmp/out.json" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (out.status !== 'current' || out.contentCurrent !== true) process.exit(1);
if (out.computedSourceTreeId !== null || out.sourceTreeCurrent !== null) process.exit(2);
if (out.status === 'update_available') process.exit(3);
NODE

    rm -rf "$tmp"
}

@test "novel assistant update check does not inherit parent directory deployment state" {
    tmp="$(mktemp -d)"
    parent="$tmp/library"
    project="$parent/具体书名"
    manifest="$tmp/manifest.json"
    mkdir -p "$project"
    cat > "$manifest" <<'JSON'
{
  "bundleName": "novel-assistant",
  "bundleId": "new123",
  "sourceCommit": "abc1234",
  "agentsVersion": 17,
  "setupSkillVersion": "1.4.1"
}
JSON
    cat > "$parent/.story-deployed" <<'SENTINEL'
deployed_at: 2026-06-22T00:00:00Z
agents_version: 17
setup_skill_version: 1.4.1
novel_assistant_bundle_id: new123
target_cli: claude-code
SENTINEL

    node "$REPO/scripts/novel-assistant-update-check.js" "$project" "$manifest" --json > "$tmp/out.json"

    node - "$tmp/out.json" "$project" <<'NODE'
const fs = require('fs');
const out = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const project = process.argv[3];
if (out.projectRoot !== project) process.exit(1);
if (out.status !== 'not_deployed') process.exit(2);
if (out.deployedBundleId !== '') process.exit(3);
if (!out.recommendedPrompt.includes('未部署')) process.exit(4);
NODE

    rm -rf "$tmp"
}
