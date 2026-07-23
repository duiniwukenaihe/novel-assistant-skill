#!/usr/bin/env bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
}

@test "long-analyze-plan creates resumable chapter and batch indexes" {
    tmp="$(mktemp -d)"
    source="$tmp/source.txt"
    out="$tmp/拆文库/测试书"
    for i in $(seq 1 95); do
        printf '第%03d章 测试标题%03d\n' "$i" "$i" >> "$source"
        printf '这是第%03d章的正文第一段，用来测试机械切章和批次计划。\n' "$i" >> "$source"
        printf '这是第%03d章的正文第二段，避免模型先读完整本书。\n\n' "$i" >> "$source"
    done

    node "$REPO/scripts/long-analyze-plan.js" "$source" "$out" --write --json --batch-size 30 > "$tmp/result.json"

    test -f "$out/原文/原文.txt"
    test -f "$out/章节切片索引.jsonl"
    test -f "$out/批次计划.json"
    test -f "$out/_progress.md"

    node - "$out" "$tmp/result.json" <<'NODE'
const fs = require('fs');
const out = process.argv[2];
const result = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const chapters = fs.readFileSync(`${out}/章节切片索引.jsonl`, 'utf8').trim().split(/\n/).map(JSON.parse);
const plan = JSON.parse(fs.readFileSync(`${out}/批次计划.json`, 'utf8'));
if (result.totalChapters !== 95) process.exit(1);
if (chapters.length !== 95) process.exit(2);
if (plan.batches.length !== 4) process.exit(3);
if (plan.batches[0].startChapter !== 1 || plan.batches[0].endChapter !== 30) process.exit(4);
if (plan.batches[3].startChapter !== 91 || plan.batches[3].endChapter !== 95) process.exit(5);
if (!chapters.every(row => row.startOffset < row.endOffset && row.batchNo >= 1)) process.exit(6);
NODE

    grep -q "schema_version: 3" "$out/_progress.md"
    grep -q "最终状态：pending" "$out/_progress.md"
    grep -q "第1-30章" "$out/_progress.md"
    grep -q "下一操作：Stage 2 从第1章开始" "$out/_progress.md"

    rm -rf "$tmp"
}

@test "long analyze skill documents continuous batch mode without asking after every batch" {
    skill="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    grep -q "无人值守完成模式" "$skill"
    grep -q "默认拆解完成并验证" "$skill"
    grep -q "不得要求用户介入批次推进" "$skill"
    grep -q "连续推进模式" "$skill"
    grep -q "批次不是用户确认点" "$skill"
    grep -q "不得每完成一个批次就要求用户继续" "$skill"
    grep -q "只有接近上下文或工具时间边界" "$skill"
}

@test "long analyze skill requires source-grounding validation before accepting stage2 summaries" {
    skill="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    grep -q "stage2-grounding-check.js" "$skill"
    grep -q "章节切片索引.jsonl" "$skill"
    grep -q "unknown_entities" "$skill"
    grep -q "quote_not_in_source" "$skill"
    grep -q "不得接受" "$skill"
    grep -q "source-grounding" "$skill"
    grep -q "stage2-summary-quality-check.js" "$skill"
    grep -q "不得用.*node -e" "$skill"
    grep -q "Contains expansion" "$skill"
}

@test "long analyze skill forbids write tasks and generic-agent fill for chapter extractor" {
    files=(
        "$REPO/src/internal-skills/story-long-analyze/SKILL.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-long-analyze/SKILL.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-long-analyze/SKILL.md"
    )

    for file in "${files[@]}"; do
        grep -q "chapter-extractor.*只读 agent" "$file"
        grep -q "disallowedTools: \\[Write, Edit, Bash\\]" "$file"
        grep -q "不得.*要求它写" "$file"
        grep -q "主线程把该返回写入" "$file"
        grep -q "paused_after_batch_output_loss" "$file"
        grep -q "blocked_batch_output_loss" "$file"
        grep -q "不得.*general-purpose" "$file"
        grep -q "通用 agent" "$file"
    done
}

@test "stage2 summary quality check detects inline plot point markers" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/章节"
    cat > "$tmp/章节/第1章_摘要.md" <<'MD'
## 第1章

**概要**：测试

**情节点**：

P1 **事件一**：类型行动 | 涉及林雷

原文一

