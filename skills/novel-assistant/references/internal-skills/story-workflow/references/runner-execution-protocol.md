# Runner Execution Protocol

runner 启动阶段后必须固定保存该次执行的 `workflow_id + task_dir + stage_id + run_id`。heartbeat、runner lease 刷新/释放和 result application 只按这组执行上下文读取 `tasks/<workflow_id>/task.json`；不得通过 `current-task.json` 重新推断任务。UI 焦点切换不影响原 runner 的合法 heartbeat、release 或 result packet；若调用者显式传入的 workflow 参数与 packet 的 `workflow_id` 冲突，则 fail closed。

此协议在生命周期推进、runner 执行、agent 分派、工具退化处理、授权控制、压缩交接与成本治理时按需读取。以下条款从 story-workflow 完整迁移。

进入已确认阶段前，宿主优先按本协议调用 `node scripts/workflow-runner.js once --project-root <book-root> --adapter <claude-code|codex|zcode> --json`；runner 只执行状态机允许的阶段，不替代专业模块。

## Execution Boundary / 执行边界

`execution_mode` 仍然只表示菜单候选的执行方式，例如 `exact_selected_option` 或 `continue_current_stage`。不要把它当成宿主能力。

宿主能力由 `host_execution_mode` 表示：

- `managed_runner`：由 `workflow-runner.js` 启动并持有子进程。本模式才可以宣称进程存活检测、流式健康监控、可中止执行、托管运行或无人值守。
- `cooperative_interactive`：用户在 Claude Code / Codex / ZCode 现有交互会话中直接调用 `/novel-assistant`。本模式只能记录断点、result packet、任务状态和成本估算；不得宣称 runner 级流式早停、进程控制或精确 token 账单。

Claude Code、Codex CLI、Codex Desktop 和 ZCode 共用可迁移命令协议：所有返回给宿主的阶段命令使用 `--project-root .`，`stage_execution.execution_workdir=.` 表示当前书籍根。外部自动化仍可向脚本传绝对路径，但状态机不得把绝对书籍路径固化进任务回执、恢复命令或记忆。`resume_running_stage` 的优先级高于已经 resolved 的旧菜单；宿主收到后只恢复当前阶段，不重复确认。读取阶段包必须执行 `context_read_command`，不得让模型复制长 `packet_md` 路径。

`resume_running_stage` 同时携带 `completion_required_before_reply=true`。交互宿主必须按 `execution_sequence` 在同一轮执行到阶段完成命令返回；不得在只完成 `write_set` 后提前回复。完成命令返回另一个无需用户确认的 `resume_running_stage` 时，继续内部修复并重跑，最多两次；返回需要创作取舍的 `workflow_choice_required` 时才显示最多四项数字菜单。一次最小宿主重试仍失败或重试预算耗尽时，保存最后可信断点并显示恢复菜单。

宿主工具参数在命令启动前损坏时，runner/交互宿主记录 `host_tool_call_malformed` 并以最小参数重试一次。只有命令已经启动且 stderr 指向真实脚本文件与行号，才归类为 `script_syntax_error`；业务阻断 JSON 不能显示成控制台 Error。

可见文案必须使用 `协作模式` / `托管运行` 区分两类能力。成本来源必须使用 `宿主实测`、`代理估算`、`不可用` 三类标签；`estimated` 只能展示为 `代理估算`，不得写成实测。

## Opt-in Persistent Supervisor / 可选持久督导器

`workflow-supervisor.js` 是 runner 之上的可选长期运行层，不是第二套状态机，也不会替用户做选择。它每次只委托一个既有的 `workflow-runner.js once`，将状态写入 `追踪/workflow/supervisor-state.json`，将事件追加到 `追踪/workflow/supervisor-events.jsonl`。因此进程重启后会复用已有 result packet 和 workflow checkpoint，而不是重跑已完成阶段。

```bash
# 一次：执行或复用一个已确认阶段，然后停靠
node scripts/workflow-supervisor.js once \
  --project-root <book-root> --adapter claude-code \
  --max-budget-usd <per-stage-cap> --json

# 长期：仅在显式预算和运行时间边界内继续安全阶段
node scripts/workflow-supervisor.js watch \
  --project-root <book-root> --adapter claude-code \
  --max-runtime-minutes 60 --max-cycles 8 \
  --max-budget-usd <per-stage-cap> --max-total-budget-usd <aggregate-cap> --json
```

规则：

- 仅 `watch` + 明确收费 adapter 时，同时要求单阶段上限和总预算上限；没有预算时在启动前停在 `stopped_budget_required`，绝不尝试调用宿主。
- 每个 cycle 预留单阶段预算，总预留达到总预算时停在 `stopped_budget_exhausted`。不会因跨进程重试而重置总上限。
- 只要 runner 返回 `needs_confirmation`、`needs_selection`、`adapter_required`、provider/认证问题、质量门/事务阻断或没有活跃任务，就立即停靠并记录原因；不得自动挑选编号、迁移项目、覆盖正文或绕过章节事务。
- `watch` 受 `max_runtime_minutes` 与 `max_cycles` 双重约束。SIGINT/SIGTERM 只请求干净停靠；不修改 Claude、Codex 或 ZCode 的权限、登录或配置文件。
- 同一书目只能有一个存活 supervisor lease。只读审阅可由普通 workflow/runner 并发，但写作与结构修改仍受既有书级、章节级事务租约保护。

## Workflow Lifecycle / 任务生命周期

任何针对某一章节、某一范围或某一全局目标的用户需求，都必须被视为一个有生命周期的 workflow，而不是一次性回复。生命周期字段写入 `tasks/<workflow_id>/task.json` 的 `lifecycle`，至少包含 `status`、`started_at`、`updated_at`、`user_goal`、`scope`。

生命周期状态：

- `active`：当前正在执行或等待用户选择的流程。
- `stage_completed` / `awaiting_next`：当前阶段完成，但整条流程仍有剩余阶段或推荐下一步。
- `completed`：整条流程收束完成，已写 closure 和推荐下一步。
- `paused`：用户主动暂停或保存断点。
- `focus_paused`：用户切换到另一个明确目标，旧流程保留完整断点并退出当前焦点。
- `superseded`：仅当用户明确终止、放弃或用新任务永久替代旧任务时使用。
- `blocked`：污染、上下文冲突、权限、写入、验证或 provider 错误阻塞。

当用户在一个 active workflow 中输入明显的新行为，例如正在审阅第 12 章时输入“写第 13 章”、正在回炉时输入“先拆这本书”、正在拆文时输入“开始短篇写作”，不得把新输入硬绑定到旧 `pending_action`。必须调用：

```bash
node scripts/workflow-state-machine.js switch-intent --project-root <book-root> --workflow-type <new-type> --scope <scope> --user-goal <goal> --reason manual_new_goal --json
```

该命令只把旧焦点写回 `追踪/workflow/tasks/<workflow_id>/task.json`，标记为可恢复的 `paused`，并把新流程设为 current task；不得默认归档或 supersede。恢复某个任务使用：

```bash
node scripts/workflow-state-machine.js activate --project-root <book-root> --workflow-id <workflow_id> --json
```

`activate` 会把当前焦点安全停靠，再恢复目标任务的阶段、result packet、pending action 和记忆绑定。一个书目允许多个未完成任务并存，但同一时刻只有一个 current focus。

每个流程结束时必须有 closure：专业模块 result packet 的最后阶段应提供 `next_recommendation`，状态机会把它写入完成后的 `pending_action`。如果用户只选择了“A 级修复”“当前步骤”“当前章节”，完成后必须继续展示剩余阶段或推荐项；不得把阶段完成描述成整条 workflow 完成。

## Production Unit Lifecycle / 创作单元生命周期

全局 workflow 只抽象“一个生产单元必须有边界、执行、验证、状态更新和交接”的方法，不把某个模块的具体写法硬套到所有模块。短篇这次验证出的“Brief -> 草稿 -> 质量门 -> 并入正文 -> 下一节建议”属于短篇实现；长篇、审阅、拆文、导入、去 AI 味必须用各自的专业产物和质量规则实现同一类生命周期。

