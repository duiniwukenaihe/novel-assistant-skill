# Story Memory Contract

`story-memory` 是通用记忆层。它解决“哪些记忆进入当前任务”和“哪些新信息可以沉淀”，不解决“故事怎么写”。

## Lifecycle

| 阶段 | 动作 | 结果 |
| --- | --- | --- |
| read | 读取 `lorebook.jsonl`、`active-cast.json`、任务 RPD、偏好和领域学习账本 | 得到候选记忆 |
| compact | 按任务、目标范围、触发词、来源证据、token budget 压缩 | 得到当前任务小包 |
| inject | 把 `assembled-context.md` 写入 workflow packet | 领域子 skill 只读此包 |
| write | 产物被接受后，记录 `memory-suggestions.jsonl` | 形成待确认或可自动应用的建议 |

accepted chapter commit 可以显式携带 `facts`。`projectAcceptedFacts()` 只接受一个已标记 accepted 的 commit/result 引用，并必须用其中的 `commit_id` 回读 `追踪/story-system/commits/<commit_id>.json` 中真实落盘且 `status=accepted` 的 commit；调用方 packet 内联携带的 `facts` 一律不可信、不得投影。不得扫描 packet 的 `content`、正文、设定、上下文或其他 prose 推断 canonical facts。落盘 accepted commit 没有显式 `facts` 数组就不产生事实事件。

事实字段固定为 `fact_id`、`subject`、`predicate`、`object`、`aliases`、`dependencies`、`scope`、`valid_from`、`valid_to`、`evidence`、`provenance`、`confidence`。每条事实必须至少携带一项可定位的 `evidence.path`，且 provenance 必须记录 accepted commit/result、workflow 与 task family 身份。缺证据的事实拒绝投影。

`facts.jsonl` 是 append-only 事件流。同一 `subject + predicate + scope` 出现不同 `object` 时，旧 active 事实追加一条 `superseded` 事件并以新 commit 写入 `valid_to`，原始事件与 provenance 继续可读；新事实成为唯一 active 版本。上下文装配只读取每个 `fact_id` 的最新 active 且 `valid_to=null` 事件，因此矛盾历史不能进入 active context。

旧项目先通过 `memory-migrate.js` 把角色状态、伏笔、上下文、最近交接包和作者风格文件投影为带 `sourceRefs.hash` 的记忆。迁移只写 `追踪/memory/`，不修改原始创作资产，并且必须幂等。章节接受后使用 `--source <relative-path>` 只刷新本次变化来源，旧版本追加 `superseded` 事件，新版本保持同一稳定 ID 并递增 `version`。

### 来源身份与刷新边界

- 仅由用户显式运行 `memory-migrate.js` 的受信命令入口产生的迁移快照，才使用 `id` 与 `memory_id` 为 `legacy.<type>.<stable-source-identity>`、`source_kind=legacy`、`migrated=true`。普通调用不得用 `migration.source_kind=legacy`、`sourceKind=legacy` 或缺少 authority 自动降级成 legacy；chapter manifest 的同名字段也不是迁移凭据。来源哈希陈旧时必须再次显式运行迁移命令，`context-assembler.js` 只阻断并报告来源，不自行刷新。
- 已接受章节事务投影的来源使用 `id` 与 `memory_id` 为 `canonical.<type>.<stable-source-identity>`、`source_kind=canonical`，不得写入 `migrated=true`。投影前必须按 `workflow_id` 读取 durable `task.json`，复验 `task_family_id`、`branch_id`、`stage_attempt_id` 与当前 stage execution；缺失或不一致一律阻断。它们保留 accepted commit、任务族、生命周期和 `sourceRefs` 证据，但绝不是来源级自动刷新的候选。
- 历史 `legacy.* + migrated=true + acceptedCommitId` 条目仍兼容读取；一旦来源 hash 陈旧，必须以 `blocked_memory_stale` 要求受控的接受/投影流程处理，禁止自动刷新或把它重新标记为迁移资料。
- accepted canonical 来源按规范化 `type + sourceRefs.path` 的稳定来源身份查找历史 accepted legacy 前任，不能按完整 `memory_id` 匹配。找到前任时追加保留其 provenance 的 `superseded` 事件，以新 commit 关闭 `valid_to`；canonical 成为唯一 active。同源 canonical 已存在后，旧 stale legacy 历史不得再阻断上下文装配。

## Lifecycle Context

长篇任务使用以下完整身份装配记忆：

```json
{"node":"chapter_commit","book_id":"book-id","volume_id":"第2卷","stage_id":"stage-03","chapter_id":"v02-c007","task_family_id":"family-id","workflow_id":"workflow-id"}
```

`memory_sources` 固定按 `book -> volume -> stage -> chapter -> task` 输出，且只包含当前节点允许的层级：

