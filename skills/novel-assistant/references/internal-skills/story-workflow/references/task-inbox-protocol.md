# Task Inbox Protocol

此协议在任务收件箱、首屏恢复、数字候选、状态机解析与阶段启动时按需读取。以下条款从 story-workflow 完整迁移。

## 任务中心工作流

`story-workflow` 的用户可见记忆是“任务记忆”，不是人物、设定、伏笔、章节全文的总数据库。启动时先展示未完成任务、当前阶段、最后可信产物、停靠原因和下一步候选；专业模块只装配上下文，在真正执行写作、审阅、拆文或去 AI 味时再读取人物、伏笔、钩子、设定和作者声口。

硬规则：

- 任务中心优先于业务猜测：只要 `workflow-task-inbox.js` 找到未完成任务，就先展示任务卡，不得凭聊天记忆生成“继续写第十二卷”之类候选。
- 用户反馈必须先分类：数字输入走 `pending_action`；自由反馈进入“当前产物修复 / 上游重规划 / 新任务切换 / 暂停取消”分类，再决定执行路径。
- 自由反馈是流程能力，不是例外：每个阶段都允许用户 chat 介入、提交人工修改、要求重构、改变范围或开启新目标。
- 任务记忆保持轻量：记录任务标题、阶段、范围、最后可信产物、停靠原因、下一步候选和必要上下文引用；不要把全部人物设定和章节内容塞进任务卡。
- 工程词对外翻译：对用户展示时使用“当前任务记录”“下一步候选”“协作环境”“权威设定”“确认范围”等中文词，不直接暴露 `pending_action`、`runtime_guard`、`range_lock`、`SSOT`。

## 跨会话写入租约

同一本书可以同时被 Claude Code、Codex、ZCode、前端和 runner 打开，但写入型任务必须只有一个 writer。`story-workflow` 使用任务族 `task_family_id` 绑定同一个用户目标下的多个 workflow 分支，并用 writer lease 判断当前谁可以推进写入阶段。

租约状态：

- `active`：当前 writer 心跳仍有效，其他会话只能只读查看或提出接管请求。
- `awaiting_claim`：旧 writer 心跳已过期或宿主未知，但不能自动视为死亡；新会话必须显示“待认领”，由用户确认是否接管。
- `takeover_required`：旧 writer 仍存活或状态不明，新会话必须二次确认接管，不能直接继续写入。

实现约束：

- `追踪/workflow/sessions/<session-id>.json` 是跨宿主心跳。Claude Code `session-start.sh` 只登记 `cooperative_interactive` 能力；它不能声明流式早停、进程托管或精确 token 统计。
- `workflow-runner` 启动的子进程才是 `managed_runner`，可以写托管心跳、刷新 runner lease，并在异常时按 runner 协议中止。
- PID 探测只是本机辅助证据。远程机器、桌面重启、Web 会话或无法确认 PID 的会话过期后，只能进入 `awaiting_claim`，不得自动接管 writer。
- 用户在多个会话里打开同一任务时，首屏必须展示“已有同目标任务/会话，是否接管或只查看”，而不是把同一任务拆成多个未完成任务。
- 接管必须由用户确认，不能因“后打开”自动发生。接管成功后，旧会话保留读取能力但降为 observer；它后续任何写入尝试都必须重新进入接管菜单。不同任务可以并存，但同一作品的正式资产写入仍由书目级写锁串行提交。

## RPD 与任务目录持久化

借鉴 Trellis 的“spec / task / workspace journal”分层，但不照搬 `.trellis` 目录。小说项目内统一使用 `追踪/workflow/tasks/<workflow_id>/` 保存每个长期任务：

```text
追踪/workflow/tasks/<workflow_id>/
  task.json
  rpd.md
  context.jsonl
  verify.jsonl
  journal.jsonl
  result-packets/
  artifacts/
```

`rpd.md` 是“任务需求与读者承诺文档”，用于保存用户目标、读者承诺、任务边界和验收标准。它不是产品 PRD；小说任务必须写清情绪兑现、剧情可信、人物连续、钩子回收、风格边界和质量门。

`context.jsonl` 是本任务允许装配的上下文清单，必须写明 `kind/path/reason`；不要让 L3 模块凭感觉广泛扫描正文。`verify.jsonl` 是任务完成前的验证清单；`journal.jsonl` 是任务局部日志，至少记录 `created`、`resolved_action`、`applied_result`、`superseded`、`completed`。

兼容规则：

- `追踪/workflow/current-task.json` 只是当前 UI 焦点入口，只保存 `workflow_id`、`task_dir`、`state_version` 和焦点时间。
- `tasks/<workflow_id>/task.json` 是该任务唯一 durable authority；pointer 的 identity/version 可以随写入刷新，但不得复制完整任务状态。
- 用户切换新目标时，旧任务目录不删除，默认标记 `lifecycle.status=paused` 并保留 RPD、journal、checkpoint、pending action 与 result packet。只有用户明确终止/放弃时才标记 `superseded/cancelled`。
- `workflow-task-inbox.js` 必须优先扫描 `tasks/*/task.json`，再读旧的 `current-task.json`、短篇状态、review-state、拆文 progress 和 legacy metadata；同一 `workflow_id` 去重。
- RPD/任务目录只保存任务记忆；人物、伏笔、设定、风格仍属于 `追踪/memory/` 和项目创作资产，由 `context-assembler.js` 按任务显式装配。

## 上游 issue 反哺硬化点

从上游公开 issue 吸收的生产边界必须进入 workflow，而不是只写在 README：

- `single_writer_merge`：多 agent 可以并行读和分析，但生产文件最终只能由主流程或指定 merge step 写入。
- `model-provider-profiles.md`：OpenAI-compatible endpoint、Qwen、Minimax、DeepSeek 和 custom endpoint 都必须先归一成 provider profile，再进入长任务。
- `outline_to_draft_gate`：开书、改大纲、扩容和回炉都要先完成设定/总纲/卷纲/细纲或短篇小节大纲的最低可写条件，再进入正文。
- `review_gap_reconciliation`：审阅 1-200 后再审 300-400 时，必须标记 201-299 缺口；后续补审缺口后，重新评估 300-400 是否过时。
- `full_auto_deconstruction`：用户要求完整拆文时，默认拆成可恢复批次自动推进；只有缺源、授权、配额、覆盖风险、grounding 失败或输出健康失败才停。
- `anti_ai_workflow`：用户说“去 AI 味 / 检测 100% AI / 改自然 / 太像 AI / 降 AI 味”时，先进入工作流诊断，再路由短篇、长篇或未知片段处理；不得直接泛化润色整篇。

下一步候选必须消除歧义：

- “只执行本项”：只完成当前候选对应的单一步骤，完成后仍要列出剩余阶段。
- “继续后续阶段”：完成当前阶段后自动进入下一个安全阶段，遇到写入/迁移/覆盖/高风险修订仍停靠确认。
- “完成整个流程”：只用于低风险、边界明确、验证脚本齐全的流程；完成后必须跑收束验证并更新 `tasks/<workflow_id>/task.json` 的 `status=completed`。

## AI Native 小说生产吸收契约

