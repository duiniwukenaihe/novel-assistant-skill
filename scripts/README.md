# scripts/ 开发脚本索引

这里是维护 `novel-assistant-skill` 仓库本体的开发脚本索引。它们不是用户直接调用的 skill 命令，也不是让普通写作者手动续跑任务的入口。

注意边界：

- 本目录脚本主要供 CI、维护者、本仓库构建和 `/novel-assistant` 内部流程调用。
- 不是 skill 运行时脚本的唯一位置；运行时脚本在源码模块自己的 scripts/ 下，并由 `build-oh-story-bundle.sh` 同步到 `skills/novel-assistant/scripts/`。
- 改名、移动或删除任一脚本时，要同步测试、README/CONTRIBUTING、bundle 构建清单和调用方。

## 静态守卫

| 脚本 | 用途 | 何时跑 |
|---|---|---|
| `static-check.sh` | skill 结构、frontmatter、引用路径、死文件和基础一致性检查 | CI / 提交前 |
| `public-release-audit.js` | GitHub 公开发布审计，拦截内网地址、本机路径、原文素材、个人创作样本、Claude 运行日志和临时 benchmark 输出 | 发布 `github/public-release` 前 |
| `sanitize-github-public-tree.js` | GitHub 公开发布树清理器，删除私有 skill、私有 workflow overlay、私有维护脚本、superpowers 过程文档、临时报告、benchmark 和个人 demo，同时保留公开 `story-workflow` 编排能力；还会把内网 URL/本机路径/私有功能名改成公开表述 | 生成 GitHub 公开分支时 |
| `publish-github-public-branch.sh` | 从 `main` 或指定 ref 创建隔离 worktree，清理公开分支、重建不含私有 skill 的 bundle、运行审计，并可选 commit/push 到 GitHub | 发布 GitHub 分支时 |
| `check-shared-files.sh` | 只检查明确托管的共享脚本和 agent-reference 镜像，不按 basename 误判内部 bundle/template 差异 | CI / 改共享脚本后 |
| `check-story-setup-deployment.sh` | story-setup 部署资产、sentinel、hooks、agent references、升级说明回归 | CI / 改 setup 或 runtime scripts 后 |
| `check-hook-regex-sync.sh` | hook 伏笔状态检测行为校验 | CI / 改 hook 规则后 |
| `check-hook-locale-safety.sh` | hook 在中文 Windows/GBK 场景下的字节安全 | CI / 改 hook shell 后 |
| `check-python-invocation.sh` | 禁止 skill 文档裸调 `python3`，要求可移植解释器探测 | CI / 改文档命令后 |
| `maintainability-audit.js` | skill 层维护性内核审计，检查共享契约、L2/L3 引用、bundle 和生产矩阵是否同步 | CI / 改 workflow、模块契约、上游反哺或 bundle 前 |
| `check-upstream.sh` | 对比上游提交、tag 和历史，生成 upstream report，并把上游 `story-*` 文件映射到 `skills/novel-assistant/references/internal-skills/...` 与当前 canonical source target；不 merge、不 cherry-pick、不 push | 上游反哺前 |
| `check-longform-stability-fixture.sh` | 长篇稳定性 fixture 的端到端守卫 | CI / 改长篇稳定性脚本后 |
| `plan-evidence-check.js` | 用确定性行状态机移除 0-3 空格 fenced code 和不在 inline-code span 内的未转义 HTML comments，再校验文档恰好有一个 ATX H1、一个正式 `## Plan Status`、无 Setext H1，并校验正式状态表与 `### Task N:` checkbox。阶段名必须非空且唯一，状态仅允许 `planned`、`implemented`、`verified`、`installed`、`released`、`blocked`。`verified`/`installed`/`released` 的 Evidence 必须有当前 `HEAD` 的 ancestor commit 或成功 JSON report；命令只作审计摘要。声明 `sourceCommit` 的 report 必须是当前 `HEAD` ancestor，`sourceTreeId`/`bundleId` 仍作结构校验；每个含完成 checkbox 的任务必须有自己的可达 `Completed by:` commit。未 `released` 或 `blocked` 的阶段必须有下一步。检查器不执行 Markdown 中的命令。 | 回写或验收实施计划时 |

## 测试回归入口

