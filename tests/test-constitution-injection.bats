#!/usr/bin/env bats
# tests/test-constitution-injection.bats

@test "constitution template exists and is valid markdown" {
    [ -f "$BATS_TEST_DIRNAME/../src/internal-skills/story-setup/references/templates/constitution.md.tmpl" ]
    head -1 "$BATS_TEST_DIRNAME/../src/internal-skills/story-setup/references/templates/constitution.md.tmpl" | grep -q "^# 写作宪法"
}

@test "constitution fixture matches template structure" {
    template="$BATS_TEST_DIRNAME/../src/internal-skills/story-setup/references/templates/constitution.md.tmpl"
    fixture="$BATS_TEST_DIRNAME/fixtures/constitution/sample-default.md"
    template_sections=$(grep -c "^## " "$template")
    fixture_sections=$(grep -c "^## " "$fixture")
    [ "$template_sections" = "$fixture_sections" ]
}

@test "4 write/analyze SKILL.md frontmatter mentions constitution" {
    for skill in story-long-write story-short-write story-short-analyze story-long-analyze; do
        grep -q "constitution" "$BATS_TEST_DIRNAME/../src/internal-skills/$skill/SKILL.md"
    done
}
