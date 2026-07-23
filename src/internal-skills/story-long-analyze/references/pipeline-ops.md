# 管道运维参考

story-long-analyze 拆解管道的运维工具文档：`_progress.md` 模板、错误处理、恢复机制操作步骤。

> 质量阈值（置信度 / 覆盖率 / 重叠率）见 [material-decomposition.md 质量阈值体系](material-decomposition.md)。

---

## _progress.md 模板

```markdown
# 深度拆解进度：{书名}
- 小说：{标题} | 总章数：{N} | 输出目录：{路径} | 开始：{日期}
- 最终状态：{pending/paused_after_stage1/completed/completed_with_errors}
- schema_version: 3
## 管道进度
| 阶段 | 状态 | 进度 | 备注 |
|------|------|------|------|
## 章节边界（Stage 0.5 产物，唯一权威；完整版见 章节切片索引.jsonl）
| 章号 | 标题 | 起始行 | 字数 | 批次 |
|------|------|--------|------|------|
## 分块进度
| 块 | 章节 | 状态 |
## 失败记录
| 类型 | 章节/阶段 | 错误信息 | 重试状态 |
|------|----------|---------|---------|
## 质量检查
| 检查项 | 阶段 | 结果 | 修正 |
## 角色合并
| 合并前 | 合并后 | 依据 | 确认 |
## 断点
- 最后处理：第{N}章 | 当前阶段 | 下一操作
```

**schema_version 说明**：

| 版本 | 含义 |
|------|------|
| 缺 / 1 | 旧版 `_progress.md`，没有「章节边界」表。续跑时按下方「恢复机制操作步骤」步骤 0 触发 lazy migration |
| 2 | 含「章节边界」表（Stage 0.5 产物）。Stage 1/2/6 全部以该表为切片真值，不再各自跑 regex |
| 3 | 含 `章节切片索引.jsonl` + `批次计划.json`。Stage 1/2/6 以 JSONL 的 offset/line 为切片真值，Stage 2 以批次计划推进 |

**最终状态值说明**：

| 状态值 | 含义 |
|--------|------|
| `pending` | 管道进行中，尚未跑完 |
| `paused_after_stage1` | Stage 1 停靠点暂停——Stage 0/1 已完成，已产出 `快速预览.md`，等待用户决定是否继续 Stage 2-6。续跑时跳过 Stage 0/1，从 Stage 2 开始 |
| `paused_at_batch_boundary` | 为避免上下文/时间超限，主动停在 Stage 2 或后续聚合的安全批次边界；`断点` 必须写清下一阶段、下一章号或下一块 |
| `completed` | 全管道 Stage 0-6 完成 |
| `completed_with_errors` | 全管道完成，但有单章/单阶段失败（详见「失败记录」表，拆文报告中注明） |

---

## 错误处理

| 场景 | 处理 |
|------|------|
| 章节识别失败 | 提示确认格式；支持自定义正则 |
| 分块中断 | 读 `_progress.md` 断点恢复；长篇应主动停在 `paused_at_batch_boundary`，不要等上下文超限后被动中断 |
| 聚合质量不达标 | 孤立情节二次分类；阈值放宽至 0.5 |
| 角色合并冲突 | 记录待确认列表 |
| 输出目录冲突 | 追加不覆盖；冲突标 `[重新分析]` |
| API error / timeout / stream stall / UI 停靠 | 运行恢复探针，按第一缺口自动续跑 |
| 429 / Token Plan / quota / usage limit | 写 `_recovery-state.json` 和断点后熔断；不循环重试 |
| `_progress.md` 与摘要文件冲突 | 以 `章节/第N章_摘要.md` 的实际连续完成范围为准，修正断点 |
| agent 不可用 | 先安全刷新 setup；仍不可用时按 bounded fast fallback，不静默串行深拆超大书 |

---

## 自愈状态探针

异常后续跑、重启后恢复、继续拆书前，优先运行内部探针：

```bash
node scripts/long-analyze-recovery-state.js "拆文库/{书名}" --write --json
```

有日志时追加 `--log <日志路径>`。探针产出 `_recovery-state.json`，字段含义：

