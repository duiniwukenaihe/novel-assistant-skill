# 上游版本映射

## 2026-08-01 上游 v0.7.2 选择性吸收

| 字段 | 记录 |
|---|---|
| 上游仓库 / 分支 | `https://github.com/worldwonderer/oh-story-claudecode.git` / `main` |
| 已评审基线 | `964d6bfdb7b78b225591e4b35bfa00d245d4f9a2` / `v0.7.0` |
| 本轮稳定目标 | `06ee854c47267dc6eb7cc7bb70ca3436ece3dc81` / `v0.7.2` |
| 本轮观察 HEAD | `8aaa701a783a3065144b2df2faac9fa70e9c8f7b` |
| 结论 | 不 merge/cherry-pick；按本仓库架构 clean-room 重实现。Dashboard、Reasonix、发布提交不吸收。 |

### 完整吸收（Task 1-3）

| 上游 Commit | 主题 | 本地结果 |
|---|---|---|
| `60bdae7` / `0a37505` | 正文句法节奏去除短句崇拜 | 公有短篇/长篇/审阅/去AI/拆文规则统一为"句长随场景功能变化"；情绪词在证据支撑下可用；禁止机械拆句。 |
| `f710ade` | 细纲只传递故事责任 | writing-craft + quality-checklist 增加细纲责任与正文表达边界；禁止字段逐条翻译、章尾总结、章尾预告。prose gate 已有工程词检测覆盖。 |
| `c0a1482` | 会话起点假未完成与更新提醒 | `is_progress_completed` 精确识别 completed/completed_with_errors；更新提醒 24h 负缓存节流。 |

### 差距补缺（Task 4）

| 上游 Commit | 主题 | 本地结果 |
|---|---|---|
| `1ced63d` | 质量门不掩盖自身失败 | `check-degeneration.js --json` 加 `status:'partial'\|'complete'` + `files_unreadable`；其余 8 脚本审计为已覆盖。 |

### 可选吸收（Task 5-6）

| 上游 Commit | 主题 | 本地结果 |
|---|---|---|
| `d83d99c` | 既有世界观命名护栏 | 长篇设定识别 original/fanfic/historical_derivative/imported_existing_world；非原创模式命名 advisory 不硬阻断。 |
| `b1e9ddb` | 开书发现本地对标 | 长短篇/通用 SKILL 增加开书阶段轻量扫描 对标/ 和 拆文库/；找不到不阻断、不联网。 |

### 明确不吸收

- Dashboard（novel-project 承担前端，上游 Dashboard 不进入 skill）
- Reasonix 适配（本项目已支持 Claude/Codex/ZCode）
- 发布提交、README 拼写修复

### 观察项（Task 7）

4 个参考项目变化（inkos/ai-novel-writing-assistant/edwardathomson-novelwriter/fanqie-rank-tracker），均建议继续观察，不在本轮吸收。详见 `reports/research/2026-07-31-reference-project-watch.md`。

---

## 2026-07-20 上游 v0.7.0 与参考项目增量分诊

| 字段 | 记录 |
|---|---|
| 上游仓库 / 分支 | `https://github.com/worldwonderer/oh-story-claudecode.git` / `main` |
| 已评审基线 | `12a9655a21abacfbd1c01eb41b98f2af007ab5be` |
| 当前观测 HEAD | `964d6bfdb7b78b225591e4b35bfa00d245d4f9a2` |
| 当前稳定 tag | `v0.7.0` |
| 结论 | 不整包合并；终局储备、读者体验合同、剧情单元贯通和增量卷规划进入 clean-room 实施队列。ZCode、去 AI 机器门和宿主验收不重复实现。 |

| Commit | 决定 | 本地结果 |
|---|---|---|
| `9cc91c0` | `absorb-design` | 终局底牌、升级台阶、期待债和主角因果/结算权进入 P1 章节合同设计。 |
| `ae22c54` | `partial-absorb` | 吸收拆文剧情单元贯通卷纲/细纲/章节合同；不照搬 schema v2 硬切旧项目。 |
| `603de4a` / `739a427` | `maintenance-candidate` | 共享 hook 核心进入行为不变的维护性重构队列。 |
| `140a01c` | `already-covered` | 本地 Claude/Codex/ZCode 适配、runner、token 回执和行为验收已覆盖。 |
| `45c25bf` | `mostly-covered` | 合同、共享资产、bundle parity 与发布审计已有本地实现。 |
| `3419e93` | `skip` | 当前不增加 Reasonix 宿主。 |
| `964d6bf` | `skip` | 只记录 release 元数据。 |

参考项目增量、许可边界和实施优先级见 `reports/research/20260720-upstream-v070-and-reference-delta-triage.md`。

## 2026-07-15 上游 12a9655 小批量反哺

| 字段 | 记录 |
|---|---|
| 上游仓库 / 分支 | `https://github.com/worldwonderer/oh-story-claudecode.git` / `main` |
| 已评审基线 | `097a7505c407e0432508da9692b8b1151ce4ae3c` |
| 当前观测 HEAD | `12a9655a21abacfbd1c01eb41b98f2af007ab5be` |
| 当前稳定 tag | `v0.6.22` / `464074f` |
| 实施分支 | `codex/workflow-memory-production-v2` |
| 结论 | 只吸收两项已验证原则；不合并上游历史，不复制其宿主专属 Python hook。 |

