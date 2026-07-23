# longform-daily-stability-audit.md：日更稳定性总审计

Longform Daily Stability Audit 在一批日更章节完成后执行，用来确认本批每章都通过单章稳定性闭环，并且相邻章节之间完成交接继承。

## 何时使用

- 批量日更完成后，进入最终汇报前使用。
- 用户要求继续下一批章节前，先对上一批执行。
- 回炉、改纲或补写导致多个相邻章节变化后，对受影响范围执行。

## 自动审计

可用脚本：

```bash
bash scripts/longform-daily-stability-audit.sh <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/longform-daily-stability-audit.sh --write <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/longform-daily-stability-audit.sh --write --json <book-dir> <start-chapter-id> <end-chapter-id>
bash scripts/longform-daily-stability-audit.sh --write --json --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>
```

默认输出 Markdown 到 stdout；`--write` 会落盘到：

```text
追踪/稳定性审计/第X卷/日更_第{N}章_to_第{M}章.md
```

旧平铺项目可省略 `--volume`，落盘到 `追踪/稳定性审计/日更_第{N}章_to_第{M}章.md`。

即使审计失败，`--write` 也必须保存包含 `Diagnostics` 的失败报告，供回炉定位问题。

`--json` 输出机器可读结果，用于 hook、CI、agent 或仪表盘判断：

```json
{
  "status": "PASS",
  "failures": 0,
  "start_chapter": "001",
  "end_chapter": "002",
  "report_path": "追踪/稳定性审计/日更_第001章_to_第002章.md",
  "checks": [
    {
      "scope": "第 001 章",
      "check": "单章稳定性",
      "result": "PASS",
      "error_codes": []
    }
  ]
}
```

自动化场景推荐同时使用 `--write --json`：Markdown 报告给人回看，JSON 给程序分流处理。

脚本会组合执行：

- `scripts/chapter-stability-check.sh`：逐章检查 Chapter Contract、Plot Drift Gate、State Delta 和角色不变量。
- `scripts/cross-chapter-continuity-audit.sh`：从第 2 个章节开始检查上一章交接包是否进入本章契约和正文。

单章稳定性检查会读取 `设定/角色不变量/*.md` 的硬边界：

- `认知边界` 中的 `不能提前知道：X` 如果直接出现在正文，会报告 `Knowledge_Leak`。
- `行为红线` 中的 `不会：Y` 如果直接出现在正文，会报告 `Motivation_Drift`。

这类检查是自动化底线，不替代 Plot Drift Gate 的人工/agent 语义审查；它负责把明显越界写法转成可分派的错误码。

## 输出模板

```md
## Longform Daily Stability Audit

- 章节范围：第 N 章 - 第 M 章

### Checks
| scope | check | result |
|---|---|---|
| 第 N 章 | 单章稳定性 | PASS/FAIL |
| 第 N 章 -> 第 N+1 章 | 跨章连续性 | PASS/FAIL |

### 结论
- Audit: PASS/FAIL
- failures:

### Diagnostics
#### 第 N 章 | 单章稳定性

```text
失败子检查输出
```
```

## 执行规则

1. 总审计是最终汇报前的批量门控，不替代单章写作时的即时 Gate。
2. 任一章节单章稳定性失败，本批不得宣布完成。
3. 任一相邻章节连续性失败，先修下一章契约和正文，再重跑 Plot Drift Gate、State Delta Ledger、Chapter Handoff Pack 和 Cross Chapter Continuity Audit。
4. 总审计失败时必须保留 `Diagnostics`，不要只报告 PASS/FAIL；诊断应包含失败子检查的原始输出。
5. 推荐日更流程使用 `--write` 保存审计报告；失败报告也必须落盘。
6. 自动化调用使用 `--json` 时，必须以 exit code 和 `status` 字段共同判断结果；不要只解析 stdout 文本。
7. 总审计通过后，才能进入下一批章节或对用户汇报本批日更完成。