| workflow | unit_type | brief_or_contract | draft_or_execute | machine_quality_gate | quality_gate | state_integration | handoff_and_next |
|---|---|---|---|---|---|---|---|
| 长篇写作 | `chapter` | 章节契约 / 上下文包 | 正文写作或回炉执行 | 单章机器门：字数、路径、标点、AI 句式、工程词、退化/复读、正文门禁 | 剧情漂移门 / 正文质量门：剧情漂移、承诺、人物、伏笔、看点 | 状态变更账本 / schema / 伏笔角色状态 | 章节交接包 / 下一章建议 |
| 短篇写作 | `section` | 素材卡、设定、小节大纲、单节 Brief | 单节正文 | 单节机器门：AI 句式、工程词、标点、退化/复读、格式 | 小节质量门：钩子、人物动机、现实因果、情绪爆点 | 正文索引、素材血缘、风格记忆 | 下一节建议 / 全文收束 |
| 审阅修复 | `range_or_fix_item` | 范围锁定、修复方案、执行范围 | 修复执行 | 修复结果机器复扫：污染、格式、目标文件存在 | recheck / 补审 | review-state / 修复台账 | closure / 剩余修复项 |
| 拆文/导入 | `workflow_batch` | 来源前置检查 / 批次计划 | 批次提取或导入 | 来源锚定 / 文件存在 / 批次覆盖 / 输出退化门 | 来源核验 / 质量对齐 | 聚合矩阵 / 章节索引 | 最终报告 / 可吸收技巧 |

全局执行规则：

- 正文或报告“已生成”不等于单元完成；必须有质量门和 handoff。
- 机器可判定问题不得拖到最终总检：AI 句式、工程词、破折号密度、模型复读、文件不存在、字数不达标、正文格式错误必须在当前单元边界进入 `machine_quality_gate`；blocking 未清零时只允许修当前单元并复扫。
- `machine_quality_gate` 是真实分支门，不是普通线性阶段。result packet 命中 `step_status=blocked|failed`、`machine_gate_result=blocking` 或 `blocking_findings[]` 时，状态机只能进入当前单元 repair loop，且不得把机器门记为 completed；result packet 明确通过时才跳过 repair loop，进入剧情/人工质量门。
- `quality_gate` 后必须按 [review-escalation-policy.md](review-escalation-policy.md) 运行或等价执行 `node scripts/review-escalation-policy.js --json`。普通章节/小节不默认多角色阅读；每 5 个生产单元轻量双角色复核；高潮、反转、卷首卷尾、跨卷、扩容、发布、故事价值门失败或用户反馈“不好看/人物不像人/剧情不合理/没爽点”时升级完整审查。
- 如果 `machine_quality_gate` blocking，`review-escalation-policy.js` 必须返回 `next_action=repair_current_unit`；不得把脏稿交给多角色审阅，也不得为了“保险”每章完整审查。
- 用户选择“只写当前章/节/修复项”时，完成后停在 `handoff_and_next`，展示剩余流程，不自动推进。
- 用户反馈影响上游设定、总纲、卷纲、细纲或素材卡时，先回到 `brief_or_contract` 修正上游，再进入下一次 `draft_or_execute`。
- 模型空转、输出污染、路径找不到、写入失败时，只阻断当前单元，保留最后可信产物和 `last_trusted_artifact`，不得把坏输出并入正文或报告。
- 可见回复污染同样是单元阻断：`internal-workflow-narration` 表示把“我先读取/并行读取/最小必要回复”等内部过程当成回复；`encoded-gibberish-blob` 表示编码/乱码块泄露。命中后必须丢弃该可见草稿，改写成“当前判断 + 阶段位置 + 下一步候选”，不得继续顺着污染文本执行。
- 具体质量门由 L3 模块定义：短篇检查节内钩子、人物动机、现实因果、情绪爆点和小节衔接；长篇检查章节承诺、人物持续发展、伏笔/状态/设定连续性、跨章交接和本章看点价值；审阅检查范围 gap、证据、分类和复检；拆文检查 source-grounding、批次覆盖和可吸收技巧。

## 短篇可见工作流

短篇写作必须呈现为一个可恢复的可见流程，而不是在素材、设定、大纲、正文和去 AI 味之间跳来跳去。公开构建使用 `story-short-write` 作为 fallback；本地私有构建若检测到 `private-short-extension` 的 `workflow-registry.json`，则由私有模块接管同一条短篇流程。

标准顺序：

```text
脑洞卡池
-> 选卡建独立项目
-> 设定
-> 节奏/爽点套路
-> 小节大纲
-> 总小节/完稿边界锁定
-> 结构变更影响审计
-> 看点价值门
-> 单节 Brief
-> 写本节
-> 单节机器门
-> 当前节修订循环（仅 blocking 时）
-> 短篇质量门
-> 候选稿对比
-> 采用锚点
-> 下一节 Brief 或全篇组装
-> 短篇去 AI
-> 最终检查与导出
```

`总小节/完稿边界锁定` 必须写清楚总小节数、目标字数带、发布形态、每节功能、当前节序号、剩余小节清单和全篇完成分支。用户要求扩容、插节、合并、删节、调换小节顺序时，必须先回到这个阶段，更新 `小节大纲.md`、已采用锚点、后续 Brief 和缺节检查，再继续正文。不能在旧总节数下硬写。

`结构变更影响审计` 必须在总小节/完稿边界锁定之后执行。它检查扩容、缩容、插节、合并、删节、重排对以下资产的影响：

- 素材卡/脑洞卡：标题承诺、核心爽点、素材血缘是否仍成立。
- `设定.md`：人物性别/称谓/关系、目标、动机、核心反转、结尾兑现是否需要改。
- 节奏/爽点套路：主节奏、辅节奏、反转方式、兑现方式是否因节数变化失衡。
- `小节大纲.md`：节序、每节功能、爆点分布、黄金阅读地图、节尾钩子是否连续。
- `写作Brief_第N节.md`：哪些 Brief 可保留、哪些因节序/功能变化必须重算。
- 已采用锚点/正文小节：哪些正文可复用，哪些需复检，哪些因因果断裂失效。
- 候选稿/人工稿：是否仍对应当前节序和设定。
- 正文索引/发布合并稿：是否有缺节、重复节、旧编号、旧结尾或旧承接。

审计结果必须输出 `保留 / 失效 / 重算 / 复检` 四类清单。只要存在未处理的失效项，不得进入看点价值门或下一节 Brief。

`采用锚点` 后有两个合法方向：如果还有未写小节，进入 `下一节 Brief`；如果计划小节全部采用，进入 `全篇组装`，检查缺节、节序、节尾承接、人物称谓一致性和发布合并稿，再进入短篇去 AI 和最终导出。

每个阶段都允许自由反馈：`pending_action.free_text_enabled=true` 是硬约束，不是 UI 装饰。用户可以在任何阶段 chat、提交人工修改、粘贴重写段落、要求重新规划、改变题材方向或指出“不好看/人物不像人/逻辑不成立”。L2 必须先分类这类输入：

- 当前阶段修订：只改当前素材卡、设定段、小节大纲、Brief 或正文小节。
- 上游设定/大纲/Brief 回写：用户反馈影响人物动机、因果渠道、核心反转、标题承诺、节奏套路或结尾兑现时，先回写上游，再继续。
- 规划回写被接受后必须建立持久 `feedback_revision_queue`：按受影响小节逐一重建 Brief、复检正文并重新采用。队列未清空时不得生成计划外新小节，队列完成后才重新合稿。
- 候选稿对比：用户提交人工稿、Claude Code 稿或 ZCode 稿时，先进入候选对比，不直接覆盖 canonical 正文。
- 新目标切换：用户明确开启新任务时，使用 `switch-intent` 归档旧 workflow，再建立新 workflow。

数字候选只是快捷键，不是强迫用户只能按钮式推进。短篇每个可见阶段都要显示当前位置、当前产物、通过标准、下一步候选和自由反馈出口。

## 审阅自动 agent 分派协议

范围审阅、批次审阅、全书审阅、跨卷审阅和大批量修复复检属于应该使用 agent 加速的任务。用户只需要说“审阅 1-200”“继续审阅 1-50”“只看第 50 章高风险点”；`story-workflow` 负责把父范围、当前批次、风险信号和可用 agent 交给 `story-review`。不要把 full/lean 暴露成用户必须理解的选择。

进入 `story-review` 前，先生成或读取 agent 调度计划：

```bash
node scripts/review-agent-dispatch-plan.js --scope <parent_scope> --batch <batch_scope> --risk <risk-tags> --existing-reports <n> --agents-available <a,b,c> --json
```

工作流字段必须保留：

- `parent_scope`：用户真正要求的审阅范围，例如 `1-200`。临时缩小到 `1-50` 或第 50 章时，不得丢失父任务。
- `batch_scope`：当前持久化叙事批次，例如 `1-43`；它由章节证据、卷/篇章边界、风险密度和运行时预算共同决定。
- `execution_plan.mode`：`agent_dispatch` 表示自动分派 reviewer agents；`solo_fallback` 表示 agent 不可用时自动降级。
- `existing_reports_policy`：旧报告只能作为证据输入和 cross-check，策略为 `use_as_evidence_then_verify`；不得把旧报告当作本轮结论跳过审阅。

