# Workflow、Memory 与专业子 Skill 协作契约

## 实施状态

- [x] 定义 TaskStore、StoryMemory、ArtifactStore、UserProfile 四层边界。
- [x] 提供默认本地 `StorageBackend` 与 repository。
- [x] 提供类型化 Memory Query、不可变 Contract 和读取回执。
- [x] 短篇逐节 Brief、正文、质量门、采用事务接入同一记忆版本。
- [x] 提供 workflow 控制摘要，首屏/恢复不读取剧情原文。
- [x] 定义 novel-project PostgreSQL 接管、单一 authority 与 outbox 契约。
- [x] 将运行脚本纳入单目录 bundle，并同步 Claude/Codex/ZCode 私有安装。

当前边界：PostgreSQL 的实际表迁移、连接池、权限与 adapter 实现属于 `novel-project`；skill 只维护稳定接口和本地后端，不在仓库中保存数据库凭据。

## 目标

让记忆真正参与写作和审阅，同时避免把全量历史、聊天记录或旧报告重复塞给模型。
`story-workflow`、`story-memory` 与专业子 skill 必须组成一条可验证的数据链，而不是依靠子 skill 自觉读取文件。

## 逻辑存储分层

物理上当前仍使用项目目录中的 JSON、JSONL 和 Markdown；未来可由 novel-project 的 PostgreSQL 接管。业务代码不得把物理文件路径当成领域身份。

| 逻辑存储 | 当前本地实现 | PostgreSQL 映射 | 主要使用者 |
| --- | --- | --- | --- |
| `TaskStore` | `追踪/workflow/tasks/`、任务族、焦点指针 | workflow/task/session 表 | `story-workflow` 直接读写 |
| `StoryMemory` | `追踪/memory/`、结构化 promise 与规则 | fact/entity/promise/memory_revision 表 | 专业子 skill 类型化查询，workflow 只读摘要 |
| `ArtifactStore` | 大纲、Brief、正文、报告及其哈希 | artifact/artifact_revision/review_cache 表或对象存储索引 | workflow 与专业子 skill 按 read/write set 使用 |
| `UserProfile` | `preference-memory.jsonl` 与项目配置 | user_profile/model_profile 表 | workflow 直接读取控制偏好，专业子 skill 按需读取写作偏好 |

四层可以共用一个 PostgreSQL 实例，但必须保持独立 namespace、权限和版本。`current-task.json` 不能变成剧情记忆，`lorebook.jsonl` 也不能承担任务队列。

每个记录使用稳定身份：`project_id + project_instance_id + domain + record_type + record_id`。制品引用使用项目相对路径和内容摘要；绝对路径只是本地适配器的瞬时解析结果，不得进入可迁移记录。

## 唯一职责

| 层级 | 负责 | 不负责 |
| --- | --- | --- |
| `story-workflow` | 直接访问 TaskStore 与 UserProfile；管理任务生命周期、阶段、目标范围、owner module、读写边界、确认与恢复；只查询 StoryMemory 摘要 | 不推断小说事实，不代替专业审阅 |
| `story-memory` | 过滤、检索、压缩、版本、证据、冲突与污染隔离 | 不决定下一阶段，不写正文，不判断剧情是否精彩 |
| 专业子 skill | 按当前阶段使用记忆完成写作、审阅、拆文或去 AI 味，并回传结果 | 不扫描其他任务，不直接更新全局记忆，不自行推进 workflow |

### 可执行权限矩阵

| 操作 | workflow | memory | 专业子 skill |
| --- | --- | --- | --- |
| 读取任务列表、焦点、断点和数字菜单 | 允许，直接访问 TaskStore | 禁止 | 禁止 |
| 读取交互偏好 | 允许，只取控制偏好 | 允许按查询筛选写作偏好 | 只能从阶段包读取相关偏好 |
| 读取人物、关系、认知、因果、钩子和承诺 | 只读数量、版本与冲突摘要 | 允许按 `workflow_id + scope + lifecycle` 检索 | 只能读取唯一 Memory Contract/阶段包 |
| 写待处理反馈和已确认方案 | 允许，写当前 durable task | 禁止 | 只能回传方案草案，不得自行标记已确认 |
| 写规划资产、正文或报告 | 只授权路径并验收回执 | 禁止 | 仅写 `write_set` 中的候选/阶段产物 |
| 写作品事实和长期规则 | 只能在制品/事务已接受后请求投影 | 允许受控投影、版本化和隔离 | 只能在 Result Packet 中提出 `memory_updates` |
| 推进、回退、暂停或完成阶段 | 唯一允许者 | 只能请求 | 只能用 `lifecycle_transition_request` 请求 |

