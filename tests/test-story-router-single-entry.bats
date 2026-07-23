#!/usr/bin/env bats
# tests/test-story-router-single-entry.bats

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    ROUTER="$REPO/src/internal-skills/story/SKILL.md"
    NOVEL="$REPO/skills/novel-assistant/SKILL.md"
    WORKFLOW="$REPO/src/internal-skills/story-workflow/SKILL.md"
    README="$REPO/README.md"
}

entry_or_protocol_has() {
    local needle="$1"
    local protocol_dir="$REPO/src/internal-skills/story-workflow/references"

    grep -q -- "$needle" "$NOVEL" ||
        grep -q -- "$needle" "$ROUTER" ||
        grep -q -- "$needle" "$WORKFLOW" ||
        grep -q -- "$needle" "$protocol_dir/task-inbox-protocol.md" ||
        grep -q -- "$needle" "$protocol_dir/runner-execution-protocol.md" ||
        grep -q -- "$needle" "$protocol_dir/canonical-write-protocol.md" ||
        grep -q -- "$needle" "$protocol_dir/completion-evidence-protocol.md"
}

@test "top entry stays within progressive disclosure budget" {
    [ "$(wc -l < "$NOVEL")" -lt 260 ]
    grep -q "触发与路由" "$NOVEL"
    grep -q "更新确认硬门" "$NOVEL"
    grep -q "首屏与恢复" "$NOVEL"
    grep -q "安全边界" "$NOVEL"
    grep -q "引用索引" "$NOVEL"
}

@test "top entry itself retains the startup gate and reference index" {
    grep -q "更新确认是硬前置门禁" "$NOVEL"
    grep -q "必须暂停正常路由" "$NOVEL"
    grep -q "用户选择暂不更新后，才继续原始意图" "$NOVEL"
    grep -q "task-inbox-protocol.md" "$NOVEL"
    grep -q "引用索引" "$NOVEL"
    ! grep -q "下方「脚本解析规则」" "$NOVEL"
}

@test "novel-assistant startup update check prompts but does not auto setup" {
    entry_or_protocol_has "启动自检"
    entry_or_protocol_has "只提醒，不自动更新写作协作环境"
    entry_or_protocol_has "novel-assistant-update-check.js"
    entry_or_protocol_has "是否现在更新写作协作环境"
    entry_or_protocol_has "必须暂停正常路由"
    entry_or_protocol_has "不要读取章节状态"
    entry_or_protocol_has "用户选择暂不更新后，才继续原始意图"
}

@test "startup environment update prompt is a hard gate before writing intent routing" {
    entry_or_protocol_has "更新确认是硬前置门禁"
    entry_or_protocol_has ".story-deployed.novel_assistant_bundle_id.*novel-assistant-manifest.json.bundleId.*不一致"
    entry_or_protocol_has "第一屏只能是更新确认"
    entry_or_protocol_has "不得先输出.*当前：第 X 卷/第 X 章"
    entry_or_protocol_has "不要读取 .book-state.json"
    entry_or_protocol_has "追踪/workflow/current-task.json"
    entry_or_protocol_has "拆文 _progress.md"
    entry_or_protocol_has "不得同时输出更新确认和写作意图候选"
    entry_or_protocol_has "确认更新或暂不更新后，才允许读取项目状态并判断写作意图"
    entry_or_protocol_has "已误读出业务状态，必须丢弃该状态"

    grep -q "更新确认优先于工作流编排" "$ROUTER"
    grep -q ".story-deployed.novel_assistant_bundle_id.*novel-assistant-manifest.json.bundleId.*不一致" "$ROUTER"
    grep -q "第一屏只能展示协作环境更新确认" "$ROUTER"
    grep -q "不得读取 story-workflow" "$ROUTER"
    grep -q "不得读取章节状态、当前进度或业务候选" "$ROUTER"
    grep -q "暂不更新后，才恢复原始写作意图路由" "$ROUTER"
}

