#!/usr/bin/env bats
# tests/test-stage-review-feedback.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    LONG_WRITE="$REPO/src/internal-skills/story-long-write/SKILL.md"
    REVIEW="$REPO/src/internal-skills/story-review/SKILL.md"
    WORKFLOW="$REPO/src/internal-skills/story-long-write/references/workflow-review-feedback.md"
    REVISION_WORKFLOW="$REPO/src/internal-skills/story-long-write/references/workflow-revision.md"
    RIA="$REPO/src/internal-skills/story-long-write/references/revision-impact-analysis.md"
    BUNDLE="$REPO/skills/novel-assistant"
}

@test "story review applies long task self healing to full book review batches" {
    grep -q "全书级审查故障自愈" "$REVIEW"
    grep -q "追踪/审查批次计划.md" "$REVIEW"
    grep -q "文件系统是权威" "$REVIEW"
    grep -q "第一未完成批次" "$REVIEW"
    grep -q "quota / Token Plan / usage limit" "$REVIEW"
    grep -q "不得从头重跑已完成批次" "$REVIEW"
}

@test "story review uses domain profile before naming growth axis audits" {
    grep -q "story-domain-profile.js" "$REVIEW"
    grep -q "domainProfile" "$REVIEW"
    grep -q "primaryDomain=xiuzhen_xianxia" "$REVIEW"
    grep -q "growthAxisLabel" "$REVIEW"
    grep -q "修炼/武学与经营规则一致性" "$REVIEW"
}

@test "story review must close batches after shell scan evidence" {
    grep -q "审阅批次收束门禁" "$REVIEW"
    grep -q "原始工具输出不是可结束状态" "$REVIEW"
    grep -q "不得只把.*raw Bash scan" "$REVIEW"
    grep -q "批次收束报告" "$REVIEW"
    grep -q "paused_after_scan" "$REVIEW"
    grep -q "running_incomplete" "$REVIEW"
    grep -q "先完成上次批次收束" "$REVIEW"
}

@test "story review writes cross batch handoff summaries before next batch" {
    grep -q "跨批交接摘要" "$REVIEW"
    grep -q "追踪/审查报告/批次交接摘要.md" "$REVIEW"
    grep -q "剧情压缩" "$REVIEW"
    grep -q "钩子与承诺状态" "$REVIEW"
    grep -q "角色状态压缩" "$REVIEW"
    grep -q "能力/成长规则压缩" "$REVIEW"
    grep -q "修真/仙侠项目才显示为修真进度压缩" "$REVIEW"
    grep -q "下一批开审前必须读取上一批交接摘要" "$REVIEW"
    grep -q "与上一批衔接判定" "$REVIEW"
    grep -q "不得只读当前批次正文" "$REVIEW"
}

@test "story review normalizes user range continuation without magic prompts" {
    grep -q "范围续审意图归一化" "$REVIEW"
    grep -q "不要求用户说.*先完成上次批次收束报告" "$REVIEW"
    grep -q "继续审阅 200-400" "$REVIEW"
    grep -q "审阅 300-400" "$REVIEW"
    grep -q "相邻续审" "$REVIEW"
    grep -q "边界重叠" "$REVIEW"
    grep -q "跳段审阅" "$REVIEW"
    grep -q "gap_unreviewed" "$REVIEW"
    grep -q "Gap Bridge Probe" "$REVIEW"
    grep -q "不得声明 1-400 已连续审完" "$REVIEW"
}

@test "story review warns about non-contiguous range risks and later reconciles gaps" {
    grep -q "非连续审阅风险提示" "$REVIEW"
    grep -q "叙事连续性风险组" "$REVIEW"
    grep -q "情节剧情连贯判断会缺少中段证据" "$REVIEW"
    grep -q "剧情情节连续性" "$REVIEW"
    grep -q "钩子上下文" "$REVIEW"
    grep -q "承诺兑现上下文" "$REVIEW"
    grep -q "钩子回收.*可能误判" "$REVIEW"
    grep -q "人物状态.*可能断层" "$REVIEW"
    grep -q "gap_reconciliation_required" "$REVIEW"
    grep -q "补审 gap 后连续性重算" "$REVIEW"
    grep -q "范围补缝报告" "$REVIEW"
    grep -q "追踪/审查报告/连续区间_" "$REVIEW"
    grep -q "重新计算 1-400 的连续结论" "$REVIEW"
    grep -q "补缝重算项" "$REVIEW"
}

@test "story review writes long reports transactionally instead of repeated fragile edits" {
    grep -q "报告落盘事务协议" "$REVIEW"
    grep -q "先创建.*追踪/审查报告" "$REVIEW"
    grep -q "写入新文件或临时文件" "$REVIEW"
    grep -q "禁止在目标文件不存在时使用 Update/Edit" "$REVIEW"
    grep -q "连续 2 次 Error editing file" "$REVIEW"
    grep -q "停止编辑并重新读取文件系统状态" "$REVIEW"
    grep -q "不得继续消耗长上下文硬改同一文件" "$REVIEW"
}