可见交互同样属于 workflow 控制面。专业子 skill 和 finalizer 必须原样转发状态机返回的 `stage_execution`、`pending_action`、`next_candidates`、`visible_response` 与 `interaction_contract`。它们不得自行输出“下一步运行某命令”、重新编号候选或把可恢复质量分支当成 shell Error。阶段内可自动修复的问题返回 `resume_running_stage`；需要作者权衡时才返回最多四项的数字菜单。

这张矩阵是运行边界，不是文档建议。状态机必须校验 owner、write set 与结果回执；短篇阶段包和所有托管 runner 阶段都必须绑定 `memory_read_receipt`。runner 才能调用记忆投影器。专业子 skill 直接执行 `memory-recommender.js`、直接编辑 task/memory 文件或直接调用另一个专业模块，均视为协议绕过。

## 记忆域与生效边界

| 记忆域 | 内容 | 写入时点 | 读取方 | 禁止事项 |
| --- | --- | --- | --- | --- |
| 任务工作记忆 | 待处理反馈、候选方案、当前阶段、恢复断点 | 对话或阶段进行中 | workflow | 不作为作品事实注入正文 |
| 任务决策记忆 | 用户明确采用的方案、影响范围、回写顺序 | 用户确认方案时 | workflow、规划回写阶段 | 未投影前不得声称大纲已经修改 |
| 作品规划记忆 | 已验收的素材卡、设定、小节大纲约束及来源 hash | 规划资产回写通过后 | Brief、正文、审阅 | 来源变化后不得继续注入旧约束 |
| 作品事实记忆 | 已采用正文中的人物、关系、事件、选择、因果、钩子 | 小节/章节事务接受后 | 后续写作、审阅 | 候选稿和聊天结论不得直接写入 |
| 作者偏好记忆 | 明确确认的声口、禁用项、交互偏好 | 用户确认或低风险规则验收后 | workflow、去 AI、写作 | 控制偏好与写作偏好必须分流；单次情节意见不得升级为全局偏好 |
| 领域学习记忆 | 私有资讯、素材血缘、技巧卡 | 专业学习流程验收后 | 私有增强模块 | 不得混入当前作品 canon 或公开包 |
| 质量与故障记忆 | 误伤规则、污染样本、模型能力画像 | 门禁复核或故障确认后 | gate、runner | 不得当成剧情事实或作者偏好 |

短篇反馈采用固定决策链：`原始聊天审计 -> 助手结构化方案草案 -> 用户确认方案 ID -> task.accepted_plan -> 回写权威规划资产 -> planning-constraints -> 逐节 Brief/正文复检 -> accepted facts`。进入记忆和回写队列的是用户确认的最终方案快照，不是未经收束的原始聊天。用户说“采用上面的总结”时，必须绑定已有方案 ID；该句是接受动作，不得复制成第二条反馈。原始聊天只用于审计和追溯，不注入正文。

`feedback_apply_patch` 是受控多资产事务，不是自由编辑提示：状态机从 `accepted_plan.projection_plan.planning_assets` 生成暂存写集；专业短篇模块只修改这些暂存文件；统一 finalizer 一次校验、一次提交并使受影响 Brief/正文进入修订队列。未生成 `execution_command`、写集与方案绑定时，该阶段不得执行。

通用 `memory_updates` 还必须通过领域防火墙。正文事实、规划约束、作者偏好、风格和带血缘的学习技巧可以进入对应记忆域；workflow、task、route、menu、session、setup、bundle 与安装版本等控制信息只能进入任务日志或审计隔离区，禁止伪装成故事事实。

## 调用链

```text
用户意图
  -> story-workflow 直接查询 TaskStore / UserProfile 并锁定 workflow_id / stage / scope / owner_module
  -> 专业子 skill 通过声明式 Memory Query 描述本阶段需要的事实类型
  -> story-memory 独立编译 Memory Contract、最小快照和读取版本
  -> workflow 只持有 memory dependency 引用并保证调用顺序
  -> 专业子 skill 直接读取 story-memory 产物并完成当前阶段
  -> 子 skill 回传 Result Packet + memory_read_receipt + memory_updates 建议
  -> workflow 验证回执、质量门和写入边界
  -> 产物被接受后，story-memory 才投影低风险事实或等待高风险确认
  -> workflow 推进下一阶段
```

## Memory Contract

每个需要记忆的阶段都由 `story-memory` 生成不可变合同。`story-workflow` 只保存合同句柄并验证身份，不拼接或解释合同内容：

- `workflow_id`、`stage_id`、`owner_module`。
- `mode=required|optional|none`。
- 唯一 `packet_path`、`packet_digest`、`memory_revision`。
- `token_budget`、选中条目和省略数量。
- `read_receipt_required` 与 `accepts_memory_updates`。
- 当前阶段的连续性义务或审阅依赖。

