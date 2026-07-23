---
name: story-memory
description: 网络小说工具箱内部记忆模块。用于工作流需要读取、压缩、注入或记录人物、伏笔、规则、作者风格、用户偏好、资讯学习和污染经验时；只提供记忆协议与脚本入口，不直接写正文、大纲或审稿结论。
---

# story-memory：内部记忆模块

`story-memory` 只负责记忆层，不替代 story-workflow，也不替代领域子 skill。

## 边界

- 不写正文、不改大纲、不生成细纲、不做审稿裁决。
- 不决定下一步任务；下一步仍由 `story-workflow` 管。
- 不替代领域子 skill：短篇爆点学习归 `private-short-extension`，长篇人物/伏笔使用归 `story-long-write`，去 AI 味风格规则归 `story-deslop`。
- 只做五件事：类型化查询、证据检索、压缩快照、版本管理、读取回执。记忆建议只有在专业产物被接受后才可投影。
- 存储必须经过 `StorageBackend` / repository 契约。当前默认读取项目内本地文件；未来 PostgreSQL 由 `novel-project` 注入 adapter。本模块不保存连接串、密码，也不直接连接数据库。
- 单目录短篇只保存当前作品连续性。跨短篇素材池、作者长期画像和学习进化由外部项目管理器消费 `追踪/integration/outbox.jsonl` 后维护，本模块不得把它们回灌成当前作品事实。
- 短篇逐节正文不读取全量 lorebook，也不重复装配全局 memory packet。专业模块先声明当前 `project_id + section_index` 所需的类型化 `Memory Query`，本模块据此编译最小记忆快照，只选取已接受的前序事实、活跃人物、未闭合承诺和已确认写作规则；`story-workflow` 只保存合同引用和校验调用顺序，不拼接事实内容。候选稿、未来小节事实、其他作品与聊天转录禁止进入。阶段结束前校验 `memory_read_receipt`，相关事实已变化时保留候选稿并局部重建上下文，不允许带着旧记忆继续采用。
- 通用内核职责固定为：按宿主上下文和阶段复杂度分配召回预算、按优先级截取事实、生成稳定版本、校验读取回执、报告失效来源。题材与文体模块只提供 profile：短篇把上一节人物状态、未决钩子和本节到期承诺转成连续性义务；长篇按书/卷/阶段/章提供自己的层级与义务。通用内核不得出现“第 N 节”“卷纲”或具体题材判断。

## 全局调用方式

`story-memory` 不是由各子 skill 自愿调用的附加能力，而是由 `workflow-runner.js` 统一执行的全局决策点。每个 workflow 都有显式策略：

- `required`：写作、审阅、拆文、回炉、去 AI 味等必须成功装配相关记忆，冲突/相关污染未解决时阻断当前阶段。
- `optional`：扫榜、封面、导入等按需读取偏好或现有项目事实；不可用时带 warning 继续，但不得凭空补记忆。
- `none`：setup/update 只维护基础设施，不注入小说事实。

装配包必须绑定 `workflow_id`、`book_root` 与 `target scope`。不同作品、不同短篇项目、不同并行任务不得共享可变上下文。结果只有在 workflow result packet 被接受后才能进入记忆建议；污染建议隔离，高风险 canon/人物认知/伏笔时点/结构变化必须确认。

控制面与内容面必须分开：`story-workflow` 可直接读取 `TaskStore`、交互偏好和 StoryMemory 的计数摘要，用于首屏、恢复和路由；人物事实、钩子、作者声口等内容只能经本模块生成的 `Memory Contract` 交给专业子 skill。专业子 skill 回传读取回执与建议，不得直接改全局记忆。

长篇 workflow 还必须传入 `lifecycle_context: { node, book_id, volume_id, stage_id, chapter_id, task_family_id, workflow_id }`。装配顺序固定为 `book -> volume -> stage -> chapter -> task`：总纲节点只读作品与任务记忆，卷纲节点增加目标卷记忆，阶段节点增加目标阶段记忆，Brief/正文/提交节点才可增加目标章节记忆。卷纲审阅不得扫描或注入无关章节正文。

## Packet Boundary

`story-memory` 仅由 `story-workflow` 或其 runner 代表 `story-workflow` 以 Workflow Packet 进入，并且仅向 `story-workflow` 返回 Result Packet。不得让用户直接调用内部 `story-*`；用户入口始终是 `/novel-assistant`。记忆层不直接召回写作、审阅或其他子 skill，也不决定下游生命周期。

- Workflow Packet 必须包含 `lifecycle_node`、`asset_target`、`upstream_dependencies`、`review_requirement`、`memory_scope`、`read_set`、`write_set` 与 `result_write_set`。
- `read_set` 是封闭只读集合：只能读取 Packet 明确指定的记忆账本、来源资产和任务状态；不得因装配方便扫描其他作品、其他任务或更低层级章节资产。
- `result_write_set` 是允许在 Result Packet 中声明的实际记忆变更，必须是 `write_set` 的子集；未接受的建议、只读状态查询和未验证投影写 `[]`。
- Result Packet 必须含 `asset_revision`、`review_decision`、`downstream_effects` 与 `lifecycle_transition_request`。记忆层使用 `review_decision=not_applicable`，除非 Packet 要求对记忆冲突或投影进行审阅；只能请求 L2 继续、停靠或回退，不能自行推进生命周期。

