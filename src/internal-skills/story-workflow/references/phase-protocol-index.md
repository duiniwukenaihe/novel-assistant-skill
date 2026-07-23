# 阶段化契约索引

此索引仅在当前 workflow 已确定阶段后读取。它用于旧项目兼容与精确检索，不是首屏上下文的一部分；命中任何锚点后，必须继续读取对应协议正文。

| 阶段 | 常用锚点与权威协议 |
|---|---|
| 收件箱、恢复、菜单、数字选择 | `task-inbox-protocol.md`：`task-index.json`、`workflow_groups`、`next_candidates`、`selection_execution_draft`、`safe_default`、`free_text_enabled`、`switch-intent`、`new_project_ready`、`show_new_project_onboarding`、任务目录持久化、RPD、候选范围从当前项目推断、不得用旧书记忆、不得把 recap 当事实源。可见回复不得输出 `pending_action` 原始 JSON/YAML；不得复述业务术语超过 2 次；默认不自动继续写作。 |
| runner、Agent、工具、成本、退化恢复 | `runner-execution-protocol.md`：`workflow-runner.js`、`runtime_guard`、`token_estimate`、`adaptive_budget_policy`、`heartbeat`、`checkpoint_policy`、`output_health_gate`、`max_retry_budget`、`stall_policy`、`runtime-guard-validate.js`、`workflow-runtime-supervisor.js`、`tool-call-degradation-check.js --strict`、同一污染类型只允许一次自愈重试、重建最小 payload 后再跑。 |
| 正式资产、扩容、章节提交 | `canonical-write-protocol.md`：扩容事务、后移映射、`chapter_commit`、`accepted_commit_id`、`outline_to_draft_gate`、`review_gap_reconciliation`。能力类资产按当前题材命名；只有修真/仙侠证据充分时才使用“修真进度”名称。 |
| 结果回执、恢复、收束 | `completion-evidence-protocol.md`：`workflow packet`、`result packet`、`checkpoint_state`、`verification_result`、`handoff_summary`、`memory_updates`、`budget_usage`、`output_health_result`。模块不得自行宣布整个 workflow 完成。 |
| 可见输出与污染隔离 | `output-safety-contract.md`：`option_payload_draft`、`visible_reply_draft`、`internal-workflow-narration`、`encoded-gibberish-blob`、`blocked_model_degradation`、`blocked_provider_sensitive`、`output-pollution-rules.jsonl`。命中污染时保留最后可信断点，不写正文或报告，不原样重试。 |
| 质量、审阅、记忆 | `quality-debt-policy.md`、`review-escalation-policy.md`、`story-assets-ledger.md`、`story-memory-context.md`：`continue_with_warning`、`stop_for_replan`、角色资产账本、自动分派、`context-assembler.js`、`memory-recommender.js`。 |

## 使用规则

1. 只加载当前阶段实际需要的一行与其权威协议；跨阶段前重新判断，不沿用上一阶段的整段上下文。
2. 短篇根资产写入也属于正式资产事务，但短篇不套用长篇 Chapter Contract。
3. 领域词、示例章节号、历史任务标题都不是默认事实；只能从当前项目、packet 或已接受回执读取。