@test "startup runtime supervisor runs before business candidates after update gate" {
    entry_or_protocol_has "启动运行时巡检"
    entry_or_protocol_has "workflow-runtime-supervisor.js"
    entry_or_protocol_has "更新确认收束后"
    entry_or_protocol_has "不得绕过 supervisor 直接生成业务候选"
    entry_or_protocol_has "pause_at_checkpoint"
    entry_or_protocol_has "resume_from_checkpoint"

    grep -q "启动运行时巡检" "$ROUTER"
    grep -q "workflow-runtime-supervisor.js" "$ROUTER"
    grep -q "先运行 supervisor" "$ROUTER"
    grep -q "再读取 story-workflow" "$ROUTER"
    grep -q "stalled / pause_at_checkpoint" "$ROUTER"
    grep -q "resumable / resume_from_checkpoint" "$ROUTER"
}

@test "novel-assistant separates skill update from project setup refresh" {
    entry_or_protocol_has "两层更新协议"
    entry_or_protocol_has "检查更新"
    entry_or_protocol_has "更新 skill"
    entry_or_protocol_has "更新写作协作环境"
    entry_or_protocol_has "novel-assistant-self-update.js"
    entry_or_protocol_has "开发版"
    entry_or_protocol_has "稳定版"
    entry_or_protocol_has "不得把 skill 更新和当前书籍项目的协作环境更新混为一步"
    entry_or_protocol_has "story-setup"
}

@test "novel-assistant documents user-facing action boundaries" {
    entry_or_protocol_has "用户动作边界"
    entry_or_protocol_has "准备写书"
    entry_or_protocol_has "更新写作协作环境"
    entry_or_protocol_has "迁移章节结构"
    entry_or_protocol_has "创作补全/回炉"
    entry_or_protocol_has "不修改正文、大纲、细纲"
    entry_or_protocol_has "迁移章节结构.*单独确认"

    grep -q "用户动作边界" "$README"
    grep -q "更新写作协作环境.*不修改正文、大纲、细纲" "$README"
    grep -q "迁移章节结构.*单独确认" "$README"
}

@test "novel-assistant defines cross-module narrative continuity responsibilities" {
    entry_or_protocol_has "跨模块叙事连续性治理"
    entry_or_protocol_has "story-long-write.*写作/续写/回炉"
    entry_or_protocol_has "story-review.*审阅/补审"
    entry_or_protocol_has "story-deslop.*只能改文字表达"
    entry_or_protocol_has "story-short-write.*短篇内部因果"
    entry_or_protocol_has "story-long-analyze.*事实底座"
    entry_or_protocol_has "story-import.*反向建立连续性资产"
}

@test "non-writing modules declare production boundaries in their own skills" {
    grep -q "事实底座" "$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    grep -q "不生成本书事实" "$REPO/src/internal-skills/story-long-analyze/SKILL.md"
    grep -q "事实底座" "$REPO/src/internal-skills/story-short-analyze/SKILL.md"
    grep -q "不生成本书事实" "$REPO/src/internal-skills/story-short-analyze/SKILL.md"

    grep -q "市场输入" "$REPO/src/internal-skills/story-long-scan/SKILL.md"
    grep -q "不替代本书大纲和连续性校验" "$REPO/src/internal-skills/story-long-scan/SKILL.md"
    grep -q "市场输入" "$REPO/src/internal-skills/story-short-scan/SKILL.md"
    grep -q "不替代短篇结构判断" "$REPO/src/internal-skills/story-short-scan/SKILL.md"

    grep -q "反向建立连续性资产" "$REPO/src/internal-skills/story-import/SKILL.md"
    grep -q "不擅自改写原正文" "$REPO/src/internal-skills/story-import/SKILL.md"
    grep -q "不参与叙事连续性" "$REPO/src/internal-skills/story-cover/SKILL.md"
    grep -q "数据采集工具" "$REPO/src/internal-skills/browser-cdp/SKILL.md"
    grep -q "不做写作判断" "$REPO/src/internal-skills/browser-cdp/SKILL.md"
}

