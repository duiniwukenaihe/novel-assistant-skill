# Changelog

## v0.1.0 - 2026-07-24

### v0.1.0 维护更新（2026-08-07）

首次发布后的稳定性、安全守卫与记忆精度改进。版本号不变，均为 v0.1.0 的同版本增量修复。

**记忆按阶段召回与可见性**

- Memory 的 11 类召回需求（NEEDS）从内部枚举升级为带描述的契约表，模型能读懂每类需求召回什么、对应上下文哪个字段。
- 短篇 brief / draft / repair / assembly 四个阶段不再全量召回 9 类记忆，按阶段职责只召回需要的子集，减少 Token 占用；跨节钩子和 stale 检测不受影响（派生与呈现分离）。
- 修复 draft 阶段漏召回 `active_promises` 导致到期伏笔义务（due_promise）不生成的缺陷。
- 长链召回路径（context-assembler）传递 needs 声明到结果包，让合同与实际召回透明可核对。
- 阶段上下文 packet 新增「本次召回说明」区块，向模型透明展示当前阶段召回的记忆类别和用途。
- `memory-recommender --status` 修复 `recentLearned` 泄露已取代（superseded）旧版本的问题；新增 `visibilitySummary` 按状态统计记忆条数。
- 补充作者向的记忆四态说明（active / superseded / archived / rejected），如实标注 quarantined 是防御性代码而非实际写入的状态。

**Workflow 性能与结构**

- 全部 `apply-result` 子进程 spawn（状态机回环、runner 调用、6 个 finalize 脚本、recover、title-lock/brief-finalize、short-startup-entry）改为进程内 invoke，消除每次子进程冷启动约 70 个模块的重载开销。
- 从 `workflow-state-machine.js` 分六轮提取 76 个工具函数到 `state-machine-utils.js`（1055 行），主状态机瘦身近千行；删除 2 个死代码函数。
- finalize 脚本辅助函数收敛到共享 `cli-utils`，消除重复的 parseJson / readJson / finish 定义。

**发布守卫增强**

- `check-bundle-sync.sh` 新增 `private-internal-skills` 源与 bundle 同步检查，堵住私有技能副本漂移无人守的缺口。
- `check-command-references` 扩展扫描到 `.md` 文件，用双重路径解析（skill 目录优先、仓库根兜底）避免 skill 内部示例命令误报。
- `static-check.sh` 串联两道守卫，本地 verify 与 CI 对齐，反馈前置到提交前。
- 新增 `check-command-references` 静态校验，防止脚本重命名后命令引用静默漂移。
- 修复 story-setup / story-long-scan / story-short-scan 共 33 处旧扁平布局路径漂移，改为模块相对路径。
- 恢复一次 bundle 重建时丢失的记忆状态文档（SKILL.md 记忆四态说明 + memory-contract.md 状态语义表），并确认源为单一事实源。

**长篇拆文修复（对齐上游 issues）**

- 章节边界正则补识别序章 / 楔子 / 引子 / 前言 / 番外 / 尾声 / 后记 / 终章等非编号结构，不再漏切导致 Stage 2 摘要缺失。
- Stage 6 文风句长统计去掉 `/tmp` 硬编码，改用拆文库目录下的临时文件，修复 Windows 上 Git Bash 与原生 Python 路径不一致导致的确定性失败。

### v0.1.0 初始发布（2026-07-24）

`novel-assistant` 的首次公开版本。项目演化自
[worldwonderer/oh-story-claudecode](https://github.com/worldwonderer/oh-story-claudecode)，
在保留长篇、短篇、审阅、拆文、扫榜、导入和去 AI 味能力的基础上，提供统一入口、
可恢复工作流与可信创作记忆。

#### Workflow

- 用户只需调用 `/novel-assistant`，内部按意图路由到公开专业模块。
- 新项目、已有作品、未完成任务和当前子任务使用不同入口。
- 多阶段任务持久化任务总览、当前子任务、尝试链、可信断点和下一步候选。
- 作者决策点提供简洁数字菜单，同时允许直接聊天纠偏。
- 局部表达修改留在当前正文；人物、因果、反转、节奏或总节数变化时先更新上游规划，
  再使受影响的 Brief、正文和检查结果失效。
- Claude Code、Codex 与 ZCode 使用同一任务身份和接管协议。

#### Memory

- Memory 只接收已确认设定、已采用正文和可信结果，不把旧聊天直接当作事实。
- 按作品、工作流和当前小节或章节召回最小上下文，减少重复读取和 Token 浪费。
- 记忆证据变化时只重建受影响条目，不用全局旧记忆掩盖阶段上下文缺失。
- 使用相对资产身份，作品目录移动或切换宿主后仍可恢复任务。

#### 短篇生产链

- 从素材、设定、人物、节奏和全篇小节大纲开始，再逐节生成 Brief 与正文。
- 一次只处理当前节；采用后保存快照并进入下一节，中途可以回炉或调整后续规划。
- 写作提要、机器门、故事门、采用提交、合稿、去 AI 味和终检形成闭环。
- 已有正文进入复检与局部回炉，不因模板字段名称差异而强迫从头重写。
- 公开短篇由 `story-short-write` 承接，全篇专业审阅由公开 `story-review` 承接。

#### 长篇与审阅

- 长篇使用总纲、卷纲、阶段细纲、章节 Brief、正文提交和跨卷交接的分层流程。
- 支持章节扩容、缩容、插入、删除和重排前的影响审计。
- 审阅按作品结构和风险分配维度，可恢复批次进度，不把抽样结果误报为全量完成。
- 上游项目通过显式迁移入口进入新版 Workflow / Memory，不修改原正文与规划。

#### 质量与稳定性

- 输出健康门识别重复循环、工程词泄漏、模型退化和污染结果。
- 机器门负责确定性异常，故事门负责剧情价值、逻辑、情绪、人物和规划兑现。
- 正式资产采用暂存、校验、提交和投影流程；失败保留可信断点。
- 更新检查、协作环境同步和目录迁移相互独立，不暗中修改正文或规划。

#### 公开发布边界

- 公开包只包含公共模块与公共 Workflow / Memory 内核。
- 发布流程排除本地扩展、个人素材、原文、Demo、运行日志、内网地址和本机路径。
- 发布前运行隐私审计、公开所有权检查、生产 smoke 和可复现制品构建。
