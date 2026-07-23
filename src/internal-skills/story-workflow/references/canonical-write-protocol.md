# Canonical Write Protocol

此协议在任何正式资产、短篇正文、候选稿接受、写入失败或事务关闭前按需读取。以下条款从 story-workflow 完整迁移。

### 正式资产事务接受

workflow 负责把正式资产接受作为独立步骤写入 packet；它不直接写 canonical 资产。严格策略项目中，L3 模块先准备事务候选，workflow 只在验证证据齐全后调用 `node scripts/chapter-commit.js prepare --project-root <book-root> --manifest <manifest.json> --json`，再调用 `node scripts/chapter-commit.js accept --project-root <book-root> --transaction <transaction-id> --json`。只有返回 `accepted` 或按既有规则处理完投影债务后，才能推进状态整合或关闭章节。只读审阅、分析和 `追踪/审查报告/` 等非 canonical 产物不要求事务；legacy 直写必须保留 `mode=legacy_nontransactional` 与迁移提示，不能伪装为严格接受。

用户仍只调用 `/novel-assistant`。本 skill 由 `story` router 内部读取，不作为用户需要记住的新命令。

**用户可见输出中文优先**：不以宿主 UI 的 thinking trace 语言作为验收对象；但工作流可见状态、下一步候选、错误提示、落盘报告摘要和正文交付必须中文优先。英文只能作为技术字段名、脚本名、错误码、JSON key 或用户明确要求的英文输出。

**用户可见术语必须中文化**：内部可用 `SSOT` / `ssot` 表示 single source of truth，但对用户展示时一律改成“权威设定”“设定基准”“唯一设定源”。涉及境界、修为、等级、能力成长时优先写“境界设定”或“成长进度设定”；不要把英文缩写夹在境界说明里，应写“境界设定：第 1-50 章维持炼气阶段”。

常见内部词对外映射：

- `Context Pack` -> “上下文包 / 本章上下文包 / 最小上下文”
- `full review` / `full 审查` -> “完整审查 / 多视角审查”
- `preflight` -> “前置检查 / 开始前检查”
- `token` -> “上下文消耗 / 成本 / 模型消耗”
- `recap` -> “运行摘要 / 状态摘要 / 会话摘要”
- `checkpoint` -> “断点 / 恢复点 / 阶段断点”

`user-facing-jargon-leak` 是可见文案重写信号，不是硬暂停信号。命中后先自动把本轮可见回复按上表改写成中文，再复扫一次；只有复扫仍失败，或同时命中 `consecutive-repeat`、`domain-token-flood`、`encoded-gibberish-blob`、`provider-artifact`、`fake-completion-sentinel` 等硬污染时，才进入暂停/阻断模板。

## 写入事务门禁

任何专业模块只要要写入正文、大纲、细纲、报告、队列、版本快照或 schema，都必须把文件系统当作权威，不得只相信工具返回、agent Done 或聊天内容。

执行规则：

1. **写前预检**：目标目录先 `mkdir -p`，再检查目录是否存在、`test -w` 是否可写，并做临时写入测试。失败时写入 `blocked_write_permission`，说明目标目录、父目录、当前用户和 ownership 修复建议，不进入下一步。
2. **写入事务**：长报告、修复队列、正文和结构化状态优先写入新文件或临时文件；需要覆盖时先生成版本快照或备份，再原子替换。禁止在目标文件不存在时反复用 Update/Edit 硬改。
3. **hook 阻断识别**：出现 `PostToolUse hook`、`PostToolUse:Edit hook returned blocking error`、`Error writing file`、`Error editing file`、`Permission denied`、`usage:` 等写入链路错误时，立即停止同一步骤，写入 `blocked_write_hook` 或 `blocked_write_permission`；不得连续重试同一 Write/Edit。
4. **write_failure_triage**：任何 Write/Edit/MultiEdit 返回 `Error writing file`、`Error editing file`、old_string not found、写后读不到内容或 hook usage 后，必须先运行确定性分诊脚本，不得说“继续执行报告落盘/继续执行审查报告落盘”，也不得再次调用同一 Write/Edit。命令格式：
   `node scripts/write-failure-triage.js --target <目标文件> --log-file <最近工具日志> --project-root <book-root> --write --json`。
   分诊结果以脚本 `status/category` 为准，并写入 `追踪/写入失败分诊/`。最低信息包括：目标路径、父目录、`file / directory / symlink` 类型、临时写入测试、hook 名称、当前用户、工作目录和恢复动作。
