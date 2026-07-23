# stability-repair-loop.md：稳定性修复闭环

Stability Repair Loop 在 Stability Repair Dispatch 之后使用，用来反复生成“当前应修 checkpoint”，直到 Longform Daily Stability Audit 变为 PASS。它不自动改正文、契约或追踪文件，只负责调度、记录和给出重跑命令。

## 何时使用

- 日更总审计失败，且已经需要按修复清单逐项处理时使用。
- agent 需要知道“当前先修哪一项、修完跑什么命令”时使用。
- 多章修复过程中，每修完一项后重新运行，用新的审计结果决定下一项。

## 自动闭环

可用脚本：

```bash
bash scripts/stability-repair-loop.sh <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-loop.sh --write <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-loop.sh --write --json <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-loop.sh --write --json --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>
```

脚本会内部运行：

```bash
bash scripts/stability-repair-dispatch.sh --write --json <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-dispatch.sh --write --json --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>
```

`--write` 会保存闭环 checkpoint 到：

```text
追踪/稳定性审计/修复闭环_第{N}章_to_第{M}章.md
追踪/稳定性审计/第X卷/修复闭环_第{N}章_to_第{M}章.md
```

## JSON 输出

`--json` 输出机器可读 checkpoint：

```json
{
  "status": "NEEDS_REPAIR",
  "volume": "第X卷",
  "start_chapter": "001",
  "end_chapter": "002",
  "audit_report_path": "追踪/稳定性审计/第X卷/日更_第001章_to_第002章.md",
  "repair_report_path": "追踪/稳定性审计/第X卷/修复清单_第001章_to_第002章.md",
  "loop_report_path": "追踪/稳定性审计/第X卷/修复闭环_第001章_to_第002章.md",
  "current_owner": "narrative-writer",
  "current_action": {
    "id": "R1",
    "priority": "P1",
    "owner": "narrative-writer",
    "code": "Continuity_Missing",
    "target_chapter": "002"
  },
  "verification_commands": [
    "bash scripts/cross-chapter-continuity-audit.sh --volume 第X卷 <book-dir> 001 002",
    "bash scripts/stability-repair-loop.sh --write --volume 第X卷 <book-dir> 001 002"
  ]
}
```

`status` 只有两种：

| status | 含义 |
|---|---|
| `PASS` | 当前批次无待修项，可以汇报完成 |
| `NEEDS_REPAIR` | 存在待修项，必须先处理 `current_action` |

`current_owner` 是当前 checkpoint 建议先调用的代理，等同于 `current_action.owner` 的顶层快捷字段。常见分派：

| code | current_owner |
|---|---|
| `Knowledge_Leak` / `Motivation_Drift` | `character-designer` |
| `Plot_Drift` / `Beat_Missing` / `Foreshadow_Early_Payoff` / `Beat_Compressed` | `story-architect` |
| `Continuity_Missing` / `State_Not_Updated` / `Untracked_Addition` | `narrative-writer` |
| `Canon_Conflict` / `Stability_Check_Failed` | `consistency-checker` |

当 `current_owner=character-designer` 时，runner 应先请求角色裁决，不要直接让正文代理整章重写。

## 执行规则

1. 每次只处理 `current_action`，不要同时修多个章节或多个错误码。
2. 修完当前 action 后，先运行 `verification_commands` 中对应 gate，再重新运行 `stability-repair-loop.sh`。卷目录项目必须保留 `--volume 第X卷`，不得退回默认第 1 卷。
3. `status=NEEDS_REPAIR` 时脚本退出码为非 0，不得宣布本批完成。
4. `current_action` 为空且 `status=PASS` 时，闭环结束。
5. 闭环脚本不会替代人工或 agent 的实际改文；它只负责把修复过程变成可重复、可追踪的 checkpoint。