主题标签成长 | 基调：热血 P2 **事件二**：类型冲突 | 涉及林雷

原文二

主题标签成长 | 基调：紧张
MD

    set +e
    out="$(node "$REPO/scripts/stage2-summary-quality-check.js" "$tmp/章节" --json 2>&1)"
    status="$?"
    set -e

    [ "$status" -eq 1 ]
    echo "$out" | grep -q "plot_point_inline_marker"
    echo "$out" | grep -q "检测到 2 个 P 标记"
    rm -rf "$tmp"
}

@test "stage2 grounding check accepts conservative Panlong role aliases" {
    tmp="$(mktemp -d)"
    out="$tmp/拆文库/测试书"
    mkdir -p "$out/原文" "$out/章节"
    cat > "$out/原文/原文.txt" <<'TXT'
第二章 巴鲁克家族
霍格抱着沃顿坐在大厅里，希里站在一旁。德林·柯沃特的声音从盘龙之戒里传来。
TXT
    node - "$out/原文/原文.txt" "$out/章节切片索引.jsonl" <<'NODE'
const fs = require('fs');
const sourcePath = process.argv[2];
const indexPath = process.argv[3];
const source = fs.readFileSync(sourcePath, 'utf8');
fs.writeFileSync(indexPath, `${JSON.stringify({chapterNo: 2, title: '巴鲁克家族', startOffset: 0, endOffset: source.length})}\n`);
NODE
    cat > "$out/章节/第2章_摘要.md" <<'MD'
## 第2章

**出场人物**：

| 角色 | 本章重要性 | 别名 | 状态 |
|---|---|---|---|
| 霍格·巴鲁克 | major | 霍格 | 主持家族 |
| 沃顿 | minor | 小沃顿 | 被照看 |
| 希里 | supporting | 希里爷爷、管家老头 | 在场 |
| 德林柯沃特 | supporting | 德林·柯沃特、白袍老者 | 戒指中出现 |

**情节点**：

P1 **家族大厅**：类型信息揭示 | 涉及霍格·巴鲁克、沃顿、希里、德林柯沃特

霍格抱着沃顿坐在大厅里，希里站在一旁。

主题标签亲情 | 基调：温馨
MD

    node "$REPO/scripts/stage2-grounding-check.js" "$out" --chapters 2 --json > "$tmp/grounding.json"
    node - "$tmp/grounding.json" <<'NODE'
const fs = require('fs');
const grounding = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (grounding.status !== 'pass') {
  console.error(JSON.stringify(grounding.failures));
  process.exit(1);
}
NODE

    rm -rf "$tmp"
}

@test "long analyze skill keeps scripts internal and exposes novel-assistant as the only user entry" {
    skill="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    entry="$REPO/skills/novel-assistant/SKILL.md"
    grep -q "脚本只作为内部执行器" "$skill"
    grep -q "不要把.*node scripts" "$skill"
    grep -q "/novel-assistant 继续拆" "$skill"
    grep -q "用户只说拆书" "$entry"
    grep -q "脚本只作为内部执行器" "$entry"
}

@test "long analyze skill documents long task supervisor mode for recap and api failures" {
    skill="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    entry="$REPO/skills/novel-assistant/SKILL.md"
    grep -q "长任务督导模式" "$skill"
    grep -q "CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0" "$skill"
    grep -q "不得修改用户的 Claude" "$skill"
    grep -q "最多只对该进程临时注入" "$skill"
    grep -q "recap" "$skill"
    grep -q "API error" "$skill"
    grep -q "不得依赖用户手动输入继续" "$skill"
    grep -q "长任务督导模式" "$entry"
    grep -q "不得修改用户的 Claude" "$entry"
    grep -q "前端或启动器" "$entry"
}

@test "long analyze skill defaults large books to fast source grounded mode" {
    skill="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    agent="$REPO/src/internal-skills/story-setup/references/templates/agents/chapter-extractor.md"
    entry="$REPO/skills/novel-assistant/SKILL.md"

    grep -q "快速源锚模式" "$skill"
    grep -q ">200 章强制优先" "$skill"
    grep -q "不得让 600 章默认全量深拆" "$skill"
    grep -q "OUTPUT_PROFILE: fast_source_grounded|deep" "$skill"
    grep -q "大书默认快拆" "$entry"

    grep -q "OUTPUT_PROFILE" "$agent"
    grep -q "fast_source_grounded" "$agent"
    grep -q "6-12 个关键情节点" "$agent"
    grep -q "deep" "$agent"
    grep -q "10-40 个动态情节点" "$agent"
}

