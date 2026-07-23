# Token Cost Governance

This is the canonical token cost decision map for `novel-assistant` workflows.

## Ownership

L2 story-workflow owns model_routing_policy. L3 modules obey the packet and report actual usage, waste signals, and recovery status back to L2.

- L2 `story-workflow`: decides workflow stage, cost ledger paths, model class, batch size, retry budget, checkpoint, and visible summary budget.
- L3 professional modules: `story-long-analyze`, `story-review`, `story-long-write`, `story-deslop`, `story-import`, scan modules, and setup modules execute scoped work only.
- L3 must not silently upgrade every task to expensive reasoning. If it needs a higher model class, it returns a reason in the result packet.
- User requests for quality, depth, or a specific model override defaults, but the override must be recorded in the cost ledger.

## Model Routing Map

| model_class | Use For | Avoid |
|---|---|---|
| `cheap_extract` | deterministic extraction, counting, grep, chapter slicing, source anchoring, schema checks, existing-file inventory, simple format validation | global arbitration, prose style decisions, major plot repair |
| `standard_reasoning` | batch synthesis, normal review, ordinary outline/planning, repair queue design, chapter contract planning, deslop diagnosis | large cross-volume canon arbitration, repeated failure root cause |
| `deep_reasoning` | global architecture, major outline rewrite, cross-volume continuity arbitration, complex hook recovery, model/tool degradation root cause after cheaper path fails | counting, scanning, shell output reading, repeated retries of failed tools |

`task_complexity=mechanical/extract/low` with `model_class=deep_reasoning` records `model_mismatch`.

## Task Type Defaults

| workflow_type | stage | default model_class | cost rule |
|---|---|---|---|
| `setup` / update check | environment inventory, version check, deployment diff | `cheap_extract` | Use scripts and hashes. Do not reason over full project files. |
| `story-long-analyze` | Stage 0 inventory, Stage 0.5 sample, Stage 2 chapter summaries | `cheap_extract` | Slice source, summarize by batch, write artifacts. Do not paste source back to main thread. |
| `story-long-analyze` | Stage 3-5 aggregation, author-technique synthesis | `standard_reasoning` | Read batch summaries and evidence matrices, not full raw chapters unless conflict requires. |
| `story-long-analyze` | failed benchmark comparison or major hallucination repair | `deep_reasoning` | Use only after source-grounded evidence shows conflict. Record reason. |
| `story-review` | range inventory, AI phrase scan, canon term scan, continuity evidence collection | `cheap_extract` | Scripts produce JSON or short tables. Raw grep output is saved, not fed back. |
| `story-review` | findings synthesis, repair queue, batch verdict | `standard_reasoning` | Use prior review-state and gap ledger. Mark provisional if preceding range is missing. |
| `story-review` | cross-volume arbitration, contradictory SSOT, gap-after-backfill re-evaluation | `deep_reasoning` | Use scoped evidence bundle and stale-range list, not all chapters. |
| `story-long-write` | current progress, chapter file discovery, chapter contract checks | `cheap_extract` | Ask `story-progress-status.js` and project files; do not answer from recap memory. |
| `story-long-write` | outline/contract/refill planning, normal continuation | `standard_reasoning` | Use current volume, chapter contract, handoff, and accepted style anchors. |
| `story-long-write` | major expansion transaction, global outline rewrite, cross-volume hook recovery | `deep_reasoning` | Create impact map and shift map before writing. |
| `story-deslop` | phrase scan, punctuation scan, repeated-token scan | `cheap_extract` | Produce targeted map first. |
| `story-deslop` | rewrite suggestions and local prose repair | `standard_reasoning` | Repair only scoped text; keep accepted chapter names and good passages. |
| `story-import` | file discovery, chapter normalization, metadata extraction | `cheap_extract` | Use deterministic parsing where possible. |
| scan modules | crawler result cleanup, ranking table extraction | `cheap_extract` | Keep raw pages outside the main thread. |
| scan modules | market positioning synthesis | `standard_reasoning` | Read cleaned tables and representative samples. |