默认分派维度：

- `story-architect` 审结构、剧情控制、钩子回收、卷目标和高潮承诺。
- `character-designer` 审人物、关系、动机、称谓、出场密度和角色持续发展。
- `narrative-writer` 审 AI 写作指纹、文字节奏、对话质量、解释腔和标点/短段碎片化。
- `consistency-checker` 审一致性、设定、时间线、能力/成长规则、跨批边界和 gap 风险。

可见候选必须是任务动作，而不是内部策略：

```text
1. 继续审阅当前叙事批次（推荐）
   自动分派 reviewer agent；父范围 1-200 保留，批次边界以已持久化计划为准。

2. 临时缩小本批高风险点
   只窄化当前批次，不丢失父任务 1-200。

3. 停止并保存断点
```

如果 agent 缺失、部署过旧、当前处于子 agent 内、spawn 失败或宿主没有 agent 能力，自动 `solo_fallback`，把原因写入任务状态和可见摘要；不要停下来问用户“full 还是 lean”。用户显式要求 `solo/full/lean` 时可以作为 override，但默认流程必须自动规划。

范围审阅必须用 `workflow-review-batches.js` 维护父范围和批次状态。`1-200` 按已持久化审阅计划切分：优先卷/篇章边界，按风险密度和运行时预算收缩或扩展，未知宿主预算使用保守降级。每批拥有独立 result packet，边界章节只作为相邻上下文而不重复主覆盖。只有所有批次完成，父 `evidence_scan` 才能完成并进入 `classify_findings`；批次中断从 `next_batch_id` 恢复，不重排已完成批次，也不能用边界抽样冒充整批完成。

## 交互恢复协议

`story-workflow` 是交互状态的来源，但不是 UI 控件实现者。交互体验采用 **host_select 优先、text_numbers 兜底**：宿主/前端/runner 支持稳定选择器时，可以把候选渲染成上下方向键列表；宿主选择器不可用或失败时，立即降级为数字文本候选。无论哪种展示方式，状态都必须落到 durable task 的 `pending_action`。

```json
{
  "type": "option_choice",
  "workflow_id": "wf-20260627-001",
  "book_root": "/abs/path/to/book",
  "created_at": "2026-06-27T10:00:00+08:00",
  "expires_at": "2026-06-27T10:30:00+08:00",
  "visible_choice_hash": "sha256-of-visible-question-and-options",
  "expected_reply_set": ["1", "2", "继续当前阶段", "返回阶段导航"],
  "interaction_renderer": "host_select_preferred",
  "render_mode": "text_numbers",
  "fallback": "text_numbers",
  "page_size": 4,
  "page": 1,
  "free_text_enabled": true,
  "options": [
    {"number": 1, "label": "继续当前阶段", "action": "continue_stage"},
    {"number": 2, "label": "返回阶段导航", "action": "stage_nav"}
  ]
}
```

宿主选择器适配规则：

- `interaction_renderer` 只描述渲染偏好，不是让模型直接调用原始 AskUserQuestion。不得直接调用原始 AskUserQuestion、TaskCreate、TaskUpdate、TodoWrite 或其他宿主任务工具；小说 workflow 已有唯一任务账本，禁止复制第二套任务状态。当前宿主未提供 `Glob` 时不得调用或重试 `Glob`，文件定位只使用阶段上下文包或已验证的一行脚本。

短篇 `section_machine_gate` 不得由主会话分别调用五个检查器、手写或覆盖 result packet。统一运行 `node scripts/short-section-machine-gate.js --project-root <book-root> --workflow-id <workflow_id> --apply --json`；该命令一次完成当前节检查、紧凑证据落盘、owner 绑定、result packet 生成与状态推进。返回 `apply_blocked` 时只处理其结构化原因，不再手工 Edit `task.json`。

短篇机器门通过后，状态机必须为 `quality_gate` 注入最小 `stage_context_packet` 和唯一 `execution_command`。主会话只读取该 packet，完成角色、因果、标题承诺、能动性、情感、钩子、吸引力、连续性、防漂移九项判断，然后运行 `short-section-quality-gate.js`。禁止搜索质量门实现、读取 workflow/private skill 全文、枚举或执行 `scripts/lib/`、调用 runner `--help`、手写 result packet；这些都属于工具/上下文污染型退化。

短篇 Brief 和采用锚点也必须消费状态机注入的 packet/command：Brief 用 `short-section-brief-finalize.js`，采用用 `short-section-accept-finalize.js`。长篇 `chapter_brief / prose / prose_acceptance / chapter_commit` 由 `long-stage-context-packet` 生成章节最小包；正文验收只运行 `long-chapter-machine-gate.js` 和 `long-chapter-quality-gate.js`。不得因长篇资产较多而扩大为全书读取。

短篇反馈回执必须携带当前 `pending_feedback.feedback_id`。`feedback_impact_sync` 与 `feedback_apply_patch` 不得复用同名旧回执；feedback_id 不匹配时重新生成当前回执。明确的 AI 味、标点、句式、措辞反馈由状态机直接进入当前节修订，不再创建反馈分析确认轮。

短篇整篇回炉不得只显示“继续当前阶段”。状态机必须把一个回炉 workflow 投影成可见的阶段组和逐节队列：先显示各组覆盖范围、剧情目标、完成条件，再显示当前小节、后续小节及最近可信检查点。用户选择继续时只推进当前小节；当前小节采用后保存 commit/checkpoint 并自动移动游标。用户选择回炉或直接输入 Chat 意见时，先做反馈影响判断，表达层只修当前正文，剧情/人物/因果/承接层先回写上游规划并重建受影响队列；已经采用且未受影响的小节和尚未开始的后续项不得丢失。
- runner 若支持上下方向键选择，必须从 `pending_action.options` 构造参数；不能让专业模块临时拼自己的选择器。
- 选择器调用失败、参数不合法、宿主不支持或用户切换到纯 CLI 时，写入 `host_select_failed` 和 `interaction_degraded_to_text_numbers`，然后按同一组选项输出数字文本。
- 降级不是失败结束；它只是渲染层降级，用户输入 `1/2/3/4` 后仍按同一个 `pending_action` 执行。

短回复只能绑定到最新可见候选。执行 `1/2/继续/下一步/e/E` 前必须校验：

- `book_root` 等于当前书目项目根目录，否则记录 `pending_action_project_mismatch` 并重新显示当前项目候选。
- 当前可见候选重新计算出的 hash 等于 `visible_choice_hash`，否则记录 `pending_action_choice_hash_mismatch` 并清理旧候选。
- 当前时间未超过 `expires_at`，否则记录 `pending_action_expired`，不得执行旧 action。
- 用户输入属于 `expected_reply_set`，否则按 `free_text_enabled` 进入普通补充说明。

编号选择执行后必须有可见停靠：用户输入 `1/2/3/4` 后，如果 action 只是读取文件、刷新索引、跳过前置检查、进入某一批审阅或准备下一阶段，也必须在动作结束时给出正式中文回复，不得只读文件后依赖 recap 或宿主 UI 状态。可见回复至少包含：

```text
本轮已执行：……
当前停靠位置：……
下一步可选：
1. ……
2. ……
也可以直接输入你的要求。
```

如果用户随后问“没有继续吗 / 我要如何操作 / 现在卡在哪”，说明上一轮违反了停靠协议；必须先读取焦点 durable task 的 `pending_action`，补发当前停靠位置和可执行候选，不得重新扫描全文或凭聊天记忆猜。

前端/runner 读取该对象后可以恢复上下方向键选择、分页、刷新后继续显示最新候选。宿主选择器不可用或 schema 校验失败时，runner 必须降级到数字文本候选，并记录 `interaction_degraded_to_text_numbers`；不得让 `Invalid tool parameters` 出现在用户可见回复里。用户不选候选而直接输入自然语言时，按 `free_text_enabled=true` 走普通聊天补充，不强行判错。

可见回复不得把 pending_action 原始 JSON/YAML 直接作为可见回复。工作流大脑必须把结构化状态写入 durable task 的 `pending_action`，对用户只显示“问题 + 1-4 个编号候选 + 回复数字继续”。`safe_default` 必须保存断点、等待用户继续或取消高风险动作；不得把默认值设成继续写作、默认修复、默认迁移、默认覆盖或“选项 1”。推荐项只能影响排序和文案，不得变成无人确认时的自动执行。