从 ExplosiveCoderflome/AI-Novel-Writing-Assistant 吸收的是 skill 层工程原则，不是它的整套应用系统。吸收范围限定为：

1. **质量债务**：局部章节问题记录为 `quality_debt`，可用 `continue_with_warning` 或 `repair_later` 继续主链；只有事实底座、全书承诺、目录结构、模型健康或写入安全问题才 `stop_for_replan`。
2. **结构化意图**：router 先形成 `intent_schema`，包含 `intent_type`、`target_scope`、`route_confidence`、`fallback_question` 和 `selected_owner_module`，再选择 workflow；关键词只是证据，不是唯一裁决。
3. **角色资源账本**：写作前装配 `chapter_participants_context`，并区分 `confirmed_facts`、`pending_cast_candidates` 和 `fact_proposals`；待确认提案不得写成既成事实。
4. **写法资产**：作者声口、赛道写法、反 AI 约束进入 `style_feature_pool`、`style_binding` 和 `style_compile_report`；写法资产不是通用 humanizer，不能抹平用户认可的强情绪和个人表达。

这些契约必须进入 workflow packet 或 result packet，而不是只写在 README。L3 模块可以产生质量债务、候选事实和写法建议，但最终是否入账、是否继续主链、是否升级重规划，由 `story-workflow` 按本内核统一裁决。

### anti_ai_workflow packet

`anti_ai_workflow` 必须在 workflow packet 中写清：

```text
anti_ai_work_type
prose_profile
target_scope
write_mode
fact_baseline_paths
author_voice_profile_paths
human_voice_protection
external_ai_detector_signal
verification_policy
completion_policy
```

- `anti_ai_work_type`: `shortform | longform | unknown_fragment`。
- `prose_profile`: `fiction | report | outline | chat | technical | unknown`。正文、审查报告、细纲/章节契约、可见回复和技术说明必须分开诊断，不能用同一套“去 AI 味”规则误伤。
- `target_scope`: `正文.md`、短篇小节、单章、章节范围或用户粘贴片段。
- `write_mode`: `report_only | rewrite_copy | in_place_with_snapshot`；默认不覆盖原文。
- `fact_baseline_paths`: 短篇用 `设定.md`、`小节大纲.md`、素材卡；长篇用章节契约、卷纲/细纲、交接包、状态账本。
- `author_voice_profile_paths`: 用户已确认优秀样本、`追踪/workflow/author-voice.json`、`设定/作者风格/` 或 `preference-memory.jsonl` 中可复用的风格证据；没有时为空，不得编造。
- `human_voice_protection`: `normal | minimal_repair`。当存在作者声音画像或确认样章时，默认 `minimal_repair`，只修硬污染、工具指纹、占位符、模型循环和用户硬禁表达，不把作者声口改成通用 humanizer 腔。
- `external_ai_detector_signal`: 用户提供的“100% AI”等外部检测结果只作为信号，不作为唯一裁决。
- `verification_policy`: 必须包含 `anti-ai-diagnose.js`、退化检测、AI 句式/标点门禁、事实保留检查；有作者样本时必须包含 `author-voice-profile.js` 或已存在的 author voice profile。

如果去 AI 味需要改变情节、补伏笔、移动钩子、改人物状态或改章节承诺，返回 `blocked_revision_required`，升级到回炉/修订，不得在 deslop 中硬改。

## 外部任务工具禁用协议

story-workflow 的任务计划必须落盘到项目文件，不依赖外部任务 UI：

- 不得调用 TaskCreate、TodoWrite、AskUserQuestion 或交互式选择工具来建立/更新小说任务计划；不得调用交互式选择工具展示下一步候选；这些工具在不同 CLI 中可能触发 `Invalid tool parameters`。
- 用户请求“补设定任务较大”“全书审阅”“1-722 章扫描”“拆文全量推进”等长任务时，先写或更新 `追踪/workflow/tasks/<workflow_id>/task.json` 和 `追踪/workflow/current-task.md`，再刷新焦点 pointer。
- `tasks/<workflow_id>/task.json` 保存机器可恢复字段：`workflow_id`、`workflow_type`、`scope`、`completion_policy`、`current_stage`、`current_step`、`status`、`next_candidates`、`resume_hint`。
- `追踪/workflow/current-task.md` 保存用户可读摘要：已确认目标、分批策略、当前批次、下一步候选和阻塞门禁。
- 用户需要选择时，只输出普通文本短选项，不调用交互式选择工具；选择结果再写回 `history.jsonl`。
- 如果已经出现 `Invalid tool parameters`，禁止重试同类外部工具；立即改用文件化任务计划恢复。

## 数字候选协议

`story-workflow` 输出的 `next_candidates` 必须使用纯数字编号。纯 CLI 用户直接输入 `1/2/3/4`；前端或 runner 可以读取同一份候选数据，用上下方向键高亮候选后提交对应 `number`。不要同时展示 `A/B/C/D`，避免用户以为数字和字母是两套不同流程。

可见候选格式：

```text
1. 继续当前阶段
2. 跳过当前步骤
3. 返回阶段导航
4. 停止并保存断点
```

durable task 的 `next_candidates` 推荐保存对象而不是裸字符串：

```json
[
  {"number":1,"label":"继续当前阶段","action":"continue_stage"},
  {"number":2,"label":"跳过当前步骤","action":"skip_step"}
]
```

规则：

- 不要只输出“继续写 / 审阅 / 拆文 / 修复”这种无编号列表。
- 不得依赖外部交互式选择工具实现上下方向键；skill 只提供稳定候选协议，方向键 UI 由前端/runner 实现。
- 候选 `number/action/label` 必须写入 durable task 的 `pending_action.options` 或 `next_candidates`，方便跨会话恢复。
- 默认最多展示 4 个业务候选；候选超过 4 个时，第 4 项用 `查看更多选项` 进入下一页，下一页第 1 项可返回上一页。
- 不要把 `Chat about this`、`Type something` 当成业务候选；用户可以随时直接输入自然语言补充或改条件。
- 每组候选必须保留一个稳定编号的自由表达出口，例如 `4. 输入其他要求`；它属于可见候选并占用编号。用户仍可不选择编号、直接输入自然语言，前端/runner 可把该编号渲染成“输入其他意见”入口。
- 若上游 `workflow-entry-guard.js` 返回 `status=new_project_ready` 或 `recommended_next=show_new_project_onboarding`，表示当前目录未初始化，必须逐字展示 `visible_response.text` 的新项目入口。未初始化目录不得展示任务收件箱，不得显示“查看未完成任务（0 个）”，也不得解释“第 1 项列表为空”；首屏应直接给出 `新开长篇 / 新开短篇 / 导入或拆文 / 输入其他目标`。
- 若上游 `workflow-entry-guard.js` 返回其他 `visible_response.text`，逐字使用该结构化文本作为唯一菜单正文。已初始化项目即使未完成任务为 0，也必须显示 `1. 查看未完成任务（0 个）`；不得绕过 guard 把智能推荐平铺为 A/B/C/D/E。不得追加业务猜测、无编号短横线列表、章节状态示例或“回复 1 即查看……”之外的自写说明；如果需要提供新目标入口，必须使用 guard 的数字候选。多个恢复项先展示工作流大类，再进入组内任务，避免同屏重复编号。
- 若本轮用户输入是明确新业务意图（例如“做反馈影响链检查”“回炉第 3 节”“审阅 1-200 章”“开始短篇写作”），`workflow-entry-guard.js --user-intent` 应返回 `business_routing_allowed`。旧任务收件箱只能作为上下文，不得用旧任务收件箱拦截明确新业务意图，也不得要求用户先选择“输入其他要求”才能执行已经说清楚的目标。
- 默认候选只放当前业务任务的下一步；检查更新、更新本地 skill、迁移章节结构等维护动作只在用户明确要求时出现。
- 如果落盘状态显示存在未完成任务，候选要按“继续未完成任务 / 开启新的任务”分组；继续项必须标出来源文件或断点，不得凭聊天记忆猜测，也不得自动替用户推进旧任务。

