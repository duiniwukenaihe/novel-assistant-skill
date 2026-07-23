#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIXTURE="$REPO/tests/fixtures/volume-chapter-versioning"
    TMP_DIR="$(mktemp -d)"
    cp -R "$FIXTURE/." "$TMP_DIR/"
}

teardown() {
    rm -rf "$TMP_DIR"
}

@test "story schema reads volume-local chapter paths" {
    node "$REPO/scripts/story-schema-build.js" "$TMP_DIR" --write --json > "$TMP_DIR/schema.json"

    grep -q '"volume": "第1卷"' "$TMP_DIR/schema.json"
    grep -q '"volumeChapterNo": 1' "$TMP_DIR/schema.json"
    grep -q '"draftPath": "正文/第1卷/第001章_穿越觉醒.md"' "$TMP_DIR/schema.json"
    grep -q '"title": "穿越觉醒"' "$TMP_DIR/schema.json"
    node "$REPO/scripts/story-schema-validate.js" "$TMP_DIR"
}

@test "chapter asset builder preserves title and volume-local numbering" {
    node "$REPO/scripts/chapter-assets-build.js" "$TMP_DIR" --write --json > "$TMP_DIR/assets.json"

    grep -q '"title": "穿越觉醒"' "$TMP_DIR/assets.json"
    grep -q '"volume": "第1卷"' "$TMP_DIR/assets.json"
    grep -q '"volumeChapterNo": 1' "$TMP_DIR/assets.json"
    grep -q '"draftPath":"正文/第1卷/第001章_穿越觉醒.md"' "$TMP_DIR/追踪/章节资产.jsonl"
}

@test "chapter asset builder prefers volume-local draft over legacy flat duplicate" {
    mkdir -p "$TMP_DIR/正文"
    printf '# 第001章 旧扁平坏稿\n旧稿。\n' > "$TMP_DIR/正文/第001章_旧扁平坏稿.md"

    node "$REPO/scripts/chapter-assets-build.js" "$TMP_DIR" --write --json > "$TMP_DIR/assets.json"

    grep -q '"draftPath":"正文/第1卷/第001章_穿越觉醒.md"' "$TMP_DIR/追踪/章节资产.jsonl"
    ! grep -q '"draftPath":"正文/第001章_旧扁平坏稿.md"' "$TMP_DIR/追踪/章节资产.jsonl"
}

@test "version snapshot captures selected writing artifacts" {
    node "$REPO/scripts/chapter-assets-build.js" "$TMP_DIR" --write
    node "$REPO/scripts/story-version-snapshot.js" "$TMP_DIR" --reason "expand-volume-1" --files "正文/第1卷/第001章_穿越觉醒.md,追踪/章节资产.jsonl" --write --json > "$TMP_DIR/snapshot.json"

    grep -q '"reason": "expand-volume-1"' "$TMP_DIR/snapshot.json"
    snapshot_dir="$(node -e "const fs=require('fs'); const j=JSON.parse(fs.readFileSync('$TMP_DIR/snapshot.json','utf8')); console.log(j.snapshotPath)")"
    [ -f "$TMP_DIR/$snapshot_dir/manifest.json" ]
    [ -f "$TMP_DIR/$snapshot_dir/正文/第1卷/第001章_穿越觉醒.md" ]
    [ -f "$TMP_DIR/$snapshot_dir/追踪/章节资产.jsonl" ]
}

@test "publish export renumbers globally and preserves original titles" {
    node "$REPO/scripts/chapter-assets-build.js" "$TMP_DIR" --write
    node "$REPO/scripts/publish-export.js" "$TMP_DIR" --write --json > "$TMP_DIR/export.json"

    [ -f "$TMP_DIR/导出/发布版/第001章_穿越觉醒.md" ]
    [ -f "$TMP_DIR/导出/发布版/第002章_巴掌大黑狗崽.md" ]
    [ -f "$TMP_DIR/导出/发布版/第003章_御兽宗来人.md" ]
    ! find "$TMP_DIR/导出/发布版" -name '*某章*' | grep -q .
    ! find "$TMP_DIR/导出/发布版" -name '*-1章*' | grep -q .
}