@test "story review preflights report write permissions before long report generation" {
    grep -q "报告写权限预检" "$REVIEW"
    grep -q "test -w" "$REVIEW"
    grep -q "临时写入测试" "$REVIEW"
    grep -q "Error writing file" "$REVIEW"
    grep -q "write_failure_triage" "$REVIEW"
    grep -q "write-failure-triage.js" "$REVIEW"
    grep -q "tool_call_schema_check" "$REVIEW"
    grep -q "参数不完整" "$REVIEW"
    grep -q "file_path.*content" "$REVIEW"
    grep -q "blocked_write_tool_call_invalid" "$REVIEW"
    grep -q "不得说.*继续执行.*落盘" "$REVIEW"
    grep -q "不得再次调用同一 Write/Edit" "$REVIEW"
    grep -q "恢复报告路径" "$REVIEW"
    grep -q "Permission denied" "$REVIEW"
    grep -q "目录 ownership" "$REVIEW"
    grep -q "chown -R" "$REVIEW"
}

@test "story review inherits transactional write gate for reports and repair queues" {
    grep -q "写入事务门禁" "$REVIEW"
    grep -q "PostToolUse hook" "$REVIEW"
    grep -q "blocked_write_hook" "$REVIEW"
    grep -q "blocked_write_missing_output" "$REVIEW"
    grep -q "changed_files.*实际存在" "$REVIEW"
    grep -q "不得把未落盘内容当作完成" "$REVIEW"
}

@test "story review locks explicit chapter range and rejects recent-chapter drift" {
    grep -q "显式范围锁" "$REVIEW"
    grep -q "用户指定 1-200 章" "$REVIEW"
    grep -q "Review Scope Contract" "$REVIEW"
    grep -q "不得改审最近章节" "$REVIEW"
    grep -q "720" "$REVIEW"
    grep -q "越界章节" "$REVIEW"
    grep -q "丢弃越界结果" "$REVIEW"
}

@test "story review preserves user requested audit dimensions in full range reports" {
    grep -q "用户指定审查维度" "$REVIEW"
    grep -q "钩子回收" "$REVIEW"
    grep -q "情节控制" "$REVIEW"
    grep -q "修真进度" "$REVIEW"
    grep -q "人物出场" "$REVIEW"
    grep -q "情节偏离" "$REVIEW"
    grep -q "AI味道" "$REVIEW"
    grep -q "维度覆盖清单" "$REVIEW"
}

@test "story review repair choices distinguish full queue from partial batch" {
    grep -q "修复执行闭环选择协议" "$REVIEW"
    grep -q "completion_policy" "$REVIEW"
    grep -q "full_auto" "$REVIEW"
    grep -q "stage_then_confirm" "$REVIEW"
    grep -q "step_then_confirm" "$REVIEW"
    grep -q "全部修复" "$REVIEW"
    grep -q "用户选择.*全部" "$REVIEW"
    grep -q "先修复 A" "$REVIEW"
    grep -q "A1" "$REVIEW"
    grep -q "完成 A1 后" "$REVIEW"
    grep -q "下一步候选" "$REVIEW"
    grep -q "阶段导航" "$REVIEW"
    grep -q "先执行什么" "$REVIEW"
    grep -q "后续任务" "$REVIEW"
    grep -q "完成后必须询问" "$REVIEW"
    grep -q "不得自动推进 B/C/D" "$REVIEW"
    grep -q "只在 full_auto" "$REVIEW"
    grep -q "任务队列清零" "$REVIEW"
    grep -q "复检" "$REVIEW"
    grep -q "只执行当前步骤" "$REVIEW"
    ! grep -q "仅执行本项" "$REVIEW"
}

@test "story router prioritizes stage review feedback before revision impact analysis" {
    grep -q "阶段审阅反馈" "$ROUTER"
    grep -q "workflow-review-feedback.md" "$ROUTER"
    grep -q "当前审阅文件" "$ROUTER"
    grep -q "优先于.*回炉" "$ROUTER"
}

@test "story router disambiguates bare update from phase execution" {
    grep -q "裸更新歧义" "$ROUTER"
    grep -q "用户只输入.*更新" "$ROUTER"
    grep -q "pending_action.type=phase_choice" "$ROUTER"
    grep -q "不得直接修改正文、大纲、细纲" "$ROUTER"
    grep -q "更新写作协作环境" "$ROUTER"
}

@test "long-write routes frontend stage context into review feedback workflow" {
    grep -q "阶段审阅反馈" "$LONG_WRITE"
    grep -q "workflow-review-feedback.md" "$LONG_WRITE"
    grep -q "【阶段上下文】" "$LONG_WRITE"
    grep -q "当前审阅文件" "$LONG_WRITE"
}

