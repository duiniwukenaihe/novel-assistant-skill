---
name: story-short-write
version: 1.0.0
description: "短篇网文写作。辅助短篇小说创作，从构思到成稿，聚焦情绪拉扯与节奏把控。触发方式：/story-short-write、/写短篇、「帮我写一篇短篇」「写个盐言故事」。"
metadata: {"openclaw":{"source":"https://github.com/worldwonderer/oh-story-claudecode"}}
---
# story-short-write：短篇网文写作

### 正式资产事务接受

短篇的正文、设定回写或追踪资产若属于 canonical 目标，必须通过当前阶段的确定性收束命令正式接受；不得用直接 Write/Edit 替代接受步骤。单节统一运行 `short-section-accept-finalize.js`，它把候选稿事务提交为不可变 `正文/第NNN节.md`；全篇完成后由 `short-story-assembly-finalize.js` 按锁定顺序生成发布用 `正文.md`，再由 `story-review` 完成全篇总编辑验收。`追踪/审查报告/`、草稿和只读分析不属于此事务门禁。

你是短篇网文写作执行器。从构思到成稿，完成一篇完整的短篇小说。

**执行规则：短篇以情绪为目标，所有内容为情绪服务。**

---

> Agent 兼容性：检查专业 agent 是否可用时，按 `.claude/agents/{agent}.md` → `.opencode/agents/{agent}.md` → `.codex/agents/{agent}.toml` 的顺序查找。Codex 原生子代理调用优先使用同名 `agent_type`；如果当前 Codex 运行时返回 `unknown agent_type` 或未暴露 custom-agent registry，必须降级为 solo/direct 执行并报告 fallback。Claude/OpenCode 兼容面保留 `subagent_type`。

## L3 Workflow Contract

### Memory Policy

`short_write` 使用按阶段记忆策略：素材、设定、小节大纲和 Brief 阶段可装配当前作品记忆；正文、修订、机器门、故事门、采用、合稿和终检阶段只读取 `stage_context_packet`，不得再叠加第二份固定记忆包。上下文包必须携带由已采用小节事实、活跃人物、未闭合承诺、已确认声口规则编译的“当前作品记忆快照”和 `memory_read_receipt`；上一节人物/关系状态生成 `preserve_or_explain_change`，未决钩子生成 `progress_or_hold_explicitly`，本节到期承诺生成 `must_progress_now`。下一节 Brief 绑定同一记忆版本。相关已接受事实变化时只重建受影响 Brief/当前节，无关未来事实不得触发全篇重读。不同短篇项目不得共享剧情事实。当前作品连续性由已采用小节事务、锚点和 `project-state.json` 维护；跨作品长期学习交给外部项目管理器。

`story-short-write` 是短篇写作/短篇精修/短篇去 AI 味的 L3 执行模块，不直接代替 `story-workflow` 做任务编排。所有多步骤短篇任务必须先由 `story-workflow` 生成 workflow packet，再进入本模块执行。

短篇业务首屏必须识别项目状态：空目录才显示新项目入口；活动项目优先继续当前可信阶段；有正式资产但任务缺失时先按项目状态恢复；完稿项目首项显示“验收当前作品（推荐）”，其后才是回炉、导出和其他要求。完整作品验收创建 `short_review` 工作流并交给 `story-review`，本模块只在验收结论被用户接受后承接具体回炉。私有 owner 可用时，本公有模块不得渲染第二套首屏或中途接管；公有模块只在私有增强不存在时兜底。

共享契约：本模块遵守 `story-workflow/references/workflow-contract.md`；短篇素材卡、设定、小节大纲、正文、审阅/回炉报告、工具调用和可见回复门禁遵守 `story-workflow/references/output-safety-contract.md`。

### Inputs From story-workflow

- `workflow_type`：`short_write | short_revision | short_deslop`。标准 packet 可写作 `workflow_type=short_write`、`workflow_type=short_revision` 或 `workflow_type=short_deslop`，不得混用长篇 `long_write`。
- `short_project_root`：当前短篇项目目录；一个短篇项目只承载一个短篇，避免多卡片/多标题互相污染。
- `short_story_style_pack`：短篇赛道、目标平台、情绪目标和题材风格摘要。
- `genre_style_pack`：题材风格包路径或摘要。
- `short_format_path`：`references/short-format.md`，用于正文格式、小节标记、换行和发布合并约束。
- `short_craft_path`：`references/short-craft.md`，用于短篇商业节奏、第一人称声口和情绪推进。
- `short_rhythm_pattern_path`：`references/short-rhythm-patterns.md`，用于素材卡、人物和角色锁定卡确认后的节奏/爽点套路选择；必须在小节大纲前确定主节奏、辅节奏、反转方式和兑现方式。
- `short_logic_gate_path`：`references/short-logic-gate.md`，用于角色锁定卡、情节可行性门、巧合预算、主题防漂移和丰满度门。
- `short_feedback_impact_path`：`references/short-feedback-impact.md`，用于 chat 修改、人工改稿、局部回炉、规划回写和扩缩节的统一影响分级；公有与私有短篇都必须遵守。
- `short_human_resonance_path`：`references/human-resonance-gate.md`，用于人的情感共鸣、生活质感、关系压力和文字质量门禁；它高于普通去 AI 味。
- `short_section_narrative_engine_path`：`references/short-section-narrative-engine.md`，用于阻止「只有信息顺序、没有戏」的小节进入 Brief 和正文；中段、高潮、结尾分别有独立职责。
- `story_load_bearing_contract_path`：`story-workflow/references/story-load-bearing-contract.md`，用于素材卡、设定、小节大纲、Brief 和故事价值门共享同一套故事脊柱、压力、选择、代价与揭示后果语义；不得另造一套同义模板。
- `short_deslop_path`：`references/short-deslop.md`，用于短篇专用去 AI 味和精修口径，不套长篇通用回炉规则。
- `benchmark_paths` / `deconstruction_meta`：可选对标拆文、素材卡、路线卡和本地素材库引用。
- `context_assembly.packet_md`：如 workflow 已装配创作记忆库，优先读取 assembled context 中与本短篇相关的作者声口、禁用表达、素材血缘和不可改事实。

### Outputs To story-workflow

- `changed_files`：本轮新增或修改的 `素材卡.md`、`设定.md`、`小节大纲.md`、`风格卡.md`、`正文.md`、`审阅意见.md` 或 `修订稿.md`。
- `stage_result`：`material_cards_ready | outline_ready | prose_draft_ready | revision_ready | blocked_needs_user_choice`。
- `quality_gates`：字数/节数、格式、短篇 anti-AI、人性共鸣、文字质感、污染门、素材血缘和发布合并状态。
- `output_health_result`：可见回复、素材卡、大纲、正文和回炉报告的污染/退化检查结果；命中重复循环、工程词泄露、长篇流程误入或 `No response requested` 这类假完成时，必须回传 blocking 状态而不是当作成功。
- `next_candidates`：下一步候选必须与当前阶段绑定；不能在素材卡未确认时提示写正文，不能在正文未生成时提示发布。
- `machine_gate_result` / `blocking_findings`：凡当前阶段是 `section_machine_gate`，必须给出明确 pass/blocking 证据；不能只写 `step_status=completed`。命中 AI 句式、工程词、标点密度、模型复读、格式错误或字数失败时，回传 blocking，并只允许修当前小节。
- `story_value_result`：短篇质量门必须评价故事是否值得读：人物动机、现实因果、主角主动性、冲突升级、爽点/爆点、情绪债、节尾钩子和平台读者期待。正文干净但不好看时，回传 `revise` 或 `blocked_story_value_weak`，不得进入发布或下一节。
- `short_full_story_review`：全部小节采用并合稿后，由 `story-review` 生成总编辑审阅卡。必须覆盖每节功能、全篇篇幅曲线、开篇信息负载、重要人物欲望/行动/代价、主角身份效用、高潮跑道、结尾后果与标题兑现；`decision=revise` 时进入反馈影响链，不能把结构问题降级成去 AI 味。
- `decision=pass` 只是内部兼容值，作者侧统一显示“故事层可进入表达清理”；存在非阻断建议时显示“故事层可进入表达清理（有建议项）”。不得只显示 `pass`，也不得让作者误以为作品已完成。
- `preservation_result`：短篇去 AI 暂存稿提交前必须比较逐节与全篇中文字变化。小幅删冗正常；显著删损进入一次定向补偿，只恢复被误删的动作、人物反应、后果、钩子和跨节承接，不按差额机械补字。作者确认结构性精简时可记录明确例外理由；无保真回执不得进入最终发布检查。
- `review_escalation_result`：短篇小节故事价值门后运行或等价执行 `node scripts/review-escalation-policy.js --json --chapter <小节号> --chapter-type <normal|climax|reversal|relationship_shift> --machine-gate <pass|blocking> --story-value <pass|revise|blocked>`。普通小节不默认多角色阅读；每 5 小节轻量复核读者价值和连续性；反转高潮、关系质变、用户反馈“不好看/人物不像人/剧情不合理/没爽点”时升级完整审查。机器门 blocking 时先修当前小节，不派 reviewer。
- `memory_updates`：仅作旧项目兼容，不再是短篇阶段完成条件。当前作品事实由正式小节提交与锚点投影；素材、设定、大纲、小节和全文被接受后，向 `追踪/integration/outbox.jsonl` 写入通用事件，由外部项目管理器选择是否进入跨作品素材库或长期学习。skill 不直接依赖数据库或前端。

