#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURES="$REPO/tests/fixtures/review-evidence-map"
    TMP_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "maps a flat chapter asset into requested global order" {
    cp -R "$FIXTURES/flat/." "$TMP_DIR/"

    node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-1 --write --json > "$TMP_DIR/result.json"

    [ "$(wc -l < "$TMP_DIR/evidence/chapter-evidence.jsonl")" -eq 1 ]
    grep -q '"chapterKey":"v01-c001"' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"globalDraftOrder":1' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"sourceStatus":"trusted"' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"staticRiskTags":\["ai-pattern","punctuation"\]' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"type":"punctuation"' "$TMP_DIR/evidence/static-findings.jsonl"
}

@test "uses schema and assets to keep volume-local chapter files distinct without double counting" {
    cp -R "$FIXTURES/volume-local/." "$TMP_DIR/"

    node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 43-44 --write --json > "$TMP_DIR/result.json"

    [ "$(wc -l < "$TMP_DIR/evidence/chapter-evidence.jsonl")" -eq 2 ]
    grep -q '"chapterKey":"v01-c001"' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"chapterKey":"v02-c001"' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"globalDraftOrder":43' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"globalDraftOrder":44' "$TMP_DIR/evidence/chapter-evidence.jsonl"
}

@test "reports legacy mixed volume numbering as an explicit untrusted layout" {
    cp -R "$FIXTURES/legacy-mixed/." "$TMP_DIR/"

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-27 --write --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"status": "blocked_mixed_chapter_layout"'* ]]
    grep -q '"type":"legacy-mixed-layout"' "$TMP_DIR/evidence/static-findings.jsonl"
    node - "$TMP_DIR/evidence/chapter-evidence.jsonl" <<'NODE'
const fs = require('fs');
const rows = fs.readFileSync(process.argv[2], 'utf8').trim().split(/\n/).filter(Boolean).map(JSON.parse);
const orders = rows.map((row) => row.globalDraftOrder);
if (orders.length !== new Set(orders).size) process.exit(1);
NODE
}

@test "blocks a schema chapter whose authoritative draftPath is missing" {
    mkdir -p "$TMP_DIR/追踪/schema"
    printf '%s\n' '{"chapterId":"第001章","chapterNo":1,"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":1,"draftPath":"正文/第001章_不存在.md"}' > "$TMP_DIR/追踪/schema/chapters.jsonl"

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-1 --write --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"status": "blocked_missing_source_file"'* ]]
    grep -q '"type":"missing-source-file"' "$TMP_DIR/evidence/static-findings.jsonl"
    [ ! -s "$TMP_DIR/evidence/chapter-evidence.jsonl" ]
}

