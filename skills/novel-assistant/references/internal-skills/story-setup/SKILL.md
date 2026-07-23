---
name: story-setup
version: 1.4.5
description: |
  网文写作工具集基础设施部署。将 hooks/rules/agents/CLAUDE.md 等基础设施部署到用户项目目录。
  触发方式：/story-setup、「准备写书」「帮我搭一下环境」「配置写作项目」
metadata:
  openclaw:
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# story-setup：网文写作工具集基础设施部署

## L3 Workflow Contract

### Inputs From story-workflow

只接受 `workflow_type=project_setup | setup_update` 的阶段包，读取项目根目录、版本差异、迁移预览、确认边界、`workflow_id` 和结果包路径。不得把 setup 当成开书创作，也不得自动消费旧业务任务。

### Outputs To story-workflow

每阶段回传标准 result packet，列出同步、保留、冲突、迁移和验证结果。更新完成后停在任务收件箱，不凭聊天生成章节候选。

### Memory Policy

`project_setup` 与 `setup_update` 的小说记忆策略为 `none`。它们只初始化或迁移 Workflow/Memory 基础设施，不注入人物、剧情、伏笔和作者风格内容；迁移出的旧任务与记忆由后续业务 workflow 单独确认。

你是写作基础设施部署器。将网文写作工具集的全套基础设施（hooks、rules、agents、CLAUDE.md）部署到用户项目目录。

**执行铁律：不覆盖用户已有配置，合并而非替换。**

**对外回复铁律：不要暴露“确认路由 / 调用子 skill / dry-run / TaskCreate / 建任务列表”等内部调度话术。setup 已被触发时，直接检查、部署、迁移并汇报结果。**

共享契约：本模块遵守 `story-workflow/references/workflow-contract.md`。setup 负责协作环境部署、刷新和迁移门禁；不会替代写作、审阅、拆文或去 AI 味模块。

## CLI 授权最小化协议

用户确认“更新写作协作环境 / 同步运行时 / 刷新 setup”后，CLI 场景优先使用单一确定性入口：

```bash
node scripts/novel-assistant-sync-runtime.js --project-root . --dry-run --json
```

已部署项目必须逐字使用上面的无占位符命令；脚本会从 Claude Code、Codex、ZCode 的本地安装目录中选择最新 `novel-assistant` bundle。禁止把尖括号占位符原样发送给 shell。确认预览无冲突后只去掉 `--dry-run`。

该命令一次性预览 hooks / agents / rules / scripts / references / 写入策略 / `.story-deployed`，并创建 `.claude/.agents-pending-restart`。确认预览无冲突后，去掉 `--dry-run` 执行；若返回 `confirmation_required`，先展示冲突路径，再由用户明确确认后追加 `--confirm-conflicts`。不得把同一动作拆成多条 `cp` / `rsync` / `mkdir` / `chmod` / `cat` / heredoc 命令让用户反复授权；只有脚本缺失或返回结构化错误时，才进入下方手工部署步骤。

运行时文件的所有权记录在 `.story-runtime-managed.json`：仅清单已托管且内容未被用户改动的文件可更新；刷新前会为已托管的变更写入 `追踪/runtime-snapshots/<timestamp>/manifest.json`。该命令不移动正文、大纲、细纲、设定或追踪创作资产；目录迁移仍按 Phase 2.6 另行确认。

---

## Phase 1：检测项目状态

1. 检查当前目录是否已部署过（存在 `.story-deployed`）
   - 如果已存在 → 使用普通文本确认是否重新部署；不得调用外部确认工具
2. 检查是否有书名目录（包含 `追踪/` 子目录的目录，或用户自定义结构）
   - 有 → 识别为长篇项目，显示当前项目信息
   - 无 → 识别为新项目或短篇项目
3. 检查 `.claude/settings.local.json` 是否存在
   - 存在 → 读取现有配置，后续合并
   - 不存在 → 后续创建新文件
4. 检查 `.active-book` 文件是否存在
   - 存在 → 显示当前活跃书目
   - 不存在 → 跳过
5. 检查 `opencode.json` 或 `.opencode/` 是否存在
   - 存在 → 识别为 OpenCode 项目，`target_cli` 至少包含 `opencode`
   - 不存在 → 默认 `target_cli=claude-code`
6. 如 `.claude/` / `CLAUDE.md` 与 OpenCode 标记同时存在，询问用户部署目标：仅 Claude Code / 仅 OpenCode / 两者都部署。
   - 两者都部署时写入 `target_cli: claude-code,opencode`
   - 不得因此改变对外入口；Claude Code、Codex、OpenCode 都统一提示 `/novel-assistant`

## Phase 2：部署基础设施

使用普通文本确认部署位置后，依次执行；确认问题只用普通文本列出选项，不调用外部交互工具。

### 2.0 部署清单（机械可检查）

