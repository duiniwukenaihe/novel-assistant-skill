#!/usr/bin/env bats
# tests/test-longform-stability.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    REVIEW="$REPO/src/internal-skills/story-review"
    SETUP="$REPO/src/internal-skills/story-setup"
    NOVEL_ASSISTANT="$REPO/skills/novel-assistant"
}

@test "longform stability references exist" {
    [ -f "$LONG_WRITE/references/chapter-contract.md" ]
    [ -f "$LONG_WRITE/references/plot-drift-control.md" ]
    [ -f "$LONG_WRITE/references/state-delta-ledger.md" ]
    [ -f "$LONG_WRITE/references/character-invariants.md" ]
    [ -f "$LONG_WRITE/references/revision-impact-analysis.md" ]
    [ -f "$LONG_WRITE/references/chapter-handoff-pack.md" ]
    [ -f "$LONG_WRITE/references/cross-chapter-continuity-audit.md" ]
    [ -f "$LONG_WRITE/references/longform-daily-stability-audit.md" ]
    [ -f "$LONG_WRITE/references/stability-repair-dispatcher.md" ]
    [ -f "$LONG_WRITE/references/stability-repair-loop.md" ]
    [ -f "$LONG_WRITE/references/stability-agent-dispatch-prompts.md" ]
    [ -f "$REVIEW/references/error-codes.md" ]
}

@test "workflow-daily orders contract before gate before delta" {
    file="$LONG_WRITE/references/workflow-daily.md"
    contract_line="$(grep -n "Chapter Contract" "$file" | head -1 | cut -d: -f1)"
    gate_line="$(grep -n "Plot Drift Gate" "$file" | head -1 | cut -d: -f1)"
    delta_line="$(grep -n "State Delta" "$file" | head -1 | cut -d: -f1)"
    [ -n "$contract_line" ]
    [ -n "$gate_line" ]
    [ -n "$delta_line" ]
    [ "$contract_line" -lt "$gate_line" ]
    [ "$gate_line" -lt "$delta_line" ]
}

@test "workflow-revision requires revision impact analysis" {
    grep -q "Revision Impact Analysis" "$LONG_WRITE/references/workflow-revision.md"
    grep -q "State_Not_Updated" "$LONG_WRITE/references/workflow-revision.md"
}

@test "workflow-revision enforces punctuation normalization after rewriting" {
    workflow="$LONG_WRITE/references/workflow-revision.md"
    grep -q "normalize-punctuation.js" "$workflow"
    grep -q "破折号密度门禁" "$workflow"
    grep -Eq "合理少量|少量.*功能|有功能" "$workflow"
    grep -q "逐字破折号化" "$workflow"
    grep -q "不得宣布.*完成" "$workflow"
}

@test "quality checklist treats dash overuse as a blocking prose issue" {
    checklist="$LONG_WRITE/references/quality-checklist.md"
    setup_copy="$SETUP/references/agent-references/quality-checklist.md"
    grep -q "破折号密度" "$checklist"
    grep -Eq "合理少量|少量.*功能|有功能" "$checklist"
    grep -q "逐字破折号化" "$checklist"
    grep -q "normalize-punctuation.js" "$checklist"
    cmp -s "$checklist" "$setup_copy"
}

@test "narrative writer treats repeated em dashes as modely prose" {
    writer="$SETUP/references/templates/agents/narrative-writer.md"
    grep -q "破折号密度" "$writer"
    grep -q "同一章.*——" "$writer"
    grep -q "normalize-punctuation.js" "$writer"
}

@test "story-long-write references all stability documents" {
    skill="$LONG_WRITE/SKILL.md"
    grep -q "chapter-contract.md" "$skill"
    grep -q "plot-drift-control.md" "$skill"
    grep -q "state-delta-ledger.md" "$skill"
    grep -q "character-invariants.md" "$skill"
    grep -q "revision-impact-analysis.md" "$skill"
    grep -q "chapter-handoff-pack.md" "$skill"
    grep -q "cross-chapter-continuity-audit.md" "$skill"
    grep -q "longform-daily-stability-audit.md" "$skill"
    grep -q "stability-repair-dispatcher.md" "$skill"
    grep -q "stability-repair-loop.md" "$skill"
    grep -q "stability-agent-dispatch-prompts.md" "$skill"
}

