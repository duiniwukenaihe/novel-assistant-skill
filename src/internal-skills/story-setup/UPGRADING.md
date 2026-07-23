# 升级指南

## 升级策略

| 策略 | 适用场景 | 风险 |
|------|----------|------|
| 覆盖部署 | 全新项目或无需保留自定义 | 低 |
| 合并部署 | 有自定义内容需保留 | 中 |
| 手动更新 | 只改特定文件 | 低 |

推荐：运行 `/novel-assistant 准备写书` 重新部署，自动走合并策略。

## 文件分类

### 可安全覆盖

这些文件由 story-setup 管理，不含用户自定义内容：
- `.claude/hooks/` — 所有 hook 脚本与 `lib/` 辅助库
- `.claude/agents/` — 所有 agent 定义
- `.claude/rules/` — 所有 path-scoped 规则
- `.claude/agent-references/novel-assistant/` — Agent 参考资料副本

### 需合并（不覆盖）

这些文件可能含用户自定义内容：
- `CLAUDE.md` — 按 marker/section 合并，用户独有 section 保留
- `.claude/settings.local.json` — hooks 按 command 去重 append，其他配置保留

### 不碰

这些文件完全由用户管理：
- `{书名}/追踪/上下文.md` — 用户写作上下文
- `{书名}/追踪/伏笔.md` — 用户伏笔追踪
- `.active-book` — 用户活跃书目
- 短篇项目的 `追踪/` — setup/hooks 不应为短篇自动创建

## 版本检测

`.story-deployed` 文件记录部署版本：
- 无此文件 → 未部署，需全新安装
- `agents_version: 1` → 旧版，需重新部署以获取新 Agent
- `agents_version: 2` → 旧版，需重新部署以获取 story-explorer agent
- `agents_version: 3` → 旧版，需重新部署以获取 story-explorer agent
- `agents_version: 4` → 旧版，需重新部署以获取 chapter-extractor agent
- `agents_version: 5` → 旧版，需重新部署以统一短篇主会话/子代理正文格式
- `agents_version: 6` → 旧版，需重新部署以获取日更续写与伏笔 hook 修复
- `agents_version: 7` → 旧版，需重新部署以获取 Agent 参考文件路径修复
- `agents_version: 8` → 旧版，需重新部署以获取 hook lib、reference bundle、root-aware hook 与短篇无副作用修复
- `agents_version: 9` → 旧版，需重新部署以获取新版写作 Agent
- `agents_version: 10` → 旧版，需重新部署以获取写正文前细纲守卫 hook、长短交错/疏密写作规则与部署后重启提示
- `agents_version: 11` → 旧版，需重新部署以获取拆文「关键信息与扩写技法」「情绪模块/节奏」产物及日更消费链 + 推理型一致性检查 + 自然分段与主语节奏规则
- `agents_version: 12` → 旧版，需重新部署以获取章节蓝图细纲与语气标点谱系
- `agents_version: 13` → 旧版，需重新部署以获取卷内编号迁移、章节资产索引和发布导出脚本
- `agents_version: 14` → 旧版，需重新部署以获取 AI 句式硬门槛、`check-ai-patterns.js` 复扫链路和 issue #166 修复
- `agents_version: 15` → 旧版，需重新部署以获取 OpenCode / OpenClaw 资产、单入口 commands 和 OpenCode 写正文守卫
- `agents_version: 16` → 旧版，需重新部署以获取用户个人风格学习 agent 与风格画像加载链路
- `agents_version: 17` → 旧版，需重新部署以获取章节定位/张弛参考、`check-degeneration.js` 正文退化检测器和 `check-ai-patterns.js` 新增标点/碎句号检测
- `agents_version: 18` → 当前版本

## 版本变更

### v2

- 4 个创作型 Agent + 1 个研究型 Agent（story-architect, character-designer, narrative-writer, consistency-checker, story-researcher）
- Agent 引用 skill references 写作理论
- Hook 脚本优化（减少 context 输出）
- 4 条 path-scoped 规则

### v3

