# Completion Evidence Protocol

此协议在恢复、构造 L2/L3 packet、验证结果、模板收束与声明完成前按需读取。以下条款从 story-workflow 完整迁移。

### 可信产物、预期产物与恢复

- `runtime_guard.heartbeat.latest_trusted_artifact` 只能指向已经存在并验证通过的产物。
- `stage_execution.expected_result_packet` / `checkpoint_policy.expected_result_packet` 表示未来应生成的回执，不能写进 `latest_trusted_artifact`。
- 启动或恢复前运行 `node scripts/workflow-state-validate.js --project-root <book-root> --json`；矛盾状态返回 `blocked_state_invariant`。
- entry guard 返回 `recover_missing_result_packet` 后，用户选择恢复时必须执行 `node scripts/workflow-recover.js --project-root <book-root> --write --json`。恢复器优先应用已存在 packet，其次从已完成阶段摘要重建；证据不足时返回重新执行当前阶段，不猜测完成。旧范围审阅若只有边界抽样或摘要、没有逐章覆盖证明，必须迁移为一等批次状态，保留旧摘要作历史证据并从首个未完成批次恢复，不得把抽样预检当成整批完成。
- 所有状态写入使用原子替换和项目级 `.workflow.lock`；`state_version` 每次成功变更递增。锁冲突返回 `blocked_workflow_locked`，不得由第二会话覆盖。

公开模板只提供 fallback owner；本地私有模块可以通过私有 `workflow-registry.json` overlay 接管对应 workflow。进入短篇、下载/续更、或其他本地增强能力时，不要假设公开 fallback 就是最终 owner，先读取状态机返回的 `owner_module`。

### 扫榜、短篇拆文与封面一等工作流

`long_scan`、`short_scan`、`short_analyze` 和 `cover` 与既有 workflow 一样属于状态机的一等模板。每个模板都必须按 `preflight -> source/input lock -> execute -> validation -> artifact assembly -> closure` 推进，并携带 `owner_module`、`risk_level`、`requires_user_confirm`、`result_contract` 与 `recovery`。`result_contract.version=2` 至少要求 `outputs`、`changed_files`、`evidence`、`verification_result`、`checkpoint_state` 和 `output_health_result`；恢复时保留最后可信产物，先按 `workflow-recover.js` 恢复缺失 result packet，再决定是否重跑当前阶段。

- `long_scan`：`story-long-scan` 是市场趋势与扫榜流程；`scan_preflight` 后进入 `source_lock` 锁定平台/时间窗口/数据来源，执行采集，经过 `trend_validation` 后交付趋势报告、选题候选和作者吸收卡。
- `short_scan`：`story-short-scan` 是市场趋势与扫榜流程；`scan_preflight` 后进入 `source_lock` 锁定短篇平台/样本窗口/数据来源，执行采集，经过 `trend_validation` 后交付情绪趋势、饱和风险和复扫时间。
- `short_analyze`：`story-short-analyze` 锁定合法原文与范围，执行 `analysis_execute`，经过 `source_validation` 后交付拆文报告、技巧卡和受限的 `memory_updates`。
- `cover`：`story-cover` 先锁定书籍信息、视觉方向、输出路径和覆盖策略；`generation_confirmation` 是硬确认点，未得到明确确认不得进入 `generate_cover_execute`。任何图像生成或覆盖任何现有封面前都必须确认。

确认阶段的数字选择必须持久化为 `last_selection` 与 `stage_execution.confirmation_context`，并生成只绑定当前 workflow、stage/step、选择、目标和操作的 `confirmation_token`。token 使用当前候选的 `expires_at`，过期、缺失、复用或任一绑定不一致时，`apply-result` 返回 `blocked_confirmation_required`。`story-cover` 只消费 `generate_cover_execute` 的有效确认上下文：`operation=generate` 与 `operation=overwrite` 分别确认生成新封面和覆盖现有封面，裸调用不得出图。
## 完成策略

### 长篇作品生命周期状态

`long_write` 不再以单章生产队列作为主状态图。新任务必须持久化 `lifecycle_graph`，并以作品资产成熟度决定当前节点：