| 字段 | 含义 |
|------|------|
| `totalChapters` | 总章数，来自 `_progress.md`、`批次计划.json`、`章节切片索引.jsonl` 或章节摘要兜底 |
| `summaryCount` | 已落盘摘要文件总数 |
| `continuousComplete` | 从第 1 章起连续完成到第几章 |
| `firstMissing` | 第一缺口；Stage 2 续跑的优先起点 |
| `stage` | `stage2_resume` / `stage3_to_5_resume` / `stage6_resume` / `complete` / `needs_plan_or_source` |
| `action` | `resume_from_first_missing` / `aggregate_and_report` / `generate_style_profile` / `rebuild_plan` / `external_blocked_quota` 等 |
| `lastError` | 日志分类结果；用于区分可恢复异常和外部阻断 |

自愈边界：

1. timeout、API error、stream stall、工具临时失败：可自动重启并续跑。
2. 单章执行失败：同模型重试 1 次；质量失败：升级模型重试 1 次。
3. 同一进程连续自动重启最多 3 次；超过后写失败记录并停在安全断点。
4. quota / Token Plan / usage limit 不做忙等重试，等待配额恢复或运行层更换供应商/模型后再续。
5. 多源冲突、原文丢失、章节切片无法唯一确定时，先尝试从 `原文/` 自动重建；仍不唯一才询问用户。

---

## 恢复机制操作步骤

0. **schema_version 检测 + 章节切片 lazy migration**（在读取断点前）：
   - 若 `_progress.md` 缺 `schema_version` 字段或值 `< 2` → 视为 v1 旧文件
   - 若 `schema_version < 3` 或缺 `章节切片索引.jsonl` / `批次计划.json`，优先定位 `原文/原文.txt`、`原文/原文.md` 或用户提供的源文件，执行 `node scripts/long-analyze-plan.js <原文文件> <拆文库目录> --write --json --batch-size 30` 补建索引
   - 若无法定位原文，但 `_progress.md` 已有「章节边界」表，按 v2 兼容续跑；后续只使用表内行号，不重扫全书
   - 这是 lazy migration——不阻断 resume，旧 `paused_after_stage1` 状态原样保留；用户感知是「续跑前多花数秒补建索引和批次计划」
   - 若 regex 也匹配不到任何章节（旧库章节前缀不标准）→ 不强行迁移，记录 `_progress.md` 失败行 `schema_migration: failed: 无法识别章节分隔符`，由用户人工处理
1. 管道启动时检查输出目录是否已有 `_progress.md` 或 `章节/`
2. 如有，运行自愈状态探针并读取 `_recovery-state.json`
3. 探针 `action=resume_from_first_missing` 或断点状态为 `paused_after_stage1` → 跳过 Stage 0/1，从 `firstMissing` 继续 Stage 2，不重跑已完成的概要、黄金三章和摘要
4. 探针 `action=aggregate_and_report` → 从 Stage 3-5 继续；`action=generate_style_profile` → 只补 Stage 6
5. `paused_at_batch_boundary` → 与探针结果交叉验证；若不同，以实际摘要连续完成范围为准
6. 其他断点状态 → 从探针给出的第一缺口或缺失阶段恢复；只有无法定位 source 时才请求用户裁定

## 长篇批次边界规范

批次边界是内部断点，不是用户确认点。正常情况下完成一个批次后继续下一批；不得每完成一个批次就要求用户继续。

只有当前会话已接近上下文/时间边界、出现需要用户裁决的严重 source 冲突、或用户明确暂停时，才主动停在批次边界并写：

```markdown
- 最终状态：paused_at_batch_boundary
## 断点
- 最后处理：第{B}章 | Stage 2 逐章摘要 | 下一操作：从第{B+1}章继续本阶段
```

对用户只输出一句可执行续跑提示：

```text
已完成第 A-B 章摘要并落盘。下次输入 `/novel-assistant 继续拆《{书名}》`，会从第 {B+1} 章继续。
```

禁止输出不可执行的总耗时估计、上下文风险提醒或换会话提醒。