@test "long write documents expansion transaction before filling gaps" {
    long_write="$REPO/src/internal-skills/story-long-write/SKILL.md"
    workflow="$REPO/src/internal-skills/story-workflow/SKILL.md"
    top="$REPO/skills/novel-assistant/SKILL.md"

    grep -q "扩容事务协议" "$long_write"
    grep -q "先生成后移映射" "$long_write"
    grep -q "原章节名和可用正文资产" "$long_write"
    grep -q "先后移旧章节资产，再补新增缺口" "$long_write"
    grep -q "同步大纲、卷纲、细纲、正文、章节契约、交接包、伏笔、时间线和角色状态" "$long_write"
    grep -q "chapter-assets-build.js" "$long_write"
    grep -q "story-version-snapshot.js" "$long_write"
    grep -q "revision-stability-recheck.sh" "$long_write"

    grep -q "扩容事务协议" "$workflow"
    grep -q "后移映射" "$workflow"
    grep -q "不得直接进入补卷纲或补细纲" "$workflow"

    grep -q "扩容事务协议" "$top"
    grep -q "先做扩容影响分析" "$top"
}

@test "daily writing separates volume chapter number from global draft order" {
    daily="$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"
    long_write="$REPO/src/internal-skills/story-long-write/SKILL.md"

    grep -q "卷内编号 N 与全书草稿顺序分离" "$daily"
    grep -q "第2卷必须从第001章开始" "$daily"
    grep -q "不得用 currentChapter 或 globalDraftOrder 生成正文文件名" "$daily"
    grep -q "混合结构" "$daily"
    grep -q "blocked_mixed_chapter_layout" "$daily"

    grep -q "第2卷必须从第001章开始" "$long_write"
    grep -q "正文/第2卷/第001章_章名.md" "$long_write"
}

@test "daily writing genre detail wording does not default to cultivation" {
    daily="$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"
    top="$REPO/skills/novel-assistant/SKILL.md"

    grep -q "补字/扩写细节不得默认修真" "$daily"
    grep -q "修真实战细节" "$daily"
    grep -q "只有题材证据明确为修真/仙侠时才可使用" "$daily"
    grep -q "能力运用、动作交锋、环境压力、厨艺动作、人物反应" "$daily"

    grep -q "补字/扩写细节不得默认修真" "$top"
}

@test "book state docs prefer volume-local fields over currentChapter for paths" {
    setup_skill="$REPO/src/internal-skills/story-setup/SKILL.md"
    explorer="$REPO/src/internal-skills/story-setup/references/templates/agents/story-explorer.md"
    daily="$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"

    grep -q "currentVolumeChapter" "$setup_skill"
    grep -q "globalDraftOrder" "$setup_skill"
    grep -q "currentDraftPath" "$setup_skill"
    grep -q "currentChapter 仅表示旧项目/全书进度" "$setup_skill"

    grep -q "currentDraftPath" "$explorer"
    grep -q "currentVolume.*currentVolumeChapter" "$explorer"
    grep -q "currentChapter.*旧扁平" "$explorer"

    grep -q "currentVolumeChapter" "$daily"
    grep -q "currentDraftPath" "$daily"
}

@test "progress status reports volume-local current position without old global range wording" {
    node "$REPO/scripts/chapter-assets-build.js" "$TMP_DIR" --write
    node "$REPO/scripts/story-progress-status.js" "$TMP_DIR" --json > "$TMP_DIR/progress.json"

    grep -q '"status": "ok"' "$TMP_DIR/progress.json"
    grep -q '"currentVolume": "第2卷"' "$TMP_DIR/progress.json"
    grep -q '"currentVolumeChapter": 1' "$TMP_DIR/progress.json"
    grep -q '"globalDraftOrder": 3' "$TMP_DIR/progress.json"
    grep -q '"display": "第2卷第001章' "$TMP_DIR/progress.json"
    ! grep -q "第27-32" "$TMP_DIR/progress.json"
    ! grep -q "32/50" "$TMP_DIR/progress.json"
}