```json
{
  "version": "1.0.0",
  "current_node": "positioning",
  "asset_target": { "kind": "book", "id": "current-book" },
  "completed_nodes": [],
  "invalidated_nodes": [],
  "review_results": {},
  "last_transition_validation": null,
  "nodes": [
    { "id": "positioning", "status": "missing" }
  ]
}
```

标准节点顺序为：`positioning -> story_bible -> master_outline -> master_outline_review -> volume_outline -> volume_outline_review -> stage_detail_outline -> detail_outline_review -> chapter_brief -> brief_review -> prose -> prose_acceptance -> chapter_commit -> milestone_review -> volume_acceptance -> book_acceptance`。

- 定位、故事圣经、各层大纲、Brief 和正文节点由 `story-long-write` 执行。
- 所有 `*_review` 与 `*_acceptance` 节点由 `story-review` 执行。
- `chapter_commit` 由 `story-workflow` 执行，并验证 accepted chapter commit 与记忆投影状态。
- 相邻节点按顺序推进；章节提交后可回 `chapter_brief` 生产下一章或进入 `milestone_review`，阶段复盘后可回阶段细纲/章节 Brief 或进入卷级验收，卷级验收后可进入下一卷卷纲或全书验收。
- review 失败不得进入下游：总纲、卷纲、阶段细纲、Brief、正文验收分别只回 `master_outline`、`volume_outline`、`stage_detail_outline`、`chapter_brief`、`prose`。阶段/卷/全书验收失败回其直接受验资产节点，并将该节点及受影响下游加入 `invalidated_nodes`。
- 必需审阅节点只有在 `step_status=completed` 且 `verification_result` 明确为 `accepted`、`approved` 或 `pass` 时才能写入 `review_results` 并解锁下游。`skipped`、空值、`indeterminate` 或其他不确定结果必须停留在当前审阅节点；明确失败结果只能触发回退。
- 审阅回退必须通过 `required_review_failure_return` 转移规则验证，验证结果写入 `last_transition_validation`。验证器拒绝时不得执行回退或忽略拒绝；状态机停留在当前节点并返回生命周期转移阻断。
- 每个 `nodes[]` 项必须持久化 `status`。节点完成时同时进入 `completed_nodes` 且 `status=accepted`；回退失效时改为 `status=invalidated`。`inspect`、`next-candidates` 和 `apply-result` 会按标准节点顺序检查当前节点的全部前置节点；首个未同时完成并 accepted 的节点返回 `blocked_longform_lifecycle_incomplete` 和 `first_missing_node`，禁止伪造完整 schema 后直接跳到正文。
- 旧项目只允许通过显式的 supported-project lifecycle migration 从元数据迁移到最近可信生命周期资产；缺失、版本错误、节点/资产/审阅台账不完整的 `lifecycle_graph` 返回 `blocked_longform_lifecycle_migration_required`。不得从 `machine.completed_stages` 静默合成图，不得重写正文、大纲、设定等创作资产。旧 `chapter_contract/chapter_machine_gate/chapter_repair_loop/drift_gate/state_delta/handoff` 状态不得继续作为新任务语义。

| completion_policy | 含义 | 停靠规则 |
|---|---|---|
| `full_auto` | 全部自动执行到队列清零 | 只在用户裁决、外部阻断、污染门禁、权限/配额失败或高风险写入确认时停 |
| `stage_then_confirm` | 执行当前阶段，例如 A 阶段 | 完成 A1..An 后停，展示 B/C/D 等剩余任务并询问 |
| `step_then_confirm` | 只执行当前步骤，例如 A1 | A1 完成后停在阶段导航，展示继续 A2、跳过 A2、返回阶段导航、停止并保存断点 |
| `plan_only` | 只制定计划，不改文件 | 输出阶段计划、推荐执行选项和风险门禁 |

必须写清楚是“只执行当前步骤 A1”，还是“执行整个 A 阶段”。不要使用含糊的执行范围描述。

## 工作流记忆

工作流记忆是落盘记忆，不依赖隐藏聊天状态。

### 任务记忆

文件：`追踪/workflow/tasks/<workflow_id>/task.json`

