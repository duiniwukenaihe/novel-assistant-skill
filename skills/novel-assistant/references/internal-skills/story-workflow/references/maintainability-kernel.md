# Maintainability Kernel

This file is the skill-layer maintenance contract for `novel-assistant`. It is not a user workflow. It tells maintainers and agents where shared production rules live so future fixes do not drift across router, workflow, modules, bundle copies, scripts, and tests.

## single_entry

`/novel-assistant` is the normal user-facing entry. `story` is the internal router. `story-workflow` is the internal L2 workflow brain. `story-*` modules are internal L3 professional modules unless explicitly documented otherwise. User-facing docs should not ask ordinary users to call internal `/story-long-write`, `/story-review`, or `/story-long-analyze` commands.

## l2_l3_boundary

L2 orchestration belongs to `story-workflow`: task memory, stages, `completion_policy`, `pending_action`, workflow packet, result packet, runtime boundaries, checkpointing, and next candidates.

L3 professional judgment belongs to the target module:

- `story-long-write`: long-form writing, outline-to-prose, revision, expansion, chapter stability.
- `story-short-write`: short story framing, short-specific prose, short deslop.
- `story-long-analyze` / `story-short-analyze`: deconstruction and source-grounded learning.
- `story-review`: review rubric, findings, range gaps, repair suggestions.
- `story-deslop`: prose-only cleanup and fact-preserving rewrite.
- `story-setup`: collaboration environment deployment and migration gates.

An L3 module may complete its own step, but it must not declare the whole workflow complete.

## script_first

Repeatable checks should be deterministic scripts before prompt prose. If a rule can be verified by a script, prefer a script plus a short instruction. Long inline shell snippets, heredocs, `node -e`, `python3 -c`, and copied tool transcripts are maintenance hazards unless guarded by existing decomposition scripts.

## bundle_sync

Source skills and generated bundles must stay aligned:

- Source modules live under `skills/story-*` and `skills/story-workflow`.
- The default installable bundle is `skills/novel-assistant`.
- `skills/oh-story` is compatibility output.
- After changing source skills, run `bash scripts/build-oh-story-bundle.sh`.
- Then run bundle and shared-file checks before claiming the package is current.

## upstream_absorption_gate

Upstream absorption is never a blind merge. For each relevant upstream change, inspect six layers:

1. router: `skills/story/SKILL.md` and `skills/novel-assistant/SKILL.md`.
2. workflow: `skills/story-workflow/SKILL.md` and `workflow-contract.md`.
3. L3 contract: target module `SKILL.md`.
4. output safety: `output-safety-contract.md` if the change affects visible output, writing, review, tools, or reports.
5. bundle: `skills/novel-assistant/references/internal-skills/` and `skills/oh-story/references/internal-skills/`.
6. tests and scripts: production smoke, bats tests, static checks, and relevant runtime scripts.

Record the decision as `absorb`, `already-covered`, or `skip` with a reason. Release metadata alone is normally skipped.

## readme_boundary

`README.md` explains usage, rationale, and high-level architecture. It should not be the only source of executable workflow rules. Detailed L2/L3 protocol lives in `workflow-contract.md`; output safety and failure handling lives in `output-safety-contract.md`; release readiness is checked by `maintainability-audit.js`.

## commercial_release_gate

Before production or commercial use, run:

```bash
node scripts/maintainability-audit.js --repo-root . --json
node scripts/production-smoke-matrix.js --repo-root . --json
bash scripts/run-bats-tests.sh
bash scripts/static-check.sh
bash scripts/check-shared-files.sh
git diff --check
```

All required checks must pass. Transitional warnings are allowed only when documented and not related to router, workflow, bundle, or output safety drift.
