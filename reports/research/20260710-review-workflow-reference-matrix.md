# 长篇审阅工作流参考项目矩阵

- Date: 2026-07-10
- Scope: `novel-assistant` skill 层，重点研究长篇范围审阅、Agent 调度、连续性、成本、恢复与修复闭环
- Method: 复核本仓库参考来源台账、历史调研文档和当前 GitHub 项目说明；许可不明、GPL/AGPL 项目只做 clean-room 设计吸收

## 结论

范围审阅不应等同于“若干 Agent 各自重读全部章节”。更稳妥的共同模式是：

1. 机器先建立章节清单、风险图和事实索引。
2. 按叙事边界与上下文预算拆批，而不是固定按章数硬切。
3. Agent 按维度取证，默认使用最少必要角色，风险触发后再升级。
4. 每批形成可验证结果包；跨批连续性单独核对。
5. 审阅只产生 findings，修复进入独立生命周期并事务化落盘。
6. 已完成批次、失败角色和可信证据可以恢复，不因单个 Agent 失败整批重跑。

## 既有参考项目

| 来源 | 与审阅相关的设计 | 吸收判断 |
|---|---|---|
| `worldwonderer/oh-story-claudecode` | full/lean/solo，多视角 reviewer，批次继承伏笔与前批 findings | 保留多视角与统一 finding schema；不照搬默认 full 和整组失败后全量 solo 重跑 |
| `lingfengQAQ/webnovel-writer` | Context/Reviewer/Data Agent 分工，Chapter Commit，投影与重放 | 高价值；吸收可信提交、投影重放、作者友好报告，不复制 GPL 实现 |
| `ExplosiveCoderflome/AI-Novel-Writing-Assistant` | 自动导演、质量债务、角色资源账本、写法资产 | 吸收质量债务和角色事实/候选分离；不引入 LangGraph、provider 与前后端 |
| `penglonghuang/chinese-novelist-skill` | 中断续写、钩子方法、偏好记忆、自动校验 | 用于任务恢复和钩子覆盖，不作为大范围审阅执行器 |
| `leenbj/novel-creator-skill` | 多层一致性、知识图谱、大纲锚点、双审、P0 阻断 | 吸收分层一致性与硬阻断思想；避免为普通项目强制完整 RAG/图谱 |
| `wordflowlab/novel-writer-skills` | 创作宪法、情节/时间线/关系/世界追踪、七步流程 | 吸收审阅基准的来源层与结构化 tracking，不照搬多命令入口 |
| `junaid18183/novel-architect-skills` | 反思门、子类型创作宪法 | 用于报告后的保留/微调/重构决策，不承担证据扫描 |
| `op7418/humanizer-zh` | 可解释中文 AI 痕迹与改写维度 | 只作为文本风险信号；不能替代剧情、人性与连续性审阅 |
| `SillyTavern/SillyTavern` | Lorebook、动态触发、上下文排序和预算 | 吸收按人物、钩子、范围和证据动态注入，不把整本设定塞给每个 Agent |
| `wen1701/FanqieRankTracker` | 榜单、bookId、字体解码 | 与审阅执行无直接关系，仅用于平台数据和作品筛选 |
| `awesome-agent-skills` / `trending-skills` | skill 发现和趋势索引 | 只用于发现来源，不作为审阅架构证据 |

## 历史调研中的补充来源

| 来源 | 可借鉴点 | 边界 |
|---|---|---|
| `zy-zmc/tianming-skill` | 体检错误码、渐进加载、意图路由 | 借鉴稳定错误码，不复制大段协议 |
| `danjdewhurst/story-skills` | 跨 Agent 中立、CLI 校验 | 审阅计划和结果包应与 Claude/Codex/ZCode 解耦 |
| `dama-cyber/Distilled-Novel-Toolbox` | 商业化、平台合规、反 AI 门 | 平台 rubric 是审阅维度，不应压过故事逻辑 |
| `forsonny/The-Crucible-Writing-System` | 多线索、分阶段与多角色评审 | 借鉴线索交汇审查，不固定复制其角色数量 |
| `skyfiredao/dreampowers` | 中文网文铁律、伏笔追踪 | 规则作为 rubric，不做重复 prompt 堆叠 |
| `FlickeringLamp/ai-novelist` | savepoint/diff、多模型适配 | savepoint/diff 有价值；桌面 IDE 不属于 skill 范围 |