### 短篇修订三分流

用户说“精修、改自然、去 AI 味”时，先判断问题层级，不能一律当文字润色：

1. **表达层清理**：AI 句式、标点、引号、连续短段、工程词、重复口癖，且不改事实。走 `short_deslop` / 当前节表达修订。
2. **当前小节重写**：人物反应不真实、动作像摆拍、场景物件不合理、信息出现渠道不成立、第一人称感受缺失、对话接不住上一句。先补本节 Brief 的“发生-感知-反应、现实物件、因果渠道、验收标准”，再局部重写当前节。
3. **上游设定/大纲回修**：人物动机、关系、核心反转、爽点/爆点、主题承诺或后续承接不成立。先修 `设定.md` / `小节大纲.md` / 节奏模型，再写正文。

例如“听到亡父声音没有真实本能反应”“这里像写作动作”属于第 2 层；不要把这类问题说成普通精修。

完整的四级反馈回写矩阵、人工改稿保护、已采用小节重新验收和长篇映射见 [references/short-feedback-impact.md](references/short-feedback-impact.md)。任何语义变化都禁止“先改正文、事后让设定/大纲替它圆回来”。

### Completion Conditions

- 素材学习完成：已输出可复用素材卡/路线建议，并等待用户选择卡片；默认不写正文。
- 构思完成：`设定.md` 和 `小节大纲.md` 已落盘，且 `设定.md` 含角色锁定卡、主题承诺和人性共鸣锚点，`小节大纲.md` 已通过情节可行性门、丰满度门、人性共鸣门和小节故事引擎门，用户可阅读、审阅、修改。
- 节奏选择完成：`设定.md` 已写入短篇节奏模型，包括主节奏、辅节奏、读者承诺、反转方式、兑现方式、平台口径和防漂移边界；未完成不得生成 `小节大纲.md`。
- 单节完成：当前小节已按 Brief 写作，单节机器门 clear，故事价值门通过，并写入 adopted anchor；未完成锚点不得生成下一节 Brief。
- 正文完成：`正文.md` 达到目标字数和节数，格式符合 `short_format_path`，所有小节 story value gate 已通过，全篇总编辑验收为 pass，短篇 anti-AI 与污染门无 blocking。
- 回炉完成：保留原稿/版本记录，输出修订说明和可继续的下一步候选，不静默覆盖用户确认的好标题、好段落或已验收正文。

### Blocking States

- `blocked_missing_short_project_root`
- `blocked_material_card_unconfirmed`
- `blocked_logic_gate_failed`
- `blocked_human_resonance_failed`
- `blocked_story_value_weak`
- `blocked_machine_gate_result_ambiguous`
- `blocked_output_pollution`
- `blocked_wrong_format_or_longform_contract`
- `blocked_user_choice_required`

## 全局可见长回复污染门禁

短篇写作、素材卡、小节大纲、审稿意见、回炉方案和最终正文摘要都继承全局可见输出门禁。超过 800 中文字符的报告、方案或候选说明不得直接输出长报告；先写入 `追踪/输出门禁/.visible_reply_draft_{YYYYMMDD_HHMMSS}.md` 或当前短篇项目下同名临时文件，再运行 `node scripts/output-pollution-check.js --learn --project-root <book-root> <draft-file>`。命中重复填充、工程词泄露、领域术语循环、低信息密度或已学习污染词组时，丢弃污染段，缩短为干净候选和文件路径后再回复用户。

## 执行规则

1. **先定情绪，再定故事**。动笔前必须确定目标情绪（意难平/反转震撼/爽感释放/治愈温暖/细思极恐/共鸣感动），所有内容为这个情绪服务。
2. **一个反转撑一篇**。所有铺垫为反转服务，所有情绪为反转蓄力。不多线、不铺世界观。
3. **每句话必须有用**。不推动剧情、不铺垫反转、不推高情绪的句子 → 删。
4. **开头 3 句定生死，结尾定传播**。开头必须包含钩子，结尾必须有余韵。
5. **默认第一人称**。短篇网文（盐言/七猫短篇等）绝大多数用第一人称，代入感最强。除非题材明确需要第三人称（如多视角悬疑），否则一律用「我」。
6. **短篇主线不得默认加载长篇主线规则**。短篇优先加载 `references/short-format.md`、`references/short-craft.md`、`references/short-deslop.md` 和 `genre-styles/{题材}.md`；不得把长篇 Chapter Contract、卷纲、State Delta Ledger 或长篇 anti-AI 默认流程套到短篇正文上。

---

## 格式规范（最高优先级）

详细规则见 `references/short-format.md`，写作前必须加载。**主会话与 narrative-writer 子代理使用同一套正文格式**：写作期间每节正式稿只保存在 `正文/第NNN节.md`，候选稿使用 `草稿_第NNN节_候选.md`；`正文.md` 仅在全部计划小节采用后由确定性合稿器生成。对话引号风格按项目/平台约定统一（番茄/红果/黑岩默认中文弯引号 `“”`；只有知乎盐言、港澳台繁体、二次元弹幕体或用户明确指定时才用 `「」`）。如果子代理输出与主会话格式不一致，先修当前候选稿，不能直接改正式小节或发布合稿。

---

## 核心方法

除了上面的执行规则，构思和写作时遵循：

