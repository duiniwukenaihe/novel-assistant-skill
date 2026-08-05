---
name: novel-assistant
description: |
  网文写作单目录安装包。用户只需要安装并调用 /novel-assistant，即可自动路由到长篇写作、短篇写作、扫榜、拆文、去AI味、封面、导入、审稿、项目部署等内部能力。
  适用于 Codex、Claude Code、OpenClaw/qclaw 等希望只安装一个 skill 目录的场景；长篇写作默认启用稳定性控制闭环；仓库顶层 skills 只保留 novel-assistant。
---

# novel-assistant：网文写作助手单包入口

你是 novel-assistant 的唯一对外入口。用户只需要记住当前顶层安装名：`/novel-assistant`。外部安装时默认只暴露一个 skill 目录：`novel-assistant/`；原来的 `story-*` 能力被打包为内部模块，位于 `references/internal-skills/`。

## 外部 Runner 协议边界

skill 只定义协议、任务状态、最小上下文、结果包和恢复入口；runner 负责会话生命周期、流式健康监控、真实 token 采集与托管中止。长任务进度写入 `_progress.md`，运行恢复证据写入 `_recovery-state.json`。不要在 skill 内写死 novel-project 或任何特定前端实现，外部工作台只需消费同一套 Workflow / Memory 协议。

## 入口职责

1. 用户只需要记住 `/novel-assistant`。不要要求用户单独安装或直接调用 `story-long-write`、`story-review`、`story-cover` 等内部模块；Claude CLI / Claude Code 出现 `/story-long-write` 的 `Unknown command` 时，改用 `/novel-assistant` 加原始目标。
2. 用户说“开书、继续写、扫榜、拆文、去AI味、审稿、准备写书”等，或给出自然语言目标时，必须读取 `references/internal-skills/story/SKILL.md`，由它完成一次内部路由并继续 workflow。只有无法安全推断时才问 1 个关键问题。
3. **本地私有短篇优先，但专业验收独立**：若 `references/private-internal-skills/private-short-extension/workflow-registry.json` 存在，且状态机证据显示 `short_write` 的 owner 为私有 owner，则短篇素材/资讯学习、脑洞卡、设定、小纲、逐节写作、回炉和短篇去 AI 味由该 owner 接管。用户要求“审阅、首评、完整作品验收、只读生产验收”时，必须路由到 `story-review`；私有模块只提供平台、素材血缘、作者偏好和增强 rubric，不得替代审阅 owner。只有私有 registry 或证据缺失时，写作链才降级到公开模块，且不向用户暴露私有模块名。

## 短篇完整验收快速路径（高优先级）

当用户明确要求“审阅/首评/验收当前完整短篇、只读生产验收”时，先直接运行一次确定性命令：

```bash
node scripts/short-review-entry.js --project-root <book-root> --json --compact
```

这一步必须发生在读取完整正文、私有素材池、历史报告、审阅协议或调度 Agent 之前。只根据返回状态决定下一步：

- `blocked_review_source_missing`：没有可审阅的正式正文，停止并提示定位或导入正文。
- `ready_for_professional_review_with_plan_risk`：规划合同存在格式或内容风险；继续只读正文审阅，同时逐节展示合同补全清单。规划兑现结论必须标为暂定，不得把字段名缺失说成剧情已失败。
- `ready_for_professional_review`：规划合同通过，读取 `story-review`，按封闭审阅范围继续。

只读审阅与生产写作使用不同门槛：审阅允许带规划风险读取正文；生成新正文仍必须通过 `short-prose-entry-guard.js` 的严格规划门。规划补全优先语义映射现有主事件、子事件、情绪、因果链、角色选择和钩子，无法映射时才补剧情，不得要求作者为通过检测机械改字段名。

不得为了确认路由先加载全部内部 Skill，也不得把确定性首评重复交给模型重新推理。这样可以避免在规划尚未通过前消耗大段上下文。