- 新增 story-explorer 只读查询 Agent（角色/伏笔/设定/进度查询，日更上下文快速加载）
- 6 个 Agent 总计（story-architect, character-designer, narrative-writer, consistency-checker, story-researcher, story-explorer）
- story-explorer 被 story-long-write、story-review、story 路由集成调用

### v4

- 新增 chapter-extractor 章节提取 Agent
- 7 个 Agent 总计（story-architect, character-designer, narrative-writer, consistency-checker, story-researcher, story-explorer, chapter-extractor）

### v5

- 更新 narrative-writer 场景写法：使用”三维度揉进”并按画面分段控制段落密度
- 字数统计改为 `chapter-text-stats.js` 优先，支持正文整章和短篇 `--sections` 小节统计；Python / `wc -m` 仅作脚本缺失时的回退，避免标题 `split`、多行循环和临时内联脚本污染上下文
- 已部署项目重新运行 `/novel-assistant 准备写书` 后获取新版 agent 定义

### v6

- 统一 narrative-writer 子代理与主会话的短篇候选稿格式：暂存后经 chapter-commit 接受为 `正文.md`、小节标记统一、段落无空行、对话半角双引号
- 短篇写作不再由 narrative-writer 创建长篇 `追踪/上下文.md`

### v7

- 修复长篇 `/novel-assistant 日更` 批量续写中的 continuation 规则：同一批次内“继续/续写/日更”保持在 daily workflow，不直接跳到正文续写。
- 修复 `detect-story-gaps.sh` 对伏笔表头和正常开放伏笔（`未埋`/`已埋`）的误报；SessionStart 只提示 `已过期` 或异常状态。
- 已部署项目需重新运行 `/novel-assistant 准备写书`，以覆盖 `.claude/hooks/`、`.claude/agents/`、`.claude/rules/` 并获得新版 hook 行为。

### v8

- 修复 story-review 及部署后的 reviewer Agent 在项目根目录下读取参考文件时，只找裸文件名（如 `quality-checklist.md`）导致找不到 skill references 的问题。
- Agent 模板新增参考文件路径规则：优先从 `.claude/agent-references/novel-assistant/` 读取同名参考资料，避免依赖当前工作目录且不跨 skill 引用 references。旧 `story-setup/references/agent-references/*.md` 仅作为兼容 fallback。
- 已部署项目需重新运行 `/novel-assistant 准备写书`，以覆盖 `.claude/agents/` 并获得新版参考文件路径规则。

### v9

- `setup_skill_version` 升级到 `1.1.0`，`.story-deployed` 的 `agents_version` 升级到 `9`。
- 部署契约补充机械可检查清单：hooks、rules、agents、Agent References、settings hooks、`CLAUDE.md` 合并和 `.story-deployed` 字段都必须明确 source、target、owner、merge mode、validation。
- Hook 部署从“只复制 `.sh` 文件”改为递归复制完整 `references/templates/hooks/` 目录树，避免遗漏 `lib/common.sh`；新增 `lib/sentinel.sh` 统一读取 `.story-deployed` 字段。
- Hook runtime 改为 root-aware：优先使用 `CLAUDE_PROJECT_DIR`，其次 git root，最后 cwd；`discover_active_book` 与 `discover_all_books` 分离，避免单本会话逻辑和全项目巡检互相污染。
- `detect-story-gaps.sh` 使用 bash 3.2 兼容数组/去重逻辑，并从公共库获取所有书目。
- `session-end.sh` 默认不写 `session-log.txt`；显式 `STORY_SESSION_LOG=1` 时也只写已存在的长篇 `追踪/`，不会为短篇创建 `追踪/`。
- `validate-story-commit.sh` 增加脚本内自检：解析 `CLAUDE_TOOL_INPUT.command` / `STORY_COMMIT_COMMAND` 后只对真实 `git commit` 生效，避免 `echo git commit docs` 这类非提交命令误触发。
- Agent Reference bundle 补齐并 canonicalize：
  - `genre-readers.md`：从 `story-long-write/references/genre-readers.md` 复制为 story-setup canonical 副本。
  - `genre-writing-formulas.md`：从 `story-long-write/references/genre-writing-formulas.md` 复制为 story-setup canonical 副本。
  - `emotional-methods.md`：从 `story-long-write/references/emotional-methods.md` 复制为 story-setup canonical 副本。
  - `style-combat-face.md`：从 `story-long-write/references/style-combat-face.md` 复制为 story-setup canonical 副本。
  - `output-templates.md`：不复制；`chapter-extractor` 已内置输出格式，旧的裸引用改写为“遵循本文件输出格式”。
