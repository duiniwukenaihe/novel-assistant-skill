# workflow-daily.md：日更续写工作流

本文件为"日更续写"场景的完整指引。SKILL.md 路由到本文件后，按以下流程执行。

> **长篇稳定性闭环**：每章必须按以下顺序执行：
> 1. `Chapter Contract`：写前锁定。
> 2. 正文写作后执行 `Plot Drift Gate`：写后验收。
> 3. `State Delta Ledger`：把本章对后续的影响写入追踪文件。
> 4. `Chapter Handoff Pack`：把本章对下一章的继承约束落盘。

> **日更准备步骤**：每章写作前 5 步——状态筛选 + 本书文风/对标召回 + 作者/用户风格画像加载 + 意图确认 + Chapter Contract，嵌入 Step 2 逐章循环。
>
> Step 2 先读本书文风，再读四类对标资料：
> 0. `{项目}/设定/文风.md`（本书自定义文风；存在时压缩为 `project_style_constraints`，是正文风格权威来源）
> 1. `{对标书路径}/剧情/情绪模块.md`（读者需求 / 情绪引擎 + 可复现模块；缺失按下方「模块/节奏缺失」规则：v12 停下修复，仅 legacy 回退）
> 2. `{对标书路径}/剧情/节奏.md`（关键信息推进 + 情绪触动点 + 爆发节奏；缺失按下方「模块/节奏缺失」规则：v12 停下修复，仅 legacy 回退）
> 3. `{对标书路径}/文风.md`（整书级 ~4000 字，含原文锚点范例片段）
> 4. `{对标书路径}/章节/第K章_摘要.md`（按本章情绪/基调挑 1 章）；若同章存在 `第K章_深度拆解.md` 则加读，否则回退黄金三章深度拆解/文风文件里的可借鉴技巧
>
> 对标书路径查找：先 `{项目}/对标/{书名}/`，回退 `拆文库/{书名}/`。
>
> **本书文风优先**：`设定/文风.md` 是本书自定义文风。存在时，本书自定义文风优先于对标文风；对标 `文风.md` 只作为可借鉴参考，不得覆盖本书已确认的句长、标点、对话、叙述口吻、禁用表达和章节标题习惯。
>
> **文风缺失**：对标书缺少 `文风.md` 且存在 `设定/文风.md` 时，继续写作，记录 `gaps.benchmark_style_missing=true`，文风指令使用 `project_style_constraints`；对标书缺少 `文风.md` 且不存在 `设定/文风.md` 时停止本章写作，不 inline 生成。报错：「对标书 X 缺少 文风.md，且当前项目没有 设定/文风.md。请用 `/novel-assistant 重新拆解对标书` 跑 Stage 6 生成文风，或先补写本书 设定/文风.md。」
>
> **模块/节奏缺失**：v12 新契约对标书缺 `剧情/情绪模块.md` 或 `剧情/节奏.md` 时停止本章准备，提示用 `/novel-assistant 重新拆解对标书` 跑 Stage 3+ 或用 `/novel-assistant 重新导入对标资料`；只有 pre-v12 legacy 拆文库可继续写作，story-explorer 必须在 `gaps.legacy_deconstruction` + `gaps.module_missing` / `gaps.rhythm_missing` 记录，依次低置信回退到 `拆文报告.md`、`文风.md` 可借鉴技巧、匹配章摘要 / `剧情/故事线.md`。
>
> **冲突规则**：`剧情/情绪模块.md` 与 `剧情/节奏.md` 是情绪和节奏的 canonical / 权威来源；`拆文报告.md`、`剧情/故事线.md` 是投影摘要；`文风.md` 只管风格。若摘要或文风与权威模块/节奏冲突，保留 `gaps.conflict`，正文意图跟随权威文件。
>
> **无对标项目**：若存在 `设定/文风.md`，跳过对标召回但继续使用 `project_style_constraints`；若不存在，则在 2.4 意图确认标记"无对标参考 / 无本书文风"。不读不存在的对标文风、不阻塞、不警告。
>
> **多本对标书**：从 `设定/题材定位.md` 读 `主对标书` 字段；缺失时用 `对标/` 下字典序第一本并提示用户补字段。
>
> **Agent 缺失质量边界**：`story-explorer`、`narrative-writer`、`consistency-checker` 缺失时属于 **SOFT FALLBACK**，由主会话手动完成同等步骤；不得跳过 Chapter Contract、不得跳过 Plot Drift Gate、不得跳过 State Delta Ledger、不得跳过 Chapter Handoff Pack。细纲缺失、Chapter Contract 无法生成、正文未落盘、字数无法机器验证、Plot Drift Gate 存在未处理 S1/S2、交接包无法生成时属于 **HARD STOP**，不得进入下一章。
>
> 完整写前准备逻辑见 `SKILL.md` 的 Phase 4。

---

## 适用条件

- 项目已有 `正文/` 和 `追踪/` 目录
- 用户说"日更""续写""继续写"
- 目标：每次会话写 2-3 章（4000-9000 字）；单轮正文上限为最多 3 章。

---

## Step 0：正文准入预检

本步骤先于上下文加载、候选稿创建、narrative-writer 调用和 chapter-commit 暂存，且每次从路由进入 daily workflow 时必须独立执行：

