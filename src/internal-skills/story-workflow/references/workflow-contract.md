# Workflow Contract

This is the canonical L2/L3 workflow contract for `novel-assistant`.

## Ownership

`story-workflow` owns orchestration. Professional modules own domain execution. The boundary is strict:

- L2 creates workflow packet data, task memory, stage navigation, checkpoints, `pending_action`, and `completion_policy`.
- L2 owns the durable task directory: `追踪/workflow/tasks/<workflow_id>/task.json`, `rpd.md`, `context.jsonl`, `verify.jsonl`, `journal.jsonl`, `result-packets/`, and `artifacts/`.
- L3 receives scoped work, reads/writes only the authorized files, performs professional judgment, and returns a result packet.
- L3 modules do not declare the whole workflow complete.

## durable task directory

Every new workflow should have a Trellis-inspired task directory under `追踪/workflow/tasks/<workflow_id>/`. `current-task.json` is only the active UI pointer, while `tasks/<workflow_id>/task.json` is the durable task-local authority.

Required files:

| File | Owner | Purpose |
|---|---|---|
| `task.json` | L2 | Machine-readable task authority; never reconstructed from UI focus. |
| `rpd.md` | L2, user-visible | 任务需求与读者承诺文档：目标、读者承诺、边界、验收标准。 |
| `context.jsonl` | L2, context assembler | Explicit context entries with `kind/path/reason`; no broad raw scanning by default. |
| `verify.jsonl` | L2/L3 | Task-local verification plan before completion. |
| `journal.jsonl` | L2 | Task-local event log: `created`, `resolved_action`, `applied_result`, `superseded`, `completed`. |
| `result-packets/` | L3 | Durable result packets for stages, batches, and gates. |
| `artifacts/` | L3 | Intermediate reports, candidate drafts, handoff packets, and temporary assets. |

RPD is not a product PRD. For fiction workflows it must protect reader promise: believable motivation, emotional payoff, hook carryover, continuity, style boundary, and quality gates.

When focus changes, the previous task directory remains. Its `task.json.lifecycle.status=paused` and `journal.jsonl` records `focus_paused`; the new workflow becomes `current-task.json`, while the old RPD/checkpoint/result packets remain resumable. `superseded` is reserved for explicit abandonment or permanent replacement.

## workflow packet

L2 sends a workflow packet before calling an L3 module. Required fields:

```text
workflow_id
workflow_type
book_root
owner_module
user_goal
scope
completion_policy
current_stage
current_step
read_set
write_set
risk_level
requires_user_confirm
completion_condition
verification
next_candidates
memory_paths
runtime_guard
agent_write_policy
intent_schema
quality_debt_policy
story_asset_context
style_binding
unit_lifecycle
task_dir
rpd_path
context_paths
```

Module-specific fields may be added, such as `short_format_path`, `chapter_range`, `review_dimensions`, `source_slices`, or `expansion_transaction`.

### unit_lifecycle

`unit_lifecycle` is the reusable production-unit lifecycle. It is a shared method, not a shared prose recipe. Workflow lifecycle answers "is this task active/completed/paused", while unit lifecycle answers "where is the current chapter/section/range/fix item inside its own production loop". Each L3 module owns its concrete gates, artifacts and craft rules.

Required fields:

```text
unit_type: chapter | section | range_or_fix_item | workflow_batch
current_scope
current_stage
current_role
stage_roles
required_sequence
completed_roles
last_quality_gate
last_trusted_artifact
closure_rule
failure_policy
```

Canonical roles:

