# Scripts Map

This document classifies top-level scripts so maintainers can understand what is runtime-critical, what is validation, and what can later be consolidated.

Skill source modules live in `src/internal-skills/`. Top-level script names remain stable because installed bundles, tests, and deployed hooks reference exact script names.

Use `node scripts/na-dev.js <command>` as the maintainer facade for common workflows. The facade reduces day-to-day command clutter without changing runtime script paths or installed skill behavior.

## Categories

| Category | Purpose |
|---|---|
| `runtime` | Called by installed skill, deployed project hooks, or user-facing workflows |
| `validation` | Repository or project validation gate |
| `workflow` | Creates or validates workflow/checkpoint/runtime artifacts |
| `longform` | Long-form chapter, continuity, expansion, revision, and publish tooling |
| `analyze-scan` | Market scan, deconstruction, source grounding, and summary quality |
| `setup-update` | Install, self-update, setup, and collaboration environment deployment |
| `maintainer` | Build, upstream comparison, release support, and source synchronization |
| `test-support` | Test runner, fixture support, or portability checks |

## runtime

| Script | Notes |
|---|---|
| `output-pollution-check.js` | Visible output and report pollution gate |
| `check-degeneration.js` | Prose/model degradation gate |
| `check-ai-patterns.js` | AI-pattern and punctuation-pattern detector |
| `story-progress-status.js` | Deterministic current progress answer |
| `story-domain-profile.js` | Genre/domain term detection |
| `story-prose-gate.js` | Prose quality gate used by writing/hook flows |
| `chapter-text-stats.js` | Robust text statistics |
| `blocked-recovery-template.js` | Deterministic blocked-state reply |
| `write-failure-triage.js` | Write/Edit failure classification |

## validation

| Script | Notes |
|---|---|
| `static-check.sh` | Skill reference/static integrity check |
| `check-shared-files.sh` | Shared file byte consistency |
| `check-python-invocation.sh` | Cross-platform Python invocation guard |
| `check-hook-regex-sync.sh` | Hook regex sync check |
| `check-hook-locale-safety.sh` | Hook locale safety |
| `check-story-setup-deployment.sh` | Setup deployment completeness |
| `check-longform-stability-fixture.sh` | Longform fixture validator wrapper |
| `git diff --check` | Not a script, but part of release validation |

## workflow

| Script | Notes |
|---|---|
| `runtime-guard-validate.js` | Validates `current-task`, workflow packet, and result packet |
| `workflow-runtime-supervisor.js` | Reads heartbeat/checkpoint and returns continue/pause/resume decisions |
| `workflow-task-inbox.js` | Builds metadata-only grouped startup task inbox and post-completion recommendations |
| `tool-call-degradation-check.js` | Detects contaminated tool payloads |
| `tool-task-decompose-plan.js` | Converts risky shell snippets into safe task plans |
| `review-state-ledger.js` | Maintains review state, gaps, stale ranges |
| `context-pack-build.js` | Builds compact context packs |
| `current-contract-build.js` | Builds current chapter contract artifact |

## longform

| Script | Notes |
|---|---|
| `chapter-assets-build.js` | Builds chapter asset index |
| `chapter-draft-resolve.js` | Resolves actual draft paths |
| `chapter-handoff-pack.sh` | Writes chapter handoff packs |
| `chapter-commit.js` | Atomically accepts staged chapter prose and tracking projections, with rollback and replay |
| `chapter-index-build.sh` | Builds `追踪/章节索引.tsv` |
| `chapter-stability-check.sh` | Validates chapter against contract and invariants |
| `cross-chapter-continuity-audit.sh` | Checks adjacent continuity |
| `cross-volume-continuity-audit.sh` | Checks cross-volume bridge inheritance |
| `cross-volume-handoff-pack.sh` | Writes volume-to-volume handoff |
| `longform-daily-stability-audit.sh` | Batch daily audit |
| `revision-impact-scan.sh` | Finds impacted artifacts for revision |
| `revision-stability-recheck.sh` | Rechecks after revision |
| `stability-agent-dispatch-prompt.sh` | Produces repair owner prompt |
| `stability-repair-dispatch.sh` | Maps failures to repair actions |
| `stability-repair-loop.sh` | Maintains current repair checkpoint |
| `story-expansion-plan.js` | Plans and applies chapter expansion shifts |
| `story-project-migrate.js` | Migrates project layout |
| `story-version-snapshot.js` | Captures writing artifact versions |
| `publish-export.js` | Exports publish-ready global numbering |