1. 请求必须明确给出目标书/项目和目标章节；只说“写长篇 / 帮我开书 / 继续 / 续写”的裸调用只诊断进度与缺失前置，不进入 Step 1，不创建正文候选。
2. 目标章节必须已有已通过的细纲和逐章 Brief；多场景章还必须逐节检查每节 Brief。Brief 至少包含人物目标、阻力或关系压力、不可逆推进/信息变化、章末或节末承接。
3. 任一字段缺失、标记 `[待补充]`、未确认或不能从已确认材料取得时，返回 `outline_underfilled` 与逐项缺口；禁止自造剧情补齐，禁止调用 narrative-writer，禁止创建/写入正文候选或 chapter-commit 暂存产物。
4. 一次先校验本轮全部目标章，再把执行范围截为前三章；第四章及之后只记入后续批次，不能创建 writer packet、候选稿或执行事务。

只有 Step 0 全部通过，才进入 Step 1。可执行准入结果必须记录 `book_id`、`scheduled_chapters`、`deferred_chapters`、各章 `brief_status=passed`；后续每章仍要先生成并落盘 Chapter Contract。

---

## Step 1：快速上下文加载

**章节索引刷新（50+ / 100+ 章项目必做）**：加载 `references/chapter-index.md`。当项目已超过 50 章、正文移动到卷目录、章节重命名、或即将执行批量审计时，先运行 `bash scripts/chapter-index-build.sh --write <book-dir>`，刷新 `追踪/章节索引.tsv`。后续稳定性 gate 优先按索引定位正文；索引缺失时才使用旧的 `正文/第{N}章_*.md` fallback。

**可选：使用 story-explorer agent 批量加载上下文**。如果项目已部署 story-explorer agent（检查 `.claude/agents/story-explorer.md` 是否存在），可以用 `Agent(subagent_type: "story-explorer", prompt: "项目目录：{dir}\n查询类型：context_load\n查询参数：准备写第 {N} 章")` 执行 `context_load` 查询，一次获取全部写作上下文。spawn 返回后检查 results 是否包含 `chapter_contract`、`character_invariants`、`recent_state_delta`、`volume_outline` 和 `chapter_plan`；字段齐全时直接使用其 results，跳过下方手动加载步骤。agent 不可用、返回不完整、或缺任一稳定性字段时，只采用已返回部分，并按下方手动加载补齐缺失字段，不得跳过稳定性证据加载。

手动加载（默认方式）：

| 序号 | 文件 | 用途 | 如果不存在 |
|------|------|------|-----------|
| 1 | `追踪/上下文.md` | 上次写作进度摘要 | 从 `追踪/伏笔.md` + `追踪/时间线.md` 重建 |
| 2 | `追踪/伏笔.md` | 待回收伏笔清单 | 跳过 |
| 3 | `追踪/时间线.md` | 当前事件时序 | 跳过（写作时从正文推断） |
| 4 | `大纲/第X卷/细纲_第{N}章.md`（旧项目回退 `大纲/细纲_第{N}章.md`） | 本章写作计划 | **必须先补建**，不允许跳过 |
| 5 | `大纲/第X卷/卷纲.md`（旧项目回退 `大纲/卷纲_第X卷.md`） | 当前卷目标、节奏、人物弧线 | 从 `大纲/大纲.md` 推断，并在 Gate 中标记证据不足 |
| 6 | `追踪/章节契约/第X卷/第{N-1}章.md`（旧项目回退 `追踪/章节契约/第{N-1}章.md`） | 上一章 State Delta/契约继承线索 | 首章或缺失时跳过 |
| 7 | `追踪/角色状态.md` | 角色当前状态快照 | 从角色设定和前文推断 |
| 8 | `设定/文风.md` | 本书自定义文风 | 不存在则 `project_style_constraints=无`；存在时优先于对标文风 |
| 9 | `设定/作者风格/我的写作偏好.md`、`设定/作者风格/正文风格画像.md`、`追踪/schema/user-style-rules.jsonl` | 用户风格画像加载 | 不存在则跳过，写作前 `user_style_constraints=无` |

**按需加载角色文件**：从细纲中提取本章涉及的角色名，按需加载 `设定/角色/{角色名}.md`。如果细纲中未列出角色，跳过。

**按需加载角色不变量**：从本章涉及角色中筛选核心角色，按需加载 `设定/角色不变量/{角色名}.md`。如果缺失，从角色档案推断本章临时不变量，并在 `Plot Drift Gate` 证据说明中标记“角色不变量缺失/推断”。

**按需加载创作公式**：当写作中需要引用创作公式约束时（如期待感公式、爽点公式、信息差公式），加载 `references/genre-writing-formulas.md`。默认不加载，避免无条件加载 1500+ 行文件浪费 token。

### 已写内容分层摘要

当项目超过 30 章时，`追踪/上下文.md` 中的已写内容摘要应按三层结构组织，压缩早期章节、保留近期细节：

| 层级 | 粒度 | 格式 | 维护时机 |
|------|------|------|----------|
| **近5章详记** | 近 5 章逐章摘要 | 保留现有格式（每章一段：事件+状态变化+伏笔） | 每章写完后更新 |
| **十章概要** | 每 10 章一段概要 | `章节范围 | 已写核心事件 | 角色状态变化` | 每写完 10 章生成一段 |
| **卷级总览** | 每卷一句话总结 | `卷名 | 已写主线进展 | 关键转折` | 每卷结束时生成 |

**示例（50 章项目）**：
```markdown
## 近5章详记（第 46-50 章）
第 46 章：主角进入秘境，发现上古遗迹...
第 47 章：遭遇守护兽，险胜后获得传承...
...

## 十章概要
第 1-10 章 | 主角觉醒金手指，进入修炼学院 | 从废柴变为内门弟子
第 11-20 章 | 学院大比，击败天才对手 | 获得长老关注，实力突破
第 21-30 章 | 离开学院，探索秘境 | 发现身世线索，结交盟友
第 31-40 章 | 卷入势力争斗，暴露身份 | 被追杀，实力再突破
第 41-50 章 | 反杀追兵，进入新地图 | 确认血脉传承，进入上界

## 卷级总览
第一卷·觉醒 | 废柴逆袭成天才 | 金手指觉醒，身世初现端倪
```