@test "long analyze skill gates parallel agent availability for large books" {
    skill="$REPO/src/internal-skills/story-long-analyze/SKILL.md"

    grep -q "Agent 可用性门禁" "$skill"
    grep -q "运行时是否已经暴露.*chapter-extractor" "$skill"
    grep -q ".claude/agents/chapter-extractor.md" "$skill"
    grep -q "story-setup.*安全刷新" "$skill"
    grep -q "不得静默退回主线程串行处理 200+ 章深拆" "$skill"
    grep -q "bounded fast fallback" "$skill"
    grep -q "连续 3 个小并发批次未被实际使用" "$skill"
}

@test "long analyze skill forbids broad filesystem search for chapter extractor" {
    files=(
        "$REPO/src/internal-skills/story-long-analyze/SKILL.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-long-analyze/SKILL.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-long-analyze/SKILL.md"
    )

    for file in "${files[@]}"; do
        grep -q "不得.*find /" "$file"
        grep -q "不得.*find ~" "$file"
        grep -q "不得.*mdfind" "$file"
        grep -q "固定位置的 bundled template" "$file"
        grep -q "不能证明 agent 可用" "$file"
    done
}

@test "long analyze keeps emotionally critical minor characters as standalone role files" {
    skill="$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    bundle="$REPO/skills/novel-assistant/references/internal-skills/story-long-analyze/SKILL.md"
    compat="$REPO/skills/novel-assistant/references/internal-skills/story-long-analyze/SKILL.md"

    for file in "$skill" "$bundle" "$compat"; do
        grep -q "角色独立成档规则" "$file"
        grep -q "关键 minor 角色不得吞并" "$file"
        grep -q "只按出场频次" "$file"
        grep -q "金手指激活" "$file"
        grep -q "沃顿" "$file"
        grep -q "希里" "$file"
        grep -q "未独立成档角色" "$file"
    done
}

@test "chapter extractor templates require standalone P blocks with per-point tone and topic" {
    files=(
        "$REPO/src/internal-skills/story-setup/references/templates/agents/chapter-extractor.md"
        "$REPO/src/internal-skills/story-setup/references/opencode/agents/chapter-extractor.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-setup/references/templates/agents/chapter-extractor.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-setup/references/opencode/agents/chapter-extractor.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-setup/references/templates/agents/chapter-extractor.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-setup/references/opencode/agents/chapter-extractor.md"
        "$REPO/src/internal-skills/story-long-analyze/references/output-templates.md"
        "$REPO/skills/novel-assistant/references/internal-skills/story-long-analyze/references/output-templates.md"
    )

    for file in "${files[@]}"; do
        grep -q "P 块硬约束" "$file"
        grep -q "必须在行首" "$file"
        grep -q "每个 P 块都必须有且只有一行" "$file"
        grep -q "主题标签.*基调：" "$file"
    done
}

@test "long analyze recovery state detects first missing chapter and quota block" {
    tmp="$(mktemp -d)"
    out="$tmp/拆文库/测试书"
    mkdir -p "$out/章节"
    cat > "$out/批次计划.json" <<'JSON'
{"totalChapters":5,"batches":[{"startChapter":1,"endChapter":5}]}
JSON
    for n in 1 2 4; do
        printf '## 第%d章\n\n**概要**：测试\n' "$n" > "$out/章节/第${n}章_摘要.md"
    done
    printf 'API Error: Token Plan quota exceeded\n' > "$tmp/run.log"

    node "$REPO/scripts/long-analyze-recovery-state.js" "$out" --log "$tmp/run.log" --write --json > "$tmp/state.json"

    test -f "$out/_recovery-state.json"
    node - "$tmp/state.json" <<'NODE'
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (state.totalChapters !== 5) process.exit(1);
if (state.summaryCount !== 3) process.exit(2);
if (state.continuousComplete !== 2) process.exit(3);
if (state.firstMissing !== 3) process.exit(4);
if (state.action !== 'external_blocked_quota') process.exit(5);
if (state.lastError.type !== 'quota_exhausted') process.exit(6);
NODE

    rm -rf "$tmp"
}