| Source path | Target path | Owner class | Merge mode | Validation check |
|-------------|-------------|-------------|------------|------------------|
| `skills/story-setup/references/templates/CLAUDE.md.tmpl` | `CLAUDE.md` | user+managed | marker/section merge | contains story skill routing sections |
| `skills/story-setup/references/templates/hooks/` | `.claude/hooks/` | story-setup managed | managed manifest per file | `session-*.sh`, `detect-story-gaps.sh`, `validate-story-commit.sh`, `safe-bash-guard.js`, `canonical-write-guard.js`, `guard-outline-before-prose.sh`, `prose-quality-gate.sh`, `lib/common.sh`, `lib/sentinel.sh` exist |
| `skills/story-deslop/scripts/ai-trace-detector.sh` | `.claude/hooks/ai-trace-detector.sh` | story-deslop managed | copy | detector script + `ai-trace-patterns.json` deployed together |
| `skills/story-setup/references/templates/rules/*.md` | `.claude/rules/*.md` | story-setup managed | managed manifest per file | every rule contains `paths` frontmatter |
| `skills/story-setup/references/templates/agents/*.md` | `.claude/agents/*.md` | story-setup managed | managed manifest per file | 8 agent files exist, including `style-learner.md` |
| `skills/story-setup/references/agent-references/*.md` | `.claude/agent-references/novel-assistant/*.md` | story-setup managed | managed manifest per file | every `novel-assistant/references/agent-references/*.md` reference resolves; legacy `story-setup` fallback may also exist |
| `scripts/normalize-punctuation.js`, `scripts/check-ai-patterns.js`, `scripts/check-degeneration.js`, `scripts/author-voice-profile.js`, `scripts/chapter-text-stats.js`, `scripts/chapter-volume-count.js`, `scripts/story-domain-profile.js`, `scripts/novel-assistant-project-smoke.js`, `scripts/production-smoke-matrix.js`, `scripts/output-pollution-check.js`, `scripts/runtime-guard-validate.js`, `scripts/token-cost-ledger.js`, `scripts/workflow-entry-guard.js`, `scripts/workflow-runtime-supervisor.js`, `scripts/workflow-state-machine.js`, `scripts/context-assembler.js`, `scripts/memory-recommender.js`, `scripts/safe-text-search.js`, `scripts/write-failure-triage.js`, `scripts/review-state-ledger.js`, `scripts/novel-assistant-sync-runtime.js` and longform runtime scripts | `scripts/` | story-setup managed | managed manifest per file | `normalize-punctuation.js`, `check-ai-patterns.js`, `check-degeneration.js`, `author-voice-profile.js`, `chapter-text-stats.js`, `chapter-volume-count.js`, `story-domain-profile.js`, `novel-assistant-project-smoke.js`, `production-smoke-matrix.js`, `output-pollution-check.js`, `runtime-guard-validate.js`, `token-cost-ledger.js`, `workflow-entry-guard.js`, `workflow-runtime-supervisor.js`, `workflow-state-machine.js`, `context-assembler.js`, `memory-recommender.js`, `safe-text-search.js`, `write-failure-triage.js`, `review-state-ledger.js`, `novel-assistant-sync-runtime.js`, stability scripts, schema scripts exist and are executable |
| `skills/story-setup/references/templates/settings-hooks.json` | `.claude/settings.local.json` | user+managed | merge by hook command | hook JSON valid and registered commands deduped |
| generated `write-policy.json` | `追踪/story-system/write-policy.json` | story-system managed | create only | 新项目为 `strict`；已有项目为 `legacy`；已有策略绝不覆盖 |
| `skills/story-setup/references/templates/上下文.md.tmpl` | `{书名}/追踪/上下文.md` | user state | create only if absent | never overwrite existing writing context |
| `skills/story-setup/references/opencode/AGENTS.md.tmpl` | `AGENTS.md` | user+managed | marker/section merge | contains single-entry `novel-assistant` routing | target_cli 含 opencode |
| `skills/story-setup/references/opencode/agents/` | `.opencode/agents/` | story-setup managed | replace | 8 agent files exist, including `style-learner.md` | target_cli 含 opencode |
| `skills/story-setup/references/opencode/commands/` | `.opencode/commands/` | story-setup managed | replace | `novel-assistant.md` exists; compatibility commands point to novel-assistant | target_cli 含 opencode |
| `skills/story-setup/references/opencode/plugin.ts` | `.opencode/plugins/story-hooks.ts` | story-setup managed | replace | TypeScript plugin file exists | target_cli 含 opencode |
| `skills/story-setup/references/opencode/opencode.json.patch` | merge into `opencode.json` | user+managed | merge by plugin key | story-hooks plugin registered | target_cli 含 opencode |
| `skills/story-setup/references/opencode/pre-commit.sh` | `.git/hooks/pre-commit` | user+managed | marker block merge | executable when platform supports chmod | target_cli 含 opencode |
| generated sentinel | `.story-deployed` | story-setup managed | replace | contains `agents_version`, `setup_skill_version`, `target_cli`, `resolver_strategy`, `references_dir` |

### 2.1 部署 CLAUDE.md

- 读取 `skills/story-setup/references/templates/CLAUDE.md.tmpl`
- 替换占位符（见下方「模板占位符」段）
- 写入项目根目录 `CLAUDE.md`（如已存在，按「CLAUDE.md 合并策略」处理）

### 2.2 部署 Hooks

- 按 `.story-runtime-managed.json` 逐文件同步 `skills/story-setup/references/templates/hooks/` 到用户项目 `.claude/hooks/`；绝不递归删除目标目录，未托管文件保持原样。
- 必须保留子目录 `lib/`，其中：
  - `lib/common.sh` 提供 `project_root`、`discover_active_book`、`discover_all_books`
  - `lib/sentinel.sh` 提供 `.story-deployed` 字段读取
- 只需对 `.claude/hooks/*.sh` 设置执行权限（`chmod +x`）；`lib/*.sh` 由 hook `source`，不要求可执行位
- ai-trace-detector.sh → .claude/hooks/ai-trace-detector.sh (story-deslop managed, merge mode=copy)
- guard-outline-before-prose.sh → .claude/hooks/guard-outline-before-prose.sh，用于在首次创建正文前检查长篇细纲或短篇小节大纲是否已存在
- prose-quality-gate.sh → .claude/hooks/prose-quality-gate.sh，用于在 Write/Edit/MultiEdit 后只对正文成稿文件运行 `story-prose-gate.js`，命中逐字破折号化、破折号密度失控、非标准破折号/省略号残留、正文工程词泄露或旧稿污染时阻断继续汇报完成；审查报告、workflow 断点、下一步候选不走正文门禁
- canonical-write-guard.js → .claude/hooks/canonical-write-guard.js，在 `Write|Edit|MultiEdit` 前检查正式资产写入策略；严格模式下正文、大纲和指定追踪资产必须带事务上下文，缺文件路径只输出 warning 并放行，审查报告等非 canonical 目标不阻断
- safe-bash-guard.js → .claude/hooks/safe-bash-guard.js，在 `Bash` 权限弹窗前把批量章节循环、`cd + grep`、管道/重定向、命令替换和直接复制 workflow 状态改写为确定性脚本；已验证的只读脚本明确 `allow`，未知普通命令仍交给宿主权限策略