不要输出“另开窗口”来处理普通候选分流；使用“稍后处理”“保留为后续任务”“另建任务断点”。只有协作环境更新导致 agent/rule 重载且必须重启时，才提示用户新开 Claude 会话。

## 交互选项污染门禁

`next_candidates`、阶段导航选项和交互式确认题属于可见输出。工作流大脑在生成选项前必须先压缩候选，不得把专业模块返回的长报告、修复清单、污染段或章节正文原样塞进选项描述。

- 单个选项描述不得超过 120 个中文字符；超过时改为短标题 + 报告路径。
- 选项总文本超过 800 中文字符，或任一候选来自长报告/修复方案摘要时，先写入 `追踪/输出门禁/.option_payload_draft_{YYYYMMDD_HHMMSS}.md`，运行 `node scripts/output-pollution-check.js --learn --project-root <book-root> <draft-file>`。
- `option_payload_draft` 命中污染时，不得展示交互选择器；丢弃污染候选，回到最后可信任务状态，输出 `paused_after_output_pollution` 和 2-4 个干净意图式下一步候选。
- durable task 的 `next_candidates` 只保存短候选，不保存长报告正文。
- 最终可见回复也属于门禁对象。即使报告文件已经通过 `output-pollution-check.js`，只要最后要发给用户的摘要、下一步候选、recap 风格状态句或自由输入提示中包含领域术语循环、`SSOT` 工程缩写、阶段标签循环或已学习污染词组，也必须先写入 `追踪/输出门禁/.visible_reply_draft_{YYYYMMDD_HHMMSS}.md` 并复扫；命中污染时禁止发送原回复。
- visible_reply_draft 命中污染后的干净候选模板只能保留动作意图：`1. 修复 S1 伏笔异常`、`2. 继续写下一章`、`3. 查看完整报告`、`4. 暂停并保存断点`，再附一句“也可以直接输入你的意见、补充要求或新的目标”。不得把污染术语原样塞回候选描述。
- **前置自检比落盘门禁更早**：如果在 thinking、阶段说明、任务标题或选项草稿中已经出现同一领域短语连续 3 次以上，或准备把源文件里的重复污染短语当作“回炉目标名”继续复述，不得再写 visible_reply_draft 试图润色。立即进入 `blocked_model_degradation`，使用 `blocked-recovery-template.js` 的短模板，并把源污染称为 `污染段#N`，只保留路径/行号证据。
- **污染源隔离**：读取旧报告、正文、细纲、审查清单时，若发现重复填充，后续所有候选、标题、摘要和 pending_action 都只能引用 `污染段#N`，不得复述原污染短语。污染段不是事实源，不能作为回炉方案内容，只能作为“需要回退/重写”的证据。
- recap 或状态摘要不得写“default is writing chapter ...”这类自动默认推进句；只能写“awaiting user choice / 等待用户选择”。推荐项可以排序靠前，但不是 safe_default。

### 早停省 token 原则

污染治理必须前置，不得等长报告、全书审阅或多 agent 执行消耗大量 token 后才发现：

- **生成前探针**：长输出、全局任务、多 agent prompt、批量审阅、批量修复和正文生产前，先读取 `追踪/schema/output-pollution-rules.jsonl`、当前任务状态和最近一次阻断记录，把已学习污染短语加入本轮前置阻断词表。
- **生成中早停**：一旦 thinking/阶段摘要/候选描述/agent handoff 出现术语循环、同词洪泛、工具转录混入、provider artifact、`Invalid tool parameters` 连续失败或长时间无新增可信产物，立即停止当前路线，不继续等待模型“自己恢复”。
- **小样本验证**：全书级任务先生成一个小批次计划或 1 个 agent handoff 样本并过门禁，再放大到多 agent / 多批次。样本失败时不得启动剩余 agent。
- **失败预算**：同一污染类型最多重试一次。重试仍失败时进入 blocked 模板，保存断点和证据，不再用“继续”消耗 token。

### 阻断态固定回复

命中 `blocked_model_degradation`、`blocked_tool_command_contaminated`、`blocked_repeated_tool_failure` 或 `blocked_provider_sensitive` 后，禁止自由生成 blocked 状态长回复，必须使用确定性模板：

```bash
node scripts/blocked-recovery-template.js --status blocked_model_degradation
```

模板输出后仍要按可见回复污染门禁复扫。若模板通过，直接展示模板；若模板也失败，说明脚本或规则损坏，停止并只写恢复记录。不得在 blocked 回复里复述污染片段、长报告、工具转录或领域术语循环；不得把“front-stop 触发”后面的解释写成超过 8 行的自由文本。

## 工具调用退化门禁

`tool_call_degradation_guard` 处理工具调用本身的污染和空转，不等同于正文污染。可疑 Bash/Agent/Write/Edit 前，先把即将执行的 payload 送入；全书审阅、批量修复、迁移、拆文聚合、长命令和多 agent 调度必须使用严格模式：

```bash
node scripts/tool-call-degradation-check.js --kind bash --json < payload.txt
node scripts/tool-call-degradation-check.js --kind bash --strict --json < payload.txt
```

- 如果 Bash 命令、Agent prompt、Write/Edit payload 中混入 `+deployed_at`、`@@`、`---/+++`、`⎿`、`Thought for`、`Added/removed lines`、Markdown 表格、diff hunk 或上一条工具输出，记录 `blocked_tool_command_contaminated`。不得把 diff hunk 或工具输出拼进 Bash 命令；不得把工具输出拼进 Bash 命令；不得执行该命令。
- **分拆优先，不是拒绝任务**：高风险场景禁止以自由拼接形态直接执行多行 Bash、`python3 -c`、`node -e`、heredoc、长内联脚本和循环拼接命令；命中时记录 `needs_tool_task_decomposition`，动作是 `decompose_and_execute_scripted_steps`。这不是拒绝任务，而是把任务拆成可验证步骤后继续执行。必须运行 `node scripts/tool-task-decompose-plan.js --kind bash --payload-file <payload> --project-root <book-root> --write --json` 生成分拆计划。若计划返回 `safeCommands[]`，优先执行其中的一行脚本命令，例如正文统计用 `chapter-text-stats.js`，拆文章节摘要硬质量检查用 `stage2-summary-quality-check.js`，当前进度问答用 `story-progress-status.js`；没有 safeCommands 时再改用已有 `scripts/*`，或先创建小脚本文件，再以一行命令调用脚本。
- 同一 Bash/Agent/Write/Edit 失败两次，或连续出现 `Invalid tool parameters`，记录 `blocked_repeated_tool_failure`。不得继续换 prompt 撞 Agent，不得把“可能 prompt 太长”当作继续调用 Agent 的理由；必须退回文件化任务计划，缩小范围或改用确定性脚本。
- 供应商 API 错误、权限错误、schema 错误、路径错误必须先分类，再决定是否恢复。未分类前，用户输入“继续”也不能直接恢复原工具调用。
- 可恢复时只允许生成一条更小、更干净的命令；不可恢复时输出最后可信断点、失败命令摘要和下一步候选。
- 工具调用/上下文污染型退化属于 skill 自身边界问题，必须在工具调用前阻断；不得把它归因给模型后继续执行。每次 Bash/Agent/Write/Edit 前都要确认 payload 来自干净意图、脚本模板或重读后的目标文件，不来自聊天转录、上一次工具输出或污染报告。

### 工具调用自愈协议

命中 `blocked_tool_command_contaminated` 后，不能只告诉用户“已拦截”，必须自动进入自愈：

1. **冻结**：立即停止原工具调用，不执行、不复制、不改写污染 payload。
2. **留证**：在项目内创建 `追踪/工具调用恢复/{YYYYMMDD_HHMMSS}/`，写入 `blocked-payload.txt`、`findings.json` 和运行时状态文件 `last-trusted-state`。如果当前不是书目项目，则写到当前目录 `.novel-assistant-recovery/`。
3. **重建/分拆**：从用户意图、`追踪/workflow/current-task.json`、目标文件现状和脚本模板重建干净工具调用。Bash 优先调用已有脚本或绝对路径脚本；需要复杂逻辑时先创建/复用脚本文件，禁止在 Bash 工具里现场拼 `python3 -c`、heredoc 或多行循环。高风险 payload 的正确恢复不是“挡住不做”，而是运行 `tool-task-decompose-plan.js` 生成分拆计划，拆成 `read -> plan -> write/script -> execute -> verify` 可验证步骤；若返回 `safeCommands[]`，执行前先用 `tool-call-degradation-check.js --strict` 复检该一行命令，然后直接执行，任务继续执行。Agent prompt 只给任务目标、输入文件清单、输出路径和禁止项；Write/Edit 必须先重读目标文件，再用最小补丁。
4. **复检**：重建 payload 再跑 `tool-call-degradation-check.js`。通过后才允许执行；仍失败则写 `blocked_repeated_tool_failure`。
5. **续跑**：执行成功后更新 workflow 断点，说明“已从污染调用恢复”，继续原任务的下一步，不要求用户手工输入“继续”。

