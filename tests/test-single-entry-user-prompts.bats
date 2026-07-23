#!/usr/bin/env bats
# tests/test-single-entry-user-prompts.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    STORY="$REPO/src/internal-skills/story/SKILL.md"
    SETUP="$REPO/src/internal-skills/story-setup"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write"
    TOP_CONTRACT="$BATS_TEST_TMPDIR/entry-contract.md"
    cat \
        "$REPO/skills/novel-assistant/SKILL.md" \
        "$REPO/skills/novel-assistant/references/entry-runtime-contract.md" \
        "$REPO/src/internal-skills/story/SKILL.md" \
        "$REPO/src/internal-skills/story-setup/SKILL.md" \
        "$REPO/src/internal-skills/story-workflow/references/task-inbox-protocol.md" \
        "$REPO/src/internal-skills/story-workflow/references/runner-execution-protocol.md" \
        > "$TOP_CONTRACT"
    WORKFLOW_CONTRACT="$BATS_TEST_TMPDIR/workflow-contract.md"
    cat \
        "$REPO/src/internal-skills/story-workflow/SKILL.md" \
        "$REPO/src/internal-skills/story-workflow/references/phase-protocol-index.md" \
        "$REPO/src/internal-skills/story-workflow/references/task-inbox-protocol.md" \
        "$REPO/src/internal-skills/story-workflow/references/runner-execution-protocol.md" \
        > "$WORKFLOW_CONTRACT"
}

@test "router documents single-entry next-step output format" {
    grep -q "对外输出命令规范" "$STORY"
    grep -q "下一步可执行" "$STORY"
    grep -q "/novel-assistant 继续写第 3 章" "$STORY"
    grep -q "/novel-assistant 对已写章节去 AI 味" "$STORY"
    grep -q "/novel-assistant 多视角审查当前正文" "$STORY"
}

@test "deployed CLAUDE template exposes novel-assistant as the only slash entry" {
    template="$SETUP/references/templates/CLAUDE.md.tmpl"
    grep -q "只记一个入口" "$template"
    grep -Fq '| `/novel-assistant`、`/网文` | novel-assistant |' "$template"
    ! grep -Fq '| `/story-long-write`' "$template"
    ! grep -Fq '| `/story-deslop`' "$template"
    ! grep -Fq '| `/story-review`' "$template"
}

@test "session hooks suggest novel-assistant intent instead of internal subcommands" {
    session_start="$SETUP/references/templates/hooks/session-start.sh"
    gaps="$SETUP/references/templates/hooks/detect-story-gaps.sh"

    grep -q "/novel-assistant 继续写第" "$session_start"
    grep -q "/novel-assistant 继续拆文" "$session_start"
    grep -q "/novel-assistant 审查伏笔" "$gaps"
    grep -q "/novel-assistant 继续拆文" "$gaps"

    ! grep -q "输入 /story-long-write" "$session_start"
    ! grep -q "运行 /story-long-analyze" "$session_start"
    ! grep -q "/story-review lean" "$gaps"
    ! grep -q "/story-long-analyze 继续" "$gaps"
}

@test "session hook visible output uses collaboration environment wording" {
    session_start="$SETUP/references/templates/hooks/session-start.sh"
    prose_gate="$SETUP/references/templates/hooks/prose-quality-gate.sh"

    visible="$(grep -E 'OUTPUT\\+=|printf|echo ' "$session_start" "$prose_gate")"

    echo "$visible" | grep -q "/novel-assistant 更新写作协作环境"
    echo "$visible" | grep -q "写作协作环境"

    ! echo "$visible" | grep -q "story-setup"
    ! echo "$visible" | grep -q "刷新 setup"
    ! echo "$visible" | grep -q "/novel-assistant 准备写书"
}

@test "setup and daily workflow do not tell users to call internal subcommands" {
    setup_skill="$SETUP/SKILL.md"
    daily="$LONG_WRITE/references/workflow-daily.md"

    grep -q "/novel-assistant 准备写书" "$setup_skill"
    grep -q "/novel-assistant 继续写" "$setup_skill"
    grep -q "/novel-assistant 审查当前正文" "$daily"

    ! grep -Fq '提示用户可以开始使用 `/story-long-write`' "$setup_skill"
    ! grep -Fq '| `/story-long-write` 或 `/story-short-write` |' "$setup_skill"
    ! grep -Fq '运行 `/story-review lean`' "$daily"
}