## Workflow State Machine

`workflow-state-machine.js` is the authoritative state machine / 状态机 helper for multi-step workflows. Before creating, resuming, advancing, completing, blocking, or rendering numbered choices for `long_write`、`short_write`、`review_repair`、`long_analyze`、`long_scan`、`short_scan`、`short_analyze`、`cover`、`download_import`、`deslop` 或 `setup_update`，先调用：

```bash
node scripts/workflow-state-machine.js inspect --project-root <book-root> --json
node scripts/workflow-state-machine.js next-candidates --project-root <book-root> --json
```

`workflow-runner.js` 是状态机的确定性执行层，不是新的专业写作模块。宿主或前端需要自动推进一个已经确认的阶段时，优先调用：

```bash
node scripts/workflow-runner.js once --project-root <book-root> --adapter <claude-code|codex|zcode> --json
```

需要连续推进安全阶段时可使用 `run`；runner 遇到 `requires_user_confirm`、结果包不合法、输出退化、重复工具失败或阶段上限必须停止。`--adapter auto` 只能探测能力，不得静默选择收费宿主。专业模块仍按 `stage_execution.owner_module` 执行业务，runner 只负责编排、流式健康、一次恢复、结果包应用和成本记录。

当用户输入 `1/2/3/4`，必须通过状态机解析。宿主从最近展示的结构化菜单元数据带回 `pending_action_id`、`visible_choice_hash` 和 `state_version`；可见回复仍只显示简洁中文编号，不显示哈希或内部 ID：

```bash
node scripts/workflow-state-machine.js resolve-action --project-root <book-root> --input <number> \
  --pending-action-id <id> --visible-choice-hash <hash> --state-version <version> --json
```

不要从聊天可见文本重新解释数字，也不得只用裸 `1` 推断旧菜单。任何 `pending_action_id`、hash、书目路径、状态版本、过期时间或已解决状态不匹配，都必须以 `blocked_*` 失败关闭，并返回 `refreshed_menu`；不得执行新菜单中恰好同号的选项。执行返回的 `action_id`，并保留 `remaining_stages`。L3 专业模块可以通过 result packet 完成一个 step 或 stage，但只有 `story-workflow` 加 `workflow-state-machine.js` 可以标记整个 workflow 完成。durable task 的 `pending_action.options[].action_id` 是编号选择的权威来源；`machine.remaining_stages` 是剩余流程的权威来源。

### 短篇单命令推进（节省上下文与 token）

短篇（`short_write` / `private_short_startup`）写完一节正文、要把它推进到下一阶段（机器门、质量门、采用锚点、下一节 Brief 等）时，**必须用单命令阶段推进器**，不要依次手跑 `inspect` → `apply-result` → `reconcile-runtime`。多步手跑会让宿主每次都重新加载 `task.json`、模板与历史结果包，是短篇逐节写作 token 与工具调用失控的主要来源。

```bash
node scripts/workflow-stage-controller.js advance \
  --project-root <book-root> --workflow-id <id> \
  --result <result-packet.json> --json
```

`advance` 一条命令完成：解析权威任务 → 校验私有 overlay 身份（`resolveTemplateForTask`，缺失时返回 `blocked_private_workflow_registry_unavailable` 不降级）→ 校验结果包 → 计算转换 → 原子持久化 → 写恰好一条 journal transition → 返回 `{status, completed_stage, next_stage, next_action, recovery_count, last_trusted_artifact}`。

输出语义：

- `advanced`：一次成功，`recovery_count=0`。直接读 `next_stage` / `next_action` 继续，不要再 `inspect`。
- `recovered_once`：首次遇到可恢复失败（陈旧 state version 或瞬时转换 block），重载权威任务与 registry 后重试一次成功。`recovery_count=1`。
- `paused_transition_failure`：连续两次同类失败。任务已 `status=paused`、`runtime_guard.max_retry_budget.retry_budget_result=exhausted`，`last_trusted_artifact` 未变。**此时不得再调任何推进命令、不得读源码排障、不得写临时脚本**，只能向用户报告从最后可信断点恢复。
- `blocked_*`（身份 / 结果包 / 权威不可用）：不可恢复，直接报告，不进恢复路径。

边界：

- **仅短篇推进用 `advance`。** 长篇（`long_write`）仍必须用 `workflow-state-machine.js apply-result`，因为长篇有 lifecycle 门、review plan 校验、task_family 主分支校验和章节事务，controller 不覆盖这些。
- `resolve-action`（编号选择解析）和 `inspect`（首屏 / 恢复对账）仍按上文用 `workflow-state-machine.js`；`advance` 只替代"写完结果包后推进到下一阶段"这一步。
- 调用 `advance` 前不要先 `inspect` 全量任务——`advance` 自己会解析权威任务，预读只是重复消耗。

## 全局任务收件箱

短篇的启动恢复经验必须提升为全局能力：每次 `/novel-assistant` 进入业务路由前，在更新确认硬门禁和 `workflow-runtime-supervisor.js` 之后，运行只读收件箱：

```bash
node scripts/workflow-task-inbox.js --project-root <book-root> --write --json
```

首屏数字动作使用固定、紧凑接口，不允许猜参数或通过 `--help | head` 探测：

```bash
node scripts/workflow-task-inbox.js --project-root <book-root> --action show_unfinished_tasks --json
node scripts/workflow-task-inbox.js --project-root <book-root> --action show_smart_recommendations --json
node scripts/workflow-task-inbox.js --project-root <book-root> --action show_new_goal_options --json
```

若入口 guard 返回 `blocked_workflow_session_lease`，不要向 `workflow-task-inbox.js` 猜测 `takeover_session` action。用户选择“接管当前任务”后，必须直接执行 `visible_response.options[].execution_command`：

```bash
node scripts/workflow-entry-guard.js --project-root <book-root> --takeover-session --confirm --write --compact --json
```

展开未完成任务后，任务卡数字与阶段候选数字属于不同层级，但不允许制造无意义的中间页：