5. **tool_call_schema_check**：如果预检显示目录可写、没有 `Permission denied`、没有 hook stderr，而日志出现 `参数不完整`、`Invalid tool parameters`、`missing required parameter`、`file_path` 缺失、`content` 缺失或类似 schema 错误，分类为 `blocked_write_tool_call_invalid`，不是权限问题。先重建明确的写入计划：`tool=Write`、`file_path=<绝对路径或项目相对目标>`、`content=<完整报告正文来源>`；确认 `file_path` 和 `content` 都非空后，才允许对恢复报告路径进行一次纠正后的 Write。禁止再次发出参数不完整的同类调用。
6. **恢复报告路径**：分诊后只有三条路：预检通过且工具参数有效，则新建带时间戳的恢复报告路径，例如 `追踪/审查报告/恢复_YYYYMMDD_HHMMSS.md`，并在正文开头记录原目标失败原因；预检不通过则只更新/输出 `blocked_write_permission` 或 `blocked_write_hook` 诊断；工具参数无效且无法重建 `file_path + content` 时，输出 `blocked_write_tool_call_invalid`，不继续生成长正文。禁止把失败前的长草稿当作已落盘报告。
7. **落盘确认**：写入后必须重新读取文件系统确认文件存在、大小非空、内容包含关键锚点；`changed_files` 只能列出实际存在的文件。若 agent Done 但解析不到目标文件、`FileNotFoundError`、候选路径 ambiguous/noncanonical，写入 `blocked_write_missing_output`。
8. **不可伪完成**：只要写入、hook、文件存在性或门禁验证失败，`verification_result=failed`，`step_status` 不能是 `done`；必须写明最后可信产物、失败文件、下一步恢复动作。不得把未落盘内容当作完成。

### 审阅修复到正文的接受链

审阅报告发现的正文 AI 味、剧情偏离、人物状态错误或设定表达问题，不能从“修复建议报告”直接跳到正式正文编辑。必须使用候选修复链：

1. `repair_execution_plan`：列出修复项、风险、目标文件、允许写入范围和验证脚本。
2. `staged_repair_candidate`：生成候选修复稿或候选补丁；正式正文不变，或仅写入临时/候选路径。
3. `repair_machine_gate`：运行退化检测、`check-ai-patterns.js`、`normalize-punctuation.js`、事实保留检查和 `output-pollution-check.js`。涉及能力/境界/成长规则时，使用当前项目题材词，不默认写“修真”。
4. `execute_repair`：只有机器门通过、事实保留通过、输出污染为 0 后，才接受到正式资产。`review_repair` 在 strict 模式下只要 result packet 的 `changed_files` 涉及正文、大纲、细纲、设定或追踪中的正式资产，就必须携带 transactional 的 accepted chapter commit，并覆盖每个声明的正式目标；缺失、legacy 直写、目标遗漏或投影债务都会被状态机阻断，不能进入 `recheck`。
5. `recheck`：复读目标文件，确认文件存在、非空、关键锚点还在、blocking 归零，再更新 workflow 状态。

如果用户已经确认“直接改正文”，也只能跳过人工二次询问，不能跳过候选稿、机器门和复检。任何一步出现领域词循环、工具污染、Write/Edit 失败或结果包缺失，都必须停在最后可信断点。

如果 `追踪/workflow/current-task.json` 的 `repair_integrity_recovery` 存在，则此前的临时 `apply-*` 脚本、其“执行完成”报告及已归档候选稿都只是不可信历史材料。重建修复方案时必须重新读取当前正式正文与本轮可信证据；不得把旧脚本的统计、备份声明或结论当作验收依据。

### 短篇写作

默认阶段：

