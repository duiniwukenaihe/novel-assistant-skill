# 细纲质量门

`detail_outline_review` 先运行确定性质量门：

```bash
node scripts/detail-outline-quality-check.js --project-root <book-root> --outline <细纲相对路径> --workflow-id <workflow-id> --write-result <workflow-result-packet> --json
```

细纲完成不等于可写。基础门通过后，才按激活标签进行最小语义审阅。只有 `detail_outline_review` 的 workflow-scoped result packet 为 `pass` 或 `pass_with_advisory`，且 `workflow_id`、`stage_id`、`outline_path`、`outline_sha256` 全部匹配，才可生成 Chapter Brief。`outline_underfilled` 必须回到细纲补足，不得以正文临场补剧情。

## 新项目剧情单元合同

新生成或主动升级的长篇细纲必须包含 `剧情单元合同`；旧细纲没有该区段时保持 `legacy_compatible`，只提示迁移，不阻断续写。区段字段如下：

```md
## 剧情单元合同
- 剧情单元ID：PU-V01-001
- 单元位置：1/4
- 本章读者问题：
- 本章可见回报：
- 关键转折：
- 本章净变化：
- 继承钩子责任：
- 终局储备动作：不动用 / 推进但不揭底 / 解锁 TR-...
```

声明该区段后八项缺一即返回 `B5_narrative_contract`，不能进入正文。`剧情单元ID` 在同一剧情单元的多章中保持不变，`单元位置` 递增；禁止为了过门而现场伪造来源单元或终局底牌。

## 最小语义审阅

- 普通风险由主会话完成语义审阅，不启动多 agent fan-out。
- 高风险标签含 `climax`、`volume_end`、`ability_transition` 或 `major_reversal` 时，只调用一个 `story-architect`。
- 仅当唯一高风险是跨章连续性时，只调用一个 `consistency-checker`。
- 语义审阅者只返回 findings，不得编辑细纲或正文。失败时先修订细纲，再重新运行确定性门。

审阅者只能在所属任务目录写临时文件：`追踪/workflow/tasks/<workflow-id>/work/detail-outline-semantic-review.json`。它不是官方 result packet；CLI 校验其路径和 identity，并将 findings 合并后一次性写入官方 result packet。

```json
{
  "outline_path": "大纲/第1卷/细纲_第001章.md",
  "outline_sha256": "64-lowercase-hex",
  "reviewer": "story-architect",
  "findings": [
    {
      "dimension": "C7_payoff_debt",
      "severity": "blocking",
      "message": "反击没有产生可见后果",
      "evidence": "爽点字段仅写完成打脸",
      "suggested_action": "补出对手失去什么、主角获得什么以及剩余债务"
    }
  ]
}
```