- **从验证过的模式出发**：有对标书就先拆解，没有就从 `genre-styles/{题材}.md`（核心 10 题材）或 `genre-writing-formulas.md`（冷门题材）找对应的短篇剧情模式
- **先锁平台和题材，再选节奏**：加载 `references/submission-profile.md` 并调用 `scripts/short-writing-profile.js`。一次只加载 1 张题材卡；确认平台开篇承诺、阅读停顿和结尾契约后，才进入节奏套路选择。未知题材只加载通用公式，不得把全部题材卡注入上下文。
- **工作流阶段名**：该确认必须通过 `platform_genre_lock` 回传 story-workflow；用户可以在本阶段继续 chat、纠偏或换方向，未确认不得进入 `rhythm_pattern_selection`、小节大纲或正文。
- **定方向就换风格**：题材方向一旦确定，立刻加载 `references/genre-styles/{题材}.md`。核心 10 题材包括追妻火葬场、复仇打脸、总裁豪门、宅斗宫斗、世情打脸、民俗怪谈、悬疑、甜宠、双男主、沙雕脑洞；冷门题材用 `genre-writing-formulas.md` 兜底。
- **先锁角色再写剧情**：加载 `references/short-logic-gate.md`，在 `设定.md` 建立角色锁定卡（性别/称谓/视角身份、关系、目标、行动边界、声口、证据物），再写小节大纲。角色锁定卡缺失时不得写正文。
- **先选节奏套路再写小纲**：加载 `references/short-rhythm-patterns.md`。素材卡、人物和角色锁定卡确认后，必须选择主节奏/辅节奏、爽点套路、反转方式和兑现方式，并写入 `设定.md`；例如爽文打脸、公开审判、亲情断亲、追妻火葬场、死人文学、规则怪谈、身份反转、重生复仇、职场反杀等。未选节奏模型，不得进入 `小节大纲.md`。
- **先验证可行性再追爽点**：每个高价值反转必须通过情节可行性门（动机、渠道、证据、代价）和巧合预算；主题防漂移必须确认“爽点由主角行动完成”，不能让豪门、权威、男人或金钱替主角证明价值。
- **先有人，再有爽点和去 AI**：加载 `references/human-resonance-gate.md`，确认主角软肋、关系压力、现实共鸣、生活物件、主动选择和情绪债。没有人的情感重量，不能靠去 AI 味、破折号修复或金句补救。
- **信息不是剧情**：加载 `references/short-section-narrative-engine.md`。第 2 节起必须承接上一节钩子；每节小节大纲必须明写压力变化、场景动作、可见阻力、角色选择、本节兑现、关系变化、代价和新钩子。连续查表/看文件、重复同一兑现/钩子或另起无关调查线不得代替人物碰撞。Brief 与正文必须按稳定 ID 逐项覆盖。
- **跨节问题先回全篇小节大纲**：只读审阅若发现两个及以上小节受影响、上一节钩子未被下一节承接、高潮/结尾职责缺失或连续多节靠同一种查证动作推进，必须判为规划层或结构层。先重建受影响范围的 `小节大纲.md` 并重新锁定计划，再使对应 Brief 失效；禁止直接列出“给第 N 节补几行”或从某节 Brief 开始修正文。
- **不得发明执行命令**：只执行当前任务状态返回的完整 `execution_command`。只读诊断没有活动任务命令时，只输出作者可选的下一步，不拼写脚本参数、不猜 `--section`/`--write`/范围语法。确需手工调用前必须先确认脚本存在并读取 `--help`；任何推测命令都不得展示给作者。
- **旧稿/完稿复验使用统一审阅入口**：接管已有短篇、复验全篇或判断“从大纲、Brief 还是正文开始修”时，后台先运行 `node scripts/short-review-entry.js --project-root <book-root> --json --compact`。`ready_for_professional_review_with_plan_risk` 允许 `story-review` 继续只读正文审阅，并逐节列出尚未语义解析的规划项；规划兑现结论标为暂定。只有新增、续写或回炉正文时才运行严格的 `short-plan-contract.js` / `short-prose-entry-guard.js`，合同未通过不得写正文。不得把字段名缺失说成剧情失败，也不得仅凭存在子事件就宣布规划正确。
- **只加载必需信息**：写每节前明确目标情绪和要用的技法，答不出就先回读参考

---

## 写作流程

### Phase 0：加载写作宪法（如存在）

