# Quality Debt Policy / 质量债务策略

## Background

AI-Novel-Writing-Assistant 的一个有价值设计是：局部章节质量问题不必自动打断整本生产链。`novel-assistant` 吸收这个原则，但只放在 skill workflow 层，不引入对方的应用运行时。

## Decision

局部质量债务不是全局失败。章节、段落、局部伏笔、轻度 AI 味、可修复节奏问题，应记录为 `quality_debt` 并允许 workflow 在安全边界内继续；只有会破坏全书承诺、事实底座、目录结构、写入安全或模型健康的情况，才升级为全局阻断。

## Current Rule

L3 专业模块 result packet 可以返回：

- `continue_with_warning`: 当前产物可用，但存在后续修复项。
- `repair_later`: 当前任务先收束，质量债务写入账本。
- `local_patch_plan`: 需要局部修复，但不要求全书重规划。
- `stop_for_replan`: 必须暂停主链，回到大纲/卷纲/角色/规则层重规划。

质量债务写入：

```text
追踪/workflow/chapter_quality_debt.jsonl
```

每条记录至少包含：

```text
workflow_id
scope
debt_type
severity
evidence_paths
recommended_fix
status
created_at
```

## Stop Conditions

只有以下情况允许阻断整条 workflow：

- `stop_for_replan` 或 `replan_required`。
- 正文不可用、章节缺失、写入失败、并行写冲突。
- 事实、角色认知、伏笔回收、成长规则出现全局冲突。
- 输出污染、模型退化、工具调用污染未能隔离。
- 用户要求覆盖、删除、迁移或大范围重排但尚未确认。

## Examples

- 单章有 3 处解释腔，但剧情事实正确：记录 `quality_debt`，继续下一阶段。
- 第 40 章提前揭晓第 120 章核心真相：返回 `stop_for_replan`，不得继续批量写。
- 审阅发现 201-299 未审 gap：记录 gap debt；后续补审后再判断 300-400 是否 stale。
