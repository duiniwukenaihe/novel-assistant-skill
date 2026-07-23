# workflow-revision.md：大修工作流

本文件为"大修/回炉"场景的完整指引。SKILL.md 路由到本文件后，按以下流程执行。

---

## 适用条件

- 用户说"修改第X章""回炉第X章""重写第X章"
- 目标：修改已写好的章节内容

> 用户必须指定章节号或章节名。无法自动推断需要修改哪一章。

> 如果请求带有阶段上下文（`【阶段上下文】`、`当前阶段`、`当前审阅文件`、`只处理当前阶段相关问题`），且用户只是审阅当前大纲/卷纲/细纲/正文并提出意见，先转 `workflow-review-feedback.md`。只有用户明确要求执行已写正文修改、批量重排章节或按影响分析开改，才回到本大修流程。

---

## Step 1：定位章节

1. 先确认当前卷（默认 `第1卷`；如果用户在前端/上下文中选择了 `第X卷`，以选择为准）。
2. 根据"第X章"优先找到卷内文件：`正文/第X卷/第{X}章_*.md`。旧平铺项目才回退 `正文/第{X}章_*.md`。
3. 如果用户说的是章节名而非编号，用 `find 正文/ -name "*{关键词}*"` 搜索；命中多卷时先让用户确认卷。
3. 找不到时让用户确认具体章节
4. 如果用户指定段落范围（"第3-5段"/"那场打斗"/"对话部分"），记录为局部修改目标

---

## Step 2：加载上下文

加载比日常写作更多的上下文（因为修改需要理解前后衔接）：

| 序号 | 文件 | 用途 | 如果不存在 |
|------|------|------|-----------|
| 1 | `正文/第X卷/第{X}章_*.md`（旧项目回退 `正文/第{X}章_*.md`） | 待修改章节 | 必须存在 |
| 2 | `大纲/第X卷/第{X}章.md`（旧项目回退 `大纲/细纲_第{X}章.md`） | 原始写作计划 | 跳过 |
| 3 | `正文/第X卷/第{X-1}章_*.md`（旧项目回退 `正文/第{X-1}章_*.md`） | 前一章（衔接） | 第1章时加载 `设定/世界观/背景设定.md` 替代 |
| 4 | `正文/第X卷/第{X+1}章_*.md`（旧项目回退 `正文/第{X+1}章_*.md`） | 后一章（衔接） | 末章时检查 `大纲/第X卷/第{X+1}章.md`（如有）确保连续性 |
| 5 | `追踪/伏笔.md` | 涉及的伏笔 | 跳过 |
| 6 | `设定/角色/{相关角色}.md` | 本章涉及角色 | 跳过 |

**相关角色判定**：从卷内细纲 `大纲/第X卷/第{X}章.md` 中提取角色名；旧项目回退 `大纲/细纲_第{X}章.md`。如果细纲不存在，从待修改章节正文中搜索 `设定/角色/` 目录下的角色名关键词。将角色名映射为文件名：`设定/角色/{角色名}.md`。

---

## Step 3：修改

0. **Revision Impact Analysis**：加载 `references/revision-impact-analysis.md`，先输出修改影响分析，覆盖 `正文/第X卷/`、`大纲/第X卷/第{X}章.md`、`追踪/角色状态.md`、`追踪/伏笔.md`、`追踪/时间线.md`、`设定/` 六类影响面，并要求用户确认后再进入编辑
1. **阅读原文**：读完整章内容，记录原始字数
2. **备份原文**：卷目录项目将原文复制为 `正文/第X卷/.versions/第{X}章_章名_原稿_{YYYYMMDDHHmmss}.md`；旧项目回退 `正文/.versions/第{X}章_章名_原稿_{YYYYMMDDHHmmss}.md`，确保可回退且不污染正文列表
3. **确认修改范围**：问用户是"全文重写"还是"修改特定段落"
   - 全文重写：基于细纲重新写，保留备份
   - 局部修改：只改指定段落（按场景序号或关键词定位），保持其他部分不变
4. **执行修改**：改写文件
5. **确定性退化与标点收尾**：对修改后的正文文件先运行 `node scripts/check-degeneration.js --check --fail-on=blocking <正文文件>`，再运行 `node scripts/normalize-punctuation.js <正文文件>`，随后运行 `node scripts/check-ai-patterns.js --check --fail-on=blocking <正文文件>`。`check-degeneration.js` 命中逐字复读、截断、占位拒绝语或纯工程词泄露时，必须重写受影响段落；`check-ai-patterns.js` 命中“先否定再肯定 / 否定铺垫后肯定翻转”、破折号密度失控或逐字破折号化时，必须改掉并复扫到 0。单个少量有功能破折号是 advisory，不得因此判定整章失败。narrative-writer agent 不运行本脚本时，由主会话在 agent 返回后针对实际落盘文件运行。
6. **正文门禁**：运行 `node scripts/story-prose-gate.js <book-dir> --chapter {X} --write`。它会检查卷目录正文、破折号/省略号残留、逐字破折号化坏稿和旧平铺重复章节污染。失败时先修正文或迁移旧文件，再重跑确定性退化/标点收尾、AI 句式复扫和正文门禁。
7. **退化、破折号密度门禁与 AI 句式门禁**：正文标题行以外破折号允许合理少量、有功能使用，破折号密度失控必须回炉重写；逐字破折号化、逐字复读、截断、占位拒绝语或纯工程词泄露必须回炉重写；先否定再肯定的翻转句式必须复扫到 0。命中即视为 AI 味和收尾失败，先运行 `check-degeneration.js` / `normalize-punctuation.js` / `check-ai-patterns.js` 或人工改成动作、短句、逗号/句号断开，不得宣布回炉完成。
8. **字数对比**：修改后与原文字数差异 > 30% 或 > 800 字时提醒用户（取较大值）