| Role | Meaning | Long form example | Short form example | Review/repair example |
|---|---|---|---|---|
| `source_or_material` | Input/source material is locked | 对标/设定/Context Pack | 素材卡 | 范围锁定/证据扫描 |
| `brief_or_contract` | The writable unit has a scoped brief/contract | Chapter Contract | 小节 Brief / 小节大纲 | 修复方案 / 执行范围 |
| `draft_or_execute` | The unit is written or repaired | 正文写作 | 小节正文 | 执行修复 |
| `machine_quality_gate` | Deterministic blockers are checked at the current unit boundary | 单章机器门：路径、字数、标点、AI 句式、工程词、退化/复读 | 单节机器门：AI 句式、工程词、标点、退化/复读、格式 | 修复结果机器复扫 |
| `quality_gate` | The unit is verified before merge/continuation | Plot Drift Gate / Prose Gate | 小节质量门 | recheck / 补审 |
| `state_integration` | State, hooks, facts and ledgers are updated | State Delta / schema | 素材/设定/正文索引 | review-state / 修复台账 |
| `handoff_and_next` | The unit produces handoff and next recommendation | Chapter Handoff Pack | 下一节建议 / 全文收束 | closure |

Rules:

- A production unit is not complete just because prose or a report exists. It must pass its quality gate and produce handoff/next recommendation.
- Deterministic blockers must be caught before interpretive quality review. AI comparison frames, engineering-word leakage, punctuation density, model loops, missing files, bad paths, and word-count failures belong to `machine_quality_gate`; while those are blocking, repair the current unit and rerun the machine gate. Plot, character, hook, continuity, and reader-value judgments belong to `quality_gate`.
- Word-count checks are diagnostic gates with tolerance, not exact-count rewrite triggers. For short sections or chapters, small shortfalls/overages should return warning quality debt such as `under_target_within_tolerance` or `over_target_review_pacing`, not blocking, when the unit's story function is complete. Only clear underfloor output, platform minimum failure, or missing story function should block. Do not pad or compress useful prose merely to hit an exact number.
- Result packets must drive branch transitions, not just the linear stage list. When a `machine_quality_gate` result has `step_status=blocked|failed`, `machine_gate_result=blocking`, or non-empty `blocking_findings`, the workflow state machine routes only to the current unit repair loop and must not mark the machine gate complete. When the same gate returns `step_status=completed` with pass-like results and no blocking findings, the repair loop is skipped and the workflow advances to the interpretive `quality_gate` stage.
- A `machine_quality_gate` result packet may not be ambiguous. It must carry at least one explicit verdict field: `machine_gate_result`, `verification_result`, `output_health_result`, `gate_result`, or non-empty `blocking_findings`. A plain `step_status=completed` without evidence is blocked as `blocked_machine_gate_result_ambiguous`.
- Story value is a hard quality dimension, not a polishing preference. A clean draft can still fail if it lacks believable motivation, visible stakes, protagonist agency, escalation, reader payoff, emotional debt, hook carryover, or platform-relevant爽点/爆点. Such failures return to `brief_or_contract` or current-unit rewrite; they are not fixed by deslop alone.
- After `quality_gate`, L2/L3 must apply the review escalation policy. The result packet should include `review_escalation_result`, `escalation_level`, `review_roles`, `cost_class`, `reason_codes`, and `next_action`. Normal passed units use `none`; periodic checkpoints use `light_dual_role`; key units, user quality complaints, cross-volume/expansion/release, or failed story-value gates use `full_multi_role`. Machine-gate blockers always return `next_action=repair_current_unit` before any reviewer dispatch.
- The method is global, but the gates are module-specific. Do not force short-form section rules onto long-form chapters, and do not force long-form Chapter Contract / State Delta / Handoff Pack onto short stories.
- If a host model stalls, outputs nothing, drifts scope, or produces polluted text, block the current unit and preserve `last_trusted_artifact`; do not continue spending tokens on the same prompt shape.
- If the user switches intent, archive the workflow lifecycle with `switch-intent`; do not reuse stale unit lifecycle to interpret new bare numbers.
- L3 modules may complete a unit role, but L2 `story-workflow` decides whether the whole workflow advances or closes.

### shortform visible workflow packets

Short-form writing has a user-visible lifecycle. The exact owner may be public `story-short-write` or private `private-short-extension`, but result packets must preserve the same boundaries:

