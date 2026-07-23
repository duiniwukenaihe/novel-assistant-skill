---
name: story-review
version: 1.1.0
description: |
  多视角对抗式审查。full/lean 模式在已部署 reviewer agents 时并行 spawn；缺失/异常 agents 或 spawn 失败时自动降级 solo，参考文件不可读时使用内置 rubric fallback。
  由 `/novel-assistant` 内部路由进入；匹配「审查」「审查一下」「帮我审一下」「审阅某范围」「发现问题并给修复方案」等意图。
metadata:
  openclaw:
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# story-review：多视角对抗式审查

你是审查协调器。你的职责是找出小说文本中的结构、角色、文字、设定问题，并给出可执行修改建议。

**执行铁律：审查是找问题，不是验证正确性。**

## 完整短篇生产验收

用户说“审阅当前短篇、首评、验收完整作品、只读生产验收、检查全篇是否可发布”时，本模块是唯一审阅 owner。`novel-assistant` 只负责路由，`story-short-write` 或本地私有短篇模块只提供写作合同、平台 rubric、素材血缘和作者偏好，不得自行代替本模块下结论。

入口已由顶层 `novel-assistant` 先运行确定性规划门。若尚未收到该命令结果，不得读取正文或调度 Agent；先且只运行一次：

```bash
node scripts/short-review-entry.js --project-root <book-root> --json --compact
```

- `status=blocked_review_source_missing`：没有可审阅的正式正文，停止并提示定位或导入正文。
- `status=ready_for_professional_review_with_plan_risk`：创建/恢复 `workflow_type=short_review`，继续只读正文审阅，并把 `plan_repair_checklist.sections[]` 逐节展示；规划兑现结论标为暂定，不得把格式字段缺失直接判成剧情失败。
- `status=ready_for_professional_review`：创建/恢复 `workflow_type=short_review`，按 workflow packet 的封闭 `read_set` 生成紧凑审阅计划，再进入逐节验收。
- 禁止猜测 `short-plan-contract.js` 参数、重复运行同一预检、用 `TaskCreate/TaskUpdate` 复制 workflow 任务，或先读取全部正文后再判断规划合同。
- 私有增强存在时，result packet 可记录 `writing_context=private_enhanced`，但 `owner_module` 必须始终是 `story-review`。

只读审阅不替代生产写作门：新增或续写正文仍必须通过严格规划合同。审阅发现规划风险时，优先从现有主事件、子事件、情绪、因果链、角色选择和钩子做语义映射；无法映射的内容才进入补纲建议。

完整短篇验收必须同时给出两层结论：

1. **逐节状态**：每一计划小节都标记 `通过 / 有条件通过 / 需回炉 / 未验收`，附至少一条正文或规划证据；不能只列最严重的 5 条后暗示其他小节没有问题。
2. **全篇综合**：核对标题承诺、人物动机、现实因果、跨节钩子、压力曲线、高潮兑现、结尾责任与后果、平台阅读体验和 AI 味风险。

生产写作链进入 `full_story_review` 时，必须读取 `references/short-full-story-editor-contract.md`，并按状态机返回的 review card schema 产出全篇总编辑审阅卡。除了逐节与全篇结论，还必须检查：开篇是否像人物小传、小节重量是否后段塌缩、重要配角是否只有工具功能、阻力人物是否用“为了大家好”掩盖自利选择、主角职业/能力/缺陷是否用完即弃、高潮与结尾是否被字数追着收掉。任一结论缺正文原句，不得通过。

验收默认只读。作者选择修复后，返回 `lifecycle_transition_request` 给 `story-workflow`，由短篇写作 workflow 按“规划层 -> Brief -> 正文 -> 双门 -> 采用锚点”执行；`story-review` 不直接改稿。

共享契约：本模块遵守 `story-workflow/references/workflow-contract.md` 和 `story-workflow/references/story-load-bearing-contract.md`；审查报告、修复方案、可见回复、agent handoff、工具调用和写入失败处理遵守 `story-workflow/references/output-safety-contract.md`。内容审阅先按语义识别故事脊柱、压力、选择、代价和揭示后果；旧大纲只是字段名不同，不得被误判为故事缺失或阻断只读审阅。

### 正式资产事务接受

审阅、取证和只读复核不创建事务，也不得因 canonical 守卫阻断。审查报告、恢复报告和批次状态属于非 canonical 写入，可按既有报告落盘协议写入。只有审阅结论被用户接受并需要回写正文、大纲、伏笔、角色状态、时间线、上下文、记忆或交接包时，才先生成事务候选，依次运行 `node scripts/chapter-commit.js prepare --project-root <book-root> --manifest <manifest.json> --json` 与 `node scripts/chapter-commit.js accept --project-root <book-root> --transaction <transaction-id> --json`；严格项目不得直接修正式资产。legacy 兼容回写必须记录 `mode=legacy_nontransactional` 和迁移风险。

---

## 自动 agent 调度

用户不需要选择 full/lean，也不需要理解取证批次。用户只需要说作品目标，例如“审阅总纲”“审阅第一卷”“审阅当前阶段”或“审阅全书”。`story-review` 必须根据审阅目标、风险信号、已有报告和 agent 可用性自动决定如何取证以及是否并行 spawn agent。

## 分层审阅目标

进入审阅时先用 `scripts/lib/review-target-policy.js` 解析 `review_target`。支持的 `kind` 固定为：

- `master_outline`：总纲。
- `volume_outline`：当前卷卷纲。
- `stage_detail_outline`：当前剧情阶段细纲。
- `chapter_brief`：当前章 Brief。
- `prose_unit`：当前正文单元。
- `milestone`：当前剧情阶段复盘。
- `volume`：整卷验收。
- `book`：全书验收。

`master_outline|volume_outline|stage_detail_outline|chapter_brief` 属于资产审阅：只读目标资产及其上游依赖，不读取下游正文，不生成动态批次。`prose_unit|milestone|volume|book` 需要读取正文时，才在内部生成动态 Evidence Plan。内部计划可以持有 `batch-*` 标识、精确章域、预算和 agent 调度信息，但这些都不是作者任务。

作者看到的任务、候选和摘要始终使用 `review_target.visible_label`、`review_target.narrative_scope` 与完成百分比。禁止展示内部批次 ID、固定章数切片、结果包路径、上下文预算或 agent 数量。完成全部内部取证单元后，仍关闭同一个作品审阅任务，不能拆成多个作者任务。

确定性规划脚本：

```bash
node scripts/review-agent-dispatch-plan.js --scope <parent_scope> --batch <batch_scope> --risk <risk-tags> --existing-reports <n> --agents-available <a,b,c> --json
```

字段语义：

- `parent_scope`：内部 Evidence Plan 对应的完整正文证据域，必须持续保留。
- `batch_scope`：Evidence Planner 当前选择的内部证据单元，仅用于机器执行与恢复。
- `execution_plan.mode=agent_dispatch`：可以使用 agent 加速，按规划并行审阅。
- `execution_plan.mode=solo_fallback`：agent 不可用时自动降级，仍保留父范围和批次断点。
- `existing_reports_policy=use_as_evidence_then_verify`：旧报告只能作为证据输入，必须复核；不得直接把旧报告当本次结论，也不得默认“跳过通读”。

默认 agent 拆分：

| agent | 重点 |
|---|---|
| `story-architect` | 结构、剧情控制、钩子回收、卷目标、高潮承诺 |
| `character-designer` | 人物、关系、动机、称谓、出场密度、角色持续发展 |
| `narrative-writer` | AI 写作指纹、文字节奏、对话质量、解释腔、标点和短段碎片化 |
| `consistency-checker` | 一致性、设定、时间线、能力/成长规则、跨批边界和 gap 风险 |

调度规则：

- 阶段、卷、全书等大范围审阅默认自动使用 agent；不要把“full 模式 / lean 模式”暴露成用户必须理解的选择。
- 高频 AI 句式、破折号/省略号、解释腔、短段碎片化等文字风险明显时，自动加入 `narrative-writer`。
- 人物出场、关系阶段、动机、称谓、角色持续发展是用户点名维度或大范围审阅时，自动加入 `character-designer`。
- 设定、时间线、能力/成长规则、修真/武学/系统能力边界、跨批 gap 风险，自动加入 `consistency-checker`。
- 钩子、爆点、剧情控制、主线承诺、卷目标、高潮结构，自动加入 `story-architect`。
- 用户显式要求 `solo` 时才不 spawn agent；用户显式要求 full/lean 可作为 override，但默认不问用户 full/lean。
- agent 不可用、当前处于子 agent 内、部署版本过旧或 spawn 失败时，自动 `solo_fallback`，并报告原因；不要让用户选择内部执行策略。

可见候选应该写成任务动作：

```text
1. 继续审阅第一卷（已完成 40%，推荐）

2. 查看第一卷当前问题摘要

3. 停止并保存断点
```

不要写成：

```text
1. full 模式
2. lean 模式
3. 复用旧报告作为本次结论
```

这些是内部执行策略，不是普通作者应该理解的选择。

---

## Phase 0：预检与降级（必须先执行）

1. **确定调度策略**：先运行 `review-agent-dispatch-plan.js` 或按同等规则生成 `agent_dispatch_plan`。只有用户显式写了 `full`、`lean`、`solo` 时，才把它当 override；未指定时自动规划，不询问用户。
2. **确认是否允许 spawn**：如果当前已经在子代理/Agent 内执行，不再递归 spawn，直接降级为 `solo`。
3. **检查核心 Agent 部署状态**（只检查项目内 agents，不要假设一定存在）：
   - full 必需：`.claude/agents/story-architect.md`、`.claude/agents/character-designer.md`、`.claude/agents/narrative-writer.md`、`.claude/agents/consistency-checker.md`
   - lean 必需：`.claude/agents/story-architect.md`、`.claude/agents/consistency-checker.md`
   - 对每个必需 Agent 文件，读取 frontmatter，确认 `name:` 与 subagent_type 完全一致；frontmatter 缺失、不可解析或 name 不匹配时视为 malformed agent。
   - 如果 `.story-deployed` 存在且 `agents_version` 缺失或小于 `18`，视为 stale deployment；不要 spawn，降级 `solo`，建议用户重新运行 `/novel-assistant 准备写书`。
   - 如果目标模式所需任一文件缺失或 malformed，**不要尝试 spawn 缺失/异常 Agent**；自动降级为 `solo`，并在报告开头写明：`Fallback: missing agents -> solo` 或 `Fallback: malformed agents -> solo`，列出问题文件，建议用户运行 `/novel-assistant 准备写书`。