**资料研究（按需）**：如果修改涉及需要验证的外部事实（历史年代、地理方位、职业细节等），spawn `story-researcher` agent 搜索验证。

---

## Step 4：级联检查

修改完成后，逐一检查是否影响后续章节：

1. **伏笔检查**：对比修改前后的伏笔列表（读取旧快照 vs 新内容），标记变化项：
   - 新增伏笔 → 添加到 `追踪/伏笔.md`
   - 删除伏笔 → 从 `追踪/伏笔.md` 移除，并检查后续章节是否引用该伏笔
   - 修改伏笔 → 更新描述，检查后续引用是否一致
2. **时间线检查**：对比修改前后的事件顺序，更新 `追踪/时间线.md`
3. **Revision Stability Recheck**：加载 `references/revision-impact-analysis.md`、`references/stability-repair-loop.md` 和 `references/stability-agent-dispatch-prompts.md`，卷目录项目运行 `bash scripts/revision-stability-recheck.sh --write --volume 第X卷 <book-dir> <request-file> <start-chapter-id> <end-chapter-id>`；runner/agent 编排可运行 `bash scripts/revision-stability-recheck.sh --json --volume 第X卷 <book-dir> <request-file> <start-chapter-id> <end-chapter-id>` 读取 `status`、`volume`、`current_owner`、`current_action` 与 `agent_call`。旧平铺项目可省略 `--volume`。如果输出 `Agent(subagent_type: "...")`，按 `stability-agent-dispatch-prompt.sh` 生成的当前 checkpoint prompt 分派修复；不得跳过闭环直接宣布回炉完成。若正文改变的角色、关系、资源、能力、伏笔或时间线未同步到追踪文件，报告 `State_Not_Updated`；如果新增人物、设定、支线、势力、规则或重要物件未记录到对应设定/追踪文件，报告 `Untracked_Addition`
4. **输出污染复查与学习**：回炉复检报告、修复清单、修复方案或长段审查结论落盘后，运行 `node scripts/output-pollution-check.js --learn --project-root <book-dir> <报告文件>`。命中“修真进度阈值”这类重复填充或已学习污染规则时，先回退污染段并重写；脚本会把污染短语沉淀到 `追踪/schema/output-pollution-rules.jsonl`、`user-style-rules.jsonl` 和 `设定/作者风格/禁用表达.md`。复扫不通过不得汇报回炉完成。
5. **后续影响**：如果修改改变了角色状态/关系/世界观设定，扫描后续章节正文标记受影响项：

```
⚠️ 修改第{X}章后，以下章节可能需要同步调整：
- 第{X+1}章：{原因}（建议检查）
- 第{X+3}章：{原因}（建议检查）
```

6. **正文元信息扫描**：检查标题行以外是否混入 `第[一二三四五六七八九十百千万两0-9]+章|上一章|上章|前一章|本章|这一章|前文|后文|伏笔|细纲|读者` 这类写作工程词，命中即改成角色当下可感知的事件锚点或相对时间；故事内真实阅读/讨论“第X章”或真实读者身份语境除外
7. **正文门禁复查**：重跑 `node scripts/check-degeneration.js --check --fail-on=blocking <正文文件>`、`node scripts/check-ai-patterns.js --check --fail-on=blocking <正文文件>` 和 `node scripts/story-prose-gate.js <book-dir> --chapter {X} --write`；任一 blocking 或正文门禁失败时不得进入完成汇报。
8. **禁用词扫描**：对照 `references/banned-words.md` 检查修改后的内容
9. **闭环完成条件**：只有 `Revision Stability Recheck` 状态为 `PASS`，正文门禁通过，且输出污染复查通过，或所有 `current_action` 已完成且重跑 `stability-repair-loop.sh --write --volume 第X卷` 返回 PASS，才能汇报"大修/回炉完成"；旧平铺项目才省略 `--volume`

---

## Step 5：质量检查

对修改后的章节执行 Phase 5 质量检查（至少包含）：

1. **禁用词扫描**：如 Step 4 未覆盖全章，再次扫描
2. **正文元信息扫描**：标题行以外不得出现 `第[一二三四五六七八九十百千万两0-9]+章|上一章|上章|前一章|本章|这一章|前文|后文|伏笔|细纲|读者` 这类写作工程词；故事内真实阅读/讨论“第X章”或真实读者身份语境除外
3. **正文门禁**：运行 `node scripts/check-degeneration.js --check --fail-on=blocking <正文文件>`、`node scripts/check-ai-patterns.js --check --fail-on=blocking <正文文件>` 和 `node scripts/story-prose-gate.js <book-dir> --chapter {X} --write`，退化、AI 翻转句式、破折号密度失控、省略号滥用、逐字破折号化或旧平铺污染不通过时不得宣布修改完成；少量有功能破折号只作为 advisory 复核
4. **人物一致性**：修改后的角色行为是否与角色设定一致
5. **节奏检查**：修改是否破坏了章节节奏

> 完整 Phase 5 检查清单见 SKILL.md Phase 5。

---

## 常见问题

| 问题 | 处理 |
|------|------|
| 用户没说改哪里 | 问"你想改哪一章？哪方面？情节/节奏/对话/描写？" |
| 修改后字数暴增/暴减 | 提醒用户，由用户决定是否调整 |
| 连续改多章 | 逐章修改，每章独立执行 Step 2-5 |
| 改完发现后续不一致 | 列出受影响章节，由用户决定是否现在修改 |