| 节点范围 | 可见层级 |
| --- | --- |
| 定位、故事核心、总纲/总纲审阅、全书验收 | `book`, `task` |
| 卷纲/卷纲审阅、卷级验收 | `book`, `volume`, `task` |
| 阶段细纲/审阅、阶段复盘 | `book`, `volume`, `stage`, `task` |
| Brief、正文、正文验收、章节提交 | `book`, `volume`, `stage`, `chapter`, `task` |

层级允许后仍须匹配对应 `book_id/volume_id/stage_id/chapter_id/task_family_id`；卷纲审阅不能因为触发词命中而加载其他卷的章节正文。

accepted chapter transaction 的增量投影必须记录 `lifecycleNode`、`bookId`、`volumeId`、`stageId`、`chapterId`、`taskFamilyId`、`workflowId`、`acceptedCommitId`。新版本以 commit ID 写入 `valid_from` 且 `valid_to=null`；被替代版本写入同一 commit ID 作为 `valid_to` 并转为 `superseded`。

active memory 只接受正式接受且仍有效的来源。`acceptance_status != accepted`、任务族非主分支、`valid_to` 已关闭、source hash 陈旧、污染命中或非 `active` 状态都必须在装配前排除；兼容旧项目的 `legacy_unbound` 条目不能冒充带任务族来源的新投影。

## Deterministic Retrieval And Budget

生命周期、scope、provenance 与 validity 过滤完成后，中文事实检索按固定优先级排序：精确 aliases 命中第一，已命中事实的 dependency/causal adjacency 第二，规范化 Han bigram overlap 第三。同分时按稳定 ID 排序。检索结果必须返回原事实的 evidence；没有 evidence 的候选不能注入。

上下文总预算由 `context-budget.js` 统一分配。候选在原始 rank 之上按当前 workflow memory layer 的距离和 unresolved dependency count 动态加权，随后仍服从 mandatory source 与总 token budget。不得以每条 lore/fact 的固定截断作为主要策略，也不得引入 embeddings、向量数据库或外部检索服务。该排序与预算规则不扩大任何 lifecycle 可见层级。

## Chat Feedback To Story Memory

聊天意见不能直接等同于作品事实。短篇反馈按四层流转：

| 层 | 落盘位置 | 是否注入写作上下文 | 升格条件 |
| --- | --- | --- | --- |
| 待处理意见 | 当前任务 `feedback-inbox.jsonl` | 否 | 完成影响分析 |
| 已接受规划约束 | `追踪/memory/planning-constraints.jsonl` | 仅相关小节 | `素材卡.md` / `设定.md` / `小节大纲.md` 已实际回写并验收 |
| 已接受故事事实 | `追踪/memory/facts.jsonl` | 按范围召回 | 正文已经采用并产生可信锚点/提交 |
| 审计历史 | 任务日志、旧回执、superseded 事件 | 否 | 不升格，只用于追溯 |

在“待处理意见”和“已接受规划约束”之间必须存在任务级 `accepted_plan`：助手先把讨论收束为带稳定 ID 的方案草案；用户回复“采用/按上述方案执行/1”后，将该方案标记为 `accepted_pending_projection`，记录受影响资产、小节、Brief、正文复检清单及顺序。它用于跨会话恢复和驱动回写，但在规划文件尚未修改并验收前，不进入当前小节写作快照。规划回写通过后状态变为 `projected_to_canonical_memory`，再生成正式 planning constraints。

任何 `memory_updates` 在写入前必须做领域分类。故事事实、规划约束、作者偏好、风格规则和带来源的学习技巧进入各自记忆域；工作流路由、任务状态、菜单、会话租约、安装与 bundle 信息属于控制域，只能隔离到任务审计，禁止进入 lorebook 或写作上下文。

每节采用事务的事实投影至少支持：本节事件摘要、实际出场人物、揭示信息、人物状态、人物关系变化、人物认知边界、世界状态、主角关键选择、因果推进、承诺变化和开放钩子。具体字段为空时不得从正文猜测；由故事质量门在 `acceptance_metadata` 中显式返回，提交事务绑定正式小节路径与内容 hash 后才生效。

规划约束必须保存用户确认的最终方案快照、受影响小节、规划文件及其 hash、workflow/feedback/proposal/result 身份。原始聊天保留在任务审计中，但不得替代最终方案进入写作上下文。规划文件再次变化后，旧约束自动变为 stale，不得继续注入。规划回写接受后由 `feedback_revision_queue` 驱动受影响小节逐一重建 Brief、复检正文和重新采用；队列状态属于 workflow，不属于事实记忆。

工作流可直接查询 memory repository，但只能读取当前 workflow、任务族、章节范围和生命周期允许的视图；专业子 skill 只接收 workflow 编译后的最小记忆快照，不得自行扫描全部 memory 文件。

### 全篇总编辑反馈的记忆边界

短篇 `full_story_review` 的审阅卡和问题项属于任务工作记忆与审计证据，不是故事事实。`decision=revise` 时，状态机把每条 finding 以 `source_kind=editorial_review` 写入当前任务 feedback inbox，并进入 `feedback_impact_sync`：

