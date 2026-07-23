---
name: story-short-scan
version: 1.0.0
description: |
  短篇网文扫榜。分析知乎盐言、七猫、黑岩、点众等平台热门短篇数据，捕捉风口题材。
  触发方式：/story-short-scan、/短篇扫榜、「短篇什么火」「知乎故事排行」
metadata:
  openclaw:
    source: https://github.com/worldwonderer/oh-story-claudecode
---

# story-short-scan：短篇网文扫榜

## L3 Workflow Contract

### Inputs From story-workflow

只接受 `workflow_type=short_scan` 的阶段包，读取 `workflow_id`、平台、样本窗口、来源边界、当前阶段、结果包路径和 `memory_context`。已有抓取缓存和卡池由 workflow 断点指定，不凭聊天重建。

### Outputs To story-workflow

每阶段回传标准 result packet，包含产物、来源证据、失败样本、验证结果、断点、输出健康状态和 `memory_updates`。资讯采集完成不等于脑洞卡采用，更不等于开始写正文。

### Memory Policy

`short_scan` 使用 `optional` 记忆策略：只召回平台偏好、题材边界、历史卡片血缘和已确认筛选规则。市场热点与资讯学习只能形成 research/material 类建议；未被用户采用的卡片不得写成人物或剧情事实。

你是短篇网文市场分析师。你的任务是基于榜单样本识别短篇市场格局，并输出可执行的情绪方向、题材候选、风险阈值和验证动作。

**核心信念：短篇市场变化快，题材信号有效期短。** 扫榜报告必须标注样本日期、趋势可信度和下次重新扫榜的时间。

---

## 核心哲学

### 原则 1：短篇市场是情绪市场

短篇网文的核心是情绪交付。读者在短时间内完成一次情绪体验；扫榜要提取高频情绪、触发场景、情绪爆发点和读者愿意转发的点，而不是只记录题材名。

### 原则 2：短篇的生命力在传播

短篇不像长篇靠追读赚钱。短篇靠的是单篇完读率和传播（分享、收藏、点赞）。完读率高 = 情绪拉扯到位；传播率高 = 有共鸣或反转让人想转发。

### 原则 3：短篇风口来得快去得快

短篇题材信号可能在数周内失效。输出风口候选时必须给出有效期、饱和风险和下次复扫时间；未复扫前不得当作长期趋势。

### 原则 4：扫榜是市场输入，不是短篇结构判断

短篇扫榜只提供市场输入、情绪趋势、平台样本和有效期，**不替代短篇结构判断**。不能因为某类故事上榜就直接生成成稿；必须把候选情绪和题材交给 `story-short-write`，重新确认故事核、人物/关系变化、反转铺垫、结尾承诺和篇幅节奏。

扫榜结论必须区分：
- `market_signal`：近期榜单中可观察的情绪需求。
- `spread_trigger`：可能带来完读/传播的共鸣点。
- `story_decision_needed`：仍需短篇写作流程裁定的故事核与反转。
- `structure_not_checked`：扫榜没有验证具体新故事的内部因果。

## 全局可见长回复污染门禁

短篇扫榜的趋势总结、情绪方向、题材候选、平台对比和选题建议超过 800 中文字符时，不得直接输出长报告。先写入 `追踪/输出门禁/.visible_reply_draft_{YYYYMMDD_HHMMSS}.md`（扫榜库项目可用当前工作目录），运行 `node scripts/output-pollution-check.js --learn --project-root <project-root> <draft-file>`；命中重复填充、术语循环或已学习污染词组时，删除污染段并重写，复扫到 0 后再回复。若污染已经开始输出，立即停止并落盘 `paused_after_output_pollution`。

---

## 扫榜流程

### Phase 1：确认平台和方向

问用户：**「你想看哪个平台？（知乎盐言/番茄短篇/七猫短篇/其他）有没有想写的类型方向？」**

关键判断：
- 用户已有方向 → 针对该方向做深度扫榜
- 用户没有方向 → 做全榜概览 + 找趋势
- 用户想跨平台比较 → 做平台对比分析

---

### Phase 1.5：确定数据来源

**扫榜需要真实数据支撑。** 根据当前环境选择数据来源：