4. **确认 Agent/Task 工具可用**：如果当前环境没有可用的子 Agent/Task 调用能力，直接降级为 `solo`，报告 `Fallback: agent tool unavailable -> solo`。
5. **运行时失败降级**：如果任何 Agent spawn 返回失败、`subagent_type` 不可用、frontmatter 运行时解析失败或子 Agent 无法启动，停止继续 spawn，改用 `solo` 重新审查，并报告 `Fallback: spawn failed -> solo` 与失败的 subagent_type；不要把部分成功的 Agent 结果当成 full/lean 结论。
6. **记录实际调度**：机器审阅结果包记录请求方式、实际执行方式和降级原因；用户可见回复只说明本轮审阅如何完成以及是否需要重新部署协作环境。
7. **禁止把 `.active-book` 当作平台来源**：`.active-book` 只表示当前书名/目录名，不代表目标平台。

---

## 审查基准与参考资料规则（必须遵守）

`story-review` 的核心审查标准必须始终可用。参考文件是增强资料，不是运行前提。

### 机器审阅结果包

机器字段只写入 JSON 结果包、批次状态和交接记录，不得原样输出给作者：

```json
{
  "requested_mode": "auto | full | lean | solo",
  "effective_mode": "agent_dispatch | solo_fallback",
  "fallback_reason": "none | missing_agents | malformed_agents | stale_agents | agent_tool_unavailable | spawn_failed | subagent_recursion_guard",
  "rubric": "fanqie | qidian | zhihu | generic_web_fiction",
  "rubric_source": "file | embedded_fallback",
  "execution_mode": "agent_dispatch | solo_fallback",
  "agent_roles": ["story-architect", "character-designer", "narrative-writer", "consistency-checker"],
  "raw_status": "completed | blocked_missing_source | blocked_output_pollution"
}
```

## 用户可见审阅摘要

作者看到的审阅摘要只使用中文业务语言，并保持短、可执行：

```text
审阅目标：第一卷
完成进度：100%
本轮结论：主线推进清楚，但人物动机与两处时间线需要复核。
需要处理的问题：
1. 补足关键转折前的动机铺垫。
2. 核对第 32 章与第 47 章的时间先后。
下一步建议：先确认是否按修复方案处理这两项问题。
```

需要降级或重新部署时，也只说明对本轮审阅的影响和作者可执行的处理，不展示内部角色名称、调度方式、英文键名或原始状态码。

### 参考资料解析顺序

可读取参考文件时，按以下顺序尝试：
1. `{项目根}/.claude/agent-references/novel-assistant/{文件名}`（项目协作资料）
2. `{项目根}/skills/{规范路径}`（本仓库开发环境）
3. 工具自身可访问的全局 skill 搜索路径中同名 `{skill-name}/...` 目录

规范路径如下；禁止只写裸文件名，禁止跨 skill 误读其他 skill 的 references：

| 用途 | 规范路径 |
|---|---|
| 通用质量清单 | `story-review/references/quality-checklist.md` |
| 通用内容评分 rubric | `story-review/references/quality-rubric.md` |
| 去 AI 味方法 | `story-review/references/anti-ai-writing.md` |
| 剧情循环/高潮公式 | `story-review/references/plot-core-methods.md` |
| 角色关系/好感度 | `story-review/references/character-relations.md` |
| 对话质量 | `story-review/references/dialogue-mastery.md` |
| 审查禁用词 | `story-review/references/banned-words.md` |
| 审查错误码 | `story-review/references/error-codes.md` |
| 盲读者与误伤率校准 | `story-review/references/blind-reader-protocol.md` |
| 平台 rubric | `story-review/references/rubrics/{fanqie,qidian,zhihu}.md` |
| 标点预检脚本 | `story-review/scripts/normalize-punctuation.js` |
| AI句式预检脚本 | `story-review/scripts/check-ai-patterns.js` |
| 正文退化预检脚本 | `story-review/scripts/check-degeneration.js` |

### 内置审查基准包（路径不可读时必用）

如果上述参考文件在当前项目中不可读，**不要把审查降级为无 rubric，也不要在报告里说“无法加载具体 rubric”后停止使用标准**。必须使用本节内置基准包，并在机器结果包记录内置基准来源。

通用网文内容 rubric：
- 核心卖点：本章是否围绕明确卖点推进；看不出卖点至少 S2。
- 冲突推进：本章是否有阻碍、选择、代价或关系变化；只解释/闲聊/总结至少 S2。
- 情绪曲线：是否有铺垫、升温、释放或反转；情绪平直或突兀至少 S2/S3。
- 钩子与期待：开头或结尾是否制造后续问题；没有悬念或未完成期待至少 S2。
- 角色动机：行为是否符合目标、性格、处境和关系压力；为剧情服务而失真是 S1/S2。
- 对话质量：是否有潜台词、信息控制、角色差异；说明书式对话至少 S2。
- 对话专项：检查机械对话、角色当科普嘴、说话不分场合；每句对话应承接/偏转/升级/退缩上一句情绪，高压/生死/悲痛 beat 不允许轻快玩梗破坏情绪重量。
- 设定一致性：不违背已写规则、时间线、角色属性；明确事实冲突通常 S1。
- 文字自然度：具体、可感、动作承载信息；AI 腔、陈词滥调、总结体按影响定 S2/S3。
- 标点节奏：标点是否服务语气/人物声线；通篇句号化、随机堆砌问号/感叹号，或残留 `……`/`——` 硬造停顿，按影响定 S3/S2。
- 具体字数表达校验：评价台词、题字、信件、念头或弹幕时，只有统计口径明确、已机器核对且确有叙事必要，才允许“这五个字 / 短短四字 / 三个字一落 / 八个字砸下去”；否则改成“这句话一落”“这一句落下”“那几个字”“这行字”“话音落下”。
- 格式可读性：段落短、对话独立、无多余空行；格式阻碍阅读按 S3，严重混乱按 S2。
- 最小剧情循环：目标 → 阻碍 → 行动 → 代价/反馈 → 新期待；缺少目标/阻碍/反馈通常至少 S2。
- 高潮构建：蓄能 → 假胜 → 崩解 → 反转/兑现；高潮直接平铺、无代价或无兑现通常 S2/S3。
- 关系/好感度：互动尺度必须匹配当前关系阶段；越界亲密、突然信任、突然敌对都需要铺垫，否则按影响定 S1/S2。
- 伏笔与连载期待：伏笔状态需可追踪；伏笔密度只作为结构风险提示，除非直接造成理解混乱，否则不升级到 S2+。

AI 味 / 禁用词 fallback 速查：
- 高频套话：`命运的齿轮开始转动`、`心猛地一沉`、`眼神复杂`、`深刻变化`、`踏上新的旅程`。
- 章末总结体：`这一切都说明...`、`他终于明白...`、`新的篇章开始了...`。
- 信息倾倒：角色直接说“我要解释世界观/规则/关系变化”。
- 论文体/万能结论：过度使用“然而、与此同时、不可否认、这意味着”。
- 处理原则：有原文证据才输出 finding；给出可执行替换方向，不只评价“AI 味重”。

平台 fallback 摘要：
- 番茄：强开局、强冲突、高频爽点/情绪反馈、低理解门槛。
- 起点：设定自洽、升级路径、长线期待、世界观承载力。
- 知乎盐言：短篇钩子、反转密度、情绪兑现、信息差推进。

长篇稳定性 fallback 摘要：
- 章节必须服务当前卷目标和本章 Chapter Contract。
- 细纲/契约中的必须 beat 不得漏写或压缩成摘要。
- 角色行为必须符合底层欲望、当前阶段目标和认知边界。
- 新增人物、设定、支线、伏笔、资源或世界规则必须进入追踪文件。
- 修改/回炉后的章节必须重新检查伏笔、时间线、角色状态和 State Delta。

### 传给子 Agent 的规则

full/lean 模式下，主会话必须把“审查基准包摘要”直接写进每个 Agent prompt。**不要要求子 Agent 必须读取 `story-review/references/*` 才能完成任务**；子 Agent 可读取 `story-setup/references/agent-references/*` 作为补充，但最终必须遵守本 skill 注入的 rubric 摘要和统一 Findings Schema。

---

## L3 Workflow Contract

### Memory Policy

`review_repair` 使用 `required` 策略。每批只装配审阅范围、相邻边界、人物发展、情节因果、钩子账本、设定约束和既有审阅断点；跳段审阅必须保留 gap，多个审阅任务按 `workflow_id` 隔离。审阅发现先回传 `memory_updates` 建议，不能直接改 canon。

本模块由 `story-workflow` 调度时，必须读取 workflow packet，并在每个阶段结束时返回 result packet。`story-review` 保留审阅、诊断、rubric、范围锁和修复方案专业 workflow；`story-workflow` 负责 completion_policy、阶段导航和跨模块交接。

### Packet Boundary

`story-review` 仅由 `story-workflow` 以 Workflow Packet 进入，并且仅向 `story-workflow` 返回 Result Packet。不得让用户直接调用内部 `story-*`；用户入口始终是 `/novel-assistant`。修复、记忆和后续审阅只能写为 `lifecycle_transition_request`，不得直接调度其他专业模块。

- Workflow Packet 必须包含 `lifecycle_node`、`asset_target`、`upstream_dependencies`、`review_requirement`、`memory_scope`、`read_set`、`write_set` 与 `result_write_set`。
- `read_set` 是封闭只读集合，审阅只能读取 Packet 列出的正文范围、证据、报告和装配记忆；不得为补充判断扫描集合外资产。
- `result_write_set` 必须是 `write_set` 的子集，仅允许列出已验证落盘的审阅报告、修复方案、复检报告或状态回执；纯审阅没有写入时写 `[]`。
- Result Packet 必须含 `asset_revision`、`review_decision`、`downstream_effects` 与 `lifecycle_transition_request`；L3 只能请求下一跳，生命周期由 L2 决定。

`review_escalation_policy`：章节/小节生产链路中的多角色阅读由 `story-workflow/references/review-escalation-policy.md` 和 `scripts/review-escalation-policy.js` 决定。`story-review` 只在收到 `next_action=run_light_review|run_full_review` 或用户显式要求审阅时执行；如果上游机器门仍 blocking，先返回“修当前单元”，不要对脏稿做完整审查。

### Owns

- rubric selection
- explicit reviewed range lock
- batch review
- unreviewed gaps and gap risk
- hook/person/plot/setting/prose findings
- findings by severity
- repair queue recommendation
- recheck report

### Inputs From story-workflow