> **首次日更兜底**：如果 `追踪/` 目录下的文件全部为空或不存在（刚完成 Phase 3 但未日更过），额外加载 `大纲/第X卷/卷纲.md`（旧项目回退 `大纲/卷纲_当前卷.md`）和最新一章正文来重建上下文。

> **确定下一章编号 N**：卷内编号 N 与全书草稿顺序分离。进入日更或回答当前进度前，先运行 `node scripts/story-progress-status.js <book-dir> --json`。`chapterNo/currentChapter/globalDraftOrder` 可用于统计全书进度，但不得用 currentChapter 或 globalDraftOrder 生成正文文件名；卷目录项目必须用 `currentVolume + currentVolumeChapter` 或章节资产中的 `volume + volumeChapterNo` 决定 `正文/第X卷/第NNN章_章名.md`，写完后更新 `currentDraftPath` 和 `currentOutline`。第1卷可以从第001章开始，第2卷必须从第001章开始，第三卷同理。若存在 `追踪/章节资产.jsonl`，优先读取当前卷最大 `volumeChapterNo` 后加 1；文件不存在时，递归扫描 `正文/第X卷/第*.md` 得到当前卷最大卷内编号。若 `story-progress-status.js` 返回 `blocked_mixed_chapter_layout`，或扫描到 `正文/第2卷/第027章_*.md`、`正文/第2卷/第029章_*.md` 这类“卷目录 + 全书连续编号”的混合结构，立即停在 `blocked_mixed_chapter_layout`，提示用户选择卷内重编号/迁移或保持旧结构兼容；不得继续写第030章，也不得把第029章当第2卷第29章。

确定本轮写作范围后直接进入 Step 2，不做"是否继续"式确认。K 默认 2-3 章，单轮正文上限为最多 3 章；用户请求更多时切分为后续日更批次，不能跳过已完成章节的 chapter-commit、交接包或门禁。用户明确说"只写1章"/"日更3章"/"逐章确认"时按用户要求调整。仅在章节号冲突、细纲缺失、请求范围超过已有细纲、用户要求会改变大纲/追踪，或存在其他会导致写错的阻塞信息时暂停确认。

> **补字/扩写细节不得默认修真**：字数不足、需要补 1000 字、展开战斗或实战时，不得自动写“修真实战细节”。只有题材证据明确为修真/仙侠时才可使用“修真/境界/灵力/法术实战”等词；题材未确认时使用“能力运用、动作交锋、环境压力、厨艺动作、人物反应”等中性细节。玄幻、武侠、高武、都市异能、魔教江湖、美食系统等项目必须按本书设定替换，不得把修真词当通用表达。

> **模型退化 front-stop**：日更、补字、回炉时如果出现领域词无间隔重复、SSOT 词组循环、阶段标签循环、同一领域词几十次刷屏、长时间 thinking 但无新增可信正文/契约/交接包，立即停止并写 `blocked_model_degradation`。此状态下不得写入正文/报告，不得继续 Write/Edit，不得把污染思路转成剧情；只保留最后可信断点，缩小任务粒度重试一次。若重试仍失败，提示用户选择：1. 缩小范围继续 2. 切换模型后续跑 3. 只保存诊断。

> **供应商敏感输出拦截**：日更或补字时如果 API 返回 `output new_sensitive`、`new_sensitive (1027)` 或类似输出安全错误，写 `blocked_provider_sensitive`。不得原样重试，不得继续 Write/Edit，不得调用 Agent/TaskCreate 继续撞同一任务，不得把被拦截内容补写进正文/报告；用户输入继续也不得直接恢复原任务，必须先进入恢复选项。保留最后可信断点，降低显性描写，改为概述式、侧写式、非露骨表达，并保留剧情因果、人物状态和章节承诺；缩小任务粒度后最多重试一次。若仍失败，提示用户选择：1. 降低描写尺度继续 2. 跳过敏感段保留剧情因果 3. 停止并只保存诊断。

---

## Step 2：串行批量写作

一次加载多章细纲，但**必须在主会话内串行逐章写作**：不得把多章同时交给多个子代理并发写。长篇章节依赖上一章正文和追踪文件，并发会导致上下文断裂、追踪覆盖和标题去重失效。

**批量 continuation 规则**：进入本 Step 后，"继续"/"续写"/"日更"只表示继续当前日更批量流程。不得把这些词解释为跳过 Step 2.2/Step 2.3 的直接正文续写；也不得在每章之间重复询问是否继续，除非用户明确要求逐章确认或出现阻塞。