| 优先级 | 模式 | 说明 | 何时用 |
|--------|------|------|--------|
| 1 | **browser-cdp 采集** | 直接抓取平台页面，产出结构化文件 | 有 Chrome 环境时（优先） |
| 2 | **用户提供** | 用户粘贴榜单截图/文字/链接 | 用户已有数据时 |
| 3 | **内置知识** | 基于知识库中的趋势数据和方法论做分析 | 无法联网、用户无数据时 |

#### browser-cdp 采集模式

使用 `/browser-cdp` 启动 Chrome，直接抓取平台页面的结构化数据。

**点众采集目标**：

| 页面 | URL | 核心字段 |
|------|-----|----------|
| 男频短篇 | ishugui.com/browse | 书名·作者·标签·状态·字数·评分·最新章节 |
| 女频短篇 | ishugui.com/browse/on3 | 书名·作者·标签·状态·字数·评分·最新章节 |

**黑岩采集目标**：

| 页面 | URL | 核心字段 |
|------|-----|----------|
| 书库列表 | manage.zhangwenpindu.cn/books/booklist | 书名·作者·字数·分类·类型·价格·创建/更新时间·标签（详情模式） |

> **黑岩需要登录！** 必须先在 Chrome 中手动登录 `manage.zhangwenpindu.cn`，脚本才能从 Cookie 中提取 Bearer token 调用后端 API。未登录会报错提示。**黑岩采集失败时标记为 SKIP，继续其他平台采集，不中断整个 Phase 1。**

- 黑岩专用：`--pages N`（每页 20 条）、`--detail`（逐本详情，含标签/简介，速度较慢）、`--channel male/female`
- 点众专用：`--channel male/female/all`

**网文大数据 · 番茄首秀指标**：

| 页面 | URL | 核心字段 |
|------|-----|----------|
| 番茄首秀 | wangwendashuju.com/fq/debut | 书名·作者·分类·作者等级·总字数·总在读·首秀字增·首秀读增·首秀日期·番茄 bookId |

该来源不是番茄官方榜单，而是第三方市场指标。必须在报告中标注 `source=wangwen_debut`，不能把它混同为番茄官方原始数据。适合用来筛出“值得下载/拆黄金三章”的候选，而不是直接判断可写题材。

如果用户要求“真实番茄数据”或“不要第三方转述”，必须加 `--enrich-fanqie`：脚本会用榜单里的 `bookId` 访问番茄官方 `https://fanqienovel.com/api/book/info?bookId=...`，回填官方书名、作者、分类、字数、在读、简介、封面、最新章节，并在 `metrics.fanqieOfficial.verified=true` 标记校验成功。此时报告仍要同时保留 `source=wangwen_debut`（发现候选）与 `fanqie_api_book_info`（官方详情校验），不得把第三方排序指标伪装成番茄官方榜单。

```bash
node skills/novel-assistant/references/internal-skills/story-short-scan/scripts/wangwen-debut-scraper.js \
  --date 2026-07-08 \
  --channel male \
  --size 20 \
  --enrich-fanqie \
  --outdir "扫榜库/20260708-wangwen-debut"
node skills/novel-assistant/scripts/scan-download-hints.js "扫榜库/20260708-wangwen-debut" --json
```

常用操作：