@test "single chapter workflow cannot bypass stability loop" {
    skill="$LONG_WRITE/SKILL.md"
    grep -q "追踪/章节契约/第{N}章.md" "$skill"
    grep -q "3.4 \\*\\*Chapter Contract\\*\\*" "$skill"
    gate_line="$(grep -n "\\*\\*Plot Drift Gate\\*\\*" "$skill" | head -1 | cut -d: -f1)"
    delta_line="$(grep -n "\\*\\*State Delta Ledger" "$skill" | head -1 | cut -d: -f1)"
    handoff_line="$(grep -n "\\*\\*Chapter Handoff Pack\\*\\*" "$skill" | head -1 | cut -d: -f1)"
    [ -n "$gate_line" ]
    [ -n "$delta_line" ]
    [ -n "$handoff_line" ]
    [ "$gate_line" -lt "$delta_line" ]
    [ "$delta_line" -lt "$handoff_line" ]
}

@test "long-write treats narrative continuity as a hard gate across writing workflows" {
    skill="$LONG_WRITE/SKILL.md"
    grep -q "叙事连续性硬门" "$skill"
    grep -q "情节剧情连续性" "$skill"
    grep -q "人物持续发展" "$skill"
    grep -q "设定与事实一致性" "$skill"
    grep -q "写作、续写、回炉、扩容、合并、阶段审阅反馈" "$skill"
    grep -q "不得只检查字数、AI味或单章爽点" "$skill"
    grep -q "Chapter Contract" "$skill"
    grep -q "Plot Drift Gate" "$skill"
    grep -q "State Delta Ledger" "$skill"
    grep -q "Chapter Handoff Pack" "$skill"
    grep -q "Cross Chapter Continuity Audit" "$skill"
}

@test "chapter contract writes preflight volume directory and permissions" {
    skill="$LONG_WRITE/SKILL.md"
    reference="$LONG_WRITE/references/chapter-contract.md"
    grep -q "章节契约写入预检" "$skill"
    grep -q "mkdir -p.*追踪/章节契约/第X卷" "$skill"
    grep -q "test -w.*追踪/章节契约/第X卷" "$skill"
    grep -q "临时写入测试" "$skill"
    grep -q "Error writing file" "$skill"
    grep -q "Permission denied" "$skill"
    grep -q "不得继续生成正文" "$skill"
    grep -q "章节契约写入预检" "$reference"
    grep -q "目录不存在时先创建卷目录" "$reference"
    grep -q "章节契约写入预检" "$LONG_WRITE/references/workflow-daily.md"
}

@test "story-long-write treats hook and missing output failures as blocked writes" {
    skill="$LONG_WRITE/SKILL.md"
    grep -q "写入事务门禁" "$skill"
    grep -q "PostToolUse hook" "$skill"
    grep -q "blocked_write_hook" "$skill"
    grep -q "blocked_write_missing_output" "$skill"
    grep -q "agent Done" "$skill"
    grep -q "不得把未落盘内容当作完成" "$skill"
}

@test "chapter draft resolver finds actual volume-local draft path" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/正文/第1卷" "$tmp/追踪"
    printf '## 第7章 曹墨和秀秀\n正文\n' > "$tmp/正文/第1卷/第007章_曹墨和秀秀.md"

    output="$(node "$REPO/scripts/chapter-draft-resolve.js" "$tmp" 7 --volume 第1卷 --json)"

    echo "$output" | grep -q '"status": "ok"'
    echo "$output" | grep -q '"relPath": "正文/第1卷/第007章_曹墨和秀秀.md"'
}

@test "chapter draft resolver accepts legacy flat draft when project is not migrated" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/正文" "$tmp/追踪"
    printf '## 第7章 曹墨和秀秀\n正文\n' > "$tmp/正文/第007章_曹墨和秀秀.md"

    output="$(node "$REPO/scripts/chapter-draft-resolve.js" "$tmp" 7 --json)"

    echo "$output" | grep -q '"status": "ok"'
    echo "$output" | grep -q '"relPath": "正文/第007章_曹墨和秀秀.md"'
    echo "$output" | grep -q '"layout": "flat"'

    rm -rf "$tmp"
}

