# story-review Workflow Contract

本文件定义 `story-workflow` 与 `story-review` 之间的分层审阅合同。通用状态、结果包、写入安全和事务接受仍以 `story-workflow/references/workflow-contract.md` 为准。

## 单一作品任务

作者创建的是一个作品语义任务，例如“审阅总纲”“审阅当前阶段”“审阅第一卷”或“审阅全书”。内部取证单元不是子任务，不得出现在用户任务卡、数字候选、进度摘要或完成建议中。

用户可见字段只允许使用：

- `review_target.visible_label`
- `review_target.narrative_scope`
- 审阅完成百分比
- 中文问题摘要与下一步作品动作

以下字段仅供机器状态、Evidence Plan、result packet 和恢复协议使用：

- `batch-*` / `batch_id` / `batch_scope`
- 精确内部章域切片
- `plan_entry_id`、结果包路径与 source digest
- 上下文预算、并行 agent 数量与角色调度

## Review Target

`review_target.kind` 必须是以下值之一：

`master_outline|volume_outline|stage_detail_outline|chapter_brief|prose_unit|milestone|volume|book`

目标由 `resolveReviewTarget(input, lifecycleState)` 解析。用户文本优先；用户省略层级时，才根据当前生命周期审阅节点和 `asset_target` 补齐。解析结果必须包含稳定的 `visible_label`、`narrative_scope` 和 `target_ref`。

## Evidence Policy

`reviewEvidencePolicy(target)` 把目标分为两类：

| 目标 | 取证模式 | 读取边界 |
|---|---|---|
| `master_outline` | `asset_dependency_closure` | 只读总纲 |
| `volume_outline` | `asset_dependency_closure` | 总纲 + 目标卷纲 |
| `stage_detail_outline` | `asset_dependency_closure` | 总纲 + 目标卷纲 + 目标阶段细纲 |
| `chapter_brief` | `asset_dependency_closure` | 总纲 + 目标卷纲 + 目标阶段细纲 + 目标 Brief |
| `prose_unit` | `dynamic_evidence_plan` | 当前正文及其规划依赖 |
| `milestone` | `dynamic_evidence_plan` | 当前阶段正文、边界与规划依赖 |
| `volume` | `dynamic_evidence_plan` | 目标卷正文、边界与规划依赖 |
| `book` | `dynamic_evidence_plan` | 全书正文、跨卷边界与规划依赖 |

资产审阅不得调用 `review-batch-planner.js`。动态取证才允许调用 planner；planner 产物必须标记 `visibility=internal_only` 与 `user_visible_batches=false`。

## 可见进度

内部取证推进后，候选仍指向同一个 `visible_label`，只增加完成百分比。暂停与恢复也恢复该作品任务，不恢复成“某批”或某个技术章域任务。全部 Evidence Plan 单元完成后，进入该目标的汇总结论与验收，不创建新的用户任务。

## 只读与写回

所有审阅取证默认只读。发现问题只生成 findings 和修复建议；需要修改正文、大纲或 canonical 追踪资产时，返回 `story-workflow` 创建独立修复候选，并遵守正式资产事务接受协议。资产审阅不得顺手读取或修改下游资产。