@test "collaboration environment update completes with clean handoff only" {
    top="$TOP_CONTRACT"
    setup_skill="$SETUP/SKILL.md"

    grep -q "更新完成后的收束规则" "$top"
    grep -q "更新完成后运行.*workflow-entry-guard.js" "$top"
    grep -q "逐字使用.*visible_response.text" "$top"
    grep -q "禁止使用 Bash/Glob 枚举或搜索.*\.claude/skills/novel-assistant" "$top"
    grep -q "N=0.*必须显示" "$top"
    grep -q "不得直接调用原始 AskUserQuestion" "$top"
    grep -q "不得凭聊天记忆生成“继续写第十二卷”" "$top"

    grep -q "更新完成后的收束规则" "$setup_skill"
    grep -q "workflow-entry-guard.js --project-root" "$setup_skill"
    grep -q "不得自动继续旧审阅/写作/拆文任务队列" "$setup_skill"
    grep -q "不得输出.*Invalid tool parameters" "$setup_skill"
    grep -q "如果用户原始意图仍需继续" "$setup_skill"
}

@test "collaboration environment handoff uses numeric choices" {
    top="$TOP_CONTRACT"
    setup_skill="$SETUP/SKILL.md"

    grep -q "数字候选协议" "$top"
    grep -q "1. 继续写下一章" "$top"
    grep -q "纯数字编号" "$top"
    grep -q "查看更多选项" "$top"
    grep -q "上下方向键" "$top"

    grep -q "数字候选协议" "$setup_skill"
    grep -q "1. 候选标题" "$setup_skill"
    grep -q "不要只输出无编号的意图列表" "$setup_skill"
    ! grep -q "\\[1/A\\]" "$top"
    ! grep -q "\\[1/A\\]" "$setup_skill"
}

@test "collaboration environment handoff does not list maintenance actions as default next choices" {
    top="$TOP_CONTRACT"
    setup_skill="$SETUP/SKILL.md"

    grep -q "维护动作不属于默认下一步候选" "$top"
    grep -q "检查更新/更新本地 skill/迁移章节结构" "$top"

    grep -q "维护动作不属于默认下一步候选" "$setup_skill"
    grep -q "不要把检查更新、更新本地 skill、迁移章节结构列入默认候选" "$setup_skill"
    grep -q "只在用户明确要求时进入维护协议" "$setup_skill"
    grep -q "继续未完成任务" "$setup_skill"
    grep -q "开启新的任务" "$setup_skill"
    grep -q "不得自动替用户推进旧任务" "$setup_skill"
}

@test "collaboration environment update prioritizes layout migration decision before task choices" {
    top="$TOP_CONTRACT"
    setup_skill="$SETUP/SKILL.md"

    grep -q "结构迁移门禁" "$top"
    grep -q "迁移到卷内编号结构" "$top"
    grep -q "保持旧结构兼容" "$top"

    grep -q "结构迁移门禁" "$setup_skill"
    grep -q "story-project-migrate.js.*--json" "$setup_skill"
    grep -q "1. 迁移到卷内编号结构" "$setup_skill"
    grep -q "2. 保持旧结构兼容" "$setup_skill"
    grep -q "结构门禁未收束前，不展示继续未完成任务或开启新的任务候选" "$setup_skill"
    grep -q "chapterLayout=flat" "$setup_skill"
    grep -q "allowLegacyFlat=true" "$setup_skill"
    grep -q "migration_status: skipped_by_user" "$setup_skill"
}

@test "genre setting taxonomy does not default to power-system wording" {
    top="$TOP_CONTRACT"
    readme="$REPO/README.md"
    workflow="$WORKFLOW_CONTRACT"
    phase_index="$REPO/src/internal-skills/story-workflow/references/phase-protocol-index.md"
    architect="$SETUP/references/templates/agents/story-architect.md"
    importer="$REPO/src/internal-skills/story-import/SKILL.md"

    grep -q "能力/成长规则一致性" "$readme"
    grep -q "不得把.*修真体系.*机械替换成.*力量体系" "$readme"
    grep -q "默认文件名用.*设定/世界观/能力与规则.md" "$workflow"
    grep -q "修炼与能力规则.md" "$workflow"
    grep -q "系统能力与成长规则.md" "$workflow"
    grep -q "不要默认创建.*力量体系.md" "$architect"
    grep -q "legacy.*力量体系.md" "$importer"
    grep -q "能力与规则.md" "$top"
}

@test "story setup keeps project collaboration references outside claude skills" {
    setup_skill="$SETUP/SKILL.md"
    deploy_check="$REPO/scripts/check-story-setup-deployment.sh"
    upgrading="$SETUP/UPGRADING.md"

    grep -q ".claude/agent-references/novel-assistant" "$setup_skill"
    grep -q ".claude/agent-references/novel-assistant" "$deploy_check"
    grep -q ".claude/agent-references/novel-assistant" "$upgrading"
    ! grep -q ".claude/skills/novel-assistant/references/agent-references" "$setup_skill"
    ! grep -q ".claude/src/internal-skills/story-setup/references/agent-references" "$setup_skill"
    ! grep -q ".claude/skills/novel-assistant" "$deploy_check"
    ! grep -q ".claude/src/internal-skills/story-setup" "$deploy_check"
    ! grep -R ".claude/skills/" "$SETUP/references/templates/agents"
}