专业子 skill 的 Result Packet 必须绑定匹配的 `memory_read_receipt`。状态机在接受短篇阶段回执前重新计算当前 revision；托管 runner 还会核对 runner packet、合同摘要和执行期间的内容源 revision。不一致时保留候选稿并局部重建上下文。回执只能证明“读取的是哪一版上下文”，不能证明模型判断正确；正确性仍由专业质量门负责。

任何正式资产的写入审计发生在**每个阶段回执被接受之前**，不是只在 workflow 结束时执行。没有 accepted transaction receipt 的改动不得进入后续 Brief、记忆投影或任务完成状态。

## 本地与 PostgreSQL 兼容

- 默认 backend 为 `local-file`，保留现有项目目录和 Git 可审计能力。
- 存储访问统一经过 adapter/repository；新增代码不得直接假设 `fs.readFileSync` 是唯一后端。
- PostgreSQL backend 由 novel-project 提供，遵守相同的 query、revision、compare-and-swap、append-event 与 transaction 语义。
- 本地与 PG 同时存在时，只有一个 authority backend；另一端通过 `追踪/integration/outbox.jsonl` 和幂等事件同步，不能双主写入。
- 后端切换前先完成 checkpoint、刷新 outbox、校验 revision；切换后旧 backend 只读，避免 split-brain。
- Skill 不保存数据库密码、连接串或用户凭据；只接受宿主提供的 adapter/capability。

## Profile

### 短篇写作

读取已接受前序小节、人物状态、未决钩子、到期承诺和确认风格。把它们编译成当前节必须完成的连续性义务。候选稿、未来小节事实和其他短篇禁止进入。

### 长篇写作

按 `book -> volume -> stage -> chapter -> task` 分层，只装配当前章节上下文包。Brief、正文、验收和提交共用同一版本；章节提交后投影事实、人物变化和 `promise_deltas`。不得同时注入第二份通用大包。

### 审阅与修复

记忆只提供当前 canon、人物状态、钩子和作者规则。旧审阅报告属于“可复用制品”，缓存键必须绑定：

```text
source_digest + planning_digest + memory_revision + rubric_version + detector_version
```

完全一致时复用；局部变化时只重审变化范围与相邻边界；不一致时旧报告标记过期。不能因为 memory 命中旧结论就跳过证据审阅。

### 拆文、扫榜与去 AI 味

- 拆文只读取目标作品与已确认分析偏好，不读取当前创作 canon。
- 扫榜只按需读取平台偏好，不注入小说人物事实。
- 去 AI 味读取作者声口与禁用规则，同时锁定事实、人物、钩子和情节功能，禁止为了过检测改剧情。

## 失败与恢复

- 回执缺失或版本不一致：保留候选产物，重建当前阶段上下文，不重写整个任务。
- 记忆冲突或污染：隔离相关条目，只阻断受影响阶段。
- 子 skill 返回高风险记忆建议：等待用户确认，不自动改 canon。
- 子 skill 未使用 runner：标记为协作模式；可保存断点，但不能声称具备托管模式的强制读取与早停能力。

## 完成标准

1. 每个专业 workflow 有显式 memory profile。
2. 同一阶段只有一个可见上下文包。
3. 必需记忆阶段的 Result Packet 有可验证读取回执。
4. 记忆更新只能发生在结果被接受之后。
5. 重复任务优先复用可信制品，来源变化时只做增量重算。
6. 用户可看到本轮使用了多少记忆、遗漏多少、哪些义务被推进或延期。
7. 每项已确认方案都有任务决策记录；所有受影响资产、Brief 和正文复检项均由同一影响队列自动生成。

## 当前落地模块

- `scripts/lib/storage-backend-contract.js`：统一本地与宿主存储能力边界。
- `scripts/lib/local-storage-backend.js`：默认本地文件 adapter，只接受项目相对路径。
- `scripts/lib/workflow-task-repository.js`：任务权威记录与焦点指针查询。
- `scripts/lib/story-memory-repository.js`：人物、事实、承诺、规则的类型化读取。
- `scripts/lib/user-profile-repository.js`：交互和路由偏好读取。
- `scripts/lib/artifact-repository.js`：制品身份、摘要和审阅缓存键。
- `scripts/lib/memory-query-contract.js`：Memory Query、Contract 与读取回执。
- `scripts/workflow-control-summary.js`：首屏/恢复使用的控制摘要，不返回剧情原文。

PostgreSQL 表、事务与 outbox 映射见 [novel-project 持久化接管契约](novel-project-persistence-contract.md)。
