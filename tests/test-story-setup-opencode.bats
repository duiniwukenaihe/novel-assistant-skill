#!/usr/bin/env bats
# tests/test-story-setup-opencode.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SETUP="$REPO/src/internal-skills/story-setup"
    BUNDLE="$REPO/skills/novel-assistant/references/internal-skills/story-setup"
    README="$REPO/README.md"
}

@test "story-setup documents OpenCode deployment without abandoning novel-assistant entry" {
    grep -q "OpenCode" "$SETUP/SKILL.md"
    grep -q "opencode" "$SETUP/SKILL.md"
    grep -q "target_cli: claude-code,opencode" "$SETUP/SKILL.md"
    grep -q "agents_version: 18" "$SETUP/SKILL.md"
    grep -q "setup_skill_version: 1.4.5" "$SETUP/SKILL.md"
    grep -q "/novel-assistant" "$SETUP/SKILL.md"
}

@test "story-setup carries opencode templates and plugin assets" {
    test -f "$SETUP/references/opencode/AGENTS.md.tmpl"
    test -f "$SETUP/references/opencode/plugin.ts"
    test -f "$SETUP/references/opencode/opencode.json.patch"
    test -f "$SETUP/references/opencode/pre-commit.sh"
    test -f "$SETUP/references/opencode/agents/narrative-writer.md"
    test -f "$SETUP/references/opencode/commands/novel-assistant.md"
    grep -q "novel-assistant" "$SETUP/references/opencode/commands/novel-assistant.md"
    grep -q "volume-local" "$SETUP/references/opencode/plugin.ts"
    grep -q "大纲\", volumeName" "$SETUP/references/opencode/plugin.ts"
    ! grep -R "请使用 story-long-write skill" "$SETUP/references/opencode/commands"
}

@test "opencode sync script exists for maintainers" {
    test -x "$REPO/scripts/sync-opencode.py"
    grep -q "Sync Claude Code agent templates to OpenCode format" "$REPO/scripts/sync-opencode.py"
}

@test "novel-assistant bundle includes opencode setup assets" {
    test -f "$BUNDLE/references/opencode/AGENTS.md.tmpl"
    test -f "$BUNDLE/references/opencode/plugin.ts"
    test -f "$BUNDLE/references/opencode/commands/novel-assistant.md"
}

@test "README records OpenCode upstream absorption and tradeoff" {
    grep -q "OpenCode CLI 支持" "$README"
    grep -q "单入口 novel-assistant" "$README"
}
