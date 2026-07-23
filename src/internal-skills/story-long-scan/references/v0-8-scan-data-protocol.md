# v0.8 扫榜数据协议

本协议用于把扫榜结果稳定输出给前端、统计脚本和后续写作流程。Markdown 报告仍然面向作者阅读；以下 JSON/JSONL 文件是机器可读契约。

## 目录

每次扫榜落盘到 `扫榜库/{scanId}/`：

```text
扫榜库/
  20260612-qidian-newsign/
    scan-metadata.json
    ranking-items.jsonl
    trend-signals.json
    topic-candidates.json
    report.md
```

## scan-metadata.json

```json
{
  "schemaVersion": "0.8.0",
  "scanId": "20260612-qidian-newsign",
  "platform": "qidian",
  "platformName": "起点中文网",
  "channel": "male",
  "board": "newsign",
  "contentLength": "long",
  "sourceUrl": "https://www.qidian.com/rank/newsign/",
  "captureMode": "mobile-ssr",
  "capturedAt": "2026-06-12T10:00:00+08:00",
  "dataQuality": {
    "status": "ok",
    "validItems": 20,
    "rawItems": 20,
    "warnings": []
  }
}
```

字段约束：

| 字段 | 说明 |
|---|---|
| `schemaVersion` | 当前固定为 `0.8.0` |
| `scanId` | 全局唯一，建议 `{YYYYMMDD}-{platform}-{board}` |
| `platform` | `qidian`、`fanqie`、`jjwxc`、`qimao`、`zhihu`、`heiyan`、`dianzhong` 等 |
| `channel` | `male`、`female`、`all`，未知可省略 |
| `contentLength` | `long` 或 `short` |
| `captureMode` | `mobile-ssr`、`cdp`、`api`、`provided`、`manual`、`ai` |
| `dataQuality.status` | `ok`、`sparse`、`partial`、`dirty`、`failed` |

## ranking-items.jsonl

一行一个作品。必填：`rank`、`title`、`author`、`url`。

```json
{"rank":1,"title":"旧账号异常水印","author":"示例作者","url":"https://example.com/book/1","genre":"都市高武","tags":["高武","账号流"],"wordCount":320000,"heat":"总推荐 120000","summary":"主角发现被封禁的旧账号仍在替自己完成任务。","updateText":"2026-06-12 第88章","metrics":{"recommendCount":120000},"signals":["高武上升","账号流"],"dataQuality":"ok"}
```

推荐指标字段：

| 字段 | 说明 |
|---|---|
| `metrics.recommendCount` | 推荐票、推荐值 |
| `metrics.readCount` | 在读、阅读量 |
| `metrics.bookmarkCount` | 收藏 |
| `metrics.nutritionCount` | 营养液 |
| `metrics.reviewCount` | 评论数 |
| `metrics.score` | 平台评分或热度分 |

## trend-signals.json

```json
{
  "scanId": "20260612-qidian-newsign",
  "signals": [
    {
      "id": "S-urban-gaowu-rise",
      "kind": "genre",
      "label": "都市高武回升",
      "strength": 0.78,
      "evidenceCount": 5,
      "representativeTitles": ["旧账号异常水印"],
      "validUntil": "2026-06-26",
      "risk": "竞争升温"
    }
  ]
}
```

`strength` 为 0 到 1。`kind` 推荐使用：`genre`、`emotion`、`trope`、`title`、`opening`、`platform`。

## topic-candidates.json

```json
{
  "scanId": "20260612-qidian-newsign",
  "candidates": [
    {
      "id": "T-urban-gaowu-account",
      "title": "旧账号异常水印 + 都市高武",
      "platformFit": ["qidian", "fanqie"],
      "difficulty": "medium",
      "expectedLength": "80-150万字",
      "whyNow": "新人榜出现高武/账号类卖点。",
      "starterHook": "主角发现被封禁的旧账号仍在替自己完成任务。",
      "risks": ["设定解释成本高"],
      "nextValidation": "拆 3 本同类新书黄金三章"
    }
  ]
}
```

## 生成要求

1. 每份 Markdown 扫榜报告旁边必须生成以上 4 个机器可读文件。
2. 写入后运行 `node scripts/scan-json-validate.js 扫榜库/{scanId}`。
3. 校验失败时不要进入选题结论，先修复采集字段或把 `dataQuality.status` 标为对应问题。
4. 用户提供榜单或 AI 归纳时也要生成同结构文件，并把 `captureMode` 标为 `provided`、`manual` 或 `ai`。
5. 短篇扫榜复用同一协议，`contentLength` 写 `short`，`signals.kind` 可偏向 `emotion`、`opening`、`title`。
