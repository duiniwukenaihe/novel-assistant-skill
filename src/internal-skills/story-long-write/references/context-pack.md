# context-pack.md：最小上下文包

Context Pack 是写作/审阅前的最小上下文包，用来替代“每次把所有追踪文件和前文都塞进 prompt”。它把当前任务真正会写错的材料压缩成结构化 JSON，并保留 sourceFiles 方便需要时回读原文。

## 生成命令

```bash
node scripts/context-pack-build.js <book-project-dir> --chapter <N> --write --json
node scripts/context-pack-build.js <book-project-dir> --chapter <N> --volume 第X卷 --write --json
```

写入路径：

- 旧平铺项目：`追踪/context-pack/第NNN章.json`
- 卷目录项目：`追踪/context-pack/第X卷/第NNN章.json`

## 包含内容

| 字段 | 用途 |
|---|---|
| `sourceFiles` | 本章细纲、卷纲、章节契约、上一章交接包、上一章正文、追踪文件、角色档案来源 |
| `summary.mustCarryForward` | 本章必须继承的剧情、钩子、状态、承诺 |
| `summary.forbiddenChanges` | 本章不得提前揭示、不得改变、不得越界的事项 |
| `summary.openForeshadows` | 当前仍需推进/保留/回收的伏笔和钩子 |
| `summary.characterState` | 相关角色当前目标、关系、能力、资源、认知边界；缺 `追踪/角色状态.md` 时从角色档案降级组装 |
| `summary.recentStateDelta` | 最近 State Delta / 上下文摘要 |
| `summary.timeline` | 与当前章和上一章相关的时间线节点 |
| `summary.continuityQuestions` | 写作或审阅前必须回答的连续性问题 |
| `gaps` | 缺失证据与降级来源 |

## 使用规则

1. 写正文前先生成或读取 Context Pack，再进入 Chapter Contract / narrative-writer prompt。
2. 审阅批次前为批次首章、尾章和边界衔接章生成 Context Pack，用它判断剧情、人物、伏笔是否连续。
3. `gate.status=fail` 时不得进入正文；`warn` 时可以继续，但必须把 gaps 写入本章风险说明和交接包。
4. Context Pack 不是新的事实来源。它只压缩已有文件；发现冲突时回读 `sourceFiles`。
5. 不要把聊天记忆当作 Context Pack 的替代品。

## 为什么需要它

长篇项目最容易失控的不是“忘了读某个文件”，而是每次读太多，模型在大上下文里混淆重点。Context Pack 把上下文变成稳定小包：本章要继承什么、不能破坏什么、哪些人物状态必须持续、哪些钩子仍未兑现。这样既省 token，也减少跨章断线。