@test "novel-assistant documents long task self healing across modules" {
    entry_or_protocol_has "长任务故障自愈协议"
    entry_or_protocol_has "长篇拆文"
    entry_or_protocol_has "全书审查"
    entry_or_protocol_has "批量回炉"
    entry_or_protocol_has "导入小说"
    entry_or_protocol_has "扫榜抓取"
    entry_or_protocol_has "文件系统是权威"
    entry_or_protocol_has "外部阻断类"
}

@test "novel-assistant requires long tasks to summarize raw tool output" {
    entry_or_protocol_has "原始工具输出不是可结束状态"
    entry_or_protocol_has "扫描只算证据收集"
    entry_or_protocol_has "报告、进度、断点和下一步"
    entry_or_protocol_has "不能让用户只看到原始 Bash 输出后回到输入框"
}

@test "novel-assistant routes explicit chapter diagnosis prompts to story review" {
    entry_or_protocol_has "读 1-200 章"
    entry_or_protocol_has "发现问题"
    entry_or_protocol_has "钩子回收"
    entry_or_protocol_has "情节偏离"
    entry_or_protocol_has "AI味道"
    entry_or_protocol_has "story-review"
}

@test "story router normalizes colloquial Chinese writing intents" {
    grep -q "中文自然语言意图归一化" "$ROUTER"
    grep -q "看一下前 200 章" "$ROUTER"
    grep -q "过一遍 1-200 章" "$ROUTER"
    grep -q "哪里不对劲" "$ROUTER"
    grep -q "节奏跑偏" "$ROUTER"
    grep -q "境界升级太快" "$ROUTER"
    grep -q "先输出修复方案" "$ROUTER"
    grep -q "明确说执行修改" "$ROUTER"
}

@test "story router sends short writing and short deslop through workflow brain" {
    grep -q "短篇写作路由补充" "$ROUTER"
    grep -q "短篇/盐言/一万字/写个故事" "$ROUTER"
    grep -q "先读取 story-workflow" "$ROUTER"
    grep -q "story-short-write" "$ROUTER"
    grep -q "genre_style_pack" "$ROUTER"
    grep -q "short_format_path" "$ROUTER"
    grep -q "short_deslop_path" "$ROUTER"
    grep -q "短篇去 AI 味" "$ROUTER"
    grep -q "正文.md.*小节大纲.md" "$ROUTER"
    grep -q "不要先路由到长篇通用 story-deslop" "$ROUTER"
}

@test "story router treats single-letter phase replies as continuation choices" {
    entry_or_protocol_has "单字母阶段续跑"
    entry_or_protocol_has "a/b/c/d/e"
    entry_or_protocol_has "不得反问.*单字符"
    entry_or_protocol_has "Phase E 人物出场铺垫"

    grep -q "单字母阶段续跑" "$ROUTER"
    grep -q "用户只输入.*e" "$ROUTER"
    grep -q "继续执行 Phase E" "$ROUTER"
    grep -q "不得把.*e.*无意义输入" "$ROUTER"
}

@test "story router supports Chinese-first short replies with English aliases" {
    entry_or_protocol_has "短回复归一化"
    entry_or_protocol_has "默认语言.*中文"
    entry_or_protocol_has "English aliases"
    entry_or_protocol_has "选E"
    entry_or_protocol_has "第5项"
    entry_or_protocol_has "确认/是/好/行/可以/yes/y/ok"

    grep -q "短回复归一化" "$ROUTER"
    grep -q "1/e/E/选E/第5项" "$ROUTER"
    grep -q "按最近确认点解释" "$ROUTER"
}

@test "visible user-facing output is Chinese-first even if model thinking drifts" {
    entry_or_protocol_has "用户可见输出中文优先"
    entry_or_protocol_has "thinking trace"
    entry_or_protocol_has "最终回复、候选项、落盘报告和正文必须中文优先"

    grep -q "用户可见输出中文优先" "$WORKFLOW"
    grep -q "不以宿主 UI 的 thinking trace 语言作为验收对象" "$WORKFLOW"
    grep -q "英文只能作为技术字段名" "$WORKFLOW"
}