1. **读取细纲**：加载本次要写的 2-3 章细纲。新版细纲优先读取「内容概括（起因/发展/转折/高潮/结尾）」「情节安排（主线/辅线/事件线/感情线/逻辑线）」「人物关系和出场顺序」「情节细化」「结尾设定和钩子」；旧版细纲可以把核心事件、情节点序列、目标情绪、章首/章尾钩子映射成 Brief，但映射后仍须满足 Step 0 的人物目标、阻力/关系压力、不可逆推进/信息变化、承接四项，缺项返回 `outline_underfilled`，不得以 legacy 为由直接写正文。
2. **逐章执行**（以下每步在每章循环内执行）：
   - 读细纲 → 按需加载角色设定
   - **2.1 标题预检**：扫描既有章节标题；如本章标题同名或明显重复，先按本章核心事件改名，并同步细纲标题与正文文件名
   - **2.2 状态筛选**：每章开始前必须确认以下来源已经在本轮 workflow 中读取或刚更新：本章细纲、当前卷纲、上一章正文（或上一章刚写入的正文）、`追踪/上下文.md`、`追踪/伏笔.md`、`追踪/时间线.md`；涉及角色时，还必须确认 `追踪/角色状态.md` 或对应 `设定/角色/{角色名}.md` 的来源；核心角色还必须加载 `设定/角色不变量/{角色名}.md` 或写明推断来源。"已加载"只指本轮 workflow 内实际读取/更新过的文件，不得用未标明来源的聊天记忆替代。角色最新状态优先从 `追踪/角色状态.md` 筛选（如不存在则从角色设定推断），待回收/推进伏笔从 `追踪/伏笔.md` 筛选；细纲不存在时仍按下方补建流程处理，不允许直接写正文
   - **2.3 本书文风 + 对标模块/节奏/文风召回**：
     - 先读 `{项目}/设定/文风.md`（如存在），只抽取会直接影响本章正文的句长、段落密度、对话口吻、标点习惯、叙述视角、禁用表达和标题习惯，压缩成 `project_style_constraints`；不存在则写 `project_style_constraints=无`。本书自定义文风优先于对标文风；若二者冲突，保留本书文风，把对标差异记为参考，不进入硬约束。
     - 调 story-explorer 的 `benchmark_style_load` query_type（输入：项目目录 + 本章目标情绪 + 本章爽点类型 + 本章目标字数）一次性拿到：`{style_profile_path, style_profile_summary, selected_emotion_module, rhythm_reference, module_source_path, rhythm_source_path, matched_chapter_K, matched_chapter_techniques, anchor_excerpts, gaps}`
     - 若 `gaps.no_benchmark: true` → 跳过对标文风召回；2.4 意图确认中使用 `project_style_constraints`，若其也为“无”则标记"无对标参考 / 无本书文风"
     - 若 `gaps.missing_primary_contract: true` → 停止本章准备，按 `repair_action` 提示用 `/novel-assistant 重新拆解对标书` 跑 Stage 3+ 或用 `/novel-assistant 重新导入对标资料`；不得进入 narrative-writer
     - 若 legacy 的 `gaps.module_missing: true` → 继续写作；`selected_emotion_module` 使用 `拆文报告.md` 读者需求 / 情绪引擎、`文风.md` 可借鉴技巧或匹配章摘要的回退摘要；仍无则写“无”
     - 若 legacy 的 `gaps.rhythm_missing: true` → 继续写作；`rhythm_reference` 使用 `拆文报告.md` 节奏与情绪触动点、匹配章摘要或 `剧情/故事线.md` 的回退摘要；仍无则写“无”
     - 若 `gaps.conflict` 或 `gaps.module_rhythm_conflict: true` → 意图确认必须说明冲突并按 `剧情/情绪模块.md` / `剧情/节奏.md` 的权威优先级执行；不得让 `文风.md` 覆盖情绪/节奏目标
     - 若 `gaps.profile_missing: true` 且 `project_style_constraints` 不为“无” → 继续写作，记录 `gaps.benchmark_style_missing=true`，文风指令只使用本书 `设定/文风.md`
     - 若 `gaps.profile_missing: true` 且 `project_style_constraints=无` → 按上文 fail-fast 流程停止
     - 若 `gaps.profile_degenerate: true`（文风不可用） → 跳过文风、回到默认 Gates 写作
     - 若 `gaps.tone_match_failed: true` → 仅用整书文风写作，不喂 matched_chapter
     - 否则原样传给 `project_style_constraints`、`style_profile_path`、`style_profile_summary`、`selected_emotion_module`、`rhythm_reference`、`module_source_path`、`rhythm_source_path`、`matched_chapter_K`、`matched_chapter_techniques`、`anchor_excerpts` 给 Step 2 末尾的 narrative-writer spawn prompt；其中 `selected_emotion_module` 必须进入情绪目标，`rhythm_reference` 必须进入节奏/爆发安排，`matched_chapter_techniques` 必须进入「文风召回指令」。写前准备记录必须保留 `gaps` 原值，尤其 `gaps.module_missing`、`gaps.rhythm_missing`、`gaps.conflict`、`gaps.matched_deep_dive_missing`、`gaps.benchmark_style_missing`；若 `matched_deep_dive_missing` 为 true，文风召回指令中明确写“同章深度拆解缺失，已回退黄金三章/文风技巧”，不得在后续报告中反转为 false
     - **无 story-explorer 时降级**：主会话手动先读 `设定/文风.md` 形成 `project_style_constraints`，再按对标书路径查找，先读 `剧情/情绪模块.md` 选 `selected_emotion_module`，再读 `剧情/节奏.md` 选 `rhythm_reference`，再读对标 `文风.md` + grep `章节/*_摘要.md` 的「基调」字段找匹配章，然后读对应 `第K章_摘要.md`；如 `第K章_深度拆解.md` 不存在，改读 `第1-3章_深度拆解.md` 中与本章基调最接近的一章。对标 `文风.md` 缺失但 `project_style_constraints` 不为“无”时继续写作；两者都无才按文风缺失 fail-fast。模块/节奏文件缺失时先判定 v12 vs legacy：v12 停止修复，legacy 才按上方回退继续
   - **2.4 意图确认 + 作者吸收卡召回 + 用户风格画像加载**：从细纲「目标情绪」字段确认本章情绪目标。若 `设定/作者吸收笔记.md` 存在，加载 [author-absorption-protocol.md](author-absorption-protocol.md)，只选与本章目标情绪/爽点类型相关的 1-2 张卡；必须把卡里的「正文动作」转成当前章节动作，不得把来源书桥段、名词或台词写入 prompt。随后加载 [user-style-learning.md](user-style-learning.md)：若存在 `设定/作者风格/我的写作偏好.md`、`设定/作者风格/正文风格画像.md`、`设定/作者风格/禁用表达.md`、`设定/作者风格/修改偏好案例.md` 或 `追踪/schema/user-style-rules.jsonl`，把与本章相关的用户硬约束、用户软偏好、本书限定规则、角色口吻规则和禁用表达压缩成 `user_style_constraints`；不存在则写 `user_style_constraints=无`。综合状态筛选结果 + `selected_emotion_module` + `rhythm_reference` + `project_style_constraints` + 文风召回输出 + 作者吸收卡 + `user_style_constraints`，用一句话写本章意图（情绪+节奏+模块+本书文风+对标参考+本章吸收动作+用户风格画像+对话声线基线）。若新版细纲存在，意图确认必须显式带入：内容概括决定起承转合，情节安排决定主线/辅线/事件线/感情线/逻辑线的取舍，人物关系和出场顺序决定镜头进入顺序，情节细化决定代价兑现/收益兑现，结尾设定和钩子决定章尾承接；并落实三条 craft——① 发展/转折=爽点(高潮)的铺垫蓄势，爽点出手前先铺可指认的危机/期待（plot-emotion-system 倒推法，不铺=空洞）；② 装逼/打脸/揭露章把 视角/信息差 经 出场顺序 里的在场配角放大成差异化反应（plot-core-methods 信息差×人际×情绪/集体震惊）；③ 按本章基调标注**对话声线基线**：防机械对话、防科普嘴、防说话不分场合；高压/生死/悲痛 beat 里搞笑担当或轻快配角声线让位，信息型配角不当科普嘴，所有对话逐句承接上一句情绪（承接/偏转/升级/退缩）。
   - **2.5 Chapter Contract**：加载 `references/chapter-contract.md`，生成本章契约并写入 `追踪/章节契约/第X卷/第{N}章.md`（旧项目可回退 `追踪/章节契约/第{N}章.md`）。**章节契约写入预检**：生成契约正文前先 `mkdir -p 追踪/章节契约/第X卷`，运行 `test -w 追踪/章节契约/第X卷`，并做临时写入测试；旧项目回退路径同样先检查 `追踪/章节契约`。如果目录不存在、`test -w` 失败、临时写入失败、工具返回 `Error writing file` / `Permission denied`，立即停止，输出当前用户、目标目录和父目录 `ls -ld`、目录 ownership 与 `sudo chown -R $(whoami):$(id -gn) <book-dir>` 修复建议；不得继续生成正文、不得假装契约已落盘、不得连续重试 Write。契约必须包含当前卷目标、本章服务卷目标的方式、必须交付 beat、禁止事项、允许新增项和章尾期待。契约落盘后才允许装配题材卡和写正文。
   - **2.5a 单张题材正文卡**：Chapter Contract 落盘后再加载 [genre-prose-cards.md](genre-prose-cards.md)。从 `设定/题材定位.md` 的主题材、平台、目标读者情绪和当前章节 Brief 选出一张 `genre_prose_card`；混合题材先选主题材，辅题材只补一个场景限制。然后以 Chapter Contract 为硬边界，与 `project_style_constraints`、用户风格取交集，删除契约禁止或无关项，只向 writer packet 传这一张裁剪卡。卡片只保留本章的场景压力、读者承诺、可见动作、语言边界和避免项；不得把全文卡库注入 prompt，不得传卡名、卡片字段名、合规自评、来源样本或题材分析，也不得让这些元数据泄漏到正文。
   - **章节提交事务（生产默认）**：新项目不得让 narrative-writer 直接覆盖 canonical 正文和追踪台账。先把正文候选、伏笔、时间线、角色状态、上下文与交接包写到 `追踪/story-system/work/<workflow-id>/第X卷/第{N}章/`；所有机器门、Plot Drift Gate 和 State Delta 核对都针对暂存制品。门禁全部通过后，生成 manifest，先运行 `node scripts/chapter-commit.js prepare --project-root <book-root> --manifest <manifest.json> --json`，再运行 `node scripts/chapter-commit.js accept --project-root <book-root> --transaction <transaction_id> --json`。只有返回 `status=accepted` 且存在 `commit_id/commit_file`，本章 canonical 正文与追踪状态才算完成。`accepted_with_projection_debt` 表示正文已安全接受但记忆投影未闭环，必须运行 `chapter-commit.js replay` 修复到 `projection_current` 后才能进入下一章。prepare/accept 冲突、回滚、门禁失败或投影债务未清时不得进入下一章。旧项目缺少事务脚本或用户明确保留旧直写结构时可兼容执行，但 result packet 必须写 `chapter_commit.mode=legacy_nontransactional`、列出实际变更文件和风险，不能把它报告为事务提交成功。
   - **2.6 正文写作 + 正文落盘路径握手**：按 Chapter Contract 写正文，并把 `selected_emotion_module` 写入情绪目标、`rhythm_reference` 写入节奏/爆发安排，把 2.4 选中的作者吸收卡转成“本章具体动作”（开场压力/中段误导/反应层/章尾钩子等），不得照搬来源书名词、桥段和台词。调用 narrative-writer 前先确定 `expected_draft_path=正文/第X卷/第{NNN}章_{细纲章名}.md`，并显式传入 prompt；prompt 必须包含 `项目文风约束：{project_style_constraints}` 与 `用户风格画像：{user_style_constraints}`。本书 `设定/文风.md` 与用户硬约束必须遵守；对标文风只作为参考；用户软偏好按场景采纳；任何风格约束都不得突破 Chapter Contract、正文门禁、AI味门禁和平台/安全约束。narrative-writer 返回摘要必须包含 `actual_draft_path`、`chapter_no`、`volume`、`char_count`、`write_status: landed`。主会话不得用自己猜测的固定路径读取正文；必须先用 `node scripts/chapter-draft-resolve.js <book-dir> {N} --volume 第X卷 --json` 解析真实落盘路径，并把返回的 `relPath` 作为后续字数验证、退化检测、标点收尾、`check-ai-patterns.js`、`story-prose-gate.js`、Plot Drift Gate 的唯一正文路径。若解析结果为 `missing` / `ambiguous` / `noncanonical`，或出现 `FileNotFoundError`，立即停止：列出 narrative-writer 返回的 `actual_draft_path`、解析器 candidates、`find 正文 -name '第{NNN}章_*'` 结果；不得继续下一章，不得把 `Done` 当作落盘成功。→ **字数验证（优先 `node scripts/chapter-text-stats.js <actual_draft_path> --json`，缺脚本才回退 Python / `wc -m`；< 目标90%则强制扩充）** → **退化检测（`node scripts/check-degeneration.js --check --fail-on=blocking <actual_draft_path>`，blocking 命中不得进入后续门禁）** → 检查钩子/爽点 → **正文元信息扫描** → 禁用词扫描。
     - **2.6a 事务路径优先级**：上一条中的 canonical `expected_draft_path`、`chapter-draft-resolve.js` 和 `write_status: landed` 只适用于 `legacy_nontransactional` 兼容模式。生产事务模式必须传 `candidate_draft_path=追踪/story-system/work/<workflow-id>/第X卷/第{N}章/正文.md` 与 `write_status: staged`；字数、退化、AI 句式、正文门和 Plot Drift Gate 直接读取该候选文件。`chapter-draft-resolve.js` 只能在 accept 成功后运行，用来核对 canonical 目标与 commit 记录一致，不能在 accept 前把暂存稿误判为缺失。
     - **正文元信息扫描**：标题行以外不得出现 `第[一二三四五六七八九十百千万两0-9]+章|上一章|上章|前一章|本章|这一章|前文|后文|伏笔|细纲|读者`。这些词属于写作/工程元信息，必须改成角色当下能感知的事件锚点或相对时间；例如“比第一章那三秒开火更疼”改成“比那三秒开火更疼”。只有角色在故事世界内真实阅读/讨论“第X章”文本，或真实身为作者/读者并谈论读者身份时例外。
     - **具体字数表达校验**：评价台词、题字、信件、诏令、念头或弹幕时，只有统计口径明确、已用脚本逐字核对且故事确有必要，才使用“这五个字 / 短短四字 / 三个字一落 / 八个字砸下去”这类具体字数表达；不能确保字数计算正确时，改成“这句话一落”“这一句落下”“那几个字”“这行字”“话音落下”等非具体数字表达。
   - **2.7 Plot Drift Gate**：加载 `references/plot-drift-control.md`，对照 `追踪/章节契约/第X卷/第{N}章.md`、细纲、卷纲、角色不变量、角色状态、伏笔和时间线检查本章。出现 S1 必须修复；出现 S2 必须修复或由用户明确确认保留。未通过前不得宣布本章完成。
   - **2.7a 长篇节奏门**：在 Plot Drift Gate 前后对照逐章 Brief 和每节 Brief，确认每节至少推动人物处境、关系权力、信息认知、目标进度或风险中的一项；纯回顾、说明和同一情绪反复不能冒充场景推进。再与前两章的章节定位比较：高压、推进、关系/回收、低压/生活、信息整理应服务卷级折线，不把所有章压成同一种钩子或高潮。门不以固定爽点数、句长、对话比例或字数配比裁决；题材、平台和已确认节奏允许例外，但例外必须写入 Chapter Contract。无可验证的推进或节奏依据时回到 Brief/细纲补齐，不以自由扩写跨过门。
  - **2.8 State Delta Ledger**：加载 `references/state-delta-ledger.md`，只记录本章导致的状态变化，不写泛泛章节摘要。State Delta 写完后再同步下列追踪文件：
    - `追踪/伏笔.md`（新增/回收伏笔）
    - `追踪/时间线.md`（记录事件时序）
    - `追踪/角色状态.md`（如本章引起角色状态变化——身份、能力、关系、公众形象——则更新对应角色条目并追加变更记录）
    - `追踪/上下文.md`（只更新进度元信息：当前位置+已写字数+本次变更，不写详细角色状态/伏笔内容）
  - **2.9 Chapter Handoff Pack**：加载 `references/chapter-handoff-pack.md`，新项目运行 `bash scripts/chapter-handoff-pack.sh --write --volume 第X卷 <book-dir> {N}`（旧项目可省略 `--volume`），新项目保存到 `追踪/交接包/第X卷/第{N}章_to_第{N+1}章.md`（旧项目可回退旧路径）。交接包必须在 Plot Drift Gate 为 PASS 且 State Delta 已同步后生成；生成失败时不得进入下一章。
  - **2.10 Cross Chapter Continuity Audit**：从本批第 2 章开始，加载 `references/cross-chapter-continuity-audit.md`，新项目运行 `bash scripts/cross-chapter-continuity-audit.sh --volume 第X卷 <book-dir> {N-1} {N}`（旧项目可省略 `--volume`），确认上一章交接包已进入本章 Chapter Contract 和正文；失败时先修本章契约/正文，再重跑 Plot Drift Gate、State Delta Ledger 和 Chapter Handoff Pack。
  - **2.11 Cross Volume Handoff / Audit**：如果本章是新卷第 001 章，先运行 `bash scripts/cross-volume-handoff-pack.sh --write --from-volume 第{X-1}卷 --to-volume 第X卷 <book-dir> <上一卷末章> 001`，把上一卷预留钩子、未回收伏笔、角色状态和卷末余波写入 `追踪/卷交接/第{X-1}卷_to_第X卷.md`。本章写完后运行 `bash scripts/cross-volume-continuity-audit.sh --from-volume 第{X-1}卷 --to-volume 第X卷 <book-dir> <上一卷末章> 001`，确认跨卷关键词已进入下一卷卷纲、首章契约和首章正文；失败时先修下一卷卷纲/契约/正文，或在契约写明延迟回收窗口后重跑。
   - **质检提示**（可选）：本章写作完成。如需一致性检查，运行 `/novel-assistant 审查当前正文`。批量写作模式跳过此步骤，全部写完后再统一审查。