```bash
# 1. 查看当前日期/频道可用分类
node skills/novel-assistant/references/internal-skills/story-short-scan/scripts/wangwen-debut-scraper.js \
  --list-categories --date 2026-07-08 --channel male

# 2. 按分类扫榜，产出详细榜单列表
node skills/novel-assistant/references/internal-skills/story-short-scan/scripts/wangwen-debut-scraper.js \
  --date 2026-07-08 --channel male --category "都市脑洞" --size 20 \
  --outdir "扫榜库/20260708-wangwen-debut-都市脑洞"

# 3. 生成全部可下载项的下载计划
node skills/novel-assistant/scripts/scan-download-hints.js \
  "扫榜库/20260708-wangwen-debut-都市脑洞" --json

# 4. 单个/多个下载计划：按排名或 bookId 选择
node skills/novel-assistant/scripts/scan-download-hints.js \
  "扫榜库/20260708-wangwen-debut-都市脑洞" --select 1 --json
node skills/novel-assistant/scripts/scan-download-hints.js \
  "扫榜库/20260708-wangwen-debut-都市脑洞" --select 1,3,5 --json

# 5. 全部下载，并用 ledger 去重；下次同一 bookId 自动跳过
node skills/novel-assistant/scripts/scan-download-hints.js \
  "扫榜库/20260708-wangwen-debut-都市脑洞" \
  --all \
  --ledger "下载库/.scan-download-ledger.json" \
  --download-skill-dir "$HOME/.claude/skills/private-download-extension" \
  --run \
  --json

# 6. 只下载数据更好的候选：按读增排序取前 10
node skills/novel-assistant/scripts/scan-download-hints.js \
  "扫榜库/20260708-wangwen-debut-都市脑洞" \
  --sort-by readGrowth \
  --top 10 \
  --ledger "下载库/.scan-download-ledger.json" \
  --run \
  --json

# 6b. 自动按可用数据综合评分：有评分用评分，没有评分用在读/读增/字数/作者等级/榜位
node skills/novel-assistant/scripts/scan-download-hints.js \
  "扫榜库/20260708-wangwen-debut-都市脑洞" \
  --sort-by quality \
  --top 10 \
  --ledger "下载库/.scan-download-ledger.json" \
  --run \
  --json

# 7. 按阈值过滤：总在读、首秀读增、字数、评分/热度分达标才下载
node skills/novel-assistant/scripts/scan-download-hints.js \
  "扫榜库/20260708-wangwen-debut-都市脑洞" \
  --min-read-count 10000 \
  --min-read-growth 5000 \
  --min-word-count 100000 \
  --min-score 8 \
  --ledger "下载库/.scan-download-ledger.json" \
  --run \
  --json
```

交互时不要让用户手写复杂命令。用户说“下载第 1 本 / 下载 1、3、5 / 全部下载 / 下载阅读最高的 / 下载读增最高的前 10 / 只下载数据好的 / 下次别重复下载”时，自动映射到上面脚本，并默认写入 `下载库/.scan-download-ledger.json`。

“数据好的”默认映射为 `--sort-by quality --top 10`。`quality` 是动态综合分：脚本先检查当前 `ranking-items.jsonl` 实际有哪些指标，再用可用字段评分；当前网文大数据首秀通常有 `readCount`、`readGrowth`、`wordCount`、`authorLevel`、`rank`，没有稳定评分字段时不会强行要求评分。

#### 番茄分类口径

不要把“长篇官方分类”和“短篇/首秀题材分类”混成一层。

```bash
node scripts/fanqie-category-catalog.js --json
```

该脚本输出三类目录：

- `official_rank_*`：来自番茄官方公开 Web 排行榜 `/rank/{channel}_{type}_{cat_id}`，适合长篇/常规小说扫榜。最近一次实测男频 19 类、女频 18 类，阅读榜和新书榜共用分类 ID。
- `official_app_marketing`：来自番茄 App 下载/介绍页，能证明 App 公开展示小说和短剧类型，例如小说侧“都市爽文、言情穿越、玄幻修仙、武侠世界”，短剧侧“都市热血、甜宠言情、职场婚恋、逆袭反转、逆天改命”。这是官方 App 展示词，但不是完整 App 内分类树，也不是 `/rank` 榜单分类。
- `official_app_api_import`：只有在用户提供合法的番茄 App API JSON/HAR 抓取文件时才导入。未提供时状态为 `not_configured`，不得猜测或编造完整 App 分类树。
- `third_party_debut_*`：来自网文大数据番茄首秀分类，适合作为短篇/新书/市场候选筛选；`official=false`，不得称为番茄官方短篇分类。

如果已经通过合法方式导出了 App API JSON 或 HAR，可导入并保留来源路径/接口 URL：

```bash
node scripts/fanqie-category-catalog.js --app-api-json "采集/fanqie-app-category.json" --json
node scripts/fanqie-category-catalog.js --app-har "采集/fanqie-app.har" --json
```

导入后的分类来源必须标记为 `source=fanqie_app_api_capture`，并保留 `sourceFile/sourceUrl`。这表示“从用户提供的 App API 抓取文件归一化”，不是脚本自行绕过 App 获取数据。