## Tool Output Policy

Raw tool output is not the model context.

1. Save long Bash, grep, test, crawler, benchmark, and MCP output to files.
2. Convert it to JSON, short tables, or an evidence index before reasoning.
3. Feed the main thread only paths, counts, changed files, failures, and next actions.
4. If output contains diffs, previous tool transcripts, provider banners, repeated terms, or `Invalid tool parameters`, run the tool-call degradation guard before reusing it.
5. A professional module may request source snippets only for conflicts, missing evidence, or user-selected inspection.

## Retry and Waste Policy

Retries are bounded by type, not by optimism.

- Same tool schema error twice: stop with `blocked_repeated_tool_failure`.
- Same pollution phrase twice: stop with `blocked_model_degradation`.
- Same provider safety error twice: stop with `blocked_provider_sensitive`.
- Same missing file/path issue twice: run write/file triage before another write.
- A retry must shrink scope, clean payload, switch to script, or change model class. Repeating the same prompt is waste.

Waste signals recorded by `token-cost-ledger.js`:

- `model_mismatch`: expensive model class used for mechanical work.
- `failure_retry_waste`: failures and retries consumed budget.
- `tool_noise_waste`: noisy tool output or too many tool calls entered the loop.
- `context_thickening_waste`: large input/output footprint suggests context buildup.
- `cache_reuse_opportunity`: reusable artifacts were likely available but not used.

## Ledger Fields

Every costly stage should append one ledger event:

```json
{
  "workflow_id": "wf-20260701-001",
  "workflow_type": "review",
  "stage": "stage-2",
  "module": "story-review",
  "model_class": "standard_reasoning",
  "task_complexity": "synthesis",
  "input_files": 20,
  "input_chars": 80000,
  "output_chars": 6000,
  "tool_calls": 4,
  "retry_count": 0,
  "failure_count": 0,
  "cache_hit": true,
  "status": "completed",
  "token_source": "host",
  "input_tokens": 1200,
  "output_tokens": 350,
  "cache_read_tokens": 800,
  "cache_write_tokens": 0,
  "estimated_tokens": 0,
  "duration_ms": 4200
}
```

### Token Provenance And Integrity

`token_source` is required for new ledger events and is exactly one of `host`, `provider`, `estimated`, or `unavailable`.

- `host` and `provider` are actual usage. They require non-negative `input_tokens` and `output_tokens`; optional cache fields and `duration_ms` are recorded when the host provides them. Character estimates must not overwrite or supplement their token totals.
- `estimated` is only for an explicit proxy calculation when no actual usage is available. A credible character/byte proxy must be recorded as `estimated`; its value belongs in `estimated_tokens`, never in actual totals.
- `unavailable` means neither complete actual usage nor a credible proxy is available. It records duration and execution metadata only.
- Negative, `NaN`, or otherwise invalid numeric fields are rejected on append. When older JSONL contains invalid values, summary safely normalizes only the affected value to zero and emits a `finding`.
- New events require a non-empty `event_id`. Appends hold a ledger-local lock and fsync the JSONL line, so concurrent replay of one invocation remains one charge. Summary also de-duplicates historical repeated IDs and emits `duplicate_event_id` rather than double-counting them.
- Stream adapters treat monotonic complete usage records as cumulative snapshots and use only the terminal snapshot. Non-monotonic complete records are treated as deltas and summed. Invalid cache or duration values do not become zero actual usage: they emit a finding and use the proxy/unavailable path.

`token-cost-summary.json` separates `actual`, `estimated`, and `unavailable` buckets. Actual totals include both `host` and `provider`, while their source counts remain visible. Retries and different hosts use stable `event_id` values; a repeated event id is ignored so replaying a runner completion does not double-count a charge. Distinct attempts remain distinct events because each attempt can consume real usage.

历史账本可以继续读取：原始 JSONL 不会被补写或改造 provenance。缺少 `token_source` 的旧 proxy event 只会在 summary 中以 `legacy_provenance_missing` finding 明示，并按其已存的 `estimated_tokens` 进入估算桶；缺少有效 proxy 值则进入 unavailable。

