# stability-agent-dispatch-prompts.md：稳定性修复 Agent 分流 Prompt

本文件用于 Longform Daily Stability Audit 失败后的 agent 编排。主会话或 runner 已经通过 `stability_repair_load` 或 `stability-repair-loop.sh --write --json` 获得：

- `current_owner`
- `current_action`
- `audit_report_path`
- `repair_report_path`
- `loop_report_path`
- `verification_commands`

分流原则：按 `current_owner` 选择首个 agent，只处理当前 checkpoint，不同时修多个 action。

## 自动生成

可用脚本：

```bash
bash scripts/stability-agent-dispatch-prompt.sh <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-agent-dispatch-prompt.sh --json <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-agent-dispatch-prompt.sh --json --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>
```

脚本会内部运行：

```bash
bash scripts/stability-repair-loop.sh --write --json <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-loop.sh --write --json --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>
```

默认输出 Markdown，包含 `Agent(subagent_type: "...", prompt: "...")` 调用文本。`--json` 输出机器可读对象，包含 `volume`、`current_owner`、`subagent_type`、`prompt` 和 `agent_call`。卷目录项目必须保留 `--volume 第X卷`，这样 `verification_commands`、`audit_report_path`、`repair_report_path` 和 `loop_report_path` 都指向同一卷；旧平铺项目才省略 `--volume`。脚本只生成 prompt，不直接执行 agent。

## 通用 Prompt 字段

所有 owner 的 prompt 必须包含：

```text
项目目录：{book_dir}
任务类型：Stability Repair Loop checkpoint
current_owner：{current_owner}
current_action：{JSON.stringify(current_action)}
audit_report_path：{audit_report_path}
repair_report_path：{repair_report_path}
loop_report_path：{loop_report_path}
verification_commands：{逐条列出}
硬约束：
- 只处理 current_action.id 指定的当前 checkpoint。
- 不处理 remaining_actions 中的其他问题。
- 不整章重写；除非 current_action.steps 明确要求，也不改其他章节。
- 如果 verification_commands 含 `--volume 第X卷`，后续复查命令必须原样保留，不得退回平铺路径。
- 输出必须保留 current_action、修改边界、后续 verification_commands。
```

## current_owner = character-designer

用于 `Knowledge_Leak`、`Motivation_Drift`，或任何需要改角色不变量、动机链、认知边界、行为红线、语言边界的 checkpoint。

```text
Agent(subagent_type: "character-designer", prompt: "
项目目录：{book_dir}
任务类型：Stability Repair Loop 角色裁决
current_owner：character-designer
current_action：{current_action_json}
audit_report_path：{audit_report_path}
repair_report_path：{repair_report_path}
loop_report_path：{loop_report_path}
verification_commands：
{verification_commands}

请只做角色裁决，不直接重写正文。
必须读取涉及角色的 设定/角色/{角色名}.md、设定/角色不变量/{角色名}.md、追踪/角色状态.md，以及 target_chapter 对应正文、Chapter Contract、细纲。
角色裁决只能从以下范围选择：
补动机链 / 改行动 / 补获知过程 / 删除越界认知 / 更新角色不变量 / 需要用户确认

输出：
1. current_action 复述
2. 角色裁决
3. 裁决理由
4. 修改边界
5. 是否需要 narrative-writer 做局部正文修补
6. verification_commands
")
```

## current_owner = story-architect

用于 `Plot_Drift`、`Beat_Missing`、`Beat_Compressed`、`Foreshadow_Early_Payoff`，或需要改契约、细纲、伏笔计划的 checkpoint。

```text
Agent(subagent_type: "story-architect", prompt: "
项目目录：{book_dir}
任务类型：Stability Repair Loop 结构裁决
current_owner：story-architect
current_action：{current_action_json}
audit_report_path：{audit_report_path}
repair_report_path：{repair_report_path}
loop_report_path：{loop_report_path}
verification_commands：
{verification_commands}

请只做结构裁决，不直接重写正文。
必须读取 target_chapter 对应卷纲、细纲、Chapter Contract、正文、伏笔追踪和审计报告。
结构裁决只能从以下范围选择：
改正文 / 改契约 / 改细纲 / 后移伏笔 / 需要用户确认

输出：
1. current_action 复述
2. 结构裁决
3. 裁决理由
4. 修改边界
5. 是否需要 narrative-writer 做局部正文修补
6. verification_commands
")
```

## current_owner = narrative-writer

用于 `Continuity_Missing`、`State_Not_Updated`、`Untracked_Addition`，或已由上游裁决为正文局部修补的 checkpoint。

```text
Agent(subagent_type: "narrative-writer", prompt: "
项目目录：{book_dir}
任务类型：Stability Repair Loop 局部修复
current_owner：narrative-writer
current_action：{current_action_json}
上游裁决：{character_or_architect_decision_or_none}
audit_report_path：{audit_report_path}
repair_report_path：{repair_report_path}
loop_report_path：{loop_report_path}
verification_commands：
{verification_commands}

只改当前 checkpoint，只改 target_chapter 或 current_action.steps 明确要求的文件。
禁止整章重写。
必须保留 Chapter Contract 的必须 beat，不得新增未追踪设定。

输出：
1. current_action 复述
2. 实际修改文件
3. 修改范围
4. 是否仍需 consistency-checker 审查
5. verification_commands
")
```

## current_owner = consistency-checker

用于 `Canon_Conflict`、`Stability_Check_Failed`，或修复后需要 checkpoint 审查的场景。

```text
Agent(subagent_type: "consistency-checker", prompt: "
项目目录：{book_dir}
任务类型：Stability Repair Loop checkpoint 审查
current_owner：consistency-checker
current_action：{current_action_json}
audit_report_path：{audit_report_path}
repair_report_path：{repair_report_path}
loop_report_path：{loop_report_path}
verification_commands：
{verification_commands}

只审查当前 checkpoint，不做全书泛审。
请对照审计报告、修复清单、修复后的目标文件，判断 current_action 是否已经解决。

输出：
1. current_action 复述
2. checkpoint 审查结果：PASS / FAIL
3. 仍失败时的错误码和证据
4. 是否需要重跑 stability-repair-loop.sh
5. verification_commands
")
```

## 需要用户确认

任一 agent 输出 `需要用户确认` 时，主会话必须暂停修复闭环，向用户说明会改变的长期结构或长期人设，不得自行继续改写。