同一工具、同一动作、同一污染类型只允许自愈重试一次。第二次失败必须停止，输出最后可信断点、污染类型、建议选项，不得空转。

## Claude CLI Recap 边界

Claude CLI 的 `※ recap` 只能作为宿主提示，不是 novel-assistant 的工作流状态。不得把 recap 当作工作流事实源，也不得用 recap 里的行数、字数、破折号数量、章节完成度、下一步描述直接触发阻断、继续任务或质量结论。

当用户引用 recap 或 CLI 自动显示 recap 后继续操作时，workflow 必须回到文件系统权威：先从 `追踪/workflow/current-task.json` 解析焦点，再读取对应 `tasks/<workflow_id>/task.json`、目标正文/短篇文件、质量报告、章节状态和脚本输出。凡涉及进度、落盘状态、质量门禁、行数、字数、破折号数量、章节编号和下一步候选，必须重新读取项目文件或运行确定性脚本确认。

## 无人值守授权预算协议

批量审阅的证据扫描不得由模型拼接 `for`、brace expansion、`cd + grep`、`wc | head` 或逐文件检查命令。统一使用：

```bash
node scripts/review-batch-evidence-scan.js --project-root "/绝对路径/书目" --workflow-id "<workflow-id>" --range 1-50 --write --apply-result --json

范围审阅的 `repair_plan.result.json` 与 `repair_execution_plan.result.json` 是前端/工作台的结构化数据源。前端应直接展示 `outputs.stages`、`outputs.execution_plan`、`target_files`、`expected_changes`、`completion_policy`、`risk_assessment` 与当前 `pending_action.options`；不得从 Claude 对话文本中反向解析计划。
```

需要同时统计题材词、人物名或钩子词时，重复传入 `--query "关键词"`；脚本一次返回紧凑汇总和范围级证据文件。`PreToolUse(Bash)` 的 `safe-bash-guard.js` 对这类已验证单命令显式放行，对复合命令在授权弹窗前拒绝并返回上述替代命令。模型必须自动改写后继续，不向用户请求授权，不缩减原审阅范围。

授权弹窗是 workflow 运行成本的一部分。novel-assistant 的目标不是让用户在长任务里不断点“允许”，而是把可自动执行的工作前置规划、脚本化和批次化。

durable task 的 `runtime_guard` 必须在长任务、全书审阅、拆文、批量修复、迁移、导入、扫榜抓取和短篇素材批量学习前写入：

```json
{
  "authorization_prompt_budget": {
    "startup_bash_prompts": 0,
    "routine_batch_prompts": 0,
    "high_risk_boundary_prompts": 1,
    "permission_prompt_count": 0,
    "on_exceeded": "permission_budget_exceeded"
  }
}
```

执行规则：

1. 启动自检目标是 0 次 Bash 授权。启动阶段优先使用 Read/LS 或 runner 注入的 JSON；不得先用 Bash cat/echo/grep 拼状态。
2. 长任务确认后不得按批次反复授权。用户确认长任务范围后，拆文 Stage 2、全书审阅、批量去 AI、批量回炉和素材学习的普通读写校验，应使用已有脚本或新建脚本后以一行命令调用。
3. 更新写作协作环境属于固定运行时同步动作。已部署项目中，用户确认后只能在书籍根目录逐字调用 `node scripts/novel-assistant-sync-runtime.js --project-root . --json`；脚本自动发现最新本地安装包。不得把尖括号占位符发送给 shell，也不得拆成多条 `mkdir`、`cp`、`rsync`、`chmod`、`cat`、heredoc 或循环命令。该脚本不迁移正文、大纲、细纲、设定或追踪创作资产。
4. 同一 workflow 授权弹窗超过预算时，立即写入 `permission_budget_exceeded`，停止散装 Bash/Agent/Write/Edit 调用，改为脚本化一行命令或 runner 后台任务；不得继续让用户逐条点允许。
5. 允许请求授权的边界只包括：删除/覆盖用户正文或大纲、写入项目外路径、sudo/chmod/chown、安装依赖、git push、访问登录态或付费源、执行未验证下载代码、迁移目录结构、或其他不可自动回滚动作。
6. 常规状态读取、章节计数、摘要质量检查、进度探测、污染门禁、token 成本摘要、报告写入到 `追踪/`、短篇卡池落盘和 workflow 账本更新，不应逐项请求用户授权；如果宿主策略仍弹窗，先把多个动作合并成一个固定脚本入口。
7. 权限预算超限不是任务失败，也不是拒绝任务。正确恢复是生成 `tool-task-decompose-plan.js` 分拆计划，复用 `safeCommands[]` 或创建小脚本，写入断点后继续无人值守执行。

### 授权友好搜索协议

全文检索、章节内检索、伏笔词检索、人物名检索、卷内命中列表这类常规读操作，目标是 0 次授权弹窗。不得生成 `cd <目录> && grep ... 2>/dev/null | head`、`cd <目录>; rg ... | head`、`grep ... 相对glob 2>/dev/null` 这类命令；它们容易触发 Claude Code 的路径解析 bypass 授权，尤其是同时包含 `cd`、重定向和管道时。

默认替代方案：

```bash
node scripts/safe-text-search.js --root "/绝对路径/正文/第11卷" --query "关键词" --glob "*.md" --mode files --limit 20 --json
node scripts/safe-text-search.js --root "/绝对路径/正文/第11卷" --query "关键词" --glob "*.md" --mode lines --limit 50 --json
```

如果项目缺少脚本，才退回一行 `rg`，并且必须是绝对路径、无 cd、无重定向、无管道：

```bash
rg -l --fixed-strings "关键词" "/绝对路径/正文/第11卷" --glob "*.md"
rg -n --fixed-strings "关键词" "/绝对路径/正文/第11卷" --glob "*.md"
```

缺目录不准用 `2>/dev/null` 隐藏；先用单独状态脚本或 `safe-text-search.js` 的 `missing_root` 返回处理。命中授权风险时，这不是跳过搜索，也不是让用户点允许，而是自动转为 `safe-text-search.js` 或 `tool-task-decompose-plan.js` 的 `safeCommands[]` 后继续。

### 授权友好章节统计协议

按卷统计章节、统计正文数量、排除 _原稿_ / 备份稿、检查卷内缺章这类常规只读动作，目标是 0 次授权弹窗。不得生成 `cd <书目录> && for v in ...; do ls 正文/$v/第*.md 2>/dev/null | grep -v "_原稿_" | wc -l | tr -d ...; done` 这类命令；不得生成 `cd ... for ... ls ... grep ... wc` 的自由拼接形态。它们容易触发 `Contains simple_expansion`、路径解析授权或 shell 展开确认。

默认替代方案：

```bash
node scripts/chapter-volume-count.js --project-root "/绝对路径/书籍项目" --volumes "第1卷,第2卷,第3卷" --exclude "_原稿_" --json
```

如果用户说“统计 1-8 卷”“看每卷多少章”“排除原稿备份”，必须路由到 `chapter-volume-count.js` 或 `tool-task-decompose-plan.js` 的 `chapter_volume_count` safeCommand。缺卷返回 `missing_volume`，不要用 `2>/dev/null` 吞掉。

### 范围优先候选协议

用户明确说了审阅、写作、修复或拆文范围时，可见候选必须把用户范围放在主标题最前面。日期、历史计划名、旧报告名、批次编号只能作为括号里的来源说明或落盘文件名，不得放在候选主语里。

正确：

```text
1. 审阅 1-200 章：完整多视角审查（推荐）
   按叙事边界、风险和运行时预算分批，最后汇总报告。
```

错误：

```text
1. 按 7-07 批计划跑 1-200 full 模式审查
```

如果用户输入 `1-200`、`200-400`、`第1卷`、`第6节` 等范围，`pending_action.options[].target_scope` 必须精确保存该范围；候选文字也必须复述同一范围，不得把日期 `7-07`、旧任务编号或前一轮范围误当成起点。`full 模式` 对用户显示为“完整多视角审查”；内部模式名只允许写入账本。

## 全局 agent 压缩协议