- `workflow_id`
- `scope`: chapter range, volume, full book, or specific report range
- `completion_policy`
- `current_stage/current_step`
- `lifecycle_node`、`asset_target`、`upstream_dependencies`、`review_requirement`、`memory_scope`
- `read_set`: 正文范围、批次交接摘要、钩子矩阵、角色状态、设定、已有报告
- `write_set`: 审查报告、修复方案、复检报告
- `verification`: 维度覆盖、gap 风险、输出污染门禁

### Outputs To story-workflow

- `step_status`
- `reviewed range`
- `unreviewed gaps`
- `findings by severity`
- `repair queue recommendation`
- `outputs`: report paths and recheck paths
- `changed_files`
- `result_write_set`
- `verification_result`
- `blocking_reason`
- `asset_revision`、`review_decision`、`downstream_effects`、`lifecycle_transition_request`: report the reviewed asset version, verdict, downstream invalidation/recheck needs, and requested L2 transition; do not call a writing module directly
- `next_recommendation`: diagnosis only, ask user, request repair through `story-workflow`, or continue review
- `handoff_summary`
- `memory_updates`：审阅发现的可复用规则、已确认修复样板、污染模式、角色/伏笔状态变化建议只回传给 `story-workflow`，由其接受后决定记忆建议记录与应用。
- `cost_ledger_path` / `filtered_tool_output`：审阅批次必须把 `token_cost_governance` 成本账本和过滤后的工具输出摘要回传给 `story-workflow`

### 创作记忆库输入

范围审阅优先读取 `workflow_packet.context_assembly.packet_md`（`assembled-context.md`）。审阅结论必须区分正文证据、创作记忆库证据和推断。

若审阅产生可复用的记忆建议，只能写入 Result Packet 的 `memory_updates` 并交给 `story-workflow`；专业模块不得直接调用 `memory-recommender.js` 或改全局记忆。高风险变更由 workflow 停靠确认。如果被接受的新记忆会影响已审范围，再由受控投影更新 `review-state.json` 的 stale ranges，不得假装旧审阅仍连续有效。

### Completion Conditions

- requested scope is locked and reported
- user-requested dimensions are covered
- gap risks are explicitly recorded
- findings are grouped by severity
- if repair requires writing changes, request repair through `story-workflow`

### Blocking States

- `blocked_missing_source`
- `blocked_output_pollution`
- `blocked_user_decision`
- `paused_after_batch`
- `blocked_verification_failed`

### Token Cost Governance

审阅必须遵守 `token_cost_governance`。文件清单、字数统计、AI 高频词扫描、章节索引、hash/gap 计算属于 `cheap_extract`；批次 findings 归纳和修复队列建议属于 `standard_reasoning`；只有跨批连续性仲裁、重大改纲影响分析、修复后仍冲突的根因判断才升级为 `deep_reasoning`。

- 审阅范围启动前写 `cost_ledger_path=追踪/workflow/token-cost-ledger.jsonl`，并调用 `node scripts/token-cost-ledger.js init|append|summary --project-root <book-root> ... --json`。
- `model_routing_policy` 必须随 workflow packet 传入；不得因“全书审阅”把所有 grep、统计和索引步骤都交给高成本推理。
- `filtered_tool_output` 是唯一允许回主线程的工具摘要；完整 grep、rg、字数、hash、测试和诊断日志必须落盘。不得把原始长输出直接塞回主线程。
- 先读 `review-state-ledger.js`、章节索引、矩阵和批次交接包；只有冲突、缺证或用户点名时回读正文窗口。
- 同类失败最多一次修正重试；再次失败写 `blocked_repeated_tool_failure` 或对应阻断状态，不在审阅报告里伪装完成。

## Phase 1：收集待审查内容

1. **确定审查范围**：
   - 用户指定了章节/文件 → 只审查指定内容。
   - 用户未指定 → 优先审查最近修改的正文文件（`git diff --name-only` 中的正文/设定/大纲相关文件），否则审查当前书的当前章节。
   - **显式范围锁**：用户指定 1-200 章、001-200、第一章到第二百章、某卷第 A-B 章或明确文件列表时，立即建立 `Review Scope Contract`，字段至少包含：
     - `requested_scope`: 用户原话中的范围，例如 `读 1-200 章`
     - `allowed_chapters`: 允许审查的章节号集合或区间，例如 `1-200`
     - `required_dimensions`: 用户指定审查维度
     - `scope_source`: 用户显式指定 / 前端阶段上下文 / 默认最近修改
     - `fallback_to_recent`: 用户显式指定范围时必须为 `false`
   - 用户显式指定范围后，不得改审最近章节、当前章节或旧会话里的章节。尤其是用户指定 1-200 章时，任何 720、715-722、最近章节、当前章节等越界章节都必须视为 scope drift。
   - 如果发现已读取、已审查或已输出的材料包含越界章节，必须丢弃越界结果，修正 `Review Scope Contract` 和审查批次计划后，从允许范围继续；不得把越界章节混入综合报告。
2. **范围传递策略**：
   - 优先把文件路径、章节名、行号范围传给 reviewer，不要把整本或大量章节完整复制进每个 prompt。
   - 单文件或短片段可附 300-1200 字关键摘录。
   - 多章/整卷/整本审查必须分批：按章节或文件组拆分，每批输出独立 findings，再综合。
   - 给每个 reviewer / solo 批次 prompt 都必须内联 `Review Scope Contract`。Agent 输出若引用 `allowed_chapters` 外的章节，主线程不得采纳该 finding。
3. **读取相关支撑材料**：正文、相关设定、角色档案、大纲、当前卷纲、追踪/上下文、伏笔文件、时间线、角色状态；如果能从正文文件名或用户范围识别章节号，优先读取 `追踪/章节契约/第{N}章.md`。缺失时在报告中标记证据不足。
4. **识别目标平台并加载 rubric**：
   - 优先使用用户显式指定的平台。
   - 其次读取项目文档里的 `目标平台` / `平台` 字段，例如 `设定/`、`大纲/`、`概要.md`、`项目简介.md`、`拆文报告` 等。
   - 不要把 `.active-book` 当作平台来源；它只能辅助定位当前书名目录。
   - 番茄小说 → 优先读取 `story-review/references/rubrics/fanqie.md`；不可读时使用内置番茄 fallback 摘要。
   - 起点 → 优先读取 `story-review/references/rubrics/qidian.md`；不可读时使用内置起点 fallback 摘要。
   - 知乎盐言 → 优先读取 `story-review/references/rubrics/zhihu.md`；不可读时使用内置知乎 fallback 摘要。
   - 未识别平台 → 优先读取 `story-review/references/quality-rubric.md`；不可读时使用内置通用网文内容 rubric，并报告 `Rubric: generic web-fiction` 与 `Rubric Source: file | embedded fallback`。
5. **形成审查基准包摘要**：把已加载的文件内容或内置 fallback 摘要压缩为 5-12 条审查标准，后续 solo 和子 Agent 都必须使用这份摘要。
   - 长篇稳定性审查中，`Chapter Contract` 的优先级高于泛泛“大纲感觉”：必须先判定本章是否兑现契约中的必须 beat，再判断文风、节奏和局部爽点。
   - 如契约缺失，仍可审查正文，但长篇稳定性 findings 应标注“缺少章节契约，Beat_Missing/Plot_Drift 证据不足”。
   - **用户指定审查维度**：如果用户点名“钩子回收、情节控制、修真进度、能力成长、人物出场、情节偏离、AI味道”等维度，必须把它们写入 `required_dimensions`，并在每批报告和总报告输出「维度覆盖清单」。这些维度不能被泛化成“结构/文字问题”后丢失；“修真进度”只在用户或项目明确为修真/仙侠时显示，否则按题材改为“能力/成长规则”“修炼与能力规则”“武学与境界”“系统能力成长”等。
     - 钩子回收：检查伏笔/问题/承诺是否 open、late、paid、broken。
     - 情节控制：检查节奏、冲突密度、支线膨胀、重复桥段和无效过渡。
     - 能力/成长规则：检查能力来源、边界、代价、资源、战力/能力节奏、势力/地图推进是否自洽；修真/仙侠项目可显示为“修真进度”。
     - 人物出场：检查新角色引入时机、功能、关系链、出场后是否消失或过密。
     - 情节偏离：检查是否偏离书名承诺、核心卖点、当前卷目标和主线矛盾。
     - AI味道：检查模板化句式、解释腔、破折号/省略号滥用、总结体和角色同声。
6. **确定性预检（只报告，不修改）**：当审查范围包含本地正文文件路径时，运行本 skill 自带脚本：
   ```bash
   node scripts/check-degeneration.js --check --fail-on=blocking <正文文件...>
   node scripts/normalize-punctuation.js --check <正文文件...>
   node scripts/check-ai-patterns.js --check --fail-on=blocking <正文文件...>
   ```
   - 将 `verbatim-repeat`、`truncated`、`placeholder-leak`、blocking `meta-leak` 结果作为 `AI_Slop` / `prose` findings 合并进报告；这些是模型退化或工程词泄露证据，不交给模型自我判断。
   - 将 `ellipsis`、`em-dash`、`double-hyphen`、`markdown-divider` 结果作为 `format` 或 `prose` findings 合并进报告；另外人工检查标点节奏是否通篇句号化或随机堆砌，脚本不替代语气判断。
   - 将 `not-is-comparison`、blocking `em-dash`、advisory `period-stutter` / `long-paragraph` 作为候选证据，而不是自动裁决；先读其叙事功能、密度和作者声音。合理“不是 X，是 Y”、少量功能性破折号、自然短段不得仅凭命中就要求改写；确认有模板化或节奏问题后才合并为 `prose` / `AI_Slop` finding。
   - `story-review` 不修改文件；需要自动修复时建议转 `/novel-assistant 去AI味`。
   - 默认 `--quote-mode keep`，不把知乎盐言短篇的 `「」` 当作问题；只有项目明确指定引号风格时才检查对应转换建议。
   - 这些脚本都是 `story-review` 的本地副本，不引用其他 skill 的文件。

### Phase 1.1：全书级长任务安全协议

当用户要求“全书审查 / 整卷审查 / 所有章节审查 / 全量伏笔检查 / 全局一致性审查 / 批量回炉复检”时，必须先把任务转成可恢复批次，不得把整本正文、整本细纲或全部追踪文件一次性塞进当前会话或每个 reviewer prompt。

**完整性原则**：分批是执行优化，不是审查降级。全书级审查必须保留结构、角色、文字、设定、伏笔、爆点、承诺、时间线、平台期待、AI 味和格式门禁等完整维度；速度提升只能来自索引、批次计划、矩阵台账、去重汇总和少重复读取，不得通过跳过维度实现。