Required runtime paths:

- `cost_ledger_path`: `追踪/workflow/token-cost-ledger.jsonl`
- `cost_summary_path`: `追踪/workflow/token-cost-summary.json`

## Stage Completion Visibility

Cost governance is not a hidden report that the user must ask for. At every meaningful completion node, L2 must read the current summary and include a compact visible note.

Completion nodes:

- stage finished,
- batch finished,
- long agent handoff finished,
- range review report written,
- deconstruction batch written,
- bulk revision batch written,
- setup/update/migration finished.

Visible note shape:

```text
成本摘要：estimated_tokens≈12000；tool_calls=9；retry/failure=1/1；账本：追踪/workflow/token-cost-summary.json
```

If `proactive_alerts` is non-empty, L2 must show a proactive warning before next candidates:

```text
成本提醒：检测到异常 token 浪费信号 tool_noise_waste、failure_retry_waste。建议先复用已落盘批次摘要，缩小下一批范围后继续。
```

The alert type for waste signals is `abnormal_waste`. It is advisory by default: pause at the checkpoint, show the last trusted artifact, and offer a cheaper recovery path. It becomes blocking only when paired with runtime statuses such as `blocked_repeated_tool_failure`, `blocked_model_degradation`, or `blocked_provider_sensitive`.

## Supervisor Visibility

`workflow-runtime-supervisor.js` reads `runtime_guard.token_cost_governance.cost_summary_path` and returns `cost_summary_status` plus `cost_summary` when available.

Visible user summaries should say:

- which stage consumed meaningful budget,
- which waste signal appeared,
- what was reused from cache or previous artifacts,
- what the next cheaper recovery path is.

They should not dump ledger JSON unless the user asks for it.

## Active And Passive Reminders

Cost visibility has two channels.

- **Active reminders** happen at stage completion, batch completion, agent handoff completion, long report write, deconstruction batch write, review batch write, bulk revision batch write, setup/update/migration completion, and every `abnormal_waste` alert. The visible reply should show `estimated_tokens`, tool calls, retry/failure count, main waste signals, summary path, and the top saving actions.
- **Passive reminders** happen when the user asks about 成本, 成本报告, token, token 消耗, 节省 token, 为什么慢, or 为什么贵. L2 reads `追踪/workflow/token-cost-summary.json` and answers with totals, waste signals, saving actions, and paths. If the summary is missing, say the ledger has not been initialized and offer to create it for the current workflow.

`workflow-runtime-supervisor.js` exposes:

- `passive_cost_report_available`
- `cost_alerts`
- `token_saving_plan`

Runners and frontends should use these fields instead of asking the model to invent cost status from chat memory.

## Token Saving Execution Plan

The saving plan is not a reminder-only feature. `token-cost-ledger.js` writes `token_saving_plan` into the summary so workflow can change the next step.

| signal | action | execution |
|---|---|---|
| `model_mismatch` | `downgrade_model_class` | Move mechanical/extract/low tasks to `cheap_extract`; reserve `deep_reasoning` for global architecture, major outline repair, cross-volume arbitration, or repeated-failure root cause. |
| `tool_noise_waste` | `filter_tool_output` | Save raw tool output to files and feed only JSON summaries, counts, changed files, failure lists, and paths back to the main thread. |
| `context_thickening_waste` | `reuse_artifacts_before_raw_read` | Reuse indexes, batch summaries, range summaries, review-state, chapter contracts, handoff packs, and evidence matrices before reading raw chapters again. |
| `failure_retry_waste` | `stop_retry_and_triage` | Same failure type gets one corrected retry; the next attempt must use triage or a deterministic script, not another freeform prompt. |
| `cache_reuse_opportunity` | `reuse_cached_artifacts` | Read cached summaries and evidence indexes instead of reloading raw batch materials. |

Token saving must preserve coverage. Do not reduce review dimensions, skip hook checks, or silently drop continuity analysis to save cost. Save cost by removing repeated context, noisy tool output, wrong model selection, and failed retries.