用途：作为当前 workflow 的 durable authority，记录断点、范围、策略、状态和下一步候选。`追踪/workflow/current-task.json` 只保存 UI 焦点指针。

```json
{
  "workflow_id": "review-20260626-001",
  "workflow_type": "review",
  "book_root": "/path/to/book",
  "user_goal": "审阅 1-200 章并提出修复方案",
  "scope": "chapter001-chapter200",
  "completion_policy": "stage_then_confirm",
  "current_stage": "A",
  "current_step": "A1",
  "status": "in_progress",
  "next_candidates": ["继续 A2", "跳过 A2", "返回阶段导航", "停止并保存断点"],
  "resume_hint": "/novel-assistant 继续"
}
```

文件：`追踪/workflow/current-task.md`

用途：记录当前 workflow 的人类可读任务导航摘要，方便用户和后续执行者快速理解当前阶段、已完成步骤、下一步候选、阻塞原因和恢复入口。它必须与 `tasks/<workflow_id>/task.json` 同步更新，但不得替代 durable JSON 状态作为机器可恢复断点。

### 历史记忆

文件：`追踪/workflow/history.jsonl`

用途：追加记录已完成阶段、用户选择、跳过项、失败门禁、复检结果。

```jsonl
{"event":"stage_completed","stage_id":"A","workflow_id":"review-20260626-001","source":"assistant","created_at":"2026-06-26T10:00:00+08:00"}
```

### 偏好记忆

文件：`追踪/workflow/preference-memory.jsonl`

用途：记录用户明确确认过且有证据支撑的流程偏好。每条偏好必须保留 evidence / 证据，例如用户原话、accepted option、confirmed correction，避免把含糊选择误记为长期偏好。

```jsonl
{"preference":"拆文默认尽量无人值守 full_auto","scope":"long-analyze","source":"用户明确要求拆文无人值守","evidence":"用户原话：拆文默认尽量无人值守","confidence":"high","created_at":"2026-06-26T10:00:00+08:00"}
```

偏好规则：

- 不得从一次含糊选择推断永久偏好。
- 每条偏好必须有 `source`、`confidence`、`scope`、`created_at`，并保留 `evidence` / `证据`；证据示例包括用户原话、accepted option、confirmed correction。
- 当前请求优先于历史偏好；冲突时记录冲突，不强行套旧偏好。
- 偏好只能改变默认选项，不能绕过覆盖、删除、迁移、批量改稿等确认门禁。

## 标准计划字段

每个计划必须包含：

```text
workflow_id
workflow_type
book_root
user_goal
scope
completion_policy
current_stage
current_step
stages[]
next_candidates[]
blocking_gates[]
verification[]
resume_hint
status
```

每个 stage 必须包含：

```text
stage_id
stage_goal
steps[]
owner_module
inputs
outputs
completion_condition
status
```

每个 step 必须包含：

```text
step_id
step_goal
owner_module
read_set
write_set
result_write_set
risk_level
requires_user_confirm
completion_condition
verification
status
```

## L2 到 L3 输入契约

`story-workflow` 调用专业模块前，必须生成 workflow packet。workflow packet 是 L2 对 L3 的工作订单，说明本步骤要做什么、边界在哪里、哪些文件可读写、什么才算完成。

必填字段：

```text
workflow_id
workflow_type
book_root
user_goal
scope
completion_policy
current_stage
current_step
owner_module
read_set
write_set
risk_level
requires_user_confirm
completion_condition
verification
next_candidates
memory_paths
runtime_guard
context_assembly
lifecycle_node
asset_target
upstream_dependencies
review_requirement
memory_scope
```

字段规则：

