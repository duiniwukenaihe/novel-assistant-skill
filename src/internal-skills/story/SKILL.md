---
name: story
description: |
  网络小说工具箱内部总控 router。用户只需要记住外部入口 /novel-assistant，由本内部模块根据需求自动路由并继续执行对应 workflow。
  触发方式：/novel-assistant、/网文、「我想写小说」「帮我写书」「写网文」
  当用户意图不明确时触发此 skill，由路由逻辑分发到具体的扫榜/拆文/写作/去AI味/封面 skill；长篇写作默认启用稳定性控制闭环。
---

# story：网文工具箱内部 router

你是 novel-assistant 的内部总控 router。用户只需要记住 `/novel-assistant`；其他 story-* skill 都是按意图读取并继续执行的内部能力。

## 单入口与输出

1. `/novel-assistant`、`/网文` 或自然语言网文任务都先在此判断意图。能安全匹配时直接读取目标 SKILL.md 并继续，不能只输出内部 skill 名；只有信息不足才问 1 个关键问题。
2. 对外输出命令规范：面向用户的下一步命令统一只写 `/novel-assistant + 意图短语`，不要把 `/story-long-write`、`/story-deslop`、`/story-review` 或 `/story-setup` 写成可直接调用的 slash command；单目录 `novel-assistant` 安装模式下内部 skill 不是顶层 slash command。
3. Codex 没有 Claude Code 的 `Skill("skill-name")` 语义：定位目标模块后读取其 SKILL.md，并执行至完成或该模块的确认点。私有扩展只在相应文件存在且 evidence gate 确认 owner 时读取，缺失则降级公开模块，不能暴露私有模块名。

需要给出后续动作时使用以下单入口格式：

```text
下一步可执行：
- /novel-assistant 继续写第 3 章
- /novel-assistant 对已写章节去 AI 味
- /novel-assistant 多视角审查当前正文
```

示例仅说明格式；实际范围、卷内编号和任务名必须来自当前项目状态，不得照抄示例。

仅当短回复、裸更新、单字母阶段续跑、短篇去 AI 味或低置信度纠偏命中时，必须读取 `references/router-edge-cases.md`；普通路由不得预读该文件。常规长篇续写/稳定性与范围审阅（如审阅 1-200）同样属于必读触发条件，不能只因意图明确就跳过 edge contract。

| 边界路由意图 | 必读 reference |
|---|---|
| 短回复、裸更新、单字母阶段续跑 | `references/router-edge-cases.md` |
| 短篇去 AI 味 | `references/router-edge-cases.md` |
| 常规长篇续写/稳定性 | `references/router-edge-cases.md` |
| 范围审阅（如审阅 1-200） | `references/router-edge-cases.md` |
| 低置信度纠偏、自由文本修正与回炉 | `references/router-edge-cases.md` |

<!-- route-reference-contract
{
  "schema_version": "1.0.0",
  "routes": [
    {
      "selected_route": "review",
      "smoke_case_id": "review",
      "match_patterns": ["(?:审阅|审查|检查|读).*(?:\\d+\\s*[-~至到]\\s*\\d+\\s*章|全书|整卷)"],
      "trigger_samples": ["审阅 1-200 章"],
      "edge_intent": "范围审阅（如审阅 1-200）",
      "references": ["story-workflow/SKILL.md", "story/references/router-edge-cases.md", "story-review/SKILL.md"]
    },
    {
      "selected_route": "short_review",
      "smoke_case_id": "review",
      "match_patterns": ["(?:审阅|审查|首评|验收|生产验收|只读验收).*(?:短篇|当前作品|完整作品|全篇|成稿)|(?:短篇|当前作品|完整作品|全篇|成稿).*(?:审阅|审查|首评|验收|生产验收|只读验收)"],
      "trigger_samples": ["对当前完整短篇做只读生产验收"],
      "references": ["story-workflow/SKILL.md", "story-review/SKILL.md"]
    },
    {
      "selected_route": "long_write",
      "smoke_case_id": "long_write",
      "match_patterns": ["继续写|下一章|日更"],
      "trigger_samples": ["继续写下一章"],
      "edge_intent": "常规长篇续写/稳定性",
      "references": ["story-workflow/SKILL.md", "story/references/router-edge-cases.md", "story-long-write/SKILL.md"]
    },
    {
      "selected_route": "short_write",
      "smoke_case_id": "short_write",
      "match_patterns": ["短篇.*(?:精修|润色|修改)|(?:精修|润色|修改).*短篇"],
      "trigger_samples": ["短篇精修这一稿"],
      "references": ["story-workflow/SKILL.md", "story-short-write/SKILL.md"]
    },
    {
      "selected_route": "update_check",
      "smoke_case_id": "update_check",
      "match_patterns": ["检查更新|更新(?:本地)?\\s*skill|更新写作协作环境|更新维护"],
      "trigger_samples": ["更新写作协作环境"],
      "references": ["references/entry-runtime-contract.md", "story-setup/SKILL.md"]
    }
  ],
  "fallback": {
    "selected_route": "fallback_question",
    "sample": "帮我概括这个故事的主题",
    "references": ["internal-skills/story/SKILL.md"]
  }
}
route-reference-contract -->

