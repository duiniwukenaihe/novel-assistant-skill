# v0.8 长篇写作状态协议

本协议用于把长篇写作的稳定性状态输出给前端和自动检查脚本。Markdown 仍然用于作者阅读；`追踪/schema/` 下的 JSON/JSONL 是机器可读契约。

## 目录

```text
追踪/
  schema/
    story-state.json
    chapters.jsonl
    promises.jsonl
    plot-units.jsonl
    expansion-gaps.jsonl
    health.json
    beat-sheets/
      第001章.json
```

写作每章后必须刷新这些文件。日更批量结束后必须再刷新一次 `health.json`。

## story-state.json

```json
{
  "schemaVersion": "0.8.0",
  "bookTitle": "旧账号异常水印",
  "mode": "longform",
  "currentChapter": 1,
  "currentVolume": "第1卷",
  "status": "drafting",
  "updatedAt": "2026-06-12T10:00:00+08:00",
  "activeArc": "主角拒绝错误任务后追查旧账号",
  "nextAction": {
    "id": "write-next-chapter",
    "label": "写第002章",
    "reason": "第001章交接包已生成，下一章细纲存在"
  }
}
```

`status` 推荐值：`planning`、`drafting`、`revising`、`paused`、`finished`。

## chapters.jsonl

一行一个章节：

```json
{"chapterId":"第001章","chapterNo":1,"title":"拒绝错误任务","volume":"第1卷","outlinePath":"大纲/细纲_第001章.md","contractPath":"追踪/章节契约/第001章.md","draftPath":"正文/第001章_拒绝错误任务.md","handoffPath":"追踪/交接包/第001章_to_第002章.md","auditStatus":"pass","wordCount":3200,"updatedAt":"2026-06-12T10:00:00+08:00"}
```

新项目推荐卷内路径，并增加卷内章号、全书草稿顺序与章节资产 ID：

```json
{"chapterId":"第001章","chapterNo":1,"title":"拒绝错误任务","volume":"第1卷","volumeChapterNo":1,"globalDraftOrder":1,"assetId":"asset-20260621-0001","outlinePath":"大纲/第1卷/细纲_第001章.md","contractPath":"追踪/章节契约/第1卷/第001章.md","draftPath":"正文/第1卷/第001章_拒绝错误任务.md","handoffPath":"追踪/交接包/第1卷/第001章_to_第002章.md","auditStatus":"pass","wordCount":3200,"updatedAt":"2026-06-21T10:00:00+08:00"}
```

旧项目的扁平路径仍可校验，但升级后应由 `/novel-assistant 准备写书` 或 `node scripts/story-project-migrate.js <book-project-dir> --write` 迁移到卷内结构。`chapterNo` 保持全书草稿顺序，`volumeChapterNo` 表示卷内编号；发布全书连续编号由 `publish-export.js` 输出到 `导出/发布版/`，不得反向改写正文目录。

`auditStatus` 推荐值：`pass`、`warn`、`fail`、`missing`。

## promises.jsonl

一行一个伏笔、承诺、悬念或爽点债：

```json
{"id":"P-旧账号水印","type":"foreshadowing","introducedIn":"第001章","status":"open","expectedPayoffRange":"第020-030章","owner":"story-architect","description":"异常水印暗示旧账号不是普通账号","risk":"early_payoff"}
```

`status` 只能是：`open`、`warming`、`paid_off`、`deferred`、`dropped`、`conflict`。

伏笔状态不得只靠扫描 Markdown 重建。章节事务 manifest 可提交 `promise_deltas`，动作使用 `open / advance / close / defer / drop`；接受后由 chapter commit 幂等写入 `promises.jsonl` 和 `追踪/story-system/promise-events.jsonl`。重复 replay 不得制造第二条事件。

## plot-units.jsonl