长任务、全局任务和多 agent 任务默认先做预算和压缩，不允许把多个 agent 的完整正文、完整设定、完整审查长报告直接塞回主线程。

适用范围：

- 全书审阅、全书补设定、分类世界设定、势力/场景/法宝/功法/灵兽档案、12 卷卷纲概要、全书回炉复检、全书拆文聚合。
- 任一单步预计读取 30 个以上文件、200 章以上正文、5 个以上设定目录，或预计输出超过 3000 中文字符。

执行规则：

1. **token_estimate**：启动前在 durable task 写入 `token_estimate`，至少包含 `input_files`、`input_chars_estimate`、`output_chars_budget`、`agent_count`、`estimated_unit_window`、`risk_level`。估算粗略即可：中文约 1.5-2 字/token，英文/代码按 4 字符/token；风险高时必须按已持久化计划分批。
2. **默认返回通道风险**：agent 如果没有被明确要求“写文件后只回交接包”，会把最终回复当作交付通道，直接贴完整正文、完整设定或完整审查报告；主线程再综合这些长回复，会造成 token 爆炸、上下文污染和幻觉扩散。因此全局任务必须采用 `write_file_then_handoff`，完整产物必须落盘。
3. **动态 agent_output_budget**：不得写死固定字数。启动时按 `adaptive_budget_policy` 计算 `visible_reply_budget`、`batch_handoff_budget`、`range_summary_budget`：参考任务类型、章节跨度、输入文件数、源文本总量、模型上下文窗口、当前剩余上下文、agent 数量、用户是否要求“全面/快速/只看问题”、输出健康风险和是否需要后续写作继承。预算目标是“足够完整且不把原文搬回主线程”，不是机械截断。
4. **范围分层而不是字数截断**：1-200 章不能压成一个短摘要。1-200 章审阅、拆文、补设定或修复复盘必须先按实际信息密度动态分批生成批次交接包，再生成 `追踪/workflow/range-summary/{workflow_id}/chapters_001-200.md` 或对应审查报告范围级摘要；主线程只返回短结论、路径、剩余风险和下一步。范围级摘要不是事实源，只是导航和综合判断；防跑题必须同时落盘 `detail_matrix_paths`，至少包含剧情承接矩阵、钩子/伏笔矩阵、人物状态矩阵、主线承诺-兑现矩阵、设定/能力与规则矩阵；仅当项目题材证据为修真/仙侠时才命名为修真进度矩阵。
5. **handoff_packet_path**：每个可写 agent 完成后必须写 `追踪/workflow/agent-handoff/{workflow_id}/{agent_id}.json` 或同目录 `.md`。字段至少包含：`agent_id`、`task_scope`、`read_files`、`created_files`、`updated_files`、`key_decisions`、`open_questions`、`source_evidence`、`token_estimate`、`model_degradation_guard`、`next_action`。只读 agent 不能写文件时，`handoff_packet_path=inline-readonly`，但仍必须按动态预算返回压缩 JSON/表格。
6. **禁止把长设定正文直接返回主线程**：完整正文、完整设定、角色档案、势力表、法宝表、卷纲概要、审查 findings 全量清单只能落盘到文件；主线程只读取压缩交接包和必要索引，不读取 agent 的长回复原文。
7. **主线程只读取压缩交接包**：多 agent 全局任务结束后，主线程先合并 handoff 包、批次交接包和范围级摘要，生成总索引和缺口清单；只有遇到冲突、缺证或用户点名时，才回读具体产物文件。
8. **source-grounding**：涉及全书事实、设定、人物、能力/成长规则、伏笔、历史事件的 agent 输出必须在 handoff 中列 `source_evidence`，引用源文件路径/章节范围/行号或章节号。无法给证据的内容标为 `unverified`，不得进入 SSOT。
9. **model_degradation_guard**：agent 交接包、可见汇总和长时间执行状态必须过输出健康门。命中重复行、术语洪泛、n-gram 循环、低信息密度、工程词泄露、provider 噪声、伪完成哨兵时，丢弃污染块，缩小任务粒度重试一次；再次失败则写 `blocked_output_pollution`，不得继续综合。
   - **模型退化 front-stop**：如果执行中出现领域词无间隔重复、SSOT 词组循环、阶段标签循环、同一领域词几十次刷屏、长时间 thinking 但无新增可信产物，立即停止当前动作并写 `blocked_model_degradation`。此状态下不得写入正文/报告，不得继续 Write/Edit，不得把污染思路转成修复方案；只保留最后可信断点，缩小任务粒度重试一次。若重试仍出现循环，向用户显示干净候选：1. 缩小范围继续 2. 切换模型后续跑 3. 只保存诊断。
   - **自学习退化规则**：长输出、全局任务、审阅报告、修复方案或正文生成前先读取已学习模型退化规则：`追踪/schema/output-pollution-rules.jsonl`。若规则含 `blockedStatus=blocked_model_degradation`，必须把对应 phrase 加入本轮前置阻断词表；生成草稿、候选或报告前先检查这些 phrase，命中即前置阻断，不进入 Write/Edit 或长回复生成。
   - **供应商敏感输出拦截**：如果 API 返回 `output new_sensitive`、`new_sensitive (1027)` 或类似输出安全错误，写 `blocked_provider_sensitive`。不得原样重试同一 prompt，不得继续 Write/Edit，不得调用 Agent/TaskCreate 继续撞同一任务，不得把被拦截内容补写到正文/报告；用户输入继续也不得直接恢复原任务，必须先进入恢复选项。保留最后可信断点，降低显性描写、改成概述式/非露骨表达，缩小任务粒度后最多重试一次。若仍失败，提示用户选择：1. 降低描写尺度继续 2. 跳过敏感段保留剧情因果 3. 停止并只保存诊断。
10. **token_guard**：当累计 token 或耗时异常增长、出现 recap/长时间 thinking、agent 0 token Done、长时间无落盘产物、输出超过预算时，必须停在批次边界，写 `paused_after_batch` 或 `blocked_verification_failed`，说明最后可信产物和下一步，不让用户看着空转。

## Token Cost Governance

`token_cost_governance` 是运行层成本治理，不是让用户少提需求，也不是减少审查维度。它把“浪费不可见”变成可见账本，把“值得花和该治理分开”写进 workflow：复杂设计、关键判断、疑难排障可以花 token；模型错配、上下文膨胀、工具噪音和失败反复重来必须治理。

成本决策映射的权威文件是同目录的 [token-cost-governance.md](token-cost-governance.md)。L2 `story-workflow` 负责在 workflow packet 中写入 `model_routing_policy`、账本路径、批次预算和失败预算；L3 专业模块只执行 packet，并把实际消耗、浪费信号和是否需要升级模型回传给 L2。

长任务、全局任务、拆文、范围审阅、批量回炉、导入和扫榜抓取启动前，`runtime_guard` 必须补充：

```json
{
  "token_cost_governance": {
    "cost_ledger_path": "追踪/workflow/token-cost-ledger.jsonl",
    "cost_summary_path": "追踪/workflow/token-cost-summary.json",
    "model_routing_policy": {
      "cheap_extract": "切章、计数、索引、grep、schema、格式校验、快速源锚摘要",
      "standard_reasoning": "普通审阅、批次聚合、写作规划、修复方案",
      "deep_reasoning": "全局架构、重大改纲、复杂一致性仲裁、反复失败后的根因分析"
    },
    "tool_output_filter": "原始工具输出先落盘再聚合；主线程只读 JSON 摘要、短结论、路径和下一步",
    "retry_budget_result": "同类失败最多一次修正重试；再次失败写 blocked 状态和最后可信断点"
  }
}
```

执行规则：

1. **过程可见**：每个阶段开始或结束时调用 `node scripts/token-cost-ledger.js init|append|summary --project-root <book-root> ... --json`，记录 input_files、input_chars、output_chars、tool_calls、retry_count、failure_count、cache_hit、model_class 和 task_complexity。Claude 看不到真实 token 时，用这些 proxy 指标估算。
2. **经验可沉淀**：`token-cost-summary.json` 的 `waste_signals` 进入 workflow 记忆。后续同类任务默认复用更便宜、更稳的 `model_routing_policy`；但当前用户明确指定模型或质量档位时，以当前请求为准。
3. **实验可回放**：benchmark、上游对比、拆文重跑和 smoke matrix 必须保存输入路径、skill bundle、模型等级、批次计划、成本账本和产物路径，便于同一状态下比较不同方案。
4. **工具输出不原样喂给模型**：Bash、grep、node、MCP、测试输出超过短日志阈值时，完整输出写文件，主线程只读脚本生成的 JSON/摘要。不得把原始长输出直接塞回主线程，不得把工具日志、diff、表格或错误堆栈拼进下一轮 prompt。
5. **模型路由先行**：机械提取和校验默认 `cheap_extract`；批次综合默认 `standard_reasoning`；只有全局架构、重大修复、跨卷连续性仲裁和高风险污染根因分析使用 `deep_reasoning`。如果 `task_complexity=low/mechanical/extract` 却使用 `deep_reasoning`，账本记录 `model_mismatch`。
6. **失败不空转**：同类失败最多一次修正重试；第二次失败写 `blocked_repeated_tool_failure`、`blocked_model_degradation` 或对应状态，不继续换 prompt 撞工具。失败后的可见回复必须短，指向 `cost_ledger_path`、最后可信产物和恢复选项。