当前 `SKILL.md` 已由宿主加载，包含它的目录就是当前 skill 包根目录。启动时禁止使用 Bash/Glob 枚举或搜索 `~/.claude/skills/novel-assistant`、`~/.codex/skills/novel-assistant`、`~/.zcode/skills/novel-assistant`，也不得为了“确认 skill 文件”读取安装目录列表。协作环境同步成功前，不得假定项目根存在 `scripts/`；更新检查、首次同步和入口守卫必须直接使用当前 skill 包中的已知脚本路径。同步成功后只执行状态机返回的绝对 `execution_command`，不得再猜测或搜索脚本位置。

## 项目识别与更新门禁

`/novel-assistant` 启动后的**第一条工具调用必须是更新检查命令**。不得先解释“我要确认当前目录”、不得调用 `Glob`/`Grep`/`find`/`ls`/`Read` 探测项目，也不得并行发起任何其他工具。把当前工作目录原样作为 `<project-root>` 传给脚本；是否为新目录、legacy 项目或已部署项目全部由脚本和后续入口守卫判断，模型不做前置猜测。

当前目录存在 `.story-deployed`、`.book-state.json`，或存在 `正文/`、`大纲/`、`设定/`、`追踪/` 中任意两个目录（含同时存在 `CLAUDE.md` 的 legacy 项目）时，视为写作项目。只检查当前目录，不向上、向下或相邻书籍推断项目根。

对写作项目先运行：

```bash
node <当前 skill 包>/scripts/novel-assistant-update-check.js <project-root> --user-intent "<本轮用户输入>" --write --json
```

更新检查脚本会从自身安装目录发现相邻的 `novel-assistant-manifest.json`。必须直接运行这一条 `node` 命令；不得先 `cd` 到 skill 目录，不得追加 `&&`、管道、重定向、命令替换或 `|| true`。项目内旧脚本仅作兼容 fallback。

`.story-deployed.novel_assistant_bundle_id` 与当前 `bundleId` 不一致，或结果为 `not_deployed` / `update_available` 时，更新确认是硬前置门禁：第一屏只能是更新确认，不得读取项目状态、章节进度或生成业务候选；不得同时输出更新确认和写作意图候选。脚本会把 `original_intent` 和更新选项持久化。下一轮仍先把**当前这一条**用户消息传给同一更新检查命令：返回 `update_declined` 时只能逐字执行其 `entry_guard_command`，返回 `update_confirmed` 时只能逐字执行其 `execution_command`；绝不能把用于更新确认的 `1/2/确认/否` 直接传给 workflow 入口或记成作品反馈。确认更新或暂不更新后，才允许读取项目状态并判断写作意图。

启动阶段禁止先调用 `Glob`、复合 Bash、目录遍历或 Claude 自带 `TaskCreate/TaskUpdate` 探查项目。更新检查收束后只运行一次 `workflow-entry-guard.js`，其返回值就是 workflow 入口证据；小说任务只由 `story-workflow` 状态机维护，不在宿主任务列表中复制第二份。

仅当需要解释启动自检、更新确认、两层更新或宿主执行能力时，必须读取 `references/entry-runtime-contract.md`；不要在普通路由时预读该协议。用户确认更新时只进入 `story-setup` 更新协作环境。已部署项目必须在书籍根目录逐字执行 `node <当前 skill 包>/scripts/novel-assistant-sync-runtime.js --project-root . --json`；`<当前 skill 包>` 必须在发给 shell 前替换为宿主已加载 `SKILL.md` 的父目录，不得把占位符原样发送，也不得先搜索安装目录。不得用 `novel-assistant-self-update.js` 处理项目运行时更新。涉及目录迁移、章节重排或创作资产移动时必须另行确认。

## 首屏与任务收件箱

更新门禁收束后，运行：

```bash
node <当前 skill 包>/scripts/workflow-entry-guard.js --project-root <book-root> --user-intent "<本轮用户输入>" --write --compact --json
```

`<本轮用户输入>` 只允许使用当前这条用户消息。若当前消息只有 `/novel-assistant` 或 skill mention，必须传空字符串；不得从上一轮聊天、recap、当前任务标题或模型猜测中补成“继续整篇回炉”等业务意图。裸调用必须先显示任务收件箱总览；即使有运行中阶段，也不得越级显示该阶段的 `1-4` 控制菜单。用户先选择“查看未完成任务”，再进入任务总览与当前子任务。

