#!/usr/bin/env bats

@test "all 7 platforms have sensitive-words JSON" {
    for p in fanqie qidian jjwxc qimao zhihu heiyan dianzong; do
        [ -f "$BATS_TEST_DIRNAME/../src/internal-skills/story-long-write/references/web-novel-commercial/sensitive-words/$p.json" ]
    done
}

@test "sensitive-words JSON has required schema fields" {
    f="$BATS_TEST_DIRNAME/fixtures/sensitive-words/fanqie-sample.json"
    grep -q '"platform"' "$f"
    grep -q '"version"' "$f"
    grep -q '"categories"' "$f"
    grep -q '"updateUrl"' "$f"
}

@test "sensitive-words updateUrl points to main branch" {
    f="$BATS_TEST_DIRNAME/fixtures/sensitive-words/fanqie-sample.json"
    grep -q "raw.githubusercontent.com.*main" "$f"
}
