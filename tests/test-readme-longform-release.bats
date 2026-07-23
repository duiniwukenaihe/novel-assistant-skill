#!/usr/bin/env bats
# tests/test-readme-longform-release.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    README="$REPO/README.md"
    README_EN="$REPO/README_EN.md"
    QUICKSTART="$REPO/docs/longform-stability-quickstart.md"
    RELEASE="$REPO/docs/release-checklist.md"
}

@test "README documents longform stability control quickstart" {
    grep -q "长篇稳定性闭环" "$README"
    grep -q "叙事连续性治理" "$README"
    grep -q "情节剧情连续性" "$README"
    grep -q "人物持续发展" "$README"
    grep -q "设定与事实一致性" "$README"
    grep -q "Chapter Contract" "$README"
    grep -q "Stability Repair Loop" "$README"
    grep -q "Context Pack" "$README"
    grep -q "context-pack-build.js" "$README"
    grep -q "追踪/章节索引.tsv" "$README"
    grep -q "docs/longform-stability-quickstart.md" "$README"
}

@test "README documents workflow boundaries for narrative continuity governance" {
    grep -q "写作/续写" "$README"
    grep -q "回炉/扩容/合并" "$README"
    grep -q "审阅/补审" "$README"
    grep -q "去AI味" "$README"
    grep -q "只能改文字表达" "$README"
    grep -q "不能改变事实、钩子、人物状态" "$README"
    grep -q "范围补缝报告" "$README"
}

@test "README documents project-derived candidates and expansion transaction design" {
    grep -q "候选必须来自当前项目" "$README"
    grep -q "不得把上一本文、模板示例或固定章节段" "$README"
    grep -q "题材词动态识别" "$README"
    grep -q "扩容事务协议" "$README"
    grep -q "先做扩容影响分析" "$README"
    grep -q "后移映射" "$README"
    grep -q "保留原章节名和可用正文资产" "$README"
    grep -q "先后移旧章节资产，再补新增缺口" "$README"
    grep -q "同步大纲、卷纲、细纲、正文、章节契约、交接包、伏笔、时间线和角色状态" "$README"
    grep -q "Revision Stability Recheck" "$README"
}

@test "README documents full workflow guidance after choices and polluted output handling" {
    grep -q "全流程选择引导" "$README"
    grep -q "执行 A 后继续提示 A2/B/C/D" "$README"
    grep -q "不要使用“仅执行本项”这类含糊说法" "$README"
    grep -q "污染输出不能入库" "$README"
    grep -q "丢弃污染块、缩小任务粒度重试" "$README"
    grep -q "blocked_output_pollution" "$README"
}

@test "README documents output health gate and review state ledger" {
    grep -q "输出健康门" "$README"
    grep -q "重复行" "$README"
    grep -q "低信息密度" "$README"
    grep -q "工程词泄露" "$README"
    grep -q "追踪/review-state.json" "$README"
    grep -q "dependency_hashes" "$README"
    grep -q "suggested_recheck_ranges" "$README"
    grep -q "review-state-ledger.js" "$README"
}

@test "README distinguishes our internal modules from upstream parallel subskills" {
    grep -q "不是上游并列子 skill 表" "$README"
    grep -q "我们的内部模块矩阵" "$README"
    grep -q "story-long-write.*生产正文" "$README"
    grep -q "story-review.*只读诊断" "$README"
    grep -q "story-deslop.*表达层" "$README"
    grep -q "story-long-analyze.*事实底座" "$README"
    grep -q "story-long-scan.*市场输入" "$README"
    grep -q "story-import.*反向建立连续性资产" "$README"
    grep -q "story-cover.*不参与叙事连续性" "$README"
    grep -q "browser-cdp.*数据采集工具" "$README"
}

@test "README foregrounds workflow brain pain points and benefits" {
    grep -q "为什么另做 novel-assistant" "$README"
    grep -q "痛点 -> 设计 -> 收益" "$README"
    grep -q "子 skill 难识别" "$README"
    grep -q "不喜欢在 skill 目录下同级安装一排 story\\*" "$README"
    grep -q "不是用户体验，而是维护者内部结构泄露" "$README"
    grep -q "长任务中断" "$README"
    grep -q "模型/工具退化" "$README"
    grep -q "成本不可见" "$README"
    grep -q "章节扩容牵一发而动全身" "$README"
    grep -q "workflow-first" "$README"
    grep -q "story-workflow.*工作流大脑" "$README"
    grep -q "story-workflow.*编排" "$README"
}