- `story-format.md` 删除“章节之间用 `---` 分隔”的旧规则，改为禁止正文片段使用水平分隔线，与 narrative-writer 保持一致。

### v10

已部署项目请重新运行 `/novel-assistant 准备写书`，刷新写作 Agent；主要影响是日更续写更稳定地沿用对标文风。

### v11

- `setup_skill_version` 升级到 `1.2.0`，`.story-deployed` 的 `agents_version` 升级到 `11`。
- 新增写正文前流程守卫 hook `guard-outline-before-prose.sh`：首次创建长篇 `正文/第N章_*.md` 时若缺同书 `大纲/细纲_第N章*.md`，或首次创建短篇 `正文.md` 时若缺 `小节大纲.md`，会直接阻断（exit 2），强制先搭大纲再写正文。正文已存在、导入迁移或非正文文件放行。
- `settings-hooks.json` 新增 `PreToolUse(Write|Edit|MultiEdit)` 注册。已部署项目必须重跑 `/novel-assistant 准备写书` 才能把该守卫写入 `.claude/settings.local.json`。
- `session-start.sh` 新增 `.claude/.agents-pending-restart` 一次性确认：部署/更新 agents 后，新开会话会提示 custom agent 已重新注册并清除标记；如果仍提示 spawn 失败/降级 solo，说明还在旧会话。
- 部署后必须新开会话：custom agents 只在会话启动时注册成 `subagent_type`。`/novel-assistant 准备写书` 部署完会留下一次性标记 `.claude/.agents-pending-restart`，session-start.sh 在下个会话确认 agents 已注册并清除标记；部署当前会话内 spawn agent 仍可能降级 solo。
- 写作规则补「深度限知视角 + 去解释腔/上帝感 + 情绪烈度 + 长短交错 + 疏密分配 + 主语节奏自然」：`anti-ai-writing.md` 从 7 种 AI 模式扩展为 8 种，新增解释腔/上帝视角/安排感；`writing-craft.md` 新增深度限知和疏密分配；`format-and-structure.md` 不再把 60 字作为一刀切硬规则，改为按戏剧单元、情绪 beat、镜头切换和主语重置自然断段，避免通篇同阈值切段或无必要连续重复主角名。
- story-architect Agent 的长篇卷纲/细纲会输出当前卷目标、本章服务卷目标的方式、必须 beat、禁止事项和允许新增项，便于后续生成 Chapter Contract。
- character-designer Agent 会为核心角色输出 `设定/角色不变量/{角色名}.md` 所需字段，减少 `Motivation_Drift` 与 `Knowledge_Leak`。
- narrative-writer Agent 新增长篇稳定性契约协议：长篇章节 prompt 含章节契约时，必须逐项兑现 Chapter Contract 的必须 beat，不得写入契约禁止事项，并在完成后列出需 State Delta 记录项。
- consistency-checker Agent 新增长篇稳定性只读检查：支持 `Plot_Drift`、`Beat_Missing`、`Beat_Compressed`、`Motivation_Drift`、`Knowledge_Leak`、`Foreshadow_Early_Payoff`、`Untracked_Addition`、`State_Not_Updated` 等错误码。
- story-explorer Agent 的 `context_load` 会返回章节契约、Chapter Handoff Pack、角色不变量、当前卷纲和最近 State Delta，供日更续写一次性加载稳定性上下文；相邻章节写完后可用 Cross Chapter Continuity Audit 检查交接包是否被下一章继承，批量结束后可用 Longform Daily Stability Audit 做总审计。
- agent-reference bundle 新增 `chapter-index.md`、`chapter-contract.md`、`plot-drift-control.md`、`state-delta-ledger.md`、`character-invariants.md`、`revision-impact-analysis.md`、`chapter-handoff-pack.md`、`cross-chapter-continuity-audit.md`、`longform-daily-stability-audit.md`、`stability-repair-dispatcher.md`、`stability-repair-loop.md`、`stability-agent-dispatch-prompts.md` 和 `error-codes.md`，保证部署后的 agents 可从 `novel-assistant/references/agent-references/` 读取长篇稳定性规则。
- 已部署项目需重新运行 `/novel-assistant 准备写书`，以覆盖 `.claude/hooks/`、`.claude/agents/`、`.claude/rules/`、`.claude/agent-references/novel-assistant/` 并获得稳定性 aware 的写作、查询与一致性检查 Agent；部署后请新开 Claude Code 会话。