### 2.2.1 正式资产事务接受与策略初始化

- 新建项目在 `追踪/story-system/write-policy.json` 创建 `{"schemaVersion":"1.0.0","mode":"strict"}`；正式资产不得直接写入，候选稿先进入事务暂存区，再由 `chapter-commit.js accept` 原子接受。
- 刷新已有项目时，若策略不存在只创建 `legacy`；若策略已存在，原样保留。刷新不迁移、不覆盖正文，也不得把旧项目强制切换为严格模式；只有用户明确确认迁移后才能改为 `strict`。
- `canonical-write-guard.js` 必须唯一、无条件登记到 `settings-hooks.json` 的 `PreToolUse` `Write|Edit|MultiEdit`，并调用项目部署后的 `scripts/lib/canonical-write-policy.js`。仅目标路径缺失输出结构化 warning 并 exit 0；legacy 项目守卫运行时缺失保持 warning 兼容，已知 strict 项目运行时缺失或加载失败必须 fail-closed。有效严格 canonical 目标须携带存在、`prepared` 且包含目标的 chapter-commit 事务，否则阻断。
- `safe-bash-guard.js` 必须登记到 `PreToolUse(Bash)`。它只自动放行白名单内、无 shell 元字符的确定性只读脚本；命中复合审阅命令时返回 `review-batch-evidence-scan.js`，命中文本检索时返回 `safe-text-search.js`，命中 workflow 直接复制/改写时返回 `workflow-state-machine.js`。阻断后必须继续原任务，不得把脚本治理转嫁成用户授权或暂停。

### 2.3 部署 Rules

- 读取 `skills/story-setup/references/templates/rules/` 下所有 `.md` 文件
- 按托管清单逐文件同步到用户项目 `.claude/rules/`；同名非托管文件或用户改动过的托管文件必须先预览冲突并取得明确确认。

### 2.4 部署 Agents

- 读取 `skills/story-setup/references/templates/agents/` 下所有 `.md` 文件
- 按托管清单逐文件同步到用户项目 `.claude/agents/` 目录
- Agent 文件只有在前次托管版本未被用户改动时才可更新；版本升级遇到同名冲突必须先预览并取得明确确认

### 2.4.1 Agent 兼容性处理

- Agent frontmatter 以 Claude Code 为主；OpenClaw/qclaw 等只要支持 AgentSkills，未知字段（如 `memory`、`skills`、`disallowedTools`）应被忽略。若目标工具报 frontmatter 错误，保留 `name`、`description`、`tools` 三项，删除不支持字段后再部署。
- 部署到项目后，agent 内引用的参考资料必须优先从 `.claude/agent-references/novel-assistant/*.md` 读取；不要把完整 skill 包复制到项目本地 skill 目录，否则 Claude Code 会把全局与项目本地同名 skill 同时展示成两个 `/novel-assistant`。旧项目若只存在 `story-setup/references/agent-references/*.md`，可作为兼容 fallback 读取，但新部署与新模板不得再以它作为主路径。

### 2.4.2 部署 Agent References

- 将源码包 `skills/story-setup/references/agent-references/` 下所有 `.md` 复制到项目内 `.claude/agent-references/novel-assistant/`
- 如目标项目已经使用项目本地 `skills/` 目录，也可以同步复制到 `skills/novel-assistant/references/agent-references/` 作为非 Claude 扫描路径 fallback，但不得在 Claude 会扫描的项目本地 skill 目录下创建 `novel-assistant` 或 `story-setup`
- 为兼容 v16 之前已部署项目，可同时复制到 `.claude/agent-references/legacy-story-setup/`；该路径只用于旧 agent fallback，不得写入新 agent 主引用。
- 校验：凡 agent 或 reference 中出现 `novel-assistant/references/agent-references/<file>.md`，源包与目标包都必须存在 `<file>.md`

### 2.4.3 部署运行时脚本

- 创建用户项目 `scripts/` 目录。
- 从 skill 包顶层 `scripts/` 复制以下运行时脚本到用户项目 `scripts/`，并设置可执行权限：
  - `normalize-punctuation.js`
  - `check-ai-patterns.js`
  - `check-degeneration.js`
  - `author-voice-profile.js`
  - `chapter-text-stats.js`
  - `story-domain-profile.js`
  - `novel-assistant-project-smoke.js`
  - `output-pollution-check.js`
  - `runtime-guard-validate.js`
  - `token-cost-ledger.js`
  - `workflow-entry-guard.js`
  - `workflow-runtime-supervisor.js`
  - `workflow-state-machine.js`
  - `workflow-state-validate.js`
  - `workflow-recover.js`
  - `workflow-review-batches.js`
  - `context-assembler.js`
  - `memory-recommender.js`
  - `memory-migrate.js`
  - `chapter-commit.js`
  - `write-failure-triage.js`
  - `story-prose-gate.js`
  - `chapter-assets-build.js`
  - `chapter-handoff-pack.sh`
  - `cross-volume-handoff-pack.sh`
  - `chapter-index-build.sh`
  - `chapter-stability-check.sh`
  - `cross-chapter-continuity-audit.sh`
  - `cross-volume-continuity-audit.sh`
  - `longform-daily-stability-audit.sh`
  - `long-analyze-plan.js`
  - `stage2-summary-quality-check.js`
  - `stage2-grounding-check.js`
  - `revision-impact-scan.sh`
  - `revision-stability-recheck.sh`
  - `stability-agent-dispatch-prompt.sh`
  - `stability-repair-dispatch.sh`
  - `stability-repair-loop.sh`
  - `story-project-migrate.js`
  - `story-schema-build.js`
  - `story-schema-validate.js`
  - `story-version-snapshot.js`
  - `current-contract-build.js`
  - `context-pack-build.js`
  - `publish-export.js`
  - `oh-story-doctor.js`
  - `novel-assistant-update-check.js`
  - `novel-assistant-sync-runtime.js`
  - `lib/oh-story-artifacts.js` 以及 `scripts/lib/` 下依赖文件
