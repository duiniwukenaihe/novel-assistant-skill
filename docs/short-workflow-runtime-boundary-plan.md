# 短篇工作流运行边界实施计划

**目标：** 将公有和私有短篇统一为“单目录单作品”的稳定生产内核，由 skill 管当前作品运行状态，由外部 `novel-project` 选择消费结构化出站事件并承担跨作品长期学习。

**架构：** `task.json` 继续作为阶段权威，`project-state.json` 作为单作品可重建投影，所有变更命令显式绑定 `workflow_id`。全局入口只负责环境、恢复和路由；私有模块存在时接管短篇业务首屏及全部后续阶段，公开模块仅兜底。短篇正文阶段使用单一最小上下文包，不再额外注入固定全局记忆包。

**技术栈：** Node.js、Bash/Bats、JSON/JSONL、Markdown skill 契约。

## 全局约束

- 一个短篇目录只对应一部作品。
- 不修改或依赖 `novel-project` 的数据库、端口和前端实现。
- 不把私有资讯规则、素材库或个性化方法写入公有模块。
- 不修改当前工作区中无关的长篇文件。
- 先写失败测试，再写最小实现。

## Task 1：短篇写入强制任务身份

**文件：**

- 修改：`tests/test-short-section-title-lock.bats`
- 修改：`tests/test-short-section-transaction.bats`
- 修改：`scripts/short-section-title-lock.js`
- 修改：`scripts/workflow-state-machine.js`

**行为：**

- 标题预览可以只读运行。
- 标题确认必须显式提供 `--workflow-id`。
- 状态机生成的预览和确认命令都携带同一个 `workflow_id`。
- 即使 `current-task.json` 已切到另一任务，标题确认也只能刷新显式任务。

- [x] 增加“焦点切换后仍绑定显式任务”的失败测试。
- [x] 运行定向测试并确认当前实现失败。
- [x] 为标题锁增加 `--workflow-id`，确认写入前读取持久任务快照。
- [x] 更新状态机生成命令。
- [x] 运行定向测试确认通过。

## Task 2：统一启动入口

**文件：**

- 修改：`tests/test-private-short-workflow-coverage.bats`
- 修改：`src/private-internal-skills/private-short-extension/SKILL.md`
- 同步：`skills/novel-assistant/references/private-internal-skills/private-short-extension/SKILL.md`

**行为：**

- `/novel-assistant` 的启动和恢复只由全局 entry guard/任务收件箱负责。
- 私有模块收到活动 `short_write` packet 后，必须展示私有短篇业务首屏并接管后续领域阶段；不得再回退到公开短篇菜单。
- `workflow_state.py scan` 仅用于用户明确要求的私有资产诊断，不再作为 broad invocation 的第二首屏。

- [x] 增加私有模块不得声明独立启动恢复的失败测试。
- [x] 运行测试确认失败。
- [x] 收缩私有 `startup resume` 规则。
- [x] 同步私有 bundle 并运行覆盖测试。

## Task 3：单作品项目状态

**文件：**

- 新建：`scripts/lib/short-project-state.js`
- 同步：`skills/novel-assistant/scripts/lib/short-project-state.js`
- 修改：`scripts/short-planning-stage-finalize.js`
- 修改：`scripts/short-section-title-lock.js`
- 修改：`scripts/short-section-brief-finalize.js`
- 修改：`scripts/workflow-state-machine.js`
- 修改：`tests/test-short-section-transaction.bats`

**接口：**

- `ensureShortProjectState(root, { workflowId, title, stageId, artifactPath, artifactHash })`
- `readShortProjectState(root)`
- `assertShortProjectOwnership(state, workflowId)`
- `advanceShortPlanRevision(root, { workflowId, outlinePath, outlineHash, plannedSections })`

**行为：**

- `material_card` 或私有 `project_seed` 被接受后初始化 `project_id`。
- 状态至少包含作品身份、活动写作任务、规划版本和采用小节。
- 已有活动写作任务仍在运行时，另一独立 workflow 不能接管同一目录。
- 标题锁和 Brief 快照绑定 `project_id + plan_revision`。

- [x] 增加公有/私有项目初始化和所有权冲突测试。
- [x] 运行测试确认失败。
- [x] 实现项目状态帮助模块及最小迁移。
- [x] 接入规划、标题锁和 Brief。
- [x] 运行项目状态与短篇事务测试。

## Task 4：通用出站事件

**文件：**

- 新建：`scripts/lib/integration-outbox.js`
- 新建：`scripts/lib/short-feedback-outbox.js`
- 同步：`skills/novel-assistant/scripts/lib/integration-outbox.js`
- 修改：`scripts/short-planning-stage-finalize.js`
- 修改：`scripts/short-section-accept-finalize.js`
- 修改：`scripts/short-story-final-check.js`
- 修改：`tests/test-short-section-transaction.bats`

**接口：**

- `appendIntegrationEvent(root, event)` 写入 `追踪/integration/outbox.jsonl`。
- `event_id` 由 `workflow_id + event_type + artifact_digest` 确定，重复执行不得重复追加。

**行为：**

- 规划采用输出 `material_accepted / setting_accepted / outline_accepted`。
- 小节采用输出 `section_accepted`。
- 全文完成输出 `story_completed`。
- 已执行并通过协议校验的用户反馈输出 `user_feedback_accepted`。
- 事件不包含数据库、页面或私有素材库实现。

- [x] 增加事件类型、身份、哈希和幂等测试。
- [x] 运行测试确认失败。
- [x] 实现 outbox 并接入规划、小节、反馈和全文接受节点。
- [x] 运行事务与最终检查测试。

## Task 5：短篇上下文单包化

**文件：**

- 修改：`scripts/lib/workflow-memory-policy.js`
- 修改：`scripts/lib/workflow-memory-context.js`
- 修改：`scripts/lib/workflow-runner-execution.js`
- 修改：`scripts/lib/workflow-stage-context-packet.js`
- 修改：`tests/test-global-workflow-memory-kernel.bats`
- 修改：`tests/test-workflow-runner.bats`
- 修改：`tests/test-short-section-transaction.bats`

**行为：**

- 短篇规划和 Brief 阶段仍可装配当前作品记忆。
- 正文、修订、故事门、采用阶段只读取 `stage_context_packet`。
- Runner 不再同时要求这些阶段读取 `memory_context`。
- 当前节直接相关事实由 Brief/锚点/项目内事实摘要进入阶段包。

- [x] 增加短篇正文阶段 `memory_context.mode=none` 的失败测试。
- [x] 运行测试确认失败。
- [x] 增加按阶段的记忆决策。
- [x] 合并必要的当前作品事实摘要。
- [x] 运行 Runner、记忆和短篇上下文测试。

## Task 6：文档、bundle 与定向回归

**文件：**

- 修改：`src/internal-skills/story-short-write/SKILL.md`
- 修改：`src/internal-skills/story-workflow/SKILL.md`
- 修改：`src/internal-skills/story-memory/SKILL.md`
- 同步对应 `skills/novel-assistant/` 文件。
- 修改：`CHANGELOG.md`

**行为：**

- 文档明确 skill 仅管理单目录当前作品。
- 长期学习和跨作品资产归外部管理器，`memory_updates` 不再是短篇完成条件。
- 私有增强与公有生产内核保持同步。

- [x] 更新源模块契约。
- [x] 运行同步脚本更新 bundle。
- [x] 运行 `git diff --check`。
- [x] 运行短篇 workflow/memory 定向 Bats 集。
- [x] 检查仅修改计划内文件及原有未提交文件未被覆盖。