3. **不中断但不并发**：一章写完不问用户，直接写下一章（除非用户要求逐章确认）；下一章必须读取上一章刚写入的正文、追踪更新和 `追踪/交接包/第X卷/第{N-1}章_to_第{N}章.md` 后再开始。

**资料研究（按需）**：如果写作中遇到需要查证的外部事实（历史年代、地理方位、职业细节等），暂停写作，spawn `story-researcher` agent 搜索并输出到 `参考资料/` 目录。研究完成后再继续写作。

---

## Step 3：质量检查

批量写作结束后，对本次所有新写章节执行 Phase 5 质量检查（至少包含）：

1. **禁用词扫描**：对照 `references/banned-words.md`，一级词命中即替换
2. **标题去重检查**：汇总本轮新写章节与既有标题；发现同名或明显重复时，回到对应细纲和正文文件统一重命名
3. **正文元信息扫描**：检查标题行以外是否混入 `第[一二三四五六七八九十百千万两0-9]+章|上一章|上章|前一章|本章|这一章|前文|后文|伏笔|细纲|读者` 这类写作工程词，命中即改成场景内表达；故事内真实阅读/讨论“第X章”或真实读者身份语境除外
4. **稳定性门控回看**：确认本轮每章都已经执行 `Chapter Contract → Plot Drift Gate → State Delta Ledger → Chapter Handoff Pack`，并从本批第 2 章开始完成 `Cross Chapter Continuity Audit`；缺任一环节时补跑，不得只凭正文完成度宣布日更完成
5. **Longform Daily Stability Audit**：加载 `references/chapter-index.md` 和 `references/longform-daily-stability-audit.md`，新项目运行 `bash scripts/longform-daily-stability-audit.sh --write --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>`（旧项目可省略 `--volume`），对本批章节做最终批量验收，并保存到 `追踪/稳定性审计/第X卷/日更_第{start}章_to_第{end}章.md`。该命令会在批量检查前刷新 `追踪/章节索引.tsv`。自动化或 agent 编排场景可改用 `--write --json`，用 JSON 的 `status`、`failures`、`checks[].error_codes` 分流修复任务。总审计失败时加载 `references/stability-repair-dispatcher.md`、`references/stability-repair-loop.md` 和 `references/stability-agent-dispatch-prompts.md`；`Stability Repair Dispatch` 负责把失败项分派成 `actions`，`Stability Repair Loop` 负责生成当前 checkpoint，`Stability Agent Dispatch Prompts` 负责按 `current_owner` 生成标准 Agent prompt。新项目运行 `bash scripts/stability-repair-loop.sh --write --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>`，runner/agent 可改用 `--write --json` 读取 `current_owner` 和 `current_action`。如项目已部署 story-explorer，调用 `stability_repair_load` 只读加载 `current_owner`、`current_action`、`repair_report_path`、`loop_report_path`、`audit_report_path` 和 `verification_commands`。

   - 当 `current_owner=story-architect` 时（常见 code：`Plot_Drift`、`Foreshadow_Early_Payoff`、`Beat_Missing`、`Beat_Compressed`），套用 `stability-agent-dispatch-prompts.md` 的 story-architect prompt，先做结构裁决，裁决范围必须是 `改正文 / 改契约 / 改细纲 / 后移伏笔 / 需要用户确认`。
   - 当 `current_owner=character-designer` 时（常见 code：`Motivation_Drift`、`Knowledge_Leak`），套用 `stability-agent-dispatch-prompts.md` 的 character-designer prompt，先做角色裁决，裁决范围必须是 `补动机链 / 改行动 / 补获知过程 / 删除越界认知 / 更新角色不变量 / 需要用户确认`。
   - 当 `current_owner=narrative-writer` 时，套用 `stability-agent-dispatch-prompts.md` 的 narrative-writer prompt，只改当前 checkpoint，禁止整章重写。
   - 当 `current_owner=consistency-checker` 时，套用 `stability-agent-dispatch-prompts.md` 的 consistency-checker prompt，只审查当前 checkpoint。

   修完后调用 consistency-checker 做 checkpoint 审查，检查范围仍只限 `current_action`。最后按 `verification_commands` 重跑对应 gate 和 `bash scripts/stability-repair-loop.sh --write --volume 第X卷 <book-dir> <start-chapter-id> <end-chapter-id>`（旧平铺项目才省略 `--volume`），直到闭环状态 PASS。不得汇报“本批完成”，必须先按 checkpoint 修复并重跑闭环。