| 脚本 | 用途 | 何时跑 |
|---|---|---|
| `run-bats-tests.sh` | 优先调用 bats，缺失时自动回退到 lite runner | 本地/CI |
| `run-bats-lite.sh` | 无 bats 环境下执行本仓库 `.bats` 子集 | 本地/CI fallback |
| `test-charcount-portable.sh` | 字数统计跨平台回归 | CI / 改字数逻辑后 |
| `test-hook-encoding-portable.sh` | hook 编码与中文路径回归 | CI / 改 hook 后 |
| `memory-index-scale-check.js` | 用同机 500→1000 条事实的相对时间/堆增长检查记忆索引是否出现非线性退化，不使用硬编码毫秒阈值 | 改记忆索引或检索后 |

## 维护者统一入口

脚本数量已经比较多，后续不要继续让维护者记一串零散命令。新增脚本时优先判断是否应该挂到 `na-dev.js` 的子命令里；旧脚本路径保留给 skill、CI、bundle 和历史文档使用。

| 命令 | 等价用途 |
|---|---|
| `node scripts/na-dev.js verify` | 当前默认本地验收：核心 bats 子集、生产矩阵、维护性审计、静态检查、`git diff --check` |
| `node scripts/na-dev.js smoke --repo-root . --json` | 生产验收矩阵 |
| `node scripts/na-dev.js audit --repo-root . --json` | 维护性审计 |
| `node scripts/na-dev.js release-audit --json` | GitHub 公开发布审计；应在已清理的 `github/public-release` 分支上运行 |
| `node scripts/na-dev.js release-status --json` | 发布前状态体检：显示当前开发分支、公开 release worktree、GitHub remote、远端 main/public-release 指针和私有资产风险 |
| `node scripts/na-dev.js prepare-public` | 公开分支发布准备：用 GitHub 更新源重建 bundle，再运行公开审计和 `git diff --check` |
| `node scripts/na-dev.js publish-public --source-ref main --commit --push` | 一键生成/提交/推送 `github/public-release`；在隔离 worktree 中删除私有 skill 与私有 workflow overlay，不改 `main` |
| `node scripts/na-dev.js static` | 静态检查 |
| `node scripts/na-dev.js bundle` | 重建 `novel-assistant` 默认包和 `oh-story` 兼容包 |
| `node scripts/na-dev.js install-local-private` | 本地自用安装：强制以 `NOVEL_ASSISTANT_INCLUDE_PRIVATE=1` 构建并同步到 Claude/Codex/zcode，全程验证私有 workflow overlay 已生效 |
| `node scripts/short-section-repair-finalize.js --project-root <book> --workflow-id <id> --apply --json` | 收束当前短篇小节修订：验证候选稿确已变化，生成受控回执并自动进入单节机器门，避免宿主猜测状态机参数 |
| `node scripts/short-section-draft-finalize.js --project-root <book> --workflow-id <id> --apply --json` | 收束当前短篇小节正文：绑定单一候选稿、生成阶段回执并自动进入机器门，禁止手写 workflow 文件或连续多写 |
| `node scripts/short-section-artifact-migrate.js --project-root <book> --workflow-id <id> --confirm --json` | 把旧版累计正文中的已采用小节迁移为 `正文/第NNN节.md` 事务制品；只复用已有验收证据，不补写正文 |
| `node scripts/short-story-assembly-finalize.js --project-root <book> --workflow-id <id> --apply --json` | 严格按锁定的 `1..N` 小节合稿；缺节、漂移或计划外小节会停靠，预检不写正式稿 |
| `node scripts/short-story-review-finalize.js --project-root <book> --workflow-id <id> --apply --json` | 生成全篇结构证据包，验收总编辑审阅卡；通过后进入表达清理，需要回炉时自动回到反馈影响链 |
| `node scripts/short-story-deslop-finalize.js --project-root <book> --workflow-id <id> --apply --json` | 验收短篇去 AI 暂存稿；同时检查污染、AI 模式和逐节删损保真，显著删损时返回数字化补偿选项而不提交正式稿 |
| `node scripts/na-dev.js upstream --write` | 上游差异报告 |
| `node scripts/na-dev.js reference-watch --write` | 以 GitHub 原仓库为主，低频观察其他优秀开源小说/skill/去 AI/扫榜下载/记忆上下文项目，并汇总手工知识来源和数据来源；记录 HEAD 与 tag/tag sha，tag 未变时只做轻量 commit 观察；分发镜像仅在显式加 `--include-distribution-mirrors` 时诊断；输出 `reports/research/`，不替代主上游反哺 |
| `node scripts/na-dev.js short-write-sync --check --json` | 检查公开短篇 `story-short-write` 与私有短篇 absorbed 方法包是否一致；加 `--upstream-repo <url> --upstream-ref <ref>` 可从上游吸附 |
| `node scripts/na-dev.js skill-policy --json` | 检查 `skills/` 顶层目录角色，避免误删源码模块或新增未归类 skill |
| `node scripts/na-dev.js panlong --candidate benchmarks/panlong/<run>` | 将盘龙候选拆文结果与 `demo/拆文库-盘龙` 基线做结构化对比 |
| `node scripts/na-dev.js behavior-eval --scenario route-single-entry --hosts claude,codex,zcode` | 三端行为验收 dry-run：输出计划命令、预算和预留报告目录；不会启动宿主或消耗额度 |

