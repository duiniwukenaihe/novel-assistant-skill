# 创作记忆库与上下文装配契约

创作记忆库借鉴 SillyTavern World Info / Lorebook 的动态上下文思想，但不复制角色扮演 UI。用户仍只调用 `/novel-assistant`。

## 文件

- `追踪/memory/lorebook.jsonl`: 角色、关系、地点、势力、物品、规则、伏笔、情节状态、读者画像、作者声口、平台风格和反向约束。
- `追踪/memory/active-cast.json`: 当前范围内出场人物、离场人物、认知边界、活动伏笔、禁止提前揭示项。
- `追踪/memory/memory-suggestions.jsonl`: 写作、审阅、拆文、导入、回炉后的记忆变更建议。
- `追踪/memory/memory-audit.jsonl`: 已应用或拒绝的记忆变更审计。
- `追踪/context-pack/{task-id}.assembled-context.json`: 机器可读上下文装配结果。
- `追踪/context-pack/{task-id}.assembled-context.md`: 给 L3 模块读取的精简上下文。
- `追踪/workflow/tasks/<workflow_id>/rpd.md`: 当前任务的需求与读者承诺，作为任务级上下文优先输入。
- `追踪/workflow/tasks/<workflow_id>/context.jsonl`: 当前任务显式上下文清单。每行包含 `kind/path/reason`，只读取项目内明确列出的文件。

## 条目类型

`character`, `relationship`, `location`, `faction`, `object`, `rule`, `hook`, `plot_state`, `reader_persona`, `author_voice`, `platform_style`, `negative_constraint`.

## 激活原则

上下文装配不是关键词匹配。必须综合任务类型、目标范围、触发词、别名、出场人物、活动伏笔、优先级、sourceRefs 和 token 预算。

当调用方提供 `workflow_id + task_dir` 时，`context-assembler.js` 只读取该耐久任务快照，注入 `rpd.md` 与 `context.jsonl` 指定文件，不受 UI 焦点切换影响。只有只读交互查询未提供任务身份时，才允许从 `current-task.json` 定位焦点；任何写入或 Result Packet 不得据此猜测目标。旧项目没有任务目录时按迁移协议提示，不把旧指针继续当正式任务事实。

`context.jsonl` 是显式清单，不是全书扫描许可。越界路径、目录、缺失文件或非法 JSONL 只记录 warning；不得把越界路径或工具日志注入给 L3 读取的 markdown context。

## 写作边界

创作记忆库不能静默改正文、大纲、细纲、设定或追踪创作资产。记忆建议必须先写入 `memory-suggestions.jsonl`。改变 canon、人物认知、伏笔回收、成长规则、章节编号或用户风格偏好的建议必须等待用户确认。

旧任务迁移遵循“向前兼容 + 明示迁移”：更新协作环境可以只读诊断旧断点，但不得静默迁移或改写创作资产。若需要把旧 `current-task.json` / 旧审查报告 / 旧拆文进度恢复成新任务目录，必须展示恢复选项，用户确认后再创建任务账本。

## 污染门禁

记忆条目、装配后的可见上下文和记忆建议都必须避免模型退化循环、工具日志、工程词泄露和低信息密度填充。命中污染时返回 `blocked_output_pollution`，不得写入 L3 输入。

## 记忆建议与安全应用

L3 模块完成写作、审阅、拆文、导入或回炉后，只能在 Result Packet 中回传 `memory_updates`。L2 接受回执后，由 runner 统一调用 `scripts/memory-recommender.js` 记录建议；建议默认先进入 `追踪/memory/memory-suggestions.jsonl`，再按风险决定是否应用。L3 不得绕过 workflow 直接写记忆。

低风险新增条目可以自动应用，前提是它只做新增、不改已确认事实、不改人物认知边界、不改伏笔时点或回收、不改成长/经营/力量规则、不改章节编号，也不改用户风格偏好。`--apply-low-risk` 不能只信任 `action=create` 和 `risk=low` 标签，必须按建议语义做保守筛查；只要命中上述任一类，就停在确认门。对 `create` 类型且 `risk=low` 的建议，若目标 `entryId` 不存在且语义筛查通过，可直接写入 `追踪/memory/lorebook.jsonl`，并把审计写入 `追踪/memory/memory-audit.jsonl`。

其余建议都要停在确认门：更新、替换、合并、删除、改 canon、改风格、改知识边界、改伏笔时点，或目标条目已经存在时，一律记录 `requires_confirmation` 审计，必要时返回 `blocked_confirmation_required`。

记忆建议本身也要过污染门。若 `proposedContent` 命中模型退化循环、工程词泄露、工具日志或低信息密度重复块，必须返回 `blocked_output_pollution`，不要写入建议文件，更不要进入应用流程。