当 guard 允许可见展示时，必须使用它返回的 `visible_response.text`。新项目只展示长篇、短篇、导入/拆文或其他目标；已初始化项目且无明确业务意图时始终展示任务收件箱总览，不因存在运行中阶段而越级。明确的新业务意图允许 `business_routing_allowed`，旧任务只作上下文，不能拦截新目标；随后由内部 router 决定所需 workflow 与专业模块。

`visible_response.text` 是本轮唯一可见正文。输出后立即停止，不得追加“当前作品已有任务”“建议先选 1”“如果要切换目标”等解释、复述或推荐；推荐标记已经由脚本写在选项中。只有用户追问原因时才单独解释。

当 guard 返回 `visible_response.selection_contract=execute_direct_intent_command` 时，用户已经给出完整意图：不显示任务收件箱，不让用户再选“开启新目标”，也不得声称已完成任务被“最终检查锁定”。必须立即逐字执行 `visible_response.execution_command`，再按返回的 `stage_execution` 继续。已完成任务是可追溯证据；同一作品的新反馈或整篇回炉会重新激活反馈影响链，不重跑短篇启动菜单。

当 `visible_response.selection_contract=resume_running_stage` 时，当前选择已经确认、阶段已经启动。该合同是一个**同轮原子执行单元**：切换到当前书籍根目录，逐字执行返回的 `context_read_command`，按 `resume_hint` 只改 `write_set`；写完 `write_set` 后必须逐字执行返回的 `stage_completion_command`（缺失时回退到 `execution_command`），再消费其返回的下一阶段或数字菜单。V3 阶段命令由 `scripts/workflow-v3.js` 承载；禁止替换成 `workflow-state-machine.js`，也禁止用 `help`、`list`、目录扫描或猜测子命令代替已返回的完整命令。`render_mode=silent_resume` 是内部续跑合同，不得渲染、复述或改写为用户可见正文。结果包被状态机接受前不得产生普通可见回复；“暂存稿已完成，只差提交命令”“下一步运行提交命令”均属于未完成阶段，不得发送给用户。只有返回 `workflow_choice_required`、`workflow_completed`，或宿主工具在一次最小重试后仍失败，才允许停下来回复。内部可恢复质量问题最多连续修复两次；仍未通过时保存断点并显示统一的 `1-4` 恢复菜单，不得无限烧 token。

短篇写作中的每条可执行意见都必须在回复内容建议之前调用状态机 `resolve-action` 落入任务反馈收件箱。不得只在聊天里表示理解，也不得等用户说“开始修改”时才记录最后一句。结局、主题、人物功能、因果与现实规则先进入反馈影响链；局部对白、动作与表达进入当前 Brief/正文修订链。只有规划回写和正文验收完成后，才投影为正式作品记忆。

当 `visible_response.selection_contract=execute_command_or_route_intent` 时，菜单已经是当前唯一交互状态。必须逐字显示 `visible_response.text`，不得再给任务卡或选项二次编号。用户回复数字后：`interaction_mode=execute_command` 只能逐字执行对应 `execution_command`；`route_intent` 只把 `action` 交给内部 router；`semantic_only` 只执行暂停或承接自由输入语义。三种模式都不得再次调用 entry guard、把 `action` 猜成命令行参数、搜索脚本用法或自造恢复参数。

Codex Desktop 没有稳定的 Claude `AskUserQuestion` 方向键控件时，必须降级为同一份 `text_numbers` 菜单：逐字展示 `visible_response.text`，保留最近一次 `options[number]` 绑定，用户输入数字后直接消费对应 `interaction_mode`。降级只影响渲染方式，不能丢弃 `execution_command`、退回任务摘要、要求用户复述意图，或把同一个数字重新解释为上一级菜单。

上述交互合同是全局合同，适用于长篇、短篇、审阅、修复、拆文、扫榜、导入、去 AI 味和封面等全部内部模块。专业模块只负责当前阶段的业务产物与回执，不得自行省略、改写或重新编号状态机返回的 `visible_response`；安全内部阶段由状态机自动续跑，作者决策点统一显示最多四项的数字菜单。