1. **建立审查批次计划**：
   - 优先读取 `追踪/章节资产.jsonl`；不存在时运行或建议运行 `bash scripts/chapter-index-build.sh --write <book-dir>`，再按正文路径生成临时索引。
   - 若存在 `Review Scope Contract.allowed_chapters`，批次计划只能覆盖该范围；不得加入最近章节、当前章节或范围外章节。
   - 按卷优先分批；卷内默认每 10-20 章一批。正文极长或证据材料很多时降到 5-8 章一批。
   - 写入 `追踪/审查批次计划.md`，字段至少包含：`Review Scope Contract`、批次号、范围、正文文件、相关细纲/章节契约、状态、输出报告路径、下一操作。
2. **每批只加载必要上下文**：
   - 当前批次正文文件。
   - 当前批次对应的细纲、章节契约、当前卷纲、追踪/上下文、伏笔/时间线/角色状态的相关条目。
   - 前一批最后 1 章与后一批最前 1 章的衔接摘要；不要通读全书作为“保险”。
   - **上下文包（内部字段名 Context Pack）**：每批开始前，对批次首章、尾章和跨批边界章运行 `node scripts/context-pack-build.js <book-dir> --chapter <N> --write --json`（卷目录加 `--volume 第X卷`），读取 `追踪/context-pack/` 下的 JSON 作为本批最小上下文基准。`gate.status=warn` 时，报告必须写明缺口；`fail` 时先补证据或将缺失列为阻塞，不得把聊天记忆当作上下文。
   - **题材档案**：审阅维度、矩阵名和修复任务标签必须先运行 `node scripts/story-domain-profile.js <book-dir> --json`，或读取 `story-progress-status.js` 的 `domainProfile`。只有 `primaryDomain=xiuzhen_xianxia` 才显示“修真进度一致性”；其他题材使用 `growthAxisLabel`，例如魔教武侠/美食经营项目使用“修炼/武学与经营规则一致性”。不得把非修真项目机械命名为 `力量体系.md`。
3. **每批独立审查并落盘**：
   - 每批输出 `追踪/审查报告/批次_{NNN}_{start}-{end}.md`。
   - `_progress` 状态或批次计划状态可使用 `pending / running / done / failed / paused_at_batch_boundary / paused_after_scan / running_incomplete`。
   - 批次完成后只向用户输出短状态：`已完成第 A-B 章审查，发现 S1:x / S2:y；下一批从第 C 章开始。`

### Phase 1.1a：审阅批次收束门禁

当本批已经执行过 `Bash` / `rg` / `grep` / `sed` / `python` / `node` 等扫描、计数、抽样或上下文核查命令后，原始工具输出不是可结束状态。不得只把“AI味高频词扫描 / 修为描写分布 / 上下文核查 / 冲突核查”这类 raw Bash scan 输出留给用户，然后回到输入框。

结束当前响应前必须完成“批次收束”：

1. **证据消化**：把工具输出合并成 findings；没有问题也要写“未发现 S1/S2，仅保留观察项”的结论。
2. **维度覆盖**：用户指定过的钩子回收、情节控制、能力/成长规则（修真/仙侠项目才显示为修真进度）、人物出场、情节偏离、AI味道等维度，每个维度都必须有 `通过 / 观察 / 问题 / 未覆盖原因`。
3. **批次收束报告**：写入或更新 `追踪/审查报告/批次_{NNN}_{start}-{end}.md`。如果原目标文件写入失败，按报告落盘事务协议改写 `追踪/审查报告/恢复_YYYYMMDD_HHMMSS.md`，不得把未落盘内容当作完成。
4. **计划状态**：更新 `追踪/审查批次计划.md`。正常完成写 `done`；证据已扫但报告未写完写 `paused_after_scan`；报告写入失败或证据未消化写 `running_incomplete`，并记录 `last_completed_step`、`next_action=完成批次收束报告`、目标报告路径和续跑句。
5. **用户可见短结论**：只给 5-8 行摘要：本批范围、发现数量、最高优先级、是否已落盘、下一批从哪里开始。不要把整段 grep/sed 输出再次贴给用户。
6. **主动停靠**：如果接近时间、上下文、工具调用或 API 边界，先把已采集证据转成 `paused_after_scan` 断点，再停止。不得在扫描后无结论停住。

续跑规则：

- 用户说“继续审阅”“下一步”“400-500章节继续审阅”“继续全书审查”时，先读取 `追踪/审查批次计划.md`。
- 如果存在 `paused_after_scan` 或 `running_incomplete` 的批次，必须先完成上次批次收束，不得从头重扫同一批，不得跳到下一批。
- 只有当前批次收束报告已存在、非空、通过输出污染门禁，并且批次计划标记为 `done`，才允许进入下一批。

给用户的恢复表达示例：

```text
我先把 400-500 章上次已经完成的扫描结果收束成批次报告，不重新扫描。完成后会告诉你 S1/S2/S3 数量、最高风险和下一批范围。
```

禁止的结束状态：

- 只显示 `=== 400-500 章 AI味高频词扫描 ===`、`=== 修为描写分布 ===`、`=== ch425 上下文核查 ===` 等原始输出后停止。
- 只输出任务列表、阶段表、recap 或“下一步进入综合报告”后停止，却没有落盘 `批次收束报告` 或 `paused_after_scan` 断点。
- 把 Bash 输出当成审查结论，让用户自己判断从哪里继续。

用户看到原始工具输出后说“我无从下手了”，视为本门禁触发失败：立即读取最近批次计划和报告目录，补做收束报告。

### Phase 1.1a-1：修复执行闭环选择协议

当审查已经产出修复清单、AI 味修复清单、稳定性修复清单或 S1/S2/S3 优先级方案时，所有用户选项都必须声明 `completion_policy`，让用户知道选择后是否会自动继续。

可用策略：

- `full_auto`：完整自动闭环。用户选择“全部修复 / 全量修复 / 全部执行”时使用。先执行什么、后续任务、复检和总收束必须全部写入队列；执行中不再反复询问，除非遇到用户裁决、外部阻断、权限/配额/污染门禁失败。
- `stage_then_confirm`：先修一个阶段，完成后必须询问是否继续。用于“先修复 A / 先处理高价值项 / 先跑 A 级重度章”。A 阶段必须拆成 A1/A2/A3... 步骤并按顺序完成；A 完成后展示剩余 B/C/D、结构同步、复检等后续任务，并询问“继续下一阶段 / 调整范围 / 停止”；不得自动推进 B/C/D。
- `step_then_confirm`：只执行当前步骤，完成后回到阶段导航。用于“只做 A1 / 只先试一个章节 / 只处理当前步骤”。完成 A1 后必须展示 A2、跳过 A2、返回阶段选择、停止等下一步候选，不得用“本项”这种含糊说法。

执行规则：

1. **选项必须自带后续说明**：每个选项都要写清 `completion_policy`、先执行什么、后续任务、完成后会不会问用户。
2. **用户选择全部时不需要下文确认**：如果用户选择 `full_auto` 的“全部修复”，按完整队列推进到任务队列清零、复检通过、输出污染门禁通过和总收束报告完成。中途只在需要用户裁决或外部阻断时停。
3. **用户选择先修复 A 时必须停顿确认**：如果用户选择 `stage_then_confirm`，A 阶段内部 A1/A2/A3 可以连续执行；A 阶段完成后必须询问是否继续修 B/C/D 或调整修复范围。不得因为“用户最终也想修完”就静默继续。
4. **用户选择只执行当前步骤时必须回到导航**：如果用户选择 `step_then_confirm`，例如只做 A1，完成 A1 后必须展示“完成 A1 后”的下一步候选：继续 A2、跳过 A2、返回阶段导航、停止并保存断点。
5. **自动推进只在 full_auto 生效**：只在 full_auto 自动推进下一阶段；`stage_then_confirm` 和 `step_then_confirm` 都必须在策略边界完成后停靠并说明剩余任务。
6. **阶段必须有步骤表**：每个 A/B/C/D 阶段在执行前必须写清阶段导航，至少包含 `stage_id`、`stage_goal`、`steps[A1..An]`、`current_step`、`next_step`、`下一步候选`。不得只写“修复 A”这种粗粒度动作。
7. **完整修复队列必须落盘**：执行前写入 `追踪/审查报告/修复执行队列.md`，字段至少包含 `目标范围`、`completion_policy`、`阶段导航`、`stage_id`、`step_id`、`先执行什么`、`后续任务`、`当前步骤`、`状态`、`完成条件`、`复检命令/门禁`、`下一步候选`。
8. **停靠也要说明剩余任务**：如果必须停靠，用户可见摘要必须写明“已完成什么、后续任务还有什么、下一次会从哪一项继续”，并把 `next_action` 写入队列文件。
9. **完成条件**：只有所有队列项状态为 `done/skipped_by_user/blocked_external`，并完成复检、输出污染门禁、正文/报告门禁和总收束报告后，才能说“完整修复完成”。单个 A 阶段或 A1 步骤完成只能说“阶段完成/步骤完成”，不能说“已修复完”。
10. **交互选项污染门禁**：审阅后的修复选项也要过可见输出门禁。选项描述不得承载修复报告正文、不得超过 120 个中文字符；如果候选来自修复清单或阶段报告，先写 `追踪/输出门禁/.option_payload_draft_{YYYYMMDD_HHMMSS}.md` 并运行 `output-pollution-check.js`。命中污染时，不得展示选择器，必须回到最后可信修复队列并输出干净的 2-4 个意图式候选。

推荐选项文案模板：

```text
1. 全部修复（推荐）
   completion_policy: full_auto
   先执行：A 级高价值/高风险项。
   后续任务：B/C/D -> 结构/设定同步 -> 复检 -> 总收束报告。
   选择后不再逐批询问；只有任务队列清零并复检通过才算完整修复完成。

2. 先修复 A 级高价值项
   completion_policy: stage_then_confirm
   先执行：A 阶段（A1/A2/A3...）。
   后续任务：B/C/D、结构同步、复检仍保留。
   A 阶段完成后必须询问是否继续下一阶段；不得自动推进 B/C/D。

3. 只执行当前步骤 A1
   completion_policy: step_then_confirm
   只执行当前步骤 A1。
   完成 A1 后展示下一步候选：继续 A2 / 跳过 A2 / 返回阶段导航 / 停止并保存断点。
```

### Phase 1.1a-2：范围续审意图归一化