一行一个本书剧情单元。只有细纲显式提供 `PU-...` 才建立单元，不为旧细纲猜造 ID。已有正文的单元为 `hard`，未写单元为 `soft`；扩容或上层规划变化只能把未写单元标成 `stale`，不得重写已接受正文。

```json
{"id":"PU-V01-001","volume":"第1卷","chapterRange":{"start":1,"end":4},"planningMode":"hard","planningState":"active_locked_prefix","chapters":[{"volumeChapterNo":1,"beatPosition":"1/4","drafted":true}]}
```

`expansion-gaps.jsonl` 记录扩容后尚待填充的卷内范围。状态为 `pending` 时，工作流必须先补卷纲、细纲和章节契约，再写正文；不得用临时“过渡章”标题填空。

## beat-sheets/第XXX章.json

每章正文写作前后都要保留 beat sheet，让前端和审稿流程知道本章必须交付什么。

```json
{
  "schemaVersion": "0.8.0",
  "chapterId": "第001章",
  "contractPath": "追踪/章节契约/第001章.md",
  "beats": [
    {
      "id": "B1",
      "type": "conflict",
      "summary": "主角公开拒绝错误任务",
      "emotion": "压迫",
      "mustShowOnPage": true,
      "promiseIds": ["P-旧账号水印"],
      "expectedPayoff": false
    }
  ],
  "required": {
    "conflictBeat": true,
    "emotionTurn": true,
    "chapterEndHook": true
  }
}
```

`beats[].type` 推荐值：`setup`、`conflict`、`choice`、`reveal`、`payoff`、`hook`、`emotion_turn`。

### 可选 qualityGate

通过细纲质量审阅的章节可以附带下列对象。它保留审阅时的细纲身份，供后续构建和校验判断结果是否仍然新鲜；旧 beat sheet 可以省略此对象。

```json
{
  "qualityGate": {
    "version": "detail_outline_quality_v1",
    "status": "pass",
    "outlinePath": "大纲/第1卷/细纲_第001章.md",
    "outlineSha256": "64 位小写十六进制 SHA-256",
    "activatedDimensions": ["C5_suspense_progression"]
  }
}
```

`status` 只能是 `pass` 或 `pass_with_advisory`；`outlineSha256` 必须匹配 `/^[a-f0-9]{64}$/`；`activatedDimensions` 是字符串数组。`story-schema-validate.js` 会校验已出现的对象，但不会要求旧项目补写它。

## health.json

```json
{
  "schemaVersion": "0.8.0",
  "status": "warn",
  "updatedAt": "2026-06-12T10:00:00+08:00",
  "summary": {
    "chapters": 1,
    "openPromises": 1,
    "overduePromises": 0,
    "failedAudits": 0,
    "missingBeatSheets": 0
  },
  "issues": [
    {
      "code": "Promise_Open",
      "severity": "P3",
      "target": "P-旧账号水印",
      "message": "伏笔已建立，等待后续升温",
      "suggestedAction": "第002章交接包继续继承该伏笔"
    }
  ]
}
```

`status` 只能是 `pass`、`warn`、`fail`。`severity` 只能是 `P0`、`P1`、`P2`、`P3`。

## 刷新时机

1. 建书/建纲后：创建 `story-state.json`、空 `chapters.jsonl`、空 `promises.jsonl` 和 `health.json`。
2. 生成 Chapter Contract 后：创建或刷新对应 `beat-sheets/第XXX章.json`。
3. 正文和 Plot Drift Gate 后：追加/更新 `chapters.jsonl` 的章节记录。
4. State Delta Ledger 后：追加/更新 `promises.jsonl`。
5. Handoff Pack 和 Daily Stability Audit 后：刷新 `story-state.json` 和 `health.json`。
6. 大修/回炉后：受影响章节、伏笔和 health 必须同步更新。

## 校验

在写作批次结束前运行：

```bash
node scripts/story-schema-validate.js <book-project-dir>
```

校验失败时不得声称写作状态已稳定，先修复缺失文件、非法状态或不完整 beat sheet。