## 启动、项目与工作流门禁

项目根只能是本会话的当前工作目录：不得向上查找父目录、书库目录或相邻书籍，也不得把父目录或书库目录的 `.story-deployed` 当作当前书状态。具体识别与更新确认读取顶层 `entry-runtime-contract.md`。

进入写作项目遵循：定位书籍根目录 -> 检查已安装 skill -> 决定是否刷新协作运行时 -> 预览并决定元数据迁移 -> 规范化工作流状态 -> 恢复任务或路由明确意图。前一步未收束时不得预读后一步状态；门禁收束后明确业务意图优先于旧任务恢复。

### 开书引导路由

`story-setup` 只部署 hooks、rules、agents、CLAUDE.md、`.story-deployed` 与状态模板，不是开书创作流程。

1. 用户说“开书、帮我写书、我想写小说、写长篇、新书启动”且没有 `.story-deployed`：先读取 `story-setup` 部署，再读取 `story-long-write` 的 `references/workflow-startup.md`；不得停在 setup。
2. 已部署项目直接进入 `story-long-write` 的新书启动，先确认章纲、约束与状态输入，不直接写正文。
3. 有 `正文/` 与 `追踪/` 且用户说“继续、下一章、日更”时按已有书门禁进入日更续写；用户明确开新书或给新书名时不复用旧书上下文。
4. 缺题材、平台、目标情绪或对标书时，按新书启动的 Market Positioning Gate 只问必要问题；用户要求市场数据才路由 `story-long-scan`，之后回到新书启动。

### 工作流编排门禁

进入写作、拆文、审阅、回炉、去 AI 味、扫榜或封面前，先读取 `story-workflow`：`current-task.json` 只落盘或恢复 UI focus pointer，任务权威必须按 `workflow_id` 读取 `追踪/workflow/tasks/<workflow_id>/task.json`；工作流锁定阶段、范围和读写边界后，再读取目标专业模块。业务路由前由 `workflow-entry-guard.js --write` 领取会话租约并校正状态，随后运行 `workflow-runtime-supervisor.js --project-root <book-root> --json`；其 `recommended_next` 优先于聊天记忆。

无明确业务意图的已初始化项目必须只展示任务收件箱四个同级数字入口；明确新业务意图允许直接普通路由，旧任务只作上下文。任务、候选、写入、恢复和完成证据必须遵循 `story-workflow` 当前阶段指定的协议。

全局任务收件箱通过 `workflow-task-inbox.js` 维护 `task-index.json`、`workflow_groups` 与任务候选；router 只交接，不自行展开卡片或推荐。

### 更新确认优先于工作流编排

顶层自检为 `not_deployed` 或 `update_available` 时，更新确认优先于任何业务路由。`.story-deployed.novel_assistant_bundle_id` 与 `novel-assistant-manifest.json.bundleId` 不一致即为 `update_available`；第一屏只能展示协作环境更新确认，不得读取章节状态、当前进度或业务候选。用户确认时只进入 `story-setup` 更新协作环境；暂不更新后，才恢复原始写作意图路由。根目录解析、确认 schema 和执行能力详情见顶层 `entry-runtime-contract.md`。

### 短篇写作路由补充