@test "blocks duplicate and partial authoritative global orders without reindexing" {
    for mode in duplicate partial; do
        project="$TMP_DIR/$mode"
        mkdir -p "$project/正文/第1卷" "$project/正文/第2卷" "$project/追踪"
        printf '# 第001章 A\n正文。\n' > "$project/正文/第1卷/第001章_A.md"
        printf '# 第001章 B\n正文。\n' > "$project/正文/第2卷/第001章_B.md"
        if [ "$mode" = duplicate ]; then
            cat > "$project/追踪/章节资产.jsonl" <<'JSONL'
{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":44,"draftPath":"正文/第1卷/第001章_A.md"}
{"volume":"第2卷","volumeChapterNo":1,"globalDraftOrder":44,"draftPath":"正文/第2卷/第001章_B.md"}
JSONL
        else
            cat > "$project/追踪/章节资产.jsonl" <<'JSONL'
{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":44,"draftPath":"正文/第1卷/第001章_A.md"}
{"volume":"第2卷","volumeChapterNo":1,"draftPath":"正文/第2卷/第001章_B.md"}
JSONL
        fi

        run node "$REPO/scripts/review-evidence-map.js" "$project" --range 44-44 --write --json

        [ "$status" -ne 0 ]
        [[ "$output" == *'"status": "blocked_global_order_'* ]]
        if [ "$mode" = duplicate ]; then
            grep -q '"globalDraftOrder":44' "$project/evidence/static-findings.jsonl"
        else
            grep -q '"path":"正文/第2卷/第001章_B.md"' "$project/evidence/static-findings.jsonl"
            grep -q '"globalDraftOrder":44' "$project/evidence/static-findings.jsonl"
        fi
        [ ! -s "$project/evidence/chapter-evidence.jsonl" ]
    done
}

@test "blocks conflicting schema or asset order evidence for the same chapter identity" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/追踪"
    printf '# 第001章 A\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_A.md"
    printf '# 第001章 B\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_B.md"
    cat > "$TMP_DIR/追踪/章节资产.jsonl" <<'JSONL'
{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":44,"draftPath":"正文/第1卷/第001章_B.md"}
{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":43,"draftPath":"正文/第1卷/第001章_A.md"}
JSONL

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 43-44 --write --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"status": "blocked_global_order_conflict"'* ]]
    grep -q '"type":"global-order-conflict"' "$TMP_DIR/evidence/static-findings.jsonl"
    [ ! -s "$TMP_DIR/evidence/chapter-evidence.jsonl" ]
}

@test "blocks distinct authoritative draft paths for the same chapter identity" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/追踪/schema" "$TMP_DIR/追踪"
    printf '# 第001章 Schema\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_Schema.md"
    printf '# 第001章 Asset\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_Asset.md"
    printf '%s\n' '{"chapterId":"第043章","chapterNo":43,"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":43,"draftPath":"正文/第1卷/第001章_Schema.md"}' > "$TMP_DIR/追踪/schema/chapters.jsonl"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":43,"draftPath":"正文/第1卷/第001章_Asset.md"}' > "$TMP_DIR/追踪/章节资产.jsonl"

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 43-43 --write --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"status": "blocked_chapter_identity_conflict"'* ]]
    grep -q '"type":"chapter-identity-path-conflict"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '第001章_Schema.md' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '第001章_Asset.md' "$TMP_DIR/evidence/static-findings.jsonl"
    [ ! -s "$TMP_DIR/evidence/chapter-evidence.jsonl" ]
}

@test "does not let a chapter 50 conflict block requested range 51-100" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/追踪/schema" "$TMP_DIR/追踪"
    printf '# 第050章 当前稿\n正文。\n' > "$TMP_DIR/正文/第1卷/第050章_当前稿.md"
    printf '# 第050章 另一稿\n正文。\n' > "$TMP_DIR/正文/第1卷/第050章_另一稿.md"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":50,"globalDraftOrder":50,"draftPath":"正文/第1卷/第050章_当前稿.md"}' > "$TMP_DIR/追踪/schema/chapters.jsonl"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":50,"globalDraftOrder":50,"draftPath":"正文/第1卷/第050章_另一稿.md"}' > "$TMP_DIR/追踪/章节资产.jsonl"
    for order in $(seq 51 100); do
        chapter="$(printf '%03d' "$order")"
        printf '# 第%s章 正文\n正文。\n' "$chapter" > "$TMP_DIR/正文/第1卷/第${chapter}章_正文.md"
        printf '{"volume":"第1卷","volumeChapterNo":%d,"globalDraftOrder":%d,"draftPath":"正文/第1卷/第%s章_正文.md"}\n' \
            "$order" "$order" "$chapter" >> "$TMP_DIR/追踪/schema/chapters.jsonl"
    done

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 51-100 --write --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "ok"'* ]]
    [ "$(wc -l < "$TMP_DIR/evidence/chapter-evidence.jsonl")" -eq 50 ]
    grep -q '"type":"chapter-identity-path-conflict"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"severity":"advisory"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"sourceStatus":"out_of_range"' "$TMP_DIR/evidence/static-findings.jsonl"
    [[ "$output" == *'"blockingSignals": 0'* ]]
}

@test "keeps an order conflict blocking when its evidence crosses into the requested range" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/追踪/schema" "$TMP_DIR/追踪"
    printf '# 第050章 正文\n正文。\n' > "$TMP_DIR/正文/第1卷/第050章_正文.md"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":50,"globalDraftOrder":50,"draftPath":"正文/第1卷/第050章_正文.md"}' > "$TMP_DIR/追踪/schema/chapters.jsonl"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":50,"globalDraftOrder":51,"draftPath":"正文/第1卷/第050章_正文.md"}' > "$TMP_DIR/追踪/章节资产.jsonl"

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 51-51 --write --json

    [ "$status" -ne 0 ]
    [[ "$output" == *'"status": "blocked_global_order_conflict"'* ]]
}

@test "does not treat an _original_ backup draft as a filesystem candidate" {
    mkdir -p "$TMP_DIR/正文/第1卷"
    printf '# 第001章 原稿备份\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_原稿_20260711.md"

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-1 --write --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "partial"'* ]]
    [ ! -s "$TMP_DIR/evidence/chapter-evidence.jsonl" ]
    grep -q '"type":"missing-chapter"' "$TMP_DIR/evidence/static-findings.jsonl"
}

@test "does not let an unindexed filesystem-only chapter outside the requested range block authoritative coverage" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/正文/第12卷" "$TMP_DIR/追踪/schema"
    printf '# 第051章 当前正文\n正文。\n' > "$TMP_DIR/正文/第1卷/第051章.md"
    printf '# 第003章 新卷未建索引\n正文。\n' > "$TMP_DIR/正文/第12卷/第003章.md"
    printf '%s\n' '{"chapterId":"第051章","chapterNo":51,"volume":"第1卷","volumeChapterNo":51,"globalDraftOrder":51,"draftPath":"正文/第1卷/第051章.md"}' > "$TMP_DIR/追踪/schema/chapters.jsonl"

    node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 51-51 --write --json > "$TMP_DIR/result.json"

    grep -q '"status": "ok"' "$TMP_DIR/result.json"
    grep -q '"globalDraftOrder":51' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"type":"global-order-incomplete"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"severity":"advisory"' "$TMP_DIR/evidence/static-findings.jsonl"
}