@test "interactive choice recovery supports host ui without exposing tool errors" {
    top="$TOP_CONTRACT"
    workflow="$WORKFLOW_CONTRACT"

    grep -q "交互恢复协议" "$top"
    grep -q "host_select" "$top"
    grep -q "fallback=text_numbers" "$top"
    grep -q "不把 Invalid tool parameters 暴露给用户" "$top"
    grep -q "page_size: 4" "$top"

    grep -q "交互恢复协议" "$workflow"
    grep -q "render_mode" "$workflow"
    grep -q "free_text_enabled" "$workflow"
    grep -q "查看更多选项" "$workflow"
}

@test "visible choices hide raw pending action internals and use safe defaults" {
    top="$TOP_CONTRACT"
    workflow="$WORKFLOW_CONTRACT"

    grep -q "不得把 pending_action: 原始结构块直接打印给用户" "$top"
    grep -q "可见回复只展示问题、编号候选和一句回复方式" "$top"
    grep -q "safe_default 必须是不执行写入并保存断点" "$top"
    grep -q "不得写成默认选择第 1 项" "$top"
    grep -q "不要让用户另开窗口" "$top"
    grep -q "直接输入你的意见" "$top"

    grep -q "不得把 pending_action 原始 JSON/YAML 直接作为可见回复" "$workflow"
    grep -q "safe_default.*保存断点" "$workflow"
    grep -q "不得把默认值设成继续写作" "$workflow"
    grep -q "不要输出.*另开窗口" "$workflow"
    grep -q "直接输入你的意见" "$workflow"
}

@test "numeric choice execution uses action id without long rationale" {
    top="$TOP_CONTRACT"
    workflow="$WORKFLOW_CONTRACT"
    phase_index="$REPO/src/internal-skills/story-workflow/references/phase-protocol-index.md"

    grep -q "数字选择执行门禁" "$top"
    grep -q "只解析 action_id" "$top"
    grep -q "不得展开长篇理由" "$top"
    grep -q "选择执行草稿" "$top"
    grep -q "blocked_output_pollution" "$top"

    grep -q "数字选择执行门禁" "$workflow"
    grep -q "selection_execution_draft" "$workflow"
    grep -q "只写 action_id" "$workflow"
    grep -q "phase-protocol-index.md" "$workflow"
    grep -q "不得复述业务术语超过 2 次" "$phase_index"
    grep -q "写入预检" "$workflow"
}

@test "next-step candidates derive ranges and genre terms from current project" {
    top="$TOP_CONTRACT"
    workflow="$WORKFLOW_CONTRACT"
    outline_rule="$REPO/src/internal-skills/story-setup/references/templates/rules/story-outline.md"

    grep -q "候选范围必须从当前项目文件推断" "$top"
    grep -q "不得凭空输出 27-50" "$top"
    grep -q "卷内编号结构" "$top"
    grep -q "题材维度词必须从当前项目识别" "$top"
    grep -q "未确认题材时使用能力/成长规则一致性" "$top"
    grep -q "不要默认创建.*力量体系.md" "$top"

    grep -q "候选范围必须从当前项目文件推断" "$workflow"
    grep -q "不得使用旧书记忆" "$workflow"
    grep -q "题材维度词必须从当前项目识别" "$workflow"
    grep -q "story-domain-profile.js" "$workflow"

    ! grep -q "沈栀" "$outline_rule"
    ! grep -q "暗卫" "$outline_rule"
    ! grep -q "第二卷回收" "$outline_rule"
}

@test "current progress questions must use deterministic progress status script" {
    top="$TOP_CONTRACT"
    workflow="$WORKFLOW_CONTRACT"
    daily="$REPO/src/internal-skills/story-long-write/references/workflow-daily.md"

    grep -q "当前进度问答协议" "$top"
    grep -q "story-progress-status.js" "$top"
    grep -q "不得从聊天记忆、recap、旧卷纲" "$top"
    grep -q "blocked_mixed_chapter_layout" "$top"

    grep -q "当前进度问答协议" "$workflow"
    grep -q "story-progress-status.js" "$workflow"

    grep -q "story-progress-status.js" "$daily"
    grep -q "不得把第029章当第2卷第29章" "$daily"
}