@test "English README mirrors workflow-first positioning" {
    [ -f "$README_EN" ]
    grep -q "Why novel-assistant exists" "$README_EN"
    grep -q "Pain point -> Design -> Benefit" "$README_EN"
    grep -q "I do not like installing a row of peer story\\* skills" "$README_EN"
    grep -q "maintainer internals leaking into the user experience" "$README_EN"
    grep -q "subskills are hard to invoke reliably" "$README_EN"
    grep -q "long tasks stop halfway" "$README_EN"
    grep -q "model/tool degradation" "$README_EN"
    grep -q "invisible token waste" "$README_EN"
    grep -q "chapter expansion shifts many assets" "$README_EN"
    grep -q "Workflow-first architecture" "$README_EN"
    grep -q "story-workflow.*workflow brain" "$README_EN"
    grep -q "Internal module matrix" "$README_EN"
}

@test "README credits user direction and Codex-assisted design" {
    grep -q "这个新 skill 的方向来自作者长期写作中的真实痛点" "$README"
    grep -q "用户提出生产约束、使用偏好和失败案例" "$README"
    grep -q "Codex 协助把这些思路整理成 router、workflow、脚本、测试和文档" "$README"
    grep -q "不是从零否定上游" "$README"

    grep -q "The direction came from the author's real production pain points" "$README_EN"
    grep -q "The user supplied constraints, preferences, and failure cases" "$README_EN"
    grep -q "Codex helped turn those ideas into router, workflow, scripts, tests, and documentation" "$README_EN"
    grep -q "not a rejection of upstream" "$README_EN"
}

@test "README documents our production design highlights" {
    grep -q "统一入口与内部路由" "$README"
    grep -q "工作流记忆与断点续跑" "$README"
    grep -q "长篇稳定性闭环" "$README"
    grep -q "审阅状态账本" "$README"
    grep -q "扩容事务协议" "$README"
    grep -q "输出健康门与工具退化自愈" "$README"
    grep -q "Token 成本治理" "$README"
    grep -q "上游反哺流程" "$README"

    grep -q "Single entry and internal routing" "$README_EN"
    grep -q "Workflow memory and checkpointed resume" "$README_EN"
    grep -q "Long-form stability loop" "$README_EN"
    grep -q "Review state ledger" "$README_EN"
    grep -q "Expansion transaction protocol" "$README_EN"
    grep -q "Output health gate and tool-degradation recovery" "$README_EN"
    grep -q "Token Cost Governance" "$README_EN"
    grep -q "Upstream backport workflow" "$README_EN"
}

@test "README explains upstream-inspired long-analyze reliability improvements" {
    grep -q "长篇拆文可靠性" "$README"
    grep -q "上游已经提供长篇拆文和 chapter-extractor" "$README"
    grep -q "真正生产时容易卡在长任务中断、上下文超限、工具输出污染、片段拒绝、章节摘要缺 source-grounding" "$README"
    grep -q "分 stage / batch / chapter 建立 checkpoint" "$README"
    grep -q "_progress.md" "$README"
    grep -q "stage2-grounding-check.js" "$README"
    grep -q "stage2-summary-quality-check.js" "$README"
    grep -q "long-analyze-recovery-state.js" "$README"

    grep -q "Long-form deconstruction reliability" "$README_EN"
    grep -q "Upstream already provides long-form deconstruction and chapter-extractor" "$README_EN"
    grep -q "long tasks stopping halfway, context overflow, polluted tool output, partial refusals, and summaries without source grounding" "$README_EN"
    grep -q "stage / batch / chapter checkpoints" "$README_EN"
    grep -q "_progress.md" "$README_EN"
    grep -q "stage2-grounding-check.js" "$README_EN"
}

@test "README documents volume outline fine-outline and cross-volume handoff design" {
    grep -q "卷级结构设计" "$README"
    grep -q "全书总纲、卷纲、章节细纲、章节契约" "$README"
    grep -q "正文/第1卷/第001章_章名.md" "$README"
    grep -q "大纲/第1卷/卷纲.md" "$README"
    grep -q "大纲/第1卷/细纲_第001章.md" "$README"
    grep -q "上一卷预留的钩子、人物状态、未兑现承诺和节奏余波写入" "$README"
    grep -q "追踪/卷交接/" "$README"
    grep -q "发布导出时再全书连续编号" "$README"

    grep -q "Volume-level structure" "$README_EN"
    grep -q "book outline, volume outline, chapter fine outline, and chapter contract" "$README_EN"
    grep -q "正文/第1卷/第001章_章名.md" "$README_EN"
    grep -q "大纲/第1卷/卷纲.md" "$README_EN"
    grep -q "追踪/卷交接/" "$README_EN"
    grep -q "continuous whole-book numbering only at export time" "$README_EN"
}

