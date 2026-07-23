# chapter-handoff-pack.md：章节交接包

Chapter Handoff Pack 在每章 `State Delta Ledger` 完成后生成，用来把上一章对下一章的继承约束压缩成可读取、可落盘、可复查的交接材料。

## 何时使用

- 日更续写每章完成后，进入下一章前使用。
- 批量日更时每章都生成，不等本批全部写完。
- 回炉或改稿导致上一章事实变化后，重新生成对应交接包。
- 下一章开写前优先读取上一章交接包，再生成新的 Chapter Contract。
- 若下一章是新卷第 001 章，除了本交接包，还必须运行跨卷交接：`bash scripts/cross-volume-handoff-pack.sh --write --from-volume 第X卷 --to-volume 第Y卷 <book-dir> <上一卷末章> 001`。

## 自动生成

可用脚本：

```bash
bash scripts/chapter-handoff-pack.sh <book-dir> <chapter-id>
bash scripts/chapter-handoff-pack.sh --write <book-dir> <chapter-id>
bash scripts/chapter-handoff-pack.sh --write --volume 第X卷 <book-dir> <chapter-id>
```

默认输出 Markdown 到 stdout；`--write` 会落盘到：

```text
追踪/交接包/第X卷/第{N}章_to_第{N+1}章.md
```

旧平铺项目可省略 `--volume`，落盘到 `追踪/交接包/第{N}章_to_第{N+1}章.md`。

脚本只在对应章节 `Plot Drift Gate` 为 `Gate: PASS` 时生成交接包。Gate 未通过时必须先修正文、契约或追踪文件，不得把失败章节交接到下一章。

## 输出模板

```md
## Chapter Handoff Pack：第 N 章 -> 第 N+1 章

### 来源
- 源正文：
- 章节标题：
- 章节契约：
- 漂移门控：
- Gate:

### 下一章继承
- 章尾钩子：
- 下一章读者期待：
- 下一章细纲：
- 下一章契约：

### 最近 State Delta
- 本章改变了什么：

### 活跃伏笔
- 下一章必须记住/推进/避免提前回收的伏笔：

### 角色连续性
- 本章后角色的目标、红线、认知边界：

### 下一章必读文件
- 大纲/第X卷/细纲_第{N+1}章.md
- 正文/第X卷/第{N}章_*.md
- 追踪/上下文.md
- 追踪/伏笔.md
- 追踪/时间线.md
- 设定/角色不变量/{核心角色}.md
- 追踪/章节契约/第X卷/第{N+1}章.md

### 交接规则
- 先读本交接包，再生成第 N+1 章 Chapter Contract。
- 不得在下一章回退本章 State Delta。
- 如要删除或改写本章线索，先运行 Revision Impact Analysis。
- 第 N+1 章写完后必须重新生成新的 Chapter Handoff Pack。
```

## 执行规则

1. 交接包不是章节摘要，只记录会影响下一章的状态、钩子、伏笔和角色边界。
2. 交接包不得替代 `追踪/伏笔.md`、`追踪/时间线.md`、`追踪/角色状态.md`；它只汇总这些文件中的下一章必读信息。
3. 如果交接包发现 State Delta 和追踪文件不一致，先修追踪文件，再重新生成交接包。
4. 下一章 Chapter Contract 必须继承交接包中的章尾期待、活跃伏笔和角色连续性。
5. 跨卷时，`追踪/卷交接/第X卷_to_第Y卷.md` 是新卷首章的额外必读文件；上一卷预留的钩子/伏笔不能在新卷开篇消失。若延迟回收，必须在第 Y 卷第 001 章契约写明回收窗口。