## 运行时脚本源

这些脚本会被复制到 skill-local scripts/ 和单目录 bundle。改动时必须保证副本字节一致，并跑 `check-shared-files.sh`。

| 脚本 | 用途 |
|---|---|
| `normalize-punctuation.js` | 正文标点规范化，处理破折号、省略号、双连字符、数字区间等 |
| `check-ai-patterns.js` | AI 句式、破折号功能、碎句号和长段落检测 |
| `check-degeneration.js` | 正文退化、重复循环、截断、占位拒绝语和工程词泄露检测 |
| `anti-ai-diagnose.js` | 聚合短篇/长篇 AI 味诊断信号，包含中文模板壳、humanizer 类通用 AI 信号、项目级学习规则、文体画像 `proseProfile`、真人声口保护 `humanVoiceProtection`、工具指纹泄露、占位符、特征簇评分和五维质量评分；只诊断不改写 |
| `author-voice-profile.js` | 从用户确认的优秀样本提取句长、段落、标点、对话比例和 voice hints，生成作者声音画像 |
| `story-prose-gate.js` | 正文交付硬门禁，拦截逐字破折号化、工程词泄露、旧稿污染等 |
| `chapter-text-stats.js` | 章节/短篇小节字数、行数、破折号、省略号统计 |
| `chapter-volume-count.js` | 按卷统计章节数，排除原稿/备份稿，用一行 Node 命令替代 `cd && for && ls && grep && wc` |
| `story-domain-profile.js` | 根据项目证据识别题材和成长轴词，避免非修真项目误用修真话术 |
| `story-progress-status.js` | 当前卷、卷内章号、全书草稿顺序和混合编号状态检测 |
| `novel-assistant-project-smoke.js` | 只读项目冒烟检查，聚合题材、进度和正文门禁风险 |
| `output-pollution-check.js` | 可见输出、报告、修复方案的污染/重复循环检测与学习 |
| `blocked-recovery-template.js` | 模型退化或工具污染后的确定性短回复 |
| `runtime-guard-validate.js` | 校验长任务 current-task、workflow packet 和 result packet 是否具备 runtime_guard、checkpoint、heartbeat 与输出健康门 |
| `token-cost-ledger.js` | 记录 workflow 阶段的 proxy token 成本、模型等级、工具噪音、失败重试和浪费信号，写入 `追踪/workflow/token-cost-ledger.jsonl` |
| `workflow-entry-guard.js` | runner / 启动器前置守卫，先校正当前任务并领取会话租约，再串联 runtime supervisor、task inbox 和可选输出污染门禁；同一本书的旧会话自动只读，返回 pass 后才允许业务路由 |
| `workflow-session-id.js` | 从 Claude Code / Codex / ZCode 进程祖先解析稳定会话标识；无法解析时使用终端或进程回退标识 |
| `workflow-runtime-supervisor.js` | 只读巡检当前 workflow heartbeat/checkpoint，给前端、后端 runner 或新会话返回 continue / pause / resume 决策 |
| `workflow-task-inbox.js` | 只读汇总长篇、短篇、审阅、拆文、下载/续更等状态，生成大工作流优先的启动任务收件箱和完成后推荐 |
| `workflow-state-machine.js` | 工作流状态机，定义模板、阶段图、生命周期、会话租约、`reconcile-runtime`、`switch-intent`、pending_action 解析、result packet 校验和 closure 下一步候选；让“继续/1/下一步”不再靠模型自由推理 |
| `short-plan-contract.js` | 短篇全篇规划门；验证素材卡、设定、全篇小节大纲、总节数、视角与节奏锁定，未完成时阻止正文 |
| `short-review-entry.js` | 完整短篇验收唯一入口；固定路由到 `story-review`，只读审阅允许带规划风险继续并逐节生成补全清单 |
| `short-brief-freshness.js` | 记录并检查单节 Brief 对素材卡、设定、小节大纲和上一节锚点的依赖摘要；上游变化后阻止陈旧 Brief 写正文 |
| `workflow-runner.js` | 工作流运行器；以 `status/once/run` 串联状态机、Claude Code/Codex/ZCode 适配器、流式健康早停、一次受控恢复、结果包应用和成本账本；默认 `auto` 只探测，不静默启动收费模型 |
| `workflow-supervisor.js` | 可选持久督导器；以 `once/watch` 逐次委托既有 runner，落盘监督状态与事件。遇到确认、选择、预算、provider、质量门或事务阻断立即停靠；不改宿主权限配置 |
| `workflow-state-validate.js` | 校验 current/durable 双副本、阶段执行、可信产物、state version 等 workflow 不变量 |
| `workflow-recover.js` | 确定性恢复缺失 result packet；可从已完成阶段摘要重建并推进。旧范围审阅若只有边界抽样、没有完整覆盖证明，则迁移为分批状态并从首个未完成批次恢复，绝不冒充审阅完成 |
| `workflow-review-batches.js` | 管理范围审阅父任务、已持久化的动态叙事批次及独立 result packet |
| `review-batch-plan.js` | 从章节证据、叙事边界、风险密度和运行时预算生成可验证的动态审阅批次计划 |
| `memory-migrate.js` | 将旧项目角色状态、伏笔、上下文、交接包和作者风格投影为带来源哈希的创作记忆 |
| `chapter-commit.js` | 章节多制品事务：prepare 暂存校验、accept 书目级加锁与原子接受、失败回滚、inspect/replay 投影修复 |
| `review-escalation-policy.js` | 章节/小节/修复项的审阅升级策略；普通单元不默认多角色阅读，周期节点轻审，关键节点或用户负反馈才 full review，机器门 blocking 时先修当前单元 |
| `write-failure-triage.js` | Write/Edit/MultiEdit 失败分诊，区分参数、hook、权限和缺失落盘 |
| `safe-text-search.js` | 授权友好文本搜索，用一行 Node 命令替代 `cd && grep ... 2>/dev/null | head`，减少 CLI 授权弹窗和命令污染 |
| `review-batch-evidence-scan.js` | 审阅批次单命令证据扫描：一次完成章节定位、字数统计、标点/AI 痕迹/退化门与可选关键词统计；避免逐章循环、brace expansion 和管道授权 |
| `chapter-metadata-reconcile.js` | 章节元数据安全对齐：预检 schema 与章节资产路径，只修复明显指向备份/缺失文件的资产记录；写入前生成快照，不修改正文 |
| `tool-call-degradation-check.js` | 长命令、heredoc、内联脚本、transcript 污染预检 |
| `tool-task-decompose-plan.js` | 将高风险命令拆成安全脚本化步骤 |
| `review-state-ledger.js` | 审阅状态账本，记录范围、hash、gap、stale 和建议重审范围 |

