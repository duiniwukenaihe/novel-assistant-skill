# 参考项目低频观察流程

本流程用于观察除主上游以外的优秀开源项目，例如 `lingfengQAQ/webnovel-writer`、`AI-Novel-Writing-Assistant`、`humanizer-zh`、长篇审阅工作流参考项目和若干 skill 设计仓库。

它不替代 [上游反哺半自动流程](upstream-backport-sop.md)。主上游仍是 `worldwonderer/oh-story-claudecode`，仍按 `reports/upstream/` 高频跟踪和小批量反哺。

## 来源分层

| 层级 | 来源 | 频率 | 输出 | 是否可直接吸收 |
|---|---|---:|---|---|
| 主上游 | `worldwonderer/oh-story-claudecode` | 高频，用户要求或每次准备发布前 | `reports/upstream/` | 可手工反哺，但仍不直接 merge |
| 参考 GitHub 项目 | 其他优秀小说/skill/去 AI/上下文项目 | 低频，通常 30-90 天或用户点名 | `reports/research/` | 默认只能 clean-room 设计吸收 |
| 分发镜像 | SkillHub、ClawHub 等目录页 | 仅用于发现线索和检查镜像漂移 | 研究报告附录 | 不参与吸收决策；必须回到 GitHub 原仓库核验 |
| 知识来源 | 文章、设计说明、Trellis/SillyTavern 等概念来源 | 手工复查 | `reports/research/` 或 `docs/superpowers/` | 只吸收设计原则 |
| 数据来源 | 番茄官方 Web、网文大数据、用户合法提供的 App API JSON/HAR | 由专项脚本检查 | `data/`、扫榜产物、研究报告 | 只吸收数据协议和字段映射 |
| 排除/特殊来源 | 本项目公开发布仓库、私有短篇/下载/本地素材资产 | 不进入公开参考项目自动检查 | 私有 overlay 或发布 SOP | 不进入公开 GitHub registry |

## 命令

```bash
node scripts/na-dev.js upstream --write
node scripts/na-dev.js reference-watch --write
node scripts/na-dev.js reference-watch --write --include-distribution-mirrors
```

`reference-watch` 读取 [reference-projects.json](reference-projects.json)。其中 `projects` 是主观察面，会执行轻量 `git ls-remote` 获取 GitHub 原仓库的默认分支 HEAD 和 tag 列表；默认不会请求分发站。只有显式传入 `--include-distribution-mirrors` 时，`skillSources` 才执行可选的镜像诊断，而且不能覆盖 GitHub 结论；`knowledgeSources`、`dataSources`、`excludedSources` 只进入报告和汇总，不触发 git。

它只做：

- 检查项目 HEAD 是否变化。
- 检查最新 tag / tag sha 是否变化。
- 核对 registry 中的分支是否与 GitHub 默认分支一致。
- 标记 `changed/current/untracked/error`。
- 输出 license、吸收模式、关注方向和建议动作。
- 写入 `reports/research/YYYYMMDD-HHMMSS-reference-project-watch.md`。
- 列出手工知识来源、数据来源和排除/特殊来源，防止只盯 GitHub repo 而漏掉用户提供的设计来源。

它不做：

- 不 merge。
- 不 cherry-pick。
- 不 fetch 到本地长期 ref。
- 不复制源码或长段 prompt。
- 不自动修改 `novel-assistant`。

## GitHub 可信锚

参考 skill 的吸收结论必须绑定 GitHub 原仓库：

1. 记录仓库 URL、真实默认分支、HEAD commit 和可用 tag。
2. 检查仓库许可证；缺失或不明确时只允许 clean-room 设计吸收。
3. SkillHub/ClawHub 的目录版本、制品内版本或内容与 GitHub 不一致时，镜像状态记为 `quarantined`。
4. 被隔离的镜像只保留诊断证据，不进入 prompt、bundle、运行时 reference 或吸收队列。
5. GitHub 仓库没有实质方法、只有包装文案时，结论可以是“拒绝吸收”，无需为了覆盖来源而增加模块。

## Commit 与 Tag 的吸收分级

参考项目不能每次 HEAD 变动就深度 clone、深读和吸收，否则会浪费 token，也容易把不稳定实验误吸收进生产 skill。

`reference-watch` 采用两级信号：

| 信号 | 处理 |
|---|---|
| HEAD 与 `lastObservedCommit/lastReviewedCommit` 一致，tag 也一致 | `no_action`，不复审 |
| HEAD 变化，但最新 tag 与 `lastObservedTag` 一致 | `light_commit_log_only_until_tag_changes`，只看 commit 摘要 / README 级变化，不深读源码、不大规模吸收 |
| 最新 tag 或 tag sha 变化 | 写 research report，进入 clean-room 设计 triage |
| 项目没有 tag | 回退到 HEAD 变化判断，但仍按 priority 控制复审深度 |

记录字段：

- `lastObservedCommit`：上次轻量观察到的分支 HEAD。
- `lastReviewedCommit`：已经完成研究报告或吸收评审的 commit。
- `lastObservedTag` / `lastObservedTagSha`：上次轻量观察到的最新 tag 与 tag 对象。
- `lastReviewedTag` / `lastReviewedTagSha`：已经完成研究报告或吸收评审的 tag。

原则：tag/release 是稳定版本信号；只有未发布 HEAD 变化时，默认不进入深度吸附。

## 参考项目吸收规则

