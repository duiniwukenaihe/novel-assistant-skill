# Behavior Evaluation

`scripts/behavior-eval.js` defines the behavior-evaluation contract for Claude, Codex, and ZCode. It has two explicit modes:

- `plan`: free deterministic dry-run. It never starts a host and never spends quota.
- `run`: paid host execution. It only runs when `--execute-paid`, exact `--paid-confirmation <run-id>`, and `--max-budget-usd` are all present.

## Dry Run

Create a JSON plan:

```bash
node scripts/behavior-eval.js plan --scenario route-single-entry --hosts claude,codex,zcode --json
```

Or use the maintainer facade:

```bash
node scripts/na-dev.js behavior-eval-plan --scenario route-single-entry --hosts claude,codex,zcode
```

Each plan contains:

- `scenario`: scenario id, fixture, and assertions.
- `hosts`: the requested `claude`, `codex`, and/or `zcode` targets.
- `budget`: dry-run budget metadata with `paidExecution: false`.
- `output`: the planned/calculated `reports/behavior-eval/<run-id>/` directory and expected summary path. Task 4 will create it atomically and prevent run-id collisions.
- `commands`: planned host commands marked `planned_only`.

Supported scenarios are:

| Scenario | Fixture | Assertions |
|---|---|---|
| `route-single-entry` | `empty-project` | `route`, `visible_response` |
| `write-only-section-6` | `short-eight-sections` | `target_scope`, `asset_diff` |
| `review-1-200` | `review-range` | `batch_coverage`, `resume` |
| `deconstruction-health-stop` | `fake-degeneration` | `early_stop`, `checkpoint` |
| `review-repair-staged-gate` | `review-repair-gate` | `staged_candidate`, `canonical_unchanged`, `transaction_required` |
| `chapter-commit-conflict` | `chapter-commit-conflict` | `concurrent_change`, `accept_blocked`, `canonical_unchanged` |

The two transactional scenarios have deliberately narrow acceptance meanings:

- `review-repair-staged-gate` must show that a multi-select repair candidate remains staged until a chapter transaction is accepted and its projections complete. A model must not rewrite canonical prose merely because it produced a candidate.
- `chapter-commit-conflict` must show that a canonical target changed after prepare prevents acceptance; the transaction must not overwrite the concurrent content.

Every declared assertion needs a structured result-packet entry with at least one hashed, isolated-project evidence asset. A dry plan only shows the required contract and never materializes a fixture or launches a host.

## Paid Execution Guard

`run` requires `--execute-paid`. Without it, the command exits with status `1` and returns `blocked_paid_confirmation_required`.

```bash
node scripts/behavior-eval.js run --scenario route-single-entry --hosts claude --json
```

Confirmed paid execution:

```bash
RUN_ID=paid-route-single-entry-001
node scripts/behavior-eval.js run \
  --execute-paid \
  --paid-confirmation "$RUN_ID" \
  --max-budget-usd 10 \
  --scenario route-single-entry \
  --hosts claude,codex,zcode \
  --run-id "$RUN_ID" \
  --json
```

The evaluator writes `reports/behavior-eval/<run-id>/summary.json`. Each passing summary records:

- current `bundleId` and `sourceCommit`;
- requested hosts and scenario;
- host-reported token/cost usage;
- assertion evidence hashes from the isolated fixture project.

Release gate:

```bash
node scripts/behavior-eval-release-gate.js --json
```

The gate only reads existing reports. It never starts a host. It blocks release if a required scenario is missing, a report is dry-run/non-paid, the bundle ID is stale, any host failed, or token/cost usage is not host-reported.

Run IDs must be 1-64 characters containing only letters, numbers, `.`, `_`, and `-`. The evaluator resolves the calculated directory and verifies it remains inside `reports/behavior-eval`; values such as `../../../outside` are rejected.

## Prose Quality Calibration

The public fixture set is a schema and regression corpus, not a substitute for an author's approved prose. The benchmark reports aggregate metrics plus separate `blocking` and `advisory` metrics so a soft style hint cannot be mistaken for a hard false positive.

Persist author adjudication in `novel-project` PostgreSQL. The Skill is a stateless evaluator: stream a versioned JSONL snapshot through stdin and save the returned metrics back to PostgreSQL.

```bash
# novel-project writes its PostgreSQL JSONL snapshot to this process's stdin.
node scripts/prose-quality-benchmark.js --corpus-stdin --json
```

Each record uses `id`, `corpusVersion`, `category`, `expectedDetection`, optional `expectedSeverity` (`none | advisory | blocking`), `text`, and self-declared `provenance`. Keep at least one accepted and one rejected record. `expectedSeverity` must agree with `expectedDetection`. The result includes severity agreement, under-escalation, and over-escalation counts without echoing source excerpts.

The Skill must not persist author excerpts, decisions, or calibration history. A temporary `--corpus <file>` remains available for compatibility and tests, but production integrations should prefer `--corpus-stdin`. Private corpus data must never be copied to public fixtures, logs, GitHub reports, or release artifacts.
