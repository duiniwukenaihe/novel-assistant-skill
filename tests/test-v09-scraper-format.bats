#!/usr/bin/env bats

setup() {
    export REPO_ROOT="$BATS_TEST_DIRNAME/.."
}

assert_scraper_format_contract() {
    local script="$1"
    grep -q -- "--format" "$script"
    grep -q "v0.8" "$script"
    grep -Eq "scan-artifact-build\\.js|scan-artifact-build|child_process|spawnSync" "$script"
    grep -Eq "markdown.*v0\\.8.*both|markdown[|/]v0\\.8[|/]both" "$script"
}

@test "long scan scrapers expose v0.8 artifact output" {
    assert_scraper_format_contract "$REPO_ROOT/src/internal-skills/story-long-scan/scripts/qidian-rank-scraper.js"
    assert_scraper_format_contract "$REPO_ROOT/src/internal-skills/story-long-scan/scripts/fanqie-rank-scraper.js"
    assert_scraper_format_contract "$REPO_ROOT/src/internal-skills/story-long-scan/scripts/qimao-rank-scraper.js"
    assert_scraper_format_contract "$REPO_ROOT/src/internal-skills/story-long-scan/scripts/jjwxc-rank-scraper.js"
    assert_scraper_format_contract "$REPO_ROOT/src/internal-skills/story-long-scan/scripts/ciweimao-rank-scraper.js"
}

@test "short scan scrapers expose v0.8 artifact output" {
    assert_scraper_format_contract "$REPO_ROOT/src/internal-skills/story-short-scan/scripts/dz-browse-scraper.js"
    assert_scraper_format_contract "$REPO_ROOT/src/internal-skills/story-short-scan/scripts/heiyan-booklist-scraper.js"
}

@test "short scan exposes wangwen debut fanqie market scraper" {
    script="$REPO_ROOT/src/internal-skills/story-short-scan/scripts/wangwen-debut-scraper.js"
    test -f "$script"
    grep -q "api/debut/list" "$script"
    grep -q "bookId" "$script"
    grep -q "scan-json-validate.js" "$script"
    grep -q "wangwen-debut-scraper.js" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
    grep -q -- "--list-categories" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
    grep -q -- "--select 1,3,5" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
    grep -q -- "--ledger" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
    grep -q -- "--run" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
    grep -q -- "--sort-by quality" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
    grep -q "数据好的" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
}

@test "fanqie category catalog separates official rank from third party debut categories" {
    script="$REPO_ROOT/scripts/fanqie-category-catalog.js"
    test -f "$script"
    grep -q "official_rank_male_reading" "$script"
    grep -q "third_party_debut_male" "$script"
    grep -q "fanqie-category-catalog.js" "$REPO_ROOT/src/internal-skills/story-long-scan/SKILL.md"
    grep -q "fanqie-category-catalog.js" "$REPO_ROOT/src/internal-skills/story-short-scan/SKILL.md"
}

@test "scan docs include upstream v0.6.16 robustness markers" {
    LONG_SCAN="$REPO_ROOT/src/internal-skills/story-long-scan/SKILL.md"
    FORMAT="$REPO_ROOT/src/internal-skills/story-long-scan/references/scan-output-format.md"

    grep -q "详情页多策略解码" "$LONG_SCAN"
    grep -q "标题解析异常" "$LONG_SCAN"
    grep -q "detail-limit" "$LONG_SCAN"
    grep -q "详情采集" "$FORMAT"
    grep -q "gb18030" "$FORMAT"
}
