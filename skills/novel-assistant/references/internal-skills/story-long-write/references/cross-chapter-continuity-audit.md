# cross-chapter-continuity-audit.md：跨章连续性审计

Cross Chapter Continuity Audit 在第 N+1 章写完后执行，用来确认第 N 章的 Chapter Handoff Pack 已被下一章契约和正文继承。

## 何时使用

- 批量日更写到第 2 章及以后时，对相邻章节对执行。
- 修改第 N 章或第 N+1 章后，重新生成交接包并重跑审计。
- 用户反馈“下一章没接上”“伏笔断了”“角色状态回退”时优先使用。
- 如果相邻关系跨卷，例如第 1 卷末章 -> 第 2 卷第 001 章，还必须额外使用 `cross-volume-handoff-pack.sh` 与 `cross-volume-continuity-audit.sh`，检查上一卷预留钩子/伏笔是否进入下一卷卷纲、首章契约和首章正文。

## 自动审计

可用脚本：

```bash
bash scripts/cross-chapter-continuity-audit.sh <book-dir> <previous-chapter-id> [next-chapter-id]
bash scripts/cross-chapter-continuity-audit.sh --volume 第X卷 <book-dir> <previous-chapter-id> [next-chapter-id]
```

脚本会读取：

- `追踪/交接包/第X卷/第{N}章_to_第{N+1}章.md`
- `追踪/章节契约/第X卷/第{N+1}章.md`
- `正文/第X卷/第{N+1}章_*.md`

旧平铺项目可省略 `--volume`，脚本会回退读取旧路径。

并检查交接包中的角色、活跃伏笔和下一章追查/推进目标是否同时出现在下一章 Chapter Contract 与正文中。缺失时输出 `Continuity_Missing`。

## 输出模板

```md
## Cross Chapter Continuity Audit：第 N 章 -> 第 N+1 章

### 来源
- 交接包：
- 下一章契约：
- 下一章正文：

### 继承关键词
| keyword | contract | body | result |
|---|---|---|---|
|  | OK/MISS | OK/MISS | OK/Continuity_Missing |

### 结论
- Audit: PASS/FAIL
- code: Continuity_Missing
```

## 执行规则

1. 下一章 Chapter Contract 必须显式继承上一章交接包中的章尾期待、活跃伏笔和角色连续性。
2. 下一章正文必须实际呈现继承项；只在契约里写到但正文没写，仍视为 `Continuity_Missing`。
3. 如果审计失败，先修下一章契约和正文，再重跑 Plot Drift Gate、State Delta Ledger、Chapter Handoff Pack。
4. 审计只检查相邻章继承，不替代全书级伏笔盘点和时间线审查。
5. 跨卷审计失败时，不能只补普通交接包；必须修 `追踪/卷交接/第X卷_to_第Y卷.md`、下一卷卷纲、首章契约或正文中的承接缺口。
