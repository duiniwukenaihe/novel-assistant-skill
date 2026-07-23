# Workflow

`story-workflow` is the internal workflow brain behind `/novel-assistant`. Users see one continuous command, while the workflow layer routes, remembers, resumes, and verifies multi-step writing tasks.

## Responsibilities

- Keep `/novel-assistant` as the only user-facing entry.
- Convert writing, review, analyze, deslop, setup, scan, import, repair, migration, and expansion goals into resumable tasks.
- Persist workflow memory in `追踪/workflow/`.
- Ask for confirmation at risk boundaries instead of every small step.
- Recover from recap, stale tasks, failed tool calls, polluted output, and long-running task stalls.

## L2/L3 Contract

L2 is `story-workflow`. L3 modules are professional modules such as `story-long-write`, `story-review`, `story-long-analyze`, `story-short-write`, `story-deslop`, `story-import`, `story-long-scan`, `story-short-scan`, and `story-setup`.

L2 sends a `workflow packet` to L3. It includes:

| Field | Meaning |
|---|---|
| `workflow_id` | Stable task id |
| `workflow_type` | Writing, review, analyze, setup, deslop, scan, import, revision, migration, or expansion |
| `book_root` | Current book project root |
| `scope` | Chapter range, volume, file set, or project-level scope |
| `owner_module` | Target L3 module |
| `completion_policy` | `full_auto`, `stage_then_confirm`, `step_then_confirm`, or `plan_only` |
| `read_set` / `write_set` | Allowed files and directories |
| `risk_level` | Confirmation and rollback requirement |
| `runtime_guard` | Long task runtime safety envelope |
| `next_candidates` | User-visible choices after the step |

L3 returns a `result packet` to L2. It includes:

| Field | Meaning |
|---|---|
| `step_status` | `completed`, `needs_user_choice`, `blocked`, or `failed` |
| `outputs` | Produced artifacts |
| `changed_files` | Files written or modified |
| `evidence` | Commands, report paths, source slices, or validation summaries |
| `verification_result` | Gate result, with pass/fail and failure reason |
| `blocking_reason` | Machine-readable block reason |
| `memory_updates` | Workflow memory to persist |
| `handoff_summary` | Compact handoff for the next step |
| `resume_hint` | Exact continuation hint |

L3 modules cannot independently announce that the whole workflow is complete. They report their own stage result; L2 decides whether the workflow is complete or what remains.

## Runtime Guard

Long tasks must include `runtime_guard`. This is a runtime boundary, not decorative prompt text.

Required parts:

- `token_estimate`: input files, input size, expected output, agents, and batch size.
- `adaptive_budget_policy`: how visible reply, batch handoff, and range summaries scale with task size.
- `heartbeat`: latest trusted artifact, latest write time, current batch, and completion ratio.
- `checkpoint_policy`: where to resume after interruption and which artifacts are reusable.
- `output_health_gate`: checks candidate text, reports, handoff packets, and visible replies.
- `max_retry_budget`: retry limit for model degradation, tool failures, API errors, and pollution.
- `stall_policy`: how to handle recap, long thinking, stream stall, zero-token agent completion, or no file writes.

If a long task lacks `runtime_guard`, it should be repaired before execution rather than pretending it can run unattended.

## Collaboration Mode vs Managed Mode

Stage advancement, retry budget, and context injection differ by host. The boundary is `工具循环熔断` (tool-loop circuit breaker) vs `流式 token 中止` (streaming token abort); the two are not interchangeable.

- **协作模式 (interactive Claude Code / Codex / ZCode in a long session)**: the host keeps a long, shared context. The workflow can block repeated tool loops — a `PreToolUse` budget guard pauses writes of `debug-*`/`scan-*`/`find-*`/`inspect-*` triage scripts, mutations of managed `scripts/*.js` / `.claude/hooks/`, and runaway source reads — and the stage controller caps same-stage transitions at one recovery. It **cannot** interrupt the model's hidden thinking already in flight, nor halt a streaming completion mid-generation. When the shared context has visibly bloated, it advises once that the section should be handed to managed mode; it does not claim to break thinking it cannot reach.
- **托管模式 (managed_runner)**: each section runs in a fresh subprocess that receives only the minimal `stage_context_packet` (current Brief, prior accepted anchor, relevant setting/outline summary, handoff tail, author voice card). The runner owns process-level streaming early stop: stream-health monitoring, idle/budget breach, and `SIGTERM` to the detached process group on health or budget anomaly. Only managed mode promises true streaming token abort.

Single-command stage advancement uses `scripts/workflow-stage-controller.js advance` (or the `advanceStage` library). It validates the result packet, re-checks the private overlay identity bound to the task snapshot, and resolves the next stage in one atomic transition that writes exactly one journal entry. A recoverable failure (stale state version or transient transition block) reloads the authoritative task and registry once; a second consecutive same-stage failure pauses with `retry_budget_result: exhausted` and leaves `last_trusted_artifact` unchanged. The controller never runs diagnostic commands or mutates project runtime from inside a writing workflow.

## Token Cost Governance