@test "chapter draft resolver honors book-state flat layout over volume default" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/正文" "$tmp/追踪"
    printf '{\n  "chapterLayout": "flat",\n  "preferredVolume": "第1卷",\n  "allowLegacyFlat": true\n}\n' > "$tmp/.book-state.json"
    printf '## 第7章 曹墨和秀秀\n正文\n' > "$tmp/正文/第007章_曹墨和秀秀.md"

    output="$(node "$REPO/scripts/chapter-draft-resolve.js" "$tmp" 7 --volume 第1卷 --json)"

    echo "$output" | grep -q '"status": "ok"'
    echo "$output" | grep -q '"relPath": "正文/第007章_曹墨和秀秀.md"'
    echo "$output" | grep -q '"layout": "flat"'

    rm -rf "$tmp"
}

@test "chapter draft resolver blocks global chapter numbers inside later volume folders" {
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/正文/第2卷"
    printf '{\n  "chapterLayout": "volume",\n  "preferredVolume": "第2卷",\n  "allowLegacyFlat": false\n}\n' > "$tmp/.book-state.json"
    printf '正文\n' > "$tmp/正文/第2卷/第027章_禁闭第一夜.md"
    printf '正文\n' > "$tmp/正文/第2卷/第028章_禁闭第二夜.md"
    printf '正文\n' > "$tmp/正文/第2卷/第029章_禁闭第三夜.md"

    output="$(node "$REPO/scripts/chapter-draft-resolve.js" "$tmp" 29 --volume 第2卷 --json || true)"

    echo "$output" | grep -q '"status": "noncanonical"'
    echo "$output" | grep -q "卷目录使用全书连续编号"
    echo "$output" | grep -q "第2卷应从第001章开始"

    rm -rf "$tmp"
}

@test "daily workflow requires draft path handshake after narrative-writer" {
    workflow="$LONG_WRITE/references/workflow-daily.md"
    skill="$LONG_WRITE/SKILL.md"
    writer="$SETUP/references/templates/agents/narrative-writer.md"
    grep -q "正文落盘路径握手" "$workflow"
    grep -q "actual_draft_path" "$workflow"
    grep -q "chapter-draft-resolve.js" "$workflow"
    grep -q "FileNotFoundError" "$workflow"
    grep -q "正文落盘路径握手" "$skill"
    grep -q "actual_draft_path" "$writer"
    grep -q "不得只返回 Done" "$writer"
}

@test "workflow-daily loads stability evidence before writing" {
    file="$LONG_WRITE/references/workflow-daily.md"
    grep -q "大纲/卷纲_第X卷.md" "$file"
    grep -q "设定/角色不变量/{角色名}.md" "$file"
    grep -q "追踪/章节契约/第{N}章.md" "$file"
    grep -q "chapter_contract" "$file"
    grep -q "recent_state_delta" "$file"
}

@test "story-review loads chapter contracts as evidence" {
    skill="$REVIEW/SKILL.md"
    grep -q "追踪/章节契约/第{N}章.md" "$skill"
    grep -q "Chapter Contract" "$skill"
}

@test "story-review schema includes machine-readable code" {
    skill="$REVIEW/SKILL.md"
    grep -q "error-codes.md" "$skill"
    grep -q "code: Plot_Drift" "$skill"
}

@test "story-review batches full-book review to avoid context overflow" {
    skill="$REVIEW/SKILL.md"
    grep -q "全书级长任务安全协议" "$skill"
    grep -q "审查批次计划" "$skill"
    grep -q "paused_at_batch_boundary" "$skill"
    grep -q "全书审查总报告" "$skill"
    ! grep -q "可能上下文超限" "$skill"
}

@test "story-review preserves global hook payoff and climax checks across batches" {
    skill="$REVIEW/SKILL.md"
    grep -q "全局钩子回收矩阵" "$skill"
    grep -q "爆点兑现矩阵" "$skill"
    grep -q "承诺-兑现链" "$skill"
    grep -q "跨批边界复核" "$skill"
    grep -q "未回收钩子" "$skill"
}