@test "README documents hooks and internal agent system compared with upstream" {
    grep -q "自动化 hooks 与 agent 体系" "$README"
    grep -q "上游 setup 会部署 agents、hooks、rules 和 CLAUDE.md" "$README"
    grep -q "我们保留并强化为写作协作环境" "$README"
    grep -q "session-start.sh" "$README"
    grep -q "detect-story-gaps.sh" "$README"
    grep -q "guard-outline-before-prose.sh" "$README"
    grep -q "prose-quality-gate.sh" "$README"
    grep -q "validate-story-commit.sh" "$README"
    grep -q "story-architect" "$README"
    grep -q "character-designer" "$README"
    grep -q "narrative-writer" "$README"
    grep -q "consistency-checker" "$README"
    grep -q "story-researcher" "$README"
    grep -q "story-explorer" "$README"
    grep -q "chapter-extractor" "$README"
    grep -q "style-learner" "$README"

    grep -q "Automated hooks and internal agent system" "$README_EN"
    grep -q "Upstream setup deploys agents, hooks, rules, and CLAUDE.md" "$README_EN"
    grep -q "writing collaboration environment" "$README_EN"
    grep -q "session-start.sh" "$README_EN"
    grep -q "guard-outline-before-prose.sh" "$README_EN"
    grep -q "prose-quality-gate.sh" "$README_EN"
    grep -q "story-architect" "$README_EN"
    grep -q "chapter-extractor" "$README_EN"
    grep -q "style-learner" "$README_EN"
}

@test "README documents practical novel-assistant usage flow" {
    grep -q "开书前" "$README"
    grep -q "拆文/扫榜" "$README"
    grep -q "开书与总纲" "$README"
    grep -q "日更写作" "$README"
    grep -q "审阅与修复" "$README"
    grep -q "扩容/插章/回炉" "$README"
    grep -q "导出发布" "$README"
    grep -q "/novel-assistant 我想开一本" "$README"
    grep -q "/novel-assistant 继续当前任务" "$README"
    grep -q "/novel-assistant 查看成本报告" "$README"
}

@test "README compares novel-assistant with upstream production design" {
    grep -q "与上游的主要差异" "$README"
    grep -q "上游更像能力集合" "$README"
    grep -q "我们更像生产系统" "$README"
    grep -q "单入口路由" "$README"
    grep -q "长任务无人值守" "$README"
    grep -q "章节/卷结构" "$README"
    grep -q "Token 成本治理" "$README"
    grep -q "生产验收矩阵" "$README"
}

@test "README explains why source story modules live under src internal skills" {
    grep -q "为什么源码里还有 story\\*" "$README"
    grep -q "普通用户不会安装这些目录" "$README"
    grep -q "src/internal-skills/story\\*" "$README"
    grep -q "skills/.*顶层只保留.*novel-assistant" "$README"
    grep -q "bundle 构建" "$README"
    grep -q "上游吸收" "$README"
    grep -q "setup 部署检查" "$README"
    grep -q "构建后同步到" "$README"
}

@test "longform stability quickstart covers daily, revision, repair, and index commands" {
    [ -f "$QUICKSTART" ]
    grep -q "bash scripts/chapter-index-build.sh --write" "$QUICKSTART"
    grep -q "bash scripts/longform-daily-stability-audit.sh --write" "$QUICKSTART"
    grep -q "bash scripts/revision-stability-recheck.sh --write" "$QUICKSTART"
    grep -q "bash scripts/stability-agent-dispatch-prompt.sh --json" "$QUICKSTART"
    grep -q "current_owner" "$QUICKSTART"
    grep -q "current_action" "$QUICKSTART"
}

@test "release checklist records final verification commands" {
    [ -f "$RELEASE" ]
    grep -q "bash scripts/run-bats-tests.sh" "$RELEASE"
    grep -q "bash scripts/check-story-setup-deployment.sh" "$RELEASE"
    grep -q "bash scripts/check-shared-files.sh" "$RELEASE"
    grep -q "bash scripts/static-check.sh" "$RELEASE"
    grep -q "git diff --check" "$RELEASE"
    grep -q "docs/release-checklist.md" "$README"
}

@test "README documents upstream backport workflow" {
    grep -q "维护者：上游反哺检查" "$README"
    grep -q "bash scripts/check-upstream.sh --write" "$README"
    grep -q "refs/remotes/upstream-check/main" "$README"
    grep -q "reports/upstream/" "$README"
    grep -q "Tag Comparison" "$README"
    grep -q "Backport Triage Template" "$README"
    grep -q "absorb" "$README"
    grep -q "already-covered" "$README"
    grep -q "docs/upstream-backport-sop.md" "$README"
}
