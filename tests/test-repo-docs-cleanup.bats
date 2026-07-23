#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "docs workflow explains workflow brain and runtime boundaries" {
    doc="$REPO/docs/workflow.md"
    [ -f "$doc" ]
    grep -q "story-workflow" "$doc"
    grep -q "L2/L3" "$doc"
    grep -q "workflow packet" "$doc"
    grep -q "result packet" "$doc"
    grep -q "runtime_guard" "$doc"
    grep -q "pending_action" "$doc"
    grep -q "review gap" "$doc"
    grep -q "扩容事务协议" "$doc"
    grep -q "output health gate" "$doc"
}

@test "docs installation guide separates skill and project updates" {
    doc="$REPO/docs/installation-and-update.md"
    [ -f "$doc" ]
    grep -q "npx skills add https://github.com/duiniwukenaihe/novel-assistant-skill.git --path skills/novel-assistant -y -g" "$doc"
    grep -q "/novel-assistant 更新 skill" "$doc"
    grep -q "/novel-assistant 更新写作协作环境" "$doc"
    grep -q "不要使用 npx skills update" "$doc"
    grep -q "稳定版" "$doc"
    grep -q "开发版" "$doc"
}

@test "docs scripts map classifies scripts without moving paths" {
    doc="$REPO/docs/scripts-map.md"
    [ -f "$doc" ]
    grep -q "runtime" "$doc"
    grep -q "validation" "$doc"
    grep -q "workflow" "$doc"
    grep -q "longform" "$doc"
    grep -q "analyze-scan" "$doc"
    grep -q "setup-update" "$doc"
    grep -q "maintainer" "$doc"
    grep -q "test-support" "$doc"
    grep -q "Consolidation candidates" "$doc"
    grep -q "src/internal-skills" "$doc"
}

@test "docs skill directory policy keeps novel-assistant as only user install target" {
    doc="$REPO/docs/skill-directory-policy.md"
    [ -f "$doc" ]
    grep -q "skills/novel-assistant" "$doc"
    grep -q "only recommended user install target" "$doc"
    grep -q "skills/ top level must contain only novel-assistant" "$doc"
    grep -q "skills/oh-story" "$doc"
    grep -q "Removed from this repo layout" "$doc"
    grep -q "src/internal-skills/story-*" "$doc"
    grep -q "source modules" "$doc"
    grep -q "upstream absorption" "$doc"
    grep -q "User-facing identity" "$doc"
    grep -q "Maintainer Checks" "$doc"
    grep -q "Rebuilds must not recreate" "$doc"
}

@test "bundle manifest records a safely recomputable build scope" {
    node - "$REPO/skills/novel-assistant/novel-assistant-manifest.json" <<'NODE'
const fs = require('fs');
const manifest = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const layout = manifest.sourceLayout;
if (!layout || layout.schemaVersion !== 1) process.exit(1);
if (typeof layout.includePrivate !== 'boolean') process.exit(2);
if (typeof layout.sourceSkillsDir !== 'string' || layout.sourceSkillsDir.startsWith('/')) process.exit(3);
if (layout.includePrivate && typeof layout.privateSourceSkillsDir !== 'string') process.exit(4);
NODE
}

@test "story-memory is an expected internal source skill" {
    run node "$REPO/scripts/check-skill-directory-policy.js" --json
    [ "$status" -eq 0 ]
    node -e '
      const result = JSON.parse(process.argv[1]);
      const skill = result.internalSourceDetected.find(({ dir }) => dir === "story-memory");
      if (!skill || skill.role !== "internalSource") process.exit(1);
    ' "$output"
}

@test "docs panlong benchmark defines reproducible comparison protocol" {
    doc="$REPO/docs/benchmark-panlong.md"
    [ -f "$doc" ]
    grep -q "demo/拆文库-盘龙/原文/原文.txt" "$doc"
    grep -q "demo/拆文库-盘龙" "$doc"
    grep -q "benchmarks/panlong" "$doc"
    grep -q "Claude Code" "$doc"
    grep -q "/novel-assistant 完整拆解" "$doc"
    grep -q "Chapter coverage" "$doc"
    grep -q "Source grounding" "$doc"
    grep -q "Artifact completeness" "$doc"
    grep -q "Runtime behavior" "$doc"
}

@test "docs github public release keeps release tooling on main and cleanup on public branch" {
    doc="$REPO/docs/github-public-release.md"
    [ -f "$doc" ]
    grep -q "github/public-release" "$doc"
    grep -q "node scripts/na-dev.js prepare-public" "$doc"
    grep -q "The sanitized deletions do \\*\\*not\\*\\* belong on" "$doc"
}
