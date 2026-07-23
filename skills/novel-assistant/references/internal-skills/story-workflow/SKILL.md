---
name: story-workflow
description: |
  网络小说工具箱内部工作流编排器。用于拆文、写作、审阅、回炉、去 AI 味、导入、扫榜等多步骤任务需要阶段计划、断点续跑、下一步候选和项目级工作流记忆时。
---

# story-workflow：内部工作流大脑

`story-workflow` 是 `novel-assistant` 的内部工作流大脑。它只负责编排：把用户目标转成可执行、可恢复、可验证的阶段计划；专业判断、正文生产、审查结论和拆文分析仍由目标模块完成。长篇专业模块只依附 `story-workflow` 的 Workflow Packet 与 Result Packet；模块间不直接调度，也不向用户暴露内部 `story-*` 调用。

边界必须明确：不得直接写正文，不得替代 story-long-write，不得替代 story-review，不得替代 story-long-analyze，也不得替代 story-deslop、story-import、story-cover 等专业模块。

用户仍只调用 `/novel-assistant`。本 skill 由 `story` router 内部读取，不作为用户需要记住的新命令。

## 共享维护契约

本模块遵守 [references/maintainability-kernel.md](references/maintainability-kernel.md)、[references/workflow-contract.md](references/workflow-contract.md)、[references/output-safety-contract.md](references/output-safety-contract.md)、[references/token-cost-governance.md](references/token-cost-governance.md)、[references/model-provider-profiles.md](references/model-provider-profiles.md)、[references/quality-debt-policy.md](references/quality-debt-policy.md)、[references/structured-intent-routing.md](references/structured-intent-routing.md)、[references/story-assets-ledger.md](references/story-assets-ledger.md)、[references/style-asset-engine.md](references/style-asset-engine.md)、[references/review-escalation-policy.md](references/review-escalation-policy.md) 和 [references/story-load-bearing-contract.md](references/story-load-bearing-contract.md)。维护架构、L2/L3 交接、运行边界、输出污染、工具污染、写入失败处理、成本决策映射、provider/model profile、质量债务、结构化意图、角色事实资产、写法资产、审阅升级策略和跨模块故事承重语义以这些内核契约为准。

## 核心职责

1. 识别任务类型：拆文、开书、日更、回炉、扩容、审阅、修复、扫榜、导入、去 AI 味、短篇、封面。
2. 制定阶段计划：每个 workflow 必须有 `A/B/C` 阶段和 `A1/A2/A3` 步骤。
3. 明确 `completion_policy`，并按策略决定自动推进或停靠确认。
4. 维护创作单元生命周期与工作流记忆；每次暂停、完成阶段、遇到阻塞时，输出下一步候选。
5. 防止伪完成：完成条件、验证门禁、最终收束都通过后，才可声明 workflow 完成。

`story-workflow` 是所有专业模块唯一的生命周期与可见交互内核，不是短篇专用协调器。长篇、短篇、审阅、修复、拆文、扫榜、导入、去 AI 味和封面只拥有各自的阶段实现；阶段结束后必须把 result packet 交回全局状态机。状态机自动续跑已确认的安全内部步骤，并在真正需要作者判断时统一返回 `1/2/3/4` 数字菜单。任何子 skill 都不得用自由文本替代这一结果。

已确认阶段遵循原子收束不变量：`读取最小上下文 -> 生成或修订暂存产物 -> 执行阶段完成命令 -> 接受结果包 -> 自动进入下一安全阶段或显示数字菜单` 必须在同一轮完成。暂存产物存在但结果包缺失时，workflow 仍处于运行中，任何模块都不得向用户回复“只差提交命令”。内部质量恢复有界执行；连续两次仍无法收束时才保存断点并返回统一恢复菜单。

## 全局 Workflow / Memory 内核