@test "stage review feedback workflow captures user constraints before planning edits" {
    test -f "$WORKFLOW"
    grep -q "用户反馈摄取" "$WORKFLOW"
    grep -q "不得直接进入 Revision Impact Analysis" "$WORKFLOW"
    grep -q "追踪/审阅反馈.md" "$WORKFLOW"
    grep -q "只处理当前阶段相关问题" "$WORKFLOW"
    grep -q "御兽宗" "$WORKFLOW"
    grep -q "灵石认知" "$WORKFLOW"
}

@test "stage review feedback validates global outline changes before implementing" {
    grep -q "可行性验证" "$WORKFLOW"
    grep -q "验证通过后立即实施" "$WORKFLOW"
    grep -q "核心承诺" "$WORKFLOW"
    grep -q "因果链" "$WORKFLOW"
    grep -q "读者期待" "$WORKFLOW"
}

@test "stage review feedback uses outline update transaction gate" {
    grep -q "大纲更新事务门禁" "$WORKFLOW"
    grep -q "Update Scope Contract" "$WORKFLOW"
    grep -q "先列受影响文件" "$WORKFLOW"
    grep -q "dry-run 差异计划" "$WORKFLOW"
    grep -q "版本快照" "$WORKFLOW"
    grep -q "不得读 1 个文件后直接 Update" "$WORKFLOW"
    grep -q "修真进度阈值" "$WORKFLOW"
}

@test "stage review feedback treats hook P0 and output pollution as blocking" {
    grep -q "Hook P0 收束门禁" "$WORKFLOW"
    grep -q "PostToolUse:Edit hook" "$WORKFLOW"
    grep -q "AI 痕迹检测" "$WORKFLOW"
    grep -q "output-pollution-check.js" "$WORKFLOW"
    grep -q "P0.*硬阻塞" "$WORKFLOW"
    grep -q "不得继续编辑同一目标文件" "$WORKFLOW"
    grep -q "paused_after_hook_p0" "$WORKFLOW"
}

@test "stage review feedback implements passed outline changes into affected artifacts" {
    grep -q "全局级 / 大纲级修改实施" "$WORKFLOW"
    grep -q "大纲/大纲.md" "$WORKFLOW"
    grep -q "大纲/卷纲_第" "$WORKFLOW"
    grep -q "大纲/细纲_第XXX章.md" "$WORKFLOW"
    grep -q "追踪/伏笔.md" "$WORKFLOW"
    grep -q "章节后移" "$WORKFLOW"
    grep -q "钩子回收" "$WORKFLOW"
}

@test "stage review feedback classifies outline change type before implementation" {
    grep -q "大纲修改类型判定" "$WORKFLOW"
    grep -q "局部细纲修改" "$WORKFLOW"
    grep -q "扩容插章" "$WORKFLOW"
    grep -q "缩容删减" "$WORKFLOW"
    grep -q "章节合并" "$WORKFLOW"
}

@test "stage review feedback treats local chapter outline edits without shifting chapters" {
    grep -q "不触发章节偏移" "$WORKFLOW"
    grep -q "只修改目标细纲" "$WORKFLOW"
    grep -q "钩子可登记到后续合适章节回收" "$WORKFLOW"
}

@test "stage review feedback shifts later outlines before filling inserted gaps" {
    grep -q "先偏移后填充" "$WORKFLOW"
    grep -q "章节偏移映射表" "$WORKFLOW"
    grep -q "先冻结原有细纲" "$WORKFLOW"
    grep -q "整体后移" "$WORKFLOW"
    grep -q "再填充中间缺口" "$WORKFLOW"
}

@test "stage review feedback prevents missing outline chapters after shifts" {
    grep -q "细纲连续性校验" "$WORKFLOW"
    grep -q "不得留下空号" "$WORKFLOW"
    grep -q "缺失章节" "$WORKFLOW"
    grep -q "承接检查" "$WORKFLOW"
    grep -q "章尾钩子" "$WORKFLOW"
}

@test "stage review feedback handles contraction and merge without breaking continuity" {
    grep -q "先合并后前移" "$WORKFLOW"
    grep -q "删减映射表" "$WORKFLOW"
    grep -q "合并映射表" "$WORKFLOW"
    grep -q "关键 beat" "$WORKFLOW"
    grep -q "后续章节前移" "$WORKFLOW"
}

@test "revision workflows defer stage-scoped review feedback to review workflow" {
    grep -q "workflow-review-feedback.md" "$REVISION_WORKFLOW"
    grep -q "阶段上下文" "$REVISION_WORKFLOW"
    grep -q "workflow-review-feedback.md" "$RIA"
    grep -q "当前审阅文件" "$RIA"
}

@test "oh-story bundle includes stage review feedback routing and workflow" {
    test -f "$BUNDLE/references/internal-skills/story-long-write/references/workflow-review-feedback.md"
    grep -q "阶段审阅反馈" "$BUNDLE/references/internal-skills/story/SKILL.md"
    grep -q "workflow-review-feedback.md" "$BUNDLE/references/internal-skills/story-long-write/SKILL.md"
}