6. **钩子检查**：每章章尾是否有钩子；如新版细纲有「结尾设定和钩子」，检查正文是否兑现收束状态、未解决问题和下一章推动力
7. **对照细纲核对**（正文有没有按细纲写到）：新版细纲存在时，核对正文是否消费了内容概括五段式、情节安排多线、人物关系变化/出场顺序、代价兑现/收益兑现；并加三条 craft 兑现核对（不达标→修复）：① 爽点出手前是否有可指认的危机/期待铺垫段落？指不出=空洞 → 回 Step 2 补铺垫情节点（plot-emotion-system 倒推法）；② 装逼/打脸/揭露章是否写出在场配角差异化反应（集体震惊/各异），还是只写主角动作？没有 → 补在场配角反应（plot-core-methods）；③ 详略是否按目的词（爽点/卖点点展开、过渡点带过、信息密度交替），还是均匀注水？均匀 → 删过渡、扩爽点点。旧版细纲只核对核心事件、目标情绪、章首/章尾钩子和字数目标
8. **伏笔盘点（仅本轮增量）**：只确认本批新增/推进/回收的伏笔已写入 `追踪/伏笔.md` 并更新状态；不得在日更流程中通读所有 session 或扫描全部正文做全量伏笔审计。全量伏笔审计只在内部模块 `story-review` 或用户明确要求"全面检查伏笔"时执行
9. **确定性标点与退化收尾**：对本批所有新写正文文件先运行 `node scripts/chapter-draft-resolve.js <book-dir> {N} --volume 第X卷 --json` 取得真实 `actual_draft_path`，再依次运行：`node scripts/check-degeneration.js --check --fail-on=blocking <actual_draft_path>`、`node scripts/normalize-punctuation.js <actual_draft_path>`（写模式，默认 `--quote-mode keep`）、`node scripts/check-ai-patterns.js --check --fail-on=blocking <actual_draft_path>`。旧项目只有在解析器报告 `noncanonical` 且用户确认保留旧结构时才用 `正文/第XXX章_*.md`。`check-degeneration.js` blocking 命中逐字复读、截断、占位拒绝语或纯工程词泄露时，必须重写受影响单元；`normalize-punctuation.js` 清理正文里不必要的 `……`、破折号 `——`/`—`、双连字符 `--` 和独立行 `---`；正文标题行以外破折号允许合理少量、有功能使用，破折号密度失控或逐字破折号化必须回炉重写；`check-ai-patterns.js` 报告“先否定再肯定 / 否定铺垫后肯定翻转”、破折号功能改写、碎句号和长段落，其中 blocking 命中必须改文并复扫到 0，advisory 用于节奏提示。**由谁运行**：narrative-writer agent 不运行本脚本；主会话在 agent 写完返回后、针对实际落盘的正文文件路径运行（文件名是写完才确定的 `第XXX章_章名.md`）。命中退化、破折号密度、逐字破折号化或 blocking AI 句式时不得进入本章 Plot Drift Gate，也不得汇报本批完成。
10. **正文门禁**：对本批每一章运行 `node scripts/story-prose-gate.js <book-dir> --chapter {N} --write`。它会检查规范卷目录正文、破折号/省略号残留、逐字破折号化坏稿，以及旧平铺章节文件污染。返回失败时按报告定位修复，再重跑确定性标点收尾、`check-ai-patterns.js` 复扫和正文门禁；不得宣布日更完成。