@test "progress status blocks mixed volume directory with global numbering" {
    mixed="$(mktemp -d)"
    mkdir -p "$mixed/正文/第1卷" "$mixed/正文/第2卷" "$mixed/大纲/第2卷" "$mixed/追踪/交接包/第2卷"
    printf '# 第001章 开局\n正文。\n' > "$mixed/正文/第1卷/第001章_开局.md"
    printf '# 第027章 禁闭第一夜\n正文。\n' > "$mixed/正文/第2卷/第027章_禁闭第一夜.md"
    printf '# 第028章 禁闭第二夜\n正文。\n' > "$mixed/正文/第2卷/第028章_禁闭第二夜.md"
    printf '# 交接\n第027章_to_第028章\n' > "$mixed/追踪/交接包/第2卷/第027章_to_第028章.md"
    printf '# 卷纲\n第027章 禁闭第一夜\n' > "$mixed/大纲/第2卷/卷纲.md"
    mkdir -p "$mixed/追踪"
    printf 'F001 | 第027章 | 禁闭伏笔\n' > "$mixed/追踪/伏笔.md"
    printf '{"chapterLayout":"volume","preferredVolume":"第2卷","currentVolume":"第2卷","currentChapter":28}\n' > "$mixed/.book-state.json"

    status=0
    node "$REPO/scripts/story-progress-status.js" "$mixed" --json > "$mixed/progress.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_mixed_chapter_layout"' "$mixed/progress.json"
    grep -q '"volume": "第2卷"' "$mixed/progress.json"
    grep -q '"source": "正文/第2卷/第027章_禁闭第一夜.md"' "$mixed/progress.json"
    grep -q '"target": "正文/第2卷/第001章_禁闭第一夜.md"' "$mixed/progress.json"
    grep -q '"source": "追踪/交接包/第2卷/第027章_to_第028章.md"' "$mixed/progress.json"
    grep -q '"target": "追踪/交接包/第2卷/第001章_to_第002章.md"' "$mixed/progress.json"
    grep -q '"path": "大纲/第2卷/卷纲.md"' "$mixed/progress.json"
    grep -q '"path": "追踪/伏笔.md"' "$mixed/progress.json"
    grep -q "迁移到卷内编号结构" "$mixed/progress.json"
    grep -q "保持旧结构兼容" "$mixed/progress.json"

    rm -rf "$mixed"
}

@test "generic agents use dynamic genre progress terms instead of default cultivation" {
    checker="$REPO/src/internal-skills/story-setup/references/templates/agents/consistency-checker.md"
    explorer="$REPO/src/internal-skills/story-setup/references/templates/agents/story-explorer.md"
    workflow="$REPO/src/internal-skills/story-workflow/SKILL.md"

    grep -q "能力/成长规则" "$checker"
    grep -q "战力/能力边界" "$checker"
    grep -q "仅当项目题材证据为修真/仙侠时显示为修真进度" "$checker"
    grep -q "不得把非修真项目机械命名为.*力量体系" "$checker"
    ! grep -q "^- 修真进度与主线连续性" "$checker"

    grep -q "能力/成长规则扫描" "$explorer"
    grep -q "仅当项目题材证据为修真/仙侠时才显示为修真进度扫描" "$explorer"

    grep -q "设定/能力与规则矩阵" "$workflow"
    grep -q "仅当项目题材证据为修真/仙侠时才命名为修真进度矩阵" "$workflow"
}