## analyze-scan

| Script | Notes |
|---|---|
| `long-analyze-plan.js` | Creates resumable analyze batch plan |
| `long-analyze-recovery-state.js` | Reads analyze recovery state |
| `scan-artifact-build.js` | Converts scan markdown into structured artifacts |
| `scan-json-validate.js` | Validates scan artifacts |
| `stage2-grounding-check.js` | Checks stage2 summaries against source slices |
| `stage2-summary-quality-check.js` | Checks summary quality without fragile shell loops |
| `story-schema-build.js` | Builds story schema artifacts |
| `story-schema-validate.js` | Validates story schema artifacts |
| `oh-story-doctor.js` | Project health doctor for story schema/prod loop |

## setup-update

| Script | Notes |
|---|---|
| `novel-assistant-update-check.js` | Checks deployed collaboration environment bundle |
| `novel-assistant-self-update.js` | Checks/applies installed skill updates |
| `novel-assistant-project-smoke.js` | Read-only project smoke check |
| `sync-opencode.py` | Syncs OpenCode assets |

## maintainer

| Script | Notes |
|---|---|
| `build-oh-story-bundle.sh` | Builds `skills/novel-assistant` from `src/internal-skills` source modules |
| `check-upstream.sh` | Fetches upstream deltas and maps upstream `story-*` files to `src/internal-skills/...` plus generated `skills/novel-assistant/references/internal-skills/...` targets |
| `check-skill-directory-policy.js` | Validates that top-level `skills/` contains only `novel-assistant` and that `src/internal-skills` source modules are present |
| `maintainability-audit.js` | Checks maintainability kernel wiring |
| `na-dev.js` | Maintainer facade for verify/smoke/audit/static/bundle/upstream/reference-watch/test |
| `production-smoke-matrix.js` | Router/workflow/module/bundle smoke matrix |
| `reference-project-watch.js` | GitHub-first low-frequency research watch for non-upstream repo projects plus manual knowledge/data sources; distribution mirrors are opt-in; writes `reports/research/` only |
| `normalize-punctuation.js` | Shared normalization script; runtime-used but also maintained as shared asset |

## test-support

| Script | Notes |
|---|---|
| `run-bats-lite.sh` | Bats-lite fallback runner |
| `run-bats-tests.sh` | Full test entry with bats fallback |
| `test-charcount-portable.sh` | Cross-platform charcount fixture |
| `test-hook-encoding-portable.sh` | Hook encoding portability fixture |

## Consolidation candidates

These are future candidates only. Moving them requires compatibility wrappers, reference updates, bundle updates, and tests.

| Candidate | Possible future location | Risk |
|---|---|---|
| validation scripts | `scripts/validation/` | Many release docs and tests reference current paths |
| longform scripts | `scripts/longform/` | Installed bundles and deployed project workflows may call exact paths |
| analyze/scan scripts | `scripts/analyze/` and `scripts/scan/` | Analyze skill and frontends may reference current paths |
| update/setup scripts | `scripts/setup/` | Installed `novel-assistant` bundle expects current copies |
| maintainer-only scripts | `scripts/maintainer/` | Lower risk, but release docs and CI still need wrappers |

Recommended later migration strategy:

1. Add subdirectory copies or wrappers while keeping old paths.
2. Update docs and tests to allow both old and new paths.
3. Update skills and bundler.
4. Rebuild `skills/novel-assistant`.
5. Remove old wrappers only after one release cycle.