- `section_machine_gate`: must return `machine_gate_result=pass|blocking` or non-empty `blocking_findings[]`. Blocking results route only to current-section repair.
- `quality_gate` / `story_value_gate`: must return `story_value_result=pass|revise|blocked`, with evidence for protagonist agency, causal channel, hook carryover, emotional debt, and section payoff. Clean prose with weak story value is not a pass.
- `section_candidate_compare`: is conditional, not a default stage. It runs only for two or more valid candidates or an explicit user request, and must return candidate verdicts, rejected reasons, and either a selected candidate ID or a pending user-choice action.
- `feedback_impact_sync`: is read-only. It classifies feedback as `expression_only | current_brief | planning | structure`, records affected assets and the required update order, and stops before creative writes.
- `feedback_apply_patch`: applies the confirmed plan. `expression_only` returns to current-section repair; `current_brief` rebuilds the active Brief; `planning` updates material/setting/outline first and invalidates affected Briefs; `structure` returns to `section_plan_lock` and must continue through `short_structure_impact_audit`. Planning/structure changes use one staged multi-asset transaction derived from `accepted_plan`; the stage is not executable without a non-empty write set and deterministic `execution_command`. It may not route planning or structural feedback directly to prose repair.
- Planning and structural feedback must create one durable revision queue under the current workflow. The queue records `revision_groups[]` (goal, section range, completion rule), ordered section items, and bounded checkpoints (Brief state, prose state, accepted commit, completion time, next cursor). A group is a visible author plan, not a second global task: the author sees what each range will accomplish, advances one section at a time, and may accept, rework, chat-adjust, or pause at every section boundary. Accepting a section advances the queue cursor; feedback received on a later section preserves accepted checkpoints and untouched future items, then rebuilds only the affected current item or queue suffix after upstream planning is reconciled.
- Public and private short-form workflows share the same feedback semantics. Stage names may map from public `section_brief` to private `first_section_brief/next_section_brief`, but the extension may not weaken upstream-first writes, Brief invalidation, downstream revalidation, manual-text preservation, or re-acceptance of an already accepted section.
- `changed_assets` describes assets actually updated by the confirmed patch. The next stage is the earliest stale downstream authority: `素材卡.md -> short_setting`, `设定.md -> section_outline`, `小节大纲.md -> section_plan_lock`, then the current Brief. A prose edit may not declare planning assets while remaining `expression_only`.
- `section_plan_lock`: must return total section count, target word-count band, publishing shape, section function map, user-confirmed section-title lock (including an explicit untitled choice), current section index, remaining section list, and whole-story completion branch. Briefs may only reuse locked titles and may never invent or rename one. Expansion, contraction, insertion, merge, deletion, or section reorder invalidates affected title locks and returns here before any further drafting.
- `short_structure_impact_audit`: must return impact results for material cards, setting, rhythm pattern, section outline, generated Brief files, accepted anchors, candidate drafts, prose index, and publish/merged draft. Each affected artifact is classified as `keep | invalidated | recompute | recheck`. The next stage is blocked while any `invalidated` item has no patch or any `recompute` item has no owner/stage.
- `section_accept_anchor`: must return `changed_files`, `handoff_summary`, `memory_updates`, `current_section_index`, `total_sections`, `remaining_sections`, and `next_recommendation`. It records canonical section text, section summary, character state, hook carryover, quality result, and whether the next legal branch is `next_section_brief` or `full_story_assembly`.
- `full_story_assembly`: must return missing-section check, section-order check, hook carryover check, character naming consistency, merged `正文.md` readiness, and export-readiness evidence before short-form de-AI or final check runs.

Every visible stage must preserve a free feedback lane. `pending_action.free_text_enabled=true` means the user may chat, paste manual edits, submit a revised section, or ask for replanning. L2 routes that input to current-stage repair, upstream setting/outline/Brief revision, candidate comparison, or `switch-intent`; it must not treat free text as invalid just because it does not match a numbered option.

When a revision queue is active, every author-facing stop shows: total groups, completed/remaining sections, the current section and its title, later section titles, and the current group's completion rule. The standard four exits are: continue the current unit, modify the current unit and then continue the queue, inspect the queue and evidence, or pause. A feedback impact check is internal bookkeeping, not another author task: the current section remains selected until it is re-accepted. Internal machine and story gates remain automatic unless they require an author decision.