- `chapter-commit.js` 是章节生产事务入口：先校验暂存稿和门禁，再用书目级写入租约原子接受正文与追踪投影；冲突或中途失败必须回滚，`inspect/replay` 用于检查提交和修复记忆投影债务。`memory-migrate.js` 支持 `--source` 增量投影，避免每写一章后全量重建记忆。
- `normalize-punctuation.js` 是正文标点收尾脚本；`check-ai-patterns.js` 是 AI 句式/碎句号/长段落/破折号功能检测脚本，不自动改写，blocking 命中必须改文并复扫到 0；`check-degeneration.js` 是正文退化检测脚本，报告逐字复读、截断、占位拒绝语和工程词泄露，命中 blocking 时必须重写受影响单元；`author-voice-profile.js` 是作者声音画像脚本，从用户确认的优秀样本中提取句长、段落形态、标点习惯和对话比例，写作/去 AI 味时用作“像我自己”的风格锚点，不改正文；`chapter-text-stats.js` 是正文/短篇小节字数、行数、破折号和省略号的确定性统计脚本，用来替代脆弱的标题 `split`、临时 Node/Python 片段和 `wc -c`；`story-domain-profile.js` 是题材档案脚本，从 `.book-state.json`、设定、大纲、正文证据识别当前项目的成长轴用语，非修真项目不得默认显示“修真进度一致性”或创建 `力量体系.md`；`novel-assistant-project-smoke.js` 是只读项目冒烟检查脚本，聚合题材档案、当前进度和正文门禁抽样，用于更新 skill 或协作环境后快速验证真实书目是否会被误判或误伤，不写入项目；`production-smoke-matrix.js` 是 skill 生产验收矩阵，更新 skill、吸收上游、调整 router/workflow 或重建 bundle 后只读检查短篇、长篇、审阅、拆文、去 AI、setup、更新检查 7 类入口是否仍完成 router/workflow/L3/bundle 四层联动；`output-pollution-check.js` 是报告/修复方案/审查结论的输出污染与输出健康门禁，检测长术语重复填充、重复行、工程词泄露、低信息密度等模型损伤输出，并可用 `--learn --project-root <dir>` 写入 `追踪/schema/output-pollution-rules.jsonl`、`user-style-rules.jsonl` 和 `设定/作者风格/禁用表达.md`；`runtime-guard-validate.js` 是长任务运行边界校验脚本，检查 `current-task.json`、workflow packet 和 result packet 是否包含 `runtime_guard`、checkpoint、heartbeat、预算、`token_cost_governance` 和输出健康门结果，防止长任务缺断点或缺成本账本却伪装为可无人值守；`token-cost-ledger.js` 是 Token Cost Governance 成本账本脚本，记录模型等级、输入输出 proxy、工具噪音、失败重试和浪费信号，写入 `追踪/workflow/token-cost-ledger.jsonl` 与 `token-cost-summary.json`；`workflow-entry-guard.js` 是 runner / 启动器前置守卫脚本，固定串联运行时巡检、任务收件箱和可选可见输出门禁；返回 `show_task_inbox_only` 时只能展示收件箱菜单，返回 `business_routing_allowed` 后才允许进入业务路由；`workflow-runtime-supervisor.js` 是只读运行时巡检脚本，读取 `追踪/workflow/current-task.json` 的 heartbeat 与 checkpoint，返回 `continue`、`pause_at_checkpoint`、`resume_from_checkpoint` 或 `repair_runtime_guard`，供前端刷新、后端重连和外部 runner 判断下一步；`workflow-state-machine.js` 是 workflow 阶段状态机，定义模板、阶段图、`pending_action` 解析、result packet 校验和下一步候选，让“继续/1/下一步”不再靠模型自由推理；`context-assembler.js` 是创作记忆库上下文装配脚本，按任务范围、active cast、伏笔、作者声口和 token 预算生成 assembled context；`memory-recommender.js` 是记忆建议脚本，只记录或低风险应用记忆变更，高风险 canon/人物认知/伏笔/成长规则变化必须等待用户确认；`safe-text-search.js` 是授权友好的文本搜索脚本，用一行 Node 命令替代 `cd && grep ... 2>/dev/null | head`，用于伏笔词、人物名、卷内命中列表等常规只读检索；`write-failure-triage.js` 是 Write/Edit/MultiEdit 失败后的确定性分诊脚本，区分 `blocked_write_tool_call_invalid`、`blocked_write_hook`、`blocked_write_permission` 和 `blocked_write_missing_output`，避免把参数错误、hook usage 或权限问题误当成“继续落盘”；`review-state-ledger.js` 是审阅状态账本，记录 `追踪/review-state.json` 的 `dependency_hashes/stale/suggested_recheck_ranges`；`story-prose-gate.js` 是正文交付硬门禁；`cross-volume-handoff-pack.sh` 与 `cross-volume-continuity-audit.sh` 用于卷末到下一卷第 001 章的钩子/伏笔交接和承接审计，保证上一卷预留不在新卷开篇断线；`stage2-summary-quality-check.js` 是长篇拆文 Stage 2 的摘要格式/枚举门禁，用固定 Node 命令替代 `cd && for && grep` 这类会触发 Claude Code 授权的 shell 展开；`stage2-grounding-check.js` 是长篇拆文 Stage 2 的 source-grounding 门禁，检查人物、涉及字段和原文引用是否来自本章 source slice。若目标项目缺少任一脚本，不得汇报 story-setup 已完整刷新。
- 上述运行态检查中的 `current-task.json` 仅用于取得 UI 焦点；`runtime_guard`、heartbeat、checkpoint、预算和 blocked 状态一律从对应 `tasks/<workflow_id>/task.json` 读取和写入，pointer 不承载任务事实。

