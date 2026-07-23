# Review Escalation Policy

本策略用于判断当前章节、短篇小节、修复项或审阅范围是否需要多角色阅读。目标是把审阅能力放在真正高价值的位置，而不是每个生产单元都烧完整审查。

## 核心原则

- 普通章节/小节默认不跑多角色审阅。每个单元仍必须完成机器门、故事价值门、状态更新和交接包。
- 机器门 blocking 时先修当前单元，不进入多角色阅读。脏稿拿去审阅会浪费 token，也会污染判断。
- 多角色阅读只在“故事判断风险高”或“用户明确不满意”时升级。
- 升级策略由 `scripts/review-escalation-policy.js` 产出 JSON，前端、CLI、runner 和 workflow 都读取同一结果。

## 升级等级

| 等级 | 触发 | 角色 | 成本 |
|---|---|---|---|
| `none` | 普通单元，机器门和故事价值门都通过，非周期节点 | 无 | low |
| `light_dual_role` | 每 5 个生产单元一次，或轻微连续性风险 | `reader_value`、`continuity` | medium |
| `full_multi_role` | 高潮、反转、卷首卷尾、关系质变、跨卷、扩容、发布、故事价值门未过、用户反馈不好看/不合理/人物不像人/没爽点 | `reader_value`、`continuity`、`character_motivation`、`commercial_hook` | high |

## 运行方式

```bash
node scripts/review-escalation-policy.js --json \
  --chapter <n> \
  --chapter-type normal \
  --machine-gate pass \
  --story-value pass
```

常用参数：

- `--chapter <n>`：当前章或短篇小节序号。
- `--batch-size <n>`：周期轻审间隔，默认 5。
- `--chapter-type normal|climax|reversal|volume_start|volume_end|relationship_shift`。
- `--machine-gate pass|blocking|failed`。
- `--story-value pass|revise|blocked`。
- `--user-feedback <text>`：用户反馈中出现不好看、不吸引、人物不像人、剧情不合理、没爽点等，会触发 full。
- `--cross-volume`、`--expansion`、`--release`：跨卷、扩容、发布节点触发 full。

## Result Packet 字段

L3 模块或 runner 返回给 `story-workflow` 的 result packet 应包含：

```text
review_escalation_result: none | light_dual_role | full_multi_role
escalation_level: none | light_dual_role | full_multi_role
review_roles: []
cost_class: low | medium | high
reason_codes: []
next_action: continue_handoff | repair_current_unit | run_light_review | run_full_review
```

当 `next_action=repair_current_unit` 时，不得调用 reviewer；先修当前单元并复扫机器门。当 `run_light_review` 或 `run_full_review` 完成后，再按 findings 决定回到 brief/contract、当前单元修订、状态入账或交接下一单元。

## 成本边界

- 每章完整审查不是生产默认值。
- 轻审只看读者价值与连续性，不展开四角色报告。
- 完整审查必须有明确触发原因，并把原因写入 `reason_codes`。
- 如果用户只要求“继续写下一章/下一节”，且上一单元没有 blocking 或关键节点，不因为“更保险”而升级。
