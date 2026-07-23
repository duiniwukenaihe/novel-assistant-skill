# v0.9 Production Loop Gate

v0.9 production loop 是长篇日更、续写和批量生产的收口门禁。它把 Markdown 追踪、v0.8 schema、当前章节契约和 doctor 体检串成一个可重复执行的闭环，避免章节写完但结构化状态没有同步。

## 执行顺序

1. **Schema build**：正文、追踪、交接包或章节契约有变更后，运行 `node scripts/story-schema-build.js <book-project-dir> --write`，刷新 `追踪/schema/` 下的结构化状态。
2. **Current contract build**：进入第 N 章正文前，或第 N 章完成后复核，运行 `node scripts/current-contract-build.js <book-project-dir> --chapter <N> --write`，生成 `追踪/schema/current-contract.json`。
3. **Context Pack build**：进入第 N 章正文前，运行 `node scripts/context-pack-build.js <book-project-dir> --chapter <N> --write`（卷目录项目加 `--volume 第X卷`），生成 `追踪/context-pack/第NNN章.json` 或 `追踪/context-pack/第X卷/第NNN章.json`。
4. **Doctor**：批次结束、进入下一章前，运行 `node scripts/oh-story-doctor.js <book-project-dir> --mode draft --write`。自动化模式可用 `--json` 读取结果。
5. **Gate read**：读取 gate/doctor 的 `gate.status` 或等价状态字段，按 fail/warn/pass 分流。

## Gate 行为

- `fail`：硬阻塞。先修复缺失目录、章节契约、正文、交接包、schema 校验错误或 doctor 报告中的失败项；不得进入下一章，不得汇报批次完成。
- `warn`：软阻塞。可以继续，但必须在本章完成说明和交接包中记录风险、证据不足项、下章继承约束，并更新 chapter handoff。
- `pass`：允许进入下一章或结束当前批次，但仍需保留 doctor report 和 schema 产物。

## Chapter Handoff 更新

每章完成后，先更新 State Delta Ledger，再生成或刷新 `追踪/交接包/第XXX章_to_第YYY章.md`。若 gate 返回 `warn`，交接包必须补充：

- 本章未完全验证的角色状态、伏笔、时间线或世界观约束；
- 下一章必须继承的契约项；
- 需要复查的 `doctor` warning 或 schema warning；
- 对 `current-contract.json` 的影响说明。

## 最小验证命令

```bash
node scripts/story-schema-build.js <book-project-dir> --write
node scripts/current-contract-build.js <book-project-dir> --chapter <N> --write
node scripts/context-pack-build.js <book-project-dir> --chapter <N> --write
node scripts/oh-story-doctor.js <book-project-dir> --mode draft --write
node scripts/story-schema-validate.js <book-project-dir>
```

这些命令失败时，先修复项目文件和结构化产物，再继续写作流程。