@test "startup self check avoids first-screen bash permission prompts" {
    top="$TOP_CONTRACT"

    grep -q "启动自检不得把 Bash 权限确认作为第一屏" "$top"
    grep -q "优先用 Read/LS" "$top"
    grep -q "不得先用 Bash cat" "$top"
    grep -q "runner 后台" "$top"
    grep -q "无人值守授权预算" "$top"
    grep -q "同一 workflow 不得让用户反复点允许" "$top"
    grep -q "permission_budget_exceeded" "$top"
    grep -q "novel-assistant-sync-runtime.js" "$top"
    grep -q "单条同步入口" "$top"
}

@test "startup self check treats legacy novel folders without sentinel as not deployed" {
    top="$TOP_CONTRACT"
    router="$REPO/src/internal-skills/story/SKILL.md"

    grep -q "未部署的已有小说项目" "$top"
    grep -q "正文/.*大纲/.*设定/.*追踪/" "$top"
    grep -q '含 `CLAUDE.md` 的 legacy 目录同样成立' "$top"
    grep -q '项目缺少 `.story-deployed`' "$top"
    grep -q "status=not_deployed" "$top"
    grep -q "必须暂停正常路由" "$top"

    grep -q "未部署的已有小说项目" "$router"
    grep -q "正文/.*大纲/.*设定/.*追踪/" "$router"
    grep -q "未部署的已有小说项目" "$router"
}

@test "startup self check manually compares bundle ids when update script is not run" {
    top="$TOP_CONTRACT"
    router="$REPO/src/internal-skills/story/SKILL.md"

    grep -q '无法运行 `novel-assistant-update-check.js` 时' "$top"
    grep -q '直接读取 `.story-deployed`' "$top"
    grep -q "novel-assistant-manifest.json" "$top"
    grep -q "比较 bundleId" "$top"
    grep -q '不一致即为 `update_available`' "$top"

    grep -q "更新确认优先于工作流编排" "$router"
    grep -q "bundleId" "$router"
    grep -q "update_available" "$router"
}

@test "startup environment update prompt uses numbered host-select compatible choices" {
    top="$TOP_CONTRACT"

    grep -q "更新确认响应" "$top"
    grep -q '"type": "update_environment"' "$top"
    grep -q "interaction_renderer=host_select_preferred" "$top"
    grep -q "fallback=text_numbers" "$top"
    grep -q "1. 现在更新写作协作环境" "$top"
    grep -q "2. 暂不更新，继续原意图" "$top"
    grep -q '`确认/是/yes/y` 等同于 1' "$top"
    grep -q '`不/否/no/n/later` 等同于 2' "$top"
    grep -q "不得只输出“回复确认”" "$top"
}

@test "startup self check is scoped to current book directory only" {
    top="$TOP_CONTRACT"
    router="$REPO/src/internal-skills/story/SKILL.md"

    grep -q "只以当前工作目录为书籍根" "$top"
    grep -q "不得向上查找父目录" "$top"
    grep -q "不得把父目录或书库目录" "$top"

    grep -q "项目根只能是本会话的当前工作目录" "$router"
    grep -q "不得向上查找父目录" "$router"
    grep -q "不得把父目录或书库目录" "$router"
}

@test "claude cli recap is not treated as workflow source of truth" {
    top="$TOP_CONTRACT"
    workflow="$WORKFLOW_CONTRACT"

    grep -q "宿主提示" "$top"
    grep -q "不得把 recap 当作工作流事实源" "$top"
    grep -q "行数、字数、破折号数量" "$top"
    grep -q "宿主提示" "$workflow"
    grep -q "不得把 recap 当作工作流事实源" "$workflow"
    grep -q "行数、字数、破折号数量" "$workflow"
}

@test "top level forbids fragile external task and choice tools" {
    top="$TOP_CONTRACT"

    grep -q "外部任务工具禁用协议" "$top"
    grep -q "不得调用 TaskCreate" "$top"
    grep -q "不得调用交互式选择工具" "$top"
    grep -q "Invalid tool parameters" "$top"
    grep -q "追踪/workflow/current-task.json" "$top"
    grep -q "追踪/workflow/current-task.md" "$top"
    grep -q "补设定任务较大" "$top"
}

@test "internal modules use plain text confirmation instead of AskUserQuestion" {
    files=(
        "$REPO/src/internal-skills/story-setup/SKILL.md"
        "$REPO/src/internal-skills/story-long-analyze/SKILL.md"
        "$REPO/src/internal-skills/story-import/SKILL.md"
        "$REPO/src/internal-skills/browser-cdp/SKILL.md"
    )

    for file in "${files[@]}"; do
        ! grep -q "AskUserQuestion" "$file"
        grep -q "普通文本确认" "$file"
    done
}
