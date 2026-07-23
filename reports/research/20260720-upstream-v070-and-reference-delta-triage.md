# 上游 v0.7.0 与参考项目增量分诊

- 评审日期：2026-07-20
- 本地基线：`ebb7b838c6624a82bdd415553b520e69f8de6ecf`
- 主上游：`worldwonderer/oh-story-claudecode@964d6bf`（`v0.7.0`）
- 上次主上游评审基线：`12a9655a21abacfbd1c01eb41b98f2af007ab5be`
- 许可策略：主上游按 clean-room 适配；GPL/AGPL/未知许可参考项目只吸收设计思想，不复制实现或提示词。

## 结论

本轮不应整包合并。值得进入 `novel-assistant` 的设计分为三档：

1. **本轮已实现**：读者体验合同 + 终局储备；拆文剧情单元贯通细纲和章节合同；结构化 open-loop 幂等投影；卷级 hard/soft 剧情单元与扩容缺口账本。
2. **候选增强**：非正史多路线推演；共享 hook 核心的维护性重构；卷纲机器化剧情单元生成器。

不吸收 Reasonix 平台清单、纯发布元数据、纯 UI 改造和番茄日榜数据快照。

## 主上游 v0.7.0

| Commit | 判断 | 本地覆盖 | 决定 |
|---|---|---|---|
| `140a01c` ZCode support | 已覆盖且本地更深 | 已有 Claude/Codex/ZCode 安装、runner adapter、token 回执与行为验收 | 不重复实现 |
| `603de4a` / `739a427` shared hook core | 部分覆盖 | 本地有 source/bundle parity、部署审计和多宿主 hooks，但核心仍分散 | 进入维护性重构候选，不直接复制 |
| `9cc91c0` 终局储备 | 明确缺口 | 本地有卷目标、细纲、伏笔和扩容规则，但没有统一的“终局底牌/升级台阶/期待债”合同 | clean-room 吸收，优先级 P1 |
| `3419e93` Reasonix manifest | 非当前目标 | 用户生产宿主为 Claude Code、Codex、ZCode | 跳过 |
| `45c25bf` contract maintenance | 大部覆盖 | 已有 `current-contract-build`、maintainability audit、bundle parity、release audit | 只参考共享资产清单思想 |
| `ae22c54` 剧情单元贯通 | 部分覆盖 | 本地已使用“剧情单元”措辞，但拆文输出尚未成为卷纲/细纲/章节合同的稳定 ID 链 | clean-room 吸收，优先级 P1 |
| `ae22c54` 去 AI 门机器化 | 已覆盖且更深 | 机器门、退化门、污染学习、短篇双门、章节事务均已存在 | 不重复实现 |
| `ae22c54` schema v2 缺失即停止 | 不适合照搬 | 本地明确要求上游旧项目可迁移、旧 novel-assistant 项目可预览迁移 | 保留“预览迁移 + 用户确认”，不硬切旧项目 |

### 应转译的主上游设计

**读者契约与终局储备**

- 书级：读者来这里看什么、主角掌握什么因果权与结算权。
- 卷级：本卷解锁哪个里程碑，哪些终局底牌禁止提前兑现。
- 章节级：当前读者问题、可见回报、关键转折、净变化、继承钩子责任和新钩子。
- 推进过快不按“单章得到太多”判断，而按“是否烧掉未解锁终局底牌、是否逼近升级天花板”判断。

**剧情单元 ID 链**

```text
拆文剧情单元
-> 对标剧情单元索引
-> 本书卷纲剧情单元
-> 细纲 unit_id / beat_position
-> Chapter Contract reader/promise obligations
-> 正文提交与记忆投影
```

同一单元的后续细纲只读取固化单元卡，不反复读取整本拆文报告；这同时降低 token 和跨批漂移。

## 参考项目增量

### lingfengQAQ/webnovel-writer

- 观察范围：`59654cc..2041abad`
- 许可：GPL-3.0，只做 clean-room 设计吸收。
- 新增：`open_loop_created/open_loop_closed` 进入状态投影并保证 replay 幂等；写前 `load-context` 显式消费作者风格记忆和风格契约。

本地判断：

- 作者风格记忆已由 `user-style-rules.jsonl`、作者风格文档和 `user_style_constraints` 覆盖。
- 伏笔目前可随章节事务整体提交，但缺少“事件 -> promises/open-loop 状态”的细粒度幂等投影。后续应给 chapter commit 增加结构化 promise delta，而不是继续解析整份 `伏笔.md`。

决定：风格部分记为 already-covered；open-loop 事件投影已由 accepted chapter commit 的 `promise_deltas`、`promises.jsonl` 与不可变 `promise-events.jsonl` 实现。