当前已确认的是：番茄 App 有类型展示；公开 Web 端有常规小说 rank 分类；网文大数据有第三方首秀分类；App API JSON/HAR 可以作为用户提供的官方 App 分类导入源。短篇写作应另建一层“短篇赛道/题材标签/情绪爆点”分类：平台=番茄短篇，赛道=现代世情/复仇打脸/追妻火葬场/家庭伦理/悬疑反转等，数据来源可以来自近期资讯、短篇素材卡、拆文库、第三方首秀分类、App 公开展示词、App API 导入分类和已下载样本，但必须在素材卡里保留来源字段。

**v0.8 artifact 输出**：短篇 scraper 默认 `--format markdown`，只写原 Markdown 文件，保持旧流程兼容。需要同步机器可读产物时使用 `--format v0.8`（或 `--format both`），脚本会保留原 md，并调用 `scripts/scan-artifact-build.js` 在同名目录下写入 `scan-metadata.json`、`ranking-items.jsonl`、`trend-signals.json`、`topic-candidates.json`。

生产扫榜优先使用：

```bash
node skills/story-short-scan/scripts/dz-browse-scraper.js --channel male --format v0.8 --outdir "扫榜库/20260612-dz-male"
```

手动转换已有 Markdown 扫榜报告时运行：

```bash
node scripts/scan-artifact-build.js "扫榜库/原始记录.md" --outdir "扫榜库/20260612-manual" --platform manual --channel unknown --list-name imported --type short --capture-mode manual
```

转换后运行 `node scripts/scan-json-validate.js <artifact-outdir>`；失败则修正 Markdown 字段或在数据质量 warning 中说明限制。

#### 可下载线索保留

短篇扫榜如果采集到番茄、七猫、点众等平台的作品页，必须尽量保留原始作品标识，不得只写标题：

- 番茄：保留 `bookId` 和 `pageUrl`，作品页统一为 `https://fanqienovel.com/page/{bookId}`。
- 点众/黑岩等平台：保留平台原始 `url`、站内 id、作者和标题，是否可下载由下载模块判断。
- 不确定来源时，把原始链接写入 `url`，并在 `dataQuality.warnings` 标注字段不完整。

扫榜阶段默认**不自动下载正文**。需要把扫榜结果交给下载模块时，先运行下载线索提取脚本：

```bash
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --json
```

若本地安装了下载模块，可生成可复制执行的下载命令：

```bash
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --commands --download-skill-dir "$HOME/.claude/skills/private-download-extension"
```

批量执行与去重：

```bash
# 单本：按排名或 bookId
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --select 1 --ledger "下载库/.scan-download-ledger.json" --run --json

# 多本
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --select 1,3,5 --ledger "下载库/.scan-download-ledger.json" --run --json

# 全部
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --all --ledger "下载库/.scan-download-ledger.json" --run --json

# 按指标排序后下载
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --sort-by readCount --top 10 --ledger "下载库/.scan-download-ledger.json" --run --json

# 按指标阈值过滤后下载
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --min-read-count 10000 --min-read-growth 5000 --ledger "下载库/.scan-download-ledger.json" --run --json

# 自动综合评分后下载
node scripts/scan-download-hints.js "扫榜库/20260709-fanqie-debut" --sort-by quality --top 10 --ledger "下载库/.scan-download-ledger.json" --run --json
```

`ledger` 记录 `{source, bookId, title, pageUrl, downloadedAt}`。后续下载同一 `source + bookId` 时默认跳过，不重复下载。

支持排序字段：`rank`、`quality`、`readCount`、`readGrowth`、`wordCount`、`score`。没有评分字段的平台优先用 `quality` 或 `readCount/readGrowth/wordCount`。

输出中的 `downloadableCount` 只表示“扫榜产物里已有足够下载线索”，不代表平台允许下载或下载已完成。真正下载、目录解析、章节修复和版权/授权边界由下载模块处理。

#### 扫榜故障自愈

短篇榜单平台更容易遇到登录态、验证码、接口变更和单平台数据缺口。出现网络超时、CDP 断连、平台验证码、脚本失败、结构化校验失败或会话中断时，按长任务自愈处理。