### 节点完成成本摘要

阶段、批次、agent 分派、长报告落盘、拆文章节批次、审阅范围批次、批量回炉和协作环境更新完成时，必须自动调用或读取 `token-cost-ledger.js summary`，在可见回复中给出 1-3 行成本摘要：`estimated_tokens`、`tool_calls`、`retry_count/failure_count`、主要 `waste_signals`、账本路径。**不用等用户询问成本**，也不要把完整 JSON 贴给用户。

异常浪费必须主动提醒：只要 `proactive_alerts` 非空，或出现 `model_mismatch`、`tool_noise_waste`、`context_thickening_waste`、`failure_retry_waste` 任一信号，下一步候选前必须先输出“成本提醒”，说明最后可信产物和更省 token 的恢复路线。提醒不是阻断全部工作；它默认停在当前 checkpoint，建议缩小范围、复用中间产物、改用确定性脚本或切换到更合适的 `model_class`。

可见格式示例：

```text
成本摘要：estimated_tokens≈12000；tool_calls=9；retry/failure=1/1；账本：追踪/workflow/token-cost-summary.json
成本提醒：检测到异常 token 浪费信号 tool_noise_waste、failure_retry_waste。建议先复用已落盘批次摘要，缩小下一批范围后继续。
```

### 主动/被动成本提醒协议

成本提醒分两类：

- **主动提醒**：阶段完成、批次完成、agent handoff 完成、长报告落盘、拆文批次、审阅批次、批量回炉、setup/update/migration 完成，或 `proactive_alerts` 非空时，必须自动显示成本摘要和 `token_saving_plan.actions` 前 1-3 项。异常浪费出现时，下一步候选前先说明更省 token 的恢复路线。
- **被动查询**：用户询问成本、token、消耗、为什么慢、为什么贵、节省 token、查看成本报告时，读取 `追踪/workflow/token-cost-summary.json`；若缺失，再说明当前任务尚未建立账本并给出创建方式。不得凭感觉回答“应该不贵”。

被动成本回复只展示摘要、浪费信号、节省动作和路径，不贴完整 JSON。前端/runner 可直接读取 `workflow-runtime-supervisor.js` 返回的 `passive_cost_report_available`、`cost_alerts` 和 `token_saving_plan`。

### 节省 token 执行协议

节省 token 不是减少用户要求，也不是减少审查维度，而是减少无效上下文、重复读取和失败空转。执行规则：

1. **读前复用**：先复用已落盘索引、批次摘要、range-summary、review-state、章节契约、handoff 包和证据矩阵；只有冲突、缺证、用户点名或必须回源时才读原文。
2. **模型路由**：机械提取、计数、grep、schema、章节切片和格式校验走 `cheap_extract`；普通聚合/规划走 `standard_reasoning`；全局架构、重大改纲、跨卷仲裁和反复失败根因才走 `deep_reasoning`。
3. **工具降噪**：长 Bash、grep、测试、MCP、crawler 输出先写文件，再生成 JSON/短表。主线程只读路径、计数、失败项、changed_files 和下一步。
4. **批次续跑**：长篇拆文、全书审阅、批量回炉按卷/范围/信息密度分批；每批写 checkpoint 和 handoff，下一批读取摘要而不是重读上一批全文。
5. **失败止损**：同类失败最多一次修正重试；第二次进入分诊脚本、确定性脚本或 blocked 状态，禁止继续换 prompt 撞工具。
6. **agent 瘦身**：agent prompt 只给目标、输入文件清单、输出路径、禁止项和证据要求；完整产物落盘，回主线程的是 handoff，不是全文。
7. **完成节点汇报**：每个完成节点读取 `token_saving_plan`。如果有 `downgrade_model_class`、`filter_tool_output`、`reuse_artifacts_before_raw_read`、`stop_retry_and_triage`、`reuse_cached_artifacts`，必须把对应动作纳入下一步候选或默认执行路线。


## 从顶层入口迁移的用户动作与长任务安全边界

## 用户动作边界

| 用户动作 | 含义 | 是否修改正文、大纲、细纲 |
|---|---|---|
| 准备写书 | 新项目初始化协作环境，并在需要时创建基础状态模板 | 不修改正文、大纲、细纲 |
| 更新写作协作环境 | 更新当前书籍项目的 hooks / agents / rules / scripts / references / `.story-deployed` | 不修改正文、大纲、细纲 |
| 迁移章节结构 | 把旧扁平目录迁移为卷内编号结构，移动正文/大纲/细纲/追踪资产 | 必须单独确认 |
| 创作补全/回炉 | 按用户明确写作意图补大纲、补细纲、改正文、扩容、合并或重写 | 必须按目标书、目标章节和影响范围执行 |

默认对用户说“更新写作协作环境”，不要说“刷新 setup / 刷新当前书目”。如果需要移动正文、大纲、细纲，必须把动作升级为“迁移章节结构”或“创作补全/回炉”，并单独确认。

## 跨模块叙事连续性治理

`novel-assistant` 负责把“情节剧情连续性、人物持续发展、设定与事实一致性”分配到正确内部模块，而不是让某个子 skill 越权处理所有问题。

| 内部模块 | 连续性职责 | 边界 |
|---|---|---|
| `story-long-write` | 写作/续写/回炉/扩容/合并时执行叙事连续性硬门，维护 Chapter Contract、State Delta、Handoff、Revision Stability Recheck | 可以改正文/大纲/细纲，但必须先确认影响范围和版本快照 |
| `story-review` | 审阅/补审时检查剧情情节连续性、钩子上下文、人物状态、设定与事实一致性；非连续范围生成 gap 风险和范围补缝报告 | 只输出报告和修复方案，除非用户明确要求执行修改 |
| `story-deslop` | 去 AI 味时只能改文字表达，保留事实、钩子、人物状态、因果链、修真进度和章节承诺 | 一旦需要改变叙事事实，升级为 `story-long-write` 回炉流程 |
| `story-short-write` | 保证短篇内部因果、反转铺垫、人物/关系变化、伏笔和情绪曲线自洽；短篇去 AI 味优先使用 `short-deslop.md` | 不套长篇跨批系统，但不能只看情绪强度或文风；短篇项目不要先套通用 deslop |
| `story-long-analyze` / `story-short-analyze` | 提供对标书事实底座、结构模块、情绪/节奏/钩子学习材料 | 不直接生成本书事实，不替本书修改正文 |
| `story-long-scan` / `story-short-scan` | 提供市场和题材输入，辅助选题、读者欲望和卖点定位 | 不替代本书大纲和连续性校验 |
| `story-import` | 反向建立连续性资产，把已有正文转成角色、时间线、伏笔、章节状态和结构索引 | 不擅自改写原正文 |
| `story-setup` | 部署 hooks、agents、rules 和脚本，让叙事连续性治理在 Claude/Codex/OpenCode 中可执行 | 不修改书籍正文、大纲、细纲 |

## 多书写入安全

当一个 workspace 下存在多个书籍项目时，查询类任务和写入类任务必须分开处理。

- 查询类任务：查角色、查伏笔、查进度、查设定、只读审查，可以使用 `.active-book`；`.active-book` 缺失时可先列出候选书并询问。
- 写入类任务：继续写、改正文、重写、回炉、扩容、合并、迁移章节结构、更新大纲/细纲、删除版本，必须先确认目标书。
- 如果只发现一本书，可以自动确认它为目标书并继续。
- 如果发现多个书籍项目且 `.active-book` 缺失、指向不存在，或用户请求中的书名与 `.active-book` 冲突，必须先确认目标书，不得猜测。
- 确认目标书后再读取章节状态、生成写作方案或执行落盘修改。

## 拆文交互原则

