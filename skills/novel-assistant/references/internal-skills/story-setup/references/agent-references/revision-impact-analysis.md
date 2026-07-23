# revision-impact-analysis.md：改稿影响分析

Revision Impact Analysis 在修改正文、大纲、设定或伏笔前执行，用来避免局部修改破坏后续连续性。

## 何时使用

- 用户要求修改、回炉、重写某章。
- 用户要求提前回收或删除伏笔。
- 用户要求改变角色动机、关系、能力、身份。
- 用户要求改卷纲、细纲或世界规则。

## 先不要使用的情况

如果请求包含 `【阶段上下文】`、`当前阶段`、`当前审阅文件` 或 `只处理当前阶段相关问题`，且用户是在审阅当前阶段产物、表达不认同、要求节奏变慢、登场后移或补过渡，先使用 `workflow-review-feedback.md` 做用户反馈摄取和 `追踪/审阅反馈.md` 落盘。只有用户确认要执行跨阶段改稿、已写正文修改、章节重排或批量同步，才升级到 Revision Impact Analysis。

## 可选自动扫描

在正式改稿前，可以先把用户请求写成修订请求文件，然后运行：

```bash
bash scripts/revision-impact-scan.sh <book-dir> <request-file>
```

修订请求文件建议格式：

```md
# Revision Request

修改对象：正文/第001章_拒绝错误任务.md
修改类型：删除伏笔
修改原因：用户要求删除异常水印线索
关键词：异常水印 江临 旧账号
```

扫描器会根据关键词命中正文、大纲、追踪和设定文件，生成影响范围、风险码与建议同步顺序。它是改稿前的证据起点，不代替人工判断；完成修改后仍必须重新运行 Plot Drift Gate，并写入 State Delta。

## 生命周期影响契约

正式扫描前，先使用 `scripts/lib/lifecycle-impact.js` 建立反馈影响链：

1. `classifyFeedbackImpact(feedback)` 将请求固定归为 `prose|brief|detail_outline|volume_outline|master_outline`，多项变化取最高层级。
2. `invalidateDownstream(graph, changedAsset)` 沿 `depends_on` 传播影响，但只返回生命周期 metadata 计划。
3. `buildReplanActions(impact)` 给出必须返回的计划节点和保留动作；它不执行文件修改。

失效传播只有三种结果：

- `needs_recheck`：已接受的下游规划资产需要复核，不代表内容已错误。
- `invalidated`：尚未接受的下游候选不再可作为可信输入。
- `preserve_until_proven_invalid`：已接受正文继续作为可信历史资产保留，直到逐项证据证明具体段落必须回炉。

传播结果中的 `delete_assets` 和 `overwrite_assets` 必须为空。影响分析不得删除、清空、覆盖 accepted prose，也不得把“上游变化”直接等同于“全文重写”。确需修改正文时，另建高风险修订事务，先快照、列出精确范围并取得用户确认。

## 结构变更回退

扩容、缩容、插章、合并和删章一律先返回计划层影响分析，不能在正文文件上直接移动、拼接或删除。章节级结构变化至少返回 `stage_detail_outline`；若同时改变卷目标或全书主线，则分别提升到 `volume_outline` 或 `master_outline`。

回退前必须冻结并保留：

- 原章节号、章节名称、核心事件、人物状态、章尾钩子和伏笔回收位置。
- 可复用的 accepted prose、Brief 与细纲片段，以及各自 revision 和来源依赖。
- 章节移动/保留/合并/删除候选映射；“删除候选”只表示待分析，不授权删除 accepted prose。

影响分析完成后，先迁移编号和依赖 metadata，再补新增计划内容。章节名称默认保留；可复用内容默认保留并标记 `preserve_until_proven_invalid`。只有精确证据证明内容与新结构冲突时，才把对应资产转入独立回炉事务。

## 全书级影响分析安全协议

当修改请求属于“全书级 / 整卷级 / 多章扩容 / 章节重排 / 删除或提前回收长线伏笔 / 修改核心设定或主线承诺”时，Revision Impact Analysis 必须先批次化，避免一次性通读全书导致超时或上下文断裂。

1. **先生成影响批次计划**：
   - 优先读取 `追踪/章节资产.jsonl`；不存在时运行 `bash scripts/chapter-index-build.sh --write <book-dir>`。
   - 将影响范围拆成：设定/大纲批次、当前卷批次、已写正文批次、后续细纲批次、追踪文件批次。
   - 写入 `追踪/修订影响/影响批次计划.md`，字段包括批次号、范围、命中文件、风险码、状态、下一操作。
