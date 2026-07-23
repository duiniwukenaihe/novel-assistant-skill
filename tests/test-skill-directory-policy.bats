#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    SCRIPT="$REPO/scripts/check-skill-directory-policy.js"
}

@test "skill directory policy check passes current layout" {
    node "$SCRIPT" --repo-root "$REPO" --json | grep -q '"status": "pass"'
}

@test "policy script documents novel-assistant roles" {
    output="$(node "$SCRIPT" --help)"
    echo "$output" | grep -q "only recommended user install target"
    echo "$output" | grep -q "skills/ top level must contain only novel-assistant"
    echo "$output" | grep -q "src/internal-skills"
    ! echo "$output" | grep -q "compatibility bundle"
}

@test "skills top level contains only novel-assistant" {
    node "$SCRIPT" --repo-root "$REPO" --json | grep -q '"topLevelPolicy": "novel-assistant-only"'
    for old_dir in oh-story story story-long-write story-review story-setup browser-cdp; do
        test ! -d "$REPO/skills/$old_dir"
    done
    test -f "$REPO/skills/novel-assistant/SKILL.md"
}

@test "internal skill source modules live under src/internal-skills" {
    for module in \
        story \
        story-workflow \
        story-long-write \
        story-short-write \
        story-long-analyze \
        story-short-analyze \
        story-long-scan \
        story-short-scan \
        story-deslop \
        story-cover \
        story-import \
        story-review \
        story-setup \
        browser-cdp
    do
        test -f "$REPO/src/internal-skills/$module/SKILL.md"
    done
}

@test "private internal skill source modules live under src/private-internal-skills" {
    private_count=0
    for private_dir in "$REPO"/src/private-internal-skills/*; do
        if [ -f "$private_dir/SKILL.md" ]; then
            private_count=$((private_count + 1))
        fi
    done
    [ "$private_count" -ge 1 ]
}