用户只说拆书、继续拆书、重新拆某几章、修复拆文质量时，仍然由 `/novel-assistant` 自动路由到长篇/短篇拆文模块并执行完整 workflow。脚本只作为内部执行器：可以由 skill 在后台调用、校验、重试、落盘，但不要把 `node scripts/...`、`bash scripts/...` 或 shell 片段作为用户需要手动输入的操作方式。

对外只给这种入口：

```text
/novel-assistant 继续拆《书名》
/novel-assistant 修复《书名》第81-86章拆文摘要
/novel-assistant 完整拆解 /path/to/原文.txt
```

当你需要提高速度、降低 token 或避免授权弹窗时，应在内部选择固定脚本、批次窗口和 source-grounding 校验，而不是让用户离开 novel-assistant 去执行脚本。

## 长任务督导模式

全书拆文、全书审阅、600 章级别重拆等任务，不应依赖一个 Claude Code 交互窗口连续跑数小时。Claude Code 可能因为 recap、API error、模型超时、会话压缩或 UI 停靠回到输入框；这不是业务确认点，也不应让用户反复手动输入“继续”。

推荐运行层：

1. 前端或启动器只向用户暴露 `/novel-assistant 完整拆解/继续拆/修复拆文`。
2. 内部以 10-40 章为原子批次，批次结束必须落盘摘要、质量状态、断点和下一批范围。
3. 不得修改用户的 Claude / shell / 系统全局默认配置。若前端或专用启动器创建长任务进程，最多只对该进程注入 `CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0` 等运行期环境变量；手动 CLI 会话不要求用户改全局配置。
4. 如果出现 API error、timeout 或进程退出，前端或启动器读取 `_progress.md` / 章节文件实际进度，自动重新发起 `/novel-assistant 继续拆《书名》`，不得要求用户手动续。
5. 每次续跑都从落盘断点和已存在文件判断进度，不依赖聊天记忆。
6. 用户界面显示“运行中 / 最近完成章 / 下一批 / 失败数 / 可暂停”，而不是暴露内部脚本命令。

## 单字母阶段续跑

长任务被 recap、任务列表或阶段表打断后，用户可能只输入 `a/b/c/d/e`、`A/B/C/D/E`、`1/2/3`、`下一步` 或 `继续` 来选择刚才列出的阶段。只要上一轮可见上下文里有 `Phase A/B/C/D/E`、`阶段 A/B/C/D/E`、编号选项或任务列表，就必须把短输入当作续跑选择，而不是当作无意义字符。

处理规则：

1. 先检查是否存在 `pending_action`。有 `pending_action` 时，短回复按该确认点解释；没有 `pending_action` 才回退到阶段表或任务列表。
2. `a/b/c/d/e`、`A/B/C/D/E`、`选E`、`phase e` 映射到最近一次阶段表中的 `Phase A/B/C/D/E`；例如用户只输入 `e`，且上一轮列出 `Phase E 人物出场铺垫补写`，必须继续执行 Phase E 人物出场铺垫，不得反问“您看到的是 e 单字符输入吗？”。
3. `1/2/3`、`第1项`、`选1` 映射到最近一次编号选项；如果编号选项不在当前上下文，不猜。
4. `继续/下一步` 映射到最近一次标记为 open / pending / in_progress 的下一项；如果上一轮明确写了“下一步请确认是逐章回炉还是 Phase E”，而用户输入 `e`，按 Phase E 执行。
5. 已完成阶段被再次选择时，说明该阶段已完成，并自动进入同一任务列表里的下一个未完成阶段；只有没有未完成项或会覆盖正文/大纲/细纲时才提问。
6. 若没有可见阶段表、任务列表或编号选项，才询问用户 `e` 指的是什么。

这类短输入是用户对上一轮选择的直接回复。不得把它升级为闲聊，不得输出“单字符无法理解”，也不得只总结已完成项后停住。

## 外部 Runner 协议边界

skill 只定义协议、状态文件和可恢复行为，不拥有也不实现具体前端。不要在 skill 内写死 novel-project、端口、页面路由、WebSocket/SSE 细节或某个服务器进程；这些属于 runner / 前端 / 启动器实现。

runner 负责会话生命周期：创建或复用 Claude/Codex 会话、维持流式输出、超时后重连、按断点续跑、向用户展示进度、暂停/恢复/取消任务。skill 负责在每个阶段落盘可机器读取的事实：`_progress.md`、`_recovery-state.json`、批次计划、章节摘要、审查报告、schema/jsonl、版本 manifest 和错误清单。

协议要求：

1. **文件系统为权威**：runner 重连后必须先读 `_progress.md`、`_recovery-state.json`、批次产物和目标目录实际文件，不用聊天 transcript 猜进度。
2. **进度可增量展示**：长任务每完成一个原子批次都更新进度文件；runner 可据此向前端推送“阶段、已完成范围、下一批、失败项、是否需要用户确认”。
3. **确认点要结构化**：只有目录迁移、覆盖已有正文/大纲/细纲、删除版本、开发版 skill 更新、配额阻断等高风险动作需要用户确认；确认请求要写明 `reason`、`risk`、`safe_default`、`resume_command`。
4. **续跑入口统一**：runner 自动续跑时仍发送 `/novel-assistant 继续...` 这类自然语言入口，由本 skill 路由；不要绕过 skill 直接调用内部脚本作为用户可见操作。
5. **实现留给外部**：novel-project 或其他前端可以用 SSE、WebSocket、轮询或 CLI PTY 实现流式和会话保持，但 skill 文档只约束输入输出契约，不绑定某一种技术。

## 长任务故障自愈协议

当长篇拆文、全书审查、批量回炉、导入小说、扫榜抓取等长任务出现 API error、timeout、recap 停靠、会话压缩、工具失败、质量校验失败、章节计数冲突、进程退出或重复启动时，默认进入自愈流程，不把这些运行层事件升级给用户。

拆文使用专用探针；其他模块借鉴同一套原则，用各自的权威落盘文件判断断点：全书审查看 `追踪/审查批次计划.md` 和批次报告，批量回炉看 `追踪/修订影响/影响批次计划.md` 和复检报告，导入小说看导入进度/章节映射，扫榜抓取看 raw/html/jsonl 缓存与结构化产物。

自愈流程：

1. **先探测再行动**：若目标输出目录已存在，内部运行 `scripts/long-analyze-recovery-state.js <拆文库/{书名}> --write --json`；若有运行日志，追加 `--log <日志路径>`。该脚本只作为内部探针，不能作为用户需要手动执行的命令。
2. **文件系统是权威**：以 `章节/第N章_摘要.md`、`章节切片索引.jsonl`、`批次计划.json`、`_progress.md` 的实际落盘结果判断总章数、连续完成章、第一缺口和阶段；聊天记忆、上一轮回复、旧 `_progress.md` 里的“最后处理”只能做参考。
3. **自动恢复类**：timeout、API error、stream stall、UI 停靠、空输出、单章执行失败、质量门禁失败，按断点从第一缺口继续；单章先同模型重试 1 次，质量失败升级模型重试 1 次，仍失败则记录失败并继续非关键章节。
4. **自动修复类**：缺 `章节切片索引.jsonl` / `批次计划.json` 但原文仍在时，先重建规划；`_progress.md` 与实际摘要冲突时，以实际摘要修正 `_progress.md` 和 `_recovery-state.json`。
5. **自动降级类**：agent 不可用、上下文/工具时间逼近边界、超大书高成本深拆时，降级为 bounded fast fallback 或快速源锚模式，先保全全书覆盖与可续跑性，再对关键章补深拆。
6. **外部阻断类**：429、Token Plan、quota、账号/供应商配额、源文件多重冲突或原文丢失，不能无限重试。写清 `_recovery-state.json`、`_progress.md`、第一缺口和阻断原因后停止；下次启动先重新探测，若阻断解除再自动续跑。
7. **熔断边界**：同一章节最多“执行重试 1 次 + 质量升级重试 1 次”；同一进程连续自动重启最多 3 次。超过后记录 `completed_with_errors` 或 `external_blocked_*`，避免故障风暴和 token 空转。
8. **原始工具输出不是可结束状态**：长任务中的 Bash/Grep/脚本扫描只算证据收集，不算完成。结束前必须收束为报告、进度、断点和下一步；不能让用户只看到原始 Bash 输出后回到输入框。如果来不及完成报告，至少写入对应模块的 `paused_after_scan` / `running_incomplete` 断点和恢复动作。

对用户的可见表达只报告结果和下一步状态，例如“已从第 N 章继续 / 当前被配额阻断，断点已保存”。不要把内部脚本、重试循环、shell 片段作为用户操作步骤。