### ExplosiveCoderflome/AI-Novel-Writing-Assistant

- 观察范围：`v0.4.2..v0.4.6`，HEAD `4f4def1`
- 许可：尚未确认，只做设计分诊。
- 高价值增量：动态卷数指导、卷战略审查、hard/soft 卷、按 beat 增量生成章节、已写 beat 锁定、未写范围最小扰动、读者体验合同、payoff ledger 同步。

本地判断：

- 我们已有卷内编号、扩容/缩容/后移和正文锁定，但卷战略、卷骨架、节奏板之间仍缺统一失效传播。
- 当前 Chapter Contract 有人物欲望、关系压力和情绪兑现，却没有机器可读的“核心问题/计划回报/关键转折/净变化/继承钩子责任”。
- “按 beat 增量生成，当前 beat 可写而整卷仍 partial”比一次生成大量细纲更适合长篇生产，也更符合 token 治理。

决定：将“读者体验合同”和“增量卷规划”列为 P1；不吸收其 UI 和数据库实现。

### Narcooo/inkos

- 观察范围：`7dce957..9f194592`
- 许可：AGPL-3.0，只做 clean-room 设计吸收。
- 新增：多路线剧情推演；候选分支始终是非正史，选择后只保存计划，不修改正文、大纲、当前状态或伏笔；正史变化后候选自动过期。

本地判断：非常适合用户在 Chat 中比较扩容、反转、人物去留或下一卷方向。它能避免“讨论一个候选就把大纲改了”的常见污染。

决定：列为 P2 `narrative_forecast` workflow。候选必须带 canon hash；采用仅生成 `selected-plan`，再次确认后才进入影响分析和正式事务。

### EdwardAThomson/NovelWriter

- 观察范围：`aa893e1..f843c972`
- 许可：尚未确认，只做 clean-room 设计吸收。
- 新增中与 skill 最相关的是 CLI 子进程环境卫生：避免父进程 `.env` 的 API key 覆盖 CLI 自己的订阅登录。

本地判断：本地 `minimalEnvironment()` 已经只传 allowlist，因此 API key 不会泄漏。当前主要生产入口是 Claude Code 和 ZCode 的交互会话，不以 Codex CLI runner 为核心；代理变量兼容不属于本轮写作 workflow / memory 优化范围。

决定：记录为宿主适配参考，不实施代码变更。

### wen1701/FanqieRankTracker

- 观察范围：`e045fe77..fb1abf86`
- 许可：MIT（项目内已有确认记录）。
- 本轮只有自动日榜数据更新，没有采集器、字体解码、bookId 或反爬边界代码变更。

决定：不吸收代码；可把最新数据作为独立市场观察源，但不得写进 skill 规则，也不得称为番茄官方短篇榜。

## 未变化来源

`humanizer-zh`、SillyTavern、`novel-architect-skills`、`novel-writer-skills`、`trending-skills`、`novel-creator-skill`、`make-ur-Agent-writer`、NovelClaw 均未发生需要重复评审的提交。本轮不重新读取，避免无效 token 消耗。

两个低优先级仓库因 TLS 握手失败未复查：`chinese-novelist-skill`、`awesome-agent-skills`。它们不是当前生产阻断，不为此反复重试。

## 实施状态

1. **已实现**：统一 `reader_experience` + `terminal_reserve` 合同，投影到细纲质量门、`current-contract` 和 Chapter Contract。
2. **已实现基础链**：拆文要求输出来源侧剧情单元索引；本书细纲使用独立稳定 `PU-...`，章节 schema 与 contract 逐级引用。来源单元不会直接冒充本书正史 ID。
3. **已实现**：chapter commit 支持结构化 promise/open-loop delta 和幂等 replay。
4. **已实现扩容边界**：剧情单元区分 hard/soft；扩容只使未写 soft 单元 stale，锁定单元内插章形成 pending gap，不扰动已有正文。
5. **待实现 P2**：增加非正史路线推演与过期检测。
6. **待完善**：卷纲到细纲的剧情单元自动规划器，以及共享 hook 核心的维护性重构。

## 验收建议

- 终局储备：单章多线收益可通过，但提前揭终极身世应阻断或要求改纲。
- 剧情单元：拆文单元 ID 能被卷纲、细纲、Chapter Contract 逐级引用；缺失时降级但不伪造。
- 增量拆章：只生成当前单元/beat，已有正文保持不变，后续未写单元标记 stale/pending。
- 伏笔投影：同一 chapter commit replay 两次不产生重复伏笔；关闭事件能准确落到原 open loop。
- 路线推演：候选不会修改 canonical 文件；正史 hash 变化后候选不可直接采用。
