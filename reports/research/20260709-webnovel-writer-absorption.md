# webnovel-writer 参考项目吸收报告

- Date: 2026-07-09
- Project: `lingfengQAQ/webnovel-writer`
- Repo: https://github.com/lingfengQAQ/webnovel-writer
- Checked commit: `59654ccaa17f240c5ae41fe51db9443284f8ca1f`
- Tag observed: `v6.2.1`
- License: GPL-3.0
- Absorb mode: `clean-room-design-only`

## 结论

值得吸收，但只能吸收设计思想，不能复制源码、长段 prompt、CSV 数据或文档内容。

`webnovel-writer` 的核心价值不是“又一个写作 prompt”，而是把长篇写作工程化为合同、写章、审查、章节提交、投影、查询和体检。它解决的问题与 `novel-assistant` 的长篇稳定性目标高度一致：写到几百章后仍能保持设定、伏笔、人物状态和大纲不漂移。

## 可吸收设计

| 设计 | 价值 | novel-assistant 映射 |
|---|---|---|
| Story System / 写前合同 | 把大纲、卷、章、审查约束变成写前硬约束 | 加强 `story-workflow` 的 workflow contract 与 `story-long-write` 的章节契约 |
| Chapter Commit | 写后事实必须先被接受，再进入状态系统 | 新增轻量 `chapter-commit ledger`：正文通过质量门后才写入人物状态、伏笔、规则和关系 |
| Projection Replay | 状态/摘要/记忆写入失败时可补跑，不重写正文 | 补 `projection retry` / `workflow doctor` 类脚本或协议 |
| Context / Reviewer / Data Agent 分工 | 写前、审查、事实提取分离，避免主流程自说自话 | 强化 agent read/write ownership，主流程只编排与验收 |
| 作者友好报告 | 最终报告面向作者，不暴露 JSON、traceback、长命令 | 与现有 `workflow result packet` 合并，要求每个长任务收尾给状态、产物、问题、下一步 |
| 长期记忆分层 | working / episodic / semantic 分层读取，减少上下文污染 | 映射到 `story-memory` 的上下文装配、用户偏好、角色/伏笔/规则注入 |

## 拒绝项

- 不吸收它的多斜杠命令体系。`novel-assistant` 仍坚持单入口 `/novel-assistant`。
- 不引入它的 Python 大型 runtime。该项目脚本体量很大，直接引入会提高维护成本。
- 不引入 Dashboard。当前前端独立在 `novel-project`，skill 层只保留数据契约。
- 不复制 `references/csv`、题材模板、agent prompt 或脚本实现。GPL-3.0 不适合直接并入本项目公开发布线。

## 建议实现优先级

### P1：章节提交链轻量化

目标：每章写完后生成可审计事实包。

建议产物：

```text
追踪/workflow/tasks/<workflow_id>/
  chapter-commit.json
  verify.jsonl
  context.jsonl
```

`chapter-commit.json` 只记录本章已接受事实：

- 人物状态变化
- 关系变化
- 新增/回收伏笔
- 世界规则变化
- 本章摘要与承接钩
- 质量门结论

### P2：projection retry / workflow doctor

目标：解决“正文已写，但状态/记忆/追踪没同步”的问题。

建议能力：

- 检查正文、细纲、章节契约、审查报告、记忆账本是否一致。
- 缺状态时从最近可信正文和报告重建。
- 只补跑缺失投影，不重写正文。

### P3：作者友好报告统一

目标：所有长任务结束时用户能看懂“到底完成了什么、下一步做什么”。

报告结构：

```text
总状态：已完成 / 部分完成 / 需要你处理 / 未完成
一、产生的文件与完成情况
二、发现的问题与自动处理
三、下一步建议
```

### P4：agent ownership 守卫

目标：避免“主流程自己审查、自己提取事实、自己补状态”的自证循环。

规则：

- context agent 只输出写作任务书。
- reviewer 只输出审查问题。
- data/fact extraction 只输出事实候选。
- 主流程负责验收、落盘和下一步。

## 与现有设计的关系

`novel-assistant` 已经有 workflow、memory、质量门、任务收件箱、context assembler 和成本治理。吸收重点不是新建一套 `.story-system`，而是把它的强约束思想映射到现有结构：

- `story-workflow`：任务生命周期与阶段状态。
- `story-memory`：长期记忆与上下文注入。
- `story-long-write`：章节契约、正文、质量门、交接包。
- `story-review`：范围审阅、gap 风险、修复方案。

## 后续验收建议

新增或扩展 smoke case：

1. 写一章后必须生成正文、审查结论、章节事实包和下一步建议。
2. 如果事实包写入失败，重跑 workflow 不得重写正文，只补 facts/projection。
3. 如果用户回炉章节，旧 commit 标记 superseded，新 commit 写入 accepted。
4. 如果章节扩容/后移，commit ledger 能标记旧章节号与新章节号映射。

## 来源

- README: https://github.com/lingfengQAQ/webnovel-writer/blob/master/README.md
- Architecture overview: https://github.com/lingfengQAQ/webnovel-writer/blob/master/docs/architecture/overview.md
- Plugin package README: https://github.com/lingfengQAQ/webnovel-writer/blob/master/webnovel-writer/README.md