### v12

- `setup_skill_version` 升级到 `1.2.1`，`.story-deployed` 的 `agents_version` 升级到 `12`。
- **拆文→写作模块链（issue #149）**：`story-long-analyze` Stage 2 摘要新增「关键信息与扩写技法」表，Stage 3 产出权威产物 `剧情/节奏.md`（关键信息推进 / 情绪触动点 / 爆发节奏）与 `剧情/情绪模块.md`（读者需求·情绪引擎 / 可复现模块）；`story-import` 同步到 `对标/{书名}/剧情/`；`story-long-write` 日更按权威优先级读取并复现。
- **agent 模板更新**：`chapter-extractor` 增加「关键信息与扩写技法」提取，`story-explorer` 的 `benchmark_style_load` 增加 `selected_emotion_module`/`rhythm_reference` 等返回字段。**已部署项目须重新运行 `/novel-assistant 准备写书` 才能拿到新 agent 行为**；否则日更回退到主会话手动加载（功能不丢，仅失去 agent 快捷路径）。
- `consistency-checker` 从纯 grep-first 字面矛盾扩展为「grep-first + 推理型一致性审查」：补查规则边界悖论、设定层级冲突、跨章因果链、规则可滥用漏洞、代价一致性。
- **自然分段 + 主语节奏**：`format-and-structure.md` 与 `writing-craft.md` 不再把 `60/45` 字数当成硬切分规则，改为按戏剧单元/镜头/一件事结束分段；完整推理链、氛围铺陈、情绪变化可保留稍长段。
- **主语过密修复**：narrative-writer 模板和 story-review 检查项新增“段首点名建立主语、段中代词/省略、关键转折再点名”的节奏规则，不按全章名字次数一刀切。
- 已部署项目重新运行 `/novel-assistant 准备写书` 刷新 agents/references；**部署后新开会话**。

### v13

- `setup_skill_version` 升级到 `1.2.2`，`.story-deployed` 的 `agents_version` 升级到 `13`。
- **细纲升级为章节蓝图（issues #162）**：新建/补建长篇 `大纲/细纲_第XXX章.md` 时，除旧字段外新增内容概括（起因/发展/转折/高潮/结尾）、情节安排（主线/辅线/事件线/感情线/逻辑线）、人物关系和出场顺序、情节细化、结尾设定和钩子；旧版细纲仍可续写，缺失字段不阻塞，回填未知项写 `[待补充]`。
- **语气标点谱系（issue #161）**：writer references、narrative-writer、review/deslop 增加“标点跟着语气/人物声线走”的规则，避免通篇句号化，也禁止随机堆砌问号/感叹号；犹豫/未尽/打断/拖长改用动作停顿、短句或换行处理，正文产物不用 `……`、不用 `——`，知乎盐言 `「」` 引号风格继续有效。
- `story-architect` 会产出新版章节蓝图；`consistency-checker` 会消费细纲里的逻辑线、人物关系变化、出场顺序和代价/收益兑现；`narrative-writer` 会按语气标点谱系执行正文标点节奏。
- 已部署项目请重新运行 `/novel-assistant 准备写书` 刷新 hooks/agents/references；**部署后新开会话**，否则旧会话仍使用 v12 agent 定义。

### v14