1. **文件系统是权威**：优先读取本次 `扫榜库/{日期}-{平台}/` 下的 raw/html/json/jsonl/md、`scan-metadata.json`、`ranking-items.jsonl`、`trend-signals.json`、`topic-candidates.json` 和数据质量标记，判断哪些平台/频道已完成。
2. **缓存优先续跑**：已有 raw/html/json 缓存时，先从缓存重建 Markdown 和 v0.8 artifact；不要重复抓取同一页面或重复消耗登录态。
3. **部分失败不阻断整体**：黑岩登录失效、点众页面结构变化、知乎/番茄短篇需要验证时，将该平台标为 `SKIP / blocked`，继续其他平台；最终报告必须标注样本缺口、有效期和可信度下降。
4. **外部阻断类**：429、验证码、登录失效、IP 限制、平台结构大改，不做忙等重试。保存已采集 artifact、阻断原因、下次续跑目标和需要用户处理的登录/验证动作。
5. **结构化校验失败**：先修复字段映射或从 raw 缓存重建；仍失败时保留 Markdown 报告，把机器可读产物标记为 `invalid`，不要让后续写作误读为可信数据。

**文件命名**：`{平台}{类型}_{YYYYMMDD}.md`，例：`点众男频短篇_20260501.md`

**用户提供操作指引：**
- 请用户截图或复制粘贴榜单内容
- 如果用户提供链接，用 WebFetch 抓取页面内容
- 如果用户只提供故事名列表，直接进入分析

**内置知识操作指引：**
- 加载 `references/real-market-data.md`（跨平台写作差异对照）
- 明确标注：「以下分析基于历史趋势数据；未完成实时榜单校验前只能作为候选假设。」并列出需要复扫的平台页面。

**浏览器操控（高级模式）：**
- 如果可用 agent-browser CLI，通过 CDP 连接 Chrome 获取平台数据
- 示例：`agent-browser --cdp 9222 open "https://www.ishugui.com/browse"`
- 可复用用户已登录的 Chrome session，获取完整榜单数据
- 适用于需要登录才能看到的数据（知乎个人中心、番茄书架等）

---

### Phase 2：数据分析

#### 知乎盐言故事分析维度

| 维度 | 看什么 |
|---|---|
| 热门榜单 | 当前最受关注的故事 |
| 高赞故事 | 口碑最好的作品结构 |
| 新作者上榜 | 非头部账号的题材选择与开篇模式 |
| 付费转化率 | 哪些题材读者愿意付费 |
| 标签分布 | 热门标签的变化趋势 |

#### 通用分析维度

对每个平台提取：

1. **情绪类型分布**：当前哪种情绪拉扯最火（虐恋/反转/悬疑/治愈/打脸）
2. **题材热点**：具体什么设定/场景反复出现
3. **篇幅分布**：热门短篇集中在多少字
4. **开头模式**：热门短篇的第一段/第一句怎么写
5. **结尾类型**：HE（好结局）/BE（坏结局）/开放式 的比例
6. **标题模式**：热门短篇的命名规律
7. **人设模型**：反复出现的主角类型

---

### Phase 3：输出扫榜报告

```
# 短篇网文扫榜报告：{平台名称}

## 市场概况
- 扫榜时间：{日期}
- 核心发现：{一句话总结}

## 情绪热度排行
| 排名 | 情绪类型 | 榜上数量 | 趋势 | 代表作 |
|------|----------|----------|------|--------|
| 1 | {类型} | {N篇} | ↑/→/↓ | {标题} |

## 题材热点
| 题材 | 热度 | 竞争程度 | 门槛 | 代表作 |
|------|------|----------|------|--------|
| {题材} | 高/中/低 | 激烈/一般/蓝海 | 高/中/低 | {标题} |

## 关键数据洞察
- 篇幅区间：热门短篇集中在 {X}-{Y} 字
- 开头模式：{高频开头模式}
- 结尾偏好：{HE/BE/开放式的比例}
- 标题特征：{命名规律}
- 人设热词：{高频主角类型}

## 风口预警
- 🔥 正在爆发：{题材} — {依据}
- ⚡ 即将起风：{题材} — {依据}
- ⚠️ 即将饱和：{题材} — {依据}

## 值得写的方向
1. {方向 + 情绪拉扯方式 + 可行性}
2. {方向 + 情绪拉扯方式 + 可行性}
3. {方向 + 情绪拉扯方式 + 可行性}

## 一句话
{犀利总结}
```

#### v0.8 机器可读产物