用户不会使用内部恢复话术；不要求用户说“先完成上次批次收束报告”。用户只说“继续审阅 200-400”“审阅 200-400”“审阅 300-400”“继续看 400-500”时，必须先读取 `追踪/审查批次计划.md`、`追踪/审查报告/批次交接摘要.md` 和已落盘批次报告，判断新范围与已完成/未完成范围的关系。

处理优先级：

1. **未收束优先**：如果存在 `paused_after_scan` 或 `running_incomplete`，先完成上次批次收束。用户明确指定的新范围写入 `next_requested_range`，收束完成后再处理；不得丢弃用户的新范围。
2. **已审范围复用**：如果用户请求范围完全落在已完成批次内，优先读取既有批次报告和交接摘要，输出复用结论；只有用户明确说“重审/复审/按新维度再审”，才重新审。
3. **相邻续审**：如果上次完成 `1-200`，用户说“继续审阅 201-400”，按新范围继续；批前读取 `1-200` 的交接摘要和 open 项。
4. **边界重叠**：如果上次完成 `1-200`，用户说“继续审阅 200-400”或“审阅 200-400”，把 `200` 作为桥接章，实际新审范围为 `201-400`，但必须用第 200 章做边界衔接校验；不得重复把第 200 章算作新批次成果。
5. **跳段审阅**：如果上次完成 `1-200`，用户说“审阅 300-400”，尊重用户显式范围，审 `300-400`，同时在批次计划标记 `gap_unreviewed: 201-299`、`gap_reconciliation_required: true`。不得声明 1-400 已连续审完，也不得把 201-299 的钩子回收状态当成已验证。
6. **Gap Bridge Probe**：跳段审阅涉及钩子回收、人物状态、主线、能力/成长规则（修真/仙侠项目才显示为修真进度）、承诺兑现等跨批维度时，先做轻量 gap 探针：读取章节索引、已有报告、交接摘要、矩阵台账、卷纲/细纲摘要和 201-299 的标题/摘要（若存在），只判断明显的承接风险；不要把它升级成 201-299 全量审阅。探针结果写入当前批报告的 `gap_probe` 小节。
7. **用户显式覆盖**：如果用户说“不要管前面，单独审 300-400”，仍可单独审，但报告必须标注 `scope_mode: isolated`，并说明跨批钩子/承诺结论只对 300-400 内部有效。

非连续审阅风险提示：

- 跳段审阅开始前，必须用自然语言告知用户风险，不要藏在内部字段里：`这次会先审 300-400，但 201-299 未审，所以情节剧情连贯判断会缺少中段证据；钩子回收可能误判，人物状态可能断层，能力/成长规则和主线承接也可能不准（修真/仙侠项目才显示为修真进度）。我会把 201-299 标为 gap，后续补审后再重算连续结论。`
- 该提示不默认阻塞用户；用户已明确要求审 300-400 时继续执行。但报告的 verdict 只能对 `300-400` 成立，跨区间结论必须标注 `provisional_due_to_gap`。
- 对涉及“全书连续性 / 剧情连贯 / 钩子回收 / 人物状态 / 能力成长曲线（仅修真/仙侠项目显示为修真进度曲线）”的 finding，必须写明 `evidence_gap: 201-299`，不能给出终局结论。
- **叙事连续性风险组**：非连续审阅报告必须显式列出以下风险，不得只写“人物状态可能断层”：
  - 剧情情节连续性：中段冲突、过渡、因果链、地图切换、高潮余波可能缺证。
  - 钩子上下文：伏笔首次出现、升级、误导、兑现窗口和读者期待可能跨 gap 发生，钩子回收可能误判。
  - 承诺兑现上下文：书名承诺、卷目标、章节钩子、人物承诺是否被中段兑现或背叛，不能仅凭 300-400 判断。
  - 人物状态连续性：目标、关系、伤势、资源、能力、认知边界可能在 gap 内变化，人物状态可能断层。
  - 能力/成长规则与主线连续性：能力来源、战力/能力边界、资源、势力地图、主线推进速度可能在 gap 内变化，后段判断只能暂定；仅当项目题材证据为修真/仙侠时显示为修真进度。

补审 gap 后连续性重算：

- 如果后续用户审阅 `201-299`，且批次计划中存在 `gap_unreviewed: 201-299` 或 `gap_reconciliation_required: true`，完成该 gap 批次后必须触发范围补缝报告。
- 范围补缝报告路径：`追踪/审查报告/连续区间_{start}-{end}_范围补缝报告.md`，例如 `追踪/审查报告/连续区间_1-400_范围补缝报告.md`。
- 补缝时读取 `1-200`、`201-299`、`300-400` 的批次报告、批次交接摘要、全局钩子回收矩阵、承诺-兑现链、角色状态连续表和主线推进表；不要重读全部正文，除非发现证据冲突。
- 必须重新计算 1-400 的连续结论：情节剧情连贯、钩子回收、人物状态、能力/成长规则、主线推进、AI 味跨段回退、承诺兑现；仅当项目题材证据为修真/仙侠时显示为修真进度。把原先 `provisional_due_to_gap` 的 finding 改为 `confirmed / resolved / downgraded / rejected`。
- **补缝重算项**：范围补缝报告必须逐项复核剧情情节连续性、钩子上下文、承诺兑现上下文、人物状态连续性、能力/成长规则与主线连续性；每项都要给出 `confirmed/resolved/downgraded/rejected/still_open`。
- 更新 `追踪/审查批次计划.md`：清除已补上的 `gap_unreviewed`，将 `gap_reconciliation_required` 改为 `false`，记录 `reconciled_range: 1-400` 和范围补缝报告路径。
- 如果补审后仍存在未审 gap，只能生成局部补缝报告，不能输出完整连续结论。

审查状态账本：

- 每个批次审阅或范围补缝报告完成后，必须更新 `追踪/review-state.json`。优先运行 `node scripts/review-state-ledger.js record --book-root <book-dir> --range <start-end> --report <报告路径> --scope-mode <continuous|continued_with_gap_probe|isolated> [--gap <gap-range>] --json`。
- `review-state.json` 至少记录：`range`、`report`、`scope_mode`、`gaps`、`dependency_hashes`、`status`、`stale_reason`、`suggested_recheck_ranges`、`created_at`、`updated_at`。
- `dependency_hashes` 必须覆盖当次报告、`追踪/伏笔.md`、`追踪/时间线.md`、`追踪/角色状态.md`、`追踪/人物状态.md`、`追踪/主线承诺.md`、`追踪/审查批次计划.md` 和 `追踪/审查报告/批次交接摘要.md`；如本书使用其他 SSOT 文件，可用 `--dependency <path>` 追加。
- 开始新审阅前运行 `node scripts/review-state-ledger.js check --book-root <book-dir> --write --json`。如果依赖 hash 改变，将相关 review 标记为 `stale`，填写 `stale_reason: dependency_hash_changed` 和 `suggested_recheck_ranges`。
- `stale` 不等于自动重跑。默认只提示哪些范围建议重审，除非用户明确选择重审或新信息阻断当前结论；这样避免成本不可控。
- 如果后续补审 gap 导致 300-400 之类已有报告依赖的伏笔、时间线、角色状态或主线承诺发生变化，应把该范围标记为 `stale`，并在范围补缝报告里说明原结论由 `provisional_due_to_gap` 变为 `confirmed/resolved/downgraded/rejected/still_open`。

范围归一化必须写入 `Review Scope Contract`：

```yaml
requested_range: "300-400"
normalized_range: "300-400"
relation_to_previous: "jump"
previous_completed_range: "1-200"
bridge_chapters: []
gap_unreviewed: "201-299"
scope_mode: "continued_with_gap_probe"
gap_reconciliation_required: true
cannot_claim_continuity: "1-400"
next_requested_range: null
```

用户可见表达必须自然：

- 对“继续审阅 200-400”：`我会把第200章当边界桥接章，实际续审201-400，并用1-200的交接摘要检查衔接。`
- 对“审阅 300-400”：`我会审300-400；201-299会标为未审 gap。因为中段未审，剧情连贯、钩子回收和人物状态判断会有缺证风险，所以本次只给300-400结论；后续补审201-299后，我会重新计算1-400的连续结论。`