@test "setup migration moves legacy flat chapters into volume layout" {
    legacy="$(mktemp -d)"
    mkdir -p "$legacy/大纲" "$legacy/正文" "$legacy/追踪/章节契约" "$legacy/追踪/交接包"
    printf '# 第001章 穿越觉醒\n' > "$legacy/大纲/细纲_第001章.md"
    printf '# 第001章 穿越觉醒\n正文。\n' > "$legacy/正文/第001章_穿越觉醒.md"
    printf '# 第001章契约\n' > "$legacy/追踪/章节契约/第001章.md"
    printf '# 第001章_to_第002章\n' > "$legacy/追踪/交接包/第001章_to_第002章.md"

    node "$REPO/scripts/story-project-migrate.js" "$legacy" --write --json > "$legacy/migrate.json"
    node "$REPO/scripts/chapter-assets-build.js" "$legacy" --write
    node "$REPO/scripts/story-schema-build.js" "$legacy" --write
    node "$REPO/scripts/story-schema-validate.js" "$legacy"

    [ -f "$legacy/大纲/第1卷/细纲_第001章.md" ]
    [ -f "$legacy/正文/第1卷/第001章_穿越觉醒.md" ]
    [ -f "$legacy/追踪/章节契约/第1卷/第001章.md" ]
    [ -f "$legacy/追踪/交接包/第1卷/第001章_to_第002章.md" ]
    [ ! -f "$legacy/正文/第001章_穿越觉醒.md" ]
    find "$legacy/追踪/版本" -path '*/legacy-flat-layout/正文/第001章_穿越觉醒.md' | grep -q .
    rm -rf "$legacy"
}

@test "setup migration detects and plans global-numbered files inside later volume folders" {
    mixed="$(mktemp -d)"
    mkdir -p "$mixed/正文/第2卷" "$mixed/大纲/第2卷" "$mixed/追踪/章节契约/第2卷" "$mixed/追踪/交接包/第2卷"
    printf '# 第027章 禁闭第一夜\n' > "$mixed/正文/第2卷/第027章_禁闭第一夜.md"
    printf '# 第028章 禁闭第二夜\n' > "$mixed/正文/第2卷/第028章_禁闭第二夜.md"
    printf '# 第027章细纲\n' > "$mixed/大纲/第2卷/细纲_第027章.md"
    printf '# 第027章契约\n' > "$mixed/追踪/章节契约/第2卷/第027章.md"
    printf '# 第027章_to_第028章\n' > "$mixed/追踪/交接包/第2卷/第027章_to_第028章.md"

    node "$REPO/scripts/story-project-migrate.js" "$mixed" --json > "$mixed/dry.json"

    grep -q '"reason": "volume_global_numbering"' "$mixed/dry.json"
    grep -q '"source": "正文/第2卷/第027章_禁闭第一夜.md"' "$mixed/dry.json"
    grep -q '"target": "正文/第2卷/第001章_禁闭第一夜.md"' "$mixed/dry.json"
    grep -q '"target": "大纲/第2卷/细纲_第001章.md"' "$mixed/dry.json"
    grep -q '"target": "追踪/章节契约/第2卷/第001章.md"' "$mixed/dry.json"
    grep -q '"target": "追踪/交接包/第2卷/第001章_to_第002章.md"' "$mixed/dry.json"

    node "$REPO/scripts/story-project-migrate.js" "$mixed" --write --json > "$mixed/write.json"

    [ -f "$mixed/正文/第2卷/第001章_禁闭第一夜.md" ]
    [ -f "$mixed/正文/第2卷/第002章_禁闭第二夜.md" ]
    [ -f "$mixed/大纲/第2卷/细纲_第001章.md" ]
    [ -f "$mixed/追踪/章节契约/第2卷/第001章.md" ]
    [ -f "$mixed/追踪/交接包/第2卷/第001章_to_第002章.md" ]
    [ ! -f "$mixed/正文/第2卷/第027章_禁闭第一夜.md" ]
    find "$mixed/追踪/版本" -path '*/legacy-flat-layout/正文/第2卷/第027章_禁闭第一夜.md' | grep -q .

    rm -rf "$mixed"
}