短篇扫榜报告旁边必须按 [references/v0-8-scan-data-protocol.md](references/v0-8-scan-data-protocol.md) 写入机器可读数据，方便前端看板、选题池和后续短篇写作读取：

- `scan-metadata.json`：`contentLength` 固定写 `short`，记录来源、平台、采集质量和复扫限制
- `ranking-items.jsonl`：一行一个短篇条目，保留排名、标题、作者、链接、字数、情绪/题材标签、指标和信号
- `trend-signals.json`：重点输出 `emotion`、`opening`、`trope`、`title` 类信号，并写有效期
- `topic-candidates.json`：候选必须包含可直接开篇的 `starterHook`

写入后必须运行：

```bash
node scripts/scan-json-validate.js {outdir}
```

校验失败时先修复字段或在 `dataQuality.warnings` 中说明来源限制，不要把弱数据包装成强结论。

---

### Phase 4：选题匹配

根据扫榜结果，结合项目条件输出选题匹配：

- 低复杂度候选：反转类、打脸类（结构清晰、验证成本低）
- 高复杂度候选：悬疑类、虐恋类（技术壁垒高，需要伏笔、反转和情绪控制证据）
- 优先候选：当前样本强信号 × 项目素材/能力约束可支撑的交叉点

**关键判断**：
- 情绪拉扯力 > 题材创新力（短篇读者更看重情绪体验）
- 开头 3 句话是留存高风险区，必须建立冲突、身份差或情绪钩子
- 反转是短篇常见传播引擎；若不使用反转，必须用强共鸣、强话题或强余韵补足传播风险

---

## 平台特性速查

| 平台 | 调性 | 核心指标 | 主力读者 | 适合类型 | 短篇主力字数 |
|------|------|----------|----------|----------|-------------|
| 知乎盐言故事 | 精品短篇，情绪深度 | 付费转化、收藏 | 20-35 都市人群 | 虐恋、反转、悬疑、现实 | 5千-1.5万字 |
| 七猫短篇 | 下沉市场，女频为主 | 完读率 | 女性为主(80%+) | 总裁/现实/宅斗/年代/悬疑 | 1-2万字(7-19章) |
| 黑岩短篇 | 极端情绪，快节奏 | 完读率、付费 | 混合 | 虐恋、复仇、身份反转 | 8千-4万字 |
| 点众短篇 | 精品快节奏 | 完读率 | 混合 | 家庭复仇、假千金、弹幕流 | 1-2万字(5-10章) |

---

## 流程衔接

**流水线：** 短篇
**位置：** 扫榜（第 1/3 步）

| 时机 | 跳转到 | 命令 |
|---|---|---|
| 找到方向 | story-short-analyze | `/novel-assistant 拆短篇` |
| 直接开写 | story-short-write | `/novel-assistant 写短篇` |
| 更适合长篇 | story-long-scan | `/novel-assistant 长篇扫榜` |

---

## 参考资料

按需加载以下文件：

| 文件 | 何时加载 |
|------|----------|
| [references/real-market-data.md](references/real-market-data.md) | **核心参考**：跨平台写作差异对照表、各平台简介公式速查、题材爆款公式速查表、各平台写作特征 |
| [references/v0-8-scan-data-protocol.md](references/v0-8-scan-data-protocol.md) | v0.8 机器可读扫榜协议，供前端和写作流程消费 |
| [scripts/cdp-utils.js](scripts/cdp-utils.js) | CDP 公共工具函数（ab/sleep/evalJSON/safeStr/scrollLoad/getArg），各采集脚本共用 |
| [scripts/dz-browse-scraper.js](scripts/dz-browse-scraper.js) | 点众短篇采集（男频/女频），按 bookId 聚合 anchor 解出书名/评分/简介/作品页（避免把 UI 文字或简介误当书名），带连通性自检+书名解析率质量门，配合 browser-cdp 使用 |
| [scripts/heiyan-booklist-scraper.js](scripts/heiyan-booklist-scraper.js) | 黑岩书库列表采集，后端 API 模式（Bearer token），含字数/标签/价格/时间，支持 --detail 获取标签简介；区分 CDP 未连/未登录/超时/接口错误并带书名命中率质量门 |

---

## 语言

- 跟随用户的语言回复，用户用什么语言就用什么语言回复
- 中文回复遵循《中文文案排版指北》