@test "prefers current schema prose over an asset backup path with an advisory" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/追踪/schema" "$TMP_DIR/追踪"
    printf '# 第001章 当前正文\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_当前正文.md"
    printf '# 第001章 原稿备份\n旧正文。\n' > "$TMP_DIR/正文/第1卷/第001章_原稿_20260711.md"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":1,"draftPath":"正文/第1卷/第001章_当前正文.md"}' > "$TMP_DIR/追踪/schema/chapters.jsonl"
    printf '%s\n' '{"volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":99,"draftPath":"正文/第1卷/第001章_原稿_20260711.md"}' > "$TMP_DIR/追踪/章节资产.jsonl"

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-1 --write --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "ok"'* ]]
    grep -q '"path":"正文/第1卷/第001章_当前正文.md"' "$TMP_DIR/evidence/chapter-evidence.jsonl"
    grep -q '"type":"chapter-backup-path-ignored"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '第001章_原稿_20260711.md' "$TMP_DIR/evidence/static-findings.jsonl"
}

@test "blocked batch output limits evidence samples and provides recovery advice" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/追踪/schema" "$TMP_DIR/追踪"
    for order in $(seq 1 8); do
        chapter="$(printf '%03d' "$order")"
        printf '# 第%s章 Schema\n正文。\n' "$chapter" > "$TMP_DIR/正文/第1卷/第${chapter}章_Schema.md"
        printf '# 第%s章 Asset\n正文。\n' "$chapter" > "$TMP_DIR/正文/第1卷/第${chapter}章_Asset.md"
        printf '{"volume":"第1卷","volumeChapterNo":%d,"globalDraftOrder":%d,"draftPath":"正文/第1卷/第%s章_Schema.md"}\n' \
            "$order" "$order" "$chapter" >> "$TMP_DIR/追踪/schema/chapters.jsonl"
        printf '{"volume":"第1卷","volumeChapterNo":%d,"globalDraftOrder":%d,"draftPath":"正文/第1卷/第%s章_Asset.md"}\n' \
            "$order" "$order" "$chapter" >> "$TMP_DIR/追踪/章节资产.jsonl"
    done

    run node "$REPO/scripts/review-batch-evidence-scan.js" --project-root "$TMP_DIR" --range 1-8 --json

    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | node -e '
const fs = require("fs");
const result = JSON.parse(fs.readFileSync(0, "utf8"));
if (!result.blockedEvidence || result.blockedEvidence.samples.length !== 5) process.exit(1);
if (result.blockedEvidence.total <= result.blockedEvidence.samples.length) process.exit(1);
if (!Array.isArray(result.blockedEvidence.recovery) || result.blockedEvidence.recovery.length < 1) process.exit(1);
'
}

@test "treats a volume-local gap as a missing asset when chapterLayout is volume" {
    mkdir -p "$TMP_DIR/正文/第1卷" "$TMP_DIR/正文/第2卷"
    printf '{"chapterLayout":"volume"}\n' > "$TMP_DIR/.book-state.json"
    printf '# 第001章 开端\n正文。\n' > "$TMP_DIR/正文/第1卷/第001章_开端.md"
    printf '# 第002章 续章\n正文。\n' > "$TMP_DIR/正文/第2卷/第002章_续章.md"

    run node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-2 --write --json

    [ "$status" -eq 0 ]
    [[ "$output" == *'"status": "ok"'* ]]
    ! grep -q 'legacy-mixed-layout' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"type":"missing-volume-chapter"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"volume":"第2卷"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"volumeChapterNo":1' "$TMP_DIR/evidence/static-findings.jsonl"
}

@test "records an explicit requested-range gap without inventing a chapter" {
    cp -R "$FIXTURES/missing-range/." "$TMP_DIR/"

    node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-2 --write --json > "$TMP_DIR/result.json"

    [ "$(wc -l < "$TMP_DIR/evidence/chapter-evidence.jsonl")" -eq 1 ]
    grep -q '"type":"missing-chapter"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"globalDraftOrder":2' "$TMP_DIR/evidence/static-findings.jsonl"
}

@test "marks polluted prior reports and excludes them from chapter canon references" {
    cp -R "$FIXTURES/polluted-report/." "$TMP_DIR/"

    node "$REPO/scripts/review-evidence-map.js" "$TMP_DIR" --range 1-1 --write --json > "$TMP_DIR/result.json"

    grep -q '"type":"polluted-prior-report"' "$TMP_DIR/evidence/static-findings.jsonl"
    grep -q '"sourceStatus":"polluted"' "$TMP_DIR/evidence/static-findings.jsonl"
    ! grep -q '审阅报告.md' "$TMP_DIR/evidence/chapter-evidence.jsonl"
}