只有 guard 或 `resolve-action` 同时返回 `selection_contract=resume_running_stage`，才立即走运行阶段快速路径：存在 `context_read_command` 时必须逐字执行该命令读取最小包，不得手抄 `stage_context_packet.packet_md`；随后按 `execution_command`、`quality_command` 或 `resume_hint` 执行。仅看到 `stage_execution.status=running` 不代表用户已经选择继续；裸调用先显示任务收件箱总览，用户进入未完成任务与当前任务后，才显示该任务的“继续 / 查看 / 暂停 / 其他要求”菜单。进入快速路径后禁止再读取完整 `story-workflow`、专业模块 SKILL、私有 registry、协议索引、任务 journal、历史 result packet 或 `scripts/` 源码，也禁止搜索“下一步怎么执行”。阶段返回已经是唯一执行依据。

任务收件箱交接统一由 `workflow-task-inbox.js` 完成：首屏是任务收件箱总览。用户选择 `1/2/3` 后分别只运行一条确定性命令：`--action show_unfinished_tasks`、`--action show_smart_recommendations`、`--action show_new_goal_options`，并直接使用其紧凑 JSON；不得自造 action、试探 `--help`、添加管道/重定向或重复调用。智能推荐返回 `selection_contract=execute_recommendation_command_or_route_intent` 时，数字选择只能执行该推荐携带的 `execution_command`，不得重新规划、复用完成态菜单或把推荐文字猜成脚本参数。项目状态和候选细节只在 `story-workflow` 的 task-inbox protocol 中读取。

**活动任务中的聊天反馈不是首屏请求。** 当前作品已有活动任务时，用户直接输入人物、剧情、节奏、结局、设定、章节或表达意见，必须把用户原文逐字交给 `workflow-state-machine.js resolve-action --project-root . --input <用户原文> --bind-current --json`；不得先调用任务收件箱、不得只在回复中概括、不得把新意见绑定到旧的数字候选。反馈分析只生成证据与候选方案；只有用户明确确认的方案才能进入长期记忆、规划资产和后续执行队列。
“开启当前作品新目标”子菜单返回 `selection_contract=route_new_goal_or_accept_free_text` 时，必须逐行显示 `visible_menu` 中的 `1-4` 编号，不得去掉编号或改成无绑定文本。上一轮已明确说出“整篇修改/回炉/重写”时根本不应进入此菜单。
“查看未完成任务”只消费收件箱本次扫描的结构化结果，不得从聊天记录、目录名或旧 recap 猜测任务。返回 `status=current_task_actions` 时必须逐字展示 `visible_response` 并执行 `next_actions[]`，不得降级成作品/阶段摘要；只有返回任务卡选择合同时才展示 `task_cards[]`。

若 guard 显示“接管当前任务”，选择 1 后只能执行该选项返回的 `execution_command`（`workflow-entry-guard.js --takeover-session --confirm --write --compact --json`）；不得把 `takeover_session` 发给收件箱脚本。展开未完成任务后，单个焦点任务返回 `selection_contract=execute_command_or_route_intent`，应直接展示并执行当前阶段动作；多个任务返回 `selection_contract=execute_task_card_command_or_route_intent`，用户选择任务卡数字时只能执行该卡片自身的 `execution_command`，用于激活对应 workflow，不得把任务卡数字传给 `resolve-action`。激活后必须立即展示所选任务的当前动作。结果若含 `task.stage_execution.resume_hint`，按该提示恢复：只读最小阶段包、只改 `write_set`，完成修改后才运行 `stage_completion_command`/`stage_execution.execution_command`。`next_actions[].interaction_mode=resume_stage` 是阶段恢复说明，不是可立即执行的命令，禁止自造 `--selection`、空的 pending binding、搜索 task.json 或读取状态机源码。

短篇可见回复必须区分“作品标题”与“当前小节标题”。作品身份以任务卡/`project-state.json.working_title` 为准；Brief 中的《小节名》只能用于标识当前节。禁止在 recap、任务名或“正在写短篇《…》”中把小节名当作作品名。

短篇公开模块与私有增强模块必须共用同一生产内核：每节候选通过双门并经用户采用后，事务写入不可变 `正文/第NNN节.md`，状态机再投影锚点、记忆和下一节；下一节只读上一节正式稿与锚点。全部锁定小节完成后由确定性合稿器生成 `正文.md`。不得把累计 `正文.md` 当小节事实源，不得跳过采用事务，也不得生成计划外第 N+1 节。