2. **每批只读取命中文件和相邻章节**：
   - 正文批次只读命中章节、前一章、后一章，以及相关细纲/章节契约。
   - 追踪批次只读相关伏笔、时间线、角色状态、上下文摘要条目。
   - 不把全部正文、全部细纲、全部追踪文件一次放进 prompt。
3. **先偏移/迁移，再补洞**：
   - 如果用户要求扩容、插章、卷内重排，先生成章节移动/保留清单，保护原章节名和可复用内容。
   - 先完成路径/序号/资产索引迁移，再补新增章节大纲和细纲；不得边写新增章节边让旧章节悬空。
4. **批次落盘与断点**：
   - 每批输出 `追踪/修订影响/批次_{NNN}_{范围}.md`。
   - 接近时间或上下文边界时，停在批次边界，计划状态写 `paused_at_batch_boundary`，下一步明确到批次号和章节范围。
5. **合并总影响报告**：
   - 所有批次完成后，只读取批次报告摘要，合并为 `追踪/修订影响/全书影响报告.md`。
   - 总报告必须给出执行顺序：先改设定/大纲，还是先迁移章节，哪些正文需回炉，哪些伏笔要后续回收。
   - 总报告、批次报告和修复方案落盘后必须运行 `node scripts/output-pollution-check.js --learn --project-root <book-dir> <报告文件>`。命中重复填充、占位符污染或已学习污染词组时，本轮报告无效：回到污染前事实点重写，复扫到 0 后才可继续执行修改。

## 改后稳定性复检

完成正文、细纲、设定或追踪文件修改后，必须把本次修订请求和受影响章节范围交给统一复检入口：

```bash
bash scripts/revision-stability-recheck.sh <book-dir> <request-file> <start-chapter-id> <end-chapter-id>
bash scripts/revision-stability-recheck.sh --write <book-dir> <request-file> <start-chapter-id> <end-chapter-id>
bash scripts/revision-stability-recheck.sh --json <book-dir> <request-file> <start-chapter-id> <end-chapter-id>
bash scripts/revision-stability-recheck.sh --write --volume 第X卷 <book-dir> <request-file> <start-chapter-id> <end-chapter-id>
bash scripts/revision-stability-recheck.sh --json --volume 第X卷 <book-dir> <request-file> <start-chapter-id> <end-chapter-id>
```

该入口会串联：

1. `Revision Impact Analysis`：保留改稿前影响证据。
2. `Stability Repair Loop`：对受影响章节执行改后稳定性闭环。
3. `Stability Agent Dispatch Prompt`：如果闭环失败，输出当前 checkpoint 对应的标准 agent prompt。

`--write` 会写入 `追踪/稳定性审计/回炉复检_第{start}章_to_第{end}章.md`；卷目录项目必须带 `--volume 第X卷`，报告写入 `追踪/稳定性审计/第X卷/回炉复检_第{start}章_to_第{end}章.md`。`--json` 用于 runner 或 agent 编排，读取 `status`、`volume`、`current_owner`、`current_action`、`agent_call` 和 `revision_report_path`。

## 输出模板

```md
## Revision Impact Analysis

### 修改请求
- 修改对象：
- 修改类型：
- 修改原因：

### 影响范围
| 范围 | 文件 | 影响 | 必须同步 |
|---|---|---|---|
| 正文 |  |  | 是/否 |
| 细纲 |  |  | 是/否 |
| 角色状态 |  |  | 是/否 |
| 伏笔 |  |  | 是/否 |
| 时间线 |  |  | 是/否 |
| 设定 |  |  | 是/否 |

### 风险
- 主线风险：
- 角色风险：
- 伏笔风险：
- 平台/读者期待风险：

### 建议执行顺序
1. 
2. 
3. 
```

## 执行规则

1. 先输出影响分析，再修改文件。
2. 修改后必须运行 `scripts/revision-stability-recheck.sh`；不得只凭人工检查宣布回炉完成。
3. 如果复检输出 `agent_call`，先处理当前 `current_action`，不得跳到其他问题。
4. 如果正文改变了状态但追踪文件未同步，输出 `State_Not_Updated`。
5. 如果新增事实未入设定或追踪，输出 `Untracked_Addition`。
6. 用户确认只改局部时，也必须检查前后一章衔接。
7. 任何修复方案、审查报告或回炉复检报告出现术语重复填充时，先运行 `output-pollution-check.js --learn` 沉淀为当前书硬规则，再重写污染段；不得把污染报告当作已完成依据。