`Token Cost Governance` is the cost-observability layer for long and repeated workflows. It addresses `浪费不可见`: a task may pick the wrong model class, reread thick context, feed noisy tool output back into the model, or retry failed tools until the bill grows.

The canonical decision map lives in `src/internal-skills/story-workflow/references/token-cost-governance.md`. L2 `story-workflow` owns `model_routing_policy`, ledger paths, batch budget, and retry budget; L3 modules obey the packet and report actual usage plus waste signals.

The goal is `值得花和该治理分开`. Deep reasoning is valid for architecture, major outline repair, difficult debugging, and cross-volume consistency arbitration. It is wasteful for mechanical extraction, file counting, grep scans, schema validation, and repeated retries.

Required behavior:

- **过程可见**：record each expensive stage in `追踪/workflow/token-cost-ledger.jsonl`; write rollups to `追踪/workflow/token-cost-summary.json`.
- **经验可沉淀**：record `model_routing_policy` decisions so later similar tasks can choose `cheap_extract`, `standard_reasoning`, or `deep_reasoning` intentionally.
- **实验可回放**：benchmark and upstream-comparison runs must keep inputs, skill bundle, batch plan, cost ledger, and output paths.
- **工具输出不原样喂给模型**：raw Bash, grep, node, MCP, and test output should be saved to files and summarized before the main thread reads it.
- **Failure budget**：same failure type gets at most one corrected retry. A second failure becomes a blocked state with the last trusted checkpoint.
- **主动提醒**：stage, batch, agent handoff, long report, deconstruction, review, bulk revision, and setup/update completion should automatically show a short cost summary. Abnormal waste signals must proactively notify the user before next candidates; the user should not need to ask for cost status.
- **被动查询**：when the user asks about 成本, token, 消耗, 为什么慢, 为什么贵, or 节省 token, workflow reads `token-cost-summary.json` and reports totals, waste signals, `token_saving_plan`, and paths.
- **节省 token**：the system saves cost by reusing indexes, batch summaries, range-summary, review-state, chapter contracts, handoff packs, and evidence matrices before raw reads; filtering long tool output; stopping repeated failures; and routing mechanical work away from expensive reasoning.

Runtime scripts:

```bash
node scripts/token-cost-ledger.js init --project-root <book-root> --workflow-id <id> --workflow-type review --json
node scripts/token-cost-ledger.js append --project-root <book-root> --workflow-id <id> --stage stage-2 --module story-review --model-class standard_reasoning --input-files 20 --input-chars 80000 --output-chars 6000 --tool-calls 4 --retry-count 0 --failure-count 0 --json
node scripts/token-cost-ledger.js summary --project-root <book-root> --workflow-id <id> --json
```

## Pending Action

`pending_action` binds short replies such as `1`, `继续`, `下一步`, `e`, and `E` to the current task only.

It must include:

- `workflow_id`
- `book_root`
- `created_at`
- `expires_at`
- `visible_choice_hash`
- `expected_reply_set`
- `render_mode`
- `fallback`

If the user switches books, refreshes after choices changed, or replies after expiry, the workflow must redisplay current candidates instead of executing an old action.

## Startup Task Inbox

Startup recovery is workflow-first, not a flat dump of every unfinished subtask.

After update/setup checks and `workflow-runtime-supervisor.js`, run `workflow-task-inbox.js` to build `追踪/workflow/task-index.json` from metadata-only state files. The first visible menu shows large workflow groups such as long-form writing, short-form creation, review/repair, deconstruction/learning, download/import, and maintenance. Only after the user chooses a group should the workflow show unfinished tasks inside that group.

When a task completes, the workflow should prefer explicit `recommended_next` from the result packet or `current-task.json`. If missing, `workflow-task-inbox.js` may derive `post_completion_recommendations` from `workflow_type` and `completed_step`. These recommendations are shown as the next menu, not executed automatically.

### Task And Subtask Navigation

Multi-stage work uses three visible levels. They must not be collapsed into one menu:

1. **Task list**: show the whole task, such as an entire-story revision. Do not expose an internal section as if it were the task.
2. **Task overview**: show all stage groups, preserved ranges, closure steps, current subtask, objective, and completion rule. Entering this level is read-only and must not auto-start a stage.
3. **Current subtask**: only after the user chooses to continue does the workflow show executable actions for the current section, chapter, review batch, or repair unit.

For an existing draft, the current subtask is `recheck existing -> repair deviations -> gates -> reaccept`, not `write from scratch`. Accepted or unaffected sections remain preserved and only re-enter at the final whole-story continuity review. Chat feedback stays attached to the current subtask; if it changes planning, Workflow first updates the affected upstream assets and then returns to the same subtask checkpoint.

## Completion Semantics

Workflow candidates must tell the user what happens after the selected action. Ambiguous options such as “先修 A 级问题” or “仅执行本项” are not enough unless the remaining workflow is visible.

Use these labels consistently:

- **只执行本项**：execute only the selected step. After completion, show `remaining_stages` and ask what to do next.
- **继续后续阶段**：finish the selected stage and continue into the next safe stage. Stop at overwrite, migration, broad revision, provider, permission, or high-risk write boundaries.
- **完成整个流程**：allowed only for bounded, low-risk, fully verifiable flows. It must run final gates and set `current-task.json.status=completed`.

`current-task.json` should preserve:

```json
{
  "completion_policy": "stage_then_confirm",
  "current_stage": "A",
  "current_step": "A1",
  "remaining_stages": ["B", "C", "D"],
  "next_candidates": [
    {"number": 1, "label": "只执行本项：修复 A1", "action": "run_step"},
    {"number": 2, "label": "继续后续阶段：完成 A 后进入 B", "action": "continue_stage"},
    {"number": 3, "label": "完成整个流程：执行 A-D 并收束验证", "action": "finish_workflow"}
  ]
}
```

This is especially important after review reports produce multiple S1/S2/S3 repair groups. If the user picks a high-value subset, the workflow must not imply that all repair work is done.

## Outline, Review, And Deconstruction Gates

Three upstream-derived hardening gates are now named explicitly:

- `outline_to_draft_gate`: opening a book, changing an outline, expanding a volume, or repairing pacing must pass the minimum outline/detail-outline readiness gate before drafting. For longform this usually means setting/core promise/volume outline/detailed outline or chapter contract. For shortform this means material card, setting, section outline, and style card when needed. Do not jump from vague intent to正文.
- `review_gap_reconciliation`: range review must track gaps. Reviewing 1-200 and then 300-400 is allowed, but 201-299 must be marked as an unreviewed gap, continuity conclusions are provisional, and later backfill of 201-299 can mark 300-400 stale.
- `full_auto_deconstruction`: when the user asks for complete longform deconstruction, the default is recoverable batch automation. Stop only for missing source, account/quota, overwrite risk, grounding failure, output-health failure, or explicit user interruption.

## Review Gap Reconciliation

Range review can be contiguous, adjacent, overlapping, skipped, or backfilled. Non-contiguous review must mark `review gap` risk.

Example:

- User reviews 1-200.
- User then asks for 300-400.
- The workflow may run 300-400, but it must mark 201-299 as a gap and treat continuity conclusions as provisional.
- If 201-299 is later reviewed and changes hook, plot, timeline, or character state assumptions, `review-state-ledger.js` updates `追踪/review-state.json` and marks affected later reports stale through `dependency_hashes` and `suggested_recheck_ranges`.

This keeps batch review efficient without pretending skipped ranges are safe.

## Expansion Transaction

扩容事务协议 applies when the user inserts chapters, expands a volume, slows pacing, moves old chapters back, contracts chapters, or merges chapters.

The order is fixed:

```text
impact analysis
-> shift map
-> version snapshot
-> shift old assets first
-> fill new gaps
-> sync outline, volume outline, detailed outline, body, chapter contracts, handoff packs, foreshadows, timeline, and character state
-> Revision Stability Recheck
```

Chapter number is a placement label, not chapter identity. Preserve original chapter titles and reusable prose by default. Migration fixes layout; expansion fixes story pacing. Do not mix them in one implicit action.

## Longform Lifecycle From The Author's View

The author still uses only `/novel-assistant`. For a new book, the visible path is positioning, story bible, master outline and review, current-volume outline and review, current-stage detailed outline and review, chapter Brief and review, then prose. Accepted prose is committed with its memory update; milestone review decides whether to plan another stage, accept the volume and hand off to the next volume, or enter whole-book acceptance.

An existing book resumes from the nearest trustworthy lifecycle asset. The workflow recommends the missing review or planning layer instead of mechanically suggesting the next chapter. Volume and whole-book review remain one author-facing task even when evidence is partitioned internally.

Free-form feedback is welcome at every visible stage. Local prose feedback returns to prose; Brief, stage, volume, or master-outline feedback returns to the matching planning layer. Downstream assets are marked for recheck, while accepted prose is preserved until an impact analysis proves that a separate revision transaction is required.

Expansion first shows impact, shift, snapshot, and synchronization scope. Cross-volume work creates a handoff pack before the next volume opens and audits the first chapter afterward. Supported legacy projects always preview lifecycle migration first; migration writes metadata and an archival snapshot only after confirmation, never rewrites creative assets.

Production smoke covers new-book layering, existing-book recovery, volume review, feedback rollback, structural expansion, cross-volume handoff, and legacy migration. It also verifies that source internal skills and bundled copies remain byte-identical. Real model trial writing and local installation on Claude Code, Codex, and ZCode are release-candidate checks performed outside deterministic repository tests.

## Output Health Gate

The output health gate blocks model and workflow pollution before text becomes visible or enters project files.

It checks:

- repeated lines
- n-gram loops
- low-information long output
- engineering term leaks
- provider artifacts
- fake completion sentinels
- model degradation loops
- contaminated tool payloads

Polluted output is discarded, not polished. The workflow shrinks the task and retries once. Repeated failure becomes `blocked_output_pollution` or `blocked_model_degradation` with the last trusted checkpoint preserved.