- 恰好只有一个未完成任务且它就是当前焦点时，直接返回 `status=current_task_actions`、`selection_contract=execute_command_or_route_intent` 与该阶段四项动作。页面必须同时显示任务、当前阶段、停靠原因和可执行 `1/2/3/4`，不得只显示任务摘要。
- 存在多个任务，或唯一任务尚未成为焦点时，才返回 `selection_contract=execute_task_card_command_or_route_intent`。用户选择任务卡只能执行 `task_cards[].execution_command`，先激活对应 workflow；禁止把任务卡数字送给 `resolve-action`。激活完成后必须立即投影所选任务的当前动作，不得再次回到任务收件箱首页。
- 激活后若任务已经停在运行阶段，按 `stage_execution.resume_hint` 恢复，并在实际完成 `write_set` 后运行阶段完成命令。只有真正的 pending-action 菜单才允许执行带 `pending_action_id / visible_choice_hash / state_version / book_root` 的 `resolve-action`；`interaction_mode=resume_stage` 不得被转换成命令行参数。
- Codex Desktop 不提供原生候选控件时使用纯文本兼容层，但仍必须逐字渲染 `visible_response.text` 并保存最近一次结构化候选。用户输入数字只消费该候选的 `interaction_mode` 和 `execution_command`；不得只显示 `task_cards[].display` 后结束，也不得把同一个数字重新交给首屏或上一级菜单。

`workflow-task-inbox.js` 只允许做 `metadata_only` 扫描，不读取正文全文、不读取章节内容、不重跑审阅、拆文或写作。它把以下可恢复状态汇总为 `追踪/workflow/task-index.json`：

- 长篇/全局 workflow：`追踪/workflow/tasks/<workflow_id>/task.json`；`current-task.json` 仅用于定位焦点。
- 短篇启动与脑洞项目：短篇状态目录中的 `current-task.json`，仅在本地存在时读取。
- 审阅范围任务：`追踪/review-state.json`。
- 拆文任务：`拆文库/*/_progress.md`。
- 下载/续更类任务：`downloads/_reports/update-state.json`。

用户可见候选必须来自 `task-index.json` 或 `workflow-entry-guard.js` 的 `visible_response`。第一屏要实事求是分流：`new_project_ready / show_new_project_onboarding` 代表未初始化新目录，直接展示新项目入口，不显示“查看未完成任务（0 个）”；已初始化项目在没有明确业务意图时，第一屏固定展示 `查看未完成任务（N 个） / 查看智能推荐新任务 / 开启当前作品新目标 / 输入其他要求` 四个同级数字入口，`candidateCount=0` 时仍显示第 1 项为 0 个。未完成数量只显示在第 1 项括号内，不额外展开分类统计；不得凭聊天记忆、recap 或旧候选推断。用户选择“查看未完成任务”后，单个焦点任务直接展示当前阶段动作，多个任务才展示 `task_cards[]` 或 `workflow_groups[]`；选择“查看智能推荐新任务”后，才展示 `smart_new_task_recommendations[]`。选择“开启当前作品新目标”后，只能展示当前作品内写作/回炉、审阅/修复、素材学习/拆文、输入其他当前作品目标。只有本轮输入已经是明确业务意图时，才直接进入对应流程。

智能推荐必须是可执行的新任务，不得把“工作流完成”“可发布”这类状态通知占成推荐编号。`selection_contract=execute_recommendation_command_or_route_intent` 时，用户选择数字后直接执行该项 `execution_command`；短篇作品的验收推荐必须创建 `short_review`，不得退化为无范围的 `range_review`，也不得让宿主重新进入 Planning 猜测 action。推荐命令失败时保留当前菜单并报告真实命令错误，不能临时生成另一套无编号菜单。

`追踪/workflow/entry-guard.json`、`task-index.json`、空的 `追踪/workflow/` 或仅由运行时同步生成的 `.claude/` 都不是作品资产。守卫不得因为自己写入这些文件，就把空目录改判为“当前作品”。只有正文/大纲/设定等创作资产、非空短篇卡池、`.book-state.json`，或真实存在的 `追踪/workflow/tasks/<workflow_id>/task.json` 才能进入项目收件箱。

短篇资讯池 `追踪/private-short-extension/cards/info-source-cards.jsonl` 中 `new`、`retained`、`selected` 的卡属于可恢复创作资产。收件箱必须将其聚合为一个“继续短篇素材选择（N 条，已保留 M 条）”任务，恢复时先展示连续编号的卡池，不得把用户已保留的资讯丢失或要求重新抓取。`discarded`、`used` 卡不计入恢复任务。

任务完成后，专业模块的 result packet 或 durable task 应写入 `recommended_next`；缺失时 `workflow-task-inbox.js` 可以根据 `workflow_type` 与 `completed_step` 生成 `post_completion_recommendations`。例如长篇开书完成 `macro_outline` 后，推荐“生成第一卷卷纲 / 补齐前 10 章细纲 / 进入第 1 章 Chapter Contract”；日更正文完成后，推荐“运行漂移门控 / 更新 State Delta 与交接包 / 继续下一章”。完成后的推荐不是自动执行项，仍要展示数字候选并等待用户选择。

收件箱不是专业模块：它不替代 `story-long-write`、`story-review`、`story-long-analyze`、`story-short-write` 或私有扩展。它只负责发现可恢复任务、写 `task-index.json`、提供稳定下一步入口。

## 审阅自动 agent 分派协议

范围审阅、批次审阅、全书审阅、跨卷审阅和大批量修复复检属于应该使用 agent 加速的任务。用户只需要说“审阅 1-200”“继续审阅 1-50”“只看第 50 章高风险点”；`story-workflow` 负责把父范围、当前批次、风险信号和可用 agent 交给 `story-review`。不要把 full/lean 暴露成用户必须理解的选择。

进入 `story-review` 前，先生成或读取 agent 调度计划：

```bash
node scripts/review-agent-dispatch-plan.js --scope <parent_scope> --batch <batch_scope> --risk <risk-tags> --existing-reports <n> --agents-available <a,b,c> --json
```

工作流字段必须保留：

- `parent_scope`：用户真正要求的审阅范围，例如 `1-200`。临时缩小到 `1-50` 或第 50 章时，不得丢失父任务。
- `batch_scope`：当前要执行的批次，例如 `1-50`。
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
   自动分派 reviewer agent；父范围 1-200 保留，当前批次以已持久化计划为准。

2. 临时缩小本批高风险点
   只窄化当前批次，不丢失父任务 1-200。