短篇/盐言/一万字/写个故事/短篇精修/短篇去 AI 味同样先读 `story-workflow`。先用 `workflow-state-machine.js templates --json` 或私有 `workflow-registry.json` 取最终 owner；本地私有 owner 存在且接管 `short_write` 时，短篇创作、资讯/素材学习、脑洞卡、回炉和短篇去 AI 味均直接进入该 owner，**不得先执行或推荐**公开 `story-short-write` / `story-short-scan`，也不得再问用户是否切换。用户明确要求“审阅、首评、完整作品验收、只读生产验收”时，无论公有或私有写作链都必须创建 `short_review` 工作流并进入 `story-review`；私有模块只向 workflow packet 提供增强 rubric 和项目上下文，不拥有审阅结论。私有短篇的新建默认链是“先获取并学习近期公开资讯 → 资讯池选择 → 素材/爆点/脑洞卡 → 建立独立项目 → 设定 → 小节大纲 → 逐节 Brief → 正文”；用户明确“获取素材/最新资讯/热点”时，直接进入当前私有 `short_write.info_source_pool`，不要误判为公开扫榜。只有当安装包中根本不存在私有模块时，GitHub 公开构建才使用公开 fallback：写作/精修由 `story-short-write`，扫榜才由 `story-short-scan`；本地私有构建不向用户提供公私切换菜单。短篇去 AI 味不得先落到通用 `story-deslop`。workflow packet 必须包含 `workflow_type=short_write | short_review | short_revision | short_deslop`、`genre_style_pack`、`short_format_path`、`short_craft_path`、`short_deslop_path`、`benchmark_paths`、`deconstruction_meta` 与 `short_project_root`。

## AI-first structured intent 路由契约与路由表

所有写作、审阅、拆文、去 AI、回炉、导入或维护先形成 `intent_schema`：`intent_type`、`target_scope`、`user_goal`、`route_confidence`、`evidence`、`required_inputs`、`fallback_question`、`selected_workflow_type`、`selected_owner_module`。`route_confidence >= 0.75` 直接路由并写入 workflow packet；介于 0.45 与 0.75 只允许低风险只读探查；更低只问一个 fallback_question。更新、覆盖/删除/迁移与高风险写入确认优先；明确新目标使用状态机 `switch-intent`，不硬绑定旧 pending_action。

短篇请求先读取 story-workflow；长篇稳定性默认策略、`Chapter Contract` 与扩容/插章/后移章节的执行细节仅在 edge-case contract 中加载。拆文请求、长篇扫榜工作流（`long_scan`）、短篇扫榜工作流（`short_scan`）、短篇拆文工作流（`short_analyze`）、封面工作流与去 AI 味请求均先经 workflow 建立范围和 owner；生成或覆盖前确认视觉方向，短篇去 AI 味读取 `short-deslop.md`，不越过确认直接写入。

| 用户意图 | 路由到 |
|---|---|
| 阶段审阅反馈、当前阶段上下文 | `story-long-write` + `workflow-review-feedback.md` |
| 全书/范围诊断、读 1-200 章、发现问题/修复方案 | `story-review` |
| 完整短篇首评、全篇只读生产验收 | `story-review`；私有短篇模块只补充增强审阅上下文 |
| 新书、长篇、连载、继续写、下一章、日更、回炉 | `story-long-write` |
| 短篇、盐言、一万字、短篇素材学习/脑洞/精修 | 先取 registry 最终 owner；本地私有 owner 接管时直接进入私有短篇流程，否则 `story-short-write`（纯榜单扫描才是 `story-short-scan`） |
| 长篇/短篇拆文 | `story-long-analyze` / `story-short-analyze` |
| 长篇扫榜、选题决策 | `story-long-scan` |
| 短篇扫榜 | `story-short-scan` |
| 去 AI 味、改自然、改人味 | `story-deslop` |
| 封面 | `story-cover` |
| 准备写书、搭环境、初始化、迁移章节结构 | `story-setup` |
| 更新维护：检查更新、更新 skill、更新写作协作环境 | 顶层两层更新协议；仅运行时更新进入 `story-setup` |
| 导入、反向解析、现成小说 | `story-import`，完成后衔接长篇或短篇写作 |
| 查角色、伏笔、进度、设定 | 可用时 `story-explorer`，否则直接检索 |
| 查资料、调研、搜索 | 可用时 `story-researcher`，否则直接检索 |

无法匹配时只问最关键问题；“我想写小说”未指定篇幅时询问长短篇，但出现连载、日更、章节或开书时默认长篇。

## 项目与多书安全

- 无项目目录时，开书/写作先走 `story-setup` 后续接 `story-long-write`；扫榜、拆文可直接路由。
- 已有项目检查 `.story-deployed`；未部署的已有小说项目（`正文/`、`大纲/`、`设定/`、`追踪/` 任意两个目录，或加 `CLAUDE.md`）必须先更新协作环境，不能直接读取章节状态或写正文。
- 多书写入类任务（继续写、回炉、扩容、合并、迁移章节结构、更新大纲/细纲、删除、发布改稿）先确认目标书；查询类可宽松。多书且 `.active-book` 缺失、失效或冲突时，先选书，再读取章节状态或写入。只发现一本时可确认它为活跃书。