`story-workflow` 是所有专业模块共享的全局编排层；`story-memory` 是需要记忆装配阶段的统一决策层。这里的“全局”不是把所有记忆塞进每次提示词，而是每个阶段都必须经过同一个 Runner 决策点：
记忆装配、建议录入与确认边界必须渐进加载 `references/internal-skills/story-memory/SKILL.md`；全局 runner 在接受 result packet 后统一调用 `context-assembler.js` 和 `memory-recommender.js`，专业模块不得自建第二个全局记忆入口。

1. `workflow-state-machine.js` 锁定 `workflow_id`、作品根目录、范围、阶段和 owner。
2. 同一用户目标的重试、重规划和多会话恢复必须归入一个 `task_family_id`：只有主分支可接受 result packet；其他会话只读，确认接管后才成为写入者。
3. 检测到受支持的 oh-story/旧版 novel-assistant 项目尚未具备任务族账本时，先展示迁移预览；只有用户确认后调用 `task-family-migrate.js --write --confirm`。迁移不得修改正文、大纲、细纲、设定或审查正文资产。
4. `workflow-runner.js` 读取 `scripts/lib/workflow-memory-policy.js`，得到 `required | optional | none`。
5. `required/optional` 阶段调用 `context-assembler.js`，生成绑定 `workflow_id + scope` 的 context packet；`none` 也必须在 runner packet 中留下明确决策，不能靠模块猜测。
6. L3 只读取 runner packet 和装配后的记忆，不广泛扫描项目，也不凭 recap/chat 恢复事实。
7. result packet 被状态机接受后，Runner 才处理允许的 `memory_updates`：安全新增可投影，高风险建议等待确认，污染建议进入任务隔离区。短篇正文生命周期改用单一 `stage_context_packet`：专业短篇模块声明本节 `Memory Query`，`story-memory` 从已接受小节事务、当前作品事实、未闭合承诺与已确认声口规则生成“当前作品记忆快照”；workflow 只持有 `Memory Contract` 引用并校验 `memory_read_receipt`，不得读取后再自行改写事实。下一节 Brief 绑定该记忆版本，相关事实变化只使受影响 Brief 失效，无关未来事实不触发重建。故事质量门再次核验本阶段回执，采用事务在正式写入前最后核验；采用时过期必须保留候选稿并回到当前节质量复核。当前作品接受事件写入 `追踪/integration/outbox.jsonl`，不在 skill 内承担跨作品学习。

长篇生产必须保持同一条受控链：`拆文剧情单元 -> 本书剧情单元 -> 细纲读者体验合同 -> current-contract -> Chapter Contract -> accepted chapter commit -> 伏笔/记忆投影`。专业模块可以生成候选，但不得跳过 workflow 直接改正式正文、伏笔状态或终局储备；`promise_deltas` 只有随 accepted chapter commit 才能成为事实。扩容、插章、后移和缩并统一进入**扩容事务协议**：先生成后移映射，再补插入缺口，不得直接进入补卷纲或补细纲；同时检查剧情承接矩阵、钩子/伏笔矩阵、人物状态矩阵、主线承诺-兑现矩阵与**设定/能力与规则矩阵**。仅当项目题材证据为修真/仙侠时才命名为修真进度矩阵。具体步骤按需读取 `task-inbox-protocol.md` 和长篇扩容协议，不在入口重复加载。

多个任务可以同时未完成。`current-task.json` 只表示当前会话焦点，不代表唯一任务；任务权威副本位于 `追踪/workflow/tasks/<workflow_id>/task.json`。切换新目标只暂停旧焦点并保留断点，只有用户明确终止/放弃时才允许 supersede、cancel 或归档。

工作流控制面直接通过 `TaskStore` 与 `UserProfile` 查询任务和交互偏好，并且只读取 StoryMemory 的计数/版本摘要。`current-task.json` 不能作为任务事实源，剧情记忆也不能用于推断任务是否完成。当前本地后端和未来 `novel-project` PostgreSQL 后端必须遵循同一 repository 契约；同时存在时只允许一个 authority，另一端经幂等 outbox 同步。