@test "revision impact analysis batches whole-book operations" {
    reference="$LONG_WRITE/references/revision-impact-analysis.md"
    grep -q "全书级影响分析安全协议" "$reference"
    grep -q "影响批次计划" "$reference"
    grep -q "每批只读取命中文件和相邻章节" "$reference"
    ! grep -q "可能上下文超限" "$reference"
}

@test "error code catalog contains core stability codes" {
    file="$REVIEW/references/error-codes.md"
    for code in Plot_Drift Beat_Missing Beat_Compressed Canon_Conflict Motivation_Drift Knowledge_Leak Foreshadow_Early_Payoff Untracked_Addition State_Not_Updated; do
        grep -q "$code" "$file"
    done
}

@test "story-setup agent templates understand longform stability contracts" {
    writer="$SETUP/references/templates/agents/narrative-writer.md"
    checker="$SETUP/references/templates/agents/consistency-checker.md"
    grep -q "章节契约" "$writer"
    grep -q "必须逐项兑现 Chapter Contract" "$writer"
    grep -q "不得写入契约禁止事项" "$writer"
    grep -q "Plot_Drift" "$checker"
    grep -q "State_Not_Updated" "$checker"
}

@test "deployed agents understand narrative continuity governance boundaries" {
    for file in \
        "$SETUP/references/templates/agents/narrative-writer.md" \
        "$SETUP/references/opencode/agents/narrative-writer.md" \
        "$SETUP/references/templates/agents/consistency-checker.md" \
        "$SETUP/references/opencode/agents/consistency-checker.md"
    do
        grep -q "叙事连续性" "$file"
    done

    grep -q "剧情情节连续性" "$SETUP/references/templates/agents/consistency-checker.md"
    grep -q "钩子上下文" "$SETUP/references/templates/agents/consistency-checker.md"
    grep -q "人物状态连续性" "$SETUP/references/templates/agents/consistency-checker.md"
}

@test "creative agents use compressed handoff for global setting tasks" {
    for file in \
        "$SETUP/references/templates/agents/story-architect.md" \
        "$SETUP/references/templates/agents/character-designer.md" \
        "$SETUP/references/templates/agents/consistency-checker.md" \
        "$SETUP/references/templates/agents/story-explorer.md"
    do
        grep -q "全局任务压缩交接" "$file"
        grep -q "token_estimate" "$file"
        grep -q "model_degradation_guard" "$file"
        grep -q "handoff_packet_path" "$file"
        grep -q "不得把完整设定正文贴回主线程" "$file"
        grep -q "动态 agent_output_budget" "$file"
        grep -q "adaptive_budget_policy" "$file"
        grep -q "visible_reply_budget" "$file"
        grep -q "batch_handoff_budget" "$file"
        grep -q "不得写死固定字数" "$file"
        grep -q "1-200 章" "$file"
        grep -q "范围级摘要" "$file"
        grep -q "范围级摘要不是事实源" "$file"
        grep -q "source-grounding" "$file"
    done
}

@test "story-explorer context load returns stability context" {
    explorer="$SETUP/references/templates/agents/story-explorer.md"
    grep -q "追踪/章节契约/第{N}章.md" "$explorer"
    grep -q "设定/角色不变量/{name}.md" "$explorer"
    grep -q '"chapter_contract"' "$explorer"
    grep -q '"chapter_handoff_pack"' "$explorer"
    grep -q '"character_invariants"' "$explorer"
    grep -q '"recent_state_delta"' "$explorer"
}

@test "story-explorer can load current stability repair checkpoint" {
    explorer="$SETUP/references/templates/agents/story-explorer.md"
    grep -q "stability_repair_load" "$explorer"
    grep -q "追踪/稳定性审计/修复闭环_第{start}章_to_第{end}章.md" "$explorer"
    grep -q "追踪/稳定性审计/修复清单_第{start}章_to_第{end}章.md" "$explorer"
    grep -q "current_owner" "$explorer"
    grep -q "current_action" "$explorer"
    grep -q "verification_commands" "$explorer"
}