每个 changed 项目先写研究报告，再决定是否进入实现。

研究报告至少包含：

1. 项目与版本证据：repo、branch、HEAD、license。
2. 值得吸收的设计：必须转译成 `novel-assistant` 的 workflow/router/memory/gate/agent 边界。
3. 拒绝项：前端、provider、重型 runtime、与单入口冲突的命令体系、许可风险内容。
4. clean-room 映射：只写我们自己的设计和测试，不复制原实现。
5. 验收建议：需要新增哪些 smoke/test/gate。

## 当前重点参考项目

| 项目 | 优先级 | 主要价值 | 默认策略 |
|---|---|---|---|
| `lingfengQAQ/webnovel-writer` | high | Story System、章节提交链、投影重放、作者友好报告、长期记忆 | GPL 项目，只做 clean-room 设计吸收 |
| `ExplosiveCoderflome/AI-Novel-Writing-Assistant` | medium | 自动导演、质量债务、角色资源账本、写法资产 | 设计 triage，不吸收前后端/runtime |
| `op7418/humanizer-zh` | low | 中文去 AI 诊断、人味指标 | ideas/tests only |
| `wen1701/FanqieRankTracker` | high | 番茄字体反爬解码、rank 抓取和 bookId 解析 | 兼容实现复查，保留许可证据 |
| `SillyTavern/SillyTavern` | medium | Lorebook、动态上下文、prompt ordering、上下文预算 | clean-room 记忆/上下文设计吸收 |
| `EdwardAThomson/NovelWriter` | medium | 场景/章节/批次审阅、质量趋势 | 只吸收分层审阅与趋势度量设计；许可证使用前核验 |
| `ARMANDSnow/make-ur-Agent-writer` | high | mock-first、fail-closed 审阅、成本预算、断点恢复 | 只吸收验收和调度设计；不复制固定 reviewer 编排或 prompt |
| `Narcooo/inkos` | high | 审计维度、有界修订、快照锁、结构化 delta | AGPL 项目，只做 clean-room 设计吸收 |
| `iLearn-Lab/NovelClaw` | medium | 动态记忆、长篇连续性 | 即使为 MIT 也只做 clean-room 设计吸收，不搬运实现 |
| skill 设计类仓库 | low | skill 包结构、触发语、文档组织 | prompt pattern review |

以上长篇审阅来源均按 45-60 天或用户点名低频观察。它们只能产出自己的架构映射、测试场景和验收规则：不得 merge、cherry-pick、复制源码、复制长段 prompt，亦不得将任何一个项目的固定 Agent 数量或 runtime 当作本项目要求。

## 当前重点非 GitHub 代码来源

| 来源 | 类型 | 主要价值 | 跟踪方式 |
|---|---|---|---|
| Trellis 任务持久化 | 概念来源 | `spec / task / workspace journal` 分层、RPD、长期任务恢复 | 手工设计复查 |
| GitHub Spec Kit Fiction preset discussion | 概念来源 | 写前结构分析、写后连续性、局部修订的职责分离 | 手工摘要；不是可观察或可 merge 的 GitHub 项目 |
| 微信短篇选题文章 | 文章来源 | 资讯选择、脑洞卡、短篇卡池交互 | 手工摘要，不依赖稳定抓取 |
| 网文大数据 · 番茄首秀 | 数据来源 | 分类、字数、在读、读增、bookId 候选 | `wangwen-debut-scraper.js` |
| 番茄官方 Web/API | 数据来源 | 官方分类、book info 校验、bookId 回填 | `fanqie-category-catalog.js` / `scan-download-hints.js` |

私有来源（`private-short-extension`、`private-download-extension`、`private-short-extension` 等）只在本地私有 overlay 或 GitLab 私有分支跟踪，不写入公开 GitHub 发布材料。

## 更新 registry

新增可自动观察的 GitHub 参考项目时修改 [reference-projects.json](reference-projects.json) 的 `projects`：

```json
{
  "id": "example",
  "name": "owner/repo",
  "repo": "https://github.com/owner/repo.git",
  "branch": "main",
  "priority": "reference-low",
  "cadenceDays": 90,
  "license": "unknown-check-before-use",
  "absorbMode": "prompt-pattern-review",
  "focusAreas": ["workflow", "memory"],
  "lastObservedCommit": "abc...",
  "lastObservedTag": "v1.0.0",
  "lastObservedTagSha": "def..."
}
```

如果某次已经完成研究，可把 `lastReviewedCommit` 和 `lastReviewedTag` 更新为当时 HEAD/tag。这样下次报告能区分 `current`、未发布 HEAD 变化和稳定 tag 变化。

新增文章、数据站、概念设计或排除项时，分别写入：

- `knowledgeSources`：文章、设计模式、概念来源。
- `dataSources`：榜单、平台公开接口、用户合法提供的 JSON/HAR 导入源。
- `excludedSources`：主上游、公开发布目标、私有本地资产等不应作为参考 repo 自动检查的来源。

## 与发布的关系

公开 GitHub 发布前，不要求所有参考项目都检查一遍；只要求主上游检查和本项目测试通过。

当用户点名某个参考项目，或准备做大版本 workflow/memory/gate 重构时，再运行：

```bash
node scripts/na-dev.js reference-watch --write
```

参考项目报告可以提交到 GitLab 开发分支；公开 GitHub 分支默认清理 `reports/`，不要把临时研究报告当用户文档发布。