| Commit | 决定 | 本地结果 | 验证 |
|---|---|---|---|
| `26c5a04` | `already-covered + regression` | Shell/OpenCode 都只接受 `.active-book` 的有效首行；空行、空白行、第二行、无效路径均回退正常发现，且不会把仓库根目录当书目。Shell resolver 同步补齐项目内存在性校验。 | `bash scripts/check-story-setup-deployment.sh`、`bash scripts/test-hook-encoding-portable.sh` |
| `12a9655` | `absorb` | 部署验收已从升级文档的固定文案匹配改为语义主题审计，运行时契约仍保留独立机械检查。 | `node scripts/public-release-audit.js --check-upgrade-guide --json`、部署验收 |

完整分诊见 `reports/upstream/20260715-132654-upstream-check.md` 与 `reports/upstream/20260715-upstream-12a9655-triage.md`。

## 2026-07-13 上游 097a750 反哺

| 字段 | 记录 |
|---|---|
| 上游仓库 / 分支 | `https://github.com/worldwonderer/oh-story-claudecode.git` / `main` |
| 上次已评审基线 | `bf70c26f042f9d08cd3599efe24baeec8b6617f9` |
| 当前观测 HEAD | `097a7505c407e0432508da9692b8b1151ce4ae3c` |
| 当前稳定 tag | `v0.6.22` / `464074f` |
| 实施分支 | `codex/upstream-097a750-absorption` |
| 结论 | 按 commit 小批量吸收，不合并上游整包；平台题材契约、六张原创方法卡和只读宿主发现已落地。 |

| Commit | 决定 | 本地结果 |
|---|---|---|
| `097a750` | `absorb` | 新增 Claude/Codex/ZCode/OpenCode/OpenClaw 五宿主静态只读发现验收；真实付费行为门仍独立执行。 |
| `2e9cbac` | `absorb` | clean-room 新增世情打脸、民俗怪谈、悬疑、甜宠、双男主、沙雕脑洞六张因果型方法卡，不复制上游语料。 |
| `464074f` | `skip` | 只记录稳定 tag，不吸收 release 元数据。 |
| `4eed2fc` | `absorb` | 新增证据标注的平台投稿契约和 `platform_genre_lock`，确认后才进入节奏与小纲。 |
| `363e994` | `already-covered` | 顶层入口已有渐进加载；内部模块瘦身留作独立维护债务，不机械删规则。 |

完整证据见 `reports/upstream/20260712-170556-upstream-check.md`、`reports/upstream/20260712173005-short-write-sync.md` 和 `reports/research/20260712-170704-reference-project-watch.md`。

## 2026-07-10 Task 11

| 字段 | 记录 |
|---|---|
| 上游仓库 / 分支 | `https://github.com/worldwonderer/oh-story-claudecode.git` / `main` |
| 上次正式观测 | `0d555cfa387f7e30ad0c2a0075c212622c230971` |
| 可复现 git/tag 基线 | `e3cb89205b8078eb1d6fcfe2faf113ab64666a33` / `v0.6.21` |
| 计划基线 | `bf70c26f042f9d08cd3599efe24baeec8b6617f9` |
| 当前观测 HEAD | `bf70c26f042f9d08cd3599efe24baeec8b6617f9` |
| 当前观测 tag | `v0.6.21` |
| 结论 | 当前 HEAD 等于计划基线，未发现基线之后的上游提交；Task 11 本地适配已按分诊收口。 |

完整命令、工作树隔离说明和行为级理由见 `reports/upstream/20260710-bf70c26-commercial-closure.md`。

| Commit | 标题 | Task 11 决定 | 覆盖主题 |
|---|---|---|---|
| `698c760` | `fix(deslop): refine anti-ai prose linting` | `skip-with-reason` | detector 细化不直接适配现有多 profile 诊断链。 |
| `620c0ec` | `fix(setup): allow generic web ai skill deployment (#216)` | `skip-with-reason` | 不属于本轮写作/去 AI 分诊范围。 |
| `6ec56b3` | `feat(deslop): add task-block and metaphor density guidance (#218)` | `absorb` | advisory 任务块与隐喻密度指导；`tests/test-anti-ai-pipeline.bats`。 |
| `d60a888` | `Keep deslop guidance from gaming detectors (#221)` | `already-covered` | 检测器仅作证据，禁止为分数重写结构；已有 anti-ai 回归锚点。 |
| `06ec453` | `Restore detector attribution without replacing human review (#220)` | `already-covered` | 外部 detector 不替代人工阅读；已有 anti-ai 回归锚点。 |
| `103dc18` | `Prevent long-write workflow overruns from discussion feedback (#225)` | `absorb` | 裸调用停靠、单轮 3 章、`outline_underfilled`；`tests/test-module-workflow-contracts.bats`。 |
| `bf70c26` | `Consolidate genre prose cards + long-form rhythm gates (#222+#223+#224) (#226)` | `absorb` | 单卡题材召回、正文防泄漏、场景/节奏门；`tests/test-upstream-20260628-backport.bats`。 |

候选实现数量为 **3 个提交**。适配时只处理报告中列出的最窄 source/test 落点；不合并上游整包、不直接编辑生成 bundle。
