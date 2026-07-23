#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/v08-scan/qidian-newsign"
}

@test "scan-json-validate.js validates v0.8 scan fixture" {
    node "$REPO/scripts/scan-json-validate.js" "$FIXTURE"
}

@test "scan-json-validate.js rejects missing ranking items" {
    tmp="$(mktemp -d)"
    cp "$FIXTURE/scan-metadata.json" "$tmp/"
    cp "$FIXTURE/trend-signals.json" "$tmp/"
    cp "$FIXTURE/topic-candidates.json" "$tmp/"
    set +e
    output="$(node "$REPO/scripts/scan-json-validate.js" "$tmp" 2>&1)"
    status="$?"
    set -e
    [ "$status" -ne 0 ]
    [[ "$output" == *"ranking-items.jsonl"* ]]
}

@test "scan protocol is referenced by long and short scan skills" {
    grep -q "v0-8-scan-data-protocol.md" "$REPO/src/internal-skills/story-long-scan/SKILL.md"
    grep -q "v0-8-scan-data-protocol.md" "$REPO/src/internal-skills/story-short-scan/SKILL.md"
    [ -f "$REPO/src/internal-skills/story-long-scan/references/v0-8-scan-data-protocol.md" ]
    [ -f "$REPO/src/internal-skills/story-short-scan/references/v0-8-scan-data-protocol.md" ]
}

@test "short scan preserves downloadable hints for downstream download modules" {
    grep -q "可下载线索保留" "$REPO/src/internal-skills/story-short-scan/SKILL.md"
    grep -q "scan-download-hints.js" "$REPO/src/internal-skills/story-short-scan/SKILL.md"
    grep -q "metrics.bookId" "$REPO/src/internal-skills/story-short-scan/references/v0-8-scan-data-protocol.md"
    grep -q "scan-download-hints.js" "$REPO/scripts/build-oh-story-bundle.sh"
}

@test "scan skills document cache based self healing for scraper failures" {
    for skill in "$REPO/src/internal-skills/story-long-scan/SKILL.md" "$REPO/src/internal-skills/story-short-scan/SKILL.md"; do
        grep -q "扫榜故障自愈" "$skill"
        grep -q "文件系统是权威" "$skill"
        grep -q "缓存优先续跑" "$skill"
        grep -q "部分失败不阻断整体" "$skill"
        grep -q "外部阻断类" "$skill"
        grep -q "结构化校验失败" "$skill"
    done
}