@test "consistency-checker understands stability repair checkpoints" {
    checker="$SETUP/references/templates/agents/consistency-checker.md"
    grep -q "stability-repair-dispatcher.md" "$checker"
    grep -q "stability-repair-loop.md" "$checker"
    grep -q "current_action" "$checker"
    grep -q "verification_commands" "$checker"
    grep -q "只审查当前 checkpoint" "$checker"
}

@test "narrative-writer repairs only the current stability checkpoint" {
    writer="$SETUP/references/templates/agents/narrative-writer.md"
    grep -q "stability-repair-dispatcher.md" "$writer"
    grep -q "stability-repair-loop.md" "$writer"
    grep -q "current_action" "$writer"
    grep -q "只改当前 checkpoint" "$writer"
    grep -q "禁止整章重写" "$writer"
    grep -q "target_chapter" "$writer"
    grep -q "verification_commands" "$writer"
}

@test "story-architect arbitrates structural stability repair checkpoints" {
    architect="$SETUP/references/templates/agents/story-architect.md"
    grep -q "stability-repair-dispatcher.md" "$architect"
    grep -q "stability-repair-loop.md" "$architect"
    grep -q "current_action" "$architect"
    grep -q "Plot_Drift" "$architect"
    grep -q "Foreshadow_Early_Payoff" "$architect"
    grep -q "结构裁决" "$architect"
    grep -q "改正文 / 改契约 / 改细纲 / 后移伏笔 / 需要用户确认" "$architect"
    grep -q "不得直接重写正文" "$architect"
}

@test "character-designer arbitrates character stability repair checkpoints" {
    designer="$SETUP/references/templates/agents/character-designer.md"
    grep -q "stability-repair-dispatcher.md" "$designer"
    grep -q "stability-repair-loop.md" "$designer"
    grep -q "current_action" "$designer"
    grep -q "Motivation_Drift" "$designer"
    grep -q "Knowledge_Leak" "$designer"
    grep -q "角色裁决" "$designer"
    grep -q "底层欲望 / 当前阶段目标 / 行为红线 / 认知边界 / 语言边界" "$designer"
    grep -q "补动机链 / 改行动 / 补获知过程 / 删除越界认知 / 更新角色不变量 / 需要用户确认" "$designer"
    grep -q "不得直接重写正文" "$designer"
}

@test "story-architect and character-designer seed stability artifacts" {
    architect="$SETUP/references/templates/agents/story-architect.md"
    designer="$SETUP/references/templates/agents/character-designer.md"
    grep -q "当前卷目标" "$architect"
    grep -q "本章服务卷目标" "$architect"
    grep -q "必须 beat" "$architect"
    grep -q "Chapter Contract" "$architect"
    grep -q "设定/角色不变量/{角色名}.md" "$designer"
    grep -q "底层欲望" "$designer"
    grep -q "认知边界" "$designer"
    grep -q "Motivation_Drift" "$designer"
    grep -q "Knowledge_Leak" "$designer"
}

@test "story-setup bumps agents version for stability-aware agents" {
    grep -q "agents_version: 18" "$SETUP/SKILL.md"
    grep -q "agents_version: 18" "$SETUP/UPGRADING.md"
    grep -q "长篇目录迁移" "$SETUP/UPGRADING.md"
    grep -q "check-ai-patterns.js" "$SETUP/SKILL.md"
    grep -q "story-project-migrate.js" "$SETUP/SKILL.md"
    grep -q "OpenCode" "$SETUP/UPGRADING.md"
}

