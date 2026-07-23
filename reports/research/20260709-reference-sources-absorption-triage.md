# 参考来源吸收分级报告

- Date: 2026-07-09
- Registry: `docs/reference-projects.json`
- Watch report: `reports/research/20260709-034133-reference-project-watch.md`
- Scope: 非主上游参考来源。主上游 `worldwonderer/oh-story-claudecode` 仍走 `node scripts/na-dev.js upstream --write`。

## 本轮结论

当前 11 个 GitHub 参考项目 HEAD 均未变化，已记录可用的最新 tag / tag sha。没有稳定 tag 或 HEAD 更新信号时，不需要再次 clone 深读或大规模吸收。

本轮只保留吸收分级与后续实现候选：

| 来源 | 当前状态 | 值得吸收 | 处理 |
|---|---|---|---|
| `lingfengQAQ/webnovel-writer` | HEAD/tag current | 行为验收矩阵、章节提交链、投影/状态重建、作者友好报告 | P0 clean-room 吸收设计，不复制 GPL 代码 |
| `wen1701/FanqieRankTracker` | HEAD current，无 tag | 榜单快照、new/dropped、涨跌、读增、市场摘要 fallback | P0 数据协议吸收，已进入扫榜/下载桥接方向 |
| `SillyTavern/SillyTavern` | HEAD/tag current | Lorebook 激活、递归触发、prompt ordering、上下文预算 | P1 clean-room 强化 `story-memory/context-assembler` |
| `ExplosiveCoderflome/AI-Novel-Writing-Assistant` | HEAD/tag current | 自动导演、质量债务、角色资源账本、写法资产 | P1 强化 workflow 模式与质量债务分级 |
| `op7418/humanizer-zh` | HEAD current，无 tag | 去 AI 指标、人味评分、句式问题解释 | P1/P2 只做测试与诊断口径，不硬套到小说正文 |
| skill 设计类仓库 | HEAD current | skill 组织、触发语、文档结构 | P2 低频观察，不作为写作质量核心来源 |

## P0 候选

### 1. 参考项目观察必须 tag/release 门控

问题：只看 GitHub HEAD 会导致每次小提交都诱发深读，浪费 token，也容易吸收未稳定实验。

已落地：

- `reference-project-watch.js` 同时记录 HEAD 与最新 tag/tag sha。
- HEAD 变但 tag 不变时输出 `light_commit_log_only_until_tag_changes`。
- tag/release 变化才建议 research report + clean-room triage。

后续要求：

- 每次更新 registry 后跑 `node scripts/na-dev.js reference-watch --write`。
- 没有 tag 的项目才回退到 HEAD 判断，并按 priority 控制复审深度。

### 2. 行为验收矩阵继续强化

`webnovel-writer` 最值得吸收的是“行为 eval”而不是具体实现。它把 skill 是否真的遵守流程变成可验收项。

映射到本项目：

- router：明确意图不能被旧任务错误拦截。
- workflow：数字选项必须绑定 `action_id`，不能靠聊天文本重新解释。
- agent：需要 agent 的阶段必须使用 agent；agent 输出必须有 artifact 边界。
- quality gate：章节/小节写完即检查，不把 AI 味积累到最后。
- user report：给用户看结论和下一步，不暴露 raw JSON、长命令和工程噪音。

### 3. 榜单数据从“列表”升级为“快照 + 趋势”

`FanqieRankTracker` 的价值不是某个抓取技巧，而是数据产物结构：

- 当前榜单快照。
- 新上榜 / 掉榜。
- 排名上升 / 下降。
- 阅读增长。
- 分类市场摘要。
- AI 不可用时的规则 fallback。

映射到本项目：

- `story-short-scan` 与 `story-long-scan` 输出 `ranking-items.jsonl` 外，还应输出 `snapshot.json`、`trend-delta.json`、`market-summary.md/json`。
- 下载桥接只消费带 `bookId/pageUrl` 的候选，不在扫榜阶段自动下载正文。

## P1 候选

### 4. 动态记忆激活补齐 SillyTavern 式边界

本项目已有 `story-memory` 和 `context-assembler.js`，但还可补：

- `minActivation`：任务至少激活几个关键记忆，不足时提示记忆缺口。
- bounded recursive activation：已激活记忆可触发相关记忆，但必须限制轮数和预算。
- insertion order：区分任务前置约束、当前场景约束、末尾提醒。
- role/position metadata：上下文片段说明是设定、人物状态、伏笔、风格还是读者画像。

拒绝项：

- 不复制 SillyTavern 角色扮演 UI。
- 不引入角色卡聊天产品形态。

### 5. 质量债务分级需要更明确

AI-Novel-Writing-Assistant 的“质量债务”概念适合吸收：局部章节问题不一定阻断全书流程，但会进入债务账本。

本项目应区分：

- blocking：会污染设定、人物、剧情或正文，必须停。
- debt：局部质量不足，可继续但必须登记和回收。
- advisory：提示风险，不阻断。

这能减少“为了几个字或一个符号反复回炉”的 token 浪费。

### 6. 去 AI 从单次清洗变成双评分

`humanizer-zh` 可参考的是“解释型诊断”。但小说正文不能机械套文章去 AI 规则。

建议拆成：

- AI-clean score：模板句、重复句、工程词、污染输出、禁用格式。
- Human-voice score：人物是否像人、场景是否真实、情绪是否有余波、对话是否有关系压力。

短篇和长篇都需要“写作中门禁”，不是最后统一清洗。

## P2 观察项

- `chinese-novelist-skill`、`novel-architect-skills`、`novel-writer-skills`、`novel-creator-skill`：作为 skill packaging / prompt structure 观察源；没有 tag 更新或明显新设计时不深读。
- `awesome-agent-skills`、`trending-skills`：只做发现索引，不进入生产写作流程。

## 拒绝项

- 不吸收其他项目的前端、provider、LangGraph、向量数据库或完整 runtime。
- 不复制 GPL/AGPL/未知许可源码和长段 prompt。
- 不把私有短篇、下载、本地素材资产写入公开 GitHub registry。
- 不因为单个 GitHub HEAD 变化就做大规模吸收。

## 下一步实现顺序

1. 保持 tag/release 门控为参考来源第一道入口。
2. 补强生产验收矩阵里的 workflow 行为 eval，尤其是 router、pending action、agent artifact、quality gate。
3. 给扫榜产物补 `snapshot/trend-delta/market-summary` 三件套。
4. 给 `context-assembler` 增加 `minActivation`、递归激活上限和 insertion order。
5. 把 anti-AI 诊断拆成 `AI-clean` 与 `Human-voice` 两层评分。