- `setup_skill_version` 升级到 `1.3.0`，`.story-deployed` 的 `agents_version` 升级到 `14`。
- **长篇目录迁移**：已部署项目重新运行 `/novel-assistant 准备写书` 后，会用 `story-project-migrate.js` 把旧扁平路径迁到卷内编号结构：
  - `大纲/细纲_第001章.md` → `大纲/第1卷/细纲_第001章.md`
  - `大纲/卷纲_第1卷.md` / `大纲/卷纲_第一卷.md` → `大纲/第1卷/卷纲.md`
  - `正文/第001章_章名.md` → `正文/第1卷/第001章_章名.md`
  - `追踪/章节契约/第001章.md` → `追踪/章节契约/第1卷/第001章.md`
  - `追踪/交接包/第001章_to_第002章.md` → `追踪/交接包/第1卷/第001章_to_第002章.md`
- **无损升级**：迁移前自动生成 `追踪/版本/{timestamp}_layout-migration/manifest.json`，旧扁平文件备份到 `legacy-flat-layout/`。目标路径已存在时不覆盖，记录 conflict/warn，由用户确认后处理。
- **章节资产与发布导出**：setup 迁移后刷新 `追踪/章节资产.jsonl` 和 `追踪/schema/`；发布时使用 `publish-export.js` 输出 `导出/发布版/第001章_原章名.md`，正文目录保持卷内编号。
- 已部署项目请重新运行 `/novel-assistant 准备写书`，迁移完成后再新开 Claude Code 会话。

### v15

- `setup_skill_version` 升级到 `1.3.1`，`.story-deployed` 的 `agents_version` 升级到 `15`。
- **AI 句式硬门槛（issue #166）**：`narrative-writer`、长篇/短篇写作、去 AI 味和审稿流程都把“先否定再肯定 / 否定铺垫后肯定翻转”的句式列为硬禁令；文风召回、对标模仿和 Gate B 软规则都不能覆盖这条禁令。
- **detector 复扫链路**：setup 会把 `check-ai-patterns.js` 部署到项目 `scripts/`；文件模式在预检或交付前执行 `node scripts/check-ai-patterns.js --check <正文文件...>`。命中时回到正文改写，直到复扫到 0。
- **低误伤规则**：detector 不把 `是不是`、`只是/可是/于是/倒是` 等连词里的“是”当成肯定翻转，避免 issue #166 里的假阳性。
- 已部署项目请重新运行 `/novel-assistant 准备写书` 刷新 hooks/agents/references/scripts；**部署后新开会话**，否则旧会话仍使用 v14 agent 定义，无法获得 AI 句式硬门槛和脚本复扫要求。

### v16

- `setup_skill_version` 升级到 `1.4.0`，`.story-deployed` 的 `agents_version` 升级到 `16`。
- **OpenCode CLI 支持（吸收上游 `ea2a9bc`）**：setup 可在检测到 `opencode.json` / `.opencode/` 或用户选择时部署 `AGENTS.md`、`.opencode/agents/`、`.opencode/commands/`、`.opencode/plugins/story-hooks.ts` 和 `opencode.json` plugin 配置。
- **单入口 novel-assistant 改造**：OpenCode commands 保留兼容 alias，但全部导向 `/novel-assistant`，不要求用户记 `/story-long-write` 等内部子 skill。
- **卷内编号正文守卫**：OpenCode plugin 的写正文前守卫兼容 `正文/第1卷/第001章_章名.md` 与旧扁平 `正文/第001章.md`，缺对应细纲时阻断创建正文。
- **Agent reference 主路径迁移**：新部署项目统一把参考资料部署到 `.claude/agent-references/novel-assistant/` 和 `.opencode/skills/novel-assistant/references/agent-references/`；旧 `story-setup/references/agent-references/` 仅作为兼容 fallback，避免单入口项目继续暴露旧 skill 名。
- **正文写后质量门禁**：`ai-trace-detector.sh` 支持从 Claude Hook JSON 自动解析目标文件，避免 PostToolUse 只输出 usage；新增 `prose-quality-gate.sh`，Write/Edit/MultiEdit 正文后运行 `story-prose-gate.js`，逐字破折号化、破折号密度失控、非标准破折号/省略号残留或旧稿污染会阻断继续汇报完成。
- 已部署项目请重新运行 `/novel-assistant 准备写书` 刷新 hooks/agents/references/scripts/OpenCode 资产；如使用 OpenCode / OpenClaw，请重新打开会话让 agents 和 commands 生效。

