# 生产准备度与运行边界

## 适合的生产场景

`novel-assistant` 适合用于：

- 长篇从定位、总纲、卷纲、阶段细纲、章节 Brief 到正文的分层生产；
- 短篇从素材卡、设定、节奏路线、小节大纲到逐节写作的受控流程；
- 可恢复的拆文、审阅、回炉、扩容、迁移和去 AI 味任务；
- 需要保留任务断点、质量证据、章节事实增量和下一步候选的个人作者工作流。

它不是“任何模型、任何网络、任何上下文下都能永不停止的自动写书器”。

## 两种运行模式

| 模式 | 能力 | 边界 |
|---|---|---|
| 协作模式 | 在 Claude Code、Codex、ZCode 等交互会话中保存任务、阶段、结果包和可恢复断点 | 无法控制宿主隐藏思考、模型 API 流或宿主级重连 |
| runner 托管模式 | 管理子进程、心跳、重试预算、阶段结果和部分流式健康中止 | 仍依赖宿主 CLI、网络、模型服务和用户授予的权限 |

不要把协作模式写成“完全无人值守”。当模型、网络或工具异常时，正确行为是停在最后可信断点并给出下一步，而不是静默继续改写。

## 正式资产保护

正式正文、大纲、细纲、角色状态、时间线和伏笔应遵循：

```text
候选暂存 -> 质量门 -> chapter-commit prepare -> 并发检查 -> accept -> 记忆/交接投影
```

这能降低半写入、并发覆盖和“报告污染被当成事实”的风险。人工修改依然允许，但应在后续任务中进入影响分析与复检，而不是被自动覆盖。

## 生产前最小检查

维护者发布或升级前至少运行：

```bash
node scripts/production-smoke-matrix.js --repo-root . --json
node scripts/maintainability-audit.js --repo-root . --json
node scripts/public-release-audit.js --repo-root . --json
git diff --check
```

真实宿主发布候选还应分别验证：单入口路由、只写指定章节或小节、任务恢复、模型退化中止和同书多会话写锁。

## 短篇 V3 单内核与兼容迁移边界

短篇生产内核统一为 V3 单内核，`scripts/workflow-v3.js` 与 `scripts/lib/workflow-v3/` 是权威实现并随 bundle 镜像。新短篇项目默认进入 V3，不并发另一套短篇运行时。

V2 任务只走单向兼容迁移路径，不再产生新的 V2 写入：

- V2 任务文件经 `scripts/lib/workflow-v3/compatibility-gateway.js` 检视为 `safe_auto_upgrade` 后，才一次性升级到 V3 持久字段（`engine_version / task_schema_version / workflow_contract_version` 置为 3，`state_version` 自增），并映射到 `section_brief / section_draft / section_repair / assembly` 四个可信断点之一。
- 升级只改任务事实与状态字段，不重写 `正文 / 大纲 / 设定` 创作树（生产 smoke 通过创作树 hash 校验保持不变）。
- V2 资产在没有 V3 持久字段前视为只读；未通过兼容门或来源不明的旧任务不会被自动改写。

## 短篇 V3 production smoke 一致门

`production-smoke-matrix.js` 的 `short_workflow_v3_production` 用例把短篇 V3 的发布边界收为可复跑的确定性门：

- `na-dev.js verify-v3-short` 必须零退出，作为短篇 V3 单内核行为基线。
- V2 单向兼容迁移门：固定 fixture 经 `inspectCompatibility / buildMigrationPlan / applyMigration` 后，目标阶段、三个 V3 版本字段、`state_version` 自增必须满足断言，且创作树 hash 前后一致（资产 hash 不变）。
- 新项目 V3 入口门：`workflow-v3.js create-short / apply-result` 必须产出带 `binding` 的可见交互，且 `pending_action_id / state_version / visible_choice_hash / workflow_id` 四键齐备。
- V3 自由 Chat 门：`submit-feedback` 必须逐字入账且不推进阶段、不执行旧菜单；`propose-feedback` 生成固定四项确认，只有作者消费“采用方案”后才把方案标记为 accepted。
- 三宿主 envelope 一致门：`renderHostVisibleResponse` 在 `claude-code / codex / zcode` 三宿主下渲染出的 `text` 与 `binding` 必须逐字一致，且三端整体序列化相同。
- source-bundle 一致门：`workflow-v3.js / workflow-entry-guard.js / workflow-task-inbox.js / legacy-short-project-migrate.js / short-state-storage-migrate.js / lib/workflow-host-adapters.js` 在 source 与 bundle 间字节一致，`scripts/lib/workflow-v3` 目录树与内容逐字镜像。

以上门不调用付费模型，也不替代真实宿主行为验收；它们只锁定“单内核资产一致、V2 只迁移、三端 envelope 一致”这三条可复跑的发布红线。

## token 与质量

账本只展示宿主实际回传的 token 与耗时。没有真实 usage 时，系统可以给预算估算，但不得假装是账单或推导美元费用。

工作流会按当前阶段、输入规模、风险和独立证据域选择单执行者或有限并行；正文、规划回写和正式修复始终保持单写入者。托管 runner 将原始 stdout/stderr 保存为任务制品，只把错误、测试统计、关键路径和短摘要提供给后续阶段，并记录原始/压缩字符数。

来源材料使用稳定 `source_id` 与可变 `source_digest` 分离管理。内容变化只刷新依赖该来源的局部制品，不得把整个任务或全部 Memory 判为过期。同一版本在阶段间通过 `consumed_artifact_ids / produced_artifact_ids` 传递，避免重复联网、重复读取全文或回放历史聊天。

`node scripts/token-efficiency-benchmark.js --fixture-dir tests/fixtures/token-efficiency --json` 提供不调用付费模型的确定性回归；它验证压缩率、来源复用、Agent 上限和质量门覆盖，不冒充真实 Token 账单。

质量门负责拦截重复、工具污染、工程词泄漏和明显格式异常；它们不是“故事质量已保证”的证明。人物动机、情节因果、平台适配、版权和最终成稿仍由作者审阅确认。