## 全局任务收件箱与新项目分流

启动统一由全局任务收件箱处理：`workflow-entry-guard.js` 生成首屏，`workflow-task-inbox.js` 在 `metadata_only` 策略下汇总 `task-index.json`、`workflow_groups`、`smart_new_task_recommendations` 与 `post_completion_recommendations`。短篇的启动恢复经验必须提升为全局能力：已落盘的素材、卡池、草稿和任务可恢复；只存在聊天上下文、从未落盘的内容不得伪装成可恢复任务。但运行时为检查而生成的空 `追踪/workflow/`、`entry-guard.json`、`task-index.json` 不是作品资产，不能让空目录误入收件箱。

任务收件箱只能负责定位任务，不能把状态摘要当作流程终点：恰好只有一个未完成且已聚焦的任务时，“查看未完成任务”必须直接返回该任务当前阶段的四项动作；存在多个任务时先返回任务列表，用户选择并激活后立即投影所选任务动作。所有非终态可见页都必须给出可执行迁移，禁止只显示作品名、阶段、最后可信产物后等待用户再次猜测。

当没有正文、大纲、设定、短篇卡池、`.book-state.json` 或真实任务快照时，状态必须是 `new_project_ready / show_new_project_onboarding`：只展示“新开长篇 / 新开短篇 / 导入或拆文 / 输入其他目标”，不得显示“查看未完成任务（0 个）”。未初始化目录不得展示任务收件箱。只有存在真实创作资产或 `追踪/workflow/tasks/<workflow_id>/task.json` 时，才把目录视作当前作品并显示任务收件箱。

## 按阶段读取协议

不要在启动时一次性加载下列重协议。先根据当前阶段读取必要的一个或多个 reference；协议文件中的硬约束与示例是本模块的规范正文，不得用摘要替代。

| 当前阶段或事件 | 必读协议 | 目的 |
|---|---|---|
| 首屏、任务恢复、收件箱、数字输入、状态机选择、阶段启动 | [task-inbox-protocol.md](references/task-inbox-protocol.md) | 只用落盘状态恢复任务，并保持首屏与候选语义。 |
| 生命周期推进、runner、agent、工具调用、授权、压缩交接、成本 | [runner-execution-protocol.md](references/runner-execution-protocol.md) | 执行已确认阶段，控制工具失败、并行写边界和成本。 |
| 任何 canonical 资产、短篇正文、候选稿、写入失败、事务接受 | [canonical-write-protocol.md](references/canonical-write-protocol.md) | 以候选稿和 `chapter-commit.js prepare/accept` 完成正式资产接受。 |
| 恢复、L2/L3 packet、验证、模板收束、最终完成声明 | [completion-evidence-protocol.md](references/completion-evidence-protocol.md) | 用已存在的可信证据恢复或收束，不把预期产物当完成。 |

### 阶段化契约索引

首屏只读取上表及 `task-inbox-protocol.md`；阶段确定后，按需读取[phase-protocol-index.md](references/phase-protocol-index.md)中的兼容锚点，再读取对应协议正文。不得为了“保险”一次性加载全部协议、示例或历史锚点。

## 阶段路由

1. 更新确认已收束后，先读取 `task-inbox-protocol.md`，执行 `workflow-entry-guard.js`，并根据真实状态决定首屏、恢复或业务路由。
2. 需要创建、恢复、推进、阻塞或解析编号时，仍以 `workflow-state-machine.js` 为权威；进入执行前读取 `runner-execution-protocol.md`。
3. L3 只执行 packet 指定的专业模块。若结果涉及正式资产或短篇根资产，必须先读取 `canonical-write-protocol.md`；事务证据不足不得写入或关闭阶段。
4. 应用 result packet、处理缺失回执、生成完成声明或下一步候选前，必须读取 `completion-evidence-protocol.md`。
5. 任何状态不依赖聊天记忆；`追踪/workflow/current-task.json`、任务目录、收件箱和结果回执是恢复依据。

