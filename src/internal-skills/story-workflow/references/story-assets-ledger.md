# Story Assets Ledger / 角色与事实资产账本

## Background

长篇跑题常常不是因为单章不会写，而是角色状态、事实公开程度、伏笔、世界规则和待确认提案混在一起。AI-Novel-Writing-Assistant 的角色资源账本和 pending 候选角色机制值得吸收。

## Decision

`novel-assistant` 在 skill 层定义轻量资产账本，不引入数据库。所有事实进入正文前必须区分：

- `confirmed_facts`: 已确认、可被正文当作既成事实。
- `pending_cast_candidates`: 候选角色、候选身份、候选关系，需用户或 workflow 确认。
- `chapter_participants_context`: 本章真正参与者，不把全书角色表塞进 prompt。
- `fact_proposals`: L3 模块提出的新事实，默认待确认。

## File Targets

```text
追踪/memory/story-assets-ledger.jsonl
追踪/memory/pending-cast-candidates.jsonl
追踪/memory/chapter-participants-context.json
追踪/memory/fact-audit.jsonl
```

## Rules

- 待确认提案不得写成既成事实。
- 单章写作前，context assembler 只装配本章参与者、相关伏笔和必要世界规则。
- agent 可以提取候选事实，但生产文件只能由主 workflow 或 designated merge step 写入。
- 新角色、新关系、新身份、新世界规则进入 `fact_proposals` 后，低风险项可自动记忆，高风险项必须等待确认。
- 审阅和回炉时必须以 `confirmed_facts` 为事实底座，不能把旧聊天中的猜测当 canon。

## Examples

- “疑似师父真实身份”是 `fact_proposals`，不是 `confirmed_facts`。
- “第 12 章主角已知道读心术限制”是 `confirmed_facts`，后续章节不能假装不知道。
- “第 13 章只出现主角、师姐、掌柜”时，只注入这三人的上下文和相关伏笔。