### 2.4.4 部署 OpenCode 资产

仅当 `target_cli` 含 `opencode` 时执行。OpenCode 支持来自上游 OpenCode CLI 方案，但本项目做了单入口改造：所有 commands 只能把用户导向 `novel-assistant`，不得要求用户直接调用 `story-*` 子 skill。

部署步骤：

1. `skills/story-setup/references/opencode/AGENTS.md.tmpl` → `AGENTS.md`，按 CLAUDE.md 同等 marker/section 策略合并。
2. `skills/story-setup/references/opencode/agents/` → `.opencode/agents/`，覆盖 story-setup 管理文件。
3. `skills/story-setup/references/opencode/commands/` → `.opencode/commands/`，必须包含 `novel-assistant.md`；兼容 alias 如 `story-long-write.md` 也必须写“请使用 novel-assistant，按某意图路由”。
4. `skills/story-setup/references/opencode/plugin.ts` → `.opencode/plugins/story-hooks.ts`。
5. `skills/story-setup/references/opencode/opencode.json.patch` 合并到 `opencode.json`：只向 `plugin` 数组追加 `./.opencode/plugins/story-hooks.ts`，去重并保留用户已有 provider/model/permission 等字段。
6. 源码包 `skills/story-setup/references/agent-references/` 同步到 `.opencode/skills/novel-assistant/references/agent-references/`；若项目有 `skills/` fallback，也同步到 `skills/novel-assistant/references/agent-references/`。旧 `.opencode/skills/story-setup/references/agent-references/` 只作为兼容 fallback。
7. `skills/story-setup/references/opencode/pre-commit.sh` 合并到 `.git/hooks/pre-commit` 的 story-setup 管理块；不覆盖用户已有 hook。

OpenCode plugin 的正文守卫必须兼容卷内编号结构：既要识别旧 `正文/第001章.md`，也要识别新 `正文/第1卷/第001章_章名.md`，并检查对应 `大纲/第1卷/细纲_第001章.md`。

### 2.5 部署 Session State 模板

- 读取 `skills/story-setup/references/templates/上下文.md.tmpl`
- 仅当已识别为长篇书目且 `{书名}/追踪/` 已存在时，创建缺失的 `{书名}/追踪/上下文.md`
- 如果目标文件已存在，不覆盖；短篇项目不得因此创建 `追踪/` 目录

### Phase 2.5: 初始化 .book-state.json

在 `.story-deployed` 写入后，模板 `.book-state.json.tmpl` 部署到 `BOOK_DIR/.book-state.json`：

- 字段：`bookTitle` / `bookPath` / `currentChapter` (1) / `currentVolume` (第1卷) / `currentVolumeChapter` (1) / `globalDraftOrder` (1) / `currentDraftPath` / `currentOutline` / `chapterLayout` (auto) / `preferredVolume` (第1卷) / `allowLegacyFlat` (true) / `status` (pending) / `wordCount` (0) / `writingMode` (serial) / `lastUpdated` (TIMESTAMP)
- `currentChapter` 仅表示旧项目/全书进度，不能用于卷目录项目拼接正文或细纲路径；卷目录项目必须用 `currentDraftPath`、`currentOutline`，缺失时才用 `currentVolume + currentVolumeChapter` 解析。
- 兼容提示：currentChapter 仅表示旧项目/全书进度；新卷目录项目的续写定位以 currentDraftPath/currentOutline 为准。
- `globalDraftOrder` 只用于全书顺序、发布导出和统计；`currentVolumeChapter` 才是 `正文/第X卷/第NNN章_章名.md` 的卷内编号。
- `chapterLayout` 用于兼容旧/新章节目录：`auto` 按现有文件推断，`flat` 保持旧扁平结构（如 `正文/第001章_章名.md`），`volume` 使用卷内结构（如 `正文/第1卷/第001章_章名.md`）
- 更新写作协作环境只补缺失配置字段，不移动正文、大纲、细纲；迁移章节结构必须另行确认
- `allowLegacyFlat=true` 表示旧扁平正文是合法候选，不应被 `chapter-draft-resolve.js` 判定为未落盘
- 由 `session-start.sh` 读取并提示续写
- 由 `story-long-write` Phase 4 写完一章后更新 `currentChapter` + `status=in_progress` → `status=completed`

### Phase 2.6: 写作项目结构迁移

已部署项目升级时，对用户可见的动作叫“更新写作协作环境”。该动作默认只同步 hooks/agents/rules/references/scripts 与 `.story-deployed`；识别到旧扁平长篇目录时，只做迁移检查和风险提示。用户另行确认“执行迁移”后，才把旧扁平长篇目录迁移到当前推荐的卷内编号结构。确认后按每本书执行：