## 本轮新增 GitHub 来源

| 来源 | 观察 | 对本项目的启发 |
|---|---|---|
| `EdwardAThomson/NovelWriter` | 场景、章节、批次三级审阅，质量趋势与重试 | 把单章门、批次连续性和全局趋势分层，避免一份报告包办全部 |
| `ARMANDSnow/make-ur-Agent-writer` | mock-first、preflight、5+1 reviewer、fail-closed、逐调用成本账本、断点驱动 | 采用模拟验收、失败维度不放行、真实调用前预算与就绪检查；不照搬 5+1 固定规模 |
| `Narcooo/inkos` | 33 维审计、最多一次自动修订、快照、文件锁、状态 delta 校验、共享交互内核 | 维度覆盖可机器验证；修订次数有界；审阅、修订、写作保持原子操作 |
| `iLearn-Lab/NovelClaw` | 动态记忆优先的长篇协作框架 | 跨批只注入活跃人物、相关钩子和可信记忆，不使用全量历史上下文 |
| GitHub Spec Kit Fiction preset | 写前结构分析、写后连续性、局部修订、表面 polish 严格分离 | 审阅 findings 必须区分结构、连续性、文风；修复范围锁定，禁止扩大重写 |
| `mrigankad/Novel-OS` / `forsonny/book-os` | 多 Agent 编辑管线、分层上下文 | 可作为后续低频观察来源；当前核心思想已被上述高相关项目覆盖 |

## 对当前实现的直接诊断

1. `scripts/review-agent-dispatch-plan.js` 已按风险选择 Agent，但 `scripts/lib/review-batch-state.js` 仍给每批固定写入四 Agent，存在双权威冲突。
2. 当前批次默认固定 50 章，没有使用卷边界、剧情阶段、正文体量、风险密度和宿主上下文预算。
3. 当前跨批矩阵在 skill 文档中很完整，但缺少确定性结果包与完成门，模型可以声称已更新而文件不完整。
4. 当前 Agent 失败策略偏向整组降级 solo，会丢弃已完成角色的可信证据并增加重复成本。
5. 当前总报告主要依赖模型合并，缺少 findings 去重、冲突、覆盖率与证据范围的机器验收。
6. 当前修复事务已经独立，但审阅结果还需要更明确地生成可选修复队列和影响范围，避免从报告直接跳到大面积重写。

## 推荐架构

采用“自适应证据审阅”架构：

```text
范围合同
  -> 章节/设定证据图
  -> 动态叙事批次
  -> 每批最少必要 Agent
  -> 维度覆盖与结果包验收
  -> 相邻批边界核对
  -> 全局 findings 合并
  -> 独立修复工作流
```

作者只选择审阅目标和是否执行修复；批次大小、Agent 数量、重试与内部 full/lean 不应成为作者负担。

## 来源

- https://github.com/worldwonderer/oh-story-claudecode
- https://github.com/lingfengQAQ/webnovel-writer
- https://github.com/ExplosiveCoderflome/AI-Novel-Writing-Assistant
- https://github.com/EdwardAThomson/NovelWriter
- https://github.com/ARMANDSnow/make-ur-Agent-writer
- https://github.com/Narcooo/inkos
- https://github.com/iLearn-Lab/NovelClaw
- https://github.com/github/spec-kit/discussions/2211
- `docs/reference-projects.json`
- `docs/superpowers/specs/2026-06-09-story-skill-optimization-design.md`