### v17

- `setup_skill_version` 升级到 `1.4.1`，`.story-deployed` 的 `agents_version` 升级到 `17`。
- **用户个人风格学习**：新增 `style-learner` agent（8 个 Agent 总计：story-architect, character-designer, narrative-writer, consistency-checker, story-researcher, story-explorer, chapter-extractor, style-learner）。它只更新 `设定/作者风格/`、`追踪/schema/user-style-rules.jsonl` 和 `追踪/风格决策日志.md`，不直接改正文、不改大纲、不改细纲。
- **Agent reference bundle 新增 `user-style-learning.md`**：写清硬约束/软偏好/单书设定/角色口吻/禁用表达的结构化 schema，部署到 `.claude/agent-references/novel-assistant/` 和 OpenCode 对应路径。
- **写前用户风格画像加载**：`story-long-write` 与 `workflow-daily.md` 会在 narrative-writer 前读取 `设定/作者风格/我的写作偏好.md`、`正文风格画像.md`、`禁用表达.md`、`修改偏好案例.md` 和 `追踪/schema/user-style-rules.jsonl`，压缩为 `user_style_constraints`。
- **narrative-writer 边界更新**：用户硬约束优先于对标文风和模型默认写法，但不得突破正文门禁、AI味门禁、Chapter Contract、平台/安全约束和字数下限；用户软偏好只调节节奏、句法、口吻和禁用表达。
- 已部署项目请重新运行 `/novel-assistant 准备写书` 刷新 hooks/agents/references/scripts/OpenCode 资产；部署后新开会话，让 `style-learner` 注册为可用 custom agent。

### v18 (当前)

- `setup_skill_version` 升级到 `1.4.5`，`.story-deployed` 的 `agents_version` 保持 `18`。本版新增 workflow 确定性恢复、状态不变量、范围审阅批次和旧项目记忆迁移运行时脚本。
- **正文退化检测器**：新增 `check-degeneration.js`，用于正文/章节级检测逐字复读、截断、占位拒绝语、工程词泄露（如“细纲/情节点/下一章/任务描述”）。它不改写正文，只报告证据；命中 blocking 后必须重写受影响段落或章节。
- **AI 句式检测增强**：`check-ai-patterns.js` 新增碎句号、长段落和破折号按功能改写检测，并支持 `--fail-on=blocking|all`。破折号是 blocking；碎句号/长段落是 advisory，用于区分必须修复与节奏提示。
- **章节定位与张弛**：agent reference bundle 新增 `outline-structure-theory.md`；story-architect 生成卷纲/细纲时必须使用“对标节奏迁移”和“章节定位与张弛”，避免把关系章、低压章、信息整理章都写成强钩子短篇。
- 已部署项目需重新运行 `/novel-assistant 准备写书`，以刷新 `.claude/agent-references/novel-assistant/`、运行时脚本和 session-start 版本提示。

### v18 skill-level hardening（无需单独 bump agents_version）

- **上游 issue 反哺边界**：workflow 契约新增 `single_writer_merge` 和 `blocked_parallel_write_conflict`，多 agent 只能写独立中间产物，生产文件由主流程或指定 merge step 单写入合并。
- **provider/model profile 边界**：skill 不管理 API key、base URL、provider 登录态或计费配置；Claude Code / Codex / OpenCode 或前端 runner 负责模型与供应商配置。workflow 只记录宿主模型能力画像，用于任务分批、模型等级选择、失败恢复和成本治理。
- **流程候选语义**：`只执行本项 / 继续后续阶段 / 完成整个流程` 必须显式写清完成后还剩哪些阶段，并把 `remaining_stages` 写入 workflow 状态，避免用户误以为选了单项后全流程已完成。
- 这些改动属于 skill/workflow 文档和 bundle 内部契约；如果项目 `.story-deployed` 已是 agents v18，通常不需要因本条单独迁移正文、大纲、细纲或书目结构。只有安装包更新后检测到 setup 资产实际变化时，才提示 `/novel-assistant 更新写作协作环境`。