```bash
node scripts/story-project-migrate.js <book-project-dir> --write
node scripts/chapter-assets-build.js <book-project-dir> --write
node scripts/story-schema-build.js <book-project-dir> --write
node scripts/story-schema-validate.js <book-project-dir>
```

结构迁移门禁：

1. 更新写作协作环境后，先对每本长篇书目运行 dry-run 检测：
   ```bash
   node scripts/story-project-migrate.js <book-project-dir> --json
   ```
2. 只要 dry-run 返回 `actions.length > 0`、存在旧扁平结构、存在混合结构，或本次 skill 引入新的目录策略版本，就必须先输出目录结构选择，不得直接进入写作/审阅/拆文候选：
   ```text
   检测到目录结构需要决策。请选择：
   1. 迁移到卷内编号结构
   2. 保持旧结构兼容
   ```
3. `1. 迁移到卷内编号结构` 是高风险写入选择：执行前必须说明会移动正文/大纲/细纲/追踪资产，先写版本快照和冲突清单；确认后才运行 `story-project-migrate.js --write`、`chapter-assets-build.js --write`、`story-schema-build.js --write`、`story-schema-validate.js`。
4. `2. 保持旧结构兼容` 不移动正文、大纲、细纲。需要更新 `.book-state.json`：`chapterLayout=flat` 或保持用户既有显式布局、`allowLegacyFlat=true`；同时在 `.story-deployed` 记录：
   ```text
   migration_status: skipped_by_user
   migration_reason: keep legacy layout compatible
   ```
   之后写作、审阅和前端读取必须按兼容模式解析旧路径，不得把旧扁平正文误判为缺失。
5. 如果用户此前已选择 `migration_status: skipped_by_user` 且本次目录策略未变化，可以不重复询问，只在收束报告里写“保持旧结构兼容”；如果目录策略版本变化或检测到新旧混合冲突，必须重新询问。
6. 结构门禁未收束前，不展示继续未完成任务或开启新的任务候选；结构门禁完成后，才进入“继续未完成任务 / 开启新的任务”的数字候选。

迁移规则：

- 旧 `大纲/细纲_第001章.md` → 新 `大纲/第1卷/细纲_第001章.md`
- 旧 `大纲/卷纲_第1卷.md` / `大纲/卷纲_第一卷.md` → 新 `大纲/第1卷/卷纲.md`
- 旧 `正文/第001章_章名.md` → 新 `正文/第1卷/第001章_章名.md`
- 旧 `追踪/章节契约/第001章.md` → 新 `追踪/章节契约/第1卷/第001章.md`
- 旧 `追踪/交接包/第001章_to_第002章.md` → 新 `追踪/交接包/第1卷/第001章_to_第002章.md`

幂等要求：

- 只有检测到旧扁平文件时才运行 `story-project-migrate.js`；项目已经是 `大纲/第X卷/`、`正文/第X卷/`、`追踪/章节契约/第X卷/` 时，不要重复迁移，也不要把“脚本跑过”汇报成“已更新”。
- 迁移必须先写入 `追踪/版本/{timestamp}_layout-migration/manifest.json`，并把旧文件备份到 `legacy-flat-layout/`。目标文件已存在时不覆盖，记录 conflict/warn，继续部署基础设施，但最终安装报告必须提示用户处理冲突。
- 迁移完成后刷新 `追踪/章节资产.jsonl` 和 `追踪/schema/`，供 `novel-project` 前端读取；如果内容未变化，只汇报“已检查，当前最新”。
- 前端或自动化调用时，“更新写作协作环境”就是“同步运行时 + 检查是否需要迁移”的动作；它不是章节内容刷新。若需要移动正文/大纲/细纲、刷新章节资产/schema，必须作为单独的迁移确认点处理。
- 只有 hooks/agents/rules/references/scripts 已同步，且必要的迁移检查完成后，才提示用户新开 Claude 会话。迁移未完成、存在冲突未确认或脚本失败时，不要要求用户新开窗口继续写作。

### Phase 2.7: 生成写作宪法文件

向用户 4 问（每问可输入或留空默认）：
1. 题材禁区（如：禁师生恋 / 禁涉政）
2. 人物红线（如：主角不死 / 配角不能真名）
3. 风格宪法（如：必须第三人称 / 对话占比 45-65%）
4. 平台约束（如：番茄 / 起点 / 晋江 限定的规则）