1. 总编辑 finding 只说明“哪里可能有问题、证据是什么、应回哪一层”，不得直接注入下一节正文上下文。
2. 助手收束为修订方案并经用户确认后，才形成 `accepted_plan`。
3. 设定/小节大纲实际回写并验收后，才投影为 planning constraints。
4. 受影响小节重建 Brief、正文复检并重新采用后，才由小节事务更新 canonical facts、人物状态、关系、因果和钩子。
5. 内部协议 `decision=pass` 对作者统一展示为“故事层可进入表达清理”，不能写成含混的“作品通过”或“已经完成”；它只保存审阅回执和正文 hash，用于证明发布前故事门已通过，“审阅通过”本身不得成为世界观或人物事实。

这样既能让 memory 驱动后续修订，又不会把审稿意见、猜测或未确认方案伪装成故事 canon。

## Risk Policy

- 低风险新增：只新增旁支事实、局部钩子提醒、已接受章节中的明确复用点；可由 `--apply-low-risk` 写入。
- 高风险：改变 canon、人物认知边界、伏笔时点/回收、成长/经营/力量规则、章节编号、用户风格偏好；必须用户确认。
- 用户确认优先于自动学习；当前请求优先于历史偏好。
- 记忆建议不能静默改正文、大纲、细纲、设定或追踪创作资产。

## Blocking Status

- `blocked_memory_conflict`：记忆条目互相冲突，或与当前任务硬约束冲突。必须让用户确认保留哪条，不能继续写。
- `blocked_output_pollution`：记忆条目、任务 RPD、候选建议或装配包出现模型循环、工程词泄露、工具日志污染。必须先隔离污染。
- `blocked_memory_stale`：来源哈希变化、手工记忆、来源消失、污染或冲突导致当前记忆不可安全注入。由迁移器生成且权威来源可读的条目也先阻断，用户显式运行 `memory-migrate.js --source <path> --write` 后再重新装配。
- `blocked_book_write_locked`：章节接受或另一次记忆投影持有书目级写入租约。当前操作保持只读并稍后重试，不能绕过锁另写 lorebook。

## Suggestion Lifecycle

建议使用稳定 `suggestionId`，状态为 `pending -> applied | rejected | superseded | stale`。低风险新增可自动应用；高风险建议必须通过 `--confirm <id> --decision apply|reject` 处理。应用操作向 lorebook 追加新版本并写审计事件；不得让旧 pending 在下一次运行中再次应用或反复请求确认。

所有会改变 `追踪/memory/` 的显式迁移与 canonical 投影都必须取得书目级写入租约；章节事务已经持锁时通过内部 `leaseHeld` 传递所有权，禁止同一进程重复加锁。

## Domain Ownership

- `story-workflow`：任务生命周期、pending action、下一步候选、恢复。
- `story-memory`：记忆协议、上下文装配、建议记录、低风险应用。
- `private-short-extension`：短篇资讯学习、爆点卡、平台信号、素材血缘。
- `story-long-write`：长篇人物、伏笔、设定、章节连续性如何使用。
- `story-deslop`：作者声口、禁用表达和污染规则如何作用到文本。

专业子 skill 只有 Result Packet 建议权，没有记忆写权限。`story-workflow` 验收 Result Packet 后，runner 才能调用 `memory-recommender.js`；`story-memory` 也只能请求 `advance|return_to_asset|repair_current|await_user_decision|stay`，不能调度其他模块或自行推进任务。

托管 runner 的每个需要记忆的阶段必须生成不可变 Memory Contract，并在 Result Packet 中回显 `memory_read_receipt`；状态机同时校验合同身份与执行期间内容源 revision。协作式交互会话只能提供断点和质量门，不能声称具备托管模式的流式早停与强制读取能力。

## Visible Output

用户问“你学到了什么”时，回答必须来自落盘记忆或本轮 `memory-suggestions`，不能凭聊天印象：

- 新增了哪些可复用规则。
- 哪些需要用户确认。
- 哪些被污染门拒绝。
- 下次会影响哪个流程：写作、审阅、去 AI 味、拆文、短篇资讯抓取。

可见状态查询统一使用：

```bash
node scripts/memory-recommender.js --project-root <book-root> --status --json
```

`--status` 是只读操作，不能写正文、不能改大纲、不能自动应用建议。可见回复必须解释：

- `recentLearned`：已经进入创作记忆、下次会被装配的内容。
- `pendingConfirmations`：高风险或边界不清，必须用户确认后才可应用。
- `autoApplicable`：可由 `--apply-low-risk` 自动应用的低风险新增。
- `blockedPollution`：被污染门挡住的建议数量。
- `nextEffects`：这些记忆会影响的流程，例如写作、审阅、去 AI 味、拆文、短篇资讯学习。
