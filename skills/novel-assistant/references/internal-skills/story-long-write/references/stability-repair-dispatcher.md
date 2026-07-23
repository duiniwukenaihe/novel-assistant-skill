# stability-repair-dispatcher.md：稳定性修复分派器

Stability Repair Dispatch 在 Longform Daily Stability Audit 之后使用，把审计 JSON 转成按优先级排序的修复清单。它只生成修复计划，不自动改正文、契约或追踪文件。

## 何时使用

- 日更总审计失败后，先生成修复清单再动手改文。
- agent 或 hook 需要按错误码分派修复任务时使用。
- 多章回炉后，需要确认先修哪一章、哪一种稳定性问题时使用。

## 自动分派

可用脚本：

```bash
bash scripts/stability-repair-dispatch.sh <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-dispatch.sh --write <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-dispatch.sh --write --json <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/stability-repair-dispatch.sh --write --json --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>
```

脚本会内部运行：

```bash
bash scripts/longform-daily-stability-audit.sh --write --json <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/longform-daily-stability-audit.sh --write --json --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>
```

因此无论审计通过或失败，都会先保存日更审计报告到：

```text
追踪/稳定性审计/日更_第{N}章_to_第{M}章.md
追踪/稳定性审计/第X卷/日更_第{N}章_to_第{M}章.md
```

`--write` 会额外保存修复清单到：

```text
追踪/稳定性审计/修复清单_第{N}章_to_第{M}章.md
追踪/稳定性审计/第X卷/修复清单_第{N}章_to_第{M}章.md
```

`--json` 输出机器可读修复队列，用于 runner、hook、CI 或 agent 编排：

```json
{
  "status": "FAIL",
  "volume": "第X卷",
  "failures": 1,
  "start_chapter": "001",
  "end_chapter": "002",
  "audit_report_path": "追踪/稳定性审计/第X卷/日更_第001章_to_第002章.md",
  "repair_report_path": "追踪/稳定性审计/第X卷/修复清单_第001章_to_第002章.md",
  "actions": [
    {
      "id": "R1",
      "priority": "P1",
      "owner": "narrative-writer",
      "scope": "第 001 章 -> 第 002 章",
      "check": "跨章连续性",
      "code": "Continuity_Missing",
      "target_chapter": "002",
      "steps": ["先修第 002 章 Chapter Contract，补入上一章交接包继承项。"]
    }
  ]
}
```

自动化场景推荐使用 `--write --json`：Markdown 修复清单给人回看，JSON 的 `actions` 给程序逐项调度。

## 输出模板

```md
## Stability Repair Dispatch

- 审计状态：FAIL
- 失败数：1
- 章节范围：第 001 章 - 第 002 章
- 审计报告：追踪/稳定性审计/第X卷/日更_第001章_to_第002章.md

### 修复队列
| priority | owner | scope | check | code | next action |
|---|---|---|---|---|---|
| P1 | narrative-writer | 第 001 章 -> 第 002 章 | 跨章连续性 | Continuity_Missing | 先修第 002 章 Chapter Contract，补入上一章交接包继承项。 |

### 修复步骤
#### R1 第 001 章 -> 第 002 章 / Continuity_Missing
1. 先修第 002 章 Chapter Contract，补入上一章交接包继承项。
2. 再修第 002 章正文，把继承项写成可见行动、线索或反馈。
3. 重跑 Plot Drift Gate、State Delta Ledger、Chapter Handoff Pack。
4. 重跑 Cross Chapter Continuity Audit，确认契约和正文都继承成功。
```

## 分派规则

| code | priority | owner | 修复方向 |
|---|---|---|---|
| `Canon_Conflict` | P0 | consistency-checker | 先统一 canon；如要改 canon，先做 Revision Impact Analysis |
| `Knowledge_Leak` | P0 | character-designer | 先做角色裁决：补获知过程 / 删除越界认知 / 更新角色不变量 / 需要用户确认 |
| `Plot_Drift` | P1 | story-architect | 回到 Chapter Contract，删除、改写或后移偏离内容 |
| `Motivation_Drift` | P1 | character-designer | 先做角色裁决：补动机链 / 改行动 / 更新角色不变量 / 需要用户确认 |
| `Continuity_Missing` | P1 | narrative-writer | 先修下一章 Chapter Contract，再修正文，最后重跑跨章审计 |
| `Beat_Missing` | P1 | story-architect | 补写缺失 beat，或修改契约并说明原因 |
| `Foreshadow_Early_Payoff` | P1 | story-architect | 改为推进、误导、半兑现或延迟兑现 |
| `State_Not_Updated` | P2 | narrative-writer | 补 State Delta，并同步追踪文件 |
| `Untracked_Addition` | P2 | narrative-writer | 把新增项写入设定/追踪，再补 State Delta |
| `Beat_Compressed` | P2 | story-architect | 把摘要带过的重要 beat 拆成可感场景 |
| `Stability_Check_Failed` | P2 | consistency-checker | 无错误码兜底；先读 Diagnostics，再按失败 gate 修复 |

`owner` 是建议的首个处理代理，不代表该代理可以直接改所有文件。`Knowledge_Leak` 和 `Motivation_Drift` 必须先由 `character-designer` 输出角色裁决，再按裁决边界交给 `narrative-writer` 做局部正文修补，或在需要改变长期人设时暂停给用户确认。

## 执行规则

1. 分派器失败退出码表示仍有稳定性问题，不得宣布本批完成。
2. 修复时按 P0 → P1 → P2 顺序处理；同优先级按章节顺序处理。
3. `Continuity_Missing` 必须先修目标章契约，再修目标章正文，不要只补正文。
4. 无错误码时使用 `Stability_Check_Failed` 兜底，必须回看审计报告的 `Diagnostics`。
5. 自动化调用使用 `--json` 时，必须以 exit code 和 `status` 字段共同判断是否完成；`actions` 为空只代表本次审计未发现修复项。
6. 修复清单只是计划；每项修复后仍必须重跑对应 Gate 和 Longform Daily Stability Audit。