## 长篇稳定性 / 项目状态

| 脚本 | 用途 |
|---|---|
| `chapter-assets-build.js` | 构建章节资产索引，保留卷内编号和标题 |
| `chapter-draft-resolve.js` | 解析真实正文落盘路径，避免猜固定文件名 |
| `chapter-handoff-pack.sh` | 章节交接包，记录下一章必须继承的状态和钩子 |
| `chapter-index-build.sh` | 构建章节索引，供稳定性检查和批次审阅使用 |
| `chapter-stability-check.sh` | 单章稳定性检查，验证契约 beat、角色认知和动机边界 |
| `context-pack-build.js` | 构建章节上下文包，减少长任务重复读全文 |
| `cross-chapter-continuity-audit.sh` | 跨章连续性审计 |
| `cross-volume-handoff-pack.sh` | 卷末到下一卷的钩子、伏笔、角色状态交接包 |
| `cross-volume-continuity-audit.sh` | 下一卷开篇承接上一卷预留项的审计 |
| `longform-daily-stability-audit.sh` | 日更批次稳定性审计 |
| `revision-impact-scan.sh` | 回炉/大修改动影响范围扫描 |
| `revision-stability-recheck.sh` | 修改后稳定性复检 |
| `stability-agent-dispatch-prompt.sh` | 根据稳定性 checkpoint 生成对应 agent 修复提示 |
| `stability-repair-dispatch.sh` | 将稳定性失败映射为修复动作 |
| `stability-repair-loop.sh` | 稳定性修复循环入口 |
| `story-expansion-plan.js` | 扩容/插章/后移映射计划，先后移旧章节再填新增缺口 |
| `story-project-migrate.js` | 旧扁平结构、混合编号结构到卷内编号结构的迁移计划/执行 |
| `story-version-snapshot.js` | 写作资产版本快照 |
| `publish-export.js` | 发布导出，按全书连续编号输出 |