> 完整 Phase 5 检查清单见 SKILL.md Phase 5。

---

## Step 4：进度摘要

更新 `追踪/上下文.md`（每章完成时已增量更新，此处做最终汇总）：

```markdown
## 写作进度

- 最后完成章节：第 {N} 章
- 更新时间：{日期}
- 本期完成：{K} 章，共 {X} 字

## 当前状态

- 活跃伏笔：{N} 条（详见追踪/伏笔.md）
- 角色状态：最近变更 {角色名}（详见追踪/角色状态.md）
- 下一章细纲状态：{已有/需补建}
- 注意事项：{需要记住的关键决策或变更}
```

---

## 细纲缺失补建流程

当检测到细纲不存在时，不能跳过。按以下步骤补建：

1. 加载 `大纲/卷纲_当前卷.md`（本章对应的事件规划）
2. 加载本章涉及的 `设定/角色/{角色名}.md`（角色状态）
3. 读取最新一章正文（情节衔接）
4. 按 SKILL.md Phase 3 的新版细纲模板补建本章细纲，补齐内容概括、情节安排、人物关系/出场顺序、情节细化、结尾设定；无法从卷纲/正文/设定确认的字段写 `[待补充]`，不杜撰
5. 补建后重新执行 Step 0；仍有 `[待补充]` 或未确认项时返回 `outline_underfilled`。只有 Brief 全字段通过且本次请求已明确目标书与章节，才继续 Step 2 写作

---

## 常见问题

| 问题 | 处理 |
|------|------|
| 细纲不存在 | 执行上方"细纲缺失补建流程" |
| 旧版细纲缺新版蓝图字段 | 不阻塞日更；本轮需要改纲/补纲时按新版模板回填，未知项写 `[待补充]` |
| 追踪文件为空 | 正常继续，写作中逐步填充 |
| 用户要求改大纲 | 提醒"改大纲会影响后续细纲"，确认后修改，标记受影响的细纲 |
| 写到卷末 | 先生成 `追踪/卷交接/第X卷_to_第Y卷.md`，列出上一卷预留钩子/伏笔/角色状态，再提示用户是否开新卷 |
| 用户中断批量写作 | 保存当前章节，已更新追踪文件，下次从断点继续 |