@test "stage2 quote repair replaces paraphrased quotes with exact source text" {
    tmp="$(mktemp -d)"
    out="$tmp/拆文库/测试书"
    mkdir -p "$out/原文" "$out/章节"
    cat > "$out/原文/原文.txt" <<'TXT'
第一章 恩斯特学院
林雷走进恩斯特学院的大门，心里第一次明白魔法师的世界有多么辽阔。
德林柯沃特在盘龙之戒中低声提醒他，不要急着暴露自己的天赋。
TXT
    node - "$out/原文/原文.txt" "$out/章节切片索引.jsonl" <<'NODE'
const fs = require('fs');
const sourcePath = process.argv[2];
const indexPath = process.argv[3];
const source = fs.readFileSync(sourcePath, 'utf8');
fs.writeFileSync(indexPath, `${JSON.stringify({chapterNo: 1, title: '恩斯特学院', startOffset: 0, endOffset: source.length})}\n`);
NODE
    cat > "$out/章节/第1章_摘要.md" <<'MD'
## 第1章

**出场人物**：

| 角色 | 本章重要性 | 别名 | 状态 |
|---|---|---|---|
| 林雷 | major |  | 入学 |

**情节点**：

P1 **林雷入学**：类型行动 | 涉及林雷

林雷进入学院，感到魔法世界很广阔。

主题标签成长 | 基调：期待

P2 **德林提醒**：类型信息揭示 | 涉及德林柯沃特

德林在戒指里提醒他隐藏天赋。

主题标签师徒 | 基调：谨慎
MD

    set +e
    before="$(node "$REPO/scripts/stage2-grounding-check.js" "$out" --chapters 1 --json 2>&1)"
    before_status="$?"
    set -e
    [ "$before_status" -eq 1 ]
    echo "$before" | grep -q "quote_not_in_source"

    node "$REPO/scripts/stage2-quote-repair.js" "$out" --chapters 1 --json > "$tmp/repair.json"
    node "$REPO/scripts/stage2-grounding-check.js" "$out" --chapters 1 --json > "$tmp/grounding.json"

    node - "$tmp/repair.json" "$tmp/grounding.json" "$out/章节/第1章_摘要.md" <<'NODE'
const fs = require('fs');
const repair = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const grounding = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const summary = fs.readFileSync(process.argv[4], 'utf8');
if (repair.repairedBlocks !== 2) process.exit(1);
if (grounding.status !== 'pass') process.exit(2);
if (!summary.includes('林雷走进恩斯特学院的大门')) process.exit(3);
if (!summary.includes('德林柯沃特在盘龙之戒中低声提醒他')) process.exit(4);
NODE

    rm -rf "$tmp"
}

@test "stage2 grounding check ignores ordinal clan-title labels" {
    tmp="$(mktemp -d)"
    out="$tmp/拆文库/测试书"
    mkdir -p "$out/原文" "$out/章节"
    cat > "$out/原文/原文.txt" <<'TXT'
第一章 龙血家族
林雷翻开族谱，看见一位先祖曾在芬莱王国留下旧事。
TXT
    node - "$out/原文/原文.txt" "$out/章节切片索引.jsonl" <<'NODE'
const fs = require('fs');
const sourcePath = process.argv[2];
const indexPath = process.argv[3];
const source = fs.readFileSync(sourcePath, 'utf8');
fs.writeFileSync(indexPath, `${JSON.stringify({chapterNo: 1, title: '龙血家族', startOffset: 0, endOffset: source.length})}\n`);
NODE
    cat > "$out/章节/第1章_摘要.md" <<'MD'
## 第1章

**出场人物**：

| 角色 | 本章重要性 | 别名 | 状态 |
|---|---|---|---|
| 林雷 | major | 第三代族长 | 读族谱 |

**情节点**：

P1 **族谱信息**：类型信息揭示 | 涉及林雷

林雷翻开族谱，看见一位先祖曾在芬莱王国留下旧事。

主题标签家族 | 基调：沉静
MD

    node "$REPO/scripts/stage2-grounding-check.js" "$out" --chapters 1 --json > "$tmp/grounding.json"
    node - "$tmp/grounding.json" <<'NODE'
const fs = require('fs');
const grounding = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (grounding.status !== 'pass') process.exit(1);
NODE

    rm -rf "$tmp"
}