读取 `skills/story-setup/references/templates/constitution.md.tmpl`，替换 `{{GENRE_TABOO}}` / `{{CHARACTER_RED_LINE}}` / `{{STYLE_CONSTITUTION}}` / `{{PLATFORM_CONSTRAINT}}` 占位符为用户答案（留空用「无（默认未设置）」），写入 [<BOOK_DIR>/.story/constitution.md](#)。4 个 write/analyze skill 在 Phase 1.0 加载它到 system prompt 顶部。

### 2.7 合并 Hooks 注册到 settings.local.json

> 兼容性说明：`settings-hooks.json` 中 PreToolUse 的 `if` 字段使用 Claude Code hook 条件语法，需要运行环境支持 hook-level if。若目标工具不支持该字段，hook 脚本本身仍会自检并 advisory-only 退出；部署时可删除该 `if` 字段并保留 matcher + command。

- 读取 `skills/story-setup/references/templates/settings-hooks.json`
- 读取用户项目的 `.claude/settings.local.json`（如存在）
- 合并 hooks 配置（按「settings-hooks.json 合并算法」处理）
- 写入 `.claude/settings.local.json`

### 2.8 创建部署标记

- 创建 `.story-deployed` 文件（sentinel file）
- 写入以下字段（YAML `key: value` 格式，hook 用 `references/templates/hooks/lib/sentinel.sh` 读取）：
  ```
  deployed_at: <date -u +"%Y-%m-%dT%H:%M:%SZ">
  agents_version: 18
  setup_skill_version: 1.4.5
  novel_assistant_bundle_id: <从 novel-assistant-manifest.json 读取 bundleId；不可读时写 unknown>
  novel_assistant_source_commit: <从 novel-assistant-manifest.json 读取 sourceCommit；不可读时写 unknown>
  target_cli: claude-code（或 opencode，或 claude-code,opencode）
  resolver_strategy: global-skill-with-project-agent-references
  references_dir: .claude/agent-references/novel-assistant
  ```
- 此文件供 session-start.sh 和写作 skill 检测部署状态，避免重复提示
- 同时创建一次性标记文件 `.claude/.agents-pending-restart`（空文件即可）。session-start.sh 在下一个会话启动时据此确认 agents 已随新会话注册，并自动删除该标记——用来向用户确认「重启已生效」。
- 如果 `.story-deployed` 已存在但无 `agents_version` 或版本 < 18，提示用户重新运行 story-setup 以更新 hooks/agents/rules/reference bundle、运行时脚本、OpenCode 资产、`style-learner.md`、`user-style-learning.md`、退化检测器和章节定位参考，并执行长篇目录迁移（具体变更见 `UPGRADING.md`）

### 更新完成后的收束规则

当本模块是由“更新写作协作环境 / 刷新 setup / 同步运行时”触发时，部署验证通过后只汇报协作环境结果并停靠：

- 不得自动继续旧审阅/写作/拆文任务队列，不得自动推进“修真进度/伏笔批次”“继续写第 X 章”等上一轮 pending 项；必须运行 `node scripts/workflow-entry-guard.js --project-root <book-root> --write --json`，并逐字展示 `visible_response.text`，不得只调用 task inbox 后自行组织候选。
- 不得输出半截交互题、不得触发无效参数选择器，也不得输出类似 `Invalid tool parameters` 的失败尾巴；已初始化项目固定展示 `查看未完成任务（N 个） / 查看智能推荐新任务 / 开启当前作品新目标 / 输入其他要求` 四项数字首屏，`N=0` 也必须显示，不得改用 A/B/C/D/E。
- 使用数字候选协议：每个候选都写成 `1. 候选标题`，并在 `pending_action.options` 中记录 `number/action/label`。不要只输出无编号的意图列表；CLI 用户输入数字，前端/runner 可渲染为上下方向键选择。默认最多展示 4 个业务候选，超过 4 个时第 4 项为 `查看更多选项`。
- 维护动作不属于默认下一步候选：启动自检已经完成版本检查；更新完成后不要把检查更新、更新本地 skill、迁移章节结构列入默认候选。它们只在用户明确要求时进入维护协议。
- 结构迁移门禁优先于普通业务候选：如果 dry-run 检测到目录结构需要决策，先让用户选择 `1. 迁移到卷内编号结构` 或 `2. 保持旧结构兼容`；结构门禁未收束前，不展示继续未完成任务或开启新的任务候选。
- 更新完成后应先识别未完成任务数量，再停在统一数字首屏。未完成任务只从落盘状态判断，例如 `追踪/workflow/task-index.json`、`追踪/workflow/current-task.json`、`追踪/review-state.json`、拆文 `_progress.md`、`.active-book`、章节交接包；伏笔异常和历史报告属于智能推荐，不冒充未完成任务。不得自动替用户推进旧任务，也不得凭聊天记忆生成“继续写第十二卷 / 继续第723章 / 为某短篇补大纲”这类候选。
- 如果 `workflow-task-inbox.js` 返回 `reconstructed=true` 或 `status=reconstructed`，这是旧项目补救入口，不是真实未完成任务；先提示用户确认要恢复哪个断点，并把确认结果写入对应 `tasks/<workflow_id>/task.json`，再刷新焦点 pointer 并进入业务执行。
- 版本展示要区分“内容包一致”和“源码提交一致”：bundleId 一致只能说明协作环境内容包已同步；commit 不一致时写“源码提交号仅供参考，当前部署记录为 X”。
- 更新触发本轮没有其他明确业务意图时，结尾必须逐字使用 entry guard 返回的统一首屏，例如：
  ```text
  1. 查看未完成任务（0 个）
  2. 查看智能推荐新任务
  3. 开启当前作品新目标
  4. 输入其他要求
  ```
  数量必须来自当前项目真实状态；不得直接展开智能推荐内容。

- 如果用户原始意图仍需继续，完成数字首屏停靠后等待用户下一句；用户也可以直接重新输入明确的写作、审阅或拆文目标，由 entry guard 放行进入对应流程。

## Phase 3：验证安装

1. 验证 hooks 注册：
   - 检查 `.claude/settings.local.json` 中的 hooks 字段是否正确
   - 检查 `.claude/hooks/` 下的脚本是否存在且有执行权限
   - 检查 `.claude/hooks/lib/common.sh` 与 `.claude/hooks/lib/sentinel.sh` 是否存在
   - 检查 PostToolUse 在 `Write|Edit|MultiEdit` 同时注册 `ai-trace-detector.sh` 与 `prose-quality-gate.sh`
2. 验证 rules 路径：
   - 检查 `.claude/rules/` 下的规则文件是否存在且包含 `paths` frontmatter
3. 验证 agents：
   - 检查 `.claude/agents/` 下的 8 个 agent 定义文件是否存在，包括 `style-learner.md`
4. 验证 agent reference bundle：
   - 检查 `.claude/agent-references/novel-assistant/` 下 reference 文件完整
   - 检查所有 `novel-assistant/references/agent-references/<file>.md` 都能解析到 deployed bundle
   - 如存在旧 `.claude/agent-references/legacy-story-setup/`，只作为兼容 fallback 检查，不作为新模板主路径
5. 验证 OpenCode 部署（仅当 target_cli 含 opencode）：
   - 检查 `AGENTS.md`、`.opencode/agents/`、`.opencode/commands/novel-assistant.md`、`.opencode/plugins/story-hooks.ts` 存在
   - 检查 `opencode.json` 的 `plugin` 数组包含 `./.opencode/plugins/story-hooks.ts`
   - 检查 `.opencode/commands/` 中所有兼容命令都导向 `novel-assistant`
6. 验证部署标记：
   - 检查 `.story-deployed` 是否存在且包含时间戳、`agents_version: 18`、`setup_skill_version: 1.4.5`、`novel_assistant_bundle_id`、`novel_assistant_source_commit`、`target_cli`、`resolver_strategy`、`references_dir`
7. 验证长篇结构迁移：
   - 如识别到长篇书目，检查 `追踪/版本/*_layout-migration/manifest.json`（有旧扁平文件时）或确认无需迁移
   - 检查 `追踪/章节资产.jsonl` 与 `追踪/schema/chapters.jsonl` 可生成
8. 输出安装报告：
   - 列出所有已部署的文件
   - 列出需要注意的事项（如已有配置已合并）
   - 醒目提示：本次部署写入/更新了 `.claude/agents/`，且 setup/迁移检查已完成。Claude Code 只在会话启动时注册 custom agent。请新开一个 Claude Code 会话再开始写作；下次会话启动时 `session-start.sh` 会读取并清除 `.claude/.agents-pending-restart`，提示 agent 已重新加载。
   - 提示用户只使用 `/novel-assistant`，例如 `/novel-assistant 准备写书`、`/novel-assistant 继续写`、`/novel-assistant 写一篇短篇`

---

## 模板占位符

| 占位符 | 替换规则 | 示例 |
|--------|----------|------|
| `{项目名}` | 用户项目名称或目录名 | 《剑来》、《暗卫》 |
| `{书名}` | 书名目录名（与目录一致） | 与 `{项目名}` 相同，或用户自定义 |
| `{目标平台}` | 目标发布平台 | 起点、番茄、晋江、知乎盐言 |
| `{作者名}` | 用户笔名或昵称 | 未指定时用「作者」 |

替换时去掉花括号。如果用户未指定项目名，用当前目录名。未指定的占位符保留原样不替换。

## CLAUDE.md 合并策略

用户已有 CLAUDE.md 时，按 marker/section 合并：
1. 优先识别 story-setup 管理块标记（如果旧项目已有标记，只替换标记内内容）
2. 无标记时，读取用户现有 CLAUDE.md，按 `##` 标题切分为 section map
3. 读取模板 CLAUDE.md.tmpl，同样切分
4. 模板中的标准 section（Skill 路由表、文件结构、协作规则、Context Recovery、语言）**覆盖**用户同名 section
5. 用户独有的 section（自定义内容）**保留**不动
6. 未知冲突用普通文本确认让用户选择保留哪个版本，不调用外部交互工具

## settings-hooks.json 合并算法

hooks 注册合并按 command 字段去重：
1. 读取用户现有 `.claude/settings.local.json`（如存在），提取 hooks 部分
2. 读取 `settings-hooks.json` 模板，提取要注册的 hooks
3. 对每个 hook event（SessionStart、PreToolUse 等）：
   - 用户已有的 hook command → 保留，不重复添加
   - 模板中的新 hook command → append 到对应 event 的 hooks 数组
   - 用户独有的其他配置（permissions、env 等）→ 完整保留
4. 写入合并后的完整 settings.local.json

## 重新部署

- `.story-deployed` 不存在 → 全新安装，Phase 2 全部执行
- `.story-deployed` 存在且 `agents_version: 18` → 提示已部署，用普通文本确认是否重新部署
- `.story-deployed` 存在但 `agents_version` < 18 → 提示需要更新，重新执行 Phase 2 覆盖 agents/hooks/rules/reference bundle、运行时脚本、OpenCode 资产，执行长篇目录迁移，CLAUDE.md / AGENTS.md 和 settings.local.json / opencode.json 走合并策略

---

## 参考资料

| 文件 | 用途 |
|------|------|
| references/templates/CLAUDE.md.tmpl | 项目根 CLAUDE.md 模板 |
| references/templates/hooks/ | hook 脚本模板 + `lib/common.sh`/`lib/sentinel.sh`，含正文前置细纲守卫与正文写后质量门禁 |
| references/templates/rules/ | 4 条 path-scoped 规则模板 |
| references/templates/agents/ | 8 个 agent 定义模板（story-architect, character-designer, narrative-writer, consistency-checker, story-researcher, story-explorer, chapter-extractor, style-learner） |
| references/agent-references/ | Agent 模板自带的参考资料源码副本；部署主路径为 `.claude/agent-references/novel-assistant/`，可复制旧 `story-setup` fallback，避免跨 skill references |
| references/opencode/ | OpenCode / OpenClaw 资产：AGENTS.md 模板、agents、commands、plugin、opencode.json patch、pre-commit |
| references/templates/settings-hooks.json | hooks 注册 JSON 片段 |
| references/templates/上下文.md.tmpl | 写作上下文模板 |

---

## 流程衔接

**流水线：** 部署
**位置：** 初始化（最前置）

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 部署完成，开始写作 | novel-assistant 自动路由到 long-write / short-write | `/novel-assistant 继续写` 或 `/novel-assistant 写一篇短篇` |
| 导入已有小说做拆解 | novel-assistant 自动路由到 import | `/novel-assistant 导入小说` |
| 需要浏览器登录态（扫榜/拆文取原文） | browser-cdp | `/browser-cdp` |
