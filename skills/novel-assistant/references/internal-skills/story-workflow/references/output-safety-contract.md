# Output Safety Contract

This file centralizes output safety and failure handling for visible replies, reports, writing, review, tool calls, and long-running tasks.

## Model Degradation

`blocked_model_degradation` applies when output enters obvious low-quality loops: repeated domain terms, repeated lines, n-gram floods, long thinking with no new trusted artifact, repeated SSOT labels, or repeated stage labels.

When detected:

1. Stop the current generation path.
2. Do not write正文, reports, outlines, or repair plans from the polluted text.
3. Preserve the 最后可信断点.
4. Retry once with a smaller scope.
5. If it repeats, return clean choices: shrink range, switch model and resume, or save diagnosis only.

## Output Pollution

Visible replies, report drafts, agent handoffs, next candidates, and repair summaries must pass pollution checks before reuse. Pollution includes:

- repeated filler;
- engineering terms inside prose;
- fake completion sentinels;
- provider artifacts;
- transcript fragments;
- 内部工作流旁白，例如“我先读取”“并行读取”“最小必要回复”“继续读 §3-§8”；这些只能存在于执行过程，不得作为最终用户回复；
- 编码/乱码块，例如长串 base64-like 文本、替换字符 `�`、模型/工具把内部二进制或日志编码片段吐到可见回复；
- 用户可见工程缩写，例如 `SSOT`。内部可以用 `ssot` 作为字段或维护术语；对用户必须改写为“权威设定”“设定基准”“唯一设定源”，具体到成长线时用“境界设定”“成长进度设定”；
- low information density;
- copied contaminated source phrases.

Polluted source text is evidence of failure, not a fact source. Refer to it as `污染段#N` with path/line evidence instead of repeating the phrase.

`user-facing-jargon-leak` is a rewrite-only signal by default. It means the visible reply should be localized and rescanned, not that the workflow should pause. Escalate to a blocked recovery template only when the rewrite fails again or when hard pollution appears in the same draft, such as repeated loops, encoded gibberish, provider artifacts, fake completion sentinels, or low-information output.

## Visible Reply Gate

Long visible replies, option payloads, review summaries, and repair summaries should be written to a temporary draft and checked with `output-pollution-check.js` when they exceed safe size or come from risky sources.

If the draft fails, do not display it. Replace it with short clean intent choices and a path to the full trusted artifact if one exists.

Visible replies should be conclusions, stage state, and next choices. They must not be a transcript of file reads, parallel probes, or tool progress. If `output-pollution-check.js` reports `internal-workflow-narration` or `encoded-gibberish-blob`, discard the visible draft, keep only the last trusted artifact path, and rewrite a clean user-facing reply.

## Tool Call Contamination

`blocked_tool_command_contaminated` applies before Bash, Agent, Write, Edit, or MultiEdit when payload contains:

- diff hunks;
- previous tool output;
- `Thought for`, `Added`, `removed`, `⎿`, `@@`, `---/+++`;
- Markdown tables in shell commands;
- heredoc or long inline scripts that should be decomposed;
- copied Claude transcript markers.

Blocking is not refusal. The recovery path is to reconstruct from user intent, current files, workflow state, and deterministic scripts.

## Multi-Agent Write Boundary

多 agent 并行是读取、分析、提证据和生成中间产物的加速手段，不是让多个 agent 抢同一份生产文件的写权限。不得让多个 agent 同时 Write/Edit 同一个正文、大纲、细纲、设定、报告文件、状态账本或 schema 文件。

执行规则：

1. agent 只能写独立中间产物，例如 `追踪/workflow/agent-handoff/{workflow_id}/{agent_name}.md`、独立审查报告草稿、独立证据 JSON 或只读摘要。
2. 并行 agent 的 `write_set` 必须互不重叠；重叠时在 dispatch 前返回 `blocked_parallel_write_conflict`，不要等写入失败。
3. 主流程或 merge step 才能把多个 agent 的结论合并到生产文件；合并前必须验证证据、冲突、输出健康和目标文件存在性。
4. 如果已有 agent 误写了生产文件，下一步不是继续并行，而是冻结该文件，生成差异报告，交给 `single_writer_merge` 或用户确认保留/回退。

这条规则对应上游多 agent 并行提交报错类问题：解决方式不是禁用 agent，而是把并行写入变成独立产物 + 单写入者合并。

## Write Failure Triage

`blocked_write_failure` is the umbrella for Write/Edit failure handling. Specific categories include:

- `blocked_write_permission`
- `blocked_write_hook`
- `blocked_write_missing_output`
- `blocked_write_tool_call_invalid`

On Write/Edit failure, run deterministic triage before retrying the same write. Do not say a report or chapter is complete until the target file exists, is non-empty, and contains expected anchors.

## Provider Sensitive Output

`blocked_provider_sensitive` applies to API errors such as `output new_sensitive` or `new_sensitive (1027)`.

Do not retry the same prompt unchanged. Preserve the checkpoint, reduce explicitness, keep plot causality, and retry at most once with a smaller scope. If still blocked, ask the user to choose between lowering depiction intensity, skipping the sensitive segment while keeping causality, or saving diagnosis only.

## Pollution Learning

When the user identifies a recurring bad phrase or the checker detects a repeated pollution pattern, write it to the project learning files where available, such as:

- `追踪/schema/output-pollution-rules.jsonl`
- `追踪/schema/user-style-rules.jsonl`
- `设定/作者风格/禁用表达.md`

Future long outputs must preload these learned rules before generation.

## Recovery Replies

Blocked recovery replies must be short and deterministic. They should include:

- status;
- 最后可信断点;
- what was not written;
- safe next choices.

Do not repeat polluted text, long reports, raw tool transcripts, or domain-term loops in the recovery reply.
