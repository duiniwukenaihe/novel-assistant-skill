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
| `captureMode` | `mobile-ssr`、`cdp`、`api`、`app-api-capture`、`provided`、`manual`、`ai` |
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

### 下载线索字段

扫榜产物必须尽量保留平台原始标识，方便后续下载、拆文或前端跳转。扫榜本身不自动下载正文。

番茄作品推荐写法：

```json
{"rank":1,"title":"星：我就翻个垃圾，你就曝光我？","author":"布萝泥鸭","url":"https://fanqienovel.com/page/7646009040631254078","metrics":{"bookId":"7646009040631254078","readCount":12345},"dataQuality":"ok"}
```

字段约束：

| 字段 | 说明 |
|---|---|
| `url` | 作品原始详情页；番茄统一优先写 `https://fanqienovel.com/page/{bookId}` |
| `metrics.bookId` | 平台作品 id；番茄必须保留，其他平台有站内 id 时也可保留 |
| `metrics.pageUrl` | 当 `url` 被其他跳转链接占用时，保留 canonical 作品页 |
| `metrics.downloadable` | 可选布尔值；只表示“字段足够交给下载模块尝试”，不是已下载 |

需要从扫榜产物提取下载线索时运行：

```bash
node scripts/scan-download-hints.js 扫榜库/{scanId} --json
```

该脚本读取 `ranking-items.jsonl`，输出 `downloadableCount` 和每本书的 `pageUrl/bookId/downloadCommand`。它不会下载正文。

### 番茄 App 分类导入来源

如果扫榜或选题卡使用了番茄 App API JSON/HAR 导入的分类目录，必须在相关产物中保留来源，不得只写“番茄分类”四个字：

```json
{"source":"fanqie_app_api_capture","sourceFile":"采集/fanqie-app.har","sourceUrl":"https://api5-normal-lq.fqnovel.com/reading/user/category","section":"短篇","id":"501","name":"复仇打脸"}
```

字段约束：

| 字段 | 说明 |
|---|---|
| `source` | 固定为 `fanqie_app_api_capture` |
| `sourceFile` | 用户提供的合法 JSON/HAR 抓取文件路径 |
| `sourceUrl` | HAR 中对应接口 URL；纯 JSON 导入可省略 |
| `section` | App 上级分组，例如短篇、短剧、小说频道等 |
| `id/name` | App 接口返回的分类 id 与名称 |

没有 `sourceFile` 的 App 分类不得标记为 `fanqie_app_api_capture`；只有 App 介绍页展示词时使用 `official_app_marketing`，只有网文大数据首秀分类时使用 `wangwen_debut`。

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