4. **报告落盘事务协议 / 写入事务门禁**：
   - **报告写权限预检**：生成长报告、批次报告、总报告或矩阵台账前，必须对目标目录做写权限检查。先 `mkdir -p 追踪/审查报告`，再运行 `test -w 追踪/审查报告`，并做一次临时写入测试（写入 `.write-test-$$.md` 后立即读取并删除）。只有预检通过，才开始组织大段报告正文。
   - 如果 `test -w`、临时写入测试或工具写文件返回 `Error writing file` / `Permission denied`，先停止报告生成，输出权限诊断：当前用户、目标目录 `ls -ld`、最近目标文件 `ls -l`、目录 ownership。不得继续生成长报告正文，也不得反复重试 Write/Edit。
   - **write_failure_triage**：任何报告、修复队列、范围补缝报告或矩阵文件写入返回 `Error writing file`、`Error editing file`、old_string not found、写后读不到内容或 hook usage 后，必须立即运行确定性分诊脚本：`node scripts/write-failure-triage.js --target <目标文件> --log-file <最近工具日志> --project-root <book-dir> --write --json`。不得说“继续执行报告落盘/继续执行审查报告落盘”，不得再次调用同一 Write/Edit。以脚本返回的 `status/category` 为准：`blocked_write_tool_call_invalid` 只允许重建一次明确 `file_path + content` 的恢复报告写入；`blocked_write_hook` 先记录 hook 名称并修 hook/payload；`blocked_write_permission` 先修目录 ownership；`blocked_write_missing_output` 先写恢复记录和最后可信证据点。
   - **tool_call_schema_check**：如果目录可写、没有 `Permission denied`、没有 hook stderr，而日志出现 `参数不完整`、`Invalid tool parameters`、`missing required parameter`、`file_path` 缺失、`content` 缺失或类似 schema 错误，分类为 `blocked_write_tool_call_invalid`。这说明 Write 工具调用本身不完整，不是文件系统问题。必须先重建明确写入计划：`tool=Write`、`file_path=<恢复报告路径>`、`content=<完整报告正文来源>`；确认 `file_path + content` 都非空后，只允许对恢复报告路径做一次纠正后的 Write。
   - **恢复报告路径**：分诊通过后，不再写原失败目标，改为新建带时间戳文件，例如 `追踪/审查报告/恢复_YYYYMMDD_HHMMSS.md` 或 `追踪/审查报告/批次恢复_YYYYMMDD_HHMMSS.md`，并在文件头记录原目标路径、失败原因、最后可信证据点和后续恢复步骤。分诊不通过时只能输出 `blocked_write_permission` / `blocked_write_hook` / `blocked_write_tool_call_invalid` 诊断，不继续生成长报告正文。
   - 如果写入链路返回 `PostToolUse hook`、`PostToolUse:Edit hook returned blocking error`、`Error editing file`、hook `usage:` 或正文/报告门禁阻断，必须把当前步骤标记为 `blocked_write_hook`，记录 hook 名称、目标文件和最后可信产物；不得把 hook 阻断后的草稿继续当成有效报告或修复队列。
   - 权限修复建议必须具体到项目目录，例如：`sudo chown -R $(whoami):$(id -gn) <book-dir>`；如果当前会话没有 sudo 权限，只记录断点并提示需要修复目录 ownership 后再继续。
   - 长报告、批次报告、总报告和矩阵台账必须先创建 `追踪/审查报告/` 目录，再写入新文件或临时文件；写完后立即验证文件存在、非空，并能读取标题/元数据。
   - 修复执行队列、复检报告和范围补缝报告同样适用写入事务门禁；result packet 的 `changed_files` 必须逐项确认实际存在、非空且能读取关键标题。若文件缺失、空文件、路径解析失败或 agent Done 但目标报告不存在，写入 `blocked_write_missing_output`。
   - 禁止在目标文件不存在时使用 Update/Edit；目标文件不存在时只能新建文件，或写入 `.tmp` 后原子替换为正式文件。
   - 需要追加内容时先重新读取目标文件尾部和目录状态，再使用最小范围追加；不得凭聊天记忆假设文件已经创建。
   - 如果出现连续 2 次 Error editing file、old_string not found、目标文件不存在或写后读不到内容，必须停止编辑并重新读取文件系统状态；随后改为新建带时间戳的恢复报告，例如 `追踪/审查报告/恢复_YYYYMMDD_HHMMSS.md`，并在批次计划中记录原目标路径失败原因。
   - 不得继续消耗长上下文硬改同一文件；不得在错误后把未落盘内容当作已经完成的审查报告。
   - **输出污染门禁**：批次报告、总报告、修复方案或恢复报告写入后，必须运行 `node scripts/output-pollution-check.js --learn --project-root <book-dir> <报告文件>`。命中长术语重复填充、占位符污染、已学习污染词组、`domain-token-flood` 术语洪泛、`provider-artifact` 模型/供应商噪声或 `fake-completion-sentinel` 伪完成哨兵时，报告视为未完成：先回退污染段并重写，再复扫到 0。`--learn` 会把污染短语写入 `追踪/schema/output-pollution-rules.jsonl`、`追踪/schema/user-style-rules.jsonl` 和 `设定/作者风格/禁用表达.md`，后续审查自动带入。
   - **模型退化 front-stop**：审阅执行中如果出现领域词无间隔重复、SSOT 词组循环、阶段标签循环、同一领域词几十次刷屏、长时间 thinking 但无新增可信报告/矩阵，立即停止并记录 `blocked_model_degradation`。此状态下不得写入正文/报告，不得继续 Write/Edit，不得把污染思路转成审查结论；只保留最后可信断点，缩小任务粒度重试一次。若重试仍失败，输出干净恢复选项：1. 缩小范围继续 2. 切换模型后续跑 3. 只保存诊断。
   - **自学习退化规则**：审阅报告、修复方案和可见长回复生成前先读取已学习模型退化规则：`追踪/schema/output-pollution-rules.jsonl`。若规则含 `blockedStatus=blocked_model_degradation`，必须把对应 phrase 加入本轮前置阻断词表；生成草稿、候选或报告前先检查这些 phrase，命中即前置阻断，不进入 Write/Edit 或长报告生成。
   - **供应商敏感输出拦截**：审阅或修复方案生成时如果 API 返回 `output new_sensitive`、`new_sensitive (1027)` 或类似输出安全错误，记录 `blocked_provider_sensitive`。不得原样重试，不得继续 Write/Edit，不得调用 Agent/TaskCreate 继续撞同一任务，不得把被拦截内容写入审查报告；用户输入继续也不得直接恢复原任务，必须先进入恢复选项。保留最后可信断点，降低显性描写，改用概述式证据描述或只列路径/章节号，缩小任务粒度后最多重试一次。若仍失败，提示用户选择：1. 降低描写尺度继续 2. 跳过敏感段保留剧情因果 3. 停止并只保存诊断。
   - **假通过作废规则**：`AI 痕迹检测通过不能替代 output-pollution-check.js`。如果报告正文自称已通过、已完成、CREATED REPORT FILE COMPLETE 或类似完成状态，但 `output-pollution-check.js` 命中任何污染，必须作废污染报告，不得引用其结论、不得把 `PASS/CONCERNS/REJECT` 当有效裁决；只能从最后可信事实点重新生成干净报告。
   - **可见长回复污染门禁**：批次结论、修复方案、设定基准对齐建议、跨批总报告等超过 800 中文字符的可见回复，在直接回复用户前必须先写入 `追踪/审查报告/.visible_reply_draft_{YYYYMMDD_HHMMSS}.md` 或目标报告临时文件，运行 `node scripts/output-pollution-check.js --learn --project-root <book-dir> <draft-file>`。命中领域术语循环、阶段标签循环或已学习污染词组时，不得把污染文本继续输出到聊天窗口；必须删除/重写污染段，复扫到 0 后再给用户精简结论。若已在聊天中开始污染循环，应立即停止，说明 `paused_after_output_pollution`，落盘断点和恢复命令。
   - **前置自检硬停**：如果还没写 draft，但 thinking、阶段标题、候选描述或回炉方案草稿里已经出现同一领域短语连续 3 次以上，不得继续生成“流程说明”。立即判为 `blocked_model_degradation`，使用 `node scripts/blocked-recovery-template.js --status blocked_model_degradation` 的短模板。不要把污染短语复述成“某某 6 章回炉”“某某核心段”这类标题；改称 `污染段#N`，证据只给文件路径/行号。
   - **源污染隔离**：审阅旧报告或正文时发现重复填充，先把污染段登记为 `polluted_source_segment`，从污染起点到文件尾部不作为事实依据。修复方案只能说“回退污染段并按最后可信事实重写”，不得沿用污染段里的术语、章节判断或结论。
   - **污染恢复协议**：命中输出污染后，不是继续润色污染文本，而是恢复可信状态。先定位最后可信事实点（最后一个有证据的 finding / 章节范围 / grep 或报告来源），丢弃污染段及其后内容；把未完成报告拆成“范围、证据、结论、修复建议、下一步”五块分块重写，每块写完复扫。连续 2 次复扫仍失败时，停止生成长报告，落盘 `paused_after_output_pollution`，记录最后可信事实点、丢弃污染段、未完成块和新会话续跑句。
5. **主动停靠，而不是被动中断**：
   - 当前会话时间、上下文或工具调用接近边界时，必须停在批次边界，把 `追踪/审查批次计划.md` 更新为 `paused_at_batch_boundary`。
   - 给出准确续跑句：`/novel-assistant 继续全书审查《{书名}》`，并说明将从哪一批 / 哪一章继续。
6. **最后合并总报告**：
   - 全部批次完成后，读取各批报告的 Findings 摘要，不重新读取所有正文。
   - 输出 `追踪/审查报告/全书审查总报告.md`，包含跨批重复问题、最高优先级修复清单、伏笔/时间线/角色状态风险，以及需要人工裁决的冲突。
   - 总报告必须先做范围一致性校验：列出 `requested_scope`、实际审查最小/最大章节、批次数、是否存在越界章节。存在越界章节时，不得生成最终报告；先丢弃越界结果并回到对应批次重跑。
   - 总报告必须包含用户指定维度的「维度覆盖清单」：每个维度至少给出结论、主要证据范围、S1/S2 问题数和修复方向。用户说“解决问题”时，默认输出优先级修复方案和受影响产物清单；除非用户明确要求“执行修改/落盘改稿”，审查模块不直接批量改写正文。
   - 总报告和优先级修复方案完成前，必须对最终文件复跑 `output-pollution-check.js`；命中输出污染时不得把 `CONCERNS/PASS/REJECT` 作为有效结论。
7. **禁止的做法**：
   - 不得把“整本书先全部读一遍”作为默认执行路径。
   - 不得把全书正文复制进每个 Agent prompt。
   - 不得用笼统风险描述替代批次计划和断点。

### Phase 1.1b：全书级审查故障自愈

全书级审查出现 API error、timeout、recap 停靠、会话压缩、reviewer agent 失败、脚本门禁失败或进程退出时，按长任务自愈处理，不从头重跑已完成批次。

1. **文件系统是权威**：优先读取 `追踪/审查批次计划.md`、`追踪/审查报告/批次_*.md`、全局钩子回收矩阵、爆点兑现矩阵、承诺-兑现链和角色状态连续表。聊天记忆和上一轮回复只作参考。
2. **定位第一未完成批次**：按批次计划中的 `pending / running / done / failed / paused_at_batch_boundary` 找第一未完成批次；若计划与批次报告冲突，以已落盘报告和最近修改时间为准，修正计划后继续。不得从头重跑已完成批次。
3. **自动恢复类**：timeout、API error、stream stall、UI 停靠、单个 reviewer 空输出或临时失败，可从第一未完成批次继续；单批失败先重试 1 次，仍失败则标记 `failed` 并继续低风险后续批次，最后总报告汇总失败范围。
4. **外部阻断类**：quota / Token Plan / usage limit / 账号配额 / 源文件缺失，不做忙等重试。写清批次计划断点、阻断原因和下一批范围后停止；下次启动先检查阻断是否解除。
5. **合并保护**：只有全部必要批次为 `done` 或明确 `failed` 后，才生成 `追踪/审查报告/全书审查总报告.md`。不得因为中断就输出“全书已审完”。
6. **用户可见表达**：只报告“已恢复到第 X 批 / 当前被配额阻断 / 已保存断点”，不要把内部脚本、grep、批次计划修复命令当成用户手动操作。

### Phase 1.2：跨批全局台账

批次审阅不能只看当前 10-20 章，否则会漏掉钩子、爆点、承诺和回收链。全书级审查必须维护以下全局矩阵；每批审阅前读取矩阵，审阅后更新矩阵，最终总报告以矩阵为核心证据。