@test "setup migration dry-run reports reference updates before writing" {
    mixed="$(mktemp -d)"
    mkdir -p "$mixed/正文/第2卷" "$mixed/大纲/第2卷" "$mixed/追踪"
    printf '# 第027章 禁闭第一夜\n正文。\n' > "$mixed/正文/第2卷/第027章_禁闭第一夜.md"
    printf '# 第028章 禁闭第二夜\n正文。\n' > "$mixed/正文/第2卷/第028章_禁闭第二夜.md"
    printf '# 卷纲\n第027章 禁闭第一夜\n第028章 禁闭第二夜\n' > "$mixed/大纲/第2卷/卷纲.md"
    printf 'F001 | 第027章 | 禁闭伏笔\n' > "$mixed/追踪/伏笔.md"
    printf '第028章：禁闭第二夜\n' > "$mixed/追踪/时间线.md"

    node "$REPO/scripts/story-project-migrate.js" "$mixed" --json > "$mixed/dry.json"

    grep -q '"status": "needs_action"' "$mixed/dry.json"
    grep -q '"referenceUpdates"' "$mixed/dry.json"
    grep -q '"path": "大纲/第2卷/卷纲.md"' "$mixed/dry.json"
    grep -q '"path": "追踪/伏笔.md"' "$mixed/dry.json"
    grep -q '"path": "追踪/时间线.md"' "$mixed/dry.json"
    grep -q "第027章" "$mixed/追踪/伏笔.md"

    rm -rf "$mixed"
}

@test "expansion plan shifts later chapter assets before filling inserted gaps" {
    book="$(mktemp -d)"
    mkdir -p "$book/正文/第2卷" "$book/大纲/第2卷" "$book/追踪/章节契约/第2卷" "$book/追踪/交接包/第2卷" "$book/追踪/schema"
    printf '# 第001章 已有一\n正文。\n' > "$book/正文/第2卷/第001章_已有一.md"
    printf '# 第002章 已有二\n正文。\n' > "$book/正文/第2卷/第002章_已有二.md"
    printf '# 第003章 已有三\n正文。\n' > "$book/正文/第2卷/第003章_已有三.md"
    printf '# 第002章细纲\n' > "$book/大纲/第2卷/细纲_第002章.md"
    printf '# 第003章细纲\n' > "$book/大纲/第2卷/细纲_第003章.md"
    printf '# 第002章契约\n' > "$book/追踪/章节契约/第2卷/第002章.md"
    printf '# 第002章_to_第003章\n' > "$book/追踪/交接包/第2卷/第002章_to_第003章.md"
    printf '# 卷纲\n第002章 已有二\n第003章 已有三\n' > "$book/大纲/第2卷/卷纲.md"
    printf 'F001 | 第002章 | 已有二钩子\n' > "$book/追踪/伏笔.md"
    printf '第003章：已有三\n' > "$book/追踪/时间线.md"
    cat > "$book/追踪/schema/plot-units.jsonl" <<'JSONL'
{"schemaVersion":"1.0.0","id":"PU-V02-001","volume":"第2卷","chapterRange":{"start":2,"end":3},"planningMode":"hard","planningState":"locked","chapters":[{"volume":"第2卷","volumeChapterNo":2,"drafted":true},{"volume":"第2卷","volumeChapterNo":3,"drafted":true}]}
JSONL

    node "$REPO/scripts/story-expansion-plan.js" "$book" --volume 第2卷 --insert-after 1 --count 2 --json > "$book/plan.json"

    grep -q '"status": "needs_action"' "$book/plan.json"
    grep -q '"gapRange"' "$book/plan.json"
    grep -q '"start": 2' "$book/plan.json"
    grep -q '"end": 3' "$book/plan.json"
    grep -q '"source": "正文/第2卷/第002章_已有二.md"' "$book/plan.json"
    grep -q '"target": "正文/第2卷/第004章_已有二.md"' "$book/plan.json"
    grep -q '"source": "追踪/交接包/第2卷/第002章_to_第003章.md"' "$book/plan.json"
    grep -q '"target": "追踪/交接包/第2卷/第004章_to_第005章.md"' "$book/plan.json"
    grep -q '"path": "大纲/第2卷/卷纲.md"' "$book/plan.json"
    grep -q '"path": "追踪/伏笔.md"' "$book/plan.json"
    grep -q '"id": "PU-V02-001"' "$book/plan.json"
    grep -q '"id": "GAP-2-2-3"' "$book/plan.json"

    node "$REPO/scripts/story-expansion-plan.js" "$book" --volume 第2卷 --insert-after 1 --count 2 --write --json > "$book/write.json"

    [ -f "$book/正文/第2卷/第004章_已有二.md" ]
    [ -f "$book/正文/第2卷/第005章_已有三.md" ]
    [ ! -f "$book/正文/第2卷/第002章_已有二.md" ]
    [ ! -f "$book/正文/第2卷/第003章_已有三.md" ]
    [ ! -f "$book/正文/第2卷/第002章_新增过渡.md" ]
    grep -q "# 第004章 已有二" "$book/正文/第2卷/第004章_已有二.md"
    grep -q "第004章 已有二" "$book/大纲/第2卷/卷纲.md"
    grep -q "第005章 已有三" "$book/大纲/第2卷/卷纲.md"
    grep -q "F001 | 第004章 | 已有二钩子" "$book/追踪/伏笔.md"
    grep -q "第005章：已有三" "$book/追踪/时间线.md"
    [ -f "$book/追踪/交接包/第2卷/第004章_to_第005章.md" ]
    grep -q '"start":4,"end":5' "$book/追踪/schema/plot-units.jsonl"
    grep -q '"planningState":"locked"' "$book/追踪/schema/plot-units.jsonl"
    grep -q '"id":"GAP-2-2-3"' "$book/追踪/schema/expansion-gaps.jsonl"
    find "$book/追踪/版本" -path '*/before-expansion/正文/第2卷/第002章_已有二.md' | grep -q .

    rm -rf "$book"
}