The public `short_write` workflow is the capability baseline. A private short-form extension may add material intelligence, personal learning, lineage, or stricter gates, but it must cover every public stage directly or through an explicit stage-equivalence map. Bundle construction fails when a new public capability is not covered, preventing private evolution from silently dropping public behavior.

### intent_schema

Router output enters L2 as `intent_schema`. It records `intent_type`, `target_scope`, `user_goal`, `route_confidence`, `evidence`, `fallback_question`, `selected_workflow_type`, and `selected_owner_module`. Keyword matches are evidence only; they are not the route decision by themselves.

### story_asset_context

Long-form and continuity-sensitive workflows must distinguish:

```text
confirmed_facts
pending_cast_candidates
chapter_participants_context
fact_proposals
```

`confirmed_facts` may be used as canon. `pending_cast_candidates` and `fact_proposals` are not canon until confirmed by user or a workflow-approved low-risk memory step. `chapter_participants_context` limits context assembly to active characters and relevant hooks instead of loading the whole cast.

### style_binding

Writing, revision, and de-AI workflows may bind style assets:

```text
style_feature_pool
style_binding
style_compile_report
author_voice_profile
```

These assets preserve approved author voice and genre technique. They are not a generic humanizer and must not override fact preservation, hook preservation, or user-approved strong emotion.

### agent_write_policy

Multi-agent work must be planned before dispatch. The default policy is:

```text
agent_write_policy
  mode: isolated_artifacts
  production_write_owner: story-workflow | designated_merge_step
  per_agent_write_set: unique temp/report/handoff paths only
  merge_strategy: single_writer_merge
  conflict_status: blocked_parallel_write_conflict
```

`single_writer_merge` means agents may read overlapping source files, but they may not concurrently edit the same production正文、大纲、细纲、设定、报告、状态账本 or schema file. Agents write independent handoff packets or intermediate reports. The main workflow, or a designated merge step, verifies evidence and performs the final production write.

## result packet

L3 returns a result packet after each step or batch. Required fields:

```text
workflow_id
stage_id
step_id
owner_module
step_status
outputs
changed_files
created_files
evidence
verification_result
blocking_reason
next_recommendation
handoff_summary
memory_updates
checkpoint_state
heartbeat_update
budget_usage
output_health_result
handoff_packet_path
resume_hint
merge_inputs
quality_debt
fact_proposals
style_asset_updates
```

`changed_files` and `created_files` may list only files that exist on disk after verification.

### accepted chapter commit

Long-form chapter production uses an accepted chapter commit as the completion proof. L3 first writes `staged_artifacts`, runs deterministic and interpretive gates against those candidates, then calls `chapter-commit.js prepare` and `chapter-commit.js accept`. The result packet carries:

```text
chapter_commit
  mode: transactional | legacy_nontransactional
  transaction_id
  accepted_commit_id
  commit_file
  staged_artifacts
  projection_status
  projection_debt
```

`changed_files` alone cannot prove a chapter is complete. `mode=transactional` requires an existing immutable commit record and `projection_status=projection_current|projection_not_required`. `accepted_with_projection_debt` keeps canonical assets accepted but blocks the next chapter until replay closes `projection_debt`. A rollback or precondition conflict returns to the current unit; it must never advance `state_integration`. Legacy projects may use `legacy_nontransactional`, but L2 must display the risk and may not label it an accepted chapter commit.

For multi-agent stages, `merge_inputs` must list each agent handoff path and evidence scope. If two agents claim the same production target in `changed_files`, the result packet is invalid and the stage must return `blocking_reason=blocked_parallel_write_conflict`.

### quality_debt

L3 may return local quality debt without failing the whole workflow:

```text
quality_debt
  status: none | continue_with_warning | repair_later | local_patch_plan | stop_for_replan
  debt_items
  ledger_path: 追踪/workflow/chapter_quality_debt.jsonl
```

`continue_with_warning` and `repair_later` allow the stage to continue after the debt is recorded. `stop_for_replan` is reserved for book-level promise, canon, structure, model-health, write-safety, or unrecoverable generation failures. Local AI flavor, minor rhythm issues, or patchable obligation gaps should not automatically stop a full-book chain.