@test "story router binds short replies to explicit pending actions" {
    entry_or_protocol_has "pending_action"
    entry_or_protocol_has "pending_action.type"
    entry_or_protocol_has "优先级从高到低"
    entry_or_protocol_has "不要同时抛出两个需要短回复的确认点"

    grep -q "短回复绑定" "$ROUTER"
    grep -q "必须先寻找最近一个 pending_action" "$ROUTER"
    grep -q "没有 pending_action 才回退到阶段表" "$ROUTER"
    grep -q "确认.*不能被绑定到 Phase" "$ROUTER"
    grep -q "workflow_id" "$ROUTER"
    grep -q "book_root" "$ROUTER"
    grep -q "expires_at" "$ROUTER"
    grep -q "visible_choice_hash" "$ROUTER"
    grep -q "expected_reply_set" "$ROUTER"
    grep -q "短回复只能绑定到最新可见候选" "$ROUTER"
    grep -q "过期.*pending_action.*不得执行" "$ROUTER"
}

@test "story router is documented as the single user-facing entry" {
    grep -q "唯一入口" "$ROUTER"
    grep -q "用户只需要记住" "$ROUTER"
    grep -q "/story" "$ROUTER"
    grep -q "其他 story-\* skill 作为内部能力" "$ROUTER"
}

@test "story router injects longform stability workflow by default" {
    grep -q "长篇稳定性默认策略" "$ROUTER"
    grep -q "不得直接写正文" "$ROUTER"
    grep -q "Chapter Contract -> 正文写作 -> Plot Drift Gate -> State Delta Ledger -> Chapter Handoff Pack" "$ROUTER"
    grep -q "Longform Daily Stability Audit" "$ROUTER"
    grep -q "Stability Repair Loop" "$ROUTER"
    grep -q "chapter-index-build.sh" "$ROUTER"
}

@test "story router routes revisions through revision stability recheck" {
    grep -q "回炉/大修默认策略" "$ROUTER"
    grep -q "Revision Impact Analysis" "$ROUTER"
    grep -q "revision-stability-recheck.sh" "$ROUTER"
    grep -q "没有通过复检前" "$ROUTER"
}

@test "story router separates startup writing from setup deployment" {
    grep -q "开书引导路由" "$ROUTER"
    grep -q "story-setup 只负责基础设施部署" "$ROUTER"
    grep -q "部署完成后必须接续" "$ROUTER"
    grep -q "不可把开书停在 story-setup" "$ROUTER"
    grep -q "workflow-startup.md" "$ROUTER"
}

@test "story router has a writing-intent decision matrix" {
    grep -q "写作意图决策矩阵" "$ROUTER"
    grep -q "新书启动" "$ROUTER"
    grep -q "已有项目续写" "$ROUTER"
    grep -q "导入已有小说" "$ROUTER"
    grep -q "扫榜选题" "$ROUTER"
    grep -q "更新维护" "$ROUTER"
    grep -q "全书/范围诊断" "$ROUTER"
    grep -q "读 1-200 章" "$ROUTER"
}

@test "story router requires active book before multi-book write actions" {
    grep -q "多书写入安全" "$ROUTER"
    grep -q "写入类任务" "$ROUTER"
    grep -q ".active-book" "$ROUTER"
    grep -q "必须先确认目标书" "$ROUTER"
    grep -q "只发现一本书时" "$ROUTER"
    grep -q "查询类任务" "$ROUTER"

    entry_or_protocol_has "多书写入安全"
    entry_or_protocol_has "多个书籍项目"
    entry_or_protocol_has "必须先确认目标书"
}

@test "story router explains Codex handoff behavior" {
    grep -q "Codex 中" "$ROUTER"
    grep -q "读取目标 skill 的 SKILL.md" "$ROUTER"
    grep -q "story-long-write.*内部模块" "$ROUTER"
    grep -q "继续执行目标 skill 的流程" "$ROUTER"
}

@test "README tells users they can start from story only" {
    grep -q "只记一个入口" "$README"
    grep -q "/story" "$README"
    grep -q "自动路由" "$README"
}