3. 停止并保存断点
```

如果 agent 缺失、部署过旧、当前处于子 agent 内、spawn 失败或宿主没有 agent 能力，自动 `solo_fallback`，把原因写入任务状态和可见摘要；不要停下来问用户“full 还是 lean”。用户显式要求 `solo/full/lean` 时可以作为 override，但默认流程必须自动规划。

范围审阅必须用 `workflow-review-batches.js` 维护父范围和批次状态。`1-200` 依据章节证据、卷/篇章边界、风险密度和运行时预算生成并持久化动态批次；未知宿主预算时使用保守降级。每批拥有独立 result packet，边界章节只作为相邻上下文而不重复主覆盖。只有所有批次完成，父 `evidence_scan` 才能完成并进入 `classify_findings`；批次中断从 `next_batch_id` 恢复，不重跑或静默重排已完成批次，也不能用边界抽样冒充整批完成。

批次收束与修复的选择必须明确后续链：

- `沉淀本批报告后继续`：先落盘并验证本批报告，随后自动进入 `next_batch_id`；不能停在“报告已写”。
- `先修本批风险再继续`：先把 findings 写入修复执行队列，按候选修复、机器门、接受、复检完成本批闭环，随后回到 `next_batch_id`；不能把“登记风险”说成已经修复。
- `只沉淀并暂停`：报告落盘后停在已保存断点，下一次默认从 `next_batch_id` 恢复。

## 多任务与焦点切换

一个书目可以同时拥有多个未完成 workflow。新写作、审阅、回炉、素材学习或拆文默认只创建/切换本会话**焦点任务**；其他任务保留在 `追踪/workflow/tasks/<workflow_id>/`，在任务收件箱中可恢复。除非用户明确说“终止/归档/放弃任务”，不得把已有任务标记为 superseded、stopped 或删除。用户可随时切回任何未完成任务；焦点切换必须保留各自的 checkpoint、pending action、result packet 和 workflow memory 绑定。

旧任务的阶段回执不符合新版协议时，不得只给“重置重跑”。标准菜单为：1）重新验收并继续原任务；2）保留旧证据、记录质量债务并从下一未完成批次继续；3）查看旧证据；4）暂停返回。选 1 或 2 后都进入原 workflow 的连续执行链，不返回任务收件箱首页。选 2 时旧范围使用 `completed_with_warning`，质量债务必须进入最终综合报告，后续批次仍按新版协议执行。

## 审阅修复执行协议

审阅 findings 进入修复时，必须按固定事务推进，不能在聊天里把“登记追踪文件、改正文、验证、下一步候选”混成一轮临场判断。

固定阶段：

```text
repair_plan -> user_scope_choice -> repair_execution_plan -> staged_repair_candidate -> repair_machine_gate -> execute_repair -> recheck
```

硬规则：

- 用户一次选择多个修复项（如 `1 2 3`）时，先写 `repair_execution_plan`，把每项分成 `tracking_only`、`canonical_prose`、`outline_or_structure`、`needs_replan` 四类；不得直接边想边改。
- `tracking_only` 可以批量更新追踪/报告类文件，但必须写入 result packet 和 changed_files。
- `canonical_prose`、正文、章节大纲、细纲、设定基准、伏笔回收位置等高风险项必须进入 `staged_repair_candidate`；不得和低风险登记同一阶段直接落盘。
- `staged_repair_candidate` 只能生成候选修复稿、候选补丁、修复建议或临时稿；不得宣布 canonical 正文已完成。
- `repair_machine_gate` 必须运行退化检测、AI 句式/标点门禁、事实保留检查和输出污染检查。blocking 未清零时回到 `staged_repair_candidate`，不得进入 `execute_repair`。
- `execute_repair` 只负责把已通过机器门和事实保留检查的候选稿接受到正式资产；接受后必须立刻进入 `recheck`。
- 用户说“落盘 / 直接改 / 全部修复”只表示允许进入候选修复和验证链，不表示允许跳过 `repair_machine_gate` 或 `recheck`。
- 若可见回复、修复摘要或状态描述出现领域词循环，例如“修真高潮/修真节拍/修真进度”密集重复，必须按 `blocked_model_degradation` 停在最后可信断点；不得继续 Write/Edit 或生成下一步候选。

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

- `interaction_renderer` 只描述渲染偏好，不是让模型直接调用原始 AskUserQuestion。不得直接调用原始 AskUserQuestion、TaskCreate 或其他未验证 schema 的交互工具。
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

## 候选范围与题材词门禁

候选范围必须从当前项目文件推断。工作流大脑生成“补全卷纲/细纲/正文范围”候选时，必须先读取当前书目录和状态文件，识别卷内编号结构或旧扁平结构；不得使用旧书记忆、模板示例、上一次项目的卷名或固定章节段。无法确认范围时只写“当前卷缺失项”，不得写 27-50、第二卷《反击》、第X卷固定范围。

### 当前进度问答协议

工作流大脑恢复任务或回答“现在第几卷/第几章/进度/下一章”时，必须先运行 `node scripts/story-progress-status.js <book-project-dir> --json`。不得从聊天记忆、recap、旧卷纲、上一轮候选、`.book-state.json.currentChapter` 单字段或文件名直觉回答。`status=ok` 时用脚本返回的 `display/currentVolume/currentVolumeChapter/globalDraftOrder`；卷内项目只把 `globalDraftOrder` 作为括号补充，不得把它写成当前卷章号。`status=blocked_mixed_chapter_layout` 时，先进入结构迁移门禁，候选只给迁移、保持旧结构兼容和查看迁移预览，不得继续输出旧范围、旧卷名或下一章写作候选。

题材维度词必须从当前项目识别。生成候选、审阅维度、修复任务、设定文件名和范围级矩阵前，必须优先读取 `story-progress-status.js` 返回的 `domainProfile`；缺失时运行 `node scripts/story-domain-profile.js <book-project-dir> --json`。不得默认写“修真进度一致性”；也不得把“修真体系”机械替换成“力量体系”。只有 `domainProfile.primaryDomain=xiuzhen_xianxia` 或用户/项目事实明确指向修真/仙侠时才使用修真术语。未知题材使用 `domainProfile.growthAxisLabel`，通常是“能力/成长规则一致性”“战力/成长节奏一致性”“世界规则一致性”；玄幻、武侠、高武、都市异能、美食经营、魔教武侠等项目按已识别题材替换术语。

题材设定文件命名协议：

- 新建或补全设定时，默认文件名用 `设定/世界观/能力与规则.md`，不要默认创建 `力量体系.md`。
- 如果项目含武侠、魔教、心法、内功、境界身份等证据，优先命名为 `修炼与能力规则.md` 或 `武学与境界.md`。
- 如果项目含系统、技能、属性、熟练度等证据，优先命名为 `系统能力与成长规则.md`；若同时存在心法/武学，可用 `修炼与能力规则.md`。
- 如果项目含魔法、异能、赛博、经营、美食等证据，分别用 `魔法规则.md`、`异能规则.md`、`技术与能力规则.md`、`经营规则.md`、`美食能力规则.md` 等更贴合题材的名称。
- 已有项目中已经存在 `力量体系.md` 时只作为 legacy 文件读取，不主动改名；用户明确要求优化命名时，先给迁移建议并同步更新引用。

## 扩容事务协议

用户要求扩容、插章、后移、放慢节奏、把原 1-9 章扩成 20 章、或“保留原章节名和优秀正文但增加情节”时，工作流大脑必须把任务路由为 `expansion_transaction`，不得直接进入补卷纲或补细纲。

阶段顺序固定：

1. `A_expand_impact`：先做扩容影响分析，确认目标卷、插入区间、原章节资产、钩子/伏笔/人物状态影响。
2. `B_shift_map`：生成后移映射，列出旧章号、旧章名、旧路径、新卷内章号、新路径、动作和原因。
3. `C_shift_existing_assets`：先后移旧章节资产，覆盖大纲、卷纲、细纲、正文、章节契约、交接包、伏笔、时间线和角色状态。
4. `D_fill_new_gaps`：旧资产后移并验证后，才补新增缺口章节的大纲、细纲、章节契约和正文。
5. `E_recheck`：执行 Revision Stability Recheck、schema 校验和连续性复核。

扩容前必须先用 `story-progress-status.js` 确认当前书不是混合编号结构；若是 `blocked_mixed_chapter_layout`，扩容暂停，先进入迁移/兼容裁决。后移映射必须由 `node scripts/story-expansion-plan.js <book-project-dir> --volume 第X卷 --insert-after N --count K --json` 生成，不得手写固定规则。执行后移时先快照，再用 `--write` 让脚本倒序移动资产，保留新增缺口；脚本只移动旧资产和同步引用，不负责编造新增章节内容。`D_fill_new_gaps` 才能补新增章节。

如果用户只选“先修 A 级问题”或“先做 A 阶段”，完成后必须展示剩余 B/C/D/E 候选；不要使用会让用户误以为全流程已完成的含糊说法。durable task 必须保存 `remaining_stages`，防止用户以为选择 1 后整条修复流程已经完成。

## 数字选择执行门禁

用户输入 `1/2/3/4` 命中最近候选后，工作流大脑只能执行结构化选择解析，不做长篇业务推理。必须从 durable task 的 `pending_action.options[number]` 或 `next_candidates[number]` 取 action，并只写 action_id、selected_number、target_files、risk_level、next_gate。不得复述业务术语超过 2 次，不得把候选描述扩写成执行理由。

### 统一四项决策面板

所有需要作者决定“下一步”的页面统一遵守：

- 恰好显示 `1/2/3/4` 四项，不显示字母键、内部 action id、JSON 或命令参数。
- 有充分依据时只允许一个 `（推荐）`，固定排在第 1 项；没有依据时不强行推荐。
- 第 2、3 项提供真实替代路径；不足时分别使用“查看当前进度与依据”和“暂停并保存断点”。
- 第 4 项优先保留“输入其他要求”或“暂停并保存断点”，让作者无需记忆工作流术语。
- 标签只写动作和结果，详细依据在用户选择后按需展开，避免菜单本身吞掉上下文。
- 选择“暂停并保存断点”必须将 durable task、lifecycle 和正在运行的 stage_execution 一并置为 `paused`，不能只把菜单标记为 resolved。

如需落盘选择执行草稿，路径使用 `追踪/输出门禁/.selection_execution_draft_{YYYYMMDD_HHMMSS}.json` 或 `.md`，并运行 `output-pollution-check.js`。命中污染时写入 `blocked_output_pollution`，保留最后可信 pending_action，不进入写入预检；通过后再进入写入预检、影响范围确认或专业模块执行。

### 阶段启动锁

用户确认某个阶段或编号候选后，必须在读取长文件、调用 Agent、跑审阅或写正文之前，先调用 `workflow-state-machine.js resolve-action` 或写出等价状态，把 durable task 的 `stage_execution.status` 置为 `running`，并写入：

- `stage_execution.stage_id`
- `stage_execution.expected_result_packet`
- `runtime_guard.heartbeat.current_batch`
- `runtime_guard.heartbeat.latest_trusted_artifact`
- `machine.last_transition=stage_started`
- `machine.next_stop_reason=stage_running_waiting_result_packet`

这一步叫“阶段启动锁”。它不是阶段完成，也不是 result packet。它只证明用户已经确认进入该阶段，后续必须等待当前阶段的 result packet 或 checkpoint，不得再说“待确认是否先执行”。

如果阶段启动后出现长时间 thinking、recap、API error、上下文压缩或用户问“没有继续吗”，必须读取焦点 durable task 的 `stage_execution` 和 `runtime_guard.heartbeat`。若 `stage_execution.status=running` 且没有对应 result packet，回复应停在“阶段执行中 / 等待回执 / 从 checkpoint 续跑”，不得回退到“Stage A 启动前待确认”。

### 写正文只读最小上下文包（节省 token）

短篇写一节正文（`draft_first_section` / `draft_next_section`）时，**必须只读 `stage_context_packet`，不要全量读 `task.json`、完整正文、历史 result-packets、`journal.jsonl` 或 `scripts/` 源码。** 全量重读是逐节写作 token 失控的主要来源：每节都让宿主重新加载十几 KB 的任务状态、几十 KB 的历史正文和上百 KB 的历史结果包。

`buildStageContextPacket` 在托管 runner 会自动生成并注入 `追踪/workflow/tasks/<workflow_id>/context-packets/<stage>/<run>/stage-context.{json,md}`；交互模式下，用一条命令生成（不传 `--workflow-id` 时自动解析焦点任务，不传 `--stage` 时用当前阶段）：

```bash
node scripts/workflow-stage-context.js build --project-root <book-root> --json
```

包内只含本节所需的最小资产：当前 `写作Brief_第N节.md`、上一节 accepted anchor、设定与小节大纲的相关摘要、正文末尾承接片段、作者风格卡。包外资产一律不读，包括：

- ❌ 完整 `task.json`（十几 KB，含历史 result、machine、runtime_guard，写正文用不到）
- ❌ 完整正文.md（越写越大，只需承接片段）
- ❌ 历史 result-packets（上百 KB 堆积）
- ❌ `journal.jsonl`（越写越大）
- ❌ `scripts/` 源码（平台源码，写正文绝不读；转换失败用 `workflow-stage-controller.js advance`，不读源码排障）

包内预算优先来自 `runtime_guard.token_estimate.context_chars_budget`；缺失时按当前阶段必需材料的实际 token 数与可选材料余量动态计算，不使用统一的 3600 token 默认值。Brief、当前草稿、用户反馈和机器门问题属于完整语义资产，预算不足时应返回 `blocked_required_context_budget`，不得截断后继续写作。写完本节后，用上文“短篇单命令推进”把结果包推进到机器门。

非短篇或非 draft 阶段，`buildStageContextPacket` 返回 `not_applicable`，正常按各阶段协议读取必要资产即可。



## 从顶层入口迁移的首屏、短回复与候选规则

## 语言与短回复归一化

默认语言是中文：`locale=zh-CN`。用户没有明确要求英文时，确认问题、选项、状态说明和错误提示都用中文。需要英文时使用对应设置 `locale=en-US`，但短回复解释规则相同。

**用户可见输出中文优先**：宿主 UI 的内部 `thinking trace` 可能因模型或客户端实现显示英文，这不作为 skill 是否生效的验收对象；但最终回复、候选项、落盘报告和正文必须中文优先。英文只能作为技术字段名、脚本名、错误码、JSON key 或用户明确要求的英文输出。

短回复归一化必须中文优先、英文兼容；English aliases 只作为同义输入，不改变默认中文输出：

- 确认：`确认/是/好/行/可以/yes/y/ok`。
- 否定：`不/否/不用/先不/no/n/later`。
- 继续：`继续/下一步/接着/next/continue`。
- 暂停：`暂停/等等/先停/pause/stop`。
- 跳过：`跳过/先跳过/skip`。
- 取消：`取消/算了/cancel`。
- 选项：`1/2/3/一/二/三/第1项/第2项/第5项/选1/选E/e/E/选E/phase e/Phase E`。

没有待确认上下文时，短回复不能新开任务；应询问用户要继续哪个任务。存在待确认上下文时，短回复必须按最近确认点解释，不得把 `E`、`1`、`ok` 当作无意义输入。

## 短回复绑定协议

每次向用户提出需要短回复的确认点时，必须在当前上下文中绑定一个 `pending_action`。前端/runner 应持久化该对象；纯 CLI 场景至少要让最后一条可见回复清楚表达“回复 1/2/e/确认 分别代表什么”。

`pending_action` 至少包含：

```text
pending_action.type: update_environment | skill_update | phase_choice | option_choice | destructive_confirm | overwrite_confirm | pause_resume | book_select
pending_action.locale: zh-CN | en-US
pending_action.question: 本次等待用户确认的问题
pending_action.options: 可接受短回复及其含义
pending_action.safe_default: 用户否定/超时/取消时的安全默认动作
pending_action.resume_command: 后续续跑入口
```

`pending_action` 是交互状态，不是给用户阅读的正文。不得把 pending_action: 原始结构块直接打印给用户，也不要把内部 JSON/YAML、`type/locale/safe_default/resume_command` 成段暴露在 CLI 回复里。可见回复只展示问题、编号候选和一句回复方式；结构化字段写入 `tasks/<workflow_id>/task.json`，或交给前端/runner 持久化。

`safe_default` 必须是不执行写入并保存断点，或取消本次高风险动作。safe_default 必须是不执行写入并保存断点；不得写成默认选择第 1 项、默认继续写下一章、默认迁移、默认覆盖、默认修复。推荐项只能标注“推荐”，不能成为超时自动执行项。

短回复绑定优先级从高到低：

1. `destructive_confirm` / `overwrite_confirm` / 删除版本 / 覆盖正文、大纲、细纲。
2. `book_select` / 多书写入目标确认。
3. `skill_update` / `update_environment`。
4. `phase_choice` / `option_choice`。
5. 普通 `continue`。

不要同时抛出两个需要短回复的确认点。若确实存在两个确认点，必须先处理优先级更高的一个；处理完成后再提出下一个。用户输入“确认/1/e”时，只能绑定到最近且优先级最高的 `pending_action`，不能同时解释成“确认更新环境”和“选择 Phase E”。没有 `pending_action` 才回退到最近阶段表或任务列表。

## 数字候选协议

所有需要用户选择的下一步候选都必须使用纯数字编号，不要同时显示字母编号。纯 CLI 场景用普通文本呈现；前端/runner 可把同一份 `pending_action.options` 渲染为上下方向键选择列表。

候选格式：

```text
1. 继续写下一章
2. 继续审阅未完成批次
3. 继续拆文 Stage 2
4. 审查伏笔异常
```

每个选项在 `pending_action.options` 中必须包含 `number`、`label`、`action` 和可选 `description`。可隐藏支持 `一/第1项` 等中文数字别名，但可见输出不得出现 `1/A`、`A/B/C/D` 或 `Chat about this`。CLI 用户直接输入数字；前端可以用上下方向键高亮候选后提交对应 `number`。

不得依赖外部交互式选择工具实现上下键，因为不同 CLI 的工具 schema 不稳定；skill 只提供稳定候选协议。真正的方向键 UI 由前端/runner 实现。

默认最多展示 4 个可见候选，其中最后一项保留给 `输入其他要求` 或 `查看更多选项`。进入下一页后可用第 1 项返回上一页；用户始终可以不选择编号、直接输入自然语言补充要求。

每组候选必须保留自由表达出口，但它必须是一个编号选项，例如 `3. 输入其他要求`。不得在编号列表后追加无编号的业务示例、短横线示例或新的候选入口。用户想聊天、解释偏好、反驳建议、直接输入你的意见或提出别的个人意见时，绑定到这个编号选项或直接自然语言输入；前端/runner 渲染上下键 UI 时，也应提供等价的“输入其他意见”入口。

最终可见回复也要过输出健康门：如果摘要、下一步候选、自由输入提示或 recap 风格状态句中出现领域术语循环、SSOT 词组循环、阶段标签循环或已学习污染词组，必须写入 `追踪/输出门禁/.visible_reply_draft_{YYYYMMDD_HHMMSS}.md` 并运行 `output-pollution-check.js`；命中污染时丢弃原回复，只输出干净的短候选和报告路径。

### 旧审阅批次重新验收后的连续执行

用户已确认“重置旧批次并重新验收”时，这次确认覆盖从首个失效批次到原审阅 workflow 的授权边界。状态机返回 `review_batches_reset` 后，必须读取并执行 `next_command`；不得返回任务收件箱首页，不得再次调用 `workflow-entry-guard.js`，也不得把“查看未完成任务”重新展示给用户。

当应用新版批次回执后返回 `batch_advanced + must_continue=true + continuation_policy=finish_authorized_workflow`，必须依次完成所有剩余批次。机械证据扫描、结果包落盘和下一批推进不再逐批确认；进入归类、综合报告和后续非高风险审阅阶段后也继续原任务。仅在需要用户选择修复范围、将要修改正文/大纲、质量门阻断、provider/预算阻断或 workflow 已完成时停靠。

Claude CLI 的 `※ recap` 只能作为宿主提示，不是 novel-assistant 的工作流状态。不得把 recap 当作工作流事实源，也不得用 recap 里的行数、字数、破折号数量、章节完成度、下一步描述直接触发阻断或继续任务。凡涉及进度、落盘状态、质量门禁、行数、字数、破折号数量、章节编号和下一步候选，必须重新读取项目文件或运行确定性脚本确认。

## 候选范围与题材词门禁

候选范围必须从当前项目文件推断，不得凭空输出 27-50、51-80、第二卷《反击》这类旧书记忆或模板范围。生成“补全卷纲/细纲/正文范围”候选前，必须先读取当前书的目录结构和状态文件：卷内编号结构优先使用 `大纲/第X卷/卷纲.md`、`大纲/第X卷/第001章*.md`、`正文/第X卷/第001章*.md`；旧扁平结构才回退到 `chapterNNN.md` 或 `细纲_第NNN章.md`。如果无法从文件系统确认范围，只能写“补全当前卷缺失卷纲/细纲”，不能写具体章节号。

### 当前进度问答协议

用户问“现在是第几卷”“还是第一卷吗”“写到第几章”“当前进度是多少”“下一章是哪章”时，必须先运行：

```bash
node scripts/story-progress-status.js <book-project-dir> --json
```

不得从聊天记忆、recap、旧卷纲、上一轮候选、`.book-state.json.currentChapter` 单字段或文件名直觉回答。返回 `status=ok` 时，卷内项目必须按 `currentVolume + currentVolumeChapter` 可见表达，例如“第2卷第006章（全书草稿顺序第32章）”；可以补充全书草稿顺序，但不能把全书顺序说成卷内章号。返回 `blocked_mixed_chapter_layout` 时，先提示“当前书目是卷目录 + 全书连续编号的混合结构”，候选只给 `1. 迁移到卷内编号结构`、`2. 保持旧结构兼容`、`3. 查看迁移预览`；不得继续说“第二卷第27-32章”“32/50章”或继续写第33章。迁移预览必须来自 `story-project-migrate.js <book-project-dir> --json` 的 dry-run 结果，不得手写固定三类文件；预览应覆盖正文、大纲/细纲、章节契约、交接包、漂移门控、context-pack，以及大纲、伏笔、时间线、上下文、角色状态、章节索引等引用更新。

题材维度词必须从当前项目识别。只有用户明确说“修真/仙侠/境界/化神”等，或项目设定、正文、追踪文件中存在稳定题材证据时，候选才可写“修真进度一致性”。未确认题材时使用能力/成长规则一致性、战力/成长节奏一致性、世界规则一致性等中性说法。不得把“修真体系”机械替换成“力量体系”；玄幻、武侠、高武、都市异能、美食经营、魔教武侠等项目必须替换为相应题材词。

补字/扩写细节不得默认修真。用户说字数不够、扩写实战、展开动作、丰富细节时，只有题材证据明确为修真/仙侠才可写“修真实战细节”；否则使用“能力运用、动作交锋、环境压力、厨艺动作、人物反应”等中性或本书专属词。书名含“魔教/江湖/圣女/系统/美食”不等于修真，必须回读本书 `设定/题材定位.md`、`设定/世界观/能力与规则.md` 或现有同义设定文件（如 `修炼与能力规则.md`、`武学与境界.md`、legacy `力量体系.md`）、卷纲和细纲后再下术语。

设定文件命名也必须题材化。新建/补设定默认使用 `设定/世界观/能力与规则.md`，不要默认创建 `力量体系.md`；魔教/心法/系统项目优先使用 `修炼与能力规则.md`，武侠项目可用 `武学与境界.md`，系统流可用 `系统能力与成长规则.md`。已有 legacy `力量体系.md` 只读取和兼容，用户要求优化命名时再迁移引用。

## 扩容事务协议

用户提到扩容、插章、后移、放慢节奏、把某卷从 N 章扩成 M 章、保留原章节名但增加情节时，必须先做扩容影响分析，再路由到 `story-workflow` 的 `expansion_transaction` 和 `story-long-write` 的扩容事务协议。

顶层候选不得写成“补全第二卷 27-50 章卷纲”这类直接填洞。正确候选应表达为：

```text
1. 做当前卷扩容影响分析
2. 生成原章节后移映射
3. 审阅扩容后新增缺口
4. 暂停并保存断点
```

只有后移映射和版本快照完成后，才能补新增缺口。原章节名和可用正文资产默认保留；大纲、卷纲、细纲、正文、章节契约、交接包、伏笔、时间线和角色状态必须随后移同步。

扩容与迁移是两种不同动作：迁移章节结构解决旧编号/混合编号；扩容解决新增情节导致后续章节整体顺延。执行扩容前必须先运行 `node scripts/story-progress-status.js <book-project-dir> --json`；如果返回 `blocked_mixed_chapter_layout`，先处理迁移或保持旧结构兼容，不得直接后移。结构确认后，运行 `node scripts/story-expansion-plan.js <book-project-dir> --volume 第X卷 --insert-after N --count K --json` 生成后移映射；用户确认并完成版本快照后，才允许用 `--write` 执行后移。`story-expansion-plan.js` 的缺口范围只表示待填充章节，不能自动生成新章内容；旧章节后移验证通过后，再补新增章节的大纲/细纲/契约/正文。

## 数字选择执行门禁

用户回复 `1/2/3/4` 后，只解析 action_id，不得展开长篇理由、不得复述整段候选描述、不得在“用户选择了 X，所以……”后继续生成业务术语解释。正确流程是：读取最近 `pending_action.options[number]` -> 记录 `selected_number`、`action_id`、`target_files`、`risk_level` -> 进入写入预检或对应模块。

数字选择是执行契约，不是语义建议。候选如果写着“只写第 6 节停下”，则该选项必须包含 `target_scope=第6节`、`max_units=1`、`stop_after=第6节` 或等价边界；用户输入 `2` 后必须先用带当前 `pending_action_id`、`visible_choice_hash` 和 `state_version` 的 `scripts/workflow-state-machine.js resolve-action --input 2` 或等价写入，把 `last_selection` 固化到 durable task。之后只能执行该选项，不能改解读成“暂停看 4-5 节”、不能连写 6-7 节、不能因为相邻选项文字相似而串线。

如果没有有效 `pending_action`、候选已过期、当前项目路径不匹配、或选项没有足够执行边界，必须重新展示候选或问一句澄清；不得凭聊天记忆执行裸数字。

如果执行前需要形成选择执行草稿，只允许写短 JSON/表格，字段不超过 `selected_number/action_id/target_files/risk_level/next_gate`。选择执行草稿必须过 `output-pollution-check.js`；一旦出现术语循环或模型退化，立即停在 `blocked_output_pollution`，保存断点，不继续思考和不继续写入。

## 交互恢复协议

用户偏好的上下方向键选择体验应由前端/runner 恢复，而不是由 skill 直接调用外部交互工具。每次输出候选时，必须同步形成可恢复的 `pending_action`：

```text
pending_action.render_mode: text_numbers
pending_action.fallback: text_numbers
pending_action.page_size: 4
pending_action.page: 1
pending_action.free_text_enabled: true
pending_action.options[].number / label / action / description
```

runner 可在 `interaction_renderer=host_select_preferred` 且当前宿主支持稳定选择器 schema 时，把底层 `render_mode=text_numbers` 渲染为上下方向键列表；如果选择器不可用、参数校验失败或宿主返回 schema 错误，继续使用 `fallback=text_numbers`，不把 Invalid tool parameters 暴露给用户。skill 自身不得调用 AskUserQuestion、TaskCreate、TodoWrite 或选择器工具来实现上下键。

维护动作不属于默认下一步候选：启动自检已经负责检查更新；协作环境更新完成后，默认候选不要列出“检查更新/更新本地 skill/迁移章节结构”。这些只在用户明确要求“检查更新、更新 skill、迁移结构、重新部署”时进入维护协议。

更新完成后的候选应分成两类：继续未完成任务，或开启新的任务。继续未完成任务必须来自落盘状态，例如 `追踪/workflow/tasks/*/task.json`、`追踪/review-state.json`、拆文 `_progress.md`、`.active-book`、章节交接包、伏笔异常清单；开启新的任务可以列“写作 / 审阅 / 拆文 / 修复”四类业务入口。不得自动替用户推进旧任务，也不要把旧任务的第一个 pending 项当作默认执行项。

不要让用户另开窗口来处理普通任务分流。可说“稍后处理”“另建任务断点”“保留为后续任务”，但不要输出“另开窗口/另开 Claude 会话”作为默认流程；只有 skill 更新导致 agent/rule 重载必须重启时，才提示新开会话。

结构迁移门禁优先于普通任务候选：如果 skill 更新或写作协作环境更新后检测到目录结构策略变化、旧扁平结构、混合结构、或可迁移文件，必须先让用户选择 `1. 迁移到卷内编号结构` 或 `2. 保持旧结构兼容`。用户选择前，不展示继续未完成任务或开启新任务候选。选择保持旧结构兼容时，应落盘兼容决策，例如 `chapterLayout=flat`、`allowLegacyFlat=true`、`migration_status: skipped_by_user`，后续写作按旧结构解析，不反复提示。