- `owner_module` 必须是具体专业模块，例如 `story-long-analyze`、`story-long-write`、`story-short-write`、`story-review`、`story-deslop`。
- `long_write` 的 `lifecycle_node` 必须等于当前标准生命周期节点；`asset_target` 必须标明本次读取、生成、审阅或提交的作品/卷/阶段/章节资产。
- `review_requirement.required=true` 时必须写明 `failure_return`；Result Packet 未通过时，`story-workflow` 只能回到该资产节点并失效受影响下游，不能接受专业模块建议直接跳到后续节点。
- `upstream_dependencies` 与 `memory_scope` 必须按当前资产层级装配，不能用固定章节批次代替作品语义。
- `read_set` 是封闭只读集合，只能列出允许读取的项目文件、章节范围、source slice 或报告；L3 不得因“可能相关”补扫集合外资产。
- `write_set` 是允许写入的目录或文件；为空表示只读。
- `result_write_set` 是本步骤允许在 Result Packet 中声明为实际变更的路径集合；它必须是 `write_set` 的子集，且仅列出已经落盘、验证通过的文件。只读步骤写 `[]`。
- `risk_level` 可为 `low`、`medium`、`high`、`destructive`。
- `requires_user_confirm=true` 时，专业模块不得直接写入高风险变更。
- `memory_paths` 至少包含 `追踪/workflow/current-task.json`、`追踪/workflow/current-task.md`、`追踪/workflow/history.jsonl`。
- 长任务和全局任务必须填写 runtime_guard，短任务可写 `runtime_guard=none`。`runtime_guard` 至少包含：
  - `token_estimate`：输入文件数、输入字符估算、输出预算、agent 数、batch_size、risk_level。
  - `adaptive_budget_policy`：`visible_reply_budget`、`batch_handoff_budget`、`range_summary_budget` 的计算依据；不得写死单一字数。
  - `heartbeat`：最近可信产物、最近落盘时间、当前批次、已完成/总数、是否长时间无新增产物。
  - `checkpoint_policy`：批次边界、断点路径、失败后从哪里恢复、哪些产物可复用。
  - `output_health_gate`：可见回复、agent handoff、报告草稿和候选项要跑的污染/退化检查。
  - `max_retry_budget`：同类污染、同一工具失败、同一 API/provider 错误允许重试的次数。
  - `stall_policy`：recap、长时间 thinking、stream stall、agent 0 token Done、无文件落盘时的暂停或缩小范围规则。
- `context_assembly` 是创作记忆库装配边界；不需要创作记忆库时可写 `context_assembly.required=false`，需要时不得省略。`context_assembly` 至少包含：
  - `required`
  - `script`
  - `status`
  - `packet_json`
  - `packet_md`
  - `selected_entry_count`
  - `omitted_entry_count`
  - `conflicts`
- 短篇写作、短篇回炉和短篇去 AI 味的 workflow packet 必须额外携带短篇上下文字段，不得只给长篇通用写作字段：
  - `short_story_style_pack`：本次短篇采用的题材风格包摘要，或 `short-craft.md` 通用底座摘要。
  - `genre_style_pack`：`references/genre-styles/{题材}.md` 路径；没有专属包时写 `genre-writing-formulas.md + short-craft.md`。
  - `short_format_path`：`references/short-format.md`。
  - `short_craft_path`：`references/short-craft.md`。
  - `short_deslop_path`：`references/short-deslop.md`，短篇去 AI 味和精修必须优先使用。
  - `benchmark_paths` / `deconstruction_meta`：当前短篇的 `对标/`、项目根 `拆文库/`、`_meta.json.genre_detected` 和拆文召回摘要。
  - `short_project_root`：短篇目录；通常包含 `设定.md`、`小节大纲.md`、`正文.md`。
- 长任务启动前必须把 `追踪/workflow/tasks/<workflow_id>/task.json` 或 workflow packet 写成 JSON 草稿，并运行：
  ```bash
  node scripts/runtime-guard-validate.js --kind current-task 追踪/workflow/tasks/<workflow_id>/task.json --json
  node scripts/runtime-guard-validate.js --kind workflow-packet 追踪/workflow/workflow-packet-{stage_id}.json --json
  ```
  返回 `blocked_runtime_guard_missing` 或 `blocked_runtime_guard_incomplete` 时，不得启动专业模块、不得 spawn agent、不得进入全书扫描；先补齐预算、heartbeat、checkpoint、输出健康门和 stall 策略。
- 专业模块收到 `runtime_guard` 后，必须把它当作执行边界，而不是建议；如果当前任务规模已经超出预算，应返回 `paused_after_batch` 或 `blocked_verification_failed`，不要继续扩大范围。

### 创作记忆库上下文装配