### 已授权审阅的连续执行

用户确认重新验收旧批次后，`reset-incompatible-review-batches` 返回 `review_batches_reset + must_continue=true + continuation_policy=finish_authorized_workflow`。此时不得再次调用 workflow-entry-guard.js，不得返回任务收件箱首页，也不得逐批询问“是否继续”。必须执行 `next_command`，把扫描结果写成状态机要求的新版回执并应用；返回 `batch_advanced` 时继续执行新的 `next_command`，依次完成所有剩余批次。只有 `workflow_completed`、真正需要用户裁决或质量/运行阻断时才停靠。

范围审阅的证据扫描只能执行状态机返回的 `next_command`。该命令会由 `review-batch-evidence-scan.js` 自动完成扫描、证据文件写入、唯一 result packet 生成和 `apply-result`；专业模块或主会话不得手工 Write/Edit result packet，不得补 `sourceDigest`、`changed_files`、`fullRangeCoverage` 或用临时脚本拼 JSON。脚本返回 `applied` 后直接读取其下一批 continuation；返回 `apply_blocked` 才报告结构化阻断原因。

批量修复不得在书目目录自建 `apply-*.js`、平铺复制正文到单一备份目录，或直接对 `正文/` 执行全量替换。正确执行链为：先从 `repair_execution_plan.result.json` 读取目标文件和阶段；按原卷目录保存可回滚版本；每个修复单元生成候选稿并通过机器门；用户确认后经章节事务提交正文、状态变化和回执；最后复检。若任务已标记完成但 `machine.completed_stages` 漏掉必经阶段，使用 `restore-incomplete-workflow --confirm` 只恢复工作流状态，再由作者确认继续，绝不新建一个替代审阅任务。

旧批次不符合当前协议时必须提供两条同级业务路径：`重新验收旧批次并继续原任务`，或 `保留旧证据并从下一批继续`。后一条只能由 `continue-review-with-legacy-evidence --confirm` 执行：旧范围标记为 `completed_with_warning`，写入 `review_quality_debt`，最终报告必须披露并建议复核；随后直接启动下一未完成批次。不得把“不重跑”解释为取消原任务、返回首页或把旧证据伪装成新版验收通过。

## 文件化任务计划协议

工作流记忆保存于 `追踪/workflow/current-task.json`、`追踪/workflow/current-task.md`、`追踪/workflow/history.jsonl` 和 `追踪/workflow/preference-memory.jsonl`。任务卡只保存任务标题、阶段、范围、最后可信产物、停靠原因、下一步候选与必要上下文引用；人物、伏笔、设定和作者声口由 `story-memory` 按 packet 显式装配。

## 输出边界

用户可见输出中文优先，不以宿主 UI 的 thinking trace 语言作为验收对象；英文只能作为技术字段名、脚本名、错误码、JSON key 或用户明确要求的英文输出。内部可用 `SSOT` / `ssot`，但对用户展示时改写为“权威设定”“设定基准”“唯一设定源”；`user-facing-jargon-leak` 先触发中文重写与复扫，只有同时命中硬污染时才进入阻断模板。完整词汇映射、污染处理和可见回复门禁见 [output-safety-contract.md](references/output-safety-contract.md)。

## 运行时巡检接口

运行时巡检与状态机命令由 [task-inbox-protocol.md](references/task-inbox-protocol.md) 定义；长任务和 result packet 在推进前必须经过 `runtime-guard-validate.js`，阻塞状态词表、模板和 L2/L3 packet 字段由 [completion-evidence-protocol.md](references/completion-evidence-protocol.md) 定义。不要把 runner 或专业模块的 `Done` 当作完成；只有已声明验证通过的证据才允许 `verification_result=pass`。
