# 盲读者与去 AI 误伤率校准协议

## 目的

去 AI 检测器只提供风险信号，不替代编辑判断。盲读用于校准两类错误：把作者认可的自然表达误判为 AI 味，以及漏掉真实工程词泄漏、复读或模板化退化。

## 盲读包

生成校准盲读包：

```bash
node scripts/prose-quality-benchmark.js --blind-packet --json
```

裁决前的每个条目只包含不透明 `id` 和 `text`；包级 `packetId` / `packetDigest` 只用于绑定本次内容。盲读包不得包含或暗示标签、预期检测结果、模型、生成器、修订版本、来源、分类或作者认可状态。

盲读者逐条给出 `retain`、`revise` 或 `reject`，并记录可定位的文本证据。先锁定独立裁决，再揭示语料标签和来源元数据；不得先看检测结论再倒推阅读意见。

## 可验证锁定与揭示

盲裁必须留下顺序可核验的产物。先以 `packetId` 和 `packetDigest` 填写 verdict JSON（`schemaVersion=1.0.0`、每个 `id` 恰有一条 verdict 和非空 evidence），再锁定：

```bash
node scripts/prose-quality-benchmark.js --blind-packet --json > blind-packet.json
node scripts/prose-quality-benchmark.js --lock-verdict verdict.json --json > blind-verdict-lock.json
```

锁定产物中的 `lockedVerdictHash` 是其规范化 `lockedPayload` 的 SHA-256；它不含标签或 provenance。保存该文件后才允许揭示：

```bash
node scripts/prose-quality-benchmark.js --reveal blind-verdict-lock.json --json > blind-verdict-reveal.json
```

`--reveal` 会拒绝 hash 被篡改、条目缺失/重复、空 evidence，或与当前盲包不匹配的锁定产物。揭示文件同时保存 `lockedAt`、`revealedAt`、锁定 hash、verdict 与揭示元数据，供审阅报告引用。没有已验证 lock artifact 的所谓“盲读结论”只能标为未完成校准，不能作为独立裁决证据。

## 校准语料与指标

固定语料位于 `tests/fixtures/prose-quality/`，当前 `corpusVersion=v1`。`accepted.jsonl` 只允许 `expectedDetection=false`，`rejected.jsonl` 只允许 `expectedDetection=true`，`boundary.jsonl` 必须以 `boundaryDisposition=accepted|rejected` 和 `boundaryReason` 明确已裁定的边界。三组均不得为空，ID 必须唯一且安全，整体必须同时支持正类和负类；否则基准拒绝运行而非把零分母伪装成零错误率。它必须持续覆盖：

- 有叙事功能的破折号。
- 合理的“不是 X，是 Y”对比。
- 自然短段和作者认可文本。
- 真实工程词泄漏与重复退化。
- 已知可能漏检的模板化文本。

运行基准并记录观察值：

```bash
node scripts/prose-quality-benchmark.js --json > reports/verification/prose-quality-baseline.json
```

报告必须包含 `precision`、`recall`、`falsePositiveRate`、`falseNegativeRate`、`corpusVersion`、`detectorVersion`、逐项 `misses`、版本化 `aggregationPolicy`、按 `advisory` / `blocking` 分层的 finding 与 record 计数，以及 `sourceIdentity`。聚合政策当前为 `severity-any-v1`：任一 advisory 或 blocking finding 都算“检测到”；政策变更必须升版本。指标的分母若不可用必须标 `unavailable` 或拒绝 corpus，绝不能输出伪造的 `0`。阈值只能在观察到基线后讨论，不得预设一个为了过测的数字。

`sourceIdentity` 以 benchmark 源码哈希、语料原始内容哈希和检测器源码哈希作为可比较的绑定身份，并记录可取得的 Git commit/tree 作为运行上下文。基线复用前必须与新运行的三类内容哈希一致；不一致即为 stale evidence，需重跑并人工说明指标变化。Git commit/tree 因提交基线本身而变化时只用于追溯，不单独判 stale。

fixture 的 `provenance` 强制使用 `claimStatus=self-declared`。它只记录夹具的声明来源，不能冒充已经由作者、模型供应方或外部样本独立验证的事实；真实来源需要单独的可追溯证据。

## 裁决规则

- `em-dash`、`not-is-comparison`、短段或单个套话命中本身都不是改写指令；先判断它在场景中的功能、密度和作者声音。
- 工程词泄漏、逐字破折号化、占位符、截断和可验证复读属于强证据，但仍需在报告中保留原文位置。
- 每次基准运行都保留误报和漏报；不得仅为使当前语料变绿而放宽或收紧检测器。
- 作者认可样章与已确认声口发生冲突时，默认保留原句并标记 `[需复核]`，除非存在独立的硬污染证据或作者明确要求修改。