当项目存在 `追踪/memory/lorebook.jsonl`、`追踪/memory/active-cast.json`，或当前 workflow 属于长篇写作、范围审阅、回炉修复、去 AI 味、导入吸收、拆文吸收时，`story-workflow` 在进入 L3 之前必须先读 [story-memory-context.md](story-memory-context.md) 和 [story-memory/SKILL.md](../../story-memory/SKILL.md)，再调用：

```bash
node scripts/context-assembler.js --project-root <book-root> --task <workflow-task> --target <target-range> --budget <budget> --json
```

`context_assembly` 必须写入 workflow packet，并至少包含上文 L2 到 L3 必填 schema 中列出的字段。

`workflow_packet.context_assembly.packet_md` 是 L3 读取创作记忆的优先入口；L3 模块不得绕过它直接扫描广泛原文。`status=blocked_memory_conflict` 时，不得继续生成正文、审稿报告或去 AI 改写，必须展示冲突条目和确认选项。`status=blocked_output_pollution` 时，按输出健康门恢复协议处理，先清理污染再进入 L3。L3 产物一旦被接受，`story-workflow` 需要调用 `memory-recommender.js` 记录记忆建议；高风险 canon、人物认知、伏笔和成长规则变更不得自动应用。

职责边界：`story-workflow` 只决定什么时候装配、什么时候记录建议、什么时候停靠用户确认；记忆协议、读写、压缩和注入由内部模块 `story-memory` 承担。短篇资讯学习、长篇人物使用、去 AI 味风格应用仍由各自领域子 skill 解释和执行。

## L3 到 L2 结果契约

专业模块完成一个步骤后，必须返回 result packet。result packet 是 L3 对 L2 的执行回执，说明做了什么、产物在哪里、验证是否通过、下一步建议是什么。

长篇章节写作还必须返回 `chapter_commit`：生产模式至少包含 `mode=transactional`、`transaction_id`、`accepted_commit_id`、`commit_file`、`projection_status` 和 `staged_artifacts`。正文存在不等于章节完成；只有 `chapter-commit.js accept` 已接受且记忆投影无债务，L2 才能关闭本章 `state_integration` 并进入下一章。`accepted_with_projection_debt` 必须先 replay；旧项目兼容直写只能返回 `mode=legacy_nontransactional`，并保留风险提示。

必填字段：

```text
workflow_id
stage_id
step_id
owner_module
lifecycle_node
asset_target
review_requirement
asset_revision
review_decision
downstream_effects
lifecycle_transition_request
result_write_set
step_status
outputs
changed_files
evidence
verification_result
blocking_reason
next_recommendation
handoff_summary
memory_updates
chapter_commit
checkpoint_state
heartbeat_update
budget_usage
output_health_result
handoff_packet_path
resume_hint
```

允许的 `step_status`：

```text
done
done_with_warnings
skipped_by_user
blocked_user_decision
blocked_missing_source
blocked_write_permission
blocked_write_hook
blocked_write_tool_call_invalid
blocked_write_missing_output
blocked_output_pollution
blocked_grounding_failed
blocked_verification_failed
paused_after_batch
paused_after_step
```

字段规则：