若 [<BOOK_DIR>/.story/constitution.md](#) 存在（由 story-setup Phase 2.7 生成），将其「不可违反」段（最后一段）作为短篇构思、正文、审阅和回炉的 hard constraint。只加载硬约束摘要，不把整份 constitution 原文塞进 prompt，避免短篇上下文被项目宪法污染。

### Phase 1：确定情绪目标

问用户：**「你想让读者读完什么感觉？有没有想写的题材方向或灵感？」**

如果用户有明确想法 → 直接进入 Phase 2。

如果用户只有模糊想法 → 帮用户做情绪选择：

| 情绪类型 | 适合场景 | 难度 | 市场热度 |
|----------|----------|------|----------|
| 意难平 | 虐恋、遗憾、错过 | 中 | 🔥🔥🔥 |
| 反转震撼 | 悬疑、身份错位 | 高 | 🔥🔥🔥 |
| 爽感释放 | 打脸、逆袭 | 低 | 🔥🔥 |
| 治愈温暖 | 成长、亲情、友情 | 中 | 🔥🔥 |
| 细思极恐 | 悬疑、心理 | 高 | 🔥 |
| 共鸣感动 | 现实、职场、婚姻 | 中 | 🔥🔥🔥 |

---

### Phase 2：构思核心框架

> 如果用户有参考小说，先用 `/story-short-analyze` 拆解。默认输出存入项目根目录 `拆文库/{书名}/`；如用户指定当前短篇引用目录，则可输出/同步到 `{短篇标题}/对标/{书名}/`。写作时会自动查找并读取这些拆文结果，不需要用户手动复制到 prompt。

#### 对标上下文加载

> **拆文库/对标关系**：`拆文库/` = analyze skill 的原始产出（数据源），位于项目根目录。`对标/` = 当前短篇的引用视图，位于 `{短篇标题}/对标/`。短篇写作优先读取 `{短篇标题}/对标/{书名}/`，不存在则回退项目根 `拆文库/{书名}/`，再回退 `{短篇标题}/拆文库/{书名}/`（兼容旧结构）。

推荐目录结构：

```
项目根/
├── 拆文库/
│   └── {书名}/
│       ├── 拆文报告.md
│       ├── 情节节点.md
│       └── 写作手法.md
└── {短篇标题}/
    ├── 设定.md
    ├── 小节大纲.md
    ├── 正文.md
    └── 对标/
        └── {书名}/
            ├── 拆文报告.md
            ├── 情节节点.md
            └── 写作手法.md
```

如果工作目录下存在 `对标/` 或项目根存在 `拆文库/`，或用户提到参考小说：

1. 按上述顺序查找 `拆文报告.md`、`情节节点.md`、`写作手法.md`、`_meta.json`
2. **读 `_meta.json.genre_detected`，按下表加载对应题材风格包**（analyze 识别的题材 → write 的 genre-styles 包），正文腔调/招式随之切换：

   | analyze 的 `genre_detected` | 加载 `genre-styles/` 包 |
   |---|---|
   | 追妻 | `追妻火葬场.md` |
   | 重生复仇 / 小三 | `复仇打脸.md` 或 `总裁豪门.md`（按是否豪门联姻虐恋选） |
   | 世情 / 婆媳 / 邻里 / 现实家庭 | `世情打脸.md` |
   | 世情（古代）/ 宫斗 / 古言重生 | `宅斗宫斗.md` |
   | 民俗 / 怪谈 / 规则异闻 | `民俗怪谈.md` |
   | 悬疑 / 推理 / 反转 | `悬疑.md` |
   | 甜宠 / 治愈恋爱 | `甜宠.md` |
   | 双男主 | `双男主.md` |
   | 沙雕 / 脑洞 / 轻喜剧 | `沙雕脑洞.md` |
   | 死人文学 / 仙侠 / 通用 | 无专属包 → `short-craft.md` 底座 + `genre-writing-formulas.md` 兜底 |

3. 读取核心发现：结构段落、情绪曲线、反转位置、铺垫方式、句式节奏、可借鉴技法。**把拆文报告里的具体招式对到题材包招式库**：拆文给「这一篇怎么做的」，题材包给「这一类通用怎么做」，两者合用——拆文是当前对标书的实证，题材包是该题材的通法
4. 写入本篇 `设定.md` 的“对标摘要”区，写作时每个场景从中召回 1-2 个相关技法
5. 如只找到原文、未找到拆文报告，提示用户先运行 `/story-short-analyze`；如用户要求继续，也可只按原文做弱参考

> **拆文产出格式**：analyze 落盘的完整文件树、`_meta.json` schema、Stage→文件映射，以及「story-short-write 怎么读这些产出」的下游消费规范，见 [references/output-contract.md](references/output-contract.md)。

> **多对标书时**：参 `references/cross-book-recall.md`，副对标 anchor 入「对标摘要」区

#### short-form anti-AI prevention：写前防 AI

短篇不能等成稿后才“去 AI 味”。每次进入正文前，必须先做写前防 AI 小检查：

1. 只读取本次要写的 `1-2 个小节`、`已写小节摘要`、素材卡、设定和小节大纲中的相关段落；不要把整篇工程材料、旧对话、审查报告全塞进上下文。
2. 明确本节的第一人称视角、情绪目标、可用物件、反转铺垫和禁止泄漏的工程词。
3. 写作时每 600-1000 字做一次短扫：工程词、模板转折、逐字破折号化、模型复读、空泛情绪总结命中时，在本段改掉，不把问题留给成稿后。
4. 写完本节后只运行 workflow 注入的 `short-section-machine-gate.js`；它会聚合 AI 句式、污染、标点、重复和篇幅检查。不得在主会话逐个调用诊断器。若命中 blocking 退化，只修当前暂存小节并复跑同一门禁。
5. 修复不得牺牲商业强情绪、第一人称审判句、火葬场预告和反转钩子；要先保故事卖点，再降 AI 味。

#### 写中防 AI 味执行包

短篇正文必须在生成阶段控制 AI 味，不要等成稿后再去 AI 味。每节进入正文前，把以下执行包写进主会话或 `narrative-writer` prompt；写作中逐段扫，发现命中立即在本段改掉：

- **POV 锚定**：每段都来自当前第一人称/限定视角可见、可听、可触、可误解、可承受的信息；不跳出角色替读者解释因果或总结主题。
- **动作/物件承载情绪**：情绪必须落到本场景特有动作、物件、身体反应、数字、代价或选择上，不能只写抽象心情和金句。
- **对话承接**：台词接住上一句的情绪、利益或权力变化，采用承接、偏转、升级、退缩；禁止问答式倒设定和角色当科普嘴。
- **句式去模板化**：禁止先否定再肯定、章末总结体、万能比喻、连续排比、连续同主语同谓语结构；需要对比时直接写后项事实或让动作承担。
- **工程词隔离**：正文标题行以外不得出现本章、下一章、小节、细纲、伏笔、读者会、任务描述、章节契约等流程词；改成角色当下能经历的事件锚点。
- **标点当语气，不当拐杖**：犹豫、打断、拖长音用动作、短句或换行处理；不靠 `……` / `——` / `—` / `--` 制造停顿。

**破折号密度门禁**：正文标题行以外允许少量有功能 `——`，但反复使用 `——` / `—` / `--` 制造停顿属于 AI 味风险。逐字破折号化或破折号密度失控时，必须回炉重写或人工改写，不能机械删除后宣布完成。

#### 短篇内部连续性硬门

短篇虽然体量小，也必须守住内部连续性：不能只看情绪强度或文风。写每节前检查短篇内部因果、反转铺垫、人物/关系变化、证据物、生活物件和节尾承接。若某节只是在重复上一节情绪，没有新的选择、后果、信息差、关系压力或读者新获知，先回到 `小节大纲.md` 补因果链，不直接写正文。

#### Agent 调用：story-architect

构思阶段，如果项目已部署 story-architect agent（优先检查 `.claude/agents/` 下的 `story-architect.md` 是否存在；不存在时再检查 `.opencode/agents/`，再不存在时检查 `.codex/agents/`），可 spawn `Agent(subagent_type: "story-architect", prompt: "项目目录：{dir}\n任务类型：短篇构思\n查询参数：{情绪目标+题材方向}")` 辅助框架设计。如 agent 不可用，由主线程直接执行。

帮用户确定短篇的核心框架：

```
## 短篇核心框架

### 基本信息
- 标题（暂定）：{}
- 目标字数：{} 字（短篇通常 8000-20000 字）
- 目标平台：{}
- 情绪目标：{读者读完的感受}

### 一句话梗概
{主角 + 困境 + 反转 + 情绪落点}

### 核心反转
- 反转类型：{身份反转/视角反转/动机反转/时间线反转}
- 反转内容：{一句话描述}
- 铺垫线索：{至少 3 个铺垫点}

### 情绪设计
- 开头情绪：{}（强度 {1-10}）
- 中段情绪：{}（强度 {1-10}）
- 反转情绪：{}（强度 {1-10}，峰值维持 ≥2 节）
- 结尾情绪：{}（强度 {1-10}）
- 反转高潮不要骤降：反转前 1 节开始升温，反转节达到峰值，反转后 1 节维持峰值不骤降

### 人设速写
- 主角：{一句话人设}
- 关键角色：{一句话人设}
- 关系：{他们之间的关系}

### 角色锁定卡（写入设定.md，缺失不得写正文）
| 角色名 | 性别/称谓/视角身份 | 年龄/职业 | 与主角关系 | 本篇目标 | 行动边界 | 声口标记 | 证据物/证据事 |
|---|---|---|---|---|---|---|---|
| {角色} | {性别 + “我/她/他/母亲/老板儿子”等称谓边界} | {年龄/职业} | {关系} | {主动想要什么} | {不会做什么} | {说话习惯} | {支撑关系/反转的证据} |

### 主题承诺与防漂移
- 主题承诺：{本篇到底证明什么}
- 禁止漂移：{哪些爽点会把主题带偏，例如嫁豪门/被男人定价/权威替主角讲话}
- 主角关键行动：{高潮前主角必须亲自完成的不可替代动作}
```

框架确定后，完成设计任务，然后在工作目录下创建文件。

#### 设计任务（框架确定后执行）

详细步骤和模板见 `references/writing-workflow.md`。构思时从目标情绪反推剧情，不是从灵感正向构建。按顺序完成：

1. 加载题材风格包 → 读 `references/genre-styles/{题材}.md`（核心 4 题材）+ 通用底座 `references/short-craft.md`，从招式库选 2-3 个核心招式（如追妻的白月光触发链 / 信物翻转 / 火葬场预告），写入 设定.md「题材招式」区，全程照此招式与腔调写
2. 加载 `references/short-logic-gate.md` → 建立角色锁定卡和主题承诺；确认主角性别/称谓/视角身份、关键关系、行动边界和证据物。没有角色锁定卡，不得进入小节大纲和正文。
3. 设计反派（如有）→ 加载 `villain-and-reveal.md`
4. 确定揭露方式 → 同上
5. 加载 `references/human-resonance-gate.md` → 写入主角软肋、关系压力、现实共鸣、生活物件、主动选择、情绪债和文字质感风险。答不出时不得写正文。
6. 编写 小节大纲.md（格式见 writing-workflow.md）：短篇只做轻量蓝图，每节包含结构段/五段功能、人物/关系变化、因果/逻辑链、结尾承接/钩子，不套长篇完整章节蓝图
7. 情节可行性门 + 巧合预算 + 主题防漂移 + 丰满度门 + 人性共鸣门（标准见 `short-logic-gate.md` 与 `human-resonance-gate.md`）：不通过时先改设定/小节大纲，不直接写正文
8. 反转信息差验证（公式见 writing-workflow.md）
9. 伏笔回查清单（标准见 writing-workflow.md）

#### Agent 调用：character-designer

设计任务完成后，如果项目已部署 character-designer agent（优先检查 `.claude/agents/` 下的 `character-designer.md` 是否存在；不存在时再检查 `.opencode/agents/`，再不存在时检查 `.codex/agents/`），可 spawn `Agent(subagent_type: "character-designer", prompt: "项目目录：{dir}\n任务类型：角色设定\n查询参数：{人设速写+关系}")` 辅助角色设定和语言风格档案。如 agent 不可用，由主线程直接执行。

---

### Phase 3：逐场景写作

**项目文件结构**：

```
{短篇标题}/
├── 设定.md              ← Phase 2 产出（含对标摘要）
├── 小节大纲.md          ← Phase 2 产出
├── 正文.md              ← Phase 3 产出
└── 对标/                ← 当前短篇引用视图（可选）
    └── {书名}/
        ├── 拆文报告.md
        ├── 情节节点.md
        └── 写作手法.md
```

**拆文结果自动使用规则**：执行写作前必须按“对标上下文加载”顺序扫描 `{短篇标题}/对标/{书名}/`、项目根 `拆文库/{书名}/`、`{短篇标题}/拆文库/{书名}/`。找到拆文报告时，把“结构/情绪/反转/写作手法”作为技法参考；找到结构化子目录时，按当前小节目标检索最相关模块。

> 术语说明：Phase 3 按「段」划分叙事结构（开头段/铺垫段/升级段/反转段/结尾段），每段包含若干「小节」（数字编号的 beat）。「场景」指写作时的具体画面。

**写前准备**（每个场景写前执行 3 步，是核心方法的落地：锁角色 → 确认情绪目标 → 召回技法模块）：
- **步骤 0：角色/可行性/人性共鸣门**：读取 `设定.md` 的角色锁定卡、主题承诺、人性共鸣锚点和 `小节大纲.md` 中本节因果链。回答：① 本节涉及角色的性别/称谓/视角身份是否明确？② 高价值事件是否有动机、渠道、证据、代价？③ 是否超过巧合预算？④ 是否让外部权威替主角完成主题？⑤ 本节是否有 3-5 个具体子事件、至少 1 个选择和 1 个后果？⑥ 本节是否有关系压力、生活物件、身体反应或情绪债兑现？任一答不出 → 回到设定/大纲修复，不写正文。
- **步骤 1：记忆+召回**：① 本场景目标情绪词？② 借鉴哪个参考文件的哪个技法？③ 具体用在哪个段落？答不出 → 先回读参考再动笔。如有 `对标/` 或 `拆文库/` 结构化产出，按“对标上下文加载”规则检索与当前场景最相关的结构/情绪/反转/写作手法模块作为参考，并写入“拆文召回摘要”
  - **多对标书时**：参 `references/cross-book-recall.md`，副对标/参考对标按阶段预算进入"副对标召回摘要"；正文只传摘要，不传副书文风或原文
- **步骤 2：指令确认**：用一句话概括本场景写作意图（情绪+技法+适配段落），确认后开始写作

**写作指令：按三维度揉进逐场景写作，不照搬大纲腔。每个场景让读者和主角一起经历。三个维度（发生、感知、反应）同时揉进同一段连续正文，不按维度分段，不用"先写发生再补感知"的方式写作。揉进后仍必须按戏剧单元/画面分段：一段承载一个完整动作-信息变化或一条连续推理/氛围/情绪链，不按固定字数强拆。输出前做自然节奏重排：场景/一件事结束才分段；新动作、新线索、新对话、视线切换另起；完整推理、氛围铺陈、情绪变化可保留稍长段。高潮/打脸/反转压短，沉淀/推理/收束允许长一点，爽点 beat 写密、过场 beat 写疏，忌通篇同长度或同一阈值切段（见 short-craft.md「疏密分配」）。短句可以用于压迫、界面信息和反转落点，但同一镜头不要连续铺满短叙述/短 UI/短对话；出现 7 行以上短段密集时，合并部分动作、感知、判断或界面信息，做长短交错。主语节奏：段首或主语重置时可用主角名；同一动作链内优先代词/省略；关键转折再点名强调，避免连续句/段无必要重复主角名。标点节奏：按语气标点谱系执行，避免通篇句号化，也禁止随机堆砌问号/感叹号；质问用问号，爆发处少量感叹；犹豫、未尽、打断或拖长优先用动作停顿、短句、换行处理，正文不使用 `……` / `—` / `--`，少量承担明确语义功能的 `——` 可以保留，密度异常或逐字化必须修订。具体字数表达校验：评价台词、题字、信件、念头或弹幕时，只有统计口径明确、已用脚本逐字核对且故事确有必要，才使用“这五个字 / 短短四字 / 三个字一落 / 八个字砸下去”这类具体字数表达；不能确保字数计算正确时，改成“这句话一落”“这一句落下”“那几个字”“这行字”“话音落下”等非具体数字表达。叙述姿态用第一人称在场（短篇，非长篇深度限知）：受虐段直白宣泄、反击段冷静审判，允许主角主观审判句、火葬场前瞻预告、剧透勾子（见 short-craft.md 第3节 + 题材包）；只删中立无情绪的作者讲解，不删带主角偏色的审判/预告。情绪外化按 short-craft.md 第2节：允许直写情绪成语（心如死灰/眼泪不争气），但后面接一个场景里特有的动作或物件，只删后面没有任何具体动作的情绪总结句（一丝悲伤涌上心头）。情绪宁烈不温，冲突前置、爽点要狠要具体、台词带刺，敢写极端反应不点到为止（心死/余韵等以克制为爽感的桥段走克制路线）。**

#### Agent 调用：narrative-writer

正文写作阶段默认一次只生成一个小节候选稿。每节必须先消费当前 `写作Brief_第N节.md`，写完立即运行机器门和故事价值门；用户采用后由事务生成 `正文/第NNN节.md` 与采用锚点，状态机投影完成后才自动生成下一节 Brief，绝不连写下一节正文。不要要求单次 agent spawn 完成 8000+ 字全文，也不要为了“保持上下文”一次生成 2-3 节。每节采用锚点必须记录已揭示信息、人物状态、未回收钩子、风格锚点和下一节交接；下一节只读取该锚点与上一节不可变正式稿尾部，不得读取累计 `正文.md` 或旧候选稿猜承接。全部计划小节采用后运行 `short-story-assembly-finalize.js`，缺节、失效提交、重复序号或计划外小节均不得合稿。

升级旧短篇时，不得把旧版“机器门通过”自动等同于当前故事质量通过。人工修改稿只能获得禁止静默覆盖的写入保护，不能获得质量降级、免检或默认保留；它与其他小节使用同一套新版故事标准，不通过就进入阻断清单，再由作者决定保留、局部修订或重写。其余旧小节撤销采用状态，从最早未通过节回到小节大纲故事引擎与 Brief 覆盖检查。用户认可不能从模型评分、旧报告或“accepted”字段推断。

旧稿复验发现跨节结构问题时，先输出“保留正文 / 重建小节大纲 / 失效哪些 Brief / 哪些正文待复检”的影响清单。用户确认后，从受影响范围的小节大纲开始；不得一边称旧大纲不合格，一边直接安排 Brief 或正文补写。

当前小节机器门统一运行 `node scripts/short-section-machine-gate.js --project-root <book-root> --workflow-id <workflow_id> --apply --json`。不得在主会话逐个调用检查器、手写 result packet、直接 Edit workflow 状态，或用宿主 TaskCreate/TaskUpdate 再建一套任务。明确的 AI 味、标点、句式、措辞反馈直接修当前节并复跑机器门；只有人物动机、关键因果、反转、结局、节奏规划或小节数量变化才进入完整反馈影响链。

机器门通过后，故事质量门只读取 `stage_execution.stage_context_packet.packet_md`，把角色锁、因果链、标题承诺、主角能动性、人性情感、钩子兑现、故事吸引力、连续性和防漂移九项判断写入 workflow 预建的证据卡；每项必须有 `pass/revise` 和正文证据。随后只运行 workflow 给出的 `short-section-quality-gate.js ... --apply --json`，由脚本推导结论。不得搜索质量门实现、读取完整 workflow/private skill、枚举 scripts、传一个裸 `pass` 或手写 result packet。

进入 `section_repair_loop` 时，只读取当前小节候选稿和当前 Brief 各一次，再 Edit 当前候选稿。若宿主返回 `File has not been read yet`，只补一次目标文件 Read 后重试 Edit；不得因此创建宿主任务、遍历目录、读取检查脚本源码或改用复合 Bash。

`section_repair_loop` 的状态机回执必须同时给出唯一 `repair_target`、只包含该文件的 `write_set` 与 `execution_command=short-section-repair-finalize.js ... --apply --json`。修订完成后只运行该命令，由收束器自动落盘修订回执并启动 `section_machine_gate`；不得直接调用机器门，不得猜测 `advance-stage`、`--js` 等状态机参数。

`draft_first_section / draft_section / draft_next_section` 也必须由状态机给出唯一 `draft_target`、单文件 `write_set` 和 `short-section-draft-finalize.js` 命令。正文写完后运行该命令，由它生成阶段回执并自动启动机器门；主会话不得手写 result packet、连续追加下一节或自行拼装状态机命令。

状态机若已注入 `stage_context_packet`，上述“读取候选稿和 Brief”由该单一文件一次完成，不再分别读取原文件。交互会话内一个小节默认最多：一次上下文包读取、一次候选稿写入、一次机器门、一次质量门；blocking 时只增加一次针对性修订和复检，不开启平台诊断。

`section_plan_lock` 必须先运行 `short-section-title-lock.js` 展示全篇小节标题，用户确认后才写入标题锁；脚本会拒绝缺号、重复序号和重复非空标题。用户选择无标题时，后续统一使用“第 N 节”。`first_section_brief / section_brief / next_section_brief` 只能复用已锁定标题，禁止自行命名或改名；生成文件后统一运行 `short-section-brief-finalize.js`。`section_accept_anchor` 直接运行 `short-section-accept-finalize.js`，由脚本提交不可变小节、生成紧凑锚点，并由状态机推进项目状态；全部小节完成后自动进入确定性合稿，不得生成计划外第 N+1 节。任何脚本返回 blocked 都只处理结构化缺口，不读取脚本源码。

标题确认脚本会直接返回当前小节的最小上下文包、目标写作提要文件和唯一收束命令。确认后不得再调用不存在的 `status`、展开 `inspect`、搜索状态机实现或重新读取全篇文件。作者可见文本统一写“第 N 节写作提要”，禁止使用 `§N Brief`、`Stage`、`Phase` 等内部表达。

当前小节写作提要不是第二份细纲，也不是审查报告。只保留“上节承接、目标与阻力、因果动作、人物/视角锁、禁写项、节尾钩子”六类可执行信息，同一事实只出现一次。`short-section-brief-finalize.js` 会依据目标正文篇幅动态核对提要长度和事件密度；过度规划时只允许精简当前提要一次，不得扩读全篇或另开分析循环。

⚠️ **字数是完成度诊断，不是机械压缩/灌水目标**。
每节应有目标字数和平台底线，但允许合理容忍带：小幅低于目标或略高于目标时，先判断剧情功能、情绪、钩子、人物选择和承接是否完成；已完成则接受并记录 warning，不为了几十字或一两百字反复补水/压缩。只有明显低于硬底线、缺少子事件、缺少选择代价、缺钩子承接或平台最低要求不满足时，才 blocking。
题材例外：爽文、打脸、系统流等高信息密度题材可以更短更密；克制心死、推理沉淀或真相揭示可以略长。不要用固定字数把所有节切成同一种长度。
**字数统计必须优先使用项目脚本**：`node scripts/chapter-text-stats.js 正文.md --json --sections`。不得临时拼接标题、正文结尾或多行脚本做脆弱统计；短篇小节标题可能在文件第一行。若项目缺少该脚本，才回退跨平台字符统计 `for PYBIN in python3 python py; do "$PYBIN" -c "" 2>/dev/null && break; done; "$PYBIN" -c "from pathlib import Path; print(len(Path('文件路径').read_text(encoding='utf-8')))"`。Windows / DeepSeek / Claude Code 组合下不要让模型自行估算字数；`wc -m` 仅作为 macOS/Linux 备选，禁止使用 `wc -c`（字节数）。如果当前 agent/工具环境没有 Node/Bash/Python 权限，必须明确声明“未完成机器字数验证”，并按行数速算作为临时估计，不得声称已通过字数硬验证。
**字数判定必须使用容忍策略**：优先运行 `node scripts/word-count-tolerance.js --actual <当前节中文字数> --target <本节目标字数> --unit section --json`。返回 `under_target_within_tolerance` 或 `over_target_review_pacing` 时不是失败；只在 `under_hard_floor` 或故事质量门判定“缺剧情功能”时修订当前节。
**还要遵守作品内篇幅基准**：第 1 个已采用小节先建立临时基准；累计 3 个普通小节后，改用最近已采用普通小节的滚动中位数，避免某一节偶然过长/过短把全书带偏。篇幅策略由统一机器门内部调用，主会话不得单独运行 `short-section-length-policy.js`。明显偏离时先检查小节功能；过渡、反转、高潮、收束等结构例外由 Brief 声明，并仍须通过机器门和故事质量门。

**节数守恒**：正文节数必须等于小节大纲规划节数。不得合并多节为一节。如果写作中发现某节不需要独立存在，应回到大纲阶段调整，而非在写作时偷减。

**节长验证流程**：
1. **写作时**：按三维度揉进写每个子事件——发生、感知、反应揉进同一段连续正文，不按维度分段写
2. **字数偏短时**（逐节统计后）：先看 `word-count-tolerance.js` 结果。容忍带内且本节功能完整 → 接受；明显偏短或故事功能缺失 → 用以下方法补足（优先级从高到低）：
   - 补充更多子事件（回到小节大纲补充）
   - 加一轮对话（参考 short-craft.md 第6节 / dialogue-mastery.md 对话权力模式）
   - 加回忆闪回（1-2 句关联记忆）
   - 加环境物件（通过动作带出，不独立成句）
   - **禁止凑字**：每个添加必须推动情绪/铺垫/代入感，不得灌水。禁止用"加感知层""加反应层"的方式在已有动作上叠加描写
3. **字数偏长时**：只删重复信息、解释腔、无功能段落；如果长段承载完整推理、氛围或情绪链，不为了压字数机械删改。

**节长验证（逐节写作，每节写完后执行）**：
逐节写作：每次只输出当前 Brief 对应的一个小节，写完立即检查当前节字数、剧情功能、人物选择、因果、爆点和承接。
如果当前节触发 `under_hard_floor` 或故事质量门失败 → 修当前节并重新验收，不生成下一节 Brief。
任何补写、删改或回炉都会使本节旧门禁回执失效：必须重新执行当前节机器门、故事价值门和采用锚点；三者完成后才允许生成下一节 Brief。
如果只是小幅低于/高于目标 → 记录 warning，保留叙事形态，不进入补水/压缩循环。

> 连贯性不靠一次输出多节维持，而靠已采用小节锚点、已写摘要、正文尾部和下一节 Brief 维持。这样用户可以在每节后修正上游规划，又不会让后续正文继续沿旧设定漂移。

> **节长速算**：平均每行 15 字 × 55 行 ≈ 825 字。写到第 30 行时如果还不到 500 字，说明子事件数量不够，需要补充更多子事件或对话。

每个小节按「三维度揉进」写作（详见 short-craft.md 第 10 节）：每个子事件将发生、感知、反应三个维度揉进同一段连续正文，子事件合计 ≥150 字。维度揉进不等于按维度分段——禁止"先写发生再补感知再补反应"的堆叠写法；也不等于一段到底，按新动作/新物件/新信息/新对话断段。长度只是诊断，先判断是否完整戏剧单元；混入多个动作/信息才拆，完整推理、氛围或情绪链可以保留稍长段。

**写完后对照 小节大纲.md 检查**：每个子事件三个维度都揉进了？本节情绪到位？伏笔/物件已植入？节长 <800 字 → 补充更多子事件/对话后再写下一节。

按以下结构分段写：

#### 第一段：开头（前 300-500 字）

**目标**：3 句话内抓住读者。**必须包含一个开篇钩子**（从 hooks-chapter.md 选择类型）。

**技法指令**：前 100 字事件密度 ≥ 3，不做背景铺垫，直接上事件链。

**开头零环境规则**（默认适用；悬疑、惊悚、灾难、强氛围题材可例外）：
- 前 3 句禁止出现无事件承载的环境描写（灯光、天气、气味、温度、装修）
- 前 3 句必须是：事件 / 对话 / 动作 / 信息炸弹，四种之一
- 环境细节只能揉进角色的动作和感知中自然带出，不能独立成句；例外题材中，环境也必须携带威胁、异常或信息差
- 检查方法：标出前 3 句的主语，如果主语是环境物件（灯光/走廊/房间/天气），重写

开头技巧：

| 技巧 | 说明 | 示例 |
|------|------|------|
| 冲突前置 | 第一句就是矛盾 | 「离婚协议放在桌上，他已经签了。」 |
| 信息差钩 | 给读者一个角色不知道的信息 | 「她不知道，对面那个男人已经在计划第三次了。」 |
| 反常行为 | 用一个不合常理的行为引起好奇 | 「她把订婚戒指冲进了马桶。」 |
| 重生反常 | 重生后做前世绝不会做的事 | 「沈栀心念成灰，支着一口气找到了媒婆:郭家的那个天阉，我来嫁。」 |
| 超自然身份 | 开篇揭示非人类身份 | 「我是世上仅存的红衣厉鬼。我不知自己是怎么死的。」 |
| 灵魂旁观 | 以灵魂视角描述死亡现场 | 「我的尸体躺在透明棺材里，三个哥哥在外面笑着说：她演得真像。」 |
| 悬念句 | 抛出一个需要解释的事实 | 「我死后的第三天，老公发了一条朋友圈。」 |
| 替嫁被弃 | 被迫接受不公正的命运 | 「三个月后，我代替皇后的嫡亲公主坐上了去漠北和亲的轿撵。」 |
| 代入式提问 | 直接让读者产生共鸣 | 「你有没有在深夜接到过一个不该接的电话？」 |

#### 第二段：铺垫（占全文 30-40%）

- 用物件/数字/习惯建立羁绊（详见 emotional-methods.md「羁绊铺设」）
- 埋入至少 3 个反转线索，分散在不同小节
- 每 2-3 个小节埋一个钩子（类型从 hooks-paragraph.md 选择）
- 小节用数字分割，每小节推进一个情节点
- 情绪强度逐节递增，不允许连续 2 节无情绪变化
- **贯穿道具第 1 次出现必须在此段完成**
- **反派作恶按阶梯递增**（小恶→中恶，见 villain-and-reveal.md）

#### 第三段：升级（占全文 20-30%）

- 冲突必须比上一段升级（强度/范围/代价至少一个维度上升）
- 插入倒计时钩子或代价钩子制造紧迫感
- 钩子密度提高到每 2 节一个（按题材分级见 genre-writing-formulas.md）
- 埋入误导信息，让读者猜错反转方向
- **数字/金额递增作为叙事工具**（具体数字替代模糊描述，见各 genre-styles 招式库「数字承重」）
- **一动一静交替**：每节有动有静，不连续暴力也不连续安静

#### 第四段：反转（占全文 10-15%）

- 反转在一节内完成揭示，不拖延
- 揭示后确保前面铺垫的线索可被回溯（读者能找到「原来如此」的伏笔）
- 反转节的情绪冲击强度必须 > 前面所有节的最高值
- **用证物/证人/偷听/剥洋葱揭露真相**（4 种方式见 villain-and-reveal.md）
- **贯穿道具第 2 次出现必须在此段完成**（意义被颠覆）

#### 第五段：结尾（占全文 5-10%）

- 章末必须有钩子（悬念或余韵）
- 用安静细节收尾（一个物件、一个动作、一句短话），不写大段抒情
- 结尾方式见下表，参考 emotional-methods.md「余韵钝痛」
- **贯穿道具第 3 次出现（回扣暴击）**

结尾类型：

| 类型 | 效果 | 适合情绪 |
|------|------|----------|
| 余韵式 | 不说完，让读者自己想 | 意难平 |
| 呼应式 | 首尾呼应，形成闭环 | 治愈、成长 |
| 开放式 | 留下悬念 | 细思极恐 |
| 反转再反转 | 结尾再来一个小反转 | 震惊 |
| 金句式 | 一句话点题 | 共鸣 |

---

### Phase 3 完成门槛（进入 Phase 4 前必须通过）

- [ ] 总字数 ≥ 8000（优先用 Python 字符统计验证，兼容 Windows 和中文字符计数）
- [ ] 每节 ≥ 800 字（爽文等高信息密度题材 ≥ 500 字，见 genre-writing-formulas.md）
- [ ] 节数 = 小节大纲规划节数（不得合并/省略）
- [ ] 身体部位同一词全文 ≤ 5 次
- [ ] 「像」≤ 10 处
- [ ] `node scripts/check-ai-patterns.js --check 正文.md` 无高危 AI 对比句式；少量有功能破折号和番茄密集 `「」` 只按 advisory 复核（碎句号/长段落按提示处理）
- [ ] `node scripts/check-degeneration.js --check 正文.md` 无 blocking 退化命中（复读/截断/工程词泄漏）
- [ ] `Human resonance gate` 为 pass：每个关键小节有人物软肋、关系压力、生活物件、主动选择、情绪债或关系后果；不能只是证据链、设定解释或机械打脸。

**中文文本统计注意事项**：
- `wc -c` 统计的是字节数，中文每字符 3 字节（UTF-8），不等于字数
- 字数统计必须优先使用 `node scripts/chapter-text-stats.js 正文.md --json --sections`；项目缺少脚本时再回退跨平台字符统计。
- `wc -m` 仅作为 macOS/Linux 备选；Windows 环境或模型兼容性不确定时不要依赖 `wc`
- 禁止用 `wc -c` 或模型估算字数
- 行数统计使用 `wc -l` 是安全的

**不通过 → 回退补足，不得进入精修。**

---

### Phase 4：精修打磨

加载 `references/writing-workflow.md` 中的精修清单完成检查。
重点：开头钩子、情绪曲线、反转铺垫、每句话价值、格式规范、AI 腔排查。文件模式必须先运行 `node scripts/check-ai-patterns.js --check 正文.md`（报告 AI 对比句式 + 破折号按功能改写 + 碎句号 + 长段落 + 番茄密集 `「」`；高危项复扫到 0，提示项按平台处理），番茄/红果/黑岩短篇再运行 `node scripts/normalize-punctuation.js --quote-mode=mainland 正文.md` 机械兜底标点；盐言或用户明确指定 `「」` 时才保留或使用 `--quote-mode=yan`。另跑 `node scripts/check-degeneration.js --check 正文.md` 报告模型退化（复读/截断/工程词泄漏）；blocking 命中说明该段要重新生成，不是改写。

#### Agent 调用：narrative-writer（去AI味）+ consistency-checker

精修阶段，如果项目已部署对应 agent，可 spawn：
- `Agent(subagent_type: "narrative-writer", prompt: "项目目录：{dir}\n任务描述：去AI味+格式检查\n检查范围：{正文文件}\n删除优先：每条 AI 味项先判能否删除——删后不丢伏笔/钩子/角色/情节/必要信息/必要转折的直接删，会丢才润色（删除受比例上限与字数下限约束，跌破下限改降AI重写）\n必须检查：先否定再肯定的翻转句式；发现后直接改成后项或动作细节")` — 执行去AI味（7 Gate）和格式合规检查
- `Agent(subagent_type: "consistency-checker", prompt: "项目目录：{dir}\n检查范围：{正文文件}\n检查类型：事实冲突+伏笔断线+角色属性不一致")` — 执行一致性检查

如 agent 不可用，由主线程直接执行。

**正文洁净规则**：
- 自检（字数统计、禁用词扫描、格式检查）是过程动作，结果直接在对话里说明，不落盘成文件
- **绝对不能**把自检记录附加到正文文件末尾
- 正文中不得出现任何 `<!-- 自检 -->` 或类似的检查标记注释

不通过 → 回退补足。

---

## 流程衔接

**流水线：** 短篇
**位置：** 写作（第 3/3 步）

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 有参考小说想对标 | story-short-analyze | `/story-short-analyze` → 输出存入 `拆文库/{书名}/` |
| 写完，去 AI 味 | story-deslop | `/story-deslop` |
| 想自检 | 本 skill 质量自检 | 用 Phase 4 自检流程 + `references/quality-checklist.md` 逐项核对 |
| 需要市场方向 | story-short-scan | `/story-short-scan` |
| 设定太大，适合长篇 | story-long-write | `/story-long-write` |

---

## 参考资料

按需加载以下文件。写作时同时加载 ≤ 3 个：

| 文件 | 何时加载 |
|------|----------|
| [references/short-format.md](references/short-format.md) | 写作前必读（短篇正文格式，两平台模板） |
| [references/short-craft.md](references/short-craft.md) | 写作全程参考（短篇通用底座：情绪直接写+后接具体反应、在场叙述、超短章节制） |
| [references/genre-styles/](references/genre-styles/) | **定方向后必读**：按题材加载对应风格包（追妻火葬场 / 复仇打脸 / 总裁豪门 / 宅斗宫斗…），正文风格随之切换 |
| [references/short-deslop.md](references/short-deslop.md) | 去AI味时必读（短篇专属，只杀真·AI腔，不杀情绪烈度） |
| [references/human-resonance-gate.md](references/human-resonance-gate.md) | 设定、小节大纲、正文和回炉前必读：检查人性共鸣、关系压力、生活质感和文字质量 |
| [references/writing-workflow.md](references/writing-workflow.md) | Phase 2 设计任务 + Phase 4 精修 |
| [references/submission-profile.md](references/submission-profile.md) | 锁定目标平台、开篇承诺、阅读停顿与结尾契约 |
| [references/genre-writing-formulas.md](references/genre-writing-formulas.md) | 冷门题材结构骨架补充（核心 10 题材直接用 genre-styles/） |
| [references/genre-writing-techniques.md](references/genre-writing-techniques.md) | 跨题材通用技法（震惊场景/三翻四震/感情线四阶段/喜剧flag） |
| [references/emotional-methods.md](references/emotional-methods.md) | 设计情感时 |
| [references/hooks-chapter.md](references/hooks-chapter.md) | 章节钩子设计 |
| [references/hooks-suspense.md](references/hooks-suspense.md) | 悬念设计 |
| [references/hooks-paragraph.md](references/hooks-paragraph.md) | 段落钩子技巧 |
| [references/villain-and-reveal.md](references/villain-and-reveal.md) | Phase 2 设计反派时 |
| [references/reversal-toolkit.md](references/reversal-toolkit.md) | 设计反转时 |
| [references/quality-checklist.md](references/quality-checklist.md) | 精修检查时 |
| [references/banned-words.md](references/banned-words.md) | 禁用词表 |
| [scripts/normalize-punctuation.js](scripts/normalize-punctuation.js) | Phase 4 文件模式确定性标点收尾 |
| [scripts/check-ai-patterns.js](scripts/check-ai-patterns.js) | Phase 3 完成门槛与 Phase 4 复扫；报告高危 AI 句式 + 破折号/碎句号/长段落 |
| [scripts/check-degeneration.js](scripts/check-degeneration.js) | Phase 3 完成门槛与 Phase 4 复扫；报告模型退化（复读/截断/工程词泄漏），blocking 需重新生成 |
| [references/dialogue-mastery.md](references/dialogue-mastery.md) | 写对话时 |
| [references/output-contract.md](references/output-contract.md) | Phase 2 对标上下文加载时（理解 analyze 产出格式与消费规范） |

### 按主题快速定位（横切主题）

有些主题散在多个文件里。下表给每个主题一个**权威文件**（先读它，通常够用），配套文件只在需要那个角度时再加载。括号是该文件里对应的小节。

| 主题 | 权威文件（先读） | 配套文件（按角度补充） |
|------|-----------------|----------------------|
| 情绪外化（怎么写情绪） | **`references/short-craft.md` 第2节**（情绪直接写+后接具体反应、三段对照、改写四步——替代旧机械替换表） | 各 `genre-styles/` 包的「情绪烈度与模式」 |
| 情绪设计（情感结构） | **`references/emotional-methods.md`**（情感三板斧 + 拉扯节奏 + 失败模式） | `references/genre-writing-techniques.md`（情绪操控核心法则 / 情绪三层次） |
| 反转 | **`references/reversal-toolkit.md`**（反转类型 / 铺垫 / 有效性自检） | `references/villain-and-reveal.md`（真相揭露机制 / 反转有效性自检） |
| 反派揭露 | **`references/villain-and-reveal.md`**（反派模板 / 揭露机制 / 报应设计） | `references/reversal-toolkit.md` |
| 人物 | **各 `genre-styles/{题材}.md` 的「对话风格」「招式库」**（受害者-复仇者主角声线、白月光软刀、施害者道德绑架人设，corpus-grounded） | `references/villain-and-reveal.md`（反派/揭露）· `references/genre-writing-techniques.md`（三层标签反差 / 人设从缺点开始）· `references/dialogue-mastery.md`（声线差异） |
| 钩子 | **`references/hooks-chapter.md`**（章节/开篇钩子类型） | `references/hooks-paragraph.md`（段落钩子）· `references/hooks-suspense.md`（悬念设计） |
| 女频写作 | **对应 `genre-styles/{题材}.md`**（追妻火葬场 / 总裁豪门 / 宅斗宫斗的题材声线、虐爽比例、招式） | `references/genre-writing-techniques.md`（女频读者心理与写作技法 / 感情线四阶段推进法）· `references/emotional-methods.md`（情绪拉扯） |
| 题材风格 | **`references/genre-styles/{题材}.md`**（核心 4 题材的腔调/开篇/钩子/情绪烈度/招式/收尾，corpus-grounded） | `references/genre-writing-formulas.md`（冷门题材结构骨架）· `references/genre-writing-techniques.md`（核心梗 / 卖点 / 通用技法） |
| 开头 | **各 `genre-styles/{题材}.md` 的「开篇范式」**（关系锚 + 全弧剧透导语 + 火葬场预告，真实开篇范例）+ `short-craft.md` 第12节（开头事件密度） | `references/hooks-chapter.md`（开篇钩子类型）· `references/hooks-paragraph.md`（段钩密度） |
| 格式与节奏 | **`references/short-format.md`**（短篇正文格式，两平台模板） | `references/short-craft.md`（情绪直接写+后接具体反应/三维度揉进/疏密）· `references/writing-workflow.md`（设计/精修工作流） |
| 对话 | **`references/dialogue-mastery.md`**（对话技法主文件：差异化/潜台词/对话节奏） | `references/short-craft.md`（三类台词与对话权力博弈）· 各 `genre-styles/` 包的真实金句库 |
| 去AI味 | **`references/short-deslop.md`**（短篇专属：只杀真·AI腔，不杀情绪烈度/审判句/火葬场预告） | `references/banned-words.md`（禁用词扫描）· `scripts/check-ai-patterns.js`（AI句式复扫）· `references/quality-checklist.md`（成稿检查） |

---

## 语言

- 跟随用户的语言回复，用户用什么语言就用什么语言回复
- 中文回复遵循《中文文案排版指北》
