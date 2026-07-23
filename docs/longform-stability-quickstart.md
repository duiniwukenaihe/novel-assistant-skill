# 长篇稳定性 Quickstart

本页用于长篇连载、回炉和批量日更后的稳定性验收。目标是让剧情可控、状态可追踪、修复可分派。

## 1. 刷新章节索引

50+ / 100+ 章项目先刷新章节索引：

```bash
bash scripts/chapter-index-build.sh --write <book-dir>
```

产物：

```text
追踪/章节索引.tsv
```

稳定性 gate 会优先按索引定位正文路径；索引不存在时才 fallback 到 `正文/第{N}章_*.md`。

## 2. 日更批量验收

写完一批章节后运行：

```bash
bash scripts/longform-daily-stability-audit.sh --write <book-dir> <start-chapter-id> <end-chapter-id>
```

它会检查：

- 每章 `Chapter Contract`
- `Plot Drift Gate`
- `State Delta`
- 角色不变量
- 相邻章节交接包继承

如果失败，报告会写入：

```text
追踪/稳定性审计/日更_第{start}章_to_第{end}章.md
```

## 3. 失败后生成当前修复任务

先生成当前 checkpoint：

```bash
bash scripts/stability-repair-loop.sh --write <book-dir> <start-chapter-id> <end-chapter-id>
```

自动化或 runner 使用 JSON：

```bash
bash scripts/stability-repair-loop.sh --write --json <book-dir> <start-chapter-id> <end-chapter-id>
```

读取重点字段：

- `current_owner`
- `current_action`
- `verification_commands`

## 4. 生成子代理 Prompt

让系统按 `current_owner` 输出标准 agent prompt：

```bash
bash scripts/stability-agent-dispatch-prompt.sh --json <book-dir> <start-chapter-id> <end-chapter-id>
```

常见分派：

| current_owner | 处理范围 |
|---|---|
| `story-architect` | 结构裁决：跑题、漏 beat、伏笔提前兑现 |
| `character-designer` | 角色裁决：动机漂移、认知泄漏 |
| `narrative-writer` | 当前 checkpoint 局部正文修补 |
| `consistency-checker` | 当前 checkpoint 复核 |

修完后按 `verification_commands` 重跑对应 gate，再重跑 `stability-repair-loop.sh --write`，直到状态为 `PASS`。

## 5. 回炉 / 大修复检

先把用户修改意图写成修订请求文件：

```md
# Revision Request

修改对象：正文/第001章_拒绝错误任务.md
修改类型：删除伏笔
修改原因：用户要求删除异常水印线索
关键词：异常水印 江临 旧账号
```

改稿后运行：

```bash
bash scripts/revision-stability-recheck.sh --write <book-dir> <request-file> <start-chapter-id> <end-chapter-id>
```

自动化场景：

```bash
bash scripts/revision-stability-recheck.sh --json <book-dir> <request-file> <start-chapter-id> <end-chapter-id>
```

该命令会串联：

1. `Revision Impact Analysis`
2. `Stability Repair Loop`
3. `Stability Agent Dispatch Prompt`

没有通过复检前，不要宣布回炉完成。