| 矩阵 | 路径 | 必须记录 |
|---|---|---|
| 全局钩子回收矩阵 | `追踪/审查报告/全局钩子回收矩阵.md` | 钩子/伏笔/疑问、首次出现章节、承诺强度、计划回收章节、实际回收章节、状态（open/paid/late/broken）、证据 |
| 爆点兑现矩阵 | `追踪/审查报告/爆点兑现矩阵.md` | 每个爆点/爽点/高潮的铺垫章节、蓄能方式、兑现章节、余波章节、读者收益、是否提前泄力 |
| 承诺-兑现链 | `追踪/审查报告/承诺-兑现链.md` | 书名/简介/开篇/卷目标/章节钩子对读者作出的承诺，以及后文是否兑现、延迟或背叛 |
| 角色状态连续表 | `追踪/审查报告/角色状态连续表.md` | 角色目标、关系、能力、伤势、资源、认知边界在批次之间是否断线 |
| 主线推进表 | `追踪/审查报告/主线推进表.md` | 每批对当前卷目标、全书主线、核心矛盾的推进/偏航/停滞情况 |
| 跨批交接摘要 | `追踪/审查报告/批次交接摘要.md` | 每批结束后的剧情压缩、钩子与承诺状态、角色状态压缩、能力/成长规则压缩（修真/仙侠项目才显示为修真进度压缩）、主线位置、下一批必须核查的衔接点 |

执行规则：
1. **批前读取**：每个批次开始前读取上述矩阵的摘要行和与当前章节范围相邻的 open 项；不要读完整正文补全记忆。第二批及以后，下一批开审前必须读取上一批交接摘要，并把其中的 open 钩子、人物状态、能力/成长规则和主线位置写入当前批审查基准；修真/仙侠项目可显示为修真进度。不得只读当前批次正文。
2. **批中标记**：遇到新钩子、新爆点、新承诺、新能力、新关系变化，必须写入对应矩阵；遇到兑现、回收、反转或废弃，也必须更新状态。
3. **跨批边界复核**：每批结束时检查“上一批遗留 open 项是否在本批被推进或回收”“本批新增项是否有后续计划”；相邻批边界至少复核上一批最后 1 章和本批前 1 章。
4. **交接摘要落盘**：每批 `done` 前必须更新 `追踪/审查报告/批次交接摘要.md`，追加当前批交接块。交接块必须包含：
   - 范围与状态：批次号、章节范围、报告路径、`PASS/CONCERNS/REJECT`。
   - 剧情压缩：用 5-12 条写清本批发生了什么、主线推进到哪里、哪些剧情问题仍未解决。
   - 钩子与承诺状态：新增、推进、回收、逾期、断裂的钩子/承诺，标明后续应检查章节或窗口。
   - 角色状态压缩：主要角色的目标、关系、伤势、资源、认知边界和能力变化。
   - 能力/成长规则压缩：能力来源、边界、代价、战力/能力节奏、资源、地图、势力推进是否越界，下一批要核对的阈值；修真/仙侠项目可显示为修真进度压缩。
   - 与上一批衔接判定：本批是否承接上一批遗留问题；如未承接，记录 `S1/S2/S3` 和证据位置。
   - 下一批审查提示：下一批必须优先核查的 open 项，不超过 12 条。
5. **下一批衔接校验**：下一批报告必须包含“与上一批衔接判定”小节，逐条核对上一批交接摘要中的 open 项：已推进、已回收、仍 open、断裂、误报。缺少该小节时，批次不得标记 `done`。
6. **缺口判定**：
   - 未回收钩子：承诺强度高、超过计划回收窗口仍无推进，标为 S1/S2。
   - 爆点泄力：铺垫过长但兑现弱、提前解释答案、高潮后无余波，标为 S2/S3。
   - 承诺背叛：开篇/书名/卷目标承诺与实际主线不符，标为 S1/S2。
   - 状态断线：角色伤势、能力、资源、关系或认知跨批突变，按一致性影响标 S1-S3。
7. **总报告合并**：`全书审查总报告.md` 必须包含上述矩阵的摘要：未回收钩子 Top、爆点兑现不足 Top、承诺-兑现断裂 Top、角色状态断线 Top、主线偏航批次，并引用 `批次交接摘要.md` 的跨批断裂结论。

**Phase 1.5：可选 story-explorer 预查询**。仅当 `Effective Mode` 仍为 `full`/`lean`、当前允许 spawn 且 Agent/Task 工具可用时，才可检查 `.claude/agents/story-explorer.md` 并 spawn `story-explorer` 预查设定摘要；`solo` 或子代理递归保护场景下不得 spawn，只能直接 Read/Grep。Prompt 示例：

```text
项目目录：{dir}
查询类型：setting_appearances
查询参数：{审查涉及的设定关键词}
```

此步可选，跳过不影响审查流程。

---

## 统一 Findings Schema（所有模式必须使用）

所有 reviewer（包括 solo）输出问题时必须使用统一结构，方便综合排序。`location` 必须使用工具读取结果显示的原始文件行号；不要删除空行后重新编号。

对 `consistency` / `factual` / `causal` / `rule_boundary` 类 finding，`fix` 字段只写事实统一方向（例如“统一为左臂旧伤，并同步正文/设定中冲突处”或“需在 A/B 时间线中裁定一个来源”），不要写文学创作建议。

```yaml
- severity: S1 | S2 | S3 | S4
  code: Plot_Drift | Beat_Missing | Canon_Conflict | Motivation_Drift | AI_Slop
  category: structure | character | prose | consistency | platform | factual | format | causal | rule_boundary
  location: 文件路径:行号 或 章节/段落描述
  evidence: "引用原文或具体证据"
  issue: "问题描述"
  fix: "可执行修改建议"
```

`code` 必须来自 `story-review/references/error-codes.md`。如果一个 finding 不匹配具体错误码，使用最接近的通用错误码；不要发明新 code。长篇稳定性相关 finding 优先使用 `Plot_Drift`、`Beat_Missing`、`Beat_Compressed`、`Canon_Conflict`、`Motivation_Drift`、`Knowledge_Leak`、`Foreshadow_Early_Payoff`、`Untracked_Addition`、`State_Not_Updated`。

严重度定义：
- **S1**：会破坏主线、角色动机、世界规则或读者信任，需优先修。
- **S2**：明显影响章节效果、留存、节奏、人物可信度，建议本轮修。
- **S3**：局部质量问题，如措辞、轻微格式、局部节奏，可排期修。
- **S4**：建议项或风格微调，不阻塞发布。

---

## Phase 2：并行 Spawn Agent（full/lean 模式）

使用 Agent 工具并行调用。每个 Agent 不继承父对话上下文，prompt 必须自包含项目路径、审查范围、文件路径、必要摘录、审查基准包摘要、Rubric Source 和统一 Findings Schema。

**调用规则**：执行 Phase 0 后，只有实际模式仍是 full/lean 时才 spawn。不要 spawn 缺失 Agent。

**Agent 1: story-architect**（subagent_type: story-architect）
- full/lean 均调用。
- 审查视角：主题对齐、大纲结构、钩子/反转质量、范围控制、平台期待。
- 提示指令：
  ```
  你是 story-architect，从故事架构层面审查以下内容。
  你的任务是【找问题】，不是验证正确性。以最严苛的标准审视。
  项目路径：{项目根}
  审查范围：{文件路径/章节/必要摘录}
  审查基准包摘要：{Phase 1 形成的 rubric / fallback 摘要，必须内联}
  Rubric Source: file | embedded fallback
  相关文件路径：{设定/大纲/细纲文件路径}
  可选补充参考：如项目已部署 story-setup reference bundle，可读取 `story-setup/references/agent-references/quality-checklist.md`、`story-setup/references/agent-references/plot-core-methods.md`；若不可读，不影响审查。
  检查项：
  1. 这一章是否推进了故事主题？
  2. 大纲结构是否完整（钩子/爽点/悬念）？
  3. 情绪节奏是否合理？
  4. 钩子和反转设计质量如何？
  5. 范围控制：有无角色/设定膨胀？
  6. 剧情循环是否存在且可重复？（参照审查基准包摘要里的剧情循环原则）
  7. 高潮场景是否用了蓄能→假胜→崩解结构？（参照审查基准包摘要里的高潮构建原则）
  8. 伏笔密度、连载期待和结构信息量是否合理？（伏笔密度通常只作为 S4 结构风险，除非已造成理解混乱）
  9. 按平台 rubric 或通用内容 rubric 逐项对照，标记 PASS/FAIL。

  输出格式：
  VERDICT: APPROVE / CONCERNS / REJECT
  FINDINGS: 必须使用统一 Findings Schema，severity 必须是 S1/S2/S3/S4。
  RECOMMENDATIONS: [修改建议]
  ```

**Agent 2: character-designer**（subagent_type: character-designer）
- full 模式调用。
- 审查视角：角色语言风格一致性、对话质量、人物弧线、关系推进。
- 提示指令：
  ```
  你是 character-designer，从角色和对话层面审查以下内容。
  你的任务是【找问题】，不是验证正确性。以最严苛的标准审视。
  项目路径：{项目根}
  审查范围：{文件路径/章节/必要摘录}
  审查基准包摘要：{Phase 1 形成的 rubric / fallback 摘要，必须内联}
  Rubric Source: file | embedded fallback
  相关角色文件：{角色设定文件路径}
  可选补充参考：如项目已部署 story-setup reference bundle，可读取 `story-setup/references/agent-references/character-relations.md`、`story-setup/references/agent-references/dialogue-mastery.md`；若不可读，不影响审查。
  检查项：
  1. 角色语言风格是否与语言风格档案一致？
  2. 对话是否千篇一律或信息过满？
  3. 人物弧线是否连贯？
  4. 角色行为是否符合其动机？
  5. 对话是否有潜台词和信息控制？
  6. 爱情线好感度与 CP 行为是否匹配？（参照审查基准包摘要或可选 `story-setup` 角色关系参考）
  7. 好感度进度是否可感知？

  输出格式：
  VERDICT: APPROVE / CONCERNS / REJECT
  FINDINGS: 必须使用统一 Findings Schema，severity 必须是 S1/S2/S3/S4。
  RECOMMENDATIONS: [修改建议]
  ```