### fact_proposals and style_asset_updates

`fact_proposals` are candidate facts from writing, review, deconstruction, or repair. They must be merged into `confirmed_facts` only by an approved memory step. `style_asset_updates` may update `style_feature_pool`, `style_binding`, or `style_compile_report`; high-risk voice changes remain pending until user confirmation.

## completion_policy

Supported policies:

- `full_auto`: complete low-risk bounded tasks unless blocked.
- `stage_then_confirm`: finish a stage, report evidence, then ask for the next stage.
- `step_then_confirm`: stop after high-risk steps or writes.
- `plan_only`: produce plan and risk analysis without modifying book content.

The policy controls stopping points. It does not override user confirmation for destructive, migration, overwrite, or broad revision actions.

## pending_action

`pending_action` stores the latest selectable user action. Required fields:

```text
type
workflow_id
book_root
created_at
expires_at
visible_choice_hash
expected_reply_set
interaction_renderer
fallback
free_text_enabled
options
```

Short replies such as `1`, `继续`, `下一步`, `e`, or `E` can only bind to the latest non-expired `pending_action` for the same `book_root` and matching `visible_choice_hash`.

This is a global presentation contract for every workflow type. Professional modules return domain artifacts and result packets only. They must forward the state machine's `visible_response`, `next_candidates`, `pending_action`, and `interaction_contract` unchanged. A stage with `requires_user_confirm=false` may be started automatically by the global state machine; a stage that requires an author decision must render at most four numbered choices and accept free-text correction.

For `selection_contract=resume_running_stage`, presentation is forbidden until the expected result packet has been accepted or the host reaches a declared terminal reply condition. Editing a staging file is not a completion boundary. The host must read the minimal packet, update the authorized write set, run the completion command, and consume the returned presentation in the same turn. This invariant applies to every workflow type.

Each option is an execution contract, not a hint. Options that write prose or files should include:

```text
number
label
action_id
target_scope
target_files
risk_level
execution_mode: exact_selected_option
max_units
stop_after
completion_boundary
forbidden_interpretations
```

If the visible label says “只写第 6 节停下”, the option must carry `max_units=1` and `stop_after=第6节`. After the user replies `2`, the workflow must write `last_selection` and follow that exact boundary. It must not reinterpret the selection as “暂停看 4-5 节”, “连写 6-7 节”, or any other nearby candidate. If the persisted `pending_action` is missing, stale, or ambiguous, stop and redisplay the latest choices instead of guessing.

## state machine

For supported workflow types, the durable `tasks/<workflow_id>/task.json` `machine` object stores `template_version`, `completed_stages`, `remaining_stages`, `allowed_actions`, `last_transition`, `last_result_packet`, and `next_stop_reason`. `pending_action.options[].action_id` is the canonical source for numbered selection.

`workflow-state-machine.js` is the deterministic stage-transition helper. Result packets must match the active `workflow_id`, `workflow_type`, `stage_id`, and `step_id`. A mismatch sets `blocked_result_packet_invalid`; the workflow must not advance. Professional modules may complete a step or stage, but they do not declare the whole workflow complete.

`workflow-runner.js` is the deterministic host execution bridge. It may execute only a stage already recorded as running, or the unique safe candidate whose `requires_user_confirm=false`. It must stop before every unconfirmed stage, invoke the `stage_execution.owner_module`, monitor streaming output, allow no more than one compact recovery attempt, and apply only the declared `expected_result_packet`. It must not generate domain artifacts itself or select a paid adapter when `--adapter auto` is used.

`workflow-supervisor.js` is an opt-in persistent wrapper, not a second state machine. It delegates only `workflow-runner.js once`, persists `追踪/workflow/supervisor-state.json` and append-only `supervisor-events.jsonl`, and stops at confirmation, selection, quality/transaction blocks, provider errors, runtime limits, or budget limits. A paid `watch` requires both `--max-budget-usd` and `--max-total-budget-usd`; it must never alter a host's permission, login, or configuration files.