@test "story-setup bundles longform stability references for deployed agents" {
    refs="$SETUP/references/agent-references"
    [ -f "$refs/chapter-contract.md" ]
    [ -f "$refs/plot-drift-control.md" ]
    [ -f "$refs/state-delta-ledger.md" ]
    [ -f "$refs/character-invariants.md" ]
    [ -f "$refs/revision-impact-analysis.md" ]
    [ -f "$refs/chapter-handoff-pack.md" ]
    [ -f "$refs/cross-chapter-continuity-audit.md" ]
    [ -f "$refs/longform-daily-stability-audit.md" ]
    [ -f "$refs/stability-repair-dispatcher.md" ]
    [ -f "$refs/stability-repair-loop.md" ]
    [ -f "$refs/stability-agent-dispatch-prompts.md" ]
    [ -f "$refs/error-codes.md" ]

    writer="$SETUP/references/templates/agents/narrative-writer.md"
    checker="$SETUP/references/templates/agents/consistency-checker.md"
    architect="$SETUP/references/templates/agents/story-architect.md"
    designer="$SETUP/references/templates/agents/character-designer.md"
    explorer="$SETUP/references/templates/agents/story-explorer.md"

    grep -q "novel-assistant/references/agent-references/chapter-contract.md" "$writer"
    grep -q "novel-assistant/references/agent-references/state-delta-ledger.md" "$writer"
    grep -q "novel-assistant/references/agent-references/stability-repair-dispatcher.md" "$writer"
    grep -q "novel-assistant/references/agent-references/stability-repair-loop.md" "$writer"
    grep -q "novel-assistant/references/agent-references/stability-agent-dispatch-prompts.md" "$writer"
    grep -q "novel-assistant/references/agent-references/plot-drift-control.md" "$checker"
    grep -q "novel-assistant/references/agent-references/error-codes.md" "$checker"
    grep -q "novel-assistant/references/agent-references/stability-repair-dispatcher.md" "$checker"
    grep -q "novel-assistant/references/agent-references/stability-repair-loop.md" "$checker"
    grep -q "novel-assistant/references/agent-references/chapter-contract.md" "$architect"
    grep -q "novel-assistant/references/agent-references/stability-repair-dispatcher.md" "$architect"
    grep -q "novel-assistant/references/agent-references/stability-repair-loop.md" "$architect"
    grep -q "novel-assistant/references/agent-references/character-invariants.md" "$designer"
    grep -q "novel-assistant/references/agent-references/stability-repair-dispatcher.md" "$designer"
    grep -q "novel-assistant/references/agent-references/stability-repair-loop.md" "$designer"
    grep -q "novel-assistant/references/agent-references/state-delta-ledger.md" "$explorer"
    grep -q "novel-assistant/references/agent-references/chapter-handoff-pack.md" "$explorer"
    grep -q "agent-reference bundle" "$SETUP/UPGRADING.md"
}

@test "deployment check locks longform stability reference bundle" {
    script="$REPO/scripts/check-story-setup-deployment.sh"
    grep -q "stability_refs" "$script"
    grep -q "chapter-contract.md" "$script"
    grep -q "plot-drift-control.md" "$script"
    grep -q "state-delta-ledger.md" "$script"
    grep -q "character-invariants.md" "$script"
    grep -q "revision-impact-analysis.md" "$script"
    grep -q "chapter-handoff-pack.md" "$script"
    grep -q "cross-chapter-continuity-audit.md" "$script"
    grep -q "longform-daily-stability-audit.md" "$script"
    grep -q "stability-repair-dispatcher.md" "$script"
    grep -q "stability-repair-loop.md" "$script"
    grep -q "stability-agent-dispatch-prompts.md" "$script"
    grep -q "error-codes.md" "$script"
    grep -q "cmp -s" "$script"
}

@test "novel-assistant defines runner protocol without owning frontend implementation" {
    skill="$NOVEL_ASSISTANT/SKILL.md"
    grep -q "外部 Runner 协议边界" "$skill"
    grep -q "skill 只定义协议" "$skill"
    grep -q "runner 负责会话生命周期" "$skill"
    grep -q "_progress.md" "$skill"
    grep -q "_recovery-state.json" "$skill"
    grep -q "不要在 skill 内写死 novel-project" "$skill"
}

@test "story-long-write documents agent fallback quality boundaries" {
    skill="$LONG_WRITE/SKILL.md"
    workflow="$LONG_WRITE/references/workflow-daily.md"
    grep -q "Agent 缺失质量边界" "$skill"
    grep -q "SOFT FALLBACK" "$skill"
    grep -q "HARD STOP" "$skill"
    grep -q "narrative-writer" "$skill"
    grep -q "consistency-checker" "$skill"
    grep -q "story-explorer" "$skill"
    grep -q "Agent 缺失质量边界" "$workflow"
    grep -q "不得跳过 Chapter Contract" "$workflow"
    grep -q "不得跳过 Plot Drift Gate" "$workflow"
    grep -q "不得跳过 Chapter Handoff Pack" "$workflow"
}