@test "expansion plan blocks mixed global-numbered volume before shifting" {
    book="$(mktemp -d)"
    mkdir -p "$book/正文/第2卷"
    printf '# 第027章 旧二十七\n' > "$book/正文/第2卷/第027章_旧二十七.md"
    printf '# 第028章 旧二十八\n' > "$book/正文/第2卷/第028章_旧二十八.md"

    status=0
    node "$REPO/scripts/story-expansion-plan.js" "$book" --volume 第2卷 --insert-after 27 --count 2 --json > "$book/plan.json" || status=$?

    [ "$status" -eq 2 ]
    grep -q '"status": "blocked_mixed_chapter_layout"' "$book/plan.json"
    grep -q "必须先迁移章节结构" "$book/plan.json"

    rm -rf "$book"
}

@test "setup migration reports needs_action for dry-run plans" {
    mixed="$(mktemp -d)"
    mkdir -p "$mixed/正文/第2卷"
    printf '# 第027章 禁闭第一夜\n' > "$mixed/正文/第2卷/第027章_禁闭第一夜.md"

    node "$REPO/scripts/story-project-migrate.js" "$mixed" --json > "$mixed/dry.json"

    grep -q '"status": "needs_action"' "$mixed/dry.json"
    grep -q '"actions"' "$mixed/dry.json"

    rm -rf "$mixed"
}