`resolve-action` must be used, or equivalently emulated by writing the same fields, before executing a numbered choice. Its output and `current-task.json.last_selection` are the canonical binding for short replies. The model must not re-infer a bare number from chat prose once `last_selection` exists.

After a numbered action is resolved and before any long read, Agent call, review pass, or prose write starts, the workflow must create a stage execution lock in the durable task. `stage_execution.status` is set to `running`, `stage_execution.expected_result_packet` points to the result packet expected for the current stage, and `runtime_guard.heartbeat.current_batch` is set to the stage id. `machine.last_execution_event=stage_started` records execution start; `machine.last_transition` keeps the last completed business transition when an internal safe stage auto-starts, so review rollback and asset acceptance remain auditable.

The stage execution lock is not a completion marker. It only records that the user already confirmed this stage. If the host later shows recap, stalls, or compresses context, the workflow reads `stage_execution` and resumes from the checkpoint. It must not revert to "waiting for confirmation" while `stage_execution.status=running` and the expected result packet is still missing.

`latest_trusted_artifact` and `expected_result_packet` are different fields. The former must exist and have passed verification; the latter may legitimately be missing while a stage is running. `workflow-state-validate.js` enforces this invariant, while `workflow-recover.js` is the executable recovery path for missing stage packets. Legacy range reviews without complete chapter-coverage evidence are migrated into first-class review batches and resumed from the first incomplete batch; sampled evidence is preserved but never promoted to a completed batch. State mutations are atomic, versioned, and guarded by a project workflow lock.

For range review, `review_batches` is a first-class child state. Every batch has `id`, `range`, `status`, `result_packet`, and `dispatch_plan`. A batch result may update the parent checkpoint, but it cannot mark `evidence_scan` complete until `aggregate_status=completed`.

Public workflow templates define safe fallback owners. Local/private internal modules may provide `workflow-registry.json` overlays to take ownership of a workflow type without changing the public template. This keeps the single `/novel-assistant`入口 stable while allowing local production stacks to route short-form creation, download/update, or other private workflows to private modules.

## first-class template contract

`long_scan`, `short_scan`, `short_analyze`, and `cover` are first-class templates alongside `download_import`, `long_analyze`, `deslop`, and `setup_update`. A first-class template must expose ordered `preflight`, `source/input lock`, `execute`, `validation`, `artifact assembly`, and `closure` stages. Every stage declares a concrete `owner_module`, `risk_level`, and `requires_user_confirm` value.

For result contract v2, `apply-result` accepts only the packet named by the current `stage_execution.expected_result_packet`. The packet file must resolve inside the project, `stage_execution.status` must be `running`, and packet stage/step IDs must match both the execution lock and current task. Pre-v2 tasks use an explicit compatibility branch; recovery-created or pre-existing v2 packets remain valid only when they occupy the declared expected path.

### long-form legacy protocol migration

Long-form legacy compatibility is layered and must not be treated as a blanket bypass:

1. Legacy chapter paths and flat layouts may remain readable. Layout migration is recommended, but ordinary continuation follows the project's declared layout until the author confirms migration.
2. A pre-v2 task or result packet must first be bound to a durable `workflow_id`, current stage, and task directory. The original packet remains immutable historical evidence.
3. If an old stage lacks the current quality evidence, write-set identity, or expected-packet binding, display a migration preview and offer numbered choices: migrate and revalidate the current stage, inspect preserved evidence, pause, or enter another requirement. It must not be reported as passed.
4. A legacy chapter written without a transactional commit may be recorded as `legacy_nontransactional` with an explicit risk. It is not equivalent to an accepted chapter commit. Before the next canonical rewrite or structural change, migrate it into the current transaction chain or revalidate the affected unit.
5. After current-stage validation succeeds, declared canonical writes receive an immutable stage receipt before canonical audit. Workflow-owned diagnostics under `tasks/<workflow_id>/work/` are evidence only and never count as creative writes.

Unsupported or corrupted packets are quarantined. The workflow preserves canonical prose and planning assets, does not delete them, and returns to the earliest stage whose evidence cannot be trusted.

