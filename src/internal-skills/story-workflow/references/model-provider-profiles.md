# Model Provider Profiles

This reference turns provider/model choice into workflow data instead of tribal knowledge. It responds to upstream issues about OpenAI-compatible endpoints, other APIs, Qwen-family models, and custom endpoint usage.

## Boundary

`novel-assistant` runs inside host tools such as Claude Code / Codex / OpenCode. 宿主工具负责 provider 配置、登录态、API key、base URL、模型选择和计费；skill 不保存 API key，不要求用户把供应商密钥写进书目项目，也不接管宿主的模型登录方式。

The profile here is not a provider manager. It is a runtime capability note used by workflow:

- what kind of model the host currently gives us;
- what task class it is suitable for;
- how much context it probably supports;
- what failure and pollution risks should be watched;
- when to shrink scope, switch model_class, or fall back to deterministic scripts.

## Profile Schema

Every runtime or frontend provider profile should normalize to these fields:

```json
{
  "provider_id": "minimax",
  "display_name": "Minimax",
  "endpoint_kind": "OpenAI-compatible endpoint",
  "custom_endpoint": true,
  "models": [
    {
      "model": "qwen3.7-max",
      "model_class": "standard_reasoning",
      "context_window_hint": "large",
      "recommended_use": ["short_write", "long_write", "review_batch"],
      "risk_notes": ["verify prose pollution", "do not assume Claude tool semantics"]
    }
  ]
}
```

Required fields:

- `provider_id`: stable lowercase id, such as `claude`, `openai`, `minimax`, `qwen`, `deepseek`, or `custom`.
- `endpoint_kind`: `native_claude`, `OpenAI-compatible endpoint`, `local_proxy`, or `custom endpoint`.
- `model_class`: one of `cheap_extract`, `standard_reasoning`, `deep_reasoning`, `long_context_review`, `creative_draft`.
- `context_window_hint`: `small`, `medium`, `large`, `very_large`, or an approximate token number when known.
- `recommended_use`: workflow types that are appropriate for this model.
- `risk_notes`: provider-specific caveats for output health, tool calling, context size, safety filters, and cost.

## Default Mapping

| Provider / family | endpoint_kind | Suggested model_class | Recommended use | Notes |
| --- | --- | --- | --- | --- |
| Claude / Anthropic | `native_claude` | `deep_reasoning` or `creative_draft` | high-risk planning, longform continuity, final arbitration | Strong tool semantics, still requires output health gate. |
| OpenAI | `OpenAI-compatible endpoint` or native OpenAI runtime | `standard_reasoning` / `deep_reasoning` | review, routing, rewrite, extraction | Do not assume identical Claude Code tool behavior. |
| Qwen | `OpenAI-compatible endpoint` or provider gateway | `standard_reasoning` / `long_context_review` | long-context review, draft, extraction | Qwen-family output must pass pollution and repetition gates before reuse. |
| Minimax | `OpenAI-compatible endpoint` or provider gateway | `standard_reasoning` / `long_context_review` | Chinese prose drafting, broad review, continuation | Good for Chinese writing workflows; still enforce single-writer merge and health gate. |
| DeepSeek | `OpenAI-compatible endpoint` or provider gateway | `cheap_extract` / `standard_reasoning` | extraction, scan, low-risk batch summary | Watch provider safety errors and repeated retry waste. |
| custom endpoint | `custom endpoint` | user-configured | depends on profile | Require a profile before using for long tasks. |

## Workflow Rules

`story-workflow` should not hardcode a provider. Before long tasks, it records:

```json
{
  "model_routing_policy": {
    "model_class": "standard_reasoning",
    "provider_profile": "minimax",
    "context_window_hint": "large",
    "fallback_model_class": "cheap_extract",
    "upgrade_when": ["evidence_conflict", "global_arbitration"],
    "downgrade_when": ["deterministic_scan", "file_inventory"]
  }
}
```

Rules:

1. If a provider is unknown, classify it as `custom endpoint`, ask for or infer only the minimum profile fields, and keep long tasks conservative.
2. If a task is deterministic inventory, stats, filename migration, or schema validation, prefer scripts and `cheap_extract`; do not spend `deep_reasoning`.
3. If a task is final arbitration, whole-book consistency, or high-impact rewrite planning, use `deep_reasoning` or the user-selected high-quality model.
4. If provider safety errors such as `output new_sensitive` appear, do not retry the same prompt unchanged; route to `blocked_provider_sensitive`.
5. If output health fails twice for the same provider/model/task, write a learned risk note and suggest switching model_class or shrinking scope.

## User-Facing Guidance

When users ask “其他 API 怎么用”, “OpenAI custom llm endpoint support?”, “qwen3 code”, “Minimax 怎么配”, or similar, answer from this profile:

- Explain that Claude Code / Codex / OpenCode or the frontend runner owns endpoint setup.
- Tell them which profile fields are useful for workflow routing, not secret configuration.
- Keep setup separate from book project migration.
- After changing providers, run setup/update smoke checks before long writing tasks.