## 记忆文件

- 创作记忆：`追踪/memory/lorebook.jsonl`
- 当前出场与认知边界：`追踪/memory/active-cast.json`
- 记忆建议：`追踪/memory/memory-suggestions.jsonl`
- 记忆审计：`追踪/memory/memory-audit.jsonl`
- 工作流偏好：`追踪/workflow/preference-memory.jsonl`
- 短篇资讯学习：`追踪/private-short-extension/learning-ledger.jsonl`
- 作者声口与污染规则：`设定/作者风格/`、`追踪/schema/user-style-rules.jsonl`、`追踪/schema/output-pollution-rules.jsonl`
- 当前承诺/伏笔事实：`追踪/schema/promises.jsonl`
- 承诺/伏笔不可变事件：`追踪/story-system/promise-events.jsonl`

## 脚本入口

查询工作流控制摘要（不泄漏剧情事实）：

```bash
node scripts/workflow-control-summary.js --project-root <book-root> --json
```

短篇阶段的类型化快照由 `scripts/lib/short-memory-snapshot.js` 通过 `StoryMemoryRepository` 和 `Memory Query` 契约生成；其他题材 profile 复用同一内核，不得复制存储逻辑。

装配当前任务需要的记忆包：

```bash
node scripts/context-assembler.js --project-root <book-root> --task <workflow-task> --target <target-range> --budget <budget> --json
node scripts/context-assembler.js --project-root <book-root> --workflow-id <id> --lifecycle-node <node> --book-id <id> --volume <id> --stage <id> --chapter <id> --task-family-id <id> --budget <budget> --json
```

记录或应用记忆建议：

```bash
node scripts/memory-recommender.js --project-root <book-root> --input <suggestions.json> --write --json
node scripts/memory-recommender.js --project-root <book-root> --apply-low-risk --json
node scripts/memory-recommender.js --project-root <book-root> --confirm <suggestion-id-or-entry-id> --decision apply|reject --json
```

旧项目首次启用记忆时，先预览再迁移：

```bash
node scripts/memory-migrate.js --project-root <book-root> --json
node scripts/memory-migrate.js --project-root <book-root> --write --json
node scripts/memory-migrate.js --project-root <book-root> --source 追踪/伏笔.md --write --json
```

查询“我学到了什么”的可见状态：

```bash
node scripts/memory-recommender.js --project-root <book-root> --status --json
```

`--status` 只读账本，不改文件。返回字段必须用于用户可见说明：`recentLearned` 是已生效记忆，`pendingConfirmations` 是需要用户确认的高风险建议，`nextEffects` 是下次会影响的流程，`autoApplicable` 是可低风险自动应用的新增项。

## 使用流程

1. workflow 进入写作、审阅、回炉、导入吸收、拆文吸收或去 AI 味前，先调用 `context-assembler.js`。
2. `status=ok` 时，把 `packet_md` 注入领域子 skill；领域子 skill 不再广泛扫描无关记忆。
   长篇包中的 `lifecycle_context` 与分层 `memory_sources` 是事实边界；领域子 skill 不得自行补扫更低层级资产。
3. `status=blocked_memory_conflict` 时，停在用户确认，不继续生成正文或报告。
4. 来源文件变化时，`context-assembler.js` 返回 `blocked_memory_stale`，并列出需要显式运行 `memory-migrate.js --source ... --write` 的来源；它不得自行生成 legacy migration authority。显式迁移完成后重新装配，手工记忆、来源缺失、污染或事实冲突仍不得注入旧事实。
5. 显式记忆迁移和章节提交共享书目级写入租约；另一个会话正在接受章节或投影记忆时返回 `blocked_book_write_locked`，不得用第二份 lorebook 覆盖第一份。
6. `status=blocked_output_pollution` 时，先隔离污染，不能把污染记忆注入上下文。
7. 领域产物被用户接受后，可用 `memory-recommender.js` 记录建议；高风险变更用 `--confirm ... --decision apply|reject` 闭环，不得只留下永久 pending。
   章节事务只有在 accepted commit 形成后才能增量投影；条目必须记录 `acceptedCommitId`、`valid_from`、`valid_to` 和生命周期身份。未接受、非任务族主分支、污染、已失效或来源陈旧的条目不得进入 active memory。
   承诺/伏笔状态只接受 accepted chapter commit 中结构化 `promise_deltas` 的幂等投影。聊天意见、Agent 摘要、未接受候选稿和对整份 `伏笔.md` 的猜测都不能直接打开、推进或关闭承诺；同一 commit 重放不得重复追加事件。
8. 用户问“你学到了什么 / 记住了什么 / 当前记忆状态”时，必须运行 `--status`，用落盘状态回答，不能凭聊天印象回答。

完整契约见 `references/memory-contract.md`。