## 拆文 / 扫榜 / Schema

| 脚本 | 用途 |
|---|---|
| `long-analyze-plan.js` | 长篇拆文批次计划和断点索引 |
| `long-analyze-recovery-state.js` | 长篇拆文恢复状态检测 |
| `stage2-summary-quality-check.js` | 拆文 Stage 2 摘要格式、枚举和批次质量门禁 |
| `stage2-grounding-check.js` | 拆文摘要 source-grounding 校验，防串书和幻觉摘要 |
| `scan-artifact-build.js` | 扫榜 Markdown 转 v0.8 结构化产物 |
| `scan-json-validate.js` | 扫榜结构化产物 schema 校验 |
| `story-schema-build.js` | 从写作项目构建 story schema |
| `story-schema-validate.js` | story schema 校验 |
| `current-contract-build.js` | 构建当前章节契约 JSON |
| `oh-story-doctor.js` | 项目结构和关键写作资产健康检查 |

## 代码生成 / 同步

| 脚本 | 用途 |
|---|---|
| `build-oh-story-bundle.sh` | 从 `src/internal-skills` 源码模块构建 `skills/novel-assistant` 单包 |
| `check-skill-directory-policy.js` | 检查 `skills/` 顶层只保留 `novel-assistant`，并确认 `src/internal-skills` 源码模块齐全 |
| `na-dev.js` | 维护者统一入口；不进入用户安装包，不替代 skill 内部运行时脚本 |
| `panlong-benchmark-compare.js` | 对比盘龙基准候选输出和 demo 基线，供长篇拆文回归使用 |
| `prepare-github-public-release.sh` | 在 `github/public-release` 上强制使用 GitHub 更新源重建 bundle，并执行公开发布审计 |
| `publish-github-public-branch.sh` | 用隔离 worktree 创建/刷新 `github/public-release`，自动清理私有资产并可选提交推送 |
| `public-release-audit.js` | 检查 GitHub 分支不能携带私有地址、个人资产、原文、运行日志和临时输出 |
| `sanitize-github-public-tree.js` | 删除公开分支不该携带的私有目录、个人素材和临时报告；保留公开 workflow 调度内核 |
| `release-status.js` | 只读汇总开发分支、公开发布 worktree、GitHub remote 和私有资产风险，避免从含私有资产的 main 直接发布 |
| `novel-assistant-update-check.js` | 检查当前书目协作环境是否落后于已安装 skill bundle |
| `novel-assistant-self-update.js` | `/novel-assistant 更新 skill` 的本地安装包自更新检查/执行 |
| `workflow-state-machine.js` | 工作流状态机；支持公开默认模板和本地私有 `workflow-registry.json` overlay，维护阶段图、剩余阶段、生命周期、候选动作、intent 切换和 result packet 校验 |
| `task-family-migrate.js` | 仅迁移受支持的 oh-story/旧版 novel-assistant workflow 元数据到任务族账本。现代 `current-task.json` 按焦点指针解析到持久 `task.json`，不会与自身制造假分叉；默认只预览，`--write --confirm` 后才写入，并核对正文、大纲、细纲、设定等创作资产哈希不变。 |
| `sync-private-short-write-absorption.js` | 短篇方法包双目标同步：公开 `story-short-write` 保持可发布，同时同步私有 `private-short-extension/references/absorbed-story-short-write/`；后续上游吸附也必须同时覆盖 public 和 private 两侧 |
| `reference-project-watch.js` | 以 GitHub commit/tag 为可信锚低频观察非主上游参考 repo，并把知识来源、数据来源和排除/特殊来源写入报告；分发镜像默认不请求；只写研究报告，不合并代码 |
| `sync-opencode.py` | 同步 OpenCode agent/command/plugin 资产 |

## 使用建议

- 提交前常用：`./scripts/run-bats-tests.sh`、`bash scripts/check-story-setup-deployment.sh`、`bash scripts/check-shared-files.sh`、`git diff --check`。
- 改 runtime scripts 后：先跑对应单测，再跑 `build-oh-story-bundle.sh`，最后跑 bundle 相关测试。
- 改上游反哺逻辑后：跑 `bash scripts/check-upstream.sh --write`，并更新 README 的上游反哺记录。