@test "volume renumber migration uses one shared map across chapter artifacts" {
    mixed="$(mktemp -d)"
    mkdir -p "$mixed/正文/第2卷" "$mixed/大纲/第2卷" "$mixed/追踪/章节契约/第2卷" "$mixed/追踪/交接包/第2卷"
    printf '# 第027章 禁闭第一夜\n正文。\n' > "$mixed/正文/第2卷/第027章_禁闭第一夜.md"
    printf '# 第028章 禁闭第二夜\n正文。\n' > "$mixed/正文/第2卷/第028章_禁闭第二夜.md"
    printf '# 第029章 禁闭第三夜\n正文。\n' > "$mixed/正文/第2卷/第029章_禁闭第三夜.md"
    printf '# 第028章细纲\n' > "$mixed/大纲/第2卷/细纲_第028章.md"
    printf '# 第029章契约\n' > "$mixed/追踪/章节契约/第2卷/第029章.md"
    printf '# 第028章_to_第029章\n' > "$mixed/追踪/交接包/第2卷/第028章_to_第029章.md"

    node "$REPO/scripts/story-project-migrate.js" "$mixed" --write --json > "$mixed/write.json"

    [ -f "$mixed/正文/第2卷/第001章_禁闭第一夜.md" ]
    [ -f "$mixed/正文/第2卷/第002章_禁闭第二夜.md" ]
    [ -f "$mixed/正文/第2卷/第003章_禁闭第三夜.md" ]
    [ -f "$mixed/大纲/第2卷/细纲_第002章.md" ]
    [ -f "$mixed/追踪/章节契约/第2卷/第003章.md" ]
    [ -f "$mixed/追踪/交接包/第2卷/第002章_to_第003章.md" ]
    [ ! -f "$mixed/大纲/第2卷/细纲_第001章.md" ]

    rm -rf "$mixed"
}

@test "volume renumber migration rewrites internal chapter references and book state" {
    mixed="$(mktemp -d)"
    mkdir -p "$mixed/正文/第2卷" "$mixed/大纲/第2卷" "$mixed/追踪/章节契约/第2卷" "$mixed/追踪"
    cat > "$mixed/.book-state.json" <<'JSON'
{
  "bookTitle": "测试书",
  "currentChapter": 29,
  "preferredVolume": "第2卷",
  "currentOutline": "大纲/第2卷/细纲_第029章.md",
  "chapterLayout": "volume"
}
JSON
    printf '# 第029章 禁闭第三夜\n参见第028章。\n' > "$mixed/正文/第2卷/第029章_禁闭第三夜.md"
    printf '# 第029章细纲\n承接第028章。\n' > "$mixed/大纲/第2卷/细纲_第029章.md"
    printf '# 第029章契约\n' > "$mixed/追踪/章节契约/第2卷/第029章.md"
    printf '# 第2卷卷纲\n第029章解除禁闭，承接第028章。\n' > "$mixed/大纲/第2卷/卷纲.md"
    printf '# 全书大纲\n第2卷第029章是转折点。\n' > "$mixed/大纲/大纲.md"
    printf 'F001 | 第029章 | 禁闭解除\n' > "$mixed/追踪/伏笔.md"
    printf '第029章：禁闭解除\n' > "$mixed/追踪/时间线.md"
    printf '最后写到第029章。\n' > "$mixed/追踪/上下文.md"

    node "$REPO/scripts/story-project-migrate.js" "$mixed" --write --json > "$mixed/write.json"

    [ -f "$mixed/正文/第2卷/第001章_禁闭第三夜.md" ]
    grep -q "# 第001章 禁闭第三夜" "$mixed/正文/第2卷/第001章_禁闭第三夜.md"
    grep -q "# 第001章细纲" "$mixed/大纲/第2卷/细纲_第001章.md"
    grep -q "第001章解除禁闭" "$mixed/大纲/第2卷/卷纲.md"
    grep -q "第2卷第001章" "$mixed/大纲/大纲.md"
    grep -q "F001 | 第001章 | 禁闭解除" "$mixed/追踪/伏笔.md"
    grep -q "第001章：禁闭解除" "$mixed/追踪/时间线.md"
    grep -q "最后写到第001章" "$mixed/追踪/上下文.md"
    grep -q '"referenceUpdates"' "$mixed/write.json"
    grep -q '"currentVolume": "第2卷"' "$mixed/.book-state.json"
    grep -q '"currentVolumeChapter": 1' "$mixed/.book-state.json"
    grep -q '"globalDraftOrder": 29' "$mixed/.book-state.json"
    grep -q '"currentDraftPath": "正文/第2卷/第001章_禁闭第三夜.md"' "$mixed/.book-state.json"
    grep -q '"currentOutline": "大纲/第2卷/细纲_第001章.md"' "$mixed/.book-state.json"

    rm -rf "$mixed"
}
