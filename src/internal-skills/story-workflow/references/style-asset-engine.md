# Style Asset Engine / 写法资产引擎

## Background

AI-Novel-Writing-Assistant 的写法引擎把风格从一次性 prompt 变成可保存、编辑、绑定、试写、复用的长期资产。`novel-assistant` 已有 author voice profile 和去 AI 门禁，但需要把它们收束成 workflow 可消费的写法资产。

## Decision

写法资产不是通用 humanizer。它服务于当前书、当前赛道和用户确认过的优秀样本，用于减少 AI 味、保持声口、控制节奏，而不是把所有文本改成同一种“像人”的模板。

## Asset Files

```text
设定/作者风格/style-feature-pool.jsonl
设定/作者风格/style-binding.json
设定/作者风格/style-compile-report.md
追踪/workflow/author-voice.json
```

## style_feature_pool

每条特征至少包含：

```text
feature_id
source_path
feature_type: sentence_rhythm | dialogue_ratio | paragraph_shape | sensory_detail | humor | taboo_expression | punctuation_habit
description
positive_examples
negative_examples
status: active | disabled | pending
confidence
```

## style_binding

`style_binding` 说明某个 workflow 使用哪些风格资产：

```text
workflow_type
target_scope
enabled_features
disabled_features
anti_ai_constraints
verification_policy
```

## Rules

- 写作前读取已确认风格资产；没有确认样本时，不编造作者声口。
- 去 AI 味优先修硬污染、工具痕迹、模板解释腔、占位符和模型循环；不得抹平用户认可的强情绪或口语化表达。
- 每次从用户修改稿学习风格，先生成 `style_compile_report.md`，只把低风险偏好写入 active，高风险偏好等待确认。
- 短篇可绑定商业情绪和赛道风格；长篇必须同时绑定事实保留、伏笔保留和角色状态保留。