@test "workflow routes repair checkpoints through writer and checker agents" {
    skill="$LONG_WRITE/SKILL.md"
    workflow="$LONG_WRITE/references/workflow-daily.md"
    grep -q "stability_repair_load" "$workflow"
    grep -q "current_owner" "$workflow"
    grep -q "current_action" "$workflow"
    grep -q "stability-agent-dispatch-prompts.md" "$workflow"
    grep -q "narrative-writer" "$workflow"
    grep -q "consistency-checker" "$workflow"
    grep -q "只改当前 checkpoint" "$workflow"
    grep -q "current_owner" "$skill"
    grep -q "current_action" "$skill"
    grep -q "stability-agent-dispatch-prompts.md" "$skill"
    grep -q "narrative-writer" "$skill"
    grep -q "consistency-checker" "$skill"
}

@test "agent dispatch prompt reference covers every stability owner" {
    reference="$LONG_WRITE/references/stability-agent-dispatch-prompts.md"
    setup_copy="$SETUP/references/agent-references/stability-agent-dispatch-prompts.md"

    [ -f "$reference" ]
    [ -f "$setup_copy" ]
    grep -q "current_owner" "$reference"
    grep -q "current_action" "$reference"
    grep -q "character-designer" "$reference"
    grep -q "story-architect" "$reference"
    grep -q "narrative-writer" "$reference"
    grep -q "consistency-checker" "$reference"
    grep -q "Agent(subagent_type" "$reference"
    grep -q "只改当前 checkpoint" "$reference"
    grep -q "角色裁决" "$reference"
    grep -q "结构裁决" "$reference"
    grep -q "verification_commands" "$reference"
    cmp -s "$reference" "$setup_copy"
}

@test "workflow routes structural repair checkpoints through architect" {
    skill="$LONG_WRITE/SKILL.md"
    workflow="$LONG_WRITE/references/workflow-daily.md"
    grep -q "story-architect" "$workflow"
    grep -q "Plot_Drift" "$workflow"
    grep -q "Foreshadow_Early_Payoff" "$workflow"
    grep -q "结构裁决" "$workflow"
    grep -q "story-architect" "$skill"
    grep -q "Plot_Drift" "$skill"
    grep -q "Foreshadow_Early_Payoff" "$skill"
}

@test "workflow routes character repair checkpoints through character designer" {
    skill="$LONG_WRITE/SKILL.md"
    workflow="$LONG_WRITE/references/workflow-daily.md"
    grep -q "character-designer" "$workflow"
    grep -q "Motivation_Drift" "$workflow"
    grep -q "Knowledge_Leak" "$workflow"
    grep -q "角色裁决" "$workflow"
    grep -q "character-designer" "$skill"
    grep -q "Motivation_Drift" "$skill"
    grep -q "Knowledge_Leak" "$skill"
    grep -q "角色裁决" "$skill"
}

@test "longform stability fixture passes end-to-end validator" {
    script="$REPO/scripts/check-longform-stability-fixture.sh"
    fixture="$REPO/tests/fixtures/longform-stability-mini"
    [ -x "$script" ]
    bash "$script" "$fixture" "001"
}

@test "longform stability fixture validator rejects missing contract beat" {
    script="$REPO/scripts/check-longform-stability-fixture.sh"
    fixture="$REPO/tests/fixtures/longform-stability-mini"
    [ -x "$script" ]
    [ -d "$fixture" ]
    tmp="$(mktemp -d)"
    cp -R "$fixture" "$tmp/book"
    perl -0pi -e 's/主角公开拒绝错误任务/主角回避错误任务/g' "$tmp/book/正文/第001章_拒绝错误任务.md"
    ! bash "$script" "$tmp/book" "001"
    rm -rf "$tmp"
}