面向作者的可见回复必须使用中文自然术语：显示“第 7 节”“写作提要”“质量检查”“下一步”，禁止输出 `§7`、`Stage 7`、`Phase 7`、`SSOT` 等内部编号或工程缩写。文件名可保留 `写作Brief_第007节.md`，但解释文字不得写成“继续 §7 Brief”。

## 安全边界与按需引用

- 运行时契约总**引用索引**：先以 `references/runtime-contract-index.md` 定位启动硬门禁、工作流、输出健康和发布隔离协议，再按当前阶段读取其中指向的细分文件；普通业务路由不预读全部协议。
- 交互底层始终保存稳定数字，宿主支持时优先渲染 host_select；具体遵循宿主选择器适配协议。不得直接调用原始 AskUserQuestion；出现 `host_select_failed` 时立即回落到同一组数字候选，不改变选项语义。
- 每次调用都要给用户中文可见回复；不得暴露内部调度、私有模块或原始工具长输出。写入 canonical 资产前，先由 `story-workflow` 的 canonical write protocol 接管。
- 禁止使用 Write/Edit 直接修改 `追踪/workflow/current-task.json`、`tasks/<workflow_id>/task.json`、任务族或任务索引；状态异常必须调用状态机或阶段控制器的受控命令。私有短篇 result packet 的 `owner_module` 必须与当前 stage execution 一致，公开 owner 不得代签私有阶段。
- 短篇机器门只运行 `short-section-machine-gate.js`；短篇故事质量门只运行 `short-section-quality-gate.js`。不得拆开运行内部检查器、读取实现源码、手写回执或临时拼接质量门。
- 长篇当前章节只读取状态机注入的章节最小上下文包；正文验收先运行 `long-chapter-machine-gate.js`，通过后运行 `long-chapter-quality-gate.js`。不得把总纲、卷纲、细纲、全量追踪和历史章节一次性塞入会话；补字/扩写细节不得默认修真，必须服从本书题材与设定。
- 长篇扩容必须进入内部扩容事务协议，先做扩容影响分析，再生成后移映射并补新增缺口；不得直接改写原章节。
- 首屏、任务收件箱、runner、事务、完成证据：读取 `references/internal-skills/story-workflow/SKILL.md`，再只加载其当前阶段指定的协议；完整的 task inbox、短回复、数字候选、状态机与恢复规则由 `task-inbox-protocol.md` 按阶段提供。
- 输出健康和污染恢复：仅当准备长回复、命中污染或恢复时读取 `references/internal-skills/story-workflow/references/output-safety-contract.md`。
- 内部记忆模块：仅由 `story-workflow` 或 runner 按当前阶段读取 `references/internal-skills/story-memory/SKILL.md`；用户不得直接调用 `story-memory`，legacy 记忆迁移只走显式 `memory-migrate.js` 命令。
- 专业写作、拆文、审阅、去 AI 味、扫榜、导入和封面：仅在 router 选中 owner 后读取 `references/internal-skills/<module>/SKILL.md`。

新增长规则应放入当前阶段的 workflow reference 或目标模块 reference，避免顶层入口继续膨胀。

## 可见回复前置健康自检

router 直接回复用户的可见长回复必须先做可见回复前置健康自检：候选回复写盘前先查 `internal-workflow-narration` / `encoded-gibberish-blob` / `user-facing-jargon-leak` / `domain-token-flood`；命中时记为污染段，证据只给文件路径/行号，并以 `污染段#N` 标记；命中 `blocked_model_degradation` 时调用 `node scripts/blocked-recovery-template.js --status blocked_model_degradation` 短模板。前置自检与源污染隔离同义：发现旧报告或正文里残留重复填充时，先把污染起点到文件尾部标记为 `polluted_source_segment` 并做污染源隔离，从污染段之后的内容不得作为事实依据，也不得把污染短语复述为标题或“核心情节”。完整门禁见 `references/internal-skills/story-workflow/references/output-safety-contract.md`。