Every stage with `requires_user_confirm=true` persists the resolved selection and a non-expired `stage_execution.confirmation_context`. Its `confirmation_token` is bound to workflow, stage/step, selected option, visible-choice hash, target, operation, and expiry. Missing, expired, reused, or mismatched confirmation returns `blocked_confirmation_required`. Cover generation uses separate `generate` and `overwrite` operation confirmations, and `story-cover` must stop before any image API call when invoked without this workflow context.

Each template exposes `result_contract.version=2` with required fields `outputs`, `changed_files`, `evidence`, `verification_result`, `checkpoint_state`, and `output_health_result`. It also exposes recovery metadata that preserves `latest_trusted_artifact`, resumes from the current checkpoint when a result packet is missing, and records a blocking reason instead of guessing completion.

`cover` is confirmation-gated: `generation_confirmation` must finish before `generate_cover_execute`. This applies both to a new image generation and to any overwrite of an existing cover file; versioned new outputs are still image-generation actions and require confirmation.

## lifecycle

Every active workflow has a lifecycle. `current-task.json.lifecycle` records:

```text
status
started_at
updated_at
completed_at
user_goal
scope
previous_workflow_id
switch_reason
```

Supported lifecycle statuses:

- `active`: the workflow is current.
- `stage_completed` / `awaiting_next`: a stage ended, but the workflow is not closed.
- `completed`: closure is written and recommended next actions are available.
- `paused`: user stopped or saved a checkpoint.
- `focus_paused`: user entered another explicit goal; the old workflow remains resumable.
- `superseded`: user explicitly abandoned or permanently replaced the old workflow.
- `blocked`: a gate or runtime condition prevents progress.

Manual new goals must use `workflow-state-machine.js switch-intent`. Do not reinterpret a new instruction as a choice inside the previous `pending_action` when the target chapter, range, or workflow type changes. `switch-intent` pauses the old focus in its durable task directory, appends a `focus_switched_from` event, and creates the new current task. `activate --workflow-id <id>` restores any unfinished task without deleting the current one.

Workflow completion must not leave an empty choice surface. When the last stage completes, `apply-result` sets `lifecycle.status=completed` and builds a completion `pending_action` from `result.next_recommendation`. If no recommendation exists, it falls back to safe options such as starting a new workflow or ending the session. Stage completion is not workflow completion while `remaining_stages` is non-empty.

## runtime_guard

Long tasks and global tasks must include `runtime_guard`. Required sections:

- `token_estimate`: input files, input chars, output budget, agent count, batch size, risk level.
- `token_cost_governance`: cost ledger path, cost summary path, `model_routing_policy`, tool output filter, and retry budget result. The canonical decision map lives in `token-cost-governance.md`.
- `adaptive_budget_policy`: visible reply, batch handoff, and range summary budget logic.
- `heartbeat`: last trusted artifact, updated time, current batch, completed/total.
- `checkpoint_policy`: checkpoint paths, batch boundary, resume source, reusable artifacts.
- `output_health_gate`: visible reply, report draft, agent handoff, and candidate checks.
- `max_retry_budget`: retry limits for pollution, tool failures, provider errors.
- `stall_policy`: recap, long thinking, stream stall, agent zero-token Done, no new files.

Missing or incomplete `runtime_guard` must block long task startup.

## Blocking Status Vocabulary

Common blocking statuses:

- `blocked_runtime_guard_missing`
- `blocked_runtime_guard_incomplete`
- `blocked_output_health_failed`
- `blocked_write_permission`
- `blocked_write_hook`
- `blocked_write_missing_output`
- `blocked_write_tool_call_invalid`
- `blocked_model_degradation`
- `blocked_provider_sensitive`
- `blocked_tool_command_contaminated`
- `blocked_repeated_tool_failure`
- `blocked_parallel_write_conflict`
- `blocked_verification_failed`
- `paused_after_batch`
- `paused_after_output_pollution`

Modules may add domain-specific status codes, but common statuses should use this vocabulary.

## Verification Rule

`verification_result=pass` is only valid when the module ran the declared verification and no required gate failed. If verification is partial, use `done_with_warnings` or a blocking status. Do not mark a step complete because a tool or agent said `Done`.