- `long_write` V2 result packet 的 `owner_module`、`lifecycle_node`、`asset_target` 和 `review_requirement` 必须逐项等于当前 running `stage_execution` 持久化的活动生命周期契约；缺失或不匹配返回 `blocked_longform_result_contract_mismatch`，不得投影结果。
- `asset_revision` 记录当前 `asset_target` 的已验证版本、接受状态和来源证据；候选稿、未接受事务和未验证报告不得伪装为新 revision。
- `review_decision` 明确记录 `pass|accepted|approved|revise|blocked|not_applicable` 及依据；`review_requirement.required=true` 时不得使用 `not_applicable`。
- `downstream_effects` 枚举本步骤导致的下游资产 `unlocked|invalidated|recheck_required|unchanged`，并附受影响范围；不得由 L3 直接修改下游生命周期状态。
- `lifecycle_transition_request` 只能请求 L2 执行 `advance|return_to_asset|repair_current|await_user_decision|stay`，并给出目标节点、原因和前置证据；专业模块不得自行推进生命周期。
- Result Packet 的 `result_write_set` 只能是 `write_set` 的子集，并且必须与 `changed_files`、`created_files` 完全一致；超出授权、未落盘或只读输入一律返回 `blocked_result_write_set_violation`。
- 必需审阅节点的成功回执必须显式声明 `step_status=completed` 和 accepted/approved/pass 的 `verification_result`。跳过、空值和不确定结果返回 `blocked_longform_review_acceptance_required`，不能解锁正文或其他下游资产。
- 专业模块必须回传 checkpoint_state：至少包含当前阶段、当前批次、完成范围、未完成范围、失败项、可复用产物和下一次恢复入口。
- `heartbeat_update` 写明最近可信产物、最近落盘时间、是否出现 stall/recap/API error/agent 0 token Done，以及是否已缩小任务粒度。
- `budget_usage` 写实际读取文件数、输出文件数、agent 数、批次数、可见回复长度和是否超过 `runtime_guard.adaptive_budget_policy`。
- `output_health_result` 写污染/退化/工程词/低信息密度检查结果；未检查时不得标 `verification_result=pass`。
- `handoff_packet_path` 指向压缩交接包；全局任务、多 agent 任务和范围级审阅不得把完整报告直接塞进 `handoff_summary`。
- `resume_hint` 必须可执行：说明用户说“继续/下一步/1”时从哪个 checkpoint 恢复，不能只写泛泛“继续处理”。
- result packet 落盘后必须运行：
  ```bash
  node scripts/runtime-guard-validate.js --kind result-packet 追踪/workflow/result-packet-{stage_id}-{step_id}.json --json
  ```
  返回 `blocked_result_packet_incomplete`、`blocked_output_health_failed` 或 `blocked_result_status_conflict` 时，L2 不得把该步骤标记完成；应保留最后可信 checkpoint，按 `blocking_reason` 进入修复、缩小范围或询问用户。

模块不能自行宣布整个 workflow 完成。专业模块只能声明当前 `stage_id/step_id` 的状态；是否进入下一阶段、是否完整完成、是否需要问用户，由 `story-workflow` 根据 `completion_policy`、`verification_result`、`blocking_reason` 和剩余 stages 决定。

若 `changed_files` 非空，必须列出相对路径。若 `verification_result=failed`，`step_status` 不得为 `done`。若需要跨模块继续，`next_recommendation` 必须写明目标模块和原因。

## 任务类型模板

### 长篇拆文

默认阶段：

```text
A. 原文预检与章节切片
B. 拆解策略选择：快拆全书 + 关键章深拆
C. 分批摘要与 source-grounding 校验
D. 串书/幻觉/缺引用修复
E. 剧情线、人物线、爽点线、情绪模块聚合
F. 作者式技巧吸收：读者欲望 -> 技巧机制 -> 可迁移骨架 -> 本书转译 -> 禁抄替换
G. 最终拆文报告和下游写作资产
```

大书拆文在用户确认完整拆解后，默认 `full_auto`；遇到缺源、grounding 失败、覆盖已有成果、权限/配额失败必须停。

### 审阅与修复

默认阶段：

```text
A. 范围锁定与连续性上下文
B. 分批审阅
C. 跨批综合
D. 修复方案
E. 用户确认修复范围
F. 交给 story-long-write 执行写入
G. 复检
H. 总收束报告
```

用户选择“先修复 A”表示 `stage_then_confirm`，执行 A1..An 后问是否继续 B/C/D。用户选择“只做 A1”表示 `step_then_confirm`，完成 A1 后展示下一步候选。

### 长篇写作

默认阶段：

```text
定位 -> 故事核心/创作圣经
-> 总纲 -> 总纲审阅
-> 当前卷卷纲 -> 卷纲审阅
-> 当前剧情阶段细纲 -> 细纲审阅
-> 当前章节 Brief -> Brief 审阅
-> 正文 -> 正文验收 -> 章节提交
-> 阶段复盘 -> 卷级验收/跨卷交接 -> 全书验收
```