**Agent 3: narrative-writer**（subagent_type: narrative-writer）
- full 模式调用。
- 审查视角：AI味检测、格式合规、节奏均匀度、文字自然度。
- 提示指令：
  ```
  你是 narrative-writer，从文字质量层面审查以下内容。
  你的任务是【找问题】，不是验证正确性。以最严苛的标准审视。
  项目路径：{项目根}
  审查范围：{文件路径/章节/必要摘录}
  审查基准包摘要：{Phase 1 形成的 rubric / fallback 摘要，必须内联}
  Rubric Source: file | embedded fallback
  AI 味 / 禁用词摘要：{从 anti-ai-writing、banned-words 或内置 fallback 提取，必须内联}
  可选补充参考：如项目已部署 story-setup reference bundle，可读取 `story-setup/references/agent-references/anti-ai-writing.md`、`story-setup/references/agent-references/banned-words.md`、`story-setup/references/agent-references/quality-checklist.md`；若不可读，不影响审查。
  检查项：
  1. 是否存在禁用词/套话/陈词滥调？
  2. 是否出现 AI 写作指纹、8 种 AI 写作模式（含模式 8 解释腔/上帝视角/安排感）或章末总结体？
  3. 格式是否合规（按戏剧单元/镜头自然断段、无机械字数切分、无空行、对话独立成行、主语节奏自然）？
  4. 标点节奏是否匹配语气/人物声线：是否通篇句号化、随机堆砌问号/感叹号，或残留 `……`/`——` 硬造停顿？正文（含对话）里的破折号是否已清理？
  5. 节奏是否均匀（有无连续多节无情绪变化）？
  6. 身体部位同一词是否超 5 次？
  7. AI味分级（轻度/中度/重度）及证据。

  输出格式：
  VERDICT: APPROVE / CONCERNS / REJECT
  FINDINGS: 必须使用统一 Findings Schema，severity 必须是 S1/S2/S3/S4；AI味级别写入 issue 或 category。
  RECOMMENDATIONS: [修改建议]
  ```

**Agent 4: consistency-checker**（subagent_type: consistency-checker）
- full/lean 均调用。
- 审查视角：grep-first + 推理型一致性检测，输出 S1-S4 报告。
- 提示指令：
  ```
  你是 consistency-checker，使用 grep-first + 推理型一致性审查检测事实矛盾。
  你的任务是【找事实矛盾、状态断线和需要推理才能发现的设定逻辑冲突】，不做创作评判，不评价文学质量，不输出创作修改建议。
  项目路径：{项目根}
  审查范围：{文件路径/章节/必要摘录}
  已知角色：{从设定文件提取角色列表}
  审查基准包摘要：{Phase 1 形成的 rubric / fallback 摘要，必须内联}
  Rubric Source: file | embedded fallback
  可选补充参考：如项目已部署 story-setup reference bundle，可读取 `story-setup/references/agent-references/quality-checklist.md`；若不可读，不影响事实冲突扫描。
  检查项：
  1. 角色属性是否前后一致？
  2. 世界规则是否被违反？
  3. 伏笔状态是否前后一致（已埋/计划回收/已回收/断线）？
  4. 时间线是否自洽？
  5. 术语、身份、地点、能力边界是否前后一致？

  输出格式：
  VERDICT: APPROVE / CONCERNS / REJECT
  FINDINGS: 必须使用统一 Findings Schema，severity 必须是 S1/S2/S3/S4；category 只能使用 consistency / factual / format / causal / rule_boundary。
  FACTUAL_RECONCILIATION: [仅列需统一的事实来源或需人工裁决项，不写文学创作建议]
  REASONING_CHAINS: [仅列推理型 finding 的前提/规则 -> 触发事件 -> 矛盾点 -> 需裁决问题]
  ```

---

## Phase 3：综合裁决

1. 收集实际执行的 reviewer VERDICT 和 FINDINGS。
2. **盲读者与误伤率校准**：当裁决涉及 AI 味、破折号、对比句、短段或作者声音争议时，先遵守 `story-review/references/blind-reader-protocol.md`。盲读包在 verdict 锁定前不得暴露模型、生成器、修订来源、作者认可状态、标签或检测预判；先生成包，再用 `--lock-verdict` 生成含 `lockedVerdictHash` 的 lock artifact，最后才可用 `--reveal` 揭示来源。没有可验证 lock artifact 的盲读只能标为未完成，不能当作独立裁决。机器命中只能作为裁决后的证据之一。基线运行必须保留四项指标、`corpusVersion`、`detectorVersion`、`sourceIdentity`、版本化 `aggregationPolicy`、advisory/blocking 分层计数和显式实际 misses；`sourceIdentity` 不一致的报告是 stale evidence，必须重跑，不得为通过语料而硬调规则。fixture provenance 只是 `self-declared` 声明，不能当作独立事实。
3. 合并去重：按 `severity` 排序（S1 > S2 > S3 > S4），同级内按影响范围排序。
4. **可选事实核查**：如果审查内容涉及需要验证的外部事实（历史年代、地理方位、职业细节等），只有在 `Effective Mode` 仍为 `full`/`lean`、当前不是子 Agent、Agent/Task 工具可用且 `.claude/agents/story-researcher.md` 已部署时，才可额外 spawn `story-researcher` 搜索验证；`solo`、missing/malformed/stale/spawn failed 降级或子代理递归保护场景下不得 spawn，只能在报告中标记“需人工事实核查”。
5. **分歧呈现**：如果 reviewer 间有冲突意见，明确呈现分歧让用户裁决；不要自动妥协。
6. 输出综合审查报告。报告必须列出实际模式、fallback 原因、使用的 rubric、Rubric Source、审查范围和证据不足项。

---

## Phase 4：输出报告（full / lean 模式）

只有 `Effective Mode` 确实为 `full` 或 `lean` 时才使用本模板；如果 Phase 0 或运行时失败导致降级 `solo`，必须改用 solo 模式模板。

注意：下列 `Requested Mode`、`Effective Mode`、`Fallback`、`Rubric`、`Rubric Source` 五个英文 key 必须逐字保留；不要改成“请求模式/实际模式/回退/评估标准”等中文 key。

```md
=== 故事审查报告 ===
Requested Mode: full | lean
Effective Mode: full | lean
Fallback: none
Rubric: fanqie | qidian | zhihu | generic web-fiction
Rubric Source: file | embedded fallback
审查范围: {章节/文件/批次}

## Verdict Summary / 结论汇总
- story-architect: APPROVE / CONCERNS(n) / REJECT / NOT_RUN
- character-designer: APPROVE / CONCERNS(n) / REJECT / NOT_RUN
- narrative-writer: APPROVE / CONCERNS(n) / REJECT / NOT_RUN
- consistency-checker: APPROVE / CONCERNS(n) / REJECT / NOT_RUN

> `NOT_RUN` 只用于 lean 模式排除的 reviewer 或可选 reviewer；如果 full/lean 必需 reviewer 缺失或 spawn 失败，应降级 solo，而不是在 full/lean 报告中标记 NOT_RUN 后继续综合。

## Severity Counts
- S1: n
- S2: n
- S3: n
- S4: n

## 综合评定
APPROVE(通过) / CONCERNS(有问题) / REJECT(需重写)

## 发现的问题
{按统一 Findings Schema 或等价表格列出所有问题}

## Agent 分歧（如有）
{列出 reviewer 间不同意见和证据}

## 证据不足 / 需补充
{缺失设定、缺失大纲、无法核查事实等}

## 修改建议
{按 S1→S4 优先级排列}
```

---

## lean 模式

lean 模式只 spawn `story-architect` + `consistency-checker`。如果任一缺失，按 Phase 0 自动降级 solo。其余流程同 full。

---

## solo 模式

不 spawn Agent。先按 Phase 1 第 4 步识别目标平台并加载对应 rubric；即使是 solo，也必须用平台 rubric、`story-review/references/quality-rubric.md` 或内置审查基准包校准判断。

solo 必须执行基础检查：
1. 格式合规性检查（戏剧单元/画面分段、无机械字数切分、无空行、对话格式、主语/角色名节奏）。
2. 简单的设定一致性 grep（角色名、属性、关键设定、伏笔关键词）+ 推理型一致性检查（规则边界、设定层级、跨章因果链、可滥用漏洞、代价一致性）。
3. AI 味与禁用词检查（优先读取 `story-review/references/banned-words.md` 与 `story-review/references/anti-ai-writing.md`，不可读时使用内置 AI 味 / 禁用词 fallback 速查）。
4. 通用网文内容评分（优先读取 `story-review/references/quality-rubric.md`，不可读时使用内置通用网文内容 rubric）。
5. 按统一 Findings Schema 输出简化版报告。

### solo 模式输出格式

注意：下列 `Requested Mode`、`Effective Mode`、`Fallback`、`Rubric`、`Rubric Source` 五个英文 key 必须逐字保留；不要改成“请求模式/实际模式/回退/评估标准”等中文 key。

```md
=== 故事审查报告（solo）===
Requested Mode: {full | lean | solo}
Effective Mode: solo
Fallback: none | missing agents -> solo | malformed agents -> solo | stale agents -> solo | agent tool unavailable -> solo | spawn failed -> solo | subagent recursion guard -> solo
Rubric: fanqie | qidian | zhihu | generic web-fiction
Rubric Source: file | embedded fallback
审查范围: {章节/文件}

## 基础检查结果

### 格式合规性
- [{x| }] 段落按戏剧单元/镜头/一件事结束自然断开，非机械按字数切分；偶发稍长的完整推理/氛围/情绪链不算违规，通篇同阈值切段或碎成提纲才算：通过/不通过；证据：...
- [{x| }] 主语/角色名节奏自然：段首能建立主语，段中有代词/省略，关键转折再点名；连续句/段无必要重复同一主角名才算主语过密：通过/不通过；证据：...
- [{x| }] 无段间空行：通过/不通过；证据：...
- [{x| }] 对话独立成行：通过/不通过；证据：...
- 违规位置：{列出}

> checklist 约定：`[x]` 只表示通过，`[ ]` 表示未通过；不得出现“`[x] ... 不通过`”这种矛盾写法。

### 设定一致性（grep + 推理扫描）
- 字面事实冲突：{列出发现的矛盾或证据不足}
- 推理型一致性：{规则边界/设定层级/跨章因果/可滥用漏洞/代价一致性的发现；无则写“未发现”}

### AI 味 / 禁用词
- {列出问题，必须附 evidence}

### Findings
{按统一 Findings Schema 或等价表格列出，severity 必须是 S1/S2/S3/S4}

### 修改建议
{按优先级排列}
```

---

## 流程衔接

**流水线：** 通用
**位置：** 审查（写作之后）

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 要修改查出的问题 | `story-workflow` | 返回编排器决定对应写作资产的修复路径 |
| 发现 AI 味需清理 | `story-workflow` | `/novel-assistant 去AI味` |
| 需要重新拆解对标书 | `story-workflow` | `/novel-assistant 重新拆解对标书` |

---

## 语言

- 跟随用户的语言回复，用户用什么语言就用什么语言回复。
- 中文回复遵循《中文文案排版指北》。