```text
A. 情绪目标、平台、题材方向确认
B. 对标/拆文上下文加载：读取 对标/、拆文库/、_meta.json.genre_detected
C. 题材风格包选择：genre-styles/{题材}.md；无专属包时 short-craft.md + genre-writing-formulas.md
D. 核心框架、设定.md、小节大纲.md
E. 分批正文写作：默认 2-3 节/批，批后更新已写小节摘要
F. 短篇内部连续性复核：因果、反转铺垫、人物/关系变化、伏笔/物件、情绪曲线
G. 短篇去 AI 味与格式收尾：short-format.md + short-deslop.md + 统计/退化/AI 句式脚本
H. 成稿交接：changed_files、verification_result、handoff_summary、next_recommendation
```

短篇不套长篇 Chapter Contract、State Delta Ledger、Chapter Handoff Pack 和跨卷/跨百章系统；但短篇仍必须通过 `story-workflow` 维护任务记忆、断点、completion_policy、runtime_guard、pending_action 和 result packet。短篇任务不是“轻量到可以绕过 workflow”，而是使用更短的短篇专属上下文包。

短篇 workflow packet 必须写清楚 `workflow_type=short_write | short_revision | short_deslop`，并携带 `short_story_style_pack`、`genre_style_pack`、`short_format_path`、`short_craft_path`、`short_deslop_path`、`benchmark_paths`、`deconstruction_meta`。执行 owner 由 `workflow-state-machine.js templates --json` 的最终模板决定：本地 private registry 存在时，`short_write` 可被 `private-short-extension` 接管；公开 GitHub 版本没有 private registry 时，才由 `story-short-write` 执行。如果用户说“短篇去 AI 味 / 这篇盐言太 AI / 正文.md 改自然”，先进入 `story-workflow`，再按最终 owner 路由：private 为 `private-short-extension` + `absorbed-story-short-write/short-deslop.md`，public fallback 为 `story-short-write` Phase 4 / `short-deslop.md`；不要先套长篇通用 `story-deslop`。泛化片段或未知来源文本才可交给 `story-deslop`，但必须把短篇模式作为约束传入。

短篇单节写作必须把“候选稿生成、质量门、局部修订、事务接受”拆成可恢复节点。实测 Claude Code 在短篇写作中通常能较稳定地产出新节候选稿，但在以下动作上容易长时间 thinking 且无新增可信产物：单节局部压缩、质量门单独生成、生成整篇替代候选稿。遇到这种情况不得继续换 prompt 空转：

1. **新节候选稿已落盘但质量门缺失**：先记录 `section_draft_written_without_gate`，读取候选小节实际字数和污染检查结果；最多再尝试一次“只写质量门”的窄任务。仍无产物时写 `quality_gate_pending`，保留候选稿为 `draft_unverified`，不要宣称通过。
2. **局部压缩/修订空转**：如果修订候选稿无产物，改为 `write_temp_revision`，让 Claude Code 只写 `草稿_第N节_修订.md`，不碰 canonical 正文；验证通过后把它作为完整目标资产的 staged candidate。若临时修订稿也无产物，写 `revision_stalled`，保留已接受版本并把超字数、代打感、职业合规等问题列为质量债。
3. **事务接受优先**：当候选稿已通过机器检查时，构造包含完整目标资产的 manifest，执行 `chapter-commit.js prepare`，随后执行 `chapter-commit.js accept`；不得直接替换或追加 `正文.md`。
4. **质量门必须诚实**：字数超 brief、外部机构代打、职业合规风险、旧设定污染、符号问题命中时，质量门必须标记 `revise` 或 `blocked`，不得为了流程完成写 `pass`。
5. **最后可信产物**：每次空转中断后，在 workflow 状态或可见回复中说明最后可信产物，例如“第 6 节候选稿已落盘，但质量门未完成；下一步是压缩修订或继续后续章节并登记质量债”。
6. **视角连续性门**：短篇如果锁定第一人称，后续小节必须继续从主角“我”的感知、动作和判断推进。若某一节“我”密度明显坍塌，主角主要被写成姓名或“她/他”，必须标记 `revise_pov_drift`，先回炉并在下一次事务接受前修复。
7. **终章爆点门**：最后一节不能只做安静旁白或总结散文。必须至少有一个由主角行动、证据回收、物件回扣、关系翻判或自我边界完成的情绪反扣/价值翻转/可截图句。若只剩余味，标记 `revise_weak_final_beat`。
