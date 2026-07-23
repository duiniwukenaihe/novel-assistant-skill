# Structured Intent Routing / 结构化意图路由

## Background

AI-Novel-Writing-Assistant 强调 AI-first decision support：意图识别、任务分类、规划和工具选择优先输出结构化判断，而不是继续叠关键词和正则。`novel-assistant` 吸收这个原则，用于改进单入口 router 的稳定性。

## Decision

自然语言进入 `/novel-assistant` 后，应先形成 `intent_schema`，再选择 L2 workflow 和 L3 专业模块。关键词只作为证据，不作为唯一裁决。

## intent_schema

```text
intent_schema
  intent_type: long_write | short_write | review | revise | analyze | scan | deslop | setup_update | import | cover | unknown
  target_scope: chapter | range | volume | book | short_project | artifact | unknown
  user_goal: 原始用户目标的中文短句
  route_confidence: 0.00-1.00
  evidence: 命中的语义证据、文件证据或上下文证据
  required_inputs: 继续前必须确认的输入
  fallback_question: route_confidence 不足时只问一个关键问题
  selected_workflow_type
  selected_owner_module
```

## Rules

- `route_confidence >= 0.75`：直接路由，并在 workflow packet 写入 intent schema。
- `0.45 <= route_confidence < 0.75`：可做低风险只读探查，但不能写正文/大纲/细纲。
- `route_confidence < 0.45`：只问一个 `fallback_question`。
- 更新确认、破坏性写入、覆盖、删除、目录迁移仍优先于 intent schema。
- 如果用户输入明显是新目标，先用 `switch-intent` 新建 workflow，不把它解释成旧 pending action。

## Failure Modes

- 用户说“更新”：必须区分 skill/协作环境更新和“更新大纲”阶段。
- 用户说“继续”：必须先查 `pending_action`、workflow task inbox 和 checkpoint，不从聊天记忆猜。
- 用户说“修真进度”：只有当前书有题材证据时才使用修真词；否则归一为成长/能力/世界规则一致性。