正文、各层大纲、Brief 和结构修订必须交给 `story-long-write`；分层审阅与验收必须交给 `story-review`；事务提交和生命周期转移只由 `story-workflow` 决定。本 workflow 维护作品资产依赖、范围、风险、失效传播和交接，不暴露固定批次数作为用户任务。

长篇写作计划必须保留已确认章节标题和有用的既有内容，除非用户明确要求丢弃、废弃或重写这些内容。

### 其他模块

- 扫榜：数据源 -> 趋势提取 -> 作者式吸收 -> 选题候选。
- 导入：原文检测 -> 章节切分 -> 连续性资产重建 -> 写作交接。
- 去 AI 味：范围锁定 -> 只改表达 -> 事实保持检查 -> 风格门禁；短篇去 AI 味优先用 `story-short-write` 的 `short-deslop.md`。
- 封面：书籍信息 -> 类型视觉方向 -> prompt -> 出图 -> 文件交接。

## 恢复规则

用户说“继续 / 下一步 / 接着 / 选 A / 1 / 审阅 200-400”时：

1. 先读取 `追踪/workflow/current-task.json` 取得焦点 `workflow_id + task_dir`，再读取该 `task_dir/task.json` 的 durable authority。
2. 若有未完成步骤，优先恢复当前步骤。
3. 若上一批没有收束，先完成收束报告。
4. 若用户指定非连续范围，提示 gap 风险并登记。
5. 若下一步是覆盖、删除、迁移、批量改稿等高风险写入，必须确认。
6. 不得仅凭聊天记忆判断进度。

## 运行时巡检接口

前端刷新、后端重连、新会话启动或外部 runner 准备接管长任务时，先运行只读巡检：

```bash
node scripts/workflow-runtime-supervisor.js --project-root <book-root> --json
```

该脚本先从 `追踪/workflow/current-task.json` 取得焦点，再从对应 `tasks/<workflow_id>/task.json` 读取 `runtime_guard.heartbeat.updated_at`、`runtime_guard.stall_policy.heartbeat_timeout_minutes` 和 `runtime_guard.checkpoint_policy.resume_from`，返回确定性动作：

- `no_active_task / idle`：没有活跃 workflow，可以进入普通意图路由。
- `running / continue`：heartbeat 未超时，可以继续当前批次。
- `stalled / pause_at_checkpoint`：heartbeat 超时，保留最后可信断点，不继续等待模型自愈。
- `resumable / resume_from_checkpoint`：任务已暂停或 blocked，可从 checkpoint 续跑。
- `blocked_runtime_guard_missing / repair_runtime_guard`：状态文件缺运行边界，先修 `runtime_guard`，不得启动长任务。

`workflow-runtime-supervisor.js` 不替代 runner，也不启动 Claude；它只是把“是否该继续/暂停/续跑”从模型猜测变成机器可读决策。真正的进程重启、模型切换和流式早停由前端或后端 runner 执行。

supervisor 只判断焦点指针所指 durable task 的运行态；全局任务列表由 `workflow-task-inbox.js` 生成。两者顺序是：更新确认硬门禁 -> supervisor -> 全局任务收件箱 -> 目标专业模块。不得只因 supervisor 返回 `no_active_task` 就跳过 task inbox；短篇、审阅、拆文和续更任务可能存在于其他状态文件。

## 阻塞状态

阻塞状态必须写入 `tasks/<workflow_id>/task.json`；焦点指针不得承载 blocked 状态：

```text
blocked_missing_source
blocked_write_permission
blocked_write_hook
blocked_write_tool_call_invalid
blocked_write_missing_output
blocked_output_pollution
blocked_grounding_failed
blocked_user_decision
paused_after_batch
paused_after_step
completed_verified
```

每个阻塞状态必须包含：最后可信产物、失败步骤、原因、下一步候选、恢复入口。

## 输出要求

每次停靠或完成时，面向用户只输出：

- 已完成：阶段、步骤、产物、验证结果。
- 当前状态：`completion_policy`、`current_stage`、`current_step`、`status`。
- 下一步候选：继续、跳过、返回阶段导航、停止并保存断点，或需要用户裁决的具体选项。
- 恢复入口：统一写 `/novel-assistant 继续` 或更具体的自然语言入口。
